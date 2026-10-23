#!/bin/bash
# Old Parent semantics are retired; verify zero delivery and preserved history.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-parent-retirement-selftest.py" RetirementTests.test_old_queue_payload_preserved_and_failed_once RetirementTests.test_new_report_put_fails_and_preserves_full_words RetirementTests.test_message_queue_still_delivers_through_existing_adapter
