#!/bin/bash
# selftest-part-of: fleet-conf-selftest.sh
SELFTEST_PART=2 exec bash "$(dirname "$0")/fleet-conf-selftest.sh" "$@"
