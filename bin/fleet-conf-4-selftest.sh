#!/bin/bash
# selftest-part-of: fleet-conf-selftest.sh
SELFTEST_PART=4 exec bash "$(dirname "$0")/fleet-conf-selftest.sh" "$@"
