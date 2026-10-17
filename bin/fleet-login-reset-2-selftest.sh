#!/bin/bash
# selftest-part-of: fleet-login-reset-selftest.sh
SELFTEST_PART=2 exec bash "$(cd "$(dirname "$0")" && pwd)/fleet-login-reset-selftest.sh" "$@"
