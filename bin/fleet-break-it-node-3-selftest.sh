#!/bin/bash
# fleet-break-it-node-3-selftest.sh — part 3 of 3 of bin/fleet-break-it-node-selftest.sh's drills (issue #2694). It
# outgrew the per-test budget, so it runs as 3 tests, each its own ceiling and its
# own durations row, sliced by each drill's wall time (bin/break-it-durations.txt,
# cred_run_drills). The drills and the runner are all there; this file holds none.
#
# selftest-part-of: fleet-break-it-node-selftest.sh
#   (run-selftests.sh --changed selects this file whenever it selects that one)
BIN="$(cd "$(dirname "$0")" && pwd)"
BREAK_PART=3/3 exec bash "$BIN/fleet-break-it-node-selftest.sh" "$@"
