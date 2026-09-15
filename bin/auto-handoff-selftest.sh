#!/bin/bash
# auto-handoff-selftest.sh — hermetic test for the auto-handoff trigger (issues #330,
# #561).
#
# Auto-handoff adds ONLY a trigger on top of the existing /fleet-handoff cycle: at a
# clean Stop, if the session's context has crossed FLEET_AUTO_HANDOFF_PCT, the Stop
# hook (bin/set-claude-state.sh) emits a Stop-hook `block` decision that steers the
# model into `/fleet-handoff`. This drives the FOUR real pieces against a FAKE tmux
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
#   DOCTOR    bin/fleet-doctor.sh evaluates the threshold THE WAY THE HOOK DOES and
#             says `hook sees N` — WARN when the conf says 60 but the hook sees 0.
#
# THE KNOB COMES FROM THE CONF, NEVER THE ENVIRONMENT (issue #561). The previous
# version of this test injected FLEET_AUTO_HANDOFF_PCT=60 into the hook's env — and
# stayed green for weeks while production was dead: nothing exports the conf into a
# hook's environment, so the hook (which read env only) always saw 0. Every NUDGE
# leg here writes the threshold into a real conf on disk — the GLOBAL fleet.conf
# (a sibling of bin/, auto-sourced by fleet-lib) and/or the PER-FLEET overlay
# ($HOME/.config/claude-fleet/fleets/<sess>/conf) — and runs the hook under `env -i`
# with ONLY what a Claude Code hook really has (PATH, HOME, TMPDIR, TMUX, TMUX_PANE;
# the FAKE_*/SETOPT_LOG vars are the fake tmux's own knobs, not the hook's). The
# scripts under test are COPIED into a throwaway install root ($WORK/inst/bin) so
# the "global conf" is $WORK/inst/fleet.conf, not this checkout's or the machine's.
# The OFF leg (no conf sets it) and the "broken" leg (the hook's lib missing) are
# both asserted, so the test can tell "off" from "inert".
#
# The fake tmux answers `display-message` reads from FAKE_* env and logs every
# `set-window-option` to SETOPT_LOG (so the latch write + the @ctx_pct stamp assert
# cleanly). tmux absent doesn't matter (we never call real tmux); jq absent SKIPs
# only the MEASURE leg. Exit 0 = pass, non-zero = fail (prints which leg diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
STATUSLINE="$BIN/../conf/statusline.sh"
for f in set-claude-state.sh fleet-hook-conf.sh fleet-lib.sh fleet-lang.sh handoff-latch-reset-hook.sh fleet-doctor.sh classify-sessions.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done
[ -f "$STATUSLINE" ] || { printf 'selftest: %s not found\n' "$STATUSLINE" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/auto-handoff-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/fakepath" "$WORK/inst/bin" "$WORK/home/.config/claude-fleet/fleets/s1" "$WORK/tmp"
SETOPT_LOG="$WORK/setopt.log"; : > "$SETOPT_LOG"
PANE='%9'
SESS='s1'
# A throwaway INSTALL ROOT: the hook resolves fleet-lib.sh (and through it the
# global conf) relative to its OWN path, so copying the pieces here makes the global
# conf $WORK/inst/fleet.conf — hermetic wherever this runs (a live install's bin
# has a real sibling fleet.conf with the operator's real threshold).
for f in set-claude-state.sh fleet-hook-conf.sh fleet-lib.sh fleet-lang.sh handoff-latch-reset-hook.sh fleet-doctor.sh classify-sessions.sh; do
  cp "$BIN/$f" "$WORK/inst/bin/$f"
done
STATE="$WORK/inst/bin/set-claude-state.sh"
RESET="$WORK/inst/bin/handoff-latch-reset-hook.sh"
DOCTOR="$WORK/inst/bin/fleet-doctor.sh"
GCONF="$WORK/inst/fleet.conf"
FCONF="$WORK/home/.config/claude-fleet/fleets/$SESS/conf"
# The env a Claude Code hook really has — nothing FLEET_* in it. /usr/bin:/bin
# supplies sh/bash/grep/tr/cat/date/dirname; the fake tmux shadows any real one.
HOOK_PATH="$WORK/fakepath:/usr/bin:/bin"

# --- fake tmux: answer display-message reads from FAKE_*, log set-window-option ---
# Strips a leading global -L/-S <socket> (none in these bare calls, but mirror the
# bridge/handoff fakes) so the verb still lands in $1. `session_name` is what
# fleet_current_session asks for (the hook's session → conf hop).
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
      *session_name*)   printf '%s\n' "${FAKE_SESSION:-}" ;;
      *window_id*)      printf '%s\n' "${FAKE_WID:-@1}" ;;
      *) : ;;
    esac ;;
  set-window-option) printf '%s\n' "$args" >> "$SETOPT_LOG" ;;
  list-clients)      printf '%b' "${FAKE_CLIENTS:-}" ;;   # "<client_activity> <window_id>" per line
  capture-pane)      printf '%b' "${FAKE_CAP:-}" ;;
  *) exit 1 ;;   # no server for anything else (list-panes etc.)
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/tmux"

