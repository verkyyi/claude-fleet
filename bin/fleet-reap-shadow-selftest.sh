#!/bin/bash
# selftest-deps: fleet_reap_shadow.py fleet_reap_shadow_local.py fleet_runtime.py fleet_pending_tool.py fleet_task_control.py fleet_reap_policy.py fleet-cleanup-idle.py fleet-cleanup.sh fleet_worker_life.py fleet-input.py fleet_task_recovery.py fleet-lib.sh
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$BIN/fleet-reap-shadow-selftest.py" "$@"
