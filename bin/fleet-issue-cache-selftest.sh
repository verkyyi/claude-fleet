#!/bin/bash
# Real linked worktrees, fake gh/tmux: spawn → cached brief, all offline (#459).
# Drives dash-issue-session.sh, fleet-claim-brief.sh and fleet-issue-cache.py —
# named here so `run-selftests.sh --changed` selects this test when they change
# (the .py beside it is not scanned; issue #2638).
set -eu
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-issue-cache-selftest.py" "$BIN"
