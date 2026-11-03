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
#
# Never from a window whose own wrapper is still there (task PV5W): a pane whose
# @wrap_win went stale (a wrapper once launched in it, the window it named since
# relinked) showing up in another window used to strip a LIVE session's window
# — renamed `<name>-shell`, marked a panel, so the lists dropped it and the 看台
# offered only 归档 — and when the moves failed the options stayed while the
# label still changed. Now: S keeps a pane whose @wrap_win is S ⇒ nothing; the
# panel mark and the rename only once every option moved.
#
# fleet-window-carry.sh --heal [socket label]: undo that label — a window marked a
# panel that still carries a session (@fleet_id) and its own wrapper pane gets
# @fleet_role worker back and loses the `-shell` suffix. Run on the cleanup tick.
set -u
if [ "${1:-}" = --heal ]; then
  tm() { if [ -n "${2:-}" ]; then tmux -L "$2" "${@:3}"; else tmux "${@:3}"; fi; }
  L="${2:-}"
  tm x "$L" list-windows -a -F '#{window_id}|#{@fleet_role}|#{@fleet_id}' 2>/dev/null | sort -u |
  while IFS='|' read -r w role fid; do
    [ "$role" = panel ] && [ -n "$fid" ] || continue
    tm x "$L" list-panes -t "$w" -F '#{@wrap_win}' 2>/dev/null | grep -qx "$w" || continue
    tm x "$L" set-option -w -t "$w" @fleet_role worker 2>/dev/null || continue
    n=$(tm x "$L" display-message -p -t "$w" '#{window_name}' 2>/dev/null)
    case "$n" in *-shell) tm x "$L" rename-window -t "$w" "${n%-shell}" 2>/dev/null ;; esac
    printf 'healed %s %s\n' "$w" "$fid"
  done
  exit 0
fi
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
# The old window still holds its own wrapper: it is that session, not a shell.
tmux list-panes -t "$S" -F '#{@wrap_win}' 2>/dev/null | grep -qx "$S" && exit 0
name=$(tmux display-message -p -t "$S" '#{window_name}' 2>/dev/null)
failed=$(tmux show-options -w -t "$S" 2>/dev/null | while IFS= read -r line; do
  o=${line%% *}
  case "$o" in
    (@origin|@origin_fid|@origin_wid|@origin_gen|@origin_retired) continue ;;
    (@*) ;; (*) continue ;;
  esac
  v=$(tmux show-options -wqv -t "$S" "$o" 2>/dev/null)
  if tmux set-option -w -t "$W" "$o" "$v" 2>/dev/null; then tmux set-option -wu -t "$S" "$o" 2>/dev/null
  else printf 'x'; fi
done)
[ -z "$failed" ] || exit 0   # a move failed: leave the session where it is, labelled as it was
tmux set-option -p -t "$P" @wrap_win "$W" 2>/dev/null
tmux set-option -w -t "$S" @fleet_role panel 2>/dev/null
[ -n "$name" ] && { tmux rename-window -t "$W" "$name" 2>/dev/null; tmux rename-window -t "$S" "$name-shell" 2>/dev/null; }
exit 0
