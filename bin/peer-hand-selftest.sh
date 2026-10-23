#!/bin/bash
# Old Parent semantics are retired; verify zero delivery and preserved history.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-parent-retirement-selftest.py" RetirementTests.test_old_hub_queue_and_receipts_never_become_reminders