fail() { printf 'selftest FAIL: %s\n' "$1" >&2
         printf -- '--- setopt log ---\n' >&2; cat "$SETOPT_LOG" >&2 2>/dev/null
         printf -- '--- global conf ---\n' >&2; cat "$GCONF" >&2 2>/dev/null
         printf -- '--- per-fleet conf ---\n' >&2; cat "$FCONF" >&2 2>/dev/null; exit 1; }

# write_confs — materialise the two conf layers from GPCT (global) / FPCT (per-fleet).
# Unset GPCT ⇒ the key stays COMMENTED OUT in the global conf (fleet.conf.example's
# shipped state); unset FPCT ⇒ the per-fleet conf carries no such line. Neither layer
# is ever missing as a FILE here (see the NO-CONF leg for that), so an absent value
# means "the operator never set it", not "the fleet isn't configured".
write_confs() {
  {
    printf '# global fleet.conf (selftest)\nFLEET_GLOBAL_MAX_SESSIONS=3\n'
    if [ -n "${GPCT:-}" ]; then printf 'FLEET_AUTO_HANDOFF_PCT=%s\n' "$GPCT"
    else                        printf '#FLEET_AUTO_HANDOFF_PCT=0        # context %% that triggers an auto-handoff; 0 = OFF\n'; fi
    [ -n "${GDEFER:-}" ] && printf 'FLEET_HANDOFF_DEFER_SECS=%s\n' "$GDEFER"
  } > "$GCONF"
  {
    printf 'FLEET_REPO="fake/repo"\nFLEET_MAIN="%s/repo"\n' "$WORK"
    [ -n "${FPCT:-}" ] && printf 'FLEET_AUTO_HANDOFF_PCT=%s\n' "$FPCT"
    [ -n "${FDEFER:-}" ] && printf 'FLEET_HANDOFF_DEFER_SECS=%s\n' "$FDEFER"
  } > "$FCONF"
}

# run the Stop hook (bin/set-claude-state.sh <arg>) from a CLEAN env — conf knobs
# come from GPCT/FPCT (written to disk), the fake tmux's answers from FAKE_*.
run_state() {
  : > "$SETOPT_LOG"
  write_confs
  env -i PATH="$HOOK_PATH" HOME="$WORK/home" TMPDIR="$WORK/tmp" \
      TMUX="$WORK/fake-sock,1,0" TMUX_PANE="$PANE" \
      SETOPT_LOG="$SETOPT_LOG" FAKE_SESSION="$SESS" \
      FAKE_PREV="${FAKE_PREV:-done}" FAKE_ARMED="${FAKE_ARMED:-}" \
      FAKE_ISSUE="${FAKE_ISSUE:-}" FAKE_RAW="${FAKE_RAW:-}" FAKE_CTX="${FAKE_CTX:-}" \
      FAKE_WID="${FAKE_WID:-}" FAKE_CLIENTS="${FAKE_CLIENTS:-}" \
      ${HOOK_ENTRY:+CLAUDE_CODE_ENTRYPOINT=$HOOK_ENTRY} \
    sh "$STATE" "$@" < /dev/null   # empty stdin → deterministic (no stop_hook_active)
}

