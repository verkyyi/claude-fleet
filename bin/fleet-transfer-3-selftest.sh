#!/bin/bash
# selftest-part-of: fleet-transfer-selftest.sh
SELFTEST_PART=3 exec bash "$(dirname "$0")/fleet-transfer-selftest.sh" "$@"
