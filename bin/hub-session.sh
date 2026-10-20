#!/bin/bash
# hub-session.sh — (re)create a fleet's resting window, `home`: a plain shell in
# $HOME that the task list draws beside (fleet_view.py), at the lowest index.
# Idempotent PER SESSION: an existing home (by role, not name — issue #1844) is
# just selected. It is not a list of its own — nothing refreshes in it — but a
# session needs a window that outlives its tasks, or the last one to close would
# take the fleet and its server with it. `home` is a panel like plan/dash/backlog
# everywhere a window is counted, snapshotted or listed as a session.
#
# The old full-screen dash hub (`plan`, issue #1533's way back) went with the
# dash (issue #4902). It never spawns a Claude session: the
# operator runs their own `claude` in whatever window they choose.
#
# The @hub pane marker is deliberately KEPT (fleet_mark_role, fleet_hub_pane,
# FLEET_HUB) even though nothing sets it automatically any more — mark a pane by
# hand (`tmux set-option -p @hub 1`, or run with FLEET_HUB=1) and it still gets
# the session-end-hook bail and the 'operator' provenance stamp.
#
# Multi-fleet (a fleet ≡ a tmux session, hosting one or more repos): SESS defaults to the CURRENT
# session so every fleet gets its OWN home, and BASE defaults to $HOME (issue
# #1941 — a fleet has no main repo). Both overridable via HUB_SESSION / HUB_CWD —
# fleet-up.sh passes them explicitly when it builds a fresh fleet.
#
# Window names are NOT unique in tmux, so nothing below targets "$SESS:home" by
# name — everything targets by window_id.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

SESS="${HUB_SESSION:-$(fleet_current_session)}"
# Last resort (run outside tmux, no session given): the login's one fleet
# (issue #979), else the name fleet-up.sh gives a brand-new fleet.
[ -z "$SESS" ] && SESS="$(fleet_login_fleet 2>/dev/null)"
[ -z "$SESS" ] && SESS=fleet
# This fleet's own tmux server socket (== session name, issue #159). Named on
# EVERY tmux call so the hub is built on the right socket whether we're invoked
# from fleet-up (no $TMUX) or from a zoom bind inside the fleet ($TMUX set) — the
# explicit -L resolves to the same socket either way.
SOCK=$(fleet_socket "$SESS")
# BASE: the explicit override, else $HOME — however many repos the fleet hosts
# (issues #795, #1941). A fleet has no main repo, so a shell or claude the
# operator opens beside the task list lands in $HOME, never inside one repo's
# base checkout — and adding a second repo moves nothing.
fleet_load_conf "$SESS"
BASE="${HUB_CWD:-$HOME}"

# HUB_PRINT_CMD: a debug seam (hub-session-selftest.sh) — print what would open
# (`cwd`: where) and exit before any tmux call.
if [ -n "${HUB_PRINT_CMD:-}" ]; then
  if [ "$HUB_PRINT_CMD" = cwd ]; then printf '%s\n' "$BASE"; else printf 'home\n'; fi
  exit 0
fi
# By role, not name (issue #1844): a home the person renamed is still home.
win=$(tmux -L "$SOCK" list-windows -t "$SESS" -F "#{window_id} $FLEET_ROLE_FMT" 2>/dev/null \
      | awk "$FLEET_ROLE_AWK"' { t=$0; sub(/^[^ ]* /, "", t) } frole(t)=="home" {print $1; exit}')
if [ -z "$win" ]; then
  win=$(tmux -L "$SOCK" new-window -P -F '#{window_id}' -t "$SESS:" -n home -c "$BASE") || exit 0
  # A name tmux's automatic-rename must not change: the panel rules key on it.
  tmux -L "$SOCK" set-window-option -t "$win" automatic-rename off 2>/dev/null
  if tmux -L "$SOCK" list-windows -t "$SESS" -F '#{window_index}' | grep -qx 1; then
    tmux -L "$SOCK" swap-window -d -s "$win" -t "$SESS:1" 2>/dev/null
  else
    tmux -L "$SOCK" move-window -d -s "$win" -t "$SESS:1" 2>/dev/null
  fi
fi
fleet_home_resident "$SOCK" "$SESS" "$win"   # its shell exiting never closes it (#1784)
tmux -L "$SOCK" select-window -t "$win"
exit 0
