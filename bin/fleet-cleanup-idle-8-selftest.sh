#!/bin/bash
# Original part 4/4, group 5/5: the complete unmerged-PR ancestor/activity case (#3884, #4637).
# selftest-part-of: fleet-cleanup-idle-selftest.sh
BIN="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -eq 0 ]; then
  set -- RoundTrip.test_unmerged_pr_requires_strict_ancestor_and_activity_recheck
fi
SELFTEST_PART=4/4 exec bash "$BIN/fleet-cleanup-idle-selftest.sh" "$@"
