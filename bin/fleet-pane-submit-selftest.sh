#!/bin/bash
# selftest-deps: fleet-pane-submit.sh fleet-pane-submit.py fleet-input.py
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-pane-submit-selftest.py"
