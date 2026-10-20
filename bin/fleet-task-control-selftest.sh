#!/bin/bash
# A task record read from a machine — children / await / closed / cancel — and a
# child report routed to its parent's ID: bin/fleet_task_control.py,
# bin/fleet-children.sh, bin/fleet-await.sh, bin/fleet-hub-node.sh,
# bin/fleet-task-record.sh.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
python3 "$BIN/fleet_task_control_test.py"
