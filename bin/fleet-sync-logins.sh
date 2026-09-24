#!/bin/bash
# fleet-sync-logins.sh [--dry-run] [--logins a,b] [--force] [--source <dir>]
#                      [--homes <dir>] [--summary]
#   — keep every login's ~/.claude/fleet on ONE machine at the same commit
#     (issue #1069).
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
#
# Exit status is the reason, worst first:
#   6  a sync or its verification failed for at least one login
#   5  at least one login needs sudo — the commands to run are printed
#   4  at least one login is blocked (local edits / newer than the source)
#   3  the source is unusable (not a git checkout)
#   2  usage error (bad flag, --logins names no install)
#   1  --dry-run only: drift found
#   0  every selected login is at the source commit
#
# --summary prints ONE line (`4 other · 1 current · 3 drifted (…)`) and nothing
# else; it implies --dry-run. `fleet-install-version.sh` reads it for its
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
dry=0 force=0 only='' summary=0

usage() { sed -n '2,70p' "$SELF" | sed 's/^# \{0,1\}//'; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|-n) dry=1 ;;
    --force)      force=1 ;;
    --summary)    summary=1; dry=1 ;;
    --logins)     shift; only="${1:-}" ;;
    --logins=*)   only="${1#--logins=}" ;;
    --source)     shift; src="${1:-}" ;;
    --homes)      shift; homes="${1:-}" ;;
    -h|--help)    usage; exit 0 ;;
    *) printf 'fleet-sync-logins: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

me="${FLEET_SYNC_LOGINS_ME:-$(id -un)}"
PGREP="${FLEET_SYNC_LOGINS_PGREP:-pgrep}"
say() { [ "$summary" -eq 1 ] || printf '%s\n' "$*"; }
# git on another login's checkout trips "dubious ownership"; a command-line
# safe.directory is honoured, and scoping it to one call keeps it off disk.
gitq() { git -c safe.directory='*' -C "$@"; }

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

# local_edits <dir> → tracked files modified in place whose content the source
# repo has never seen (space-separated). A file matching ANY version the source
# knows is an earlier sync's footprint, not work.
local_edits() {
  gitq "$1" status --porcelain --untracked-files=no 2>/dev/null | while IFS= read -r _l; do
    _f=${_l#???}; _f=${_f#*-> }
    [ -f "$1/$_f" ] || continue
    _b=$(git hash-object --no-filters -- "$1/$_f" 2>/dev/null) || continue
    gitq "$src" cat-file -e "$_b" 2>/dev/null || printf '%s ' "$_f"
  done
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
  [ "$(gitq "$d" rev-parse --show-toplevel 2>/dev/null)" = "$rd" ] || continue
  h=$(gitq "$d" rev-parse --verify --quiet HEAD 2>/dev/null) || continue
  [ "$(relation "$h")" = newer ] && newer_than_src="$newer_than_src $(basename "$(dirname "$(dirname "$d")")")"
done
newer_than_src=${newer_than_src# }

plan=''  # one line per login: login|dir|owner|shape|head|drift|state|note|entries(,)
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
  owner=$(ls -ld "$d" | awk '{print $3}')
  if [ "$(gitq "$d" rev-parse --show-toplevel 2>/dev/null)" = "$rd" ]; then
    shape=git; ents=$entries
    head=$(gitq "$d" rev-parse --verify --quiet HEAD 2>/dev/null)
  else
    shape=copy; ents=''
    for e in $entries; do { [ -e "$d/$e" ] || [ -L "$d/$e" ]; } && ents="$ents $e"; done
    head=$(awk 'NR==1{print $1}' "$d/.fleet-synced-from" 2>/dev/null)
  fi
  n=$(drift "$d" "$ents")
  rel=''; [ -n "$head" ] && rel=$(relation "$head")
  edits=''; [ "$shape" = git ] && edits=$(local_edits "$d")
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
  plan="$plan$login|$rd|$owner|$shape|$head|$n|$state|$note|$(echo $ents | tr ' ' ',')
"
done

if [ -n "$only" ]; then
  for want in $(printf '%s' "$only" | tr ',' ' '); do
    case " $found " in *" $want "*) ;; *) printf 'fleet-sync-logins: no install for login %s under %s\n' "$want" "$homes" >&2; exit 2 ;; esac
  done
fi

total=0 ncur=0 ndrift=0 nblock=0 driftlist=''
while IFS='|' read -r login rd owner shape head n state note ents; do
  [ -n "$login" ] || continue
  total=$((total + 1))
  case "$state" in
    current) ncur=$((ncur + 1)) ;;
    blocked) nblock=$((nblock + 1)); driftlist="$driftlist $login:$n(blocked)" ;;
    *)       ndrift=$((ndrift + 1)); driftlist="$driftlist $login:$n" ;;
  esac
done <<EOF
$plan
EOF

if [ "$summary" -eq 1 ]; then
  line="$total other · $ncur current · $ndrift drifted"
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
while IFS='|' read -r login rd owner shape head n state note ents; do
  [ -n "$login" ] || continue
  hs=${head%"${head#???????}"}
  say "$(printf '%-12s %-5s %-8s %6s  %s%s' "$login" "$shape" "${hs:--}" "$n" "$state" "${note:+ — $note}")"
done <<EOF
$plan
EOF

