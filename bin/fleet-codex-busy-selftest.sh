#!/bin/bash
# selftest-deps: fleet_launch.py fleet_pending_tool.py
# Exact Codex MCP/helper classification and reap gate (issue #4318).
# bin/fleet_worker_life.py bin/fleet_agent_mcp.py bin/fleet-lib.sh
set -eu
BIN=$(cd "$(dirname "$0")" && pwd)
exec python3 "$BIN/fleet-codex-busy-selftest.py" "$BIN" "$@"
