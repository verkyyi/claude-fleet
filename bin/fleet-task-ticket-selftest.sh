#!/bin/bash
# bin/fleet-task-record.sh bin/fleet-issue-file.sh bin/fleet-ticket.sh
# bin/fleet_task_ticket.py retain accepted dispatch/filing receipts.
# bin/fleet-gh-lib.sh bin/fleet_ticket.py keep one send and bounded reconciliation.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
python3 "$BIN/fleet_task_ticket_test.py"
