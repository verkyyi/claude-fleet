#!/bin/bash
# Original part 4/4, group 2/5: DoneNoPr keep/home/notice/grammar cases (#3884, #4637).
# selftest-part-of: fleet-cleanup-idle-selftest.sh
BIN="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -eq 0 ]; then
  set -- DoneNoPr.test_working_pr_open_issue_and_keep_are_kept \
    HomeReap.test_no_policy_or_keep_is_never_closed_a_pin_keeps_nothing \
    NoticeTests.test_notice_has_visible_tick_and_resets_on_activity_or_stale_tick \
    PolicyGrammar.test_norm_default_label
fi
SELFTEST_PART=4/4 exec bash "$BIN/fleet-cleanup-idle-selftest.sh" "$@"
