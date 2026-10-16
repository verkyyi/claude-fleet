#!/bin/bash
# Part 10/21; cases and fixtures stay in fleet-break-it-selftest.sh.
# BREAK_PART=all on the parent runs the complete family (issue #4500).
# selftest-part-of: fleet-break-it-selftest.sh
BIN="$(cd "$(dirname "$0")" && pwd)"
BREAK_PART=10/21 exec bash "$BIN/fleet-break-it-selftest.sh" "$@"
