#!/bin/sh
# bin/fleet-cred-proxy.py bin/fleet-credsep-launch.py bin/fleet-node-linux.py
# extras/managed-node/render.py deploy/k8s/egress/base/fleet-egress.py
set -eu
TASK_BIN=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
python3 "$TASK_BIN/fleet-anthropic-egress-selftest.py"
python3 -I "$TASK_BIN/../deploy/k8s/egress/base/fleet-egress.py" --selftest
