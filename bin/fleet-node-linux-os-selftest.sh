#!/bin/bash
# Real Linux uid/store/proxy integration on an ephemeral GitHub runner (#3022).
# fleet-node-linux.py fleet-node-supervisor.py fleet-credsep.py
# fleet-credsep-launch.py extras/managed-node/smoke.py
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
if [ "${CI:-}" != true ] || [ "$(uname -s)" != Linux ]; then
  echo 'SKIP Linux OS smoke: requires an ephemeral Linux CI runner'
  exit 0
fi
exec sudo -n env CI=true python3 "$BIN/../extras/managed-node/smoke.py"
