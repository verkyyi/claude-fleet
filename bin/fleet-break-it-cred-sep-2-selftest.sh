#!/bin/bash
# Part 2/2; measured drill weights, all assertions remain in the parent.
# selftest-part-of: fleet-break-it-cred-sep-selftest.sh
BIN="$(cd "$(dirname "$0")" && pwd)"
BREAK_PART=2/2 exec bash "$BIN/fleet-break-it-cred-sep-selftest.sh" "$@"
