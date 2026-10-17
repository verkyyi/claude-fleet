#!/bin/bash
# selftest-part-of: fleet-start-warm-selftest.sh
SELFTEST_PART=2 exec bash "$(cd "$(dirname "$0")" && pwd)/fleet-start-warm-selftest.sh" "$@"
