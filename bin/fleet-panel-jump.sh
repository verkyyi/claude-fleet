#!/bin/bash
# fleet-panel-jump.sh — a panel's 「到 …」 button (EPIC #2831; issues #2833, #2834):
# show the window a key names to whoever is looking at THIS window.
#
#   fleet-panel-jump.sh <key>        orchestrator · steward · <slug>:issue-<N> · scratch-<N> …
#
# The key goes through the one resolver, fleet_win_for_key (CLAUDE.md «跨会话寻址
# 只有一个解析器»): rc 1 NOTFOUND, rc 2 AMBIGUOUS — nothing switches, never a guess.
# Found: every client whose current window is this pane's moves to the target in
# its OWN session (a view session is grouped, #1489 — its current window is its
# own); no client looking here ⇒ the pane's session selects it.
#
# Run from a pane (the mod's button): bare tmux is this fleet's server ($TMUX).
#   exit 0 switched · 1 not found · 2 ambiguous · 3 usage / no pane
set -u
BIN=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

key=${1:-}
if [ -z "$key" ] || [ -z "${TMUX_PANE:-}" ]; then
  echo "usage: fleet-panel-jump.sh <key>   (from a fleet pane)" >&2
  exit 3
fi

target=$(fleet_win_for_key "$key")
rc=$?
[ "$rc" -eq 0 ] && [ -n "$target" ] || exit $(( rc == 2 ? 2 : 1 ))

self=$(tmux display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null)
moved=0
while IFS="$(printf '\t')" read -r cs cw; do
  [ -n "$cs" ] && [ "$cw" = "$self" ] || continue
  tmux select-window -t "$cs:$target" 2>/dev/null && moved=$((moved + 1))
done <<EOF
$(tmux list-clients -F "#{session_name}$(printf '\t')#{window_id}" 2>/dev/null)
EOF
if [ "$moved" -eq 0 ]; then
  sess=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
  tmux select-window -t "$sess:$target" 2>/dev/null || exit 1
fi
exit 0
