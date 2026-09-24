#!/bin/bash
# fleet-sync-logins.sh [--dry-run] [--logins a,b] [--include-off] [--force]
#                      [--source <dir>] [--homes <dir>] [--summary]
#                      [--to-git [--origin <url>]]
#   — keep every login's ~/.claude/fleet on ONE machine at the same commit
#     (issue #1069); --to-git turns a copy install into a git clone (issue #1121).
#
# `/fleet-sync-install` is per-machine AND manual, and `fleet-install-version.sh`
# measures one install. On a shared machine the unit is not the machine but the
# LOGIN: the Mac mini has five logins, each with its own `~/.claude/fleet` and its
# own daemons. Measured 2026-09-23: one login at origin/master head, the other
# four 5–13 days behind with 120–130 differing scripts each — while every daemon
# was green. This script is the hand-run recipe that fixed it, automated:
#
#   plan   for every OTHER login's install under --homes (default /Users on
#          macOS, /home elsewhere): its shape (git checkout / file copy), head,
#          how many tracked entries differ from the source, local edits, and
#          whether it is NEWER than the source.
#   act    per login that drifted, AS THAT LOGIN (`sudo -n -u <owner>`, so every
#          file it writes is owned right by construction — no `chown -R`):
#            1. back up the entries about to change → ~u/.claude/fleet.bak-<date>/
#            2. `rsync -a --delete` each git-tracked top-level entry of the
#               source's HEAD into ~u/.claude/fleet/ — a git checkout gets every
#               entry, a guest (copy) install only the entries it already has.
#               Never `fleet.conf`, `logs/`, `.git/` — none of them is tracked,
#               and they are excluded again on top of that.
#            3. a git checkout also moves its HEAD to the source commit (fetched
#               from a bundle — no network, no credentials). Without this the
#               target's tree is new but its HEAD old, so `git status` shows the
#               synced files as local edits and the NEXT run would refuse it as
#               dirty — which is exactly the state the hand-run recipe left one
#               login in. A copy install gets a `.fleet-synced-from` marker
#               instead, so the next run can tell which commit it holds.
#            4. `launchctl kickstart -k` each of that login's daemons — the
#               system-domain `com.claude-fleet.<login>.*` LaunchDaemons, and any
#               gui-domain LaunchAgents under ~u/Library/LaunchAgents.
#            5. verify: zero differing entries, a clean git status at the source
#               commit, and one tmux-spinner.sh alive (a warning, not a failure —
#               a login may simply not run one).
#
# Rails:
#   - Only the source's COMMITTED HEAD is synced (`git archive`), never its
#     working tree — so an uncommitted edit in the source cannot spread.
#   - No downgrade. A login whose install is NEWER than the source (its HEAD, or
#     a copy install's marker, is a commit the source does not have or does not
#     descend to) is blocked: run the sync from the newer login instead.
#   - Local edits block. A tracked file in the target whose content is unknown
#     to the source repo is someone's work, and blocks that login. A file whose
#     content IS a version the source knows is the footprint of an earlier sync,
#     not work, and does not. `--force` overrides both blocks (the backup keeps
#     what it replaces).
#   - No passwordless sudo → nothing is changed for that login; the exact
#     command to run it as an admin is printed instead.
#   - A login that turned auto-update OFF is listed and left alone (issue
#     #1122): FLEET_INSTALL_SYNC=0 in its settings file
#     (`$FLEET_CONF_DIR/fleet.settings`, FLEET_CONF_DIR per its install conf,
#     default ~u/.config/claude-fleet) or, under that, its ~u/.claude/fleet/
#     fleet.conf — the same precedence fleet-lib.sh gives the login's own reads;
#     unset = on. The conf is read as text (as the owner when unreadable), never
#     sourced. Its state is `off`: not current, not drifted, not blocked, and
#     never an error — /fleet-sync-install ends with this sync, and a login's
#     own choice is not the operator's to overrule from another login. Naming
#     it in --logins syncs it anyway (that login was asked for); --include-off
#     syncs every off login. Off wins over blocked: an off login is not this
#     run's to unblock either.
#
# --to-git (issue #1121) — convert, instead of sync. A copy install cannot say
# which version it is (only its marker can, and only if a sync wrote one) and
# cannot update itself; every login should be a clone that follows the public
# repo on its own. For each COPY-shaped login, as that login:
#   1. build a clone beside it (`~u/.claude/fleet.to-git.<pid>`): `git init`,
#      fetch the source's HEAD from a bundle (no network, no credentials), check
#      out the commit the copy holds — its marker, or the source's HEAD for an
#      unmarked copy — and set `origin` to the public repo's https URL (the
#      source's own origin rewritten to https, or `--origin <url>`).
#   2. copy into the clone every file the commit does NOT track — fleet.conf and
#      its backups, logs/, any local file — with rsync, modes kept. Caches
#      (__pycache__, *.pyc, .DS_Store, *.sock) and the marker stay behind.
#   3. swap: the copy dir becomes `~u/.claude/fleet.copy-<date>` (a complete
#      backup, nothing is deleted from it), the clone becomes ~u/.claude/fleet.
#   4. kickstart that login's daemons; verify HEAD, a clean tracked tree, and
#      that fleet.conf / logs came along.
# A login that is already a checkout is skipped. A copy whose tracked files hold
# content the source repo has never seen is someone's work and is blocked (the
# note names the files); `--force` converts anyway — the old copy dir keeps the
# edits. The steps run in ONE owner-side shell (`umask 022`, the owner's HOME):
# `sudo -u` keeps the caller's umask, which on macOS is 077, and a clone built
# that way is unreadable to every other login. --to-git never runs the ordinary
# sync: the converted login sits at the version it had; a following plain run
# brings it forward like any other checkout.
#
# Exit status is the reason, worst first:
#   6  a sync / conversion or its verification failed for at least one login
#   5  at least one login needs sudo — the commands to run are printed
#   4  at least one login is blocked (local edits / newer than the source)
#   3  the source is unusable (not a git checkout; --to-git: no https origin)
#   2  usage error (bad flag, --logins names no install, --summary --to-git)
#   1  --dry-run only: drift found (--to-git: a copy install to convert)
#   0  every selected login is at the source commit (--to-git: is a checkout)
#
# --summary prints ONE line (`4 other · 1 current · 1 off · 2 drifted (…)`; the
# `off` count is there only when some login is off, so a machine with none reads
# as before) and nothing else; it implies --dry-run. `fleet-install-version.sh` reads it for its
# `logins:` line, so the per-login drift of a multi-login machine is on the same
# read as the machine's own.
#
# Seams for the selftest (bin/sync-logins-selftest.sh), all optional:
#   FLEET_SYNC_LOGINS_HOMES       the homes root (same as --homes)
#   FLEET_SYNC_LOGINS_SUDO        the privilege prefix (default `sudo -n`; empty =
#                                 run directly, i.e. only same-owner installs)
#   FLEET_SYNC_LOGINS_LAUNCHCTL   the launchctl binary
#   FLEET_SYNC_LOGINS_DAEMON_DIR  the LaunchDaemons dir (default /Library/LaunchDaemons)
#   FLEET_SYNC_LOGINS_TMP         where the world-readable staging dir goes (/tmp)
#   FLEET_SYNC_LOGINS_ME          who "this login" is (default `id -un`) — lets a
#                                 test reach the sudo path with files it owns
#   FLEET_SYNC_LOGINS_PGREP       the pgrep the spinner check uses
set -u

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
src="${FLEET_LIVE_DIR:-$HOME/.claude/fleet}"
case "$(uname -s 2>/dev/null)" in Darwin) homes_default=/Users ;; *) homes_default=/home ;; esac
homes="${FLEET_SYNC_LOGINS_HOMES:-$homes_default}"
SUDO="${FLEET_SYNC_LOGINS_SUDO-sudo -n}"
LAUNCHCTL="${FLEET_SYNC_LOGINS_LAUNCHCTL:-launchctl}"
DAEMON_DIR="${FLEET_SYNC_LOGINS_DAEMON_DIR:-/Library/LaunchDaemons}"
TMPROOT="${FLEET_SYNC_LOGINS_TMP:-/tmp}"
dry=0 force=0 only='' summary=0 togit=0 origin='' incoff=0

