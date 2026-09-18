#!/bin/bash
# Worker hibernation. Explicit session/socket; no default-server discovery.
set -uo pipefail
BIN=$(cd "$(dirname "$0")" && pwd)
. "$BIN/fleet-lib.sh"
action=${1:-status}; shift || :
session=${1:-$(fleet_current_session)}; [ $# -eq 0 ] || shift
[ -n "$session" ] || { echo 'usage: fleet-sleep.sh action session [window] [--dry-run]' >&2; exit 2; }
fleet_load_conf "$session"
export FLEET_CONF_DIR FLEET_MAIN
export FLEET_SLEEP="${FLEET_SLEEP:-observe}"
export FLEET_SLEEP_AFTER="${FLEET_SLEEP_AFTER:-1800}"
exec python3 "$BIN/fleet-sleep.py" "$action" --session "$session" "$@"
