#!/bin/bash
# Original part 4/4, group 4/5: the complete dry/cap/off/rate-limit case (#3884, #4637).
# selftest-part-of: fleet-cleanup-idle-selftest.sh
BIN="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -eq 0 ]; then
  set -- RoundTrip.test_dry_cap_off_and_rate_limit
fi
SELFTEST_PART=4/4 exec bash "$BIN/fleet-cleanup-idle-selftest.sh" "$@"
