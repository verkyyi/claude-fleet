#!/bin/bash
# Original part 4/4, group 4/5: the complete dirty/active/loop/PR refusal case.
# selftest-part-of: fleet-cleanup-idle-selftest.sh
BIN="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -eq 0 ]; then
  set -- RoundTrip.test_dirty_active_loop_recent_unknown_and_unmerged_are_kept
fi
SELFTEST_PART=4/4 exec bash "$BIN/fleet-cleanup-idle-selftest.sh" "$@"
