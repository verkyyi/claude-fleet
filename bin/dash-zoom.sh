#!/bin/bash
# dash-zoom.sh — prefix+G, progressive DASH focus, SCOPED TO THE CURRENT SESSION
# (one dash hub per fleet), the mirror image of steward-zoom.sh:
#   from another window : jump to THIS session's plan window and focus the dash
#                         pane (split view — dash above, steward below)
#   already in that window: toggle the dash pane fullscreen (zoom) — press again
#                         to restore the split
# The dash pane = pane option @dash=1 (tmux-dashboard.sh marks its OWN pane via
# fleet_mark_role — never the active pane, issue #135). No marked pane IN THIS
# SESSION → fall back to building this fleet's hub (steward-session.sh builds the
# dash+steward split), passing the current session so the hub lands here, not in
# another fleet.
set -uo pipefail
SESS=$(tmux display-message -p '#{session_name}' 2>/dev/null)
target=$(tmux list-panes -s -t "$SESS" -F '#{pane_id} #{@dash}' 2>/dev/null | awk '$2=="1"{print $1; exit}')
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
