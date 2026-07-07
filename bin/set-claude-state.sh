#!/bin/sh
# set-claude-state.sh <state> [bell]
# Stamps the current tmux window's @claude_state (semantic: working|done|needs).
# The tmux-spinner.sh daemon reads @claude_state and renders ALL the visuals
# (spinner glyph + its pulsing font color + name color) via @spin, so this hook
# only sets the semantic state and (for needs) rings the bell.
# Registered as a Claude Code hook (see hooks/settings-hooks.json).
# Always exits 0 so it never blocks a turn.
[ -n "$TMUX" ] || exit 0
[ -n "$TMUX_PANE" ] || exit 0

BIN=$(cd "$(dirname "$0")" && pwd)

case "$1" in
  needs) sem="needs" ;;
  done)  sem="done" ;;
  *)     sem="working" ;;   # busy / between-tools / prompt submitted
esac

tmux set-window-option -t "$TMUX_PANE" @claude_state "$sem" 2>/dev/null
# last-activity stamp (drives the dashboard's "Nm ago" column).
tmux set-window-option -t "$TMUX_PANE" @claude_state_ts "$(date +%s)" 2>/dev/null

[ "${2:-}" = "bell" ] && printf '\a' > /dev/tty 2>/dev/null

# Re-slot windows by urgency (lowest-index window pinned) — backgrounded, never blocks the turn.
sess=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
[ -n "$sess" ] && ( "$BIN/tmux-sort-windows.sh" "$sess" >/dev/null 2>&1 & )

exit 0
