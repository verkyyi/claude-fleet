#!/bin/bash
# Part 2/3; cases and fixtures stay in fleet-quotawatch-selftest.sh.
# SELFTEST_PART=all on the parent runs the complete family (issue #4500).
# selftest-part-of: fleet-quotawatch-selftest.sh
BIN="$(cd "$(dirname "$0")" && pwd)"
SELFTEST_PART=2/3 exec bash "$BIN/fleet-quotawatch-selftest.sh" "$@"
