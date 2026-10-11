#!/usr/bin/env bash
# fleet-deps-share.sh — a new worktree shares the dependency trees this login
# already has, instead of installing them all over again (issue #3403).
#
#   fleet-deps-share.sh [<worktree> [<main>]]   share into a new worktree
#   fleet-deps-share.sh --status [<worktree>]   what that worktree was given
#
# Why: every worktree used to install its node_modules from zero — slow, hundreds
# of MB a directory, and tens of thousands of new files for fseventsd to chew
# (2026-10-11: fseventsd at 115% CPU on the macmini, issue #3402). Measured on the
# monorepo's core/admin-frontend: `npm ci` in a second worktree wrote 41,778 files
# and 298 MB; an APFS clone of the first one's tree took 0.33 s and 12 MB.
#
# fleet_worktree_setup (fleet-lib.sh) runs this on EVERY new worktree, after the
# optional FLEET_WORKTREE_SETUP hook, under a timebox; FLEET_DEPS_SHARE=0 turns it
# off. It never installs anything: a repo that installs nothing at worktree time
# still installs nothing — what an install would reproduce is cloned in, the rest
# is left to install as usual. Same login only: every source is this login's base
# checkout or one of its worktrees, every cache this login's own.
#
# Per lockfile directory (tracked lockfiles only — `git ls-files`), one line:
#
#   clone:<how> <dir> <from>  <dir>/node_modules (and its lockfile-less workspace
#                             members') is a copy-on-write clone of <from>'s, whose
#                             lockfile is byte-identical and whose tree was
#                             installed from it. <how>: clonefile (APFS — one
#                             clonefile(2) per tree) or reflink (`cp --reflink=always`)
#   install <dir>             no source has this lockfile installed — install as usual
#   skipped:no-clone <dir>    a source exists but this filesystem cannot clone
#                             (not APFS / no reflink / another volume) — install as
#                             usual; a full copy would cost what the install does
#   skipped:exists <dir>      the worktree already has a node_modules there
#   skipped:link-into-source <dir>
#                             the source's tree holds an ABSOLUTE link into the
#                             source checkout (a file:/link: dep): a clone would run
#                             this worktree against the source's copy of that code
#   skipped:not-ignored <dir> git does not ignore <dir>/node_modules — a clone
#                             would read as untracked work
#   pnpm-store <dir>          pnpm-lock.yaml, nothing to clone: pnpm already keeps
#                             ONE store per login and imports with clone → hardlink
#                             → copy (`package-import-method=auto`), so the install
#                             is the shared one already
#   uv-cache <dir>            uv.lock: uv's cache is per login and links with clone
#                             (macOS) / hardlink (Linux) by default. A .venv is never
#                             cloned — it carries absolute paths
#   go-modcache <dir>         go.mod: GOMODCACHE is per login already
#
# A source is fresh when its node_modules carries the fleet's base stamp
# (`.fleet-lock-sha`, fleet-deps-link.sh #961) equal to the lockfile's sha, or —
# no stamp — the package manager's own install marker (.package-lock.json,
# .yarn-integrity, .yarn-state.yml, .modules.yaml) is not older than the lockfile
# on disk; a reinstall in flight (`.fleet-installing`) never is. The base checkout
# is asked first, then the other worktrees of the same checkout.
#
# The record: <git-dir>/fleet-deps-share (the per-worktree admin dir — outside
# `git status`, pruned with the worktree) holds the lines above; one summary line
# per worktree goes to <install>/logs/deps-share.log (FLEET_DEPS_SHARE_LOG). A repo
# with no lockfile writes neither. Exit 0 on a completed run, 2 on usage.
set -u

BIN="$(cd "$(dirname "$0")" && pwd)"
STATUS=0 POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --status)  STATUS=1 ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    -*)        sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    *)         POS+=("$1") ;;
  esac
  shift
done

abs() { (cd "$1" 2>/dev/null && pwd -P); }

WT="${POS[0]:-}"
[ -n "$WT" ] || WT=$(git rev-parse --show-toplevel 2>/dev/null) || true
WT=$(abs "${WT:-.}") && [ -n "$WT" ] || { echo "fleet-deps-share: no worktree" >&2; exit 2; }
GD=$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null) || { echo "fleet-deps-share: not a git worktree: $WT" >&2; exit 2; }
REC="$GD/fleet-deps-share"

if [ "$STATUS" = 1 ]; then
  [ -f "$REC" ] && cat "$REC" || echo "none ."
  exit 0
fi

