#!/bin/bash
# fleet-handoff-invariant-selftest.sh — auto-handoff's floor is a REAL invariant
# now, not an accident that happened to hold (issue #677).
#
# WHAT WAS WRONG. /fleet-handoff's auto-cycle waits for @claude_state to leave
# `working` and, past FLEET_HANDOFF_IDLE_TIMEOUT, ABORTS WITHOUT CLEARING. For the
# case the whole mechanism exists to survive — a turn that emitted no Stop hook at
# all (a fable cap #580, a crash), which pins `working` forever — the ONLY thing
# that can ever open that gate is the spinner's stuck-working demotion (#101), and
# that lands at worst FLEET_STUCK_WORKING_SECS + 2 × STUCK_CHECK_SECS.
#
# Shipped, those were 140s and 180s: a 40s margin, in two files whose authors could
# not see each other, behind two independently-overridable knobs. Reverse it and
# nothing errors — an overnight loop simply fills its context and stops, and every
# remaining hour is wasted. That is the class of bug a test must own, because a
# human reading either file alone cannot see it.
#
# Covers:
#   1. SHIPPED     — the defaults IN THIS TREE satisfy both invariants. This is the
#                    gate: edit either number into a dangerous relation and it reds.
#   2. FLOOR       — a wait-idle ceiling below the demote worst case → exit 1.
#   2b. THIN       — and a margin that is merely POSITIVE is still a failure: the
#                    shipped 40s was "correct" and was the bug, so the checker
#                    requires real headroom, not just a > 0 subtraction.
#   3. DISABLED    — FLEET_STUCK_WORKING_SECS=0 is a VIOLATION, not "no limit":
#                    with the backstop off the gate can never open at all.
#   4. CEILING     — wait-idle + verify ≥ the cycle's own hard watchdog → exit 1.
#   5. PARSE       — a tunable that was renamed/reshaped exits 2 (can't evaluate),
#                    never a silent PASS off a 0 it invented.
#   6. CONF        — the global fleet.conf overrides the file default…
#   7. OVERLAY     — …a per-fleet overlay overrides IDLE on top of that, while
#                    FLEET_STUCK_WORKING_SECS ignores an overlay (global-only:
#                    one spinner daemon serves every fleet — _FLEET_GLOBAL_ONLY).
#   8. ONELINE     — --oneline is exactly ONE line whatever fired (fleet-doctor.sh
#                    prints it as a single pass/warn).
#   9. WIRED       — the three consumers actually reference it: the doctor checks
#                    it, the handoff cycle diagnoses an abort with it, and the
#                    spinner stamps the liveness heartbeat both of them read.
#  10. HEARTBEAT   — running the spinner really does produce that stamp, including
#                    when NO fleet is up (a quiet machine must not read as dead).
#
# Hermetic: no tmux server, no network, no repos — fixtures are sed-edited copies
# of the two real scripts, so the test tracks whatever shape they actually have.
# Exit 0 = pass, non-zero = fail.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
INV="$BIN/fleet-handoff-invariant.sh"
SPIN="$BIN/tmux-spinner.sh"
CYCLE="$BIN/fleet-handoff-cycle.sh"
for f in "$INV" "$SPIN" "$CYCLE"; do
  [ -r "$f" ] || { printf 'selftest: %s not found\n' "$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/handoff-invariant-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; fails=$((fails+1)); }

NOCONF="$WORK/no-such.conf"          # a conf path that does not exist = no overlay
export FLEET_CONF_DIR="$WORK/confdir"   # nothing here unless a case puts it there
mkdir -p "$FLEET_CONF_DIR"

# run_inv <args...> → captures output in $OUT, exit code in $RC. Every case drives
# --conf explicitly so the operator's real fleet.conf can never colour a verdict.
OUT='' RC=0
run_inv() { OUT="$("$INV" "$@" 2>&1)"; RC=$?; }

# fixture <name> <sed-expr> <src> → a copy of <src> with one tunable rewritten.
fixture() { sed "$2" "$3" > "$WORK/$1"; printf '%s\n' "$WORK/$1"; }

printf 'fleet-handoff-invariant-selftest\n'

# --- 1. SHIPPED ----------------------------------------------------------------
# The whole point. If someone lowers FLEET_HANDOFF_IDLE_TIMEOUT's default, or
# raises FLEET_STUCK_WORKING_SECS's, or slows the sweep, this is what goes red.
run_inv --conf "$NOCONF"
if [ "$RC" = 0 ]; then
  ok "SHIPPED: this tree's defaults hold the invariant"
  printf '       %s\n' "$("$INV" --conf "$NOCONF" --oneline 2>&1)"
else
  fail "SHIPPED: the defaults in this tree VIOLATE the handoff invariant (rc=$RC)"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi

# --- 2. FLOOR ------------------------------------------------------------------
# The exact reversal #677 was filed about. The fixture drives the ceiling to 1s
# rather than to a number chosen against today's 140s worst case: a case that only
# violates while the OTHER default holds still would quietly stop testing anything
# the moment someone tuned FLEET_STUCK_WORKING_SECS.
f_low="$(fixture cycle-low.sh 's/FLEET_HANDOFF_IDLE_TIMEOUT:-[0-9]*/FLEET_HANDOFF_IDLE_TIMEOUT:-1/' "$CYCLE")"
run_inv --conf "$NOCONF" --cycle "$f_low"
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'VIOLATED'; then
  ok "FLOOR: a wait-idle ceiling under the demote worst case is a VIOLATION"
else
  fail "FLOOR: expected rc=1 + VIOLATED, got rc=$RC: $OUT"
fi

# --- 2b. THIN ------------------------------------------------------------------
# The subtle half. `worst` assumes a NOMINAL sweep cadence, but the spinner runs at
# launchd's lowest CPU/IO tier, where #653 measured a poll loop costing up to 4.2×
# its nominal wall clock under load — i.e. the sweeps slip exactly when the machine
# is busy enough to drop Stop hooks. So a positive-but-small margin must red too.
# Both sides are PINNED by fixtures (margin = 240 - 120 = 120s, positive whatever
# the tree's real defaults are) and the floor is then driven out of reach, so this
# case reads THIN — never OK, never VIOLATED — and case 1 stays the only one that
# re-asserts the shipped numbers.
f_thin_s="$(fixture spin-thin.sh 's/FLEET_STUCK_WORKING_SECS:-[0-9]*/FLEET_STUCK_WORKING_SECS:-100/' "$SPIN")"
f_thin_c="$(fixture cycle-thin.sh 's/FLEET_HANDOFF_IDLE_TIMEOUT:-[0-9]*/FLEET_HANDOFF_IDLE_TIMEOUT:-240/' "$CYCLE")"
OUT="$(FLEET_HANDOFF_MARGIN_MIN=100000 "$INV" --conf "$NOCONF" --spinner "$f_thin_s" --cycle "$f_thin_c" 2>&1)"; RC=$?
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'THIN'; then
  ok "THIN: a positive but too-small margin reds instead of passing"
else
  fail "THIN: expected rc=1 + THIN for an unreachable margin floor, got rc=$RC: $OUT"
fi

# --- 3. DISABLED ---------------------------------------------------------------
# 0 disables the demoter (documented in fleet.conf.example). That is not a large
# threshold — it is NO threshold, and it kills auto-handoff outright.
f_off="$(fixture spin-off.sh 's/FLEET_STUCK_WORKING_SECS:-[0-9]*/FLEET_STUCK_WORKING_SECS:-0/' "$SPIN")"
run_inv --conf "$NOCONF" --spinner "$f_off"
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'OFF'; then
  ok "DISABLED: FLEET_STUCK_WORKING_SECS=0 reads as a violation, not as no limit"
else
  fail "DISABLED: expected rc=1 naming the disabled backstop, got rc=$RC: $OUT"
fi

# --- 4. CEILING ----------------------------------------------------------------
# Raising IDLE to buy floor margin is what tightens this one, so it is checked too.
# Blown through VERIFY rather than by lowering HARD to a number that only exceeds
# today's IDLE — same reason as FLOOR above: the case must violate on its own terms.
f_hard="$(fixture cycle-hard.sh 's/FLEET_HANDOFF_VERIFY_TIMEOUT:-[0-9]*/FLEET_HANDOFF_VERIFY_TIMEOUT:-9000/' "$CYCLE")"
run_inv --conf "$NOCONF" --cycle "$f_hard"
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'hard timeout'; then
  ok "CEILING: wait-idle + verify past the cycle's own watchdog is a VIOLATION"
else
  fail "CEILING: expected rc=1 naming the hard timeout, got rc=$RC: $OUT"
fi

# --- 5. PARSE ------------------------------------------------------------------
# A renamed tunable must exit 2 (cannot evaluate). A checker that quietly treats a
# missing number as 0 is worse than no checker — #492's lesson.
printf 'IDLE_TIMEOUT=$(compute_it)\n' > "$WORK/cycle-renamed.sh"
run_inv --conf "$NOCONF" --cycle "$WORK/cycle-renamed.sh"
if [ "$RC" = 2 ]; then
  ok "PARSE: a reshaped tunable exits 2 rather than passing off an invented 0"
else
  fail "PARSE: expected rc=2 for an unparseable source, got rc=$RC: $OUT"
fi

# --- 6. CONF -------------------------------------------------------------------
cat > "$WORK/fleet.conf" <<CONF
# a global conf that walks the ceiling under the floor
FLEET_HANDOFF_IDLE_TIMEOUT=1
CONF
run_inv --conf "$WORK/fleet.conf"
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'ceiling = 1s'; then
  ok "CONF: a global fleet.conf value overrides the file default and is judged"
else
  fail "CONF: expected rc=1 resolving IDLE to the conf's 1s, got rc=$RC: $OUT"
fi

# --- 7. OVERLAY ----------------------------------------------------------------
# IDLE takes a per-fleet overlay; STUCK does not (one spinner serves the machine,
# so a per-fleet value would be a silent no-op — fleet-lib.sh's _FLEET_GLOBAL_ONLY).
mkdir -p "$FLEET_CONF_DIR/fleets/fleet-probe"
cat > "$FLEET_CONF_DIR/fleets/fleet-probe/conf" <<CONF
FLEET_HANDOFF_IDLE_TIMEOUT=2
FLEET_STUCK_WORKING_SECS=9999
CONF
run_inv --conf "$NOCONF" --session fleet-probe
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'ceiling = 2s' && ! printf '%s' "$OUT" | grep -q '9999'; then
  ok "OVERLAY: per-fleet IDLE applies; per-fleet FLEET_STUCK_WORKING_SECS is ignored (global-only)"
else
  fail "OVERLAY: expected rc=1 with IDLE=2 and the overlay's STUCK=9999 ignored, got rc=$RC: $OUT"
fi
# …and without --session that same overlay must not leak in. Asserted on the
# RESOLVED VALUE rather than on a passing exit code, so a genuinely broken default
# reds case 1 alone instead of scattering misleading failures across the file.
run_inv --conf "$NOCONF"
if ! printf '%s' "$OUT" | grep -q 'ceiling = 2s'; then
  ok "OVERLAY: an unrelated fleet's overlay does not colour the sessionless verdict"
else
  fail "OVERLAY: a sessionless run resolved IDLE from fleet-probe's overlay: $OUT"
fi

# --- 8. ONELINE ----------------------------------------------------------------
# fleet-doctor.sh renders one pass/warn per fleet, so more than one line would
# corrupt that row however many invariants fired at once.
f_both="$(fixture cycle-both.sh 's/FLEET_HANDOFF_IDLE_TIMEOUT:-[0-9]*/FLEET_HANDOFF_IDLE_TIMEOUT:-1/; s/FLEET_HANDOFF_VERIFY_TIMEOUT:-[0-9]*/FLEET_HANDOFF_VERIFY_TIMEOUT:-9000/' "$CYCLE")"
n=$("$INV" --conf "$NOCONF" --cycle "$f_both" --oneline 2>&1 | wc -l | tr -d ' ')
if [ "$n" = 1 ]; then
  ok "ONELINE: two simultaneous violations still render as exactly one line"
else
  fail "ONELINE: expected 1 line, got $n"
fi
n=$("$INV" --conf "$NOCONF" --oneline 2>&1 | wc -l | tr -d ' ')
[ "$n" = 1 ] || fail "ONELINE: a passing run printed $n lines, expected 1"

# --- 9. WIRED ------------------------------------------------------------------
# An invariant nothing reads is a comment. Pin each consumer by name.
grep -q 'fleet-handoff-invariant.sh' "$BIN/fleet-doctor.sh" \
  && ok "WIRED: fleet-doctor.sh evaluates the invariant" \
  || fail "WIRED: fleet-doctor.sh no longer calls fleet-handoff-invariant.sh"
grep -q 'backstop_diag' "$CYCLE" \
  && ok "WIRED: fleet-handoff-cycle.sh diagnoses a wait-idle abort" \
  || fail "WIRED: fleet-handoff-cycle.sh lost its wait-idle abort diagnosis"
grep -q 'spinner.heartbeat' "$SPIN" && grep -q 'spinner.heartbeat' "$BIN/fleet-doctor.sh" \
  && ok "WIRED: the spinner stamps a heartbeat and the doctor reads it" \
  || fail "WIRED: the spinner liveness heartbeat is not stamped and/or not read"

# --- 10. HEARTBEAT -------------------------------------------------------------
# The heartbeat is what makes "is the demoter running?" answerable at all (this
# unit is KeepAlive, so it is absent from the interval-daemon registry every other
# daemon's liveness comes from). Run the real spinner from a throwaway bin/ with an
# EMPTY conf dir — no fleet sockets, i.e. the quiet-machine path, which must still
# read as alive.
mkdir -p "$WORK/bin" "$WORK/logs" "$WORK/emptyconf"
cp "$SPIN" "$WORK/bin/tmux-spinner.sh"
( FLEET_CONF_DIR="$WORK/emptyconf" SPIN_INTERVAL=0.05 sh "$WORK/bin/tmux-spinner.sh" >/dev/null 2>&1 ) &
spid=$!
hb=''
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  sleep 1
  [ -f "$WORK/logs/spinner.heartbeat" ] && { hb=$(cat "$WORK/logs/spinner.heartbeat" 2>/dev/null); hb=${hb%% *}; break; }
done
kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
case "$hb" in
  ''|*[!0-9]*) fail "HEARTBEAT: the spinner wrote no usable stamp with no fleet up (got '${hb}')" ;;
  *) age=$(( $(date +%s) - hb ))
     if [ "$age" -ge 0 ] && [ "$age" -le 60 ]; then
       ok "HEARTBEAT: the spinner stamps liveness even with no fleet up (${age}s old)"
     else
       fail "HEARTBEAT: stamp is ${age}s off now — not a current epoch second"
     fi ;;
esac

printf '\n'
if [ "$fails" = 0 ]; then printf 'fleet-handoff-invariant-selftest: PASS\n'; exit 0; fi
printf 'fleet-handoff-invariant-selftest: %d FAILURE(S)\n' "$fails"; exit 1
