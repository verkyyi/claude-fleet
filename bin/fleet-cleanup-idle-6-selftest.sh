#!/bin/bash
# Original part 4/4, group 3/5: done/sleep-on reap policy cases (#3884, #4637).
# selftest-part-of: fleet-cleanup-idle-selftest.sh
BIN="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -eq 0 ]; then
  set -- ReapPolicy.test_done_waits_its_own_idle_then_reaps_keeping_unpushed_work \
    ReapPolicy.test_sleep_on_considers_only_windows_with_a_policy
fi
SELFTEST_PART=4/4 exec bash "$BIN/fleet-cleanup-idle-selftest.sh" "$@"
