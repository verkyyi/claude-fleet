#!/bin/bash
# dash-issue-spawn.sh — popup issue picker that STARTS A NEW SESSION for the
# chosen issue (git worktree + claude, bound to it) in the current fleet. Run
# inside `tmux display-popup -E`. Type to search; Enter spawns and focuses the
# new window; Esc cancels. Replaces the old dash ⌃g "bind window ↔ issue" picker
# (dash-issue-pick.sh) — same list UI, but it spawns a worker instead of binding
# an existing window.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-lib.sh" 2>/dev/null || true

# Scope the issue list to THIS fleet — resolve the tmux session the same way the
# backlog (tmux-issues.sh) does, and export FLEET_SESSION so the rows producer
# reads the right issues cache. dash-issue-session.sh resolves the same fleet.
FLEET_SESSION=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null)
[ -z "$FLEET_SESSION" ] && FLEET_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null)
export FLEET_SESSION

num=$(bash "$BIN/tmux-issues-rows.sh" all 2>/dev/null \
  | fzf --ansi --delimiter=$'\x1f' --with-nth=2 --no-sort --layout=reverse \
        --prompt='new session ▸ ' \
        --header='pick an issue to start a session · type to search · enter spawns · esc cancels' \
  | cut -d$'\x1f' -f1)
[ -n "$num" ] && bash "$BIN/dash-issue-session.sh" "$num"
