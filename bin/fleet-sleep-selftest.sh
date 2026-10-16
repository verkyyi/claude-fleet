#!/bin/bash
set -eu
BIN=$(cd "$(dirname "$0")" && pwd)
SELFTEST_PART=${SELFTEST_PART:-1/3} exec python3 "$BIN/fleet-sleep-selftest.py" "$BIN" "$@"
