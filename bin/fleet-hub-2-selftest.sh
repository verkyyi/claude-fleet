#!/bin/bash
# fleet-hub-2-selftest.sh — part 2 of 2 of bin/fleet-hub-selftest.sh's cases (issue #2694):
# they outgrew the per-test budget, so they run as 2 tests, each its own ceiling
# and durations row, a stride over the cases (bin/selftest_part.py). The cases are
# all in bin/fleet-hub-selftest.py; this file holds none.
#
# selftest-part-of: fleet-hub-selftest.sh
#   (run-selftests.sh --changed selects this file whenever it selects that one)
BIN="$(cd "$(dirname "$0")" && pwd)"
SELFTEST_PART=2/2 exec bash "$BIN/fleet-hub-selftest.sh" "$@"
