#!/bin/bash
# steward-session.sh — (re)create the HUB: the plan window with the dash on top
# (40%) and the persistent steward Claude session below, in the base checkout.
# Idempotent: if a @steward-marked pane exists anywhere, just jump to it.
# This is prefix+g's fallback (steward-zoom.sh), so an accidentally closed hub
# window is one keypress from restored. The steward picks up its standing
# orders from ~/.claude/steward.md and the latest handoff doc if one exists.
#
# IMPORTANT: window names are NOT unique in tmux, so we NEVER target "$SESS:plan"
# by name — a second 'plan' window makes that reference ambiguous, which is how
# earlier versions piled up orphan 'plan' windows and left you on the wrong one
# with no steward. Everything below targets by window_id / pane_id.
SESS="${STEWARD_SESSION:-ClaudeFleet}"
BASE="${STEWARD_CWD:-$HOME/projects/24haowan-monorepo}"
STEWARD_CMD="${STEWARD_CMD:-claude \"Read ~/.claude/steward.md and adopt it: you are the steward session. If ~/.claude/handoff/ has a recent steward handoff, /handoff pick up the newest one first; otherwise run one /sweep now. Then arm /loop 45m /sweep.\"; exec \$SHELL}"

# already have a live steward pane anywhere → just focus it, done.
existing=$(tmux list-panes -a -F '#{pane_id} #{@steward}' | awk '$2=="1"{print $1; exit}')
if [ -n "$existing" ]; then
  tmux select-window -t "$existing"; tmux select-pane -t "$existing"; exit 0
fi

# No steward pane exists → no 'plan' window holds anything precious (their dash
# pane is just a respawnable `bash tmux-dashboard.sh`). Nuke ALL 'plan' windows
# so we rebuild exactly one hub — this also self-heals any accumulated orphans.
for wid in $(tmux list-windows -t "$SESS" -F '#{window_id} #{window_name}' | awk '$2=="plan"{print $1}'); do
  tmux kill-window -t "$wid" 2>/dev/null
done

# build the hub fresh, capturing IDs so every op hits THIS window/pane.
win=$(tmux new-window -P -F '#{window_id}' -t "$SESS:" -n plan -c "$HOME/.claude" 'bash ~/.claude/tmux-dashboard.sh')
sp=$(tmux split-window -P -F '#{pane_id}' -v -l 60% -t "$win" -c "$BASE" "$STEWARD_CMD")
tmux set-option -p -t "$sp" @steward 1 2>/dev/null

# hub belongs at the lowest index (the urgency sorter pins slot 1)
if tmux list-windows -t "$SESS" -F '#{window_index}' | grep -qx 1; then
  tmux swap-window -d -s "$win" -t "$SESS:1" 2>/dev/null
else
  tmux move-window -d -s "$win" -t "$SESS:1" 2>/dev/null
fi
tmux select-window -t "$win"
tmux select-pane -t "$sp"
exit 0
