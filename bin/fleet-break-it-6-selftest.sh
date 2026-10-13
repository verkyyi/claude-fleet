#!/bin/bash
# fleet-break-it-6-selftest.sh — part 6 of 7 of bin/fleet-break-it-selftest.sh's
# drills (issues #2955, #2694). The whole list outgrew the per-test budget, so it
# runs as seven tests, each its own ceiling and its own durations row: that file
# runs BREAK_PART=1/7, the parts 2..7 run the rest, sliced by each drill's wall
# time (bin/break-it-durations.txt). The drills, the lockstep lint and the runner
# are all there; this file holds none of its own.
#
# selftest-part-of: fleet-break-it-selftest.sh
#   (run-selftests.sh --changed selects this file whenever it selects that one)
BIN="$(cd "$(dirname "$0")" && pwd)"
BREAK_PART=6/7 exec bash "$BIN/fleet-break-it-selftest.sh" "$@"
