#!/usr/bin/env bash
# fleet-deps-link.sh — a new worktree borrows the base checkout's node_modules
# instead of installing its own (issue #885).
#
#   fleet-deps-link.sh [--dry-run] [<worktree> [<main>]]
#   fleet-deps-link.sh --unlink <dir>
#   fleet-deps-link.sh --prime-base [<main>]         install + stamp every base dir
#   fleet-deps-link.sh --refresh-base <main> [<old> <new>]   reinstall the stale ones
#   fleet-deps-link.sh --base-status [<main>]        fresh / stale / … per base dir
#
# Why: every worktree used to install its dependencies from zero — on the monorepo
# that is 3–6 GB and >200,000 files per spawn, nearly all of them byte-identical
# to the base checkout's copy, and every one of them is an event for fseventsd to
# chew (at install, and again when the worktree is reaped). When a directory's
# lockfile is byte-identical to the base checkout's, the install would reproduce
# the tree already there, so link to it: `node_modules → $MAIN/<dir>/node_modules`.
#
# This is the stock FLEET_WORKTREE_SETUP hook (fleet_worktree_setup in
# fleet-lib.sh calls it as `<cmd> <worktree> <main>`, cwd = the worktree, under a
# timebox). Run by hand it defaults to the worktree containing cwd and that
# worktree's main checkout.
#
# Per directory holding a package.json (node_modules/ and .git skipped), one line:
#
#   linked <dir>              node_modules is now a link into the base checkout
#   installed-needed <dir>    the lockfile differs, or the base has nothing
#                             installed there — install as usual
#   installed-needed:base-stale <dir>
#                             lockfiles match, but the base's node_modules was NOT
#                             installed from that lockfile (its stamp is another
#                             sha, or a base reinstall is running) — install as usual
#   installed-needed:base-unstamped <dir>
#                             lockfiles match, but the base's node_modules carries
#                             no stamp at all, so nothing proves it is current —
#                             `--prime-base` once stamps it
#   skipped:<why> <dir>       not linked, for <why>:
#       no-lockfile           no lockfile here or above it to compare
#       local-link            the base's node_modules links back into repo SOURCE
#                             (a workspace / file: / link: dep): a link would make
#                             this worktree run against the BASE's copy of that
#                             source, so its own edits would go untested
#       root-not-linked       a workspace member whose lockfile-owning ancestor was
#                             not linked (an install there writes into this dir)
#       no-deps               the base has no node_modules here and none is needed
#       exists                the worktree already has its own node_modules
#
# A directory is linked only when ALL of: its governing lockfile (its own
# package-lock.json / pnpm-lock.yaml / yarn.lock, else the nearest ancestor's) is
# byte-identical to the base checkout's, that ancestor was itself linked, the
# base's node_modules exists AND IS FRESH, and none of its top-level entries links
# back into the repo outside a node_modules tree.
#
# FRESH (issue #961): matching lockfiles prove nothing about the base's TREE. The
# base-sync daemon fast-forwards the base checkout every 60 s, so its lockfile
# always matches a new worktree's — even when its node_modules was installed from
# the lockfile two dependency bumps ago. So a base install is trusted only when it
# says which lockfile it came from: `node_modules/.fleet-lock-sha` = the sha256 of
# the lockfile it was installed from, written only after that install SUCCEEDED,
# and removed before a reinstall starts (`node_modules/.fleet-installing` marks one
# in flight). No stamp, another sha, or a marker ⇒ not linked. The base side:
#
#   --prime-base [<main>]     install (npm ci / yarn --frozen-lockfile|--immutable /
#                             pnpm --frozen-lockfile) in every lockfile directory of
#                             the base checkout, one at a time, and stamp each — the
#                             one-off for a fleet turning shared deps on.
#   --refresh-base <main> [<old> <new>]
#                             what base-sync runs after each tick when shared deps are
#                             on (fleet_base_deps_on): reinstall every directory this
#                             tool has stamped whose stamp no longer matches, plus
#                             every directory whose lockfile changed in <old>..<new>.
#                             A no-op tick costs a sha per stamped lockfile.
#   --base-status [<main>]    `<state> <dir>` per lockfile directory (fresh / stale /
#                             unstamped / installing / not-installed) and a closing
#                             `summary fresh=… stale=… unstamped=… not-installed=…`.
#
# Installs are `nice -n 10`, serial, each under fleet_timebox
# (FLEET_BASE_DEPS_TIMEOUT, default 900 s), output appended to
# <install>/logs/base-deps.log (FLEET_BASE_DEPS_LOG). A failed or timed-out install
# leaves the directory UNSTAMPED — i.e. not linked — and is retried next tick. One
# run per base at a time (a mkdir lock in the base's git dir); a second one skips.
#
# The shared tree must never be written through the link: hooks/bash-guard.py
# refuses `npm|pnpm|yarn|bun install/add/remove/ci/…` inside a linked directory.
# `--unlink <dir>` removes the link (the LINK only — never the base's tree) for
# <dir> and every linked directory beneath it, after which an install there
# writes a real node_modules of the worktree's own.
#
# Bookkeeping, all outside the worktree's `git status`:
#   <git-dir>/fleet-deps-links   the linked dirs, one per line (the guard and the
#                                --unlink path read it; `git worktree prune`
#                                deletes it with the worktree's admin dir)
#   <common-dir>/info/exclude    `/<dir>/node_modules` when git does not already
#                                ignore the link — a `node_modules/` pattern
#                                matches only a DIRECTORY, and a symlink is not
#                                one, so the link would read as untracked (dirty
#                                to fleet_worktree_drop's gate and the ship step)
#
# Exit: 0 on a completed run (whatever each line says), 2 on usage / not a git
# worktree. Every setup-hook failure is non-fatal to the spawn by contract.
set -u

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

