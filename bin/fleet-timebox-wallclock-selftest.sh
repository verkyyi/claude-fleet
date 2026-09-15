#!/bin/bash
# fleet-timebox-wallclock-selftest.sh — fleet_timebox's budget is WALL-CLOCK, not a
# count of `sleep 1` calls (issue #653).
#
# The bug this pins (#653): the poll loop counted iterations —
#
#     while [ "$waited" -lt "$budget" ]; do
#       kill -0 "$job" || { wait "$job"; return $?; }
#       sleep 1; waited=$((waited+1))          # <- a COUNTER, not a clock
#     done
#
# — on the assumption that one iteration costs one second. That assumption fails
# exactly when a budget matters. The collector runs under launchd
# `ProcessType=Background` (lowest CPU + I/O tier); at load 40+ each iteration's
# `sleep` fork/exec cost SECONDS, so a 30s budget spent 56s and then 126s of wall
# clock — 1.9x and 4.2x — while `waited` dutifully counted to 30. The budget
# inflated by the very factor that made the work slow, so it was loosest at the
# moment it was needed, and #653 could not give the other phases budgets until the
# mechanism itself was trustworthy.
#
# The test makes that inflation deterministic instead of load-dependent: a PATH
# shim makes every `sleep` take SLOW_ADD seconds longer than asked. Under the old
# counting loop a budget of B costs B*(1+SLOW_ADD) seconds; under a wall-clock
# deadline it costs ~B plus at most one over-long poll, whatever a `sleep` costs.
#
# Covers:
#   1. WALL-CLOCK — a job that never ends is killed at ~the budget in real time,
#      even when each poll iteration takes many times longer than 1s. rc=124.
#   2. EARLY-EXIT — a job that finishes inside the budget returns promptly with
#      ITS OWN exit status (the budget is a ceiling, never a floor).
#   3. STATUS     — a failing job's non-zero status is passed through unchanged.
#   4. UNBUDGETED — budget 0 / non-numeric runs the command unbudgeted.
#
# Hermetic: no tmux, no network, no repos — just fleet-lib.sh and a fake `sleep`.
# Exit 0 = pass, non-zero = fail.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/fleet-lib.sh" ] || { printf 'selftest: %s not found\n' "$BIN/fleet-lib.sh" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/timebox-wallclock-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/fakepath"

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; fails=$((fails+1)); }

# Resolve the REAL sleep before the shim shadows it (the shim must not recurse).
REAL_SLEEP="$(command -v sleep)"
[ -x "$REAL_SLEEP" ] || { printf 'selftest: no sleep(1) on PATH — SKIP\n' >&2; exit 0; }

# --- the shim: every `sleep N` actually sleeps N + SLOW_ADD -----------------------
# This is the whole point of the test. It reproduces, deterministically and in a
# couple of seconds, what load average 40 under ProcessType=Background did to the
# collector: a poll iteration that costs far more than the 1s the loop assumed.
SLOW_ADD=4
cat > "$WORK/fakepath/sleep" <<FAKE
#!/bin/sh
# every sleep costs SLOW_ADD seconds more than asked (integer seconds only)
n="\${1:-0}"; n="\${n%%.*}"
case "\$n" in ''|*[!0-9]*) n=0 ;; esac
exec "$REAL_SLEEP" "\$(( n + $SLOW_ADD ))"
FAKE
chmod +x "$WORK/fakepath/sleep"
PATH="$WORK/fakepath:$PATH"; export PATH

# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

# Sanity: the shim really is in force. Without it the test proves nothing, so a
# silent shim failure must not read as a pass.
_t0=$(date +%s); sleep 1; _t1=$(date +%s)
[ $(( _t1 - _t0 )) -ge "$SLOW_ADD" ] \
  || { printf 'selftest: the slow-sleep shim is not in effect (1s sleep took %ss) — cannot test\n' \
       $(( _t1 - _t0 )) >&2; exit 2; }

BUDGET=4
# What the two implementations cost, with SLOW_ADD=4 (so a `sleep 1` costs 5s):
#   counting loop : BUDGET polls * 5s          = 20s, + the kill grace (5s) = ~25s
#   wall clock    : ~BUDGET, rounded up to the
#                   next poll boundary (5s)    =  5s, + the kill grace (5s) = ~10s
# 16s sits clear of both: above every wall-clock outcome, below every counting one.
CEILING=16

# --- 1. WALL-CLOCK: an endless job is killed at ~the budget in REAL time ----------
endless() { sleep 600; }
t0=$(date +%s); fleet_timebox "$BUDGET" endless 2>/dev/null; rc=$?; t1=$(date +%s)
elapsed=$(( t1 - t0 ))
if [ "$rc" != 124 ]; then
  fail "1: an over-budget job must return 124 (got $rc after ${elapsed}s)"
elif [ "$elapsed" -gt "$CEILING" ]; then
  fail "1: budget ${BUDGET}s was spent in ${elapsed}s of wall clock (ceiling ${CEILING}s) — the budget is still counting poll iterations, not the clock (#653)"
else
  ok "an endless job is killed at ~${BUDGET}s wall clock (${elapsed}s), not after ${BUDGET} slow polls"
fi

# --- 2. EARLY-EXIT: the budget is a ceiling, never a floor ------------------------
# The job outlives one poll (so the loop really iterates) but finishes well inside
# the budget; fleet_timebox must return as soon as it does.
quick() { sleep 0; return 0; }
t0=$(date +%s); fleet_timebox 60 quick; rc=$?; t1=$(date +%s)
elapsed=$(( t1 - t0 ))
if [ "$rc" != 0 ]; then
  fail "2: a job that finishes inside its budget must return its own status 0 (got $rc)"
elif [ "$elapsed" -gt 20 ]; then
  fail "2: a finished job must not be waited out to its budget (took ${elapsed}s of a 60s budget)"
else
  ok "a job finishing inside the budget returns immediately with its own status (${elapsed}s)"
fi

# --- 3. STATUS: a failing job's exit status is passed through ---------------------
boom() { return 7; }
fleet_timebox 60 boom; rc=$?
[ "$rc" = 7 ] && ok "a failing job's exit status is passed through (7)" \
               || fail "3: expected the job's status 7, got $rc"

# --- 4. UNBUDGETED: budget 0 / non-numeric runs the command directly --------------
fleet_timebox 0 boom; rc=$?
[ "$rc" = 7 ] && ok "budget 0 runs the command unbudgeted (status passed through)" \
               || fail "4: budget 0 must run unbudgeted and pass status 7, got $rc"
fleet_timebox "" boom; rc=$?
[ "$rc" = 7 ] && ok "a non-numeric budget runs the command unbudgeted" \
               || fail "4: a non-numeric budget must run unbudgeted and pass status 7, got $rc"

printf '\n'
if [ "$fails" -gt 0 ]; then
  printf 'fleet-timebox-wallclock-selftest: %s FAILED\n' "$fails" >&2
  exit 1
fi
printf 'fleet-timebox-wallclock-selftest: all checks passed\n'
