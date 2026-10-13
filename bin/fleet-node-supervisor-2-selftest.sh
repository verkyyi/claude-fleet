#!/bin/bash
# fleet-node-supervisor-2-selftest.sh — part 2 of 3 of bin/fleet-node-supervisor-selftest.sh's cases (issue #2694):
# they outgrew the per-test budget, so they run as 3 tests, each its own ceiling
# and durations row, a stride over the cases (bin/selftest_part.py). The cases are
# all in bin/fleet-node-supervisor-selftest.py; this file holds none.
#
# selftest-part-of: fleet-node-supervisor-selftest.sh
#   (run-selftests.sh --changed selects this file whenever it selects that one)
BIN="$(cd "$(dirname "$0")" && pwd)"
SELFTEST_PART=2/3 exec bash "$BIN/fleet-node-supervisor-selftest.sh" "$@"
