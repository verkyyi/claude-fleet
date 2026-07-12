#!/bin/bash
# fleet-handoff-cycle.sh — the detached, self-terminating half of /fleet-handoff.
#
# Armed as the LAST tool call of a /fleet-handoff (cycle mode) turn:
#
#     nohup ~/.claude/fleet/bin/fleet-handoff-cycle.sh --pane "$TMUX_PANE" \
#           --doc <abs-path> >/dev/null 2>&1 &
#
# It outlives that turn and drives the context-clear + resume the arming session
# cannot do to itself: WAIT for the arming turn to end (@claude_state leaves
# `working`), then `/clear` the pane, verify a fresh session, and type
# `/fleet-handoff pickup <doc>` so the emptied session resumes from the doc.
#
# It runs OUTSIDE any pane (nohup+disown), but is LAUNCHED from inside one, so it
# inherits $TMUX and bare `tmux` targets that fleet's own server/socket (issue
# #159). Pass --socket to override (used by nothing in production; handy for tests).
#
# DESIGN INVARIANTS (see issue #273):
#   • Wait-for-Stop, never send-during-turn — keys typed mid-turn queue with
#     undefined interleaving, so gate every keystroke on @claude_state != working
#     (the Stop hook fired = the arming turn ended), exactly like the issue-bridge
#     idle-gate. On the never-idle timeout we ABORT *without clearing*.
#   • Fail-safe ordering — every failure degrades to "doc written, context not
#     cleared": the doc is written+verified by the skill BEFORE this is armed; we
#     abort rather than clear a busy/gone pane; and if the post-clear verify fails
#     we do NOT type pickup (a lost pickup still leaves the operator a manual
#     `/fleet-handoff pickup <doc>`).
#   • Never an immortal orphan (the crash-#3 lesson) — a hard overall self-timeout
#     TERMs the whole process group even if a phase wedges; the runaway-CPU
#     watchdog is the backstop, not the plan.
#
# Exit 0 = the cycle ran to the point it intended (pickup sent, OR a fail-safe
# abort that left the doc intact). Non-zero = a validation refusal.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -r "$BIN/fleet-lib.sh" ] && . "$BIN/fleet-lib.sh" 2>/dev/null || true

# --- tunables (env-overridable; the selftest drives them tiny for speed) --------
IDLE_TIMEOUT="${FLEET_HANDOFF_IDLE_TIMEOUT:-120}"   # wait-idle ceiling (s)
VERIFY_TIMEOUT="${FLEET_HANDOFF_VERIFY_TIMEOUT:-10}" # fresh-session detect (s)
HARD_TIMEOUT="${FLEET_HANDOFF_HARD_TIMEOUT:-300}"    # overall self-kill (s) — ≤5min
POLL="${FLEET_HANDOFF_POLL:-2}"                      # poll interval (s)
PICKUP_CMD="${FLEET_HANDOFF_PICKUP_CMD:-/fleet-handoff pickup}"
LOG_DIR="${FLEET_HANDOFF_LOG_DIR:-$HOME/.claude/fleet/logs}"

PANE='' DOC='' SOCKET=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pane)   PANE="${2:-}"; shift 2 ;;
    --doc)    DOC="${2:-}"; shift 2 ;;
    --socket) SOCKET="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/handoff-cycle.log"

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)" "${PANE:-?}" "$*" >> "$LOG" 2>/dev/null || true; }

# bare tmux honours the inherited $TMUX (the arming pane's server); --socket wins.
TM() { if [ -n "$SOCKET" ]; then tmux -L "$SOCKET" "$@"; else tmux "$@"; fi; }

# A visible, non-fatal notice on the pane's status line, plus the log.
notify() { log "$*"; TM display-message -t "$PANE" "fleet-handoff: $*" 2>/dev/null || true; }

# A validation refusal: log, notify, and exit non-zero (nothing destructive ran).
refuse() { log "REFUSE: $*"; TM display-message -t "$PANE" "fleet-handoff: $*" 2>/dev/null || true; exit 1; }

nap() { sleep "$POLL" 2>/dev/null || sleep 1; }

# ============================ 1. VALIDATE ======================================
[ -n "$PANE" ] || { log "REFUSE: no --pane"; exit 1; }
[ -n "$DOC" ]  || refuse "no --doc handoff path given"
# Inside tmux (bare) or an explicit socket — else there is nothing to drive.
[ -n "$SOCKET" ] || [ -n "${TMUX:-}" ] || refuse "not inside tmux (no \$TMUX and no --socket)"
# The doc MUST exist and be non-empty — never arm/clear around an empty handoff.
[ -s "$DOC" ] || refuse "handoff doc missing or empty: $DOC"
# The pane must be alive (a dead pane = nothing to clear/resume).
TM display-message -p -t "$PANE" '#{pane_id}' >/dev/null 2>&1 \
  || refuse "target pane $PANE is gone"

