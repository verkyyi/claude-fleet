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
# `/fleet-handoff pickup [<doc>]` so the emptied session resumes from the doc.
#
# Two storage modes for the handoff (issue #275) — exactly one is armed:
#   • --doc <abs-path>  FILE storage (raw scratch / no bound issue). The gate is
#     `-s <doc>`; the injected pickup carries the doc path.
#   • --issue <N>       COMMENT storage (the pane is issue-bound). The handoff was
#     posted as a `<!-- fleet:handoff -->`-marked comment on issue N (durable —
#     it survives the worktree teardown a committed doc/handoff/*.md does not).
#     The gate is "a marked comment is fetchable on issue N"; the injected pickup
#     is ARGUMENT-FREE (`/fleet-handoff pickup` self-resolves from the pane @issue).
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
#   • Fail-safe ordering — every failure degrades to "handoff stored, context not
#     cleared": the handoff is stored+verified (doc on disk, or marked comment on
#     the issue) BEFORE this is armed, and re-validated here BEFORE the first key;
#     we abort rather than clear a busy/gone pane; and if the post-clear verify
#     fails we do NOT type pickup (a lost pickup still leaves the operator a manual
#     `/fleet-handoff pickup [<doc>]`).
#   • Deterministic clear-verify (issue #345) — §4 confirms the /clear landed via a
#     marker (@handoff_cleared_at) the SessionStart(source=clear) hook stamps on this
#     same pane, NOT by screen-scraping the live TUI (glyph/banner text is
#     version-dependent and race-prone — the old scrape confirmed <1s on success but
#     burned the full timeout on failure ~50% of the time). The scrape is kept only
#     as a compat fallback (a fleet not yet synced to the marker-stamping hook), and
#     we retry the /clear ONCE before falling through to the fail-safe.
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
IDLE_TIMEOUT="${FLEET_HANDOFF_IDLE_TIMEOUT:-180}"   # wait-idle ceiling (s) — a big
                                                    # handoff turn can legitimately
                                                    # run >2min (#345 WAIT-IDLE miss);
                                                    # stays < HARD_TIMEOUT - VERIFY.
VERIFY_TIMEOUT="${FLEET_HANDOFF_VERIFY_TIMEOUT:-25}" # fresh-session detect (s) — the
                                                    # deterministic marker confirms in
                                                    # <1s; the wider window only backs
                                                    # the one /clear retry (#345).
RETRY_AFTER="${FLEET_HANDOFF_RETRY_AFTER:-8}"       # re-type /clear once if no fresh
                                                    # signal within this many s (a
                                                    # dropped keystroke, #345).
HARD_TIMEOUT="${FLEET_HANDOFF_HARD_TIMEOUT:-300}"    # overall self-kill (s) — ≤5min
POLL="${FLEET_HANDOFF_POLL:-2}"                      # poll interval (s)
PICKUP_CMD="${FLEET_HANDOFF_PICKUP_CMD:-/fleet-handoff pickup}"
LOG_DIR="${FLEET_HANDOFF_LOG_DIR:-$HOME/.claude/fleet/logs}"

HANDOFF_MARKER='<!-- fleet:handoff -->'   # pickup-lookup marker on a stored comment

PANE='' DOC='' ISSUE='' REPO='' SOCKET=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pane)   PANE="${2:-}"; shift 2 ;;
    --doc)    DOC="${2:-}"; shift 2 ;;
    --issue)  ISSUE="${2//[^0-9]/}"; shift 2 ;;
    --repo)   REPO="${2:-}"; shift 2 ;;
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
# Exactly one storage mode: --issue (comment) or --doc (file). --issue wins if both.
[ -n "$ISSUE" ] || [ -n "$DOC" ] || refuse "need --issue <N> (comment storage) or --doc <path> (file storage)"
# Inside tmux (bare) or an explicit socket — else there is nothing to drive.
[ -n "$SOCKET" ] || [ -n "${TMUX:-}" ] || refuse "not inside tmux (no \$TMUX and no --socket)"

