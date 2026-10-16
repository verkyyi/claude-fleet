#!/bin/bash
# selftest-deps: fleet_reap_shadow.py fleet_runtime.py fleet_pending_tool.py fleet_task_control.py fleet_reap_policy.py
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$BIN/fleet-reap-shadow-selftest.py" "$@"
