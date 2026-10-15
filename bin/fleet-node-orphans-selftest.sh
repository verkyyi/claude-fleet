#!/bin/bash
# #3135: isolated supervisor/core restarts and whole-group cleanup.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 -W ignore::ResourceWarning "$BIN/fleet-node-orphans-selftest.py" "$@"
