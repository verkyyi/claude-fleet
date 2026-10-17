#!/bin/bash
# Original part 4/4, group 3/5: keep/merged policy and test-identity cases (#3884, #4637).
# selftest-part-of: fleet-cleanup-idle-selftest.sh
BIN="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -eq 0 ]; then
  set -- ReapPolicy.test_keep_and_merged_are_never_this_pass \
    TestIdentity.test_closes_a_test_session_past_its_policy_and_nothing_else
fi
SELFTEST_PART=4/4 exec bash "$BIN/fleet-cleanup-idle-selftest.sh" "$@"
