#!/bin/bash
# fleet-worker-life-selftest.sh — bin/fleet_worker_life.py (T545, EPIC T542 C7):
# the life module, the renamed bin/fleet_agent_argv.py · bin/fleet_agent_mcp.py,
# and the one-version forwards bin/fleet-sleep.py · bin/fleet_sleep_argv.py ·
# bin/fleet_sleep_mcp.py keep.
set -eu
BIN=$(cd "$(dirname "$0")" && pwd)
exec python3 "$BIN/fleet-worker-life-selftest.py" "$BIN" "$@"
