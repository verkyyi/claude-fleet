#!/bin/bash
# fleet-login-remove.sh <login> [--keep-home|--delete-home] [--archive-dir <dir>] [--apply]
# Offboard one shared-machine login. Dry run by default; run as an admin login,
# from any directory (issue #1216).
#
# Home policy (EPIC #1212 C5, issue #1217 — #1210 ⑤ is the diagnosis):
#   --keep-home    default. The home is ARCHIVED first — a 600 tar.gz owned by
#                  the admin under --archive-dir (default /Users/Shared/offboarded,
#                  env FLEET_OFFBOARD_ARCHIVE_DIR) — and the login is then deleted
#                  home and all. `sysadminctl -deleteUser -keepHome` is NEVER
#                  passed: on this macOS it answers "'-keepHome' options is not
#                  available on this system", which is how the default offboarding
#                  died on the last test login. The archive path prints last.
#   --delete-home  no archive; the login and its home are deleted outright.
# The copied Claude account pool is removed BEFORE the archive is taken, so the
# shared tokens are never inside it.
# After the login is gone its name AND its GUID are removed from every
# com.apple.access_* group (Remote Login's SSH allow-list, Screen Sharing, …).
# `dseditgroup -d` cannot do that once the user record is gone ("Record was not
# found"); only `dscl . -delete` on the attribute can — without it the name stays
# in the SSH allow-list forever.
set -uo pipefail

PROG=fleet-login-remove
BIN="$(cd "$(dirname "$0")" && pwd)"
usage() { printf 'usage: %s <login> [--keep-home|--delete-home] [--archive-dir <dir>] [--apply]\n' "$PROG" >&2; exit 2; }
die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 2; }
refuse() { printf '%s: refusing %s\n' "$PROG" "$1" >&2; exit 3; }

LOGIN='' APPLY=0 KEEP=1 ARCHIVE_DIR=${FLEET_OFFBOARD_ARCHIVE_DIR:-/Users/Shared/offboarded}
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-home) KEEP=1; shift ;;
    --delete-home) KEEP=0; shift ;;
    --archive-dir) [ $# -ge 2 ] && [ -n "$2" ] || die '--archive-dir needs a directory'; ARCHIVE_DIR=$2; shift 2 ;;
    --archive-dir=*) ARCHIVE_DIR=${1#*=}; [ -n "$ARCHIVE_DIR" ] || die '--archive-dir needs a directory'; shift ;;
    --apply) APPLY=1; shift ;;
    -h|--help) usage ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$LOGIN" ] || usage; LOGIN=$1; shift ;;
  esac
done
[ -n "$LOGIN" ] || usage
printf '%s' "$LOGIN" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$' || die "bad login name '$LOGIN'"
[ "$EUID" != 0 ] || refuse 'running under sudo/root; run as the admin login'
UID_TARGET=$(id -u "$LOGIN" 2>/dev/null) || refuse "unknown login '$LOGIN'"
ADMIN_UID=$(id -u)
[ "$UID_TARGET" != "$ADMIN_UID" ] || refuse "deleting the current login '$LOGIN'"
GROUPS_TARGET=$(id -Gn "$LOGIN" 2>/dev/null) || refuse "cannot read groups for '$LOGIN'"
case " $GROUPS_TARGET " in
  *' admin '*) refuse "deleting admin group member '$LOGIN'" ;;
esac