nudged()  { case "$1" in *'"decision":"block"'*) return 0 ;; *) return 1 ;; esac; }
latched() { grep -q '@handoff_armed 1' "$SETOPT_LOG" 2>/dev/null; }

# ---- THE #561 CASE: threshold in the GLOBAL conf only, nothing in the env -------
# This is production: FLEET_AUTO_HANDOFF_PCT=60 in ~/.claude/fleet/fleet.conf, a
# per-fleet conf that doesn't mention it, a worker at 65% — the hook must nudge.
# (An env-only hook sees 0 here and this leg is the one that goes red.)
out="$(GPCT=60 FAKE_CTX=65 FAKE_ISSUE=561 FAKE_PREV='done' run_state 'done')"
nudged "$out" || fail "GLOBAL conf FLEET_AUTO_HANDOFF_PCT=60 + clean env: the hook must read the conf and nudge (#561), got: '$out'"
case "$out" in *'65%'*) : ;; *) fail "nudge reason must report the measured 65%, got: '$out'";; esac
case "$out" in *'>= 60%'*) : ;; *) fail "nudge reason must report the conf threshold 60, got: '$out'";; esac
case "$out" in *'/fleet-handoff'*) : ;; *) fail "nudge reason must direct the model to /fleet-handoff, got: '$out'";; esac
# Issue #620: this directive is injected as the LAST instruction of a turn, so a
# session held in Chinese would write its handoff doc — and everything after the
# pickup — in English without the trailing language rule.
case "$out" in *'Continue replying in the language this session was using'*) : ;;
  *) fail "nudge reason must end with the language rule (issue #620), got: '$out'";; esac
latched || fail "nudge must set the @handoff_armed latch"

# ---- OFF ≠ BROKEN: no conf layer sets it → no nudge even at 95% ---------------
out="$(FAKE_CTX=95 FAKE_ISSUE=561 run_state 'done')"
nudged "$out" && fail "no conf sets the threshold (OFF) must NOT nudge, got: '$out'"
latched && fail "OFF must not set the latch"

# ---- explicit 0 in the global conf → off ---------------------------------------
out="$(GPCT=0 FAKE_CTX=95 FAKE_ISSUE=561 run_state 'done')"
nudged "$out" && fail "global FLEET_AUTO_HANDOFF_PCT=0 (off) must NOT nudge"

# ---- PER-FLEET OVERLAY WINS over the global default (both directions) -----------
out="$(GPCT=0 FPCT=60 FAKE_CTX=65 FAKE_ISSUE=561 run_state 'done')"
nudged "$out" || fail "per-fleet 60 must override global 0 (overlay wins), got: '$out'"
out="$(GPCT=60 FPCT=0 FAKE_CTX=95 FAKE_ISSUE=561 run_state 'done')"
nudged "$out" && fail "per-fleet 0 must override global 60 (overlay wins) — no nudge, got: '$out'"
out="$(FPCT=60 FAKE_CTX=65 FAKE_ISSUE=561 run_state 'done')"
nudged "$out" || fail "per-fleet 60 with the global key unset must nudge, got: '$out'"

# ---- BELOW THRESHOLD → no nudge ----------------------------------------------
out="$(GPCT=60 FAKE_CTX=50 FAKE_ISSUE=561 run_state 'done')"
nudged "$out" && fail "below threshold (50<60) must NOT nudge"
latched && fail "below threshold must not set the latch"

# ---- BOUNDARY: exactly at threshold → nudge (>=) ------------------------------
out="$(GPCT=60 FAKE_CTX=60 FAKE_ISSUE=561 run_state 'done')"
nudged "$out" || fail "at exactly the threshold (60>=60) must nudge"

# ---- NON-NUMERIC value in the conf → treated as off ----------------------------
out="$(GPCT=abc FAKE_CTX=95 FAKE_ISSUE=561 run_state 'done')"
nudged "$out" && fail "non-numeric FLEET_AUTO_HANDOFF_PCT must be treated as off (no nudge)"

