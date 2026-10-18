#!/bin/bash
# Original part 4/4, group 1/5: complete DoneNoPr driver/recent cases (#3884, #4637).
# Parent SELFTEST_PART=all still runs all 41 cases; original parts 1-3 stay put.
# selftest-part-of: fleet-cleanup-idle-selftest.sh
BIN="$(cd "$(dirname "$0")" && pwd)"
# Explicit argv keeps its original meaning. Default discovery uses this group.
if [ "$#" -eq 0 ]; then
  set -- DoneNoPr.test_driver_scratch_closes_once_its_epic_is_closed \
    DoneNoPr.test_recent_is_kept_and_said_once
fi
# Retain the one process-wide RigCalls start/40/50; argv selects whole cases.
SELFTEST_PART=4/4 exec bash "$BIN/fleet-cleanup-idle-selftest.sh" "$@"
