#!/bin/bash
# Part 3/3; measured drill weights, all assertions remain in the parent.
# selftest-part-of: fleet-break-it-hub-selftest.sh
BIN="$(cd "$(dirname "$0")" && pwd)"
BREAK_PART=3/3 exec bash "$BIN/fleet-break-it-hub-selftest.sh" "$@"
