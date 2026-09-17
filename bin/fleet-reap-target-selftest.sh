#!/bin/bash
set -uo pipefail
BIN=$(cd "$(dirname "$0")" && pwd)
exec python3 "$BIN/fleet-reap-target-selftest.py" "$BIN"
