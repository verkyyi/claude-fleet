#!/bin/bash
# Original part 4/4, group 1/5: complete DoneNoPr cases (issue #3884).
# Parent SELFTEST_PART=all still runs all 38 cases; original parts 1-3 stay put.
# selftest-part-of: fleet-cleanup-idle-selftest.sh
BIN="$(cd "$(dirname "$0")" && pwd)"
# Explicit argv keeps its original meaning. Default discovery uses this group.
if [ "$#" -eq 0 ]; then
  set -- DoneNoPr.test_driver_scratch_closes_once_its_epic_is_closed \
    DoneNoPr.test_two_hours_clean_closes_and_drops_the_worktree
fi
# Retain the one process-wide RigCalls start/40/50; argv selects whole cases.
SELFTEST_PART=4/4 exec bash "$BIN/fleet-cleanup-idle-selftest.sh" "$@"
