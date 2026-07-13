#!/bin/bash
# steward-zoom.sh — F9, progressive steward focus, SCOPED TO THE CURRENT
# SESSION (one steward hub per fleet):
#   from another window : jump to THIS session's plan window and focus the
#                         steward pane (split view — dash above, steward below)
#   already in that window: toggle the steward pane fullscreen (zoom) — press
#                         again to restore the split
# The steward pane = pane option @steward=1 (steward-session.sh marks its
# spawn; mark any pane by hand: tmux set-option -p @steward 1). No marked pane
# IN THIS SESSION → fall back to building this fleet's hub (steward-session.sh),
# passing the current session so the hub lands here, not in another fleet.
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/fleet-lib.sh"
SESS=$(tmux display-message -p '#{session_name}' 2>/dev/null)
target=$(fleet_steward_pane "$SESS")
if [ -z "$target" ]; then
  exec env STEWARD_SESSION="$SESS" bash "$(dirname "$0")/steward-session.sh"
fi

tw=$(tmux display-message -p -t "$target" '#{window_id}')
curw=$(tmux display-message -p '#{window_id}')

if [ "$curw" != "$tw" ]; then
  tmux select-window -t "$target"       # jump — always arrive at the SPLIT view
  tmux select-pane -t "$target"
  if [ "$(tmux display-message -p -t "$target" '#{window_zoomed_flag}')" = "1" ]; then
    tmux resize-pane -Z -t "$target"
  fi
else
  tmux select-pane -t "$target"         # inside already — toggle fullscreen
  tmux resize-pane -Z -t "$target"
fi
# run-shell shows a blocking error view on ANY nonzero exit (e.g. the zoom-flag
# test above evaluating false) — always leave cleanly.
exit 0