# ---- DON'T HIJACK A needs TURN (prior state = needs) → no nudge ---------------
out="$(GPCT=60 FAKE_CTX=95 FAKE_ISSUE=561 FAKE_PREV='needs' run_state 'done')"
nudged "$out" && fail "prior state 'needs' must NOT be hijacked by an auto-handoff"
latched && fail "needs-turn must not set the latch"

# ---- SCOPE: panel/hub (no @issue, no @raw) → excluded -------------------------
out="$(GPCT=60 FAKE_CTX=95 FAKE_ISSUE='' FAKE_RAW='' run_state 'done')"
nudged "$out" && fail "a pane with neither @issue nor @raw (panel/hub) must be excluded"
latched && fail "out-of-scope pane must not set the latch"

# ---- SCRATCH (@raw=1, no @issue) → STILL nudges (issue #330 scratch case) ------
out="$(GPCT=60 FAKE_CTX=95 FAKE_ISSUE='' FAKE_RAW=1 FAKE_PREV='done' run_state 'done')"
nudged "$out" || fail "a scratch pane (@raw=1, no @issue) must still nudge"
latched || fail "scratch nudge must set the latch"

# ---- LATCH HOLDS on the 2nd fire (already armed) → no nudge -------------------
out="$(GPCT=60 FAKE_CTX=95 FAKE_ISSUE=561 FAKE_ARMED=1 run_state 'done')"
nudged "$out" && fail "an already-armed pane (@handoff_armed=1) must NOT re-nudge (debounce)"
latched && fail "the 2nd fire must not re-write the latch"

# ---- UNSTAMPED @ctx_pct (statusline hasn't rendered yet) → no nudge -----------
out="$(GPCT=60 FAKE_CTX='' FAKE_ISSUE=561 run_state 'done')"
nudged "$out" && fail "an unstamped @ctx_pct must NOT nudge (no measurement yet)"

# ---- HEADLESS CHILD (issue #571): a `claude -p` helper's hooks must touch NOTHING --
# A headless claude (the Stop-hook classifier; any `claude -p` a worker spawns from
# its Bash tool) inherits the pane's TMUX/TMUX_PANE AND the global hooks — so ITS
# Stop landed here, read the PANE's @ctx_pct and nudged ITSELF into /fleet-handoff,
# which then /clear-ed the operator's pane (16 cycles in 24h, one every ~70s on the
# pane the operator was typing into). Claude Code marks the entrypoint in the env
# its hooks inherit: `cli` for the TUI, `sdk-cli` for -p. Not the TUI ⇒ this hook is
# not the pane's session ⇒ no state write, no latch, no nudge.
out="$(HOOK_ENTRY=sdk-cli GPCT=60 FAKE_CTX=65 FAKE_ISSUE=561 run_state 'done')"
nudged "$out" && fail "a headless child (CLAUDE_CODE_ENTRYPOINT=sdk-cli) must NEVER be nudged, got: '$out'"
latched && fail "a headless child must not set the latch"
[ -s "$SETOPT_LOG" ] && fail "a headless child must not write the pane's @claude_state, log: $(cat "$SETOPT_LOG")"
out="$(HOOK_ENTRY=cli GPCT=60 FAKE_CTX=65 FAKE_ISSUE=561 run_state 'done')"
nudged "$out" || fail "the TUI (CLAUDE_CODE_ENTRYPOINT=cli) must still nudge, got: '$out'"
printf 'selftest: HEADLESS leg PASS (sdk-cli child: no state/latch/nudge; cli still nudges)\n' >&2

