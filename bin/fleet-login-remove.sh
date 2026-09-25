#!/bin/bash
# fleet-login-remove.sh <login> [--keep-home|--delete-home] [--apply]
# Offboard one shared-machine login. Dry run by default; run as an admin login.
# --keep-home is the default (EPIC #1190). --delete-home is explicit.
set -uo pipefail

PROG=fleet-login-remove
BIN="$(cd "$(dirname "$0")" && pwd)"
usage() { printf 'usage: %s <login> [--keep-home|--delete-home] [--apply]\n' "$PROG" >&2; exit 2; }
die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 2; }
refuse() { printf '%s: refusing %s\n' "$PROG" "$1" >&2; exit 3; }

LOGIN='' APPLY=0 KEEP=1
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-home) KEEP=1; shift ;;
    --delete-home) KEEP=0; shift ;;
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
[ "$UID_TARGET" != "$(id -u)" ] || refuse "deleting the current login '$LOGIN'"
GROUPS_TARGET=$(id -Gn "$LOGIN" 2>/dev/null) || refuse "cannot read groups for '$LOGIN'"
case " $GROUPS_TARGET " in
  *' admin '*) refuse "deleting admin group member '$LOGIN'" ;;
esac

HOMES=${FLEET_LOGIN_HOMES:-/Users}
H="$HOMES/$LOGIN"
DDIR=${FLEET_INSTALL_DAEMON_DIR:-/Library/LaunchDaemons}
ACCOUNTS="$H/.config/claude-fleet/accounts"
[ ! -L "$H" ] || refuse "symlinked home '$H'"
[ ! -L "$H/.config" ] && [ ! -L "$H/.config/claude-fleet" ] || refuse "symlinked config under '$H'"
if [ "$APPLY" = 1 ]; then
  for cmd in sudo launchctl sysadminctl; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found; nothing changed"
  done
fi

show() { local q; q=$(printf '%q ' "$@"); printf '  $ %s\n' "${q% }"; }
run() { show "$@"; [ "$APPLY" = 1 ] || return 0; "$@" || { printf '%s: failed; stopped before deleting the login\n' "$PROG" >&2; exit 1; }; }
step() { printf '\n[%s] %s\n' "$1" "$2"; }

if [ "$APPLY" = 1 ]; then
  printf '%s: removing login %s (uid %s)\n' "$PROG" "$LOGIN" "$UID_TARGET"
else
  printf '%s: DRY RUN — no change; re-run with --apply\n' "$PROG"
fi
printf '  home=%s  home-policy=%s\n' "$H" "$([ "$KEEP" = 1 ] && echo keep || echo delete)"

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

step 5 'delete the OS login'
if [ "$KEEP" = 1 ]; then
  run sudo sysadminctl -deleteUser "$LOGIN" -keepHome
else
  run sudo sysadminctl -deleteUser "$LOGIN"
fi
if [ "$APPLY" = 1 ]; then
  printf '%s: done\n' "$PROG"
else
  printf '%s: dry run complete\n' "$PROG"
fi
