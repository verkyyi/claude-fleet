#!/bin/bash
# fleet-timebox-kill-selftest.sh — a blown budget really KILLS the tree (issue #682).
#
# The bug this pins. `fleet_timebox` reported "killed" for a phase and returned
# 124; the accounting was perfect and the process was still running. On the
# incident host (2026-09-15) `FLEET_COLLECT_TICK_BUDGET` read 120s while the tick
# ran 3259s, quotawatch's 120s deadline ran 3108s, and `fleet-daemon-watch
# --status` correctly reported both `stale` — so the ledger, the alarm and the
# logs all agreed, and nothing was actually bounded.
#
# Two mechanisms, both covered here:
#
#   1. THE ENUMERATION RACE. `fleet_kill_tree` walked the tree with one `pgrep -P`
#      fork per node and signalled the set it found. Under launchd
#      `ProcessType=Background` at load 170+ each of those forks is starved for
#      tens of seconds, so the set was minutes stale when the signal landed and
#      everything forked in the gap survived as an orphan — which the next tick
#      then piled a fresh tree on top of. The fix launches the job as its own
#      PROCESS-GROUP LEADER (`set -m`) and signals the GROUP, which reaches
#      children forked after the sweep began, and re-enumerates between rounds.
#
#   2. THE ORPHAN THAT HOLDS THE PIPE. Inside `x=$(fleet_timebox …)` — how the
#      collector reads `sockets` — a surviving grandchild keeps the command
#      substitution's stdout pipe open, so the PARENT blocks in `$( )` long after
#      the budget returned 124. Measured against the pre-fix library, a 3s budget
#      cost 123s: the whole budget mechanism inverted into an unbounded wait.
#      That is the shape of the 54-minute tick.
#
# Which check catches which, honestly: §3 is the DISCRIMINATOR — against the
# pre-fix library it fails outright, blocking 123s on a 3s budget. §1 and §2 pass
# on both at desk priority, because the enumeration race needs the starvation to
# open a window wide enough to lose a child in; they are kept as regression guards
# on the group kill, which is what makes §3 pass.
#
# The tests need no load: a tree that forks continuously makes every enumeration
# stale by construction, and a `trap '' TERM` tree makes the SIGKILL round
# load-bearing. Each check bounds WALL CLOCK and then counts survivors by a
# per-run marker, so a leak cannot read as a pass.
#
# Hermetic: no tmux, no network, no repos — just fleet-lib.sh and marked sleeps.
# Exit 0 = pass, non-zero = fail.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/fleet-lib.sh" ] || { printf 'selftest: %s not found\n' "$BIN/fleet-lib.sh" >&2; exit 2; }
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

command -v pgrep >/dev/null 2>&1 || { printf 'selftest: no pgrep(1) — SKIP\n' >&2; exit 0; }

# A marker unique to this run, so we never count (or kill) a peer test's processes.
MARK="tbkill-selftest-$$-$(date +%s)"
cleanup() { pkill -9 -f "$MARK" >/dev/null 2>&1; return 0; }
trap 'cleanup' EXIT

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; fails=$((fails+1)); }

# survivors — how many marked processes are still alive. Given a moment first:
# a tree that is dying is not a tree that leaked.
survivors() { sleep 2; pgrep -f "$MARK" 2>/dev/null | wc -l | tr -d ' '; }

BUDGET=3
CEILING=20     # clear of BUDGET + kill grace, far below a leaked child's 120s

# The two adversaries.
#   forker   — forks a fresh long child every 0.3s, so any enumerated set is
#              already stale by the time it is signalled.
#   stubborn — ignores SIGTERM at every level, so only the SIGKILL round ends it.
forker()   { while :; do bash -c "sleep 120 # $MARK" & sleep 0.3; done; }
stubborn() { bash -c "trap '' TERM; bash -c \"trap '' TERM; sleep 120 # $MARK\""; }