MAIN="${POS[1]:-}"
if [ -z "$MAIN" ]; then
  c=$(git -C "$WT" rev-parse --git-common-dir 2>/dev/null) || c=""
  case "$c" in /*) ;; ?*) c="$WT/$c" ;; esac
  [ -n "$c" ] && MAIN="$(abs "$c")" && MAIN="${MAIN%/.git}"
fi
MAIN=$(abs "${MAIN:-/nonexistent}") || MAIN=""
[ "$MAIN" = "$WT" ] && { echo "skipped:is-main ."; exit 0; }

LOCKS="package-lock.json pnpm-lock.yaml yarn.lock npm-shrinkwrap.json"
STAMP=.fleet-lock-sha INSTALLING=.fleet-installing
MARKERS=".package-lock.json .yarn-integrity .yarn-state.yml .modules.yaml"
T0=$(date +%s)

lock_sha() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 < "$1" 2>/dev/null
  else sha256sum < "$1" 2>/dev/null; fi | cut -d' ' -f1
}
at() { [ "$2" = . ] && printf '%s' "$1" || printf '%s/%s' "$1" "$2"; }

# Every tracked file that decides anything, outside vendored node_modules.
FILES=$(git -C "$WT" ls-files 2>/dev/null \
  | grep -E '(^|/)(package\.json|package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|uv\.lock|go\.mod)$' \
  | grep -Ev '(^|/)node_modules/')
[ -n "$FILES" ] || exit 0

dirof() { case "$1" in */*) printf '%s' "${1%/*}" ;; *) printf . ;; esac; }

# lock_of <dir> → the governing JS lockfile basename in <dir>, or empty.
lock_of() {
  local f
  for f in $LOCKS; do [ -f "$1/$f" ] && { printf '%s' "$f"; return 0; }; done
  return 1
}

# fresh <src-dir> <lockfile-basename> — rc 0 iff <src-dir>/node_modules is the tree
# that lockfile installs (see the header).
fresh() {
  local d="$1" lk="$2" st m
  [ -d "$d/node_modules" ] && [ ! -L "$d/node_modules" ] || return 1
  [ -e "$d/node_modules/$INSTALLING" ] && return 1
  if [ -f "$d/node_modules/$STAMP" ]; then
    IFS= read -r st < "$d/node_modules/$STAMP" 2>/dev/null || st=""
    [ -n "$st" ] && [ "$st" = "$(lock_sha "$d/$lk")" ]; return
  fi
  for m in $MARKERS; do
    [ -f "$d/node_modules/$m" ] && ! [ "$d/$lk" -nt "$d/node_modules/$m" ] && return 0
  done
  return 1
}

# abs_link_into <root> <nm-dir> — rc 0 iff a top-level entry (incl. @scope/pkg) of
# <nm-dir> is an ABSOLUTE symlink into <root>: after a clone it would still point
# at <root>'s copy. Relative links (workspace members, .bin, pnpm's .pnpm) follow
# the clone to the worktree's own files.
abs_link_into() {
  local root="$1" nm="$2" l t
  for l in "$nm"/* "$nm"/.[!.]* "$nm"/@*/*; do
    [ -L "$l" ] || continue
    t=$(readlink "$l") || continue
    case "$t" in "$root"/*|"$root") return 0 ;; esac
  done
  return 1
}

# How this filesystem clones a tree. FLEET_DEPS_SHARE_CLONE is a selftest seam:
# `off` = cannot clone, `copy` = a plain `cp -R` (a filesystem without clones
# still exercises every other path).
CLONE_HOW="${FLEET_DEPS_SHARE_CLONE:-auto}"
if [ "$CLONE_HOW" = auto ]; then
  case "$(uname -s)" in Darwin) CLONE_HOW=clonefile ;; *) CLONE_HOW=reflink ;; esac
fi
clone_tree() {  # <src> <dst> — rc 0 iff <dst> is now a clone of <src>
  case "$CLONE_HOW" in
    clonefile)
      command -v python3 >/dev/null 2>&1 || return 1
      python3 -I -c '
import ctypes, sys
libc = ctypes.CDLL(None, use_errno=True)
# CLONE_NOFOLLOW = 1: a top-level link is cloned as the link itself.
sys.exit(0 if libc.clonefile(sys.argv[1].encode(), sys.argv[2].encode(), ctypes.c_uint32(1)) == 0 else 1)
' "$1" "$2" 2>/dev/null ;;
    reflink) cp -R -P -p --reflink=always "$1" "$2" 2>/dev/null ;;
    copy)    cp -R -P -p "$1" "$2" 2>/dev/null ;;
    *)       return 1 ;;
  esac
}

# Sources: the base checkout first, then this checkout's other worktrees.
SOURCES=$(
  [ -n "$MAIN" ] && printf '%s\n' "$MAIN"
  git -C "$WT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' \
    | while IFS= read -r p; do p=$(abs "$p") || continue; [ "$p" = "$WT" ] || [ "$p" = "$MAIN" ] || printf '%s\n' "$p"; done
)

# The JS lockfile dirs, shallowest first, and every package.json dir.
PKGDIRS=$(printf '%s\n' "$FILES" | grep -E '(^|/)package\.json$' | while IFS= read -r f; do dirof "$f"; printf '\n'; done)
LOCKDIRS=$(printf '%s\n' "$FILES" | grep -E '(^|/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml)$' \
  | while IFS= read -r f; do dirof "$f"; printf '\n'; done | awk 'NF && !s[$0]++')

# members <L> → L, then every package.json dir under L whose nearest lockfile dir is L.
members() {
  local L="$1" p a
  printf '%s\n' "$L"
  printf '%s\n' "$PKGDIRS" | while IFS= read -r p; do
    [ -n "$p" ] && [ "$p" != "$L" ] || continue
    case "$L" in .) ;; *) case "$p" in "$L"/*) ;; *) continue ;; esac ;; esac
    printf '%s\n' "$LOCKDIRS" | grep -qxF -- "$p" && continue   # its own lockfile governs it
    a="$p"
    while :; do
      case "$a" in */*) a="${a%/*}" ;; *) a=. ;; esac
      if printf '%s\n' "$LOCKDIRS" | grep -qxF -- "$a"; then [ "$a" = "$L" ] && printf '%s\n' "$p"; break; fi
      [ "$a" = . ] && break
    done
  done
}