# ---- DEFER while the operator is typing at THIS window (issue #571) --------------
# Claude Code hands a hook no "draft in the input box" signal (checked: the Stop
# payload has none), so the proxy is tmux: a client whose CURRENT window is this one
# and whose last keypress (#{client_activity}) is within FLEET_HANDOFF_DEFER_SECS.
# Then: no nudge, NO latch (the next Stop re-judges), and a visible
# @handoff_deferred_ts stamp. A ceiling at threshold+10 keeps a long conversation
# from deferring forever into autocompact.
now=$(date +%s)
deferred() { grep -q '@handoff_deferred_ts' "$SETOPT_LOG" 2>/dev/null; }
out="$(GPCT=60 FAKE_CTX=65 FAKE_ISSUE=561 FAKE_WID='@1' FAKE_CLIENTS="$((now-5)) @1\n" run_state 'done')"
nudged "$out" && fail "operator active at this window 5s ago must DEFER the nudge, got: '$out'"
latched && fail "a deferred nudge must not set the latch (the next Stop re-judges)"
deferred || fail "a deferral must stamp @handoff_deferred_ts, log: $(cat "$SETOPT_LOG")"
out="$(GPCT=60 FAKE_CTX=65 FAKE_ISSUE=561 FAKE_WID='@1' FAKE_CLIENTS="$((now-120)) @1\n" run_state 'done')"
nudged "$out" || fail "operator idle for 120s (> 30s default) must nudge, got: '$out'"
out="$(GPCT=60 FAKE_CTX=65 FAKE_ISSUE=561 FAKE_WID='@1' FAKE_CLIENTS="$((now-1)) @2\n" run_state 'done')"
nudged "$out" || fail "operator active on a DIFFERENT window must not defer this one, got: '$out'"
out="$(GPCT=60 FAKE_CTX=70 FAKE_ISSUE=561 FAKE_WID='@1' FAKE_CLIENTS="$((now-1)) @1\n" run_state 'done')"
nudged "$out" || fail "at threshold+10 (70>=60+10) the deferral must yield — nudge anyway, got: '$out'"
out="$(GPCT=60 FAKE_CTX=69 FAKE_ISSUE=561 FAKE_WID='@1' FAKE_CLIENTS="$((now-1)) @1\n" run_state 'done')"
nudged "$out" && fail "just under the ceiling (69<70) an active operator must still defer, got: '$out'"
out="$(GPCT=60 GDEFER=0 FAKE_CTX=65 FAKE_ISSUE=561 FAKE_WID='@1' FAKE_CLIENTS="$((now-1)) @1\n" run_state 'done')"
nudged "$out" || fail "FLEET_HANDOFF_DEFER_SECS=0 must disable the deferral, got: '$out'"
deferred && fail "with the deferral off nothing must stamp @handoff_deferred_ts"
# PER-FLEET overlay wins, both directions — and each leg is shaped so the only
# reading that passes is "the overlay's EXACT value was used": a fall back to the
# global value OR to the built-in 30s default goes red in both. The keypress ages
# also sit ~60s from their boundary instead of 2s (issue #715): `now` is taken ~10
# run_state calls above — a subshell plus a script start each — and #693's lesson is
# that a real-time window must never be a bet on the test's own process startup.
out="$(GPCT=60 GDEFER=0 FDEFER=120 FAKE_CTX=65 FAKE_ISSUE=561 FAKE_WID='@1' FAKE_CLIENTS="$((now-60)) @1\n" run_state 'done')"
nudged "$out" && fail "per-fleet FLEET_HANDOFF_DEFER_SECS=120 with a 60s-old keypress must defer (global 0 or the 30s default would nudge), got: '$out'"
deferred || fail "the per-fleet deferral must stamp @handoff_deferred_ts, log: $(cat "$SETOPT_LOG")"
out="$(GPCT=60 GDEFER=120 FDEFER=5 FAKE_CTX=65 FAKE_ISSUE=561 FAKE_WID='@1' FAKE_CLIENTS="$((now-8)) @1\n" run_state 'done')"
nudged "$out" || fail "per-fleet FLEET_HANDOFF_DEFER_SECS=5 with an 8s-old keypress must nudge (global 120 or the 30s default would defer), got: '$out'"
out="$(GPCT=60 FAKE_CTX=65 FAKE_ISSUE=561 FAKE_WID='@1' FAKE_CLIENTS="$((now-3000)) @1\n$((now-2)) @1\n" run_state 'done')"
nudged "$out" && fail "a live client beside a stale ghost (dropped Termius) must still defer, got: '$out'"
out="$(GPCT=60 FAKE_CTX=65 FAKE_ISSUE=561 FAKE_WID='@1' FAKE_CLIENTS="garbage\n" run_state 'done')"
nudged "$out" || fail "garbage in list-clients must fail open (nudge), got: '$out'"
printf 'selftest: DEFER legs PASS (active/stale/other-window/ceiling/off/per-fleet/ghost/garbage)\n' >&2

