#!/bin/bash
set -eu
BIN=$(cd "$(dirname "$0")" && pwd)
exec python3 "$BIN/fleet-sleep-selftest.py" "$BIN"