# Run from / (issue #1216): step 1 runs as the login (`sudo -u`), which inherits
# the cwd and cannot stand in the admin's 0700 home — from ~/projects/… its bash
# died on `getcwd: … Permission denied` before fleet-down ran (the same family as
# fleet-login-new's step 7, #1210 ④). No path argument here; the env/option
# knobs are made absolute first, and $BIN already is.
abs_dir() { case "$1" in /*) printf '%s\n' "$1" ;; *) ( cd -- "$1" 2>/dev/null && pwd -P ) || printf '%s/%s\n' "$PWD" "$1" ;; esac; }
HOMES=$(abs_dir "${FLEET_LOGIN_HOMES:-/Users}")
H="$HOMES/$LOGIN"
DDIR=$(abs_dir "${FLEET_INSTALL_DAEMON_DIR:-/Library/LaunchDaemons}")
ARCHIVE_DIR=$(abs_dir "$ARCHIVE_DIR")
ACCOUNTS="$H/.config/claude-fleet/accounts"
cd / || die 'cannot cd / (every step runs from there; issue #1216)'
[ ! -L "$H" ] || refuse "symlinked home '$H'"
[ ! -L "$H/.config" ] && [ ! -L "$H/.config/claude-fleet" ] || refuse "symlinked config under '$H'"
ARCHIVE=''
if [ "$KEEP" = 1 ]; then
  case "$ARCHIVE_DIR/" in "$H/"*) refuse "archiving '$H' into itself ($ARCHIVE_DIR)" ;; esac
  ARCHIVE="$ARCHIVE_DIR/$LOGIN-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  [ ! -e "$ARCHIVE" ] || refuse "overwriting existing archive '$ARCHIVE'"
fi
if [ "$APPLY" = 1 ]; then
  for cmd in sudo launchctl sysadminctl dscl; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found; nothing changed"
  done
  [ "$KEEP" = 0 ] || command -v tar >/dev/null 2>&1 || die 'tar not found; nothing changed'
fi

# The access-control groups that list this login, read now while the user
# record still exists (its GUID is only readable before sysadminctl deletes it).
# Every com.apple.access_* group is checked, not only com.apple.access_ssh:
# whichever service ACLs the login was granted, none may keep its name.
GUID_TARGET=$(dscl . -read "/Users/$LOGIN" GeneratedUID 2>/dev/null | awk '$1=="GeneratedUID:" {print $2; exit}')
# acl_values <group> <attr>: one value per line (dscl prints them on the attr
# line, or one per indented line when a value holds a space).
acl_values() { dscl . -read "/Groups/$1" "$2" 2>/dev/null | awk -v a="$2:" '$1==a {for (i = 2; i <= NF; i++) print $i; f = 1; next} f && /^ / {print $1; next} {f = 0}'; }
ACL_BY_NAME=() ACL_BY_GUID=()
for g in $(dscl . -list /Groups 2>/dev/null | grep '^com\.apple\.access_' || :); do
  acl_values "$g" GroupMembership | grep -Fxq -- "$LOGIN" && ACL_BY_NAME+=("$g")
  [ -n "$GUID_TARGET" ] && acl_values "$g" GroupMembers | grep -Fxq -- "$GUID_TARGET" && ACL_BY_GUID+=("$g")
done

show() { local q; q=$(printf '%q ' "$@"); printf '  $ %s\n' "${q% }"; }
run() { show "$@"; [ "$APPLY" = 1 ] || return 0; "$@" || { printf '%s: failed; stopped before deleting the login\n' "$PROG" >&2; exit 1; }; }
# run_post: a step after the login is gone cannot stop before deleting it —
# report what is left to finish by hand, keep going, exit 1 at the end.
LEFT=0
run_post() { show "$@"; [ "$APPLY" = 1 ] || return 0; "$@" || { printf '%s: failed after the login was deleted; finish by hand:\n' "$PROG" >&2; show "$@" >&2; LEFT=1; }; }
step() { printf '\n[%s] %s\n' "$1" "$2"; }

if [ "$APPLY" = 1 ]; then
  printf '%s: removing login %s (uid %s)\n' "$PROG" "$LOGIN" "$UID_TARGET"
else
  printf '%s: DRY RUN — no change; re-run with --apply\n' "$PROG"
fi
printf '  home=%s  home-policy=%s\n' "$H" "$([ "$KEEP" = 1 ] && echo "archive → $ARCHIVE, then delete" || echo delete)"

# Do this under the target login so fleet-down uses that login's conf and socket.
# fleet_sockets lists only live, configured fleet servers. Capture the list before
# stopping one; the last fleet-down disarms that login's crash restore.
step 1 "stop $LOGIN's live fleet"
# shellcheck disable=SC2016 # $1/$2 are expanded by the target login's bash.
show sudo -u "$LOGIN" -H env "HOME=$H" "FLEET_CONF_DIR=$H/.config/claude-fleet" bash -c 'source "$1"; while IFS= read -r sess; do [ -n "$sess" ] || continue; bash "$2" "$sess" || exit; done < <(fleet_sockets)' _ "$BIN/fleet-lib.sh" "$BIN/fleet-down.sh"
if [ "$APPLY" = 1 ]; then
  sudo -u "$LOGIN" -H env "HOME=$H" "FLEET_CONF_DIR=$H/.config/claude-fleet" bash -c 'source "$1"; while IFS= read -r sess; do [ -n "$sess" ] || continue; bash "$2" "$sess" || exit; done < <(fleet_sockets)' _ "$BIN/fleet-lib.sh" "$BIN/fleet-down.sh" || exit 1
fi

# System shape belongs to this login by label. GUI shape belongs to the login's
# private LaunchAgents directory, where its fleet labels do not include login.
step 2 'boot out and remove fleet/ccquota services'
for plist in "$DDIR"/com.claude-fleet."$LOGIN".*.plist \
             "$H"/Library/LaunchAgents/com.claude-fleet.*.plist \
             "$H"/Library/LaunchAgents/com.ccquota.agent*.plist; do
  [ -f "$plist" ] || continue
  case "$plist" in
    "$DDIR"/*) domain=system ;;
    *) domain="gui/$UID_TARGET" ;;
  esac
  show sudo launchctl bootout "$domain" "$plist"
  if [ "$APPLY" = 1 ]; then
    # An installed plist need not still be loaded (for example, no GUI login).
    # If bootout fails, refuse to remove a service that is still registered.
    label=${plist##*/}; label=${label%.plist}
    if ! sudo launchctl bootout "$domain" "$plist"; then
      sudo launchctl print "$domain/$label" >/dev/null 2>&1 && {
        printf '%s: %s remains loaded; stopped\n' "$PROG" "$label" >&2; exit 1;
      }
    fi
  fi
  run sudo rm -f "$plist"
