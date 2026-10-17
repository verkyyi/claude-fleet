#!/bin/bash
# selftest-part-of: multirepo-e2e-selftest.sh
SELFTEST_PART=7 exec bash "$(dirname "$0")/multirepo-e2e-selftest.sh" "$@"
