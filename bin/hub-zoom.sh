#!/bin/bash
# hub-zoom.sh — hub focus, SCOPED TO THE CURRENT SESSION (one hub per fleet).
# Two modes, differing ONLY in what happens when you're ALREADY on the hub window:
#
#   default (F9) — progressive hub focus:
#     from another window : jump to THIS session's plan window and focus the
#                           hub pane (split view — dash above, hub below)
#     already in that window: toggle the hub pane fullscreen (zoom) — press
#                           again to restore the split
#
#   --home (the ⌂ hub icon tap, issue #405) — pure "go home", CONSISTENT:
#     ALWAYS lands on the half-dash / half-hub SPLIT and focuses the hub pane,
#     whatever window you start on and whatever the current zoom state. A single
#     tap can never leave you fullscreen — the home icon is nav, not a zoom
#     toggle (the iPad/Termius operator relies on that; README + #368).
#
# The hub pane = pane option @hub=1 (hub-session.sh marks its spawn; mark any
# pane by hand: tmux set-option -p @hub 1). No marked pane IN THIS SESSION →
# fall back to building this fleet's hub (hub-session.sh), passing the current
# session so the hub lands here, not in another fleet.
set -uo pipefail
mode="${1:-}"                             # --home ⇒ always land on the split
. "$(cd "$(dirname "$0")" && pwd)/fleet-lib.sh"
SESS=$(tmux display-message -p '#{session_name}' 2>/dev/null)
target=$(fleet_hub_pane "$SESS")
if [ -z "$target" ]; then
  exec env HUB_SESSION="$SESS" bash "$(dirname "$0")/hub-session.sh"
fi

tw=$(tmux display-message -p -t "$target" '#{window_id}')
curw=$(tmux display-message -p '#{window_id}')

if [ "$mode" = "--home" ] || [ "$curw" != "$tw" ]; then
  # Home nav (⌂) always, and every cross-window jump: arrive at the SPLIT view,
  # hub focused. select-window is a no-op when already here (home-on-hub).
  tmux select-window -t "$target"
  tmux select-pane -t "$target"
  if [ "$(tmux display-message -p -t "$target" '#{window_zoomed_flag}')" = "1" ]; then
    tmux resize-pane -Z -t "$target"     # unzoom → reveal half dash / half hub
  fi
else
  tmux select-pane -t "$target"         # F9 already on the hub → toggle fullscreen
  tmux resize-pane -Z -t "$target"
fi
# run-shell shows a blocking error view on ANY nonzero exit (e.g. the zoom-flag
# test above evaluating false) — always leave cleanly.
exit 0
