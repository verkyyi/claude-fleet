#!/bin/bash
# Read-only liveness probes; the optional tmux server uses its own named socket.
set -eu
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-reap-live-selftest.py" "$BIN"