# The handoff MUST be durably stored BEFORE we ever touch the pane — the whole
# fail-safe rests on this gate (never clear a session whose handoff can't be
# recovered). PICKUP is what the emptied session's first turn will type.
if [ -n "$ISSUE" ]; then
  # COMMENT storage (issue #275): the skill already posted the scrubbed handoff as
  # a `<!-- fleet:handoff -->`-marked comment on issue N. Re-confirm it is fetchable
  # (the equivalent of `-s "$DOC"` for a file). Repo: --repo → CF_REPO → this
  # fleet's cached repo → FLEET_REPO (mirrors bin/fleet-comment.sh).
  command -v gh >/dev/null 2>&1 || refuse "comment-storage handoff needs gh on PATH"
  repo="${REPO:-${CF_REPO:-${FLEET_REPO:-}}}"
  if [ -z "$repo" ]; then
    repo="$(fleet_repo_cached "$(fleet_current_session 2>/dev/null)" 2>/dev/null)"
  fi
  [ -n "$repo" ] || refuse "comment-storage handoff: no repo resolved (pass --repo or set FLEET_REPO)"
  gh issue view "$ISSUE" --repo "$repo" --json comments -q '.comments[].body' 2>/dev/null \
    | grep -Fq "$HANDOFF_MARKER" \
    || refuse "no fleet:handoff comment on issue #$ISSUE (@ $repo) — NOT clearing (handoff not durably stored)"
  STORE="issue #$ISSUE"
  PICKUP="$PICKUP_CMD"            # argument-free — the pane @issue self-resolves the comment
else
  # FILE storage: the doc must exist and be non-empty — never arm around an empty one.
  [ -s "$DOC" ] || refuse "handoff doc missing or empty: $DOC"
  STORE="$DOC"
  PICKUP="$PICKUP_CMD $DOC"       # the raw-scratch pane has no @issue → pass the path
fi

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

log "armed: store=$STORE pane=$PANE socket=${SOCKET:-\$TMUX} idle_to=${IDLE_TIMEOUT}s hard_to=${HARD_TIMEOUT}s"

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
  notify "arming turn never went idle within ${IDLE_TIMEOUT}s — NOT clearing (handoff saved: $STORE)"
  exit 0   # fail-safe: doc intact, context untouched
fi

# ============================ 3. CLEAR =========================================
# Escape first (dismiss any open TUI menu/palette), then type `/clear`, then a
# SEPARATE Enter — text and Enter as distinct send-keys calls so the string is
# typed into the input line and Enter is what executes the slash command (a
# combined send-keys would submit early / mis-fire the palette). Factored into a
# helper because §4 may retry it once on a dropped keystroke.
# FLEET_ALLOW_SENDKEYS=1 prefixes each send-keys: this is sanctioned fleet
# plumbing, exempt from the issue-bridge send-keys rail (issue #437). Prefixed,
# not exported, so nothing this cycle drives inherits the hatch.
send_clear() {
  FLEET_ALLOW_SENDKEYS=1 TM send-keys -t "$PANE" Escape 2>/dev/null || true
  sleep 0.3 2>/dev/null || true
  FLEET_ALLOW_SENDKEYS=1 TM send-keys -t "$PANE" -l -- "/clear" 2>/dev/null || true
  FLEET_ALLOW_SENDKEYS=1 TM send-keys -t "$PANE" Enter 2>/dev/null || true
}
# Stamp t0 BEFORE the keystroke: the deterministic verify (§4) accepts only a
# fresh-session marker stamped by THIS clear (@handoff_cleared_at >= clear_t0),
# never a stale one left by an earlier cycle at this pane.
clear_t0=$(date +%s 2>/dev/null || echo 0)
log "clearing pane $PANE"
send_clear

