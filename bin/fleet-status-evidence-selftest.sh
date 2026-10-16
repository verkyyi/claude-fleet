#!/bin/bash
# bin/fleet_status_evidence.py bin/fleet_runtime.py bin/fleet_reap_shadow.py
# bin/fleet-status-evidence-selftest.py bin/tmux-dashboard-rows.sh bin/fleet_view.py
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
python3 "$BIN/fleet-status-evidence-selftest.py"