# Per-pane lock — a second arm while one cycle is pending must REFUSE (never race
# two clears at one pane). A stale lock (dead pid) is reclaimed.
pane_san="${PANE//[^A-Za-z0-9]/_}"
LOCK="$LOG_DIR/handoff-cycle-${pane_san}.lock"
if [ -e "$LOCK" ]; then
  oldpid="$(cat "$LOCK" 2>/dev/null)"
  if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
    refuse "a handoff cycle (pid $oldpid) is already pending for $PANE — refusing double-arm"
  fi
  log "reclaiming stale lock (pid ${oldpid:-?} dead)"
fi
printf '%s\n' "$$" > "$LOCK" 2>/dev/null || true

# ---- hard self-timeout: never an immortal orphan (crash-#3). A watchdog TERMs
# ---- this whole process even if a phase wedges; killed on normal exit.
( sleep "$HARD_TIMEOUT" 2>/dev/null; kill -TERM "$$" 2>/dev/null ) &
WATCHDOG=$!
cleanup() { rm -f "$LOCK" 2>/dev/null || true; kill "$WATCHDOG" 2>/dev/null || true; }
trap cleanup EXIT
trap 'log "TERM (hard timeout ${HARD_TIMEOUT}s or signal) — exiting; doc left intact"; exit 0' TERM

log "armed: doc=$DOC pane=$PANE socket=${SOCKET:-\$TMUX} idle_to=${IDLE_TIMEOUT}s hard_to=${HARD_TIMEOUT}s"

# ============================ 2. WAIT-IDLE =====================================
# The arming turn is still running (this was its last tool call). Wait until the
# Stop hook flips @claude_state off `working` (turn ended). `done` is the normal
# terminal state; `needs`/`looping` also mean the turn ended, so any non-working,
# non-empty state satisfies the gate. Timeout ⇒ ABORT WITHOUT CLEARING.
idle=0 idl_deadline=$(( $(date +%s 2>/dev/null || echo 0) + IDLE_TIMEOUT ))
while [ "$(date +%s 2>/dev/null || echo 0)" -lt "$idl_deadline" ]; do
  st="$(TM display-message -p -t "$PANE" '#{@claude_state}' 2>/dev/null)"
  case "$st" in
    working|'') : ;;                 # still in-turn (or not yet stamped) — keep waiting
    *) idle=1; log "arming turn ended (@claude_state=$st)"; break ;;
  esac
  nap
done
if [ "$idle" != 1 ]; then
  notify "arming turn never went idle within ${IDLE_TIMEOUT}s — NOT clearing (doc saved at $DOC)"
  exit 0   # fail-safe: doc intact, context untouched
fi

# ============================ 3. CLEAR =========================================
# Escape first (dismiss any open TUI menu/palette), then type `/clear`, then a
# SEPARATE Enter — text and Enter as distinct send-keys calls so the string is
# typed into the input line and Enter is what executes the slash command (a
# combined send-keys would submit early / mis-fire the palette).
log "clearing pane $PANE"
TM send-keys -t "$PANE" Escape 2>/dev/null || true
sleep 0.3 2>/dev/null || true
TM send-keys -t "$PANE" -l -- "/clear" 2>/dev/null || true
TM send-keys -t "$PANE" Enter 2>/dev/null || true

# ============================ 4. VERIFY ========================================
# Poll capture-pane until the fresh (post-clear) session UI shows — bounded. The
# cleared Claude TUI drops the prior transcript and redraws the empty input row
# (`❯`/`>`) and its shortcut hint. If it never confirms within the bound we do
# NOT type pickup (fail-safe: the operator still has a manual pickup).
log "verifying fresh session (≤${VERIFY_TIMEOUT}s)"
fresh=0 vf_deadline=$(( $(date +%s 2>/dev/null || echo 0) + VERIFY_TIMEOUT ))
while [ "$(date +%s 2>/dev/null || echo 0)" -lt "$vf_deadline" ]; do
  cap="$(TM capture-pane -p -t "$PANE" 2>/dev/null)"
  # Fresh signals, any one is enough (TUI-version tolerant): the empty prompt row,
  # the shortcut hint, or the welcome banner — AND the `/clear` we typed is gone
  # (the command was consumed, not still sitting half-typed in the palette).
  if printf '%s' "$cap" | grep -Eq '(^|[[:space:]])(❯|>)[[:space:]]|for shortcuts|Welcome to Claude'; then
    if ! printf '%s' "$cap" | grep -q '/clear'; then fresh=1; break; fi
  fi
  sleep 0.5 2>/dev/null || true
done
if [ "$fresh" != 1 ]; then
  notify "could not confirm a fresh session after /clear — resume manually: $PICKUP_CMD $DOC"
  exit 0   # fail-safe: cleared but pickup withheld; manual pickup still works
fi

# ============================ 5. PICKUP ========================================
# Type the pickup command + a SEPARATE Enter (same bracketed-paste discipline) so
# the emptied session's FIRST turn is `/fleet-handoff pickup <doc>` and it resumes
# from the doc's NEXT ACTION.
log "sending pickup: $PICKUP_CMD $DOC"
TM send-keys -t "$PANE" -l -- "$PICKUP_CMD $DOC" 2>/dev/null || true
TM send-keys -t "$PANE" Enter 2>/dev/null || true

log "cycle complete — pane $PANE cleared and resumed from $DOC"
exit 0
