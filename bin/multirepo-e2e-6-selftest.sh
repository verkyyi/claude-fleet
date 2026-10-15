#!/bin/bash
# selftest-part-of: multirepo-e2e-selftest.sh
SELFTEST_PART=6 exec bash "$(dirname "$0")/multirepo-e2e-selftest.sh" "$@"
