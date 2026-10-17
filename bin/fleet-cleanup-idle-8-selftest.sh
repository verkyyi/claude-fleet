#!/bin/bash
# Original part 4/4, group 5/5: the complete bound-live-worktree git gate case.
# selftest-part-of: fleet-cleanup-idle-selftest.sh
BIN="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -eq 0 ]; then
  set -- RoundTrip.test_shared_git_gate_protects_bound_live_worktree
fi
SELFTEST_PART=4/4 exec bash "$BIN/fleet-cleanup-idle-selftest.sh" "$@"
