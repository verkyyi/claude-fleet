#!/bin/bash
# Part 2/3; dynamic unittest stride, with every selected case's own cleanup.
# selftest-part-of: fleet-sleep-selftest.sh
BIN="$(cd "$(dirname "$0")" && pwd)"
SELFTEST_PART=2/3 exec bash "$BIN/fleet-sleep-selftest.sh" "$@"
