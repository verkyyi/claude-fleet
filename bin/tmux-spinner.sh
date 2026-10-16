#!/bin/sh
# Config remains shell syntax; export its values before replacing this PID with
# the existing spinner loop. No sidecar daemon or per-deadline helper process.
set -u
BIN=$(CDPATH='' cd -- "${0%/*}" && pwd)
set -a
[ ! -f "$BIN/../fleet.conf" ] || . "$BIN/../fleet.conf"
# fleet-handoff-invariant.sh reads these same defaults. Export them to the loop
# so its worst-case bound and the runtime cannot drift.
STUCK_SECS="${FLEET_STUCK_WORKING_SECS:-120}"
STUCK_CHECK_SECS=10
export STUCK_SECS STUCK_CHECK_SECS
set +a
# shellcheck disable=SC3045
printf 'tmux-spinner: nofile=%s\n' "$(ulimit -n 2>/dev/null || echo '?')" >&2
exec python3 "$BIN/tmux-spinner.py" "$@"
