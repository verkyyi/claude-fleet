#!/bin/bash
# Task-authoritative children/await/report: bin/fleet_task_control.py,
# bin/fleet-children.sh, bin/fleet-await.sh, bin/fleet-report-parent.sh,
# bin/fleet-hub-node.sh, bin/fleet_launch.py, bin/fleet-task-record.sh.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
python3 "$BIN/fleet_task_control_test.py"
