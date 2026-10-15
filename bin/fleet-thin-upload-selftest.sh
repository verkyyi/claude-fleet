#!/bin/bash
# Slow capture/transfer, ordering, cancellation and lifetime on isolated PTYs.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-thin-upload-selftest.py" "$@"
