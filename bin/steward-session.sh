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
else
  fleet_load_conf "$SESS"
  BASE="${FLEET_MAIN:-}"
  [ -z "$BASE" ] && BASE=$(tmux list-windows -t "$SESS" -F '#{pane_current_path}' 2>/dev/null | awk 'NF{print; exit}')
  [ -z "$BASE" ] && BASE="$HOME"
fi
STEWARD_CMD="${STEWARD_CMD:-claude \"Read ~/.claude/steward.md and adopt it: you are the steward session. If ~/.claude/handoff/ has a recent steward handoff, /handoff pick up the newest one first; otherwise run one /sweep now. Then arm /loop 45m /sweep.\"; exec \$SHELL}"

# already have a live steward pane IN THIS SESSION → just focus it, done. Scoped
# with -s (not -a) so a fresh fleet builds its own hub instead of jumping to
# another fleet's steward.
existing=$(tmux list-panes -s -t "$SESS" -F '#{pane_id} #{@steward}' 2>/dev/null | awk '$2=="1"{print $1; exit}')
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
win=$(tmux new-window -P -F '#{window_id}' -t "$SESS:" -n plan -c "$HOME/.claude" "bash '$BIN/tmux-dashboard.sh'")
sp=$(tmux split-window -P -F '#{pane_id}' -v -l 60% -t "$win" -c "$BASE" "$STEWARD_CMD")
tmux set-option -p -t "$sp" @steward 1 2>/dev/null

# hub belongs at the lowest index (the urgency sorter pins slot 1)
if tmux list-windows -t "$SESS" -F '#{window_index}' | grep -qx 1; then
  tmux swap-window -d -s "$win" -t "$SESS:1" 2>/dev/null
else
  tmux move-window -d -s "$win" -t "$SESS:1" 2>/dev/null
fi
tmux select-window -t "$win"
tmux select-pane -t "$sp"
exit 0
