#!/bin/bash
# auto-handoff-selftest.sh — hermetic test for the auto-handoff trigger (issue #330).
#
# Auto-handoff adds ONLY a trigger on top of the existing /fleet-handoff cycle: at a
# clean Stop, if the session's context has crossed FLEET_AUTO_HANDOFF_PCT, the Stop
# hook (bin/set-claude-state.sh) emits a Stop-hook `block` decision that steers the
# model into `/fleet-handoff`. This drives the THREE real pieces against a FAKE tmux
# (the same PATH-less mock-tmux shape bin/fleet-handoff-selftest.sh uses) — no tmux
# server, no live Claude:
#
#   MEASURE   conf/statusline.sh, fed a JSON with .context_window.used_percentage,
#             stamps the rounded % onto @ctx_pct (the Stop hook's only input).
#   NUDGE     bin/set-claude-state.sh done emits the block-stop JSON exactly when
#             armed + over-threshold + in scope + from a clean done, and sets the
#             @handoff_armed latch; below threshold / off / needs / out-of-scope /
#             already-armed / unstamped → NO nudge; a scratch (@raw, no @issue) pane
#             still nudges (the cycle self-selects FILE storage downstream).
#   RESET     bin/handoff-latch-reset-hook.sh clears @handoff_armed at SessionStart,
#             and on source=clear ALSO stamps the deterministic @handoff_cleared_at
#             marker the auto-handoff cycle polls to confirm a fresh session (#345).
#
# The fake tmux answers `display-message` reads from FAKE_* env and logs every
# `set-window-option` to SETOPT_LOG (so the latch write + the @ctx_pct stamp assert
# cleanly). tmux absent doesn't matter (we never call real tmux); jq absent SKIPs
# only the MEASURE leg. Exit 0 = pass, non-zero = fail (prints which leg diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
STATE="$BIN/set-claude-state.sh"
RESET="$BIN/handoff-latch-reset-hook.sh"
STATUSLINE="$BIN/../conf/statusline.sh"
for f in "$STATE" "$RESET" "$STATUSLINE"; do
  [ -f "$f" ] || { printf 'selftest: %s not found\n' "$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/auto-handoff-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/fakepath"
SETOPT_LOG="$WORK/setopt.log"; : > "$SETOPT_LOG"
PANE='%9'

# --- fake tmux: answer display-message reads from FAKE_*, log set-window-option ---
# Strips a leading global -L/-S <socket> (none in these bare calls, but mirror the
# bridge/handoff fakes) so the verb still lands in $1.
cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/bin/bash
if [ "${1:-}" = "-L" ] || [ "${1:-}" = "-S" ]; then shift 2; fi
verb="${1:-}"; args="$*"
case "$verb" in
  display-message)
    case "$args" in
      *@handoff_armed*) printf '%s\n' "${FAKE_ARMED:-}" ;;
      *@ctx_pct*)       printf '%s\n' "${FAKE_CTX:-}" ;;
      *@issue*)         printf '%s\n' "${FAKE_ISSUE:-}" ;;
      *@raw*)           printf '%s\n' "${FAKE_RAW:-}" ;;
      *@claude_state*)  printf '%s\n' "${FAKE_PREV:-done}" ;;
      *) : ;;
    esac ;;
  set-window-option) printf '%s\n' "$args" >> "$SETOPT_LOG" ;;
  *) : ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/tmux"

fail() { printf 'selftest FAIL: %s\n' "$1" >&2
         printf -- '--- setopt log ---\n' >&2; cat "$SETOPT_LOG" >&2 2>/dev/null; exit 1; }

# run the Stop hook (bin/set-claude-state.sh <arg>) under the fake tmux; env knobs
# come from caller-set shell vars (PCT / FAKE_*), mirroring fleet-handoff-selftest.
run_state() {
  : > "$SETOPT_LOG"
  PATH="$WORK/fakepath:$PATH" \
  TMUX='fake,1,0' TMUX_PANE="$PANE" \
  SETOPT_LOG="$SETOPT_LOG" \
  FLEET_AUTO_HANDOFF_PCT="${PCT:-0}" \
  FAKE_PREV="${FAKE_PREV:-done}" FAKE_ARMED="${FAKE_ARMED:-}" \
  FAKE_ISSUE="${FAKE_ISSUE:-}" FAKE_RAW="${FAKE_RAW:-}" FAKE_CTX="${FAKE_CTX:-}" \
    sh "$STATE" "$@" < /dev/null   # empty stdin → deterministic (no stop_hook_active)
}

nudged()  { case "$1" in *'"decision":"block"'*) return 0 ;; *) return 1 ;; esac; }
latched() { grep -q '@handoff_armed 1' "$SETOPT_LOG" 2>/dev/null; }