# ============================ 4. VERIFY ========================================
# Confirm the /clear landed and a fresh session started — DETERMINISTICALLY (#345).
# Primary signal: the SessionStart(source=clear) hook (bin/handoff-latch-reset-hook.sh)
# stamps @handoff_cleared_at=<epoch> on this pane; a value >= clear_t0 means THIS
# clear fired the fresh session (TUI-version-independent, unambiguous). Fallback:
# the legacy capture-pane scrape (empty `❯`/`>` prompt row + shortcut hint, and the
# typed `/clear` gone) — retained only for a fleet not yet synced to the stamping
# hook. If neither confirms within RETRY_AFTER, re-type /clear ONCE (covers a
# dropped keystroke); if neither ever confirms we do NOT type pickup (fail-safe:
# the operator still has a manual pickup).
log "verifying fresh session (≤${VERIFY_TIMEOUT}s, retry after ${RETRY_AFTER}s)"
fresh=0 retried=0
vf_start=$(date +%s 2>/dev/null || echo 0)
vf_deadline=$(( vf_start + VERIFY_TIMEOUT ))
retry_at=$(( vf_start + RETRY_AFTER ))
while [ "$(date +%s 2>/dev/null || echo 0)" -lt "$vf_deadline" ]; do
  # Primary: the deterministic marker (>= clear_t0 ⇒ stamped by this clear).
  mk="$(TM display-message -p -t "$PANE" '#{@handoff_cleared_at}' 2>/dev/null)"
  case "$mk" in
    ''|*[!0-9]*) : ;;   # unset / non-numeric → no deterministic signal yet
    *) if [ "$mk" -ge "$clear_t0" ]; then
         fresh=1; log "fresh session confirmed via @handoff_cleared_at=$mk (>= $clear_t0)"; break
       fi ;;
  esac
  # Fallback: the legacy screen-scrape (any one signal, and the `/clear` is gone).
  cap="$(TM capture-pane -p -t "$PANE" 2>/dev/null)"
  if printf '%s' "$cap" | grep -Eq '(^|[[:space:]])(❯|>)[[:space:]]|for shortcuts|Welcome to Claude'; then
    if ! printf '%s' "$cap" | grep -q '/clear'; then
      fresh=1; log "fresh session confirmed via capture-pane fallback"; break
    fi
  fi
  # Retry the /clear ONCE if nothing has confirmed within RETRY_AFTER — a dropped
  # Escape/keystroke leaves the session uncleared and no marker is ever stamped.
  if [ "$retried" = 0 ] && [ "$(date +%s 2>/dev/null || echo 0)" -ge "$retry_at" ]; then
    retried=1
    log "no fresh signal within ${RETRY_AFTER}s — retrying /clear once"
    send_clear
  fi
  sleep 0.5 2>/dev/null || true
done
if [ "$fresh" != 1 ]; then
  notify "could not confirm a fresh session after /clear — resume manually: $PICKUP"
  exit 0   # fail-safe: cleared but pickup withheld; manual pickup still works
fi

# ============================ 5. PICKUP ========================================
# Type the pickup command + a SEPARATE Enter (same bracketed-paste discipline) so
# the emptied session's FIRST turn is `/fleet-handoff pickup [<doc>]` and it
# resumes from the handoff's NEXT ACTION. Comment storage → argument-free (the
# pane @issue self-resolves the marked comment); file storage → the doc path.
# Brief settle: the marker fires at SessionStart, which can beat the input row's
# first render by a hair — a short pause keeps the pickup keystrokes from landing
# in a not-yet-ready TUI (the scrape path already implies a rendered prompt).
sleep 0.5 2>/dev/null || true
log "sending pickup: $PICKUP"
FLEET_ALLOW_SENDKEYS=1 TM send-keys -t "$PANE" -l -- "$PICKUP" 2>/dev/null || true
FLEET_ALLOW_SENDKEYS=1 TM send-keys -t "$PANE" Enter 2>/dev/null || true

log "cycle complete — pane $PANE cleared and resumed from $STORE"
exit 0
