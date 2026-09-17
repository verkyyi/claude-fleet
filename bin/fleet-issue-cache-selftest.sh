#!/bin/bash
# Real linked worktrees, fake gh/tmux: spawn → cached brief, all offline (#459).
set -eu
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-issue-cache-selftest.py" "$BIN"
