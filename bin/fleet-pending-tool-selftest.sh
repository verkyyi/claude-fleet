#!/bin/bash
# selftest-deps: fleet_pending_tool.py fleet-pending-tool.sh fleet-lib.sh fleet_native_proc.py fleet_agent_argv.py
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-pending-tool-selftest.py" "$@"
