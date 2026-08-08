#!/bin/bash
# hub-session.sh — (re)create the HUB for a fleet: the plan window, holding the
# dash and NOTHING ELSE. Idempotent PER SESSION: if a @dash-marked pane already
# exists IN THIS SESSION, just jump to it. This is F9's fallback (hub-zoom.sh),
# so an accidentally closed hub window is one keypress from restored.
#
# The hub is DASH-ONLY — it never spawns a Claude session. Earlier versions split
# a persistent `claude` in below the dash (the "hub pane", issue #439, itself the
# successor to the steward seat). That pane came back on its OWN, unasked: the ⌂
# home tap, F9 and prefix+g all fall back here when they find no pane to focus,
# and `fleet-up`/`fleet-restore` rebuilt it on every fresh fleet and every crash
# recovery. An operator who closed it got it back on the next tap. It is gone: the
# operator runs their own `claude` in whatever window they choose, and NO key,
# tap, spawn or restore path re-creates one.
#
# The @hub pane marker is deliberately KEPT (fleet_mark_role, fleet_hub_pane,
# FLEET_HUB) even though nothing sets it automatically any more — mark a pane by
# hand (`tmux set-option -p @hub 1`, or run with FLEET_HUB=1) and it still gets
# the cw.zsh kill-window exemption (#177/#202), the session-end-hook bail and the
# 'operator' provenance stamp. Nothing about those rails changed.
#
# Multi-fleet (a fleet ≡ a tmux session ≡ one repo): SESS defaults to the CURRENT
# session so every fleet gets its OWN hub, and BASE defaults to that fleet's
# FLEET_MAIN (its per-session conf). Both overridable via HUB_SESSION / HUB_CWD —
# fleet-up.sh passes them explicitly when it builds a fresh fleet.
#
# IMPORTANT: window names are NOT unique in tmux, so we NEVER target "$SESS:plan"
# by name — a second 'plan' window makes that reference ambiguous, which is how
# earlier versions piled up orphan 'plan' windows and left you on the wrong one
# with no hub. Everything below targets by window_id / pane_id.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

SESS="${HUB_SESSION:-$(fleet_current_session)}"
# Last resort (run outside tmux, no session given): the global primary fleet,
# named by the same 'fleet-<repo>' standard fleet-up.sh uses.
[ -z "$SESS" ] && SESS="fleet-$(basename "${FLEET_REPO:-primary}")"
# This fleet's own tmux server socket (== session name, issue #159). Named on
# EVERY tmux call so the hub is built on the right socket whether we're invoked
# from fleet-up (no $TMUX) or from a zoom bind inside the fleet ($TMUX set) — the
# explicit -L resolves to the same socket either way.
SOCK=$(fleet_socket "$SESS")
# BASE: explicit override → this fleet's FLEET_MAIN (per-session conf) →
# the session's first window cwd → HOME.
if [ -n "${HUB_CWD:-}" ]; then
  BASE="$HUB_CWD"
  fleet_load_conf "$SESS"   # per-fleet conf; BASE stays pinned above
else
  fleet_load_conf "$SESS"
  BASE="${FLEET_MAIN:-}"
  [ -z "$BASE" ] && BASE=$(tmux -L "$SOCK" list-windows -t "$SESS" -F '#{pane_current_path}' 2>/dev/null | awk 'NF{print; exit}')
  [ -z "$BASE" ] && BASE="$HOME"
fi

# The ONLY command the hub runs: the dashboard. There is no second pane and no
# `claude` launch here any more, so FLEET_HUB_CMD / HUB_RESUME_ID / HUB_CMD are
# gone with it — a hub has no transcript to resume, and no env to inject.
DASH_CMD="bash '$BIN/tmux-dashboard.sh'"

# Debug seam: print the fully-resolved launch command and exit BEFORE any tmux
# spawn, so the launch logic (hub-session-selftest.sh) can be asserted
# hermetically without a live tmux/dash. Never set in normal use.
if [ -n "${HUB_PRINT_CMD:-}" ]; then
  printf '%s\n' "$DASH_CMD"
  exit 0
fi

# already have a live dash pane IN THIS SESSION → just focus it, done. Scoped
# with -s (not -a) so a fresh fleet builds its own hub instead of jumping to
# another fleet's hub. Keys on @dash (not @hub): the dash IS the hub now.
existing=$(fleet_dash_pane "$SESS")   # socket-aware (issue #159)
if [ -n "$existing" ]; then
  tmux -L "$SOCK" select-window -t "$existing"; tmux -L "$SOCK" select-pane -t "$existing"; exit 0
fi

# No dash pane in this session → no 'plan' window here holds anything precious
# (its dash pane is just a respawnable `bash tmux-dashboard.sh`). Nuke ALL
# 'plan' windows IN THIS SESSION so we rebuild exactly one hub — this also
# self-heals any accumulated orphans.
for wid in $(tmux -L "$SOCK" list-windows -t "$SESS" -F '#{window_id} #{window_name}' | awk '$2=="plan"{print $1}'); do
  tmux -L "$SOCK" kill-window -t "$wid" 2>/dev/null
done

# Build the hub fresh, capturing the window id so every op hits THIS window. ONE
# pane: the dash, full height. No split-window follows — that split is exactly the
# self-restoring Claude pane this script no longer creates. The dash pane's
# `tmux-dashboard.sh` runs ON this socket (tmux new-window inherits it via $TMUX),
# so it self-marks @dash correctly with bare tmux.
win=$(tmux -L "$SOCK" new-window -P -F '#{window_id}' -t "$SESS:" -n plan -c "$BASE" "$DASH_CMD")
# Re-affirm the top pane-border on this window. Since issue #267 the conf sets
# pane-border-status top GLOBALLY (every window shows a top-of-window header), so
# this is now a redundant safety net for a hub built before that conf is live.
# pane-border-format (in the conf) renders the @dash pane's header EMPTY, so a
# dash-only hub shows a bare border — the window name in the status list is the cue.
tmux -L "$SOCK" set-window-option -t "$win" pane-border-status top 2>/dev/null

# hub belongs at the lowest index (slot 1). Nothing re-sorts windows anymore,
# so this one-time placement is what keeps the hub at slot 1.
if tmux -L "$SOCK" list-windows -t "$SESS" -F '#{window_index}' | grep -qx 1; then
  tmux -L "$SOCK" swap-window -d -s "$win" -t "$SESS:1" 2>/dev/null
else
  tmux -L "$SOCK" move-window -d -s "$win" -t "$SESS:1" 2>/dev/null
fi
tmux -L "$SOCK" select-window -t "$win"
exit 0
