#!/bin/bash
# bin/fleet_view.py · bin/fleet_panel.py · bin/fleet-quickopen.py
# bin/fleet_status_evidence.py · bin/fleet_runtime.py · bin/fleet_reap_shadow.py
# State/input regression plus real curses on an isolated tmux PTY. No Fleet calls.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-panel-overlay-selftest.py"