# A clone cut short (the timebox's TERM) must not leave its half-tree behind as
# untracked files: the one in flight is removed on the way out.
CUR_TMP=""
trap '[ -n "$CUR_TMP" ] && rm -rf "$CUR_TMP"; exit 143' TERM
trap '[ -n "$CUR_TMP" ] && rm -rf "$CUR_TMP"; exit 130' INT HUP

OUT=""
emit() { OUT="$OUT$1
"; printf '%s\n' "$1"; }

while IFS= read -r L; do
  [ -n "$L" ] || continue
  w=$(at "$WT" "$L")
  lk=$(lock_of "$w") || continue
  if [ -e "$w/node_modules" ]; then emit "skipped:exists $L"; continue; fi
  src=""
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    sd=$(at "$s" "$L")
    [ -f "$sd/$lk" ] && cmp -s "$w/$lk" "$sd/$lk" && fresh "$sd" "$lk" || continue
    src="$s"; break
  done <<EOF
$SOURCES
EOF
  if [ -z "$src" ]; then
    [ "$lk" = pnpm-lock.yaml ] && emit "pnpm-store $L" || emit "install $L"
    continue
  fi
  verdict="" n=0 made=""
  while IFS= read -r P; do
    [ -n "$P" ] || continue
    sn="$(at "$src" "$P")/node_modules" wd="$(at "$WT" "$P")"
    [ -d "$sn" ] && [ ! -L "$sn" ] && [ -d "$wd" ] && [ ! -e "$wd/node_modules" ] || continue
    if abs_link_into "$src" "$sn"; then verdict="skipped:link-into-source"; break; fi
    tmp="$wd/.node_modules.fleet-share.$$"
    rm -rf "$tmp" 2>/dev/null; CUR_TMP="$tmp"
    if ! clone_tree "$sn" "$tmp"; then
      rm -rf "$tmp" 2>/dev/null; verdict="skipped:no-clone"; break
    fi
    mv "$tmp" "$wd/node_modules" 2>/dev/null || { rm -rf "$tmp"; CUR_TMP=""; verdict="skipped:no-clone"; break; }
    CUR_TMP=""
    if ! git -C "$WT" check-ignore -q "$( [ "$P" = . ] && echo node_modules || echo "$P/node_modules")" 2>/dev/null; then
      rm -rf "$wd/node_modules"; verdict="skipped:not-ignored"; break
    fi
    n=$((n + 1)) made="$made$wd/node_modules
"
  done <<EOF
$(members "$L")
EOF
  # All of a lockfile's trees or none: a half-cloned workspace is neither shape.
  if [ -n "$verdict" ] && [ -n "$made" ]; then
    printf '%s' "$made" | while IFS= read -r m; do [ -n "$m" ] && rm -rf "$m"; done
  fi
  [ -n "$verdict" ] || [ "$n" -gt 0 ] || verdict="install"
  if [ -n "$verdict" ]; then emit "$verdict $L"; else emit "clone:$CLONE_HOW $L $src"; fi
done <<EOF
$LOCKDIRS
EOF

while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in *uv.lock) emit "uv-cache $(dirof "$f")" ;; *) emit "go-modcache $(dirof "$f")" ;; esac
done <<EOF
$(printf '%s\n' "$FILES" | grep -E '(^|/)(uv\.lock|go\.mod)$')
EOF
[ -n "$OUT" ] || exit 0

printf '%s' "$OUT" > "$REC" 2>/dev/null
LOG="${FLEET_DEPS_SHARE_LOG:-$BIN/../logs/deps-share.log}"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
printf '%s' "$OUT" | awk -v ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)" -v wt="$WT" -v secs="$(( $(date +%s) - T0 ))" '
  { k = $1; sub(/:.*/, "", k); if (k == "skipped") k = $1; c[k]++; if (!(k in o)) { o[k] = ++n; ord[n] = k } }
  END { s = ts " " wt; for (i = 1; i <= n; i++) s = s " " ord[i] "=" c[ord[i]]; print s " " secs "s" }' >> "$LOG" 2>/dev/null
exit 0