DRY=0 UNLINK="" BASE_MODE="" POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=1 ;;
    --prime-base)   BASE_MODE=prime ;;
    --refresh-base) BASE_MODE=refresh ;;
    --base-status)  BASE_MODE=status ;;
    --unlink)     UNLINK="${2:-}"; [ -n "$UNLINK" ] || usage; shift ;;
    -h|--help)    usage ;;
    -*)           usage ;;
    *)            POS+=("$1") ;;
  esac
  shift
done

LOCKS="package-lock.json pnpm-lock.yaml yarn.lock npm-shrinkwrap.json"

# abs <path> → physical absolute path of an existing directory, or empty.
abs() { (cd "$1" 2>/dev/null && pwd -P); }

# The worktree's own git dir (per-worktree admin dir) and the shared one.
git_dir()    { git -C "$1" rev-parse --absolute-git-dir 2>/dev/null; }
common_dir() {
  local c; c=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$c" in /*) ;; *) c="$1/$c" ;; esac
  abs "$c"
}

# norm <path> — collapse `.`, `..` and `//` lexically (no fork, no symlink walk).
# Used on the targets of a few hundred symlinks per directory, so it stays in-shell.
norm() {
  local p="$1" out="" seg rest
  rest="${p#/}"
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    if [ "$seg" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    case "$seg" in
      ''|.) ;;
      ..)   out="${out%/*}" ;;
      *)    out="$out/$seg" ;;
    esac
  done
  printf '%s' "${out:-/}"
}