if [ "$dry" -eq 1 ]; then
  say "other logins on this machine: $total · $ncur current · $ndrift to sync · $nblock blocked (dry run — nothing changed)"
  if [ "$nblock" -gt 0 ]; then exit 4; elif [ "$ndrift" -gt 0 ]; then exit 1; else exit 0; fi
fi

# --- act ---------------------------------------------------------------------
root_ok() { [ -z "$SUDO" ] || $SUDO true 2>/dev/null; }
bundle_made=0
nsync=0 nskip=$nblock nfail=0 nsudo=0 sudo_cmds=''
while IFS='|' read -r login rd owner shape head n state note ents <&3; do
  [ "$state" = sync ] || continue
  ents=$(printf '%s' "$ents" | tr ',' ' ')
  if [ "$owner" = "$me" ]; then as=''
  elif [ -n "$SUDO" ] && $SUDO -u "$owner" true 2>/dev/null; then as="$SUDO -u $owner"
  else
    nsudo=$((nsudo + 1)); nskip=$((nskip + 1))
    say "$login: needs sudo — skipped"
    fflag=''; [ "$force" -eq 1 ] && fflag=' --force'
    sudo_cmds="$sudo_cmds  sudo $SELF --source $src --logins $login$fflag
"
    continue
  fi
  home=$(dirname "$(dirname "$rd")")
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
    if [ "$bundle_made" -eq 0 ]; then
      gitq "$src" bundle create "$STAGE/fleet.bundle" HEAD >/dev/null 2>&1 && chmod a+r "$STAGE/fleet.bundle" && bundle_made=1
    fi
    { [ "$bundle_made" -eq 1 ] \
      && $as git -c safe.directory='*' -C "$rd" fetch --quiet "$STAGE/fleet.bundle" HEAD \
      && $as git -c safe.directory='*' -C "$rd" reset --quiet "$src_sha"; } || ok=0
  elif [ "$ok" -eq 1 ]; then
    printf '%s %s %s\n' "$src_sha" "$me" "$(date +%Y-%m-%dT%H:%M:%S)" | $as tee "$rd/.fleet-synced-from" >/dev/null || ok=0
  fi

  # 4. restart that login's daemons
  kicked=0 kickfail=0 spin=0
  if [ "$ok" -eq 1 ]; then
    for p in "$DAEMON_DIR"/com.claude-fleet."$login".*.plist; do
      [ -f "$p" ] || continue
      label=$(basename "$p" .plist)
      case "$label" in *.spinner) spin=1 ;; esac
      if root_ok && $SUDO $LAUNCHCTL kickstart -k "system/$label" >/dev/null 2>&1; then kicked=$((kicked + 1)); else kickfail=$((kickfail + 1)); fi
    done
    uid=$(id -u "$owner" 2>/dev/null)
    for p in "$home"/Library/LaunchAgents/com.claude-fleet.*.plist; do
      [ -f "$p" ] && [ -n "$uid" ] || continue
      label=$(basename "$p" .plist)
      case "$label" in *.spinner) spin=1 ;; esac
      pre=$SUDO; [ "$owner" = "$me" ] && pre=''
      if $pre $LAUNCHCTL kickstart -k "gui/$uid/$label" >/dev/null 2>&1; then kicked=$((kicked + 1)); else kickfail=$((kickfail + 1)); fi
    done
  fi

  # 5. verify
  left=$(drift "$rd" "$ents")
  [ "$left" -eq 0 ] || ok=0
  if [ "$shape" = git ]; then
    [ "$(gitq "$rd" rev-parse HEAD 2>/dev/null)" = "$src_sha" ] || ok=0
    [ -z "$(gitq "$rd" status --porcelain --untracked-files=no 2>/dev/null)" ] || ok=0
  fi
  spinmsg=''
  if [ "$spin" -eq 1 ] && command -v "$PGREP" >/dev/null 2>&1; then
    tries=0 alive=0
    while [ "$tries" -lt 5 ]; do
      alive=$($PGREP -u "$owner" -f 'tmux-spinner\.sh' 2>/dev/null | wc -l | tr -d ' ')
      [ "$alive" -eq 1 ] && break
      tries=$((tries + 1)); sleep 1
    done
    [ "$alive" -eq 1 ] || spinmsg=" · WARN $alive tmux-spinner.sh alive (want 1)"
  fi
  if [ "$ok" -eq 1 ]; then
    nsync=$((nsync + 1))
    kf=''; [ "$kickfail" -gt 0 ] && kf=" ($kickfail not loaded/failed)"
    say "$login: synced to $src_short · backup $bak · daemons kicked $kicked$kf$spinmsg"
  else
    nfail=$((nfail + 1))
    say "$login: FAILED — $left entr(ies) still differ; the backup is at $bak"
  fi
done 3<<EOF
$plan
EOF

say "other logins on this machine: $nsync synced / $nskip skipped · $ncur already current"
if [ -n "$sudo_cmds" ]; then
  say "no passwordless sudo for $nsudo login(s) — run as an admin:"
  printf '%s' "$sudo_cmds"
fi
if [ "$nfail" -gt 0 ]; then exit 6
elif [ "$nsudo" -gt 0 ]; then exit 5
elif [ "$nblock" -gt 0 ]; then exit 4
fi
exit 0
