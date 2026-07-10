#!/bin/bash
# steward-session.sh — (re)create the HUB for a fleet: the plan window with the
# dash on top (40%) and the persistent steward Claude session below, in the
# fleet's base checkout. Idempotent PER SESSION: if a @steward-marked pane
# already exists IN THIS SESSION, just jump to it. This is prefix+g's fallback
# (steward-zoom.sh), so an accidentally closed hub window is one keypress from
# restored. The steward picks up its standing orders from ~/.claude/steward.md
# and the latest handoff doc if one exists.
#
# Multi-fleet (a fleet ≡ a tmux session ≡ one repo): SESS defaults to the CURRENT
# session so every fleet gets its OWN hub, and BASE defaults to that fleet's
# FLEET_MAIN (its per-session conf). Both overridable via STEWARD_SESSION /
# STEWARD_CWD — fleet-up.sh passes them explicitly when it builds a fresh fleet.
#
# IMPORTANT: window names are NOT unique in tmux, so we NEVER target "$SESS:plan"
# by name — a second 'plan' window makes that reference ambiguous, which is how
# earlier versions piled up orphan 'plan' windows and left you on the wrong one
# with no steward. Everything below targets by window_id / pane_id.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

SESS="${STEWARD_SESSION:-$(fleet_current_session)}"
# Last resort (run outside tmux, no session given): the global primary fleet,
# named by the same 'fleet-<repo>' standard fleet-up.sh uses.
[ -z "$SESS" ] && SESS="fleet-$(basename "${FLEET_REPO:-primary}")"
# BASE: explicit override → this fleet's FLEET_MAIN (per-session conf) →
# the session's first window cwd → HOME.
if [ -n "${STEWARD_CWD:-}" ]; then
  BASE="$STEWARD_CWD"
  fleet_load_conf "$SESS"   # pick up FLEET_STEWARD_CMD; BASE stays pinned above
else
  fleet_load_conf "$SESS"
  BASE="${FLEET_MAIN:-}"
  [ -z "$BASE" ] && BASE=$(tmux list-windows -t "$SESS" -F '#{pane_current_path}' 2>/dev/null | awk 'NF{print; exit}')
  [ -z "$BASE" ] && BASE="$HOME"
fi
# The command the steward pane runs. The FRESH launch is the steward's normal
# startup: a documented per-fleet FLEET_STEWARD_CMD override if set, else the
# built-in that reads its standing orders from steward.md and picks up the newest
# handoff. FRESH_INNER is that launch WITHOUT the pane-keep-alive `exec $SHELL`
# tail (appended once below) so it can double as the resume fallback.
FRESH_INNER="${FLEET_STEWARD_CMD:-claude \"Read ~/.claude/steward.md and adopt it: you are the ON-DEMAND steward for THIS fleet (default scope = your bound repo only). If ~/.claude/handoff/ has a recent steward handoff for this fleet, /handoff pick up the newest one. Do NOT run /sweep and do NOT arm /loop — there is no periodic sweep. Stay quiet until asked.\"}"
# Crash-resume (issue #143): if fleet-restore.sh captured this steward's live
# transcript and passes its id via STEWARD_RESUME_ID, RESUME it (`claude --resume
# <id>`) so the steward's full history survives a tmux-server crash — same as a
# worker. Resume is PRIMARY (it beats FLEET_STEWARD_CMD, matching what restore
# announces), but if the resume FAILS (stale/pruned id) fall back to the fresh
# launch with `||` — never leave a bare shell with no steward (which would be
# strictly worse than the pre-#143 always-fresh behaviour). No id → just fresh.
# NB: a successful resume already carries the steward.md adoption in its restored
# history, so it stays correctly scoped without re-reading steward.md.
if [ -n "${STEWARD_RESUME_ID:-}" ] && [ "${STEWARD_RESUME_ID}" != "-" ]; then
  LAUNCH="claude --resume '${STEWARD_RESUME_ID}' || { ${FRESH_INNER}; }"
else
  LAUNCH="$FRESH_INNER"
fi
# An explicit STEWARD_CMD in the environment (fleet-up.sh's internal contract)
# still overrides everything; otherwise run LAUNCH and keep the pane as a shell.
STEWARD_CMD="${STEWARD_CMD:-$LAUNCH; exec \$SHELL}"

# already have a live steward pane IN THIS SESSION → just focus it, done. Scoped
# with -s (not -a) so a fresh fleet builds its own hub instead of jumping to
# another fleet's steward.
existing=$(fleet_steward_pane "$SESS")
if [ -n "$existing" ]; then
  tmux select-window -t "$existing"; tmux select-pane -t "$existing"; exit 0
fi

# No steward pane in this session → no 'plan' window here holds anything precious
# (their dash pane is just a respawnable `bash tmux-dashboard.sh`). Nuke ALL
# 'plan' windows IN THIS SESSION so we rebuild exactly one hub — this also
# self-heals any accumulated orphans.
for wid in $(tmux list-windows -t "$SESS" -F '#{window_id} #{window_name}' | awk '$2=="plan"{print $1}'); do
  tmux kill-window -t "$wid" 2>/dev/null
done

# build the hub fresh, capturing IDs so every op hits THIS window/pane.
win=$(tmux new-window -P -F '#{window_id}' -t "$SESS:" -n plan -c "$BASE" "bash '$BIN/tmux-dashboard.sh'")
sp=$(tmux split-window -P -F '#{pane_id}' -v -l 60% -t "$win" -c "$BASE" "$STEWARD_CMD")
# Mark the steward pane by its explicit id (never the active pane) and clear any
# @dash on it — @dash/@steward must stay mutually exclusive (issue #135).
fleet_mark_role steward "$sp" 2>/dev/null || \
  tmux set-option -p -t "$sp" @steward 1 2>/dev/null
# Hub cue: show the top pane-border title on JUST this window (the conf keeps it
# off globally to spare worker panes a row). pane-border-format (in the conf)
# labels the @steward pane "▸ STEWARD HUB · <fleet>" — visible even when the pane
# is zoomed fullscreen (prefix+g), where the window list is the only other cue.
tmux set-window-option -t "$win" pane-border-status top 2>/dev/null

# hub belongs at the lowest index (slot 1). Nothing re-sorts windows anymore,
# so this one-time placement is what keeps the hub at slot 1.
if tmux list-windows -t "$SESS" -F '#{window_index}' | grep -qx 1; then
  tmux swap-window -d -s "$win" -t "$SESS:1" 2>/dev/null
else
  tmux move-window -d -s "$win" -t "$SESS:1" 2>/dev/null
fi
tmux select-window -t "$win"
tmux select-pane -t "$sp"
exit 0
