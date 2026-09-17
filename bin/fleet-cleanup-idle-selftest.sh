#!/bin/bash
set -eu
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-cleanup-idle-selftest.py" "$BIN"
