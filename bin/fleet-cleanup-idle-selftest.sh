#!/bin/bash
set -eu
BIN="$(cd "$(dirname "$0")" && pwd)"
SELFTEST_PART=${SELFTEST_PART:-1/4} exec python3 "$BIN/fleet-cleanup-idle-selftest.py" "$BIN" "$@"
