#!/bin/bash
# Original part 4/4, group 3/5: Claude -> same Rig rebuild -> Codex stays whole.
# selftest-part-of: fleet-cleanup-idle-selftest.sh
BIN="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -eq 0 ]; then
  set -- ReapPolicy.test_scratch_default_is_fifteen_minutes_for_claude_and_codex
fi
SELFTEST_PART=4/4 exec bash "$BIN/fleet-cleanup-idle-selftest.sh" "$@"
