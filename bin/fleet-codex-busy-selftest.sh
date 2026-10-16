#!/bin/bash
# Exact Codex MCP/helper classification and reap gate (issue #4318).
# bin/fleet-sleep.py bin/fleet_sleep_mcp.py bin/fleet-lib.sh
set -eu
BIN=$(cd "$(dirname "$0")" && pwd)
exec python3 "$BIN/fleet-codex-busy-selftest.py" "$BIN" "$@"
