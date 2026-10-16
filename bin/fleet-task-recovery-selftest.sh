#!/bin/bash
# bin/fleet_task_recovery.py, bin/fleet_task_control.py, bin/fleet_launch.py,
# bin/fleet-task-record.sh, bin/fleet-hub-node.sh reuse the operation journal.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
python3 "$BIN/fleet_task_recovery_test.py"
