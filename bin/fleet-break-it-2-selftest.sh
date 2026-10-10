#!/bin/bash
# fleet-break-it-2-selftest.sh — the second half of bin/fleet-break-it-selftest.sh's
# drills (issue #2955). The whole list outgrew the gate's 240 s per-test ceiling,
# so it runs as two tests, each its own ceiling and its own durations row: that
# file runs BREAK_PART=1/2, this one 2/2. The drills, the lockstep lint and the
# runner are all there; this file holds none of its own.
#
# selftest-part-of: fleet-break-it-selftest.sh
#   (run-selftests.sh --changed selects this file whenever it selects that one)
BIN="$(cd "$(dirname "$0")" && pwd)"
BREAK_PART=2/2 exec bash "$BIN/fleet-break-it-selftest.sh" "$@"
