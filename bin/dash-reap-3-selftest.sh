#!/bin/bash
# Part 3/5; SELFTEST_PART=all on the parent preserves the full sequence.
# selftest-part-of: dash-reap-selftest.sh
SELFTEST_PART=3 exec bash "$(cd "$(dirname "$0")" && pwd)/dash-reap-selftest.sh" "$@"
