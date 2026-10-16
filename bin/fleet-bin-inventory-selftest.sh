#!/bin/bash
set -eu
BIN="$(cd "$(dirname "$0")" && pwd)"
# COMPONENTS.md owns the mapping; this wrapper makes the embedded fixtures a CI test.
python3 "$BIN/fleet-bin-inventory.py" --selftest
python3 "$BIN/fleet-bin-inventory.py" --summary
