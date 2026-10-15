#!/bin/bash
# selftest-part-of: fleet-install-selftest.sh
SELFTEST_PART=3 exec bash "$(dirname "$0")/fleet-install-selftest.sh" "$@"