usage() { sed -n '2,/^set -u/p' "$SELF" | sed '$d' | sed 's/^# \{0,1\}//'; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|-n) dry=1 ;;
    --force)      force=1 ;;
    --include-off) incoff=1 ;;
    --summary)    summary=1; dry=1 ;;
    --to-git)     togit=1 ;;
    --origin)     shift; origin="${1:-}" ;;
    --origin=*)   origin="${1#--origin=}" ;;
    --logins)     shift; only="${1:-}" ;;
    --logins=*)   only="${1#--logins=}" ;;
    --source)     shift; src="${1:-}" ;;
    --homes)      shift; homes="${1:-}" ;;
    -h|--help)    usage; exit 0 ;;
    *) printf 'fleet-sync-logins: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
if [ "$summary" -eq 1 ] && [ "$togit" -eq 1 ]; then
  echo 'fleet-sync-logins: --summary and --to-git are exclusive (the summary line counts drift, not shape)' >&2; exit 2
fi

me="${FLEET_SYNC_LOGINS_ME:-$(id -un)}"
PGREP="${FLEET_SYNC_LOGINS_PGREP:-pgrep}"
say() { [ "$summary" -eq 1 ] || printf '%s\n' "$*"; }
# git on another login's checkout trips "dubious ownership"; a command-line
# safe.directory is honoured, and scoping it to one call keeps it off disk.
gitq() { git -c safe.directory='*' -C "$@"; }
# ogit <owner> <dir> <git args…> — read ANOTHER login's checkout as its owner
# (issue #1115). safe.directory only waives the ownership check, not file
# permissions: a `.git` the caller cannot read makes `rev-parse HEAD` / `status`
# fail, so a sync that landed reported FAILED and --summary called it drifted.
# Steps 1–4 already write as the owner; the reads match them. Falls back to the
# caller when it IS the owner or the owner cannot be reached through $SUDO.
# The probe is cached per owner — one `sudo -n true` each, not one per git call;
# ogit mostly runs in a `$(…)` subshell, so warm the cache in the main shell
# (`as_owner <owner> || :`) wherever an owner is first known.
owner_ok='' owner_no=''
as_owner() {
  [ "$1" != "$me" ] && [ -n "$SUDO" ] || return 1
  case " $owner_ok " in *" $1 "*) return 0 ;; esac
  case " $owner_no " in *" $1 "*) return 1 ;; esac
  if $SUDO -u "$1" true 2>/dev/null; then owner_ok="$owner_ok $1"; return 0; fi
  owner_no="$owner_no $1"; return 1
}
ogit() {
  _og=$1; shift
  if as_owner "$_og"; then $SUDO -u "$_og" git -c safe.directory='*' -C "$@"
  else gitq "$@"; fi
}
# oread <owner> <file> — a file's contents, as the owner when the caller cannot
# read it (the copy marker is written as the owner, under sudo's 077 umask).
oread() {
  if [ -r "$2" ]; then cat "$2" 2>/dev/null
  elif as_owner "$1"; then $SUDO -u "$1" cat "$2" 2>/dev/null
  fi
}
# conf_val <text> <KEY> — the last plain `KEY=value` assignment in a conf's
# text, unquoted, trailing comment dropped. A conf is READ, never sourced:
# another login's file is not code to run here.
conf_val() {
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$2=//p" | tail -1 \
    | sed "s/[[:space:]]*#.*$//; s/^[\"']//; s/[\"'][[:space:]]*$//"
}
# autosync_off <owner> <dir> <home> → true iff that login turned auto-update off
# (FLEET_INSTALL_SYNC=0; issue #1122). Its settings file wins over the install's
# fleet.conf, as in fleet-lib.sh; unset anywhere = on. FLEET_CONF_DIR is taken
# from the install conf when set there (a `$HOME`/`~` prefix means that login's
# home), default ~u/.config/claude-fleet.
autosync_off() {
  _c=$(oread "$1" "$2/fleet.conf")
  _v=$(conf_val "$_c" FLEET_INSTALL_SYNC)
  _cd=$(conf_val "$_c" FLEET_CONF_DIR)
  case "$_cd" in
    '')          _cd="$3/.config/claude-fleet" ;;
    '$HOME'/*)   _cd="$3/${_cd#\$HOME/}" ;;
    '${HOME}'/*) _cd="$3/${_cd#\$\{HOME\}/}" ;;
    '~'/*)       _cd="$3/${_cd#\~/}" ;;
  esac
  _s=$(conf_val "$(oread "$1" "$_cd/fleet.settings")" FLEET_INSTALL_SYNC)
  [ -n "$_s" ] && _v=$_s
  [ "$_v" = 0 ]
}
# to_https <url> — an origin URL as its https form (git@host:path, ssh://…)
to_https() {
  case "$1" in
    https://*) printf '%s' "$1" ;;
    ssh://*)   _u=${1#ssh://}; _u=${_u#*@}; printf 'https://%s' "$_u" ;;
    *@*:*)     _u=${1#*@}; printf 'https://%s/%s' "${_u%%:*}" "${_u#*:}" ;;
    *)         printf '%s' "$1" ;;
  esac
}

# --- the source --------------------------------------------------------------
[ -n "$src" ] && [ -d "$src" ] || { printf 'fleet-sync-logins: no source install at %s\n' "$src" >&2; exit 3; }
src=$(cd "$src" && pwd -P)
if [ "$(gitq "$src" rev-parse --show-toplevel 2>/dev/null)" != "$src" ]; then
  printf 'fleet-sync-logins: %s is not a git checkout — the tracked set and the commit come from git, so a copy install cannot be a source\n' "$src" >&2
  exit 3
fi
src_sha=$(gitq "$src" rev-parse --verify --quiet HEAD) || { printf 'fleet-sync-logins: %s has no HEAD commit\n' "$src" >&2; exit 3; }
src_short=$(gitq "$src" rev-parse --short HEAD)
src_subject=$(gitq "$src" log -1 --format=%s HEAD 2>/dev/null)
# --to-git: the clone's origin is the PUBLIC repo over https — reachable by every
# login without credentials. The source's own origin, rewritten; --origin wins.
branch=''
if [ "$togit" -eq 1 ]; then
  branch=$(gitq "$src" symbolic-ref --short HEAD 2>/dev/null); branch=${branch:-master}
  if [ -z "$origin" ]; then
    src_origin=$(gitq "$src" remote get-url origin 2>/dev/null)
    origin=$(to_https "$src_origin")
    case "$origin" in
      https://*) ;;
      *) printf 'fleet-sync-logins: --to-git needs an https origin for the clones, and the source'"'"'s origin is %s — pass --origin <https-url>\n' "${src_origin:-unset}" >&2; exit 3 ;;
    esac
  fi
fi

# The tracked top-level entries at HEAD. fleet.conf / logs / .git are never
# tracked; they are dropped here again so a future mistake cannot sync one.
entries=$(gitq "$src" ls-tree --name-only HEAD | grep -v -x -e 'fleet.conf' -e 'logs' -e '.git' | grep -v '^fleet\.conf\.bak')

# Stage HEAD once, world-readable, so every login's own rsync can read it.
STAGE=$(mktemp -d "$TMPROOT/fleet-sync-logins.XXXXXX") || { echo 'fleet-sync-logins: mktemp failed' >&2; exit 3; }
trap 'rm -rf "$STAGE"' EXIT INT TERM HUP
mkdir -p "$STAGE/tree"
gitq "$src" archive --format=tar HEAD | tar -xf - -C "$STAGE/tree"
# Both halves: an archive that dies early can hand tar a clean-looking EOF.
[ "${PIPESTATUS[0]}${PIPESTATUS[1]}" = 00 ] \
  || { echo 'fleet-sync-logins: git archive of the source failed (unreadable objects? run it as the login that owns the source)' >&2; exit 3; }
# Never delete what a login keeps beside the tracked files (caches, logs, local
# sockets) — --delete leaves excluded paths alone.
{ cat "$STAGE/tree/.gitignore" 2>/dev/null; printf '%s\n' '__pycache__/' '*.pyc' '.DS_Store' 'fleet.conf' 'fleet.conf.bak*'; } > "$STAGE/exclude"
chmod -R a+rX "$STAGE"

# drift <dir> <entries> → the number of differing paths (diff -rq lines).
drift() {
  _d=$1 _n=0
  for _e in $2; do
    if [ ! -e "$_d/$_e" ] && [ ! -L "$_d/$_e" ]; then _n=$((_n + 1)); continue; fi
    _c=$(diff -rq -x __pycache__ -x '*.pyc' -x .DS_Store -x '*.log' -x '*.sock' \
           "$STAGE/tree/$_e" "$_d/$_e" 2>/dev/null | wc -l | tr -d ' ')
    _n=$((_n + ${_c:-0}))
  done
  printf '%s' "$_n"
}

# relation <sha> → same | behind:<n> | newer   (as seen from the source)
relation() {
  if [ "$1" = "$src_sha" ]; then echo same
  elif gitq "$src" cat-file -e "$1^{commit}" 2>/dev/null \
       && gitq "$src" merge-base --is-ancestor "$1" "$src_sha" 2>/dev/null; then
    echo "behind:$(gitq "$src" rev-list --count "$1..$src_sha")"
  else echo newer
  fi
}

# local_edits <dir> <owner> → tracked files modified in place whose content the source
# repo has never seen (space-separated). A file matching ANY version the source
# knows is an earlier sync's footprint, not work.
local_edits() {
  ogit "$2" "$1" status --porcelain --untracked-files=no 2>/dev/null | while IFS= read -r _l; do
    _f=${_l#???}; _f=${_f#*-> }
    [ -f "$1/$_f" ] || continue
    _b=$(git hash-object --no-filters -- "$1/$_f" 2>/dev/null) || continue
    gitq "$src" cat-file -e "$_b" 2>/dev/null || printf '%s ' "$_f"
  done
}

# --- --to-git helpers (issue #1121) ------------------------------------------
# tracked_at <sha> → a file listing every path the commit tracks (cached per sha)
tracked_at() {
  [ -s "$STAGE/tracked.$1" ] || { gitq "$src" ls-tree -r --name-only "$1" > "$STAGE/tracked.$1"; chmod a+r "$STAGE/tracked.$1"; }
  printf '%s' "$STAGE/tracked.$1"
}
# copy_files <dir> <owner> → every file / symlink under a copy install, relative,
# minus .git, caches and the sync marker — listed as the owner when reachable.
copy_files() {
  ( cd / && if as_owner "$2"; then $SUDO -u "$2" find "$1" \( -name .git -o -name __pycache__ \) -prune -o \( -type f -o -type l \) ! -name '*.pyc' ! -name .DS_Store ! -name '*.sock' -print
    else find "$1" \( -name .git -o -name __pycache__ \) -prune -o \( -type f -o -type l \) ! -name '*.pyc' ! -name .DS_Store ! -name '*.sock' -print; fi ) 2>/dev/null \
    | sed "s|^$1/||" | grep -v -x -e '.fleet-synced-from'
}
# copy_edits <dir> <owner> <sha> → the copy's tracked files whose content the
# source repo has never seen (space-separated): the copy-install twin of
# local_edits. One hash batch + one cat-file batch, not one git call per file.
# A batch that could not hash every file (an unreadable one) names nothing —
# the old copy dir keeps whatever was there either way.
copy_edits() {
  copy_files "$1" "$2" | grep -F -x -f "$(tracked_at "$3")" > "$STAGE/ce.files"
  [ -s "$STAGE/ce.files" ] || return 0
  ( cd "$1" && git hash-object --no-filters --stdin-paths < "$STAGE/ce.files" 2>/dev/null ) > "$STAGE/ce.hashes"
  [ "$(wc -l < "$STAGE/ce.hashes")" -eq "$(wc -l < "$STAGE/ce.files")" ] || return 0
  paste -d' ' "$STAGE/ce.hashes" "$STAGE/ce.files" > "$STAGE/ce.pairs"
  gitq "$src" cat-file --batch-check < "$STAGE/ce.hashes" 2>/dev/null \
    | awk 'NR==FNR { if ($2 == "missing") m[$1] = 1; next } ($1 in m) { printf "%s ", $2 }' - "$STAGE/ce.pairs"
}

# --- discover the other logins ----------------------------------------------
# Pre-pass: is ANY checkout on this machine newer than the source? Then the
# source is demonstrably not the newest install, and a copy install with no
# marker — whose version nobody can tell — is blocked too rather than risk a
# downgrade.
newer_than_src=''
for d in "$homes"/*/.claude/fleet; do
  [ -d "$d" ] || continue
  rd=$(cd "$d" && pwd -P)
  [ "$rd" = "$src" ] && continue
  o=$(ls -ld "$d" | awk '{print $3}'); as_owner "$o" || :
  [ "$(ogit "$o" "$d" rev-parse --show-toplevel 2>/dev/null)" = "$rd" ] || continue
  h=$(ogit "$o" "$d" rev-parse --verify --quiet HEAD 2>/dev/null) || continue
  [ "$(relation "$h")" = newer ] && newer_than_src="$newer_than_src $(basename "$(dirname "$(dirname "$d")")")"