done

step 3 'remove the copied Claude account pool'
run sudo rm -rf "$ACCOUNTS"

step 4 'stop remaining processes owned by the login'
show sudo pkill -TERM -U "$UID_TARGET"
if [ "$APPLY" = 1 ]; then
  sudo pkill -TERM -U "$UID_TARGET" 2>/dev/null || : # no processes is normal
  sleep 1
  if pgrep -U "$UID_TARGET" >/dev/null 2>&1; then
    show sudo pkill -KILL -U "$UID_TARGET"
    sudo pkill -KILL -U "$UID_TARGET" 2>/dev/null || :
    sleep 1
  fi
  pgrep -U "$UID_TARGET" >/dev/null 2>&1 && {
    printf '%s: processes still run as uid %s; stopped before deleting login\n' "$PROG" "$UID_TARGET" >&2; exit 1;
  }
fi

# The home is quiet now (pool removed, processes gone): archive it as root — the
# admin cannot read a 0700 home — into a dir only the admin can enter, then hand
# the archive to the admin at 600. A failed archive stops BEFORE the login goes.
step 5 "archive $LOGIN's home"
if [ "$KEEP" = 0 ]; then
  printf '  (skipped: --delete-home)\n'
elif [ ! -d "$H" ]; then
  printf '  (skipped: no home directory at %s)\n' "$H"
  ARCHIVE=''
else
  run sudo install -d -m 700 -o "$ADMIN_UID" "$ARCHIVE_DIR"
  run sudo tar -czf "$ARCHIVE" -C "$HOMES" "$LOGIN"
  run sudo chown "$ADMIN_UID" "$ARCHIVE"
  run sudo chmod 600 "$ARCHIVE"
fi

step 6 'delete the OS login (and its home)'
run sudo sysadminctl -deleteUser "$LOGIN"
if [ "$APPLY" = 1 ] && [ -d "$H" ]; then
  printf '%s: WARN home still present after deleteUser: %s — remove it by hand once you have what you need\n' "$PROG" "$H" >&2
fi

step 7 "remove $LOGIN from the com.apple.access_* service groups"
if [ "${#ACL_BY_NAME[@]}" = 0 ] && [ "${#ACL_BY_GUID[@]}" = 0 ]; then
  printf '  (no com.apple.access_* group lists %s)\n' "$LOGIN"
fi
for g in ${ACL_BY_NAME[@]+"${ACL_BY_NAME[@]}"}; do
  run_post sudo dscl . -delete "/Groups/$g" GroupMembership "$LOGIN"
done
for g in ${ACL_BY_GUID[@]+"${ACL_BY_GUID[@]}"}; do
  run_post sudo dscl . -delete "/Groups/$g" GroupMembers "$GUID_TARGET"
done

printf '\n'
if [ "$APPLY" = 1 ]; then
  if [ "$LEFT" = 1 ]; then
    printf '%s: login %s deleted, but a step after it failed (above)\n' "$PROG" "$LOGIN"
  else
    printf '%s: done\n' "$PROG"
  fi
else
  printf '%s: dry run complete\n' "$PROG"
fi
if [ -n "$ARCHIVE" ]; then
  size=''
  [ "$APPLY" = 1 ] && size=" ($(du -h "$ARCHIVE" 2>/dev/null | awk '{print $1}'))"
  printf '  archive=%s%s  (600, owned by uid %s; --delete-home skips it)\n' "$ARCHIVE" "$size" "$ADMIN_UID"
fi
[ "$LEFT" = 0 ] || exit 1
exit 0
