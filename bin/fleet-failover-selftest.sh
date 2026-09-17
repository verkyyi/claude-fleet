#!/bin/bash
# Isolated policy/state tests; no live tmux or provider calls.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-failover-selftest.py"
