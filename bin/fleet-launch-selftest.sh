#!/bin/bash
# selftest-deps: fleet_launch.py fleet_control.py fleet-codex-session.py fleet-session-wrap.sh
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$BIN/fleet-launch-selftest.py"