# --- 1. A tree that keeps forking is gone when the budget blows -------------------
t0=$SECONDS; fleet_timebox "$BUDGET" forker >/dev/null 2>&1; rc=$?; el=$(( SECONDS - t0 ))
n=$(survivors)
if [ "$rc" != 124 ]; then
  fail "1: a blown budget must return 124, got $rc"
elif [ "$el" -gt "$CEILING" ]; then
  fail "1: the budget took ${el}s (ceiling ${CEILING}s)"
elif [ "$n" != 0 ]; then
  fail "1: $n orphan(s) outlived the kill — the budget bounded the ledger, not the processes"
else
  ok "a continuously-forking tree is fully gone after its budget (${el}s, 0 orphans)"
fi
cleanup

# --- 2. A tree that ignores SIGTERM still dies (the SIGKILL round) ----------------
t0=$SECONDS; fleet_timebox "$BUDGET" stubborn >/dev/null 2>&1; rc=$?; el=$(( SECONDS - t0 ))
n=$(survivors)
if [ "$el" -gt "$CEILING" ]; then
  fail "2: a TERM-ignoring tree took ${el}s (ceiling ${CEILING}s)"
elif [ "$n" != 0 ]; then
  fail "2: $n process(es) ignored SIGTERM and were never SIGKILLed"
else
  ok "a tree that traps SIGTERM is still killed (${el}s, 0 orphans)"
fi
cleanup

# --- 3. THE INCIDENT: a blown budget inside $( ) does not hang the caller ---------
# The collector reads `sockets` exactly this way. Pre-fix this took 123s for a 3s
# budget, because the orphan kept the substitution's pipe open; that unbounded
# wait is what a 120s tick budget looked like after 54 minutes.
t0=$SECONDS; out=$(fleet_timebox "$BUDGET" forker 2>/dev/null); rc=$?; el=$(( SECONDS - t0 ))
n=$(survivors)
if [ "$el" -gt "$CEILING" ]; then
  fail "3: \$( ) blocked ${el}s on a ${BUDGET}s budget — an orphan is holding the pipe open (captured: ${out:-<empty>})"
elif [ "$rc" != 124 ]; then
  fail "3: a budget blown inside \$( ) must still return 124, got $rc"
elif [ "$n" != 0 ]; then
  fail "3: $n orphan(s) survived a budget blown inside \$( )"
else
  ok "a budget blown inside \$( ) returns at the budget, pipe closed (${el}s, 0 orphans)"
fi
cleanup

# --- 4. fleet_kill_tree's verdict is a READ, not an assumption --------------------
# It used to `return 0` unconditionally, which is how "killed" and "still running"
# became the same log line. 0 = the tree is gone; 1 = something outlived SIGKILL.
sleep 120 & victim=$!
if fleet_kill_tree "$victim" 1; then
  kill -0 "$victim" 2>/dev/null && fail "4: reported the tree gone while $victim is alive" \
                                || ok "fleet_kill_tree returns 0 for a tree it actually killed"
else
  fail "4: could not kill a plain background sleep"
fi
wait "$victim" 2>/dev/null

# An already-dead pid is not an error — a caller racing a normally-exiting child
# must not be failed by it.
sleep 0.1 & gone=$!; wait "$gone" 2>/dev/null
fleet_kill_tree "$gone" 1 && ok "an already-exited pid reads as gone (no false failure)" \
                          || fail "4: an already-exited pid must read as gone"

# A pid that is not ours to signal must be refused outright, not walked.
fleet_kill_tree 1 1 && ok "pid 1 is refused" || fail "4: pid 1 must be refused"
fleet_kill_tree "" 1 && ok "an empty pid is refused" || fail "4: an empty pid must be refused"

printf '\n'
if [ "$fails" -gt 0 ]; then
  printf 'fleet-timebox-kill-selftest: %s FAILED\n' "$fails" >&2
  exit 1
fi
printf 'fleet-timebox-kill-selftest: all checks passed\n'
