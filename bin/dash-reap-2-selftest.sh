#!/bin/bash
# Part 2/5; SELFTEST_PART=all on the parent preserves the full sequence.
# selftest-part-of: dash-reap-selftest.sh
SELFTEST_PART=2 exec bash "$(cd "$(dirname "$0")" && pwd)/dash-reap-selftest.sh" "$@"
