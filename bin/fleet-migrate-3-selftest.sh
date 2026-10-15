#!/bin/bash
# selftest-part-of: fleet-migrate-selftest.sh
SELFTEST_PART=3 exec bash "$(dirname "$0")/fleet-migrate-selftest.sh" "$@"
