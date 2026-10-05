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
#
# The full-screen list retired (issue #1533): unless FLEET_DASH_WINDOW=1 brings
# the hub window back, prefix+g lands where ⌂ does — the task list in the window
# you are in, focused (fleet-sidebar.sh home). Below is the FLEET_DASH_WINDOW=1 path.
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/fleet-lib.sh"
SESS=$(tmux display-message -p '#{?#{session_group},#{session_group},#{session_name}}' 2>/dev/null)
(
  BIN="$(cd "$(dirname "$0")" && pwd)"
  [ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
  _fs="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/fleet.settings"; [ -f "$_fs" ] && . "$_fs"
  fleet_load_conf "$SESS"
  [ "${FLEET_DASH_WINDOW:-0}" = 1 ]
) || exec bash "$(cd "$(dirname "$0")" && pwd)/fleet-sidebar.sh" home '' g
target=$(fleet_dash_pane "$SESS")
if [ -z "$target" ]; then
  exec env HUB_SESSION="$SESS" bash "$(dirname "$0")/hub-session.sh"
fi

tw=$(tmux display-message -p -t "$target" '#{window_id}')
curw=$(tmux display-message -p '#{window_id}')

if [ "$curw" != "$tw" ]; then
  tmux set -q @hub_nav_via g            # one-shot cause for the hub-visit meter (#897)
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
