#!/bin/bash
# Part 2/6; cases and fixtures stay in fleet-break-it-node-selftest.sh.
# BREAK_PART=all on the parent runs the complete family (issue #4500).
# selftest-part-of: fleet-break-it-node-selftest.sh
BIN="$(cd "$(dirname "$0")" && pwd)"
BREAK_PART=2/6 exec bash "$BIN/fleet-break-it-node-selftest.sh" "$@"