# ---- NUDGE: worker over threshold, clean done → emit + latch -------------------
out="$(PCT=60 FAKE_CTX=65 FAKE_ISSUE=330 FAKE_PREV='done' run_state 'done')"
nudged "$out" || fail "worker over-threshold: expected a block-stop nudge, got: '$out'"
case "$out" in *'65%'*) : ;; *) fail "nudge reason must report the measured 65%, got: '$out'";; esac
case "$out" in *'/fleet-handoff'*) : ;; *) fail "nudge reason must direct the model to /fleet-handoff, got: '$out'";; esac
latched || fail "nudge must set the @handoff_armed latch"

# ---- BELOW THRESHOLD → no nudge ----------------------------------------------
out="$(PCT=60 FAKE_CTX=50 FAKE_ISSUE=330 run_state 'done')"
nudged "$out" && fail "below threshold (50<60) must NOT nudge"
latched && fail "below threshold must not set the latch"

# ---- BOUNDARY: exactly at threshold → nudge (>=) ------------------------------
out="$(PCT=60 FAKE_CTX=60 FAKE_ISSUE=330 run_state 'done')"
nudged "$out" || fail "at exactly the threshold (60>=60) must nudge"

# ---- OFF (PCT=0) → no nudge even at high ctx ----------------------------------
out="$(PCT=0 FAKE_CTX=95 FAKE_ISSUE=330 run_state 'done')"
nudged "$out" && fail "PCT=0 (off) must NOT nudge"
latched && fail "PCT=0 must not set the latch"

# ---- NON-NUMERIC PCT → treated as off ----------------------------------------
out="$(PCT=abc FAKE_CTX=95 FAKE_ISSUE=330 run_state 'done')"
nudged "$out" && fail "non-numeric PCT must be treated as off (no nudge)"

# ---- DON'T HIJACK A needs TURN (prior state = needs) → no nudge ---------------
out="$(PCT=60 FAKE_CTX=95 FAKE_ISSUE=330 FAKE_PREV='needs' run_state 'done')"
nudged "$out" && fail "prior state 'needs' must NOT be hijacked by an auto-handoff"
latched && fail "needs-turn must not set the latch"

# ---- SCOPE: panel/steward (no @issue, no @raw) → excluded ---------------------
out="$(PCT=60 FAKE_CTX=95 FAKE_ISSUE='' FAKE_RAW='' run_state 'done')"
nudged "$out" && fail "a pane with neither @issue nor @raw (panel/steward) must be excluded"
latched && fail "out-of-scope pane must not set the latch"

# ---- SCRATCH (@raw=1, no @issue) → STILL nudges (issue #330 scratch case) ------
out="$(PCT=60 FAKE_CTX=95 FAKE_ISSUE='' FAKE_RAW=1 FAKE_PREV='done' run_state 'done')"
nudged "$out" || fail "a scratch pane (@raw=1, no @issue) must still nudge"
latched || fail "scratch nudge must set the latch"

# ---- LATCH HOLDS on the 2nd fire (already armed) → no nudge -------------------
out="$(PCT=60 FAKE_CTX=95 FAKE_ISSUE=330 FAKE_ARMED=1 run_state 'done')"
nudged "$out" && fail "an already-armed pane (@handoff_armed=1) must NOT re-nudge (debounce)"
latched && fail "the 2nd fire must not re-write the latch"

# ---- UNSTAMPED @ctx_pct (statusline hasn't rendered yet) → no nudge -----------
out="$(PCT=60 FAKE_CTX='' FAKE_ISSUE=330 run_state 'done')"
nudged "$out" && fail "an unstamped @ctx_pct must NOT nudge (no measurement yet)"

# ---- WRONG EVENT: the nudge lives ONLY in the done branch ---------------------
for ev in working busy needs; do
  out="$(PCT=60 FAKE_CTX=95 FAKE_ISSUE=330 run_state "$ev")"
  nudged "$out" && fail "arg '$ev' (not the Stop hook) must never emit a block decision"
done

# ---- LOOP-GUARD: stop_hook_active=true on stdin → stand down (no re-block) -----
# The model is already continuing from a prior Stop-hook block; re-blocking would
# loop. Feed the Stop-hook payload on stdin (bypassing run_state's /dev/null).
: > "$SETOPT_LOG"
out="$(printf '%s' '{"stop_hook_active":true}' | \
  PATH="$WORK/fakepath:$PATH" TMUX='fake,1,0' TMUX_PANE="$PANE" SETOPT_LOG="$SETOPT_LOG" \
  FLEET_AUTO_HANDOFF_PCT=60 FAKE_PREV='done' FAKE_ARMED='' FAKE_ISSUE=330 FAKE_RAW='' FAKE_CTX=95 \
    sh "$STATE" 'done')"
