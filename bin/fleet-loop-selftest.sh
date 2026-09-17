#!/bin/bash
# Isolated loop/controller tests; no real agents or model requests.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-loop-selftest.py"
