#!/bin/bash
# Real same-second/reaped-worker idle guard regression, on isolated sockets.
# selftest-part-of: fleet-idle-cost-selftest.sh
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v tmux >/dev/null 2>&1 || { echo 'SKIP: no tmux'; exit 0; }
exec python3 "$BIN/../tests/idle-cost/edges.py"
