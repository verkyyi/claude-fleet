#!/bin/bash
# Drives bin/hub-sessions-watch-selftest.py, bin/fleet-hub-sessions.sh,
# bin/fleet-render-watch.py, bin/fleet_view.py and bin/tmux-spinner.py.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/hub-sessions-watch-selftest.py" "$@"
