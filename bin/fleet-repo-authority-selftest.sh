#!/bin/bash
# Per-repo authority manifest/cutover: bin/fleet_repo_authority.py,
# bin/fleet-repo.sh, bin/fleet-lib.sh, bin/fleet_ticket.py,
# bin/dash-issue-session.sh, bin/dash-raw-session.sh, bin/fleet_task_control.py.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
python3 "$BIN/fleet_repo_authority_test.py"