done
newer_than_src=${newer_than_src# }

plan=''  # one line per login: login|dir|owner|shape|head|drift|state|note|entries(,)|to-git target
found=''
for d in "$homes"/*/.claude/fleet; do
  [ -d "$d" ] || continue
  rd=$(cd "$d" && pwd -P)
  [ "$rd" = "$src" ] && continue
  login=$(basename "$(dirname "$(dirname "$d")")")
  found="$found $login"
  if [ -n "$only" ]; then
    case ",$only," in *",$login,"*) ;; *) continue ;; esac
  fi
  owner=$(ls -ld "$d" | awk '{print $3}'); as_owner "$owner" || :
  # a `.git` present is a checkout even when nobody here can read it (issue
  # #1115) — never a copy install, whose empty drift would call it current
  if [ -e "$d/.git" ] || [ "$(ogit "$owner" "$d" rev-parse --show-toplevel 2>/dev/null)" = "$rd" ]; then
    shape=git; ents=$entries
    head=$(ogit "$owner" "$d" rev-parse --verify --quiet HEAD 2>/dev/null)
  else
    shape=copy; ents=''
    for e in $entries; do { [ -e "$d/$e" ] || [ -L "$d/$e" ]; } && ents="$ents $e"; done
    head=$(oread "$owner" "$d/.fleet-synced-from" | awk 'NR==1{print $1}')
  fi
  n=$(drift "$d" "$ents")
  rel=''; [ -n "$head" ] && rel=$(relation "$head")
  edits=''; [ "$shape" = git ] && edits=$(local_edits "$d" "$owner")
  note=''
  if [ "$n" -eq 0 ] && { [ "$shape" = copy ] || [ "$rel" = same ]; } && [ -z "$edits" ]; then
    state=current
  elif [ "$rel" = newer ] && [ "$force" -eq 0 ]; then
    state=blocked; note="its install is NEWER than the source (${head%"${head#???????}"}) — run the sync from $login, or --force"
  elif [ "$shape" = copy ] && [ -z "$head" ] && [ -n "$newer_than_src" ] && [ "$force" -eq 0 ]; then
    state=blocked; note="unversioned copy, and $newer_than_src holds a newer install than the source — run the sync from there, or --force"
  elif [ -n "$edits" ] && [ "$force" -eq 0 ]; then
    state=blocked; note="local edits: ${edits% } — commit/stash them, or --force (the backup keeps them)"
  else
    state=sync
    case "$rel" in behind:*) note="${rel#behind:} commit(s) behind" ;; newer) note="newer than the source — forced" ;; esac
    [ -n "$edits" ] && note="${note:+$note · }local edits overwritten (forced): ${edits% }"
  fi
  # --to-git re-reads the same plan as a conversion: a checkout is skipped, a
  # blocked copy stays blocked (its version is unknown or not in the source), and
  # a convertible copy is checked for work the source has never seen.
  target=''
  if [ "$togit" -eq 1 ]; then
    if [ "$shape" = git ]; then
      state=skip; note='already a git checkout'
    elif [ "$state" != blocked ]; then
      # the commit the clone checks out: the marker's, or the source HEAD for an
      # unmarked copy. A marker the source cannot resolve (a copy synced from a
      # newer login) has no tree to clone; --force takes the source HEAD.
      target=${head:-$src_sha} tnote=''
      if [ -n "$head" ] && [ "$rel" = newer ]; then
        hs=${head%"${head#???????}"}
        if [ "$force" -eq 1 ]; then target=$src_sha; tnote="marker $hs unknown to the source → "
        else state=blocked; note="its marker names $hs, a commit the source does not have — run --to-git from a newer login, or --force (clone at the source HEAD)"; fi
      elif [ -z "$head" ]; then tnote='unversioned copy → '
      fi
      if [ "$state" != blocked ]; then
        cedits=$(copy_edits "$d" "$owner" "$target")
        if [ -n "$cedits" ] && [ "$force" -eq 0 ]; then
          state=blocked; note="local edits: ${cedits% } — --force converts anyway (the old copy dir keeps them)"
        else
          state=to-git; note="${tnote}clone at $(gitq "$src" rev-parse --short "$target") · origin $origin"
          [ -n "$cedits" ] && note="$note · local edits left in the old copy (forced): ${cedits% }"
        fi
      fi
    fi
  fi
  # A login that turned auto-update off is listed and left alone (issue #1122)
  # unless --logins names it or --include-off is given. Decided last, over
  # blocked / sync / current alike: an off login is not this run's to touch,
  # unblock, or count toward the machine's drift.
  if [ "$incoff" -eq 0 ] && [ "$state" != skip ]; then
    case ",$only," in
      *",$login,"*) ;;
      *) if autosync_off "$owner" "$rd" "$(dirname "$(dirname "$d")")"; then
           state=off target=''
           note="auto-update off (FLEET_INSTALL_SYNC=0) — left alone; --logins $login or --include-off syncs it anyway"
         fi ;;
    esac
  fi
  plan="$plan$login|$rd|$owner|$shape|$head|$n|$state|$note|$(echo $ents | tr ' ' ',')|$target
"
done

if [ -n "$only" ]; then
  for want in $(printf '%s' "$only" | tr ',' ' '); do
    case " $found " in *" $want "*) ;; *) printf 'fleet-sync-logins: no install for login %s under %s\n' "$want" "$homes" >&2; exit 2 ;; esac
  done
fi

total=0 ncur=0 ndrift=0 nblock=0 nskipgit=0 noff=0 driftlist=''
while IFS='|' read -r login rd owner shape head n state note ents target; do
  [ -n "$login" ] || continue
  total=$((total + 1))
  case "$state" in
    current) ncur=$((ncur + 1)) ;;
    skip)    nskipgit=$((nskipgit + 1)) ;;
    off)     noff=$((noff + 1)) ;;
    blocked) nblock=$((nblock + 1)); driftlist="$driftlist $login:$n(blocked)" ;;
    *)       ndrift=$((ndrift + 1)); driftlist="$driftlist $login:$n" ;;
  esac
done <<EOF
$plan
EOF

# `· N off` only when some login is off — before `drifted`, so a reader keyed on
# the ` 0 drifted` tail (fleet-install-version.sh) is unchanged either way.
offtail=''; [ "$noff" -gt 0 ] && offtail=" · $noff off"
if [ "$summary" -eq 1 ]; then
  line="$total other · $ncur current$offtail · $ndrift drifted"
  [ "$nblock" -gt 0 ] && line="$line · $nblock blocked"
  [ -n "$driftlist" ] && line="$line (${driftlist# })"
  printf '%s\n' "$line"
  if [ "$nblock" -gt 0 ]; then exit 4; elif [ "$ndrift" -gt 0 ]; then exit 1; else exit 0; fi
fi

say "source:  $src @ $src_short ($src_subject)"
if [ "$total" -eq 0 ]; then
  say "no other login's install under $homes${only:+ matching --logins $only} — nothing to sync"
  exit 0
fi
say "$(printf '%-12s %-5s %-8s %6s  %s' login shape head drift state)"
while IFS='|' read -r login rd owner shape head n state note ents target; do
  [ -n "$login" ] || continue
  hs=${head%"${head#???????}"}
  say "$(printf '%-12s %-5s %-8s %6s  %s%s' "$login" "$shape" "${hs:--}" "$n" "$state" "${note:+ — $note}")"
done <<EOF
$plan
EOF

if [ "$dry" -eq 1 ]; then
  if [ "$togit" -eq 1 ]; then
    say "other logins on this machine: $total · $ndrift to convert · $nskipgit already git checkouts · $nblock blocked$offtail (dry run — nothing changed)"
  else
    say "other logins on this machine: $total · $ncur current · $ndrift to sync · $nblock blocked$offtail (dry run — nothing changed)"
  fi
  if [ "$nblock" -gt 0 ]; then exit 4; elif [ "$ndrift" -gt 0 ]; then exit 1; else exit 0; fi
fi

# --- act ---------------------------------------------------------------------
root_ok() { [ -z "$SUDO" ] || $SUDO true 2>/dev/null; }
bundle_made=0
make_bundle() {
  [ "$bundle_made" -eq 1 ] && return 0
  gitq "$src" bundle create "$STAGE/fleet.bundle" HEAD >/dev/null 2>&1 && chmod a+r "$STAGE/fleet.bundle" && bundle_made=1
}
# kick_daemons <login> <owner> <home> — restart that login's daemons: the
# system-domain com.claude-fleet.<login>.* LaunchDaemons and any gui-domain
# LaunchAgents under its home. Sets kicked / kickfail / spin.
kick_daemons() {
  kicked=0 kickfail=0 spin=0
  for p in "$DAEMON_DIR"/com.claude-fleet."$1".*.plist; do
    [ -f "$p" ] || continue
    label=$(basename "$p" .plist)
    case "$label" in *.spinner) spin=1 ;; esac
    if root_ok && $SUDO $LAUNCHCTL kickstart -k "system/$label" >/dev/null 2>&1; then kicked=$((kicked + 1)); else kickfail=$((kickfail + 1)); fi
  done
  uid=$(id -u "$2" 2>/dev/null)
  for p in "$3"/Library/LaunchAgents/com.claude-fleet.*.plist; do
    [ -f "$p" ] && [ -n "$uid" ] || continue
    label=$(basename "$p" .plist)
    case "$label" in *.spinner) spin=1 ;; esac
    pre=$SUDO; [ "$2" = "$me" ] && pre=''
    if $pre $LAUNCHCTL kickstart -k "gui/$uid/$label" >/dev/null 2>&1; then kicked=$((kicked + 1)); else kickfail=$((kickfail + 1)); fi
  done
}
# spinner_msg <owner> → " · WARN …" unless exactly one tmux-spinner.sh is alive
spinner_msg() {
  spinmsg=''
  [ "$spin" -eq 1 ] && command -v "$PGREP" >/dev/null 2>&1 || return 0
  tries=0 alive=0
  while [ "$tries" -lt 5 ]; do
    alive=$($PGREP -u "$1" -f 'tmux-spinner\.sh' 2>/dev/null | wc -l | tr -d ' ')
    [ "$alive" -eq 1 ] && break
    tries=$((tries + 1)); sleep 1
  done
  [ "$alive" -eq 1 ] || spinmsg=" · WARN $alive tmux-spinner.sh alive (want 1)"
}

# The owner-side half of --to-git: one shell, run AS THE LOGIN, so the clone is
# built with a sane umask and the login's own HOME (sudo -u keeps the caller's
# umask — 077 on macOS — and a clone built under it is unreadable to every other
# login, this script included). Nothing under the copy dir is deleted: a failure
# before the swap removes only the half-built clone; a failed second rename puts
# the copy back.
if [ "$togit" -eq 1 ]; then
  cat > "$STAGE/to-git.sh" <<'EOS'
#!/bin/sh
# to-git.sh <old> <new> <bundle> <target> <branch> <origin> <carry-list> <backup> <mode>
set -u
old=$1 new=$2 bundle=$3 target=$4 branch=$5 origin=$6 carry=$7 bak=$8 mode=$9
umask 022
cd / || exit 1
HOME=$(dirname "$(dirname "$old")"); export HOME
fail() { printf 'to-git: %s\n' "$1" >&2; rm -rf "$new"; exit 1; }
[ -e "$new" ] && fail "$new already exists"
mkdir "$new" && chmod "$mode" "$new" || fail "cannot create $new"
g() { git -c safe.directory='*' -C "$new" "$@"; }
git -c safe.directory='*' init -q "$new" || fail 'git init failed'
g symbolic-ref HEAD "refs/heads/$branch" || fail 'cannot name the branch'
g fetch --quiet "$bundle" HEAD || fail 'fetch from the bundle failed'
g reset -q --hard "$target" || fail "checkout of $target failed"
g remote add origin "$origin" || fail 'cannot set origin'
g config "branch.$branch.remote" origin && g config "branch.$branch.merge" "refs/heads/$branch" || fail 'cannot set upstream'
if [ -s "$carry" ]; then
  rsync -a --files-from="$carry" "$old/" "$new/" || fail 'carrying the local files failed'
fi
mkdir -p "$new/logs"
mv "$old" "$bak" || fail "cannot move $old aside"
mv "$new" "$old" || { mv "$bak" "$old"; rm -rf "$new"; printf 'to-git: cannot move the clone into place; %s restored\n' "$old" >&2; exit 1; }
exit 0
EOS
  chmod a+r "$STAGE/to-git.sh"
fi
# convert_login — --to-git for the login the act loop stands on (its variables).
convert_login() {
  tshort=$(gitq "$src" rev-parse --short "$target")
  ok=1 why='' swapped=0
  make_bundle || { ok=0; why='bundling the source failed'; }
  carry="$STAGE/carry.$login"
  if [ "$ok" -eq 1 ]; then
    copy_files "$rd" "$owner" | grep -v -F -x -f "$(tracked_at "$target")" > "$carry"
    chmod a+r "$carry"
  fi
  new="$home/.claude/fleet.to-git.$$"
  bak="$home/.claude/fleet.copy-$(date +%Y%m%d)"
  i=1 base=$bak
  while [ -e "$bak" ]; do i=$((i + 1)); bak="$base-$i"; done
  # GNU stat FIRST: on GNU `stat -f` is filesystem status and exits 0 with the
  # wrong output; `stat -c` errors cleanly on BSD (see fleet-lib.sh's mtime read)
  mode=$(stat -c %a "$rd" 2>/dev/null || stat -f %Lp "$rd" 2>/dev/null); mode=${mode:-755}
  if [ "$ok" -eq 1 ]; then
    if ( cd / && $as sh "$STAGE/to-git.sh" "$rd" "$new" "$STAGE/fleet.bundle" "$target" "$branch" "$origin" "$carry" "$bak" "$mode" ); then
      swapped=1
    else ok=0; why='the conversion failed before the swap'; fi
  fi
  kicked=0 kickfail=0 spin=0
  [ "$ok" -eq 1 ] && kick_daemons "$login" "$owner" "$home"
  if [ "$ok" -eq 1 ]; then
    [ "$(ogit "$owner" "$rd" rev-parse HEAD 2>/dev/null)" = "$target" ] || { ok=0; why="HEAD is not $tshort"; }
    [ -z "$(ogit "$owner" "$rd" status --porcelain --untracked-files=no 2>/dev/null)" ] || { ok=0; why="${why:+$why · }tracked files dirty"; }
    for f in fleet.conf logs; do
      [ -e "$bak/$f" ] && [ ! -e "$rd/$f" ] && { ok=0; why="${why:+$why · }$f did not carry over"; }
    done
  fi
  spinner_msg "$owner"
  if [ "$ok" -eq 1 ]; then
    nsync=$((nsync + 1))
    kf=''; [ "$kickfail" -gt 0 ] && kf=" ($kickfail not loaded/failed)"
    say "$login: converted to a git checkout @ $tshort · origin $origin · old copy kept at $bak · daemons kicked $kicked$kf$spinmsg"
  else
    nfail=$((nfail + 1))
    if [ "$swapped" -eq 1 ]; then say "$login: FAILED — $why; the old copy is at $bak"
    else say "$login: FAILED — $why; the copy install is untouched"; fi
  fi
}

nsync=0 nskip=$nblock nfail=0 nsudo=0 sudo_cmds=''
while IFS='|' read -r login rd owner shape head n state note ents target <&3; do
  case "$state" in sync|to-git) ;; *) continue ;; esac
  ents=$(printf '%s' "$ents" | tr ',' ' ')
  if [ "$owner" = "$me" ]; then as=''
  elif as_owner "$owner"; then as="$SUDO -u $owner"
  else
    nsudo=$((nsudo + 1)); nskip=$((nskip + 1))
    say "$login: needs sudo — skipped"
    fflag=''; [ "$force" -eq 1 ] && fflag=' --force'
    [ "$togit" -eq 1 ] && fflag="$fflag --to-git --origin $origin"
    sudo_cmds="$sudo_cmds  sudo $SELF --source $src --logins $login$fflag
"
    continue
  fi
  home=$(dirname "$(dirname "$rd")")
  if [ "$togit" -eq 1 ]; then convert_login; continue; fi
  ok=1

  # 1. backup the entries about to change
  bak="$home/.claude/fleet.bak-$(date +%Y%m%d)"
  i=1 base=$bak
  while [ -e "$bak" ]; do i=$((i + 1)); bak="$base-$i"; done
  $as mkdir -p "$bak" || ok=0
  for e in $ents; do
    { [ -e "$rd/$e" ] || [ -L "$rd/$e" ]; } || continue
    $as cp -Rp "$rd/$e" "$bak/" 2>/dev/null || ok=0
  done
  [ -n "$head" ] && printf '%s\n' "$head" | $as tee "$bak/.fleet-prior-head" >/dev/null

  # 2. rsync each tracked entry from the staged HEAD. --checksum, not the
  #    size+mtime quick check: `git archive` stamps every file with the COMMIT
  #    time, so a same-size edit can carry the very mtime the target already
  #    has and be skipped as unchanged.
  if [ "$ok" -eq 1 ]; then
    for e in $ents; do
      if [ -d "$STAGE/tree/$e" ]; then
        $as rsync -a --checksum --delete --exclude-from="$STAGE/exclude" "$STAGE/tree/$e/" "$rd/$e/" || ok=0
      else
        $as rsync -a --checksum "$STAGE/tree/$e" "$rd/$e" || ok=0
      fi
    done
  fi

  # 3. align HEAD (git) / write the marker (copy)
  if [ "$ok" -eq 1 ] && [ "$shape" = git ]; then
    { make_bundle \
      && $as git -c safe.directory='*' -C "$rd" fetch --quiet "$STAGE/fleet.bundle" HEAD \
      && $as git -c safe.directory='*' -C "$rd" reset --quiet "$src_sha"; } || ok=0
  elif [ "$ok" -eq 1 ]; then
    printf '%s %s %s\n' "$src_sha" "$me" "$(date +%Y-%m-%dT%H:%M:%S)" | $as tee "$rd/.fleet-synced-from" >/dev/null || ok=0
  fi

  # 4. restart that login's daemons
  kicked=0 kickfail=0 spin=0
  [ "$ok" -eq 1 ] && kick_daemons "$login" "$owner" "$home"

  # 5. verify
  why=''
  left=$(drift "$rd" "$ents")
  [ "$left" -eq 0 ] || { ok=0; why="$left entr(ies) still differ"; }
  if [ "$shape" = git ]; then
    # as the owner, like the writes above (issue #1115)
    [ "$(ogit "$owner" "$rd" rev-parse HEAD 2>/dev/null)" = "$src_sha" ] || { ok=0; why="${why:+$why · }HEAD is not $src_short"; }
    [ -z "$(ogit "$owner" "$rd" status --porcelain --untracked-files=no 2>/dev/null)" ] || { ok=0; why="${why:+$why · }tracked files dirty"; }
  fi
  [ "$ok" -eq 1 ] || [ -n "$why" ] || why="a sync step failed"
  spinner_msg "$owner"
  if [ "$ok" -eq 1 ]; then
    nsync=$((nsync + 1))
    kf=''; [ "$kickfail" -gt 0 ] && kf=" ($kickfail not loaded/failed)"
    say "$login: synced to $src_short · backup $bak · daemons kicked $kicked$kf$spinmsg"
  else
    nfail=$((nfail + 1))
    say "$login: FAILED — $why; the backup is at $bak"
  fi
done 3<<EOF
$plan
EOF

if [ "$togit" -eq 1 ]; then
  say "other logins on this machine: $nsync converted / $nskip skipped · $nskipgit already git checkouts$offtail"
else
  say "other logins on this machine: $nsync synced / $nskip skipped · $ncur already current$offtail"
fi
if [ -n "$sudo_cmds" ]; then
  say "no passwordless sudo for $nsudo login(s) — run as an admin:"
  printf '%s' "$sudo_cmds"
fi
if [ "$nfail" -gt 0 ]; then exit 6
elif [ "$nsudo" -gt 0 ]; then exit 5
elif [ "$nblock" -gt 0 ]; then exit 4
fi
exit 0
