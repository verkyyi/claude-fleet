#!/bin/sh
# classify-hook.sh — event trigger for real-time single-window state classification.
# Wired to the Stop Claude Code hook so a stopped turn is disambiguated (done vs
# looping vs needs) within ~1-2s, instead of waiting for the slow ~1800s backstop
# tick of the com.claude-fleet.classify daemon. This is the ONLY fast path to the
# purple 'looping' state.
#
# set-claude-state.sh has just stamped this window 'done'; that state is ambiguous
# (a Stop between loop iterations looks identical to a real finish). We hand the
# window to classify-sessions.sh --window, which reads the pane and recovers intent.
#
# Backgrounds the (LLM) work and exits 0 immediately so it never blocks or slows
# the turn. No-op outside tmux, and a no-op if `claude` isn't on PATH (the worker
# self-disables). classify-sessions.sh --window is debounced by a change-hash and
# a per-window lock, so firing it on every Stop is safe (static screens never
# re-call the LLM; a concurrent daemon backstop can't double-run the same window).
set -u
[ -n "${TMUX:-}" ] || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0
command -v claude >/dev/null 2>&1 || exit 0
BIN=$(cd "$(dirname "$0")" && pwd)
wid=$(tmux display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null)
[ -n "$wid" ] || exit 0
( "$BIN/classify-sessions.sh" --window "$wid" >/dev/null 2>&1 & )
exit 0
