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
#
# TASK BAR FIRST (issue #899, FLEET_HOME_SIDEBAR_FIRST, default on): pressed in a
# task whose window shows the task bar (`@sidebar_worker`, not zoomed, and no name
# half-typed on its input line — `@sidebar_input` on the view, the `{top-left}`
# pane, issue #896), either key first puts the keyboard ON the
# task bar — the same navigation state prefix E enters — and stays in this window;
# most of the time "home" only meant "switch task", and the bar is right there.
# Pressed again while the bar has the keyboard, it goes to the hub as before. The
# conf tells the two presses apart with `--nav`: tmux resets the client to the
# root key table BEFORE a binding runs, so the script cannot read
# #{client_key_table} itself — the fleet-sidebar table's own F9 / ⌂ binds pass it.
# A zoomed window has no bar on screen, so ⌂ there still unzooms and goes home.
# The landing is logged to the hub-visit meter as `home-sidebar` / `f9-sidebar`
# (issue #897) — a trip to the hub that did NOT happen. Knob 0 ⇒ exactly the old
# behaviour.
#
# Usage: hub-zoom.sh [--home] [--nav] [--client <name>]
set -uo pipefail
mode='' nav=0 client=''
while [ $# -gt 0 ]; do
  case "$1" in
    --home)   mode=--home ;;             # --home ⇒ always land unzoomed
    --nav)    nav=1 ;;                   # the client was on the task bar already
    --client) client="${2:-}"; shift ;;  # the client that pressed the key
  esac
  shift
done
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-lib.sh"
SESS=$(tmux display-message -p '#{session_name}' 2>/dev/null)

# Task bar first — decided on this window's own options, before any hub lookup.
if [ "$nav" = 0 ] &&
   [ "$(tmux display-message -p '#{&&:#{@sidebar_worker},#{!=:#{window_zoomed_flag},1}}' 2>/dev/null)" = 1 ] &&
   [ -z "$(tmux display-message -p -t '{top-left}' '#{@sidebar_input}' 2>/dev/null)" ]; then
  [ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
  fleet_load_conf "$SESS"
  if [ "${FLEET_HOME_SIDEBAR_FIRST:-1}" != 0 ] &&
     tmux switch-client ${client:+-c "$client"} -T fleet-sidebar 2>/dev/null; then
    sid=$(tmux display-message -p '#{session_id}' 2>/dev/null)
    bash "$BIN/fleet-sidebar.sh" key "$sid" Escape >/dev/null 2>&1 || :
    tmux display-message ${client:+-c "$client"} 'Tasks: type a name ↵ = new session · ↑↓ switch · ↵/Esc worker · ⌂/F9 again → hub' 2>/dev/null || :
    if [ "$mode" = --home ]; then cause=home-sidebar; else cause=f9-sidebar; fi
    bash "$BIN/fleet-hub-visits.sh" record '' "$SESS" "$cause" \
      "$(tmux display-message -p '#{?#{@wid},#{@wid},#{window_id}}' 2>/dev/null)" '' >/dev/null 2>&1 || :
    exit 0
  fi
fi

target=$(fleet_dash_pane "$SESS")
if [ -z "$target" ]; then
  exec env HUB_SESSION="$SESS" bash "$(dirname "$0")/hub-session.sh"
fi

tw=$(tmux display-message -p -t "$target" '#{window_id}')
curw=$(tmux display-message -p '#{window_id}')

if [ "$mode" = "--home" ] || [ "$curw" != "$tw" ]; then
  # Home nav (⌂) always, and every cross-window jump: arrive UNZOOMED with the
  # dash focused. select-window is a no-op when already here (home-on-hub).
  # Stamp WHY for the hub-visit meter (issue #897) — one-shot, read and cleared by
  # the session-window-changed[73] hook the select-window below fires. Only on a
  # real jump: home-on-hub changes no window, so a stamp there would go stale.
  if [ "$curw" != "$tw" ]; then
    if [ "$mode" = "--home" ]; then tmux set -q @hub_nav_via home; else tmux set -q @hub_nav_via f9; fi
  fi
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