nudged "$out" && fail "stop_hook_active=true must stand down (no re-block loop)"
latched && fail "stop_hook_active loop-guard must not set the latch"

printf 'selftest: NUDGE legs PASS (threshold/off/needs/scope/scratch/latch/unstamped/event/loop-guard)\n' >&2

# ---- RESET: SessionStart latch-reset clears @handoff_armed --------------------
: > "$SETOPT_LOG"
PATH="$WORK/fakepath:$PATH" TMUX='fake,1,0' TMUX_PANE="$PANE" SETOPT_LOG="$SETOPT_LOG" \
  sh "$RESET"
grep -q -- '-u .*@handoff_armed' "$SETOPT_LOG" 2>/dev/null \
  || fail "SessionStart reset must UNSET (-u) @handoff_armed, log: $(cat "$SETOPT_LOG")"
# and it must never LEAVE the latch set (no bare '@handoff_armed 1')
latched && fail "reset must not set the latch"

printf 'selftest: RESET leg PASS (SessionStart unsets @handoff_armed)\n' >&2

# ---- RESET(clear): SessionStart(source=clear) also STAMPS @handoff_cleared_at ---
# The deterministic auto-handoff verify signal (#345): on a /clear the latch-reset
# hook stamps a monotonic-epoch marker the cycle polls to confirm the fresh session.
# It must STILL unset the latch, AND stamp @handoff_cleared_at <epoch>.
: > "$SETOPT_LOG"
PATH="$WORK/fakepath:$PATH" TMUX='fake,1,0' TMUX_PANE="$PANE" SETOPT_LOG="$SETOPT_LOG" \
  FLEET_LATCH_RESET_SOURCE=clear sh "$RESET" < /dev/null
grep -q -- '-u .*@handoff_armed' "$SETOPT_LOG" 2>/dev/null \
  || fail "source=clear reset must still unset @handoff_armed, log: $(cat "$SETOPT_LOG")"
grep -Eq '@handoff_cleared_at [0-9]+' "$SETOPT_LOG" 2>/dev/null \
  || fail "source=clear must stamp @handoff_cleared_at <epoch>, log: $(cat "$SETOPT_LOG")"

# ---- RESET(non-clear): startup/resume/compact must NOT stamp the marker --------
# Only a /clear is the cycle's fresh-session signal; other boundaries must reset the
# latch WITHOUT stamping the marker (else they'd false-confirm a clear that never ran).
: > "$SETOPT_LOG"
PATH="$WORK/fakepath:$PATH" TMUX='fake,1,0' TMUX_PANE="$PANE" SETOPT_LOG="$SETOPT_LOG" \
  FLEET_LATCH_RESET_SOURCE=startup sh "$RESET" < /dev/null
grep -q -- '-u .*@handoff_armed' "$SETOPT_LOG" 2>/dev/null \
  || fail "startup reset must still unset @handoff_armed, log: $(cat "$SETOPT_LOG")"
grep -q '@handoff_cleared_at' "$SETOPT_LOG" 2>/dev/null \
  && fail "source!=clear must NOT stamp @handoff_cleared_at, log: $(cat "$SETOPT_LOG")"

printf 'selftest: RESET-marker legs PASS (source=clear stamps @handoff_cleared_at; others do not)\n' >&2

# ---- MEASURE: the statusline stamps @ctx_pct (skip if jq absent) --------------
if command -v jq >/dev/null 2>&1; then
  : > "$SETOPT_LOG"
  # Only context_window in the payload → the statusline skips cwd/git/model and just
  # computes + stamps the %. 63.4 rounds to 63.
  printf '%s' '{"context_window":{"used_percentage":63.4}}' \
    | PATH="$WORK/fakepath:$PATH" TMUX='fake,1,0' TMUX_PANE="$PANE" SETOPT_LOG="$SETOPT_LOG" \
        bash "$STATUSLINE" >/dev/null 2>&1
  grep -q '@ctx_pct 63' "$SETOPT_LOG" 2>/dev/null \
    || fail "statusline must stamp @ctx_pct 63 for used_percentage=63.4, log: $(cat "$SETOPT_LOG")"
  printf 'selftest: MEASURE leg PASS (statusline stamps @ctx_pct)\n' >&2
else
  printf 'selftest: MEASURE leg SKIPPED (jq not installed)\n' >&2
fi

printf 'selftest PASS: auto-handoff — measure (@ctx_pct) + nudge (block-stop, gated + latched) + reset (#330)\n'
exit 0
