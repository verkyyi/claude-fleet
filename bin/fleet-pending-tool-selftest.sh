#!/bin/bash
# selftest-deps: fleet_pending_tool.py fleet-pending-tool.sh fleet-lib.sh fleet_launch.py fleet_runtime.py fleet_sleep_argv.py
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-pending-tool-selftest.py" "$@"
