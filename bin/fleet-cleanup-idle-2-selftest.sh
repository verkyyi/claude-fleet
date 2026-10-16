#!/bin/bash
# Part 2/4; cases and fixtures stay in fleet-cleanup-idle-selftest.sh.
# SELFTEST_PART=all on the parent runs the complete family (issue #4500).
# selftest-part-of: fleet-cleanup-idle-selftest.sh
BIN="$(cd "$(dirname "$0")" && pwd)"
SELFTEST_PART=2/4 exec bash "$BIN/fleet-cleanup-idle-selftest.sh" "$@"
