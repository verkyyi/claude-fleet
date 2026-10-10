#!/bin/bash
# Linux/container managed lifecycle contracts (#3022).
# fleet-node-supervisor.py fleet-node-update.py fleet-node-install.sh
# fleet-node-linux.py fleet-credsep.py extras/managed-node/render.py
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-node-linux-selftest.py"
