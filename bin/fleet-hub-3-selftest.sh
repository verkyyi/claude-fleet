#!/bin/bash
# Part 3/4; cases and fixtures stay in fleet-hub-selftest.sh.
# SELFTEST_PART=all on the parent runs the complete family (issue #4500).
# selftest-part-of: fleet-hub-selftest.sh
BIN="$(cd "$(dirname "$0")" && pwd)"
SELFTEST_PART=3/4 exec bash "$BIN/fleet-hub-selftest.sh" "$@"
