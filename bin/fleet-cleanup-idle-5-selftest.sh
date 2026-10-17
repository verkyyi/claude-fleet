#!/bin/bash
# Original part 4/4, group 2/5: complete dry-run/home/at-policy cases (#3884).
# selftest-part-of: fleet-cleanup-idle-selftest.sh
BIN="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -eq 0 ]; then
  set -- EmptyReap.test_dry_run_closes_nothing \
    HomeReap.test_spawned_norepo_without_policy_is_never_closed \
    PinIsOrder.test_dry_run_migrates_nothing \
    ReapPolicy.test_at_only_once_the_time_has_come_and_never_while_working
fi
SELFTEST_PART=4/4 exec bash "$BIN/fleet-cleanup-idle-selftest.sh" "$@"
