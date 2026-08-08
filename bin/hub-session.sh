#!/bin/bash
# hub-session.sh — (re)create the HUB for a fleet: the plan window with the dash
# on top (40%) and a plain, persistent Claude session below, in the fleet's base
# checkout. Idempotent PER SESSION: if a @hub-marked pane already exists IN THIS
# SESSION, just jump to it. This is F9's fallback (hub-zoom.sh), so an
# accidentally closed hub window is one keypress from restored.
#
# The bottom pane is the OPERATOR's own Claude session (issue #439) — a bare
# `claude` in the base checkout, no seed prompt, no charter, no settings profile.
# The fleet is operator-driven: you file, spawn, hand back and land from here,
# with `/fleet-*` skills and the dash right above. The base checkout stays
# edit-read-only for every seat (hooks/base-readonly-guard.py), so the hub can
# read and drive the fleet without ever committing to it.
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
  fleet_load_conf "$SESS"   # pick up FLEET_HUB_CMD; BASE stays pinned above
else
  fleet_load_conf "$SESS"
  BASE="${FLEET_MAIN:-}"
  [ -z "$BASE" ] && BASE=$(tmux -L "$SOCK" list-windows -t "$SESS" -F '#{pane_current_path}' 2>/dev/null | awk 'NF{print; exit}')
  [ -z "$BASE" ] && BASE="$HOME"
fi

# The command the hub pane runs. The FRESH launch is a plain `claude` — the
# operator's own session, with whatever model/MCP/settings their normal claude
# config gives them (no fleet-injected flags, issue #439). A documented per-fleet
# FLEET_HUB_CMD override replaces it wholesale. FRESH_INNER is that launch WITHOUT
# the pane-keep-alive `exec $SHELL` tail (appended once below) so it can double as
# the resume fallback.
FRESH_INNER="${FLEET_HUB_CMD:-claude}"
# Crash-resume (issue #143): if fleet-restore.sh captured this hub's live
# transcript and passes its id via HUB_RESUME_ID, RESUME it (`claude --resume
# <id>`) so the operator's full history survives a tmux-server crash — same as a
# worker. Resume is PRIMARY (it beats FLEET_HUB_CMD, matching what restore
# announces), but if the resume FAILS (stale/pruned id) fall back to the fresh
# launch with `||` — never leave a bare shell with no hub session. No id → fresh.
if [ -n "${HUB_RESUME_ID:-}" ] && [ "${HUB_RESUME_ID}" != "-" ]; then
  LAUNCH="claude --resume '${HUB_RESUME_ID}' || { ${FRESH_INNER}; }"
else
  LAUNCH="$FRESH_INNER"
fi
# An explicit HUB_CMD in the environment (fleet-up.sh's internal contract) still
# overrides everything; otherwise run LAUNCH and keep the pane as a shell.
HUB_CMD="${HUB_CMD:-$LAUNCH; exec \$SHELL}"
# Durable hub marker (issue #202): export FLEET_HUB=1 into the pane's command so
# the operator's claude AND every Bash-tool shell it spawns inherit it —
# independent of whether tmux re-exports $TMUX_PANE per shell (that per-shell
# export proved unreliable, intermittently refusing the hub's own kill-window
# under the #185 strict-$TMUX_PANE guard). The tmux() destroy-guard in
# shell/cw.zsh treats this env as the PRIMARY hub signal. A worker spawn
# (dash-issue-session.sh) never sets it, so #158 is untouched. Prepended to the
# FINAL command so it applies to fresh, resume, and override alike.
HUB_CMD="export FLEET_HUB=1; $HUB_CMD"

# Debug seam: print the fully-resolved launch command and exit BEFORE any tmux
# spawn, so the launch logic (hub-session-selftest.sh) can be asserted
# hermetically without a live claude/hub. Never set in normal use.
if [ -n "${HUB_PRINT_CMD:-}" ]; then
  printf '%s\n' "$HUB_CMD"
  exit 0
fi

# already have a live hub pane IN THIS SESSION → just focus it, done. Scoped
# with -s (not -a) so a fresh fleet builds its own hub instead of jumping to
# another fleet's hub.
existing=$(fleet_hub_pane "$SESS")   # socket-aware (issue #159)
if [ -n "$existing" ]; then
  tmux -L "$SOCK" select-window -t "$existing"; tmux -L "$SOCK" select-pane -t "$existing"; exit 0
fi

# No hub pane in this session → no 'plan' window here holds anything precious
# (their dash pane is just a respawnable `bash tmux-dashboard.sh`). Nuke ALL
# 'plan' windows IN THIS SESSION so we rebuild exactly one hub — this also
# self-heals any accumulated orphans.
for wid in $(tmux -L "$SOCK" list-windows -t "$SESS" -F '#{window_id} #{window_name}' | awk '$2=="plan"{print $1}'); do
  tmux -L "$SOCK" kill-window -t "$wid" 2>/dev/null
done

# build the hub fresh, capturing IDs so every op hits THIS window/pane. The dash
# pane's `tmux-dashboard.sh` runs ON this socket (tmux new-window inherits it via
# $TMUX), so it self-marks @dash correctly with bare tmux.
win=$(tmux -L "$SOCK" new-window -P -F '#{window_id}' -t "$SESS:" -n plan -c "$BASE" "bash '$BIN/tmux-dashboard.sh'")
sp=$(tmux -L "$SOCK" split-window -P -F '#{pane_id}' -v -l 60% -t "$win" -c "$BASE" "$HUB_CMD")
# Mark the hub pane by its explicit id (never the active pane) and clear any
# @dash on it — @dash/@hub must stay mutually exclusive (issue #135). Done
# inline (not via fleet_mark_role) because that helper uses bare tmux, which would
# hit the WRONG (default) socket when we're invoked from fleet-up outside $TMUX.
tmux -L "$SOCK" set-option -p -t "$sp" @hub 1  2>/dev/null || true
tmux -L "$SOCK" set-option -u -p -t "$sp" @dash 2>/dev/null || true
# Hub cue: re-affirm the top pane-border on this window. Since issue #267 the conf
# sets pane-border-status top GLOBALLY (every window shows a top-of-window header),
# so this is now a redundant safety net for a hub built before that conf is live.
# pane-border-format (in the conf) labels the @hub pane "▸ FLEET HUB · <fleet>"
# — visible even when the pane is zoomed fullscreen (F9), where the window
# list is the only other cue — while worker/scratch windows get an index:name+#issue
# header and the hub's dash pane stays empty.
tmux -L "$SOCK" set-window-option -t "$win" pane-border-status top 2>/dev/null

# hub belongs at the lowest index (slot 1). Nothing re-sorts windows anymore,
# so this one-time placement is what keeps the hub at slot 1.
if tmux -L "$SOCK" list-windows -t "$SESS" -F '#{window_index}' | grep -qx 1; then
  tmux -L "$SOCK" swap-window -d -s "$win" -t "$SESS:1" 2>/dev/null
else
  tmux -L "$SOCK" move-window -d -s "$win" -t "$SESS:1" 2>/dev/null
fi
tmux -L "$SOCK" select-window -t "$win"
tmux -L "$SOCK" select-pane -t "$sp"
exit 0
