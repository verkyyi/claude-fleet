#!/bin/sh
# summarize-hook.sh — event trigger for a fresh single-window dash summary.
# Wired to the Stop and SessionStart Claude Code hooks so the summary column
# updates the instant a turn ends or a session starts, instead of waiting for
# the ~180s com.claude-fleet.summarize daemon tick. Backgrounds the (LLM) work
# and exits 0 immediately so it never blocks or slows the turn. No-op outside
# tmux. tmux-summarize.sh --window is itself debounced + locked, so firing it
# on every Stop is safe (rapid turns coalesce; a static screen never re-summarizes).
set -u
[ -n "${TMUX:-}" ] || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0
BIN=$(cd "$(dirname "$0")" && pwd)
wid=$(tmux display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null)
[ -n "$wid" ] || exit 0
( "$BIN/tmux-summarize.sh" --window "$wid" >/dev/null 2>&1 & )
exit 0