# local_link <main> <nm-dir> — rc 0 iff some top-level entry of <nm-dir> (incl. one
# scope level, @scope/pkg) is a symlink that resolves INSIDE <main> but OUTSIDE
# every node_modules tree: a workspace / file: / link: dependency on repo source.
# pnpm's own links (into node_modules/.pnpm) and anything outside the repo pass.
local_link() {
  local main="$1" nm="$2" l t dir r
  for l in "$nm"/* "$nm"/.[!.]* "$nm"/@*/*; do
    [ -L "$l" ] || continue
    case "${l##*/}" in .bin) continue ;; esac
    t=$(readlink "$l") || continue
    dir="${l%/*}"
    case "$t" in /*) r=$(norm "$t") ;; *) r=$(norm "$dir/$t") ;; esac
    case "$r" in
      "$main"/*) case "$r/" in */node_modules/*) ;; *) return 0 ;; esac ;;
    esac
  done
  return 1
}

# lock_of <dir> → the lockfile basename in <dir>, or empty.
lock_of() {
  local f
  for f in $LOCKS; do [ -f "$1/$f" ] && { printf '%s' "$f"; return 0; }; done
  return 1
}

# lock_sha <file> → its sha256 (hex), or empty.
lock_sha() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 < "$1" 2>/dev/null
  else sha256sum < "$1" 2>/dev/null; fi | cut -d' ' -f1
}

STAMP=.fleet-lock-sha INSTALLING=.fleet-installing

# base_state <base-dir> <lockfile-basename> → fresh | stale | unstamped |
# installing | not-installed: is <base-dir>/node_modules the tree <lockfile> installs?
base_state() {
  local d="$1" lk="$2" st
  [ -d "$d/node_modules" ] || { echo not-installed; return; }
  [ -e "$d/node_modules/$INSTALLING" ] && { echo installing; return; }
  [ -f "$d/node_modules/$STAMP" ] || { echo unstamped; return; }
  IFS= read -r st < "$d/node_modules/$STAMP" 2>/dev/null || st=""
  [ -n "$st" ] && [ "$st" = "$(lock_sha "$d/$lk")" ] && { echo fresh; return; }
  echo stale
}

manifest_add() {  # <manifest> <rel>
  [ -f "$1" ] && grep -qxF -- "$2" "$1" 2>/dev/null && return 0
  printf '%s\n' "$2" >> "$1"
}

# exclude_link <wt> <rel> — make git ignore the link when it does not already.
exclude_link() {
  local wt="$1" rel="$2" pat cd ex
  [ "$rel" = . ] && pat="/node_modules" || pat="/$rel/node_modules"
  git -C "$wt" check-ignore -q "${pat#/}" 2>/dev/null && return 0
  cd=$(common_dir "$wt") || return 0
  ex="$cd/info/exclude"
  mkdir -p "$cd/info" 2>/dev/null
  grep -qxF -- "$pat" "$ex" 2>/dev/null && return 0
  { [ -s "$ex" ] && [ -n "$(tail -c1 "$ex")" ] && printf '\n'
    grep -qF '# fleet-deps-link' "$ex" 2>/dev/null \
      || printf '# fleet-deps-link (issue #885): node_modules symlinks into the base checkout\n'
    printf '%s\n' "$pat"; } >> "$ex" 2>/dev/null
}

# ---- the base side: --prime-base / --refresh-base / --base-status (#961) -----
if [ -n "$BASE_MODE" ]; then
  BIN="$(cd "$(dirname "$0")" && pwd)"
  MAIN="${POS[0]:-${FLEET_MAIN:-}}"
  if [ -z "$MAIN" ]; then
    t=$(git rev-parse --show-toplevel 2>/dev/null) && cdir=$(common_dir "$t") && MAIN="${cdir%/.git}"
  fi
  MAIN=$(abs "${MAIN:-/nonexistent}") || { echo "fleet-deps-link: no base checkout" >&2; exit 2; }
  GD=$(git_dir "$MAIN") || { echo "fleet-deps-link: not a git checkout: $MAIN" >&2; exit 2; }
  MANAGED="$GD/fleet-base-deps"
  at() { [ "$1" = . ] && printf '%s' "$MAIN" || printf '%s/%s' "$MAIN" "$1"; }

  # Every lockfile-owning directory of the base, shallowest first.
  base_dirs() {
    find "$MAIN" \( -name node_modules -o -name .git -o -name .claude -o -name .fleet-trash \) -prune \
         -o -name package.json -type f -print 2>/dev/null \
      | sed 's#/package\.json$##' \
      | awk -v m="$MAIN" '{ r = substr($0, length(m) + 2); if (r == "") r = "."; n = (r == ".") ? 0 : gsub("/", "/", r) + 1; print n "\t" r }' \
      | sort -n -k1,1 -k2 | cut -f2- \
      | while IFS= read -r r; do lock_of "$(at "$r")" >/dev/null && printf '%s\n' "$r"; done
  }

  if [ "$BASE_MODE" = status ]; then
    nf=0 ns=0 nu=0 ni=0 nn=0
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      st=$(base_state "$(at "$r")" "$(lock_of "$(at "$r")")")
      case "$st" in fresh) nf=$((nf+1)) ;; stale) ns=$((ns+1)) ;; unstamped) nu=$((nu+1)) ;;
                    installing) ni=$((ni+1)) ;; *) nn=$((nn+1)) ;; esac
      printf '%s %s\n' "$st" "$r"
    done <<EOF
$(base_dirs)
EOF
    printf 'summary fresh=%s stale=%s unstamped=%s installing=%s not-installed=%s\n' "$nf" "$ns" "$nu" "$ni" "$nn"
    exit 0
  fi

  # The work list: prime = every lockfile dir; refresh = every stamped-by-us dir
  # that is no longer fresh + every dir whose lockfile changed in <old>..<new>.
  if [ "$BASE_MODE" = prime ]; then
    TODO=$(base_dirs)
  else
    TODO=""
    if [ -f "$MANAGED" ]; then
      while IFS= read -r r; do
        [ -n "$r" ] && lk=$(lock_of "$(at "$r")") || continue
        [ "$(base_state "$(at "$r")" "$lk")" = fresh ] || TODO="$TODO$r
"
      done < "$MANAGED"
    fi
    if [ -n "${POS[1]:-}" ] && [ -n "${POS[2]:-}" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in */*) r="${f%/*}" ;; *) r=. ;; esac
        [ "$(lock_of "$(at "$r")")" = "${f##*/}" ] && [ -f "$(at "$r")/package.json" ] || continue
        TODO="$TODO$r
