#!/bin/sh
# fleet-compact-send.sh <pane> [<map-file>] — type `/compact <keep the recovery map>`
# into a worker pane once its turn has ended (issue #1269, EPIC #1262 R1).
#
# Step 2 of the in-place compaction the Stop hook (bin/set-claude-state.sh) drives:
#
#   prep        at a clean Stop with @ctx_pct in [FLEET_COMPACT_PREP_PCT, handoff %)
#               the hook blocks the stop and asks the worker to write a recovery
#               map (issue, branch, PR, next step) — @compact_stage=prep
#   compacting  at the NEXT clean Stop (the map is written, the pane is idle) the
#               hook spawns THIS script detached; it types `/compact …` — stage
#               flips to compacting just before the keystrokes
#   restored    SessionStart(source=compact) → bin/refocus-hook.sh re-states the
#               charter, adds a "check the map" line, and stamps restored
#
# Why a detached script and not the hook itself: a Stop hook still OWNS the turn
# while it runs, and keystrokes typed then race the TUI's own redraw. This waits a
# short grace, then types only while @claude_state is not `working` — the same
# idle gate bin/fleet-handoff-cycle.sh uses before its `/clear`.
#
# Operator-typing hold (issue #571): a client whose current window is this one with
# a keypress within FLEET_HANDOFF_DEFER_SECS holds the keystrokes (Esc + text into
# a half-written draft would submit the draft with "/compact" glued on). Still held
# at the deadline ⇒ give up WITHOUT typing; @compact_stage stays `prep`, so the next
# clean Stop re-spawns this (the hook paces that to once per 60 s). A turn that
# starts meanwhile (@claude_state=working) or a stage someone else moved also gives
# up. Bounded: never runs past FLEET_COMPACT_SEND_TIMEOUT (default 90 s).
#
# Text and Enter go as SEPARATE send-keys calls (bracketed paste eats an inline
# Enter); FLEET_ALLOW_SENDKEYS=1 marks this as sanctioned fleet plumbing (#437).
# Always exits 0.
set -u
PANE="${1:-}"
MAP="${2:-}"
[ -n "$PANE" ] || exit 0
GRACE="${FLEET_COMPACT_SEND_GRACE:-2}"
TIMEOUT="${FLEET_COMPACT_SEND_TIMEOUT:-90}"
DEFER="${FLEET_HANDOFF_DEFER_SECS:-30}"
case "$GRACE" in ''|*[!0-9]*) GRACE=2 ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=90 ;; esac
case "$DEFER" in ''|*[!0-9]*) DEFER=30 ;; esac

opt() { tmux display-message -p -t "$PANE" "#{$1}" 2>/dev/null; }

sleep "$GRACE"
deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  [ "$(opt @compact_stage)" = prep ] || exit 0           # moved on / already sent
  st=$(opt @claude_state)
  [ "$st" = working ] && exit 0                           # a new turn started: not idle
  held=''
  if [ "$DEFER" -gt 0 ]; then
    wid=$(opt window_id); now=$(date +%s)
    [ -n "$wid" ] && held=$(tmux list-clients -F '#{client_activity} #{window_id}' 2>/dev/null \
      | awk -v w="$wid" -v now="$now" -v ds="$DEFER" \
          '$2 == w && $1 ~ /^[0-9]+$/ && (now - $1) <= ds { print 1; exit }')
  fi
  [ "$held" = 1 ] || break
  [ "$(date +%s)" -lt "$deadline" ] || exit 0             # operator still typing: next Stop retries
  sleep 2
done

keep='Keep the fleet RECOVERY MAP verbatim (issue, branch, PR, done, in progress, next steps)'
[ -n "$MAP" ] && keep="$keep; it is also saved at $MAP"
# Stage FIRST: the SessionStart(compact) hook keys on `compacting`, and a fast
# compaction must never beat the stamp.
tmux set-window-option -t "$PANE" @compact_stage compacting 2>/dev/null
tmux set-window-option -t "$PANE" @compact_ts "$(date +%s)" 2>/dev/null
FLEET_ALLOW_SENDKEYS=1 tmux send-keys -t "$PANE" Escape 2>/dev/null
sleep 0.3 2>/dev/null || sleep 1
FLEET_ALLOW_SENDKEYS=1 tmux send-keys -t "$PANE" -l -- "/compact $keep" 2>/dev/null
sleep 0.3 2>/dev/null || sleep 1
FLEET_ALLOW_SENDKEYS=1 tmux send-keys -t "$PANE" Enter 2>/dev/null
exit 0
