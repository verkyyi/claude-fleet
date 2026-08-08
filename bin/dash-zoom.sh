#!/bin/bash
# dash-zoom.sh — prefix+g, progressive DASH focus, SCOPED TO THE CURRENT SESSION
# (one dash hub per fleet):
#   from another window : jump to THIS session's plan window and focus the dash
#   already in that window: toggle the dash pane fullscreen (zoom) — press again
#                         to restore
# The dash pane = pane option @dash=1 (tmux-dashboard.sh marks its OWN pane via
# fleet_mark_role — never the active pane, issue #135). No marked pane IN THIS
# SESSION → fall back to building this fleet's hub (hub-session.sh), passing the
# current session so the hub lands here, not in another fleet.
#
# Now that the hub is DASH-ONLY this is very nearly hub-zoom.sh; both stay bound
# (prefix+g and F9/⌂ are different muscle memory) and both resolve the same pane
# via fleet_dash_pane. The rebuild fallback can no longer spawn a Claude session.
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/fleet-lib.sh"
SESS=$(tmux display-message -p '#{session_name}' 2>/dev/null)
target=$(fleet_dash_pane "$SESS")
if [ -z "$target" ]; then
  exec env HUB_SESSION="$SESS" bash "$(dirname "$0")/hub-session.sh"
fi

tw=$(tmux display-message -p -t "$target" '#{window_id}')
curw=$(tmux display-message -p '#{window_id}')

if [ "$curw" != "$tw" ]; then
  tmux select-window -t "$target"       # jump — always arrive UNZOOMED
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