"
      done <<EOF
$(git -C "$MAIN" diff --name-only "${POS[1]}" "${POS[2]}" 2>/dev/null | grep -E '(^|/)(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|npm-shrinkwrap\.json)$' | grep -Ev '(^|/)node_modules/')
EOF
    fi
    TODO=$(printf '%s' "$TODO" | awk 'NF && !seen[$0]++ { n = ($0 == ".") ? 0 : gsub("/", "/") + 1; print n "\t" $0 }' \
      | sort -n -k1,1 -k2 | cut -f2-)
  fi
  [ -n "$TODO" ] || exit 0

  if [ "$DRY" = 1 ]; then
    printf '%s\n' "$TODO" | sed 's/^/would-install /'; exit 0
  fi

  # One run per base: a mkdir lock whose holder is a live pid; a dead one's is taken over.
  LOCK="$GD/fleet-base-deps.lock"
  if ! mkdir "$LOCK" 2>/dev/null; then
    hp=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$hp" ] && kill -0 "$hp" 2>/dev/null; then
      printf 'busy . (pid %s is installing in this base)\n' "$hp"; exit 0
    fi
    rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || { printf 'busy .\n'; exit 0; }
  fi
  echo $$ > "$LOCK/pid"
  trap 'rm -rf "$LOCK"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # shellcheck source=/dev/null
  [ -f "$BIN/fleet-lib.sh" ] && . "$BIN/fleet-lib.sh"
  command -v fleet_timebox >/dev/null 2>&1 || fleet_timebox() { shift; "$@"; }
  TMO="${FLEET_BASE_DEPS_TIMEOUT:-900}"
  case "$TMO" in ''|*[!0-9]*) TMO=900 ;; esac
  LOG="${FLEET_BASE_DEPS_LOG:-$BIN/../logs/base-deps.log}"
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

  while IFS= read -r r; do
    [ -n "$r" ] || continue
    d=$(at "$r")
    lk=$(lock_of "$d") || continue
    case "$lk" in
      pnpm-lock.yaml) set -- pnpm install --frozen-lockfile ;;
      yarn.lock)      if [ -f "$d/.yarnrc.yml" ] || [ -f "$MAIN/.yarnrc.yml" ]; then
                        set -- yarn install --immutable
                      else
                        set -- yarn install --frozen-lockfile
                      fi ;;
      *)              set -- npm ci ;;
    esac
    if ! command -v "$1" >/dev/null 2>&1; then
      printf '%s %s skipped: %s not on PATH\n' "$(ts)" "$d" "$1" >> "$LOG"
      printf 'skipped:no-%s %s\n' "$1" "$r"; continue
    fi
    sha=$(lock_sha "$d/$lk")
    manifest_add "$MANAGED" "$r"          # before the install: a killed run is retried
    mkdir -p "$d/node_modules" 2>/dev/null
    rm -f "$d/node_modules/$STAMP"
    : > "$d/node_modules/$INSTALLING"
    printf '%s %s start: %s (lock %s)\n' "$(ts)" "$d" "$*" "${sha%"${sha#????????????}"}" >> "$LOG"
    ( cd "$d" && fleet_timebox "$TMO" nice -n 10 "$@" ) </dev/null >> "$LOG" 2>&1; rc=$?
    rm -f "$d/node_modules/$INSTALLING"
    if [ "$rc" = 0 ] && [ -d "$d/node_modules" ]; then
      printf '%s\n' "$sha" > "$d/node_modules/$STAMP"
      printf '%s %s ok\n' "$(ts)" "$d" >> "$LOG"
      printf 'installed %s\n' "$r"
    else
      [ "$rc" = 124 ] && why=timeout || why="rc=$rc"
      printf '%s %s FAILED (%s) — left unstamped, retried next tick\n' "$(ts)" "$d" "$why" >> "$LOG"
      printf 'install-failed:%s %s\n' "$why" "$r"
    fi
  done <<EOF
$TODO
EOF
  exit 0
fi

# ---- --unlink ---------------------------------------------------------------
if [ -n "$UNLINK" ]; then
  d="$UNLINK"; d="${d%/}"
  case "$d" in node_modules) d=. ;; */node_modules) d="${d%/node_modules}" ;; esac
  [ -n "$d" ] || d=/
  D=$(abs "$d") || { echo "fleet-deps-link: no such directory: $UNLINK" >&2; exit 2; }
  WT=$(git -C "$D" rev-parse --show-toplevel 2>/dev/null) && WT=$(abs "$WT") \
    || { echo "fleet-deps-link: not inside a git worktree: $UNLINK" >&2; exit 2; }
  MF="$(git_dir "$WT")/fleet-deps-links"
  rel="${D#"$WT"}"; rel="${rel#/}"; [ -n "$rel" ] || rel=.
  n=0; keep=""
  if [ -f "$MF" ]; then
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      case "$rel" in
        .) under=1 ;;
        *) case "$l" in "$rel"|"$rel"/*) under=1 ;; *) under=0 ;; esac ;;
      esac
      if [ "$under" = 1 ]; then
        p="$WT/$l"; [ "$l" = . ] && p="$WT"
        if [ -L "$p/node_modules" ]; then
          [ "$DRY" = 1 ] || rm -f "$p/node_modules"     # the LINK — never its target
          printf 'unlinked %s\n' "$l"; n=$((n + 1))
        fi
      else
        keep="$keep$l
"
      fi
    done < "$MF"
    [ "$DRY" = 1 ] || printf '%s' "$keep" > "$MF"
  fi
  # A link the manifest never recorded (made by hand, or a manifest lost) still goes.
  if [ "$n" = 0 ] && [ -L "$D/node_modules" ]; then
    [ "$DRY" = 1 ] || rm -f "$D/node_modules"
    printf 'unlinked %s\n' "$rel"; n=1
  fi
  [ "$n" -gt 0 ] || printf 'not-linked %s\n' "$rel"
  exit 0
fi

# ---- link -------------------------------------------------------------------
WT="${POS[0]:-}"
[ -n "$WT" ] || WT=$(git rev-parse --show-toplevel 2>/dev/null) || true
WT=$(abs "${WT:-.}") && [ -n "$WT" ] || { echo "fleet-deps-link: no worktree" >&2; exit 2; }
git -C "$WT" rev-parse --git-dir >/dev/null 2>&1 || { echo "fleet-deps-link: not a git worktree: $WT" >&2; exit 2; }
MAIN="${POS[1]:-${FLEET_MAIN:-}}"
if [ -z "$MAIN" ]; then
  cdir=$(common_dir "$WT") && MAIN="${cdir%/.git}"
fi
MAIN=$(abs "${MAIN:-/nonexistent}") || { echo "fleet-deps-link: no main checkout" >&2; exit 2; }
if [ "$MAIN" = "$WT" ]; then
  printf 'skipped:is-main .\n'; exit 0
fi
MF="$(git_dir "$WT")/fleet-deps-links"

# Every package.json directory, shallowest first, so a workspace root is decided
# before its members consult it.
DIRS=$(find "$WT" \( -name node_modules -o -name .git \) -prune -o -name package.json -type f -print 2>/dev/null \
  | sed 's#/package\.json$##' \
  | awk -v wt="$WT" '{ r = substr($0, length(wt) + 2); if (r == "") r = "."; n = (r == ".") ? 0 : gsub("/", "/", r) + 1; print n "\t" r }' \
  | sort -n -k1,1 -k2 | cut -f2-)

VERDICT=""   # "<rel>=<token>" lines for lockfile-owning dirs (members look up)

verdict_of() {  # <rel> → the recorded verdict token, or empty
  printf '%s' "$VERDICT" | awk -F'\t' -v r="$1" '$1 == r { print $2; exit }'
}

decide() {  # <rel> → prints the token
  local rel="$1" w m lk a
  if [ "$rel" = . ]; then w="$WT"; m="$MAIN"; else w="$WT/$rel"; m="$MAIN/$rel"; fi
  if [ -L "$w/node_modules" ]; then
    [ "$(readlink "$w/node_modules")" = "$m/node_modules" ] && { echo linked; return; }
    echo skipped:exists; return
  fi
  [ -e "$w/node_modules" ] && { echo skipped:exists; return; }

  if lk=$(lock_of "$w"); then
    [ -f "$m/$lk" ] && cmp -s "$w/$lk" "$m/$lk" || { echo installed-needed; return; }
    [ -d "$m/node_modules" ] || { echo installed-needed; return; }
    case "$(base_state "$m" "$lk")" in
      fresh)     ;;
      unstamped) echo installed-needed:base-unstamped; return ;;
      *)         echo installed-needed:base-stale; return ;;
    esac
    local_link "$MAIN" "$m/node_modules" && { echo skipped:local-link; return; }
    echo link; return
  fi
  # No lockfile of its own: a workspace member — governed by the nearest ancestor
  # that has one. Linked only if that ancestor was.
  a="$rel"
  while [ "$a" != . ]; do
    case "$a" in */*) a="${a%/*}" ;; *) a=. ;; esac
    case "$(verdict_of "$a")" in
      '')                    continue ;;
      link|linked)           [ -d "$m/node_modules" ] || { echo skipped:no-deps; return; }
                             local_link "$MAIN" "$m/node_modules" && { echo skipped:local-link; return; }
                             echo link; return ;;
      *)                     echo skipped:root-not-linked; return ;;
    esac
  done
  echo skipped:no-lockfile
}

while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  tok=$(decide "$rel")
  if [ "$rel" = . ]; then w="$WT"; m="$MAIN"; else w="$WT/$rel"; m="$MAIN/$rel"; fi
  if [ "$tok" = link ]; then
    if [ "$DRY" = 1 ]; then
      tok=linked
    elif ln -s "$m/node_modules" "$w/node_modules" 2>/dev/null; then
      tok=linked
      manifest_add "$MF" "$rel"
      exclude_link "$WT" "$rel"
    else
      tok=skipped:ln-failed
    fi
  elif [ "$tok" = linked ] && [ "$DRY" != 1 ]; then
    manifest_add "$MF" "$rel"   # idempotent re-run: keep the record whole
  fi
  lock_of "$w" >/dev/null && VERDICT="$VERDICT$rel	$tok
"
  printf '%s %s\n' "$tok" "$rel"
done <<EOF
$DIRS
EOF
exit 0
