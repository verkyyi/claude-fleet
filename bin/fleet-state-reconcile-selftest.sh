#!/bin/bash
set -eu
BIN=$(cd "$(dirname "$0")" && pwd)
exec python3 "$BIN/fleet-state-reconcile-selftest.py" "$BIN"
