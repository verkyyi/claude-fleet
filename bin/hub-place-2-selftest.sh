#!/bin/bash
# Part 2/3; SELFTEST_PART=all on the parent preserves the full sequence.
# selftest-part-of: hub-place-selftest.sh
SELFTEST_PART=2 exec bash "$(cd "$(dirname "$0")" && pwd)/hub-place-selftest.sh" "$@"
