#!/bin/bash
# hub-zoom.sh — hub focus, SCOPED TO THE CURRENT SESSION (one hub per fleet).
# Two modes, differing ONLY in what happens when you're ALREADY on the hub window:
#
#   default (F9) — progressive hub focus:
#     from another window : jump to THIS session's plan window and focus the dash
#     already in that window: toggle the dash fullscreen (zoom) — press again to
#                           restore
#
#   --home (the ⌂ hub icon tap, issue #405) — pure "go home", CONSISTENT:
#     ALWAYS lands on the plan window with the dash focused and UNZOOMED,
#     whatever window you start on and whatever the current zoom state. A single
#     tap can never leave you fullscreen — the home icon is nav, not a zoom
#     toggle (the iPad/Termius operator relies on that; README + #368).
#
# The hub is DASH-ONLY, so the target is the @dash pane (tmux-dashboard.sh marks
# its own). It used to be the @hub pane — the operator's Claude — and when that
# pane was absent this script rebuilt it via hub-session.sh, which is how a hub
# Claude you had deliberately closed came BACK on the next ⌂ tap or F9. The
# fallback is kept (an accidentally closed hub window is still one tap from
# restored) but hub-session.sh now rebuilds the dash ALONE, so neither key can
# resurrect a Claude session.
set -uo pipefail
mode="${1:-}"                             # --home ⇒ always land unzoomed
. "$(cd "$(dirname "$0")" && pwd)/fleet-lib.sh"
SESS=$(tmux display-message -p '#{session_name}' 2>/dev/null)
target=$(fleet_dash_pane "$SESS")
if [ -z "$target" ]; then
  exec env HUB_SESSION="$SESS" bash "$(dirname "$0")/hub-session.sh"
fi

tw=$(tmux display-message -p -t "$target" '#{window_id}')
curw=$(tmux display-message -p '#{window_id}')

if [ "$mode" = "--home" ] || [ "$curw" != "$tw" ]; then
  # Home nav (⌂) always, and every cross-window jump: arrive UNZOOMED with the
  # dash focused. select-window is a no-op when already here (home-on-hub).
  tmux select-window -t "$target"
  tmux select-pane -t "$target"
  if [ "$(tmux display-message -p -t "$target" '#{window_zoomed_flag}')" = "1" ]; then
    tmux resize-pane -Z -t "$target"     # unzoom → reveal half dash / half hub
  fi
else
  tmux select-pane -t "$target"         # F9 already on the hub → toggle fullscreen
  tmux resize-pane -Z -t "$target"      # (a no-op-looking toggle on a 1-pane hub)
fi
# run-shell shows a blocking error view on ANY nonzero exit (e.g. the zoom-flag
# test above evaluating false) — always leave cleanly.
exit 0
