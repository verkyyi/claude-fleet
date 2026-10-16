#!/bin/bash
# Part 2/2; cases and fixtures stay in fleet-await-stall-selftest.sh.
# SELFTEST_PART=all on the parent runs the complete family (issue #4500).
# selftest-part-of: fleet-await-stall-selftest.sh
BIN="$(cd "$(dirname "$0")" && pwd)"
SELFTEST_PART=2/2 exec bash "$BIN/fleet-await-stall-selftest.sh" "$@"