# ---- WRONG EVENT: the nudge lives ONLY in the done branch ---------------------
for ev in working busy needs; do
  out="$(GPCT=60 FAKE_CTX=95 FAKE_ISSUE=561 run_state "$ev")"
  nudged "$out" && fail "arg '$ev' (not the Stop hook) must never emit a block decision"
done

# ---- LOOP-GUARD: stop_hook_active=true on stdin → stand down (no re-block) -----
# The model is already continuing from a prior Stop-hook block; re-blocking would
# loop. Feed the Stop-hook payload on stdin (bypassing run_state's /dev/null).
: > "$SETOPT_LOG"; GPCT=60 write_confs
out="$(printf '%s' '{"stop_hook_active":true}' | \
  env -i PATH="$HOOK_PATH" HOME="$WORK/home" TMPDIR="$WORK/tmp" \
      TMUX="$WORK/fake-sock,1,0" TMUX_PANE="$PANE" SETOPT_LOG="$SETOPT_LOG" FAKE_SESSION="$SESS" \
      FAKE_PREV='done' FAKE_ARMED='' FAKE_ISSUE=561 FAKE_RAW='' FAKE_CTX=95 \
    sh "$STATE" 'done')"
nudged "$out" && fail "stop_hook_active=true must stand down (no re-block loop)"
latched && fail "stop_hook_active loop-guard must not set the latch"

# ---- NO CONF AT ALL (no global file, no per-fleet dir) → fail-open: no nudge, rc 0
: > "$SETOPT_LOG"; rm -f "$GCONF"
out="$(env -i PATH="$HOOK_PATH" HOME="$WORK/nohome" TMPDIR="$WORK/tmp" \
      TMUX="$WORK/fake-sock,1,0" TMUX_PANE="$PANE" SETOPT_LOG="$SETOPT_LOG" FAKE_SESSION="$SESS" \
      FAKE_PREV='done' FAKE_ISSUE=561 FAKE_CTX=95 \
    sh "$WORK/inst/bin/set-claude-state.sh" 'done' < /dev/null 2>&1)"; rc=$?
[ "$rc" = 0 ] || fail "with no conf anywhere the hook must still exit 0 (never block a turn), rc=$rc: '$out'"
nudged "$out" && fail "with no conf anywhere the nudge must stay OFF, got: '$out'"
grep -q '@claude_state done' "$SETOPT_LOG" || fail "with no conf the hook must still stamp @claude_state done"

# ---- BROKEN INSTALL (fleet-lib.sh missing beside the hook) → fail-open, rc 0 -----
mv "$WORK/inst/bin/fleet-lib.sh" "$WORK/inst/bin/fleet-lib.sh.off"
out="$(GPCT=60 FAKE_CTX=95 FAKE_ISSUE=561 run_state 'done' 2>&1)"; rc=$?
mv "$WORK/inst/bin/fleet-lib.sh.off" "$WORK/inst/bin/fleet-lib.sh"
[ "$rc" = 0 ] || fail "a missing fleet-lib.sh must not break the Stop hook (rc=$rc): '$out'"
nudged "$out" && fail "a missing fleet-lib.sh cannot resolve the conf → nudge must stay OFF, got: '$out'"

# ---- COST: the conf hop runs on every Stop — keep it cheap (issue #561: ≲ 50 ms) --
# Measured, not asserted tightly (CI runners jitter): 20 runs must finish inside 20 s,
# which only catches a hang; the per-run figure is printed for the record.
GPCT=60 write_confs
t0=$(date +%s)
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  env -i PATH="$HOOK_PATH" HOME="$WORK/home" TMPDIR="$WORK/tmp" \
      TMUX="$WORK/fake-sock,1,0" TMUX_PANE="$PANE" SETOPT_LOG="$SETOPT_LOG" FAKE_SESSION="$SESS" \
      FAKE_PREV='done' FAKE_ISSUE=561 FAKE_CTX=10 \
    sh "$STATE" 'done' < /dev/null >/dev/null
