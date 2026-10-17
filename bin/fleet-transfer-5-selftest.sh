#!/bin/bash
# selftest-part-of: fleet-transfer-selftest.sh
SELFTEST_PART=5 exec bash "$(dirname "$0")/fleet-transfer-selftest.sh" "$@"
