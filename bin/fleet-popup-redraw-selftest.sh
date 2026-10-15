#!/bin/bash
# Real terminal regression for bin/fleet-quickopen.py Heal + bin/fleet_view.py,
# through bin/dash-popup.sh and bin/fleet-popup-lib.sh (issue #4410).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v tmux >/dev/null || { echo 'SKIP: tmux absent'; exit 0; }
exec python3 "$BIN/fleet-popup-redraw-selftest.py" "$@"
