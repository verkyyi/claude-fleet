#!/bin/bash
# Original part 4/4, group 5/5: the complete missing-transcript/failed-ledger case (#3884, #4637).
# selftest-part-of: fleet-cleanup-idle-selftest.sh
BIN="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -eq 0 ]; then
  set -- RoundTrip.test_missing_transcript_and_failed_ledger_do_not_close
fi
SELFTEST_PART=4/4 exec bash "$BIN/fleet-cleanup-idle-selftest.sh" "$@"