done
t1=$(date +%s); el=$(( t1 - t0 ))
[ "$el" -le 20 ] || fail "20 Stop-hook runs took ${el}s — the conf hop must stay cheap"
printf 'selftest: NUDGE legs PASS (global conf/off/overlay/threshold/needs/scope/scratch/latch/unstamped/event/loop-guard/no-conf/broken-lib; 20 runs in %ss)\n' "$el" >&2

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
# …and UNSET the stale @ctx_pct (issue #571): after a /clear the window still carries
# the OLD session's percentage until the fresh TUI re-stamps it, and any Stop in that
# gap (a classifier child, a fast first turn) read "73%" against a 9% session.
grep -q -- '-u .*@ctx_pct' "$SETOPT_LOG" 2>/dev/null \
  || fail "source=clear must UNSET the stale @ctx_pct stamp (#571), log: $(cat "$SETOPT_LOG")"

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
grep -q '@ctx_pct' "$SETOPT_LOG" 2>/dev/null \
  && fail "source!=clear must leave @ctx_pct alone (a compact's stamp is still the live session's), log: $(cat "$SETOPT_LOG")"

printf 'selftest: RESET-marker legs PASS (source=clear stamps @handoff_cleared_at; others do not)\n' >&2

# ---- RESET(headless): a `claude -p` child's SessionStart must not touch the pane ---
# The classifier's own SessionStart cleared the pane's latch every classification —
# that is what let the same pane be re-nudged every Stop (issue #571).
: > "$SETOPT_LOG"
PATH="$WORK/fakepath:$PATH" TMUX='fake,1,0' TMUX_PANE="$PANE" SETOPT_LOG="$SETOPT_LOG" \
  CLAUDE_CODE_ENTRYPOINT=sdk-cli FLEET_LATCH_RESET_SOURCE=clear sh "$RESET" < /dev/null
[ -s "$SETOPT_LOG" ] && fail "a headless child's SessionStart must not reset the latch or stamp the marker, log: $(cat "$SETOPT_LOG")"
printf 'selftest: RESET-headless leg PASS (sdk-cli SessionStart touches nothing)\n' >&2

# ---- CLASSIFIER HELPER runs `claude -p` OUTSIDE tmux (issue #571) ----------------
# Belt to the headless guard's suspenders: bin/classify-sessions.sh strips TMUX and
# TMUX_PANE from the helper's environment, so every fleet hook (`[ -n "$TMUX" ] ||
# exit 0`) no-ops inside it whatever Claude Code's env markers say. A fake `claude`
# records the environment it was handed.
CLASSIFY="$WORK/inst/bin/classify-sessions.sh"
CLENV="$WORK/classify-claude.env"; rm -f "$CLENV"
cat > "$WORK/fakepath/claude" <<FAKECL
#!/bin/sh
env > "$CLENV"
cat >/dev/null
printf 'STOPPED\n'
FAKECL
chmod +x "$WORK/fakepath/claude"
mkdir -p "$WORK/inst/logs"
PATH="$WORK/fakepath:/usr/bin:/bin" HOME="$WORK/home" TMUX="$WORK/fake-sock,1,0" TMUX_PANE="$PANE" \
  SETOPT_LOG="$SETOPT_LOG" FAKE_PREV='done' FAKE_WID='@1' FAKE_CAP='some screen text\n' CLASSIFY_SETTLE=0 \
  bash "$CLASSIFY" --window '@1' </dev/null
