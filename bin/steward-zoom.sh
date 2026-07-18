#!/bin/bash
# steward-zoom.sh — steward focus, SCOPED TO THE CURRENT SESSION (one steward hub
# per fleet). Two modes, differing ONLY in what happens when you're ALREADY on the
# hub window:
#
#   default (F9) — progressive steward focus:
#     from another window : jump to THIS session's plan window and focus the
#                           steward pane (split view — dash above, steward below)
#     already in that window: toggle the steward pane fullscreen (zoom) — press
#                           again to restore the split
#
#   --home (the ⌂ hub icon tap, issue #405) — pure "go home", CONSISTENT:
#     ALWAYS lands on the half-dash / half-steward SPLIT and focuses the steward
#     pane, whatever window you start on and whatever the current zoom state. A
#     single tap can never leave you fullscreen — the home icon is nav, not a
#     zoom toggle (the iPad/Termius operator relies on that; README + #368).
#
# The steward pane = pane option @steward=1 (steward-session.sh marks its
# spawn; mark any pane by hand: tmux set-option -p @steward 1). No marked pane
# IN THIS SESSION → fall back to building this fleet's hub (steward-session.sh),
# passing the current session so the hub lands here, not in another fleet.
set -uo pipefail
mode="${1:-}"                             # --home ⇒ always land on the split
. "$(cd "$(dirname "$0")" && pwd)/fleet-lib.sh"
SESS=$(tmux display-message -p '#{session_name}' 2>/dev/null)
target=$(fleet_steward_pane "$SESS")
if [ -z "$target" ]; then
  exec env STEWARD_SESSION="$SESS" bash "$(dirname "$0")/steward-session.sh"
fi

tw=$(tmux display-message -p -t "$target" '#{window_id}')
curw=$(tmux display-message -p '#{window_id}')

if [ "$mode" = "--home" ] || [ "$curw" != "$tw" ]; then
  # Home nav (⌂) always, and every cross-window jump: arrive at the SPLIT view,
  # steward focused. select-window is a no-op when already here (home-on-hub).
  tmux select-window -t "$target"
  tmux select-pane -t "$target"
  if [ "$(tmux display-message -p -t "$target" '#{window_zoomed_flag}')" = "1" ]; then
    tmux resize-pane -Z -t "$target"     # unzoom → reveal half dash / half steward
  fi
else
  tmux select-pane -t "$target"         # F9 already on the hub → toggle fullscreen
  tmux resize-pane -Z -t "$target"
fi
# run-shell shows a blocking error view on ANY nonzero exit (e.g. the zoom-flag
# test above evaluating false) — always leave cleanly.
exit 0
