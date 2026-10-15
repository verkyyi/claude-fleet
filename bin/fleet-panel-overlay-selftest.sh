#!/bin/bash
# bin/fleet_view.py · bin/fleet_panel.py · bin/fleet-quickopen.py
# State/input regression plus real curses on an isolated tmux PTY. No Fleet calls.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-panel-overlay-selftest.py"