[ -f "$CLENV" ] || fail "classifier must have called the helper claude (fake never invoked)"
grep -q '^TMUX=' "$CLENV" && fail "the helper claude -p must NOT inherit TMUX (its hooks would drive the pane), got: $(grep '^TMUX' "$CLENV")"
grep -q '^TMUX_PANE=' "$CLENV" && fail "the helper claude -p must NOT inherit TMUX_PANE, got: $(grep '^TMUX' "$CLENV")"
rm -f "$WORK/fakepath/claude"
printf 'selftest: CLASSIFIER-ENV leg PASS (helper claude -p sees no TMUX/TMUX_PANE)\n' >&2

# ---- DOCTOR: evaluates the threshold the way the hook does (issue #561) ---------
# The doctor line is the regression tripwire: it compares what the conf files SAY
# with what the hook's resolution path SEES. Same throwaway install root, the
# per-fleet estate under FLEET_CONF_DIR (the doctor's own seam), the fake tmux on
# PATH (no live server → it resolves by session name, and says so).
# run-selftests.sh exports FLEET_SKIP_GLOBAL_CONF=1 so the LIVE install's fleet.conf
# can't leak into tests — but the global layer under test here is the throwaway
# $WORK/inst/fleet.conf, so drop that seam (and the cap it clears) for the doctor,
# which is not run under env -i (it needs the caller's tools on PATH).
run_doctor() {
  write_confs
  env -u FLEET_SKIP_GLOBAL_CONF -u FLEET_GLOBAL_MAX_SESSIONS \
      PATH="$WORK/fakepath:$PATH" FLEET_CONF_DIR="$WORK/home/.config/claude-fleet" HOME="$WORK/home" \
    sh "$DOCTOR" 2>/dev/null | grep -E '^  (PASS|WARN|FAIL)  handoff '
}
out="$(GPCT=60 run_doctor)"
case "$out" in *PASS*'auto-handoff at 60%'*'hook sees 60'*) : ;;
  *) fail "doctor: global 60 must read PASS 'auto-handoff at 60% (hook sees 60 …)', got: '$out'";; esac
out="$(GPCT=0 FPCT=45 run_doctor)"
case "$out" in *PASS*'auto-handoff at 45%'*'hook sees 45'*) : ;;
  *) fail "doctor: per-fleet 45 over global 0 must read 'at 45% (hook sees 45 …)', got: '$out'";; esac
out="$(run_doctor)"
case "$out" in *PASS*'auto-handoff OFF'*) : ;;
  *) fail "doctor: nothing set must read PASS 'auto-handoff OFF', got: '$out'";; esac
# The typing-deferral window rides the same line (issue #571): default 30s, conf value.
out="$(GPCT=60 run_doctor)"
case "$out" in *'defer 30s'*) : ;;
  *) fail "doctor: with the knob unset the handoff line must show 'defer 30s' (default), got: '$out'";; esac
out="$(GPCT=60 GDEFER=45 run_doctor)"
case "$out" in *'defer 45s'*) : ;;
  *) fail "doctor: FLEET_HANDOFF_DEFER_SECS=45 must show 'defer 45s', got: '$out'";; esac
out="$(GPCT=60 GDEFER=0 run_doctor)"
case "$out" in *'defer off'*) : ;;
  *) fail "doctor: FLEET_HANDOFF_DEFER_SECS=0 must show 'defer off', got: '$out'";; esac
# The inert case the doctor exists for: the conf says 60 but the hook's path can't
# resolve it (its lib is gone) → WARN, naming the hole.
mv "$WORK/inst/bin/fleet-lib.sh" "$WORK/inst/bin/fleet-lib.sh.off"
out="$(GPCT=60 run_doctor)"
mv "$WORK/inst/bin/fleet-lib.sh.off" "$WORK/inst/bin/fleet-lib.sh"
case "$out" in *WARN*'hook sees 0'*'inert'*) : ;;
  *) fail "doctor: conf 60 but the hook resolves 0 must WARN 'hook sees 0 — nudge inert', got: '$out'";; esac

printf 'selftest: DOCTOR leg PASS (hook-eye view of the threshold: 60/45/OFF/inert)\n' >&2

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

printf 'selftest PASS: auto-handoff — measure (@ctx_pct) + nudge (block-stop from the CONF, gated + latched) + reset + doctor (#330, #561)\n'
exit 0
