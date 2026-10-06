#!/bin/bash
# fleet-window-carry.sh <window id> — a session's identity follows its agent pane
# (issue #1844, EPIC #1851 C5).
#
# A session IS its window's options (@issue, @fleet_id, @cc_session_id, @repo,
# @worktree, @fleet_role …) — every resolver, the recovery page and restore read
# them off the window the agent's pane sits in. `prefix !` (break-pane) moves the
# pane to a NEW window and leaves the options behind: the new window answers to
# nothing, the old one answers for a shell, and the recovery page finds no
# conversation id. The node conf's window-linked hook calls this when a wrapper
# pane (fleet-session-wrap.sh stamps @wrap_win = its window) shows up in a window
# that is not @wrap_win: every @ option moves to the new window, which takes the
# name too; the window left behind is renamed `<name>-shell` and marked a panel,
# so nothing counts, lists or restores it as a session. Quiet; rc 0 always.
set -u
W="${1:-}"
case "$W" in @[0-9]*) ;; *) exit 0 ;; esac
P=$(tmux display-message -p -t "$W" '#{pane_id}' 2>/dev/null) || exit 0
S=$(tmux show-options -pqv -t "$P" @wrap_win 2>/dev/null)
[ -n "$S" ] && [ "$S" != "$W" ] || exit 0
# A grouped (view) session links the window once per session: one carry only.
sk=${TMUX:-}; sk=${sk%%,*}; sk=${sk##*/}
lock="${TMPDIR:-/tmp}/fleet-carry.$(id -u).${sk:-x}.${P#%}"
mkdir "$lock" 2>/dev/null || exit 0
trap 'rmdir "$lock" 2>/dev/null' EXIT
[ "$(tmux show-options -pqv -t "$P" @wrap_win 2>/dev/null)" = "$S" ] || exit 0
# The old window gone: nothing to carry, the pane simply lives here now.
if [ "$(tmux display-message -p -t "$S" '#{window_id}' 2>/dev/null)" != "$S" ]; then
  tmux set-option -p -t "$P" @wrap_win "$W" 2>/dev/null; exit 0
fi
name=$(tmux display-message -p -t "$S" '#{window_name}' 2>/dev/null)
tmux show-options -w -t "$S" 2>/dev/null | while IFS= read -r line; do
  o=${line%% *}
  case "$o" in @*) ;; *) continue ;; esac
  v=$(tmux show-options -wqv -t "$S" "$o" 2>/dev/null)
  tmux set-option -w -t "$W" "$o" "$v" 2>/dev/null && tmux set-option -wu -t "$S" "$o" 2>/dev/null
done
tmux set-option -p -t "$P" @wrap_win "$W" 2>/dev/null
tmux set-option -w -t "$S" @fleet_role panel 2>/dev/null
[ -n "$name" ] && { tmux rename-window -t "$W" "$name" 2>/dev/null; tmux rename-window -t "$S" "$name-shell" 2>/dev/null; }
exit 0
