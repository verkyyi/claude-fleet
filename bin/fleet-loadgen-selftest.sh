#!/bin/bash
# fleet-loadgen-selftest.sh — the invariant bin/fleet-loadgen.sh exists for
# (issue #697): a burner's deadline lives in the BURNER, so killing the parent
# outright cannot leak it.
#
# That is the whole reason the tool is not just a documented `trap` snippet. On
# 2026-09-15 a worker's hand-written experiment leaked 8 spinning zsh processes
# that survived 3h20m as PPID=1 orphans and drove the machine to load 108; its
# `trap … EXIT` never fired and its trailing `kill` was never reached. So the
# assertion that matters here is not "cleanup runs" — it is "cleanup still
# happens when the parent is SIGKILLed and no cleanup code can possibly run".
# Everything else in this file is the surface around that one claim.
#
# This test spawns REAL CPU burners, which is exactly what the repo tells workers
# not to do casually — so it is deliberately tiny (1–2 burners, ≤5s deadlines)
# and every batch is tagged with this pid, so a parallel shard can neither see
# nor stop another's. And if this script itself dies mid-run, its burners still
# expire on their own: that is the property under test.
#
# Hermetic: no network, no tmux, no launchd, no fleet conf. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LG="$BIN/fleet-loadgen.sh"
[ -f "$LG" ] || { echo "selftest: $LG not found" >&2; exit 2; }

TAG="st$$"
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
ok() { CHECKS=$((CHECKS + 1)); }
cleanup() { bash "$LG" --stop "${TAG}a" >/dev/null 2>&1
            bash "$LG" --stop "${TAG}b" >/dev/null 2>&1
            bash "$LG" --stop "${TAG}c" >/dev/null 2>&1
            bash "$LG" --stop "${TAG}10" >/dev/null 2>&1
            bash "$LG" --stop "${TAG}1"  >/dev/null 2>&1; }
trap cleanup EXIT

live() { bash "$LG" --status "$1" 2>/dev/null | grep -c '^[0-9]'; }

# ============================================================================
# 1. Caps + usage. A typo must not be able to ask for hours of load.
# ============================================================================
bash "$LG" 0 5 >/dev/null 2>&1;      eq "cap: zero burners refused"    2 "$?"
bash "$LG" abc 5 >/dev/null 2>&1;    eq "cap: non-numeric n refused"   2 "$?"
bash "$LG" 99999 5 >/dev/null 2>&1;  eq "cap: over MAX_PROCS refused"  2 "$?"
bash "$LG" 1 99999 >/dev/null 2>&1;  eq "cap: over MAX_SECS refused"   2 "$?"
bash "$LG" 1 5 --tag 'a b' >/dev/null 2>&1; eq "cap: bad tag refused"  2 "$?"
# The caps are knobs, so a raised one must actually raise.
FLEET_LOADGEN_MAX_PROCS=2 bash "$LG" 3 2 >/dev/null 2>&1
eq "cap: FLEET_LOADGEN_MAX_PROCS is honored" 2 "$?"

# ============================================================================
# 2. THE invariant: SIGKILL the parent, burners still expire on their own.
# ============================================================================
bash "$LG" 1 5 --tag "${TAG}a" >/dev/null 2>&1 &
par=$!
sleep 1
kill -KILL "$par" 2>/dev/null
wait "$par" 2>/dev/null

# They must be orphaned and ALIVE first — otherwise the expiry proved below could
# just be "the parent's death took them with it", which is not the claim.
eq "orphan: burner survived the parent's SIGKILL" 1 "$(live "${TAG}a")"
eq "orphan: burner reparented to init (PPID=1)" 1 \
   "$(bash "$LG" --status "${TAG}a" 2>/dev/null | grep -c 'ORPHANED (PPID=1)')"

# …and then die by themselves, with NOTHING running that could clean them up.
# Deadline is 5s from t0; allow generous slack for a loaded CI runner.
t0=$(date +%s)
while [ "$(live "${TAG}a")" -gt 0 ]; do
  [ $(( $(date +%s) - t0 )) -gt 25 ] && fail "orphan: burner LEAKED — still alive 25s past a 5s deadline with its parent dead. This is the #697 failure mode and the entire point of the tool"
  sleep 1
done
ok   # burner expired unattended

# ============================================================================
# 3. --status / --stop round trip, on a deadline far too long to wait out.
# ============================================================================
bash "$LG" 2 600 --detach --tag "${TAG}b" >/dev/null 2>&1
eq "status: --detach started 2 burners" 2 "$(live "${TAG}b")"
# --status must never list ITSELF: a naive `ps | grep <marker>` matches the grep,
# and a --stop built on that would report phantom kills forever.
eq "status: does not list its own scan" 2 \
   "$(bash "$LG" --status "${TAG}b" 2>/dev/null | grep -c "${TAG}b")"
bash "$LG" --stop "${TAG}b" >/dev/null 2>&1
eq "stop: --stop reaped them"           0 "$(live "${TAG}b")"

# ============================================================================
# 4. Tag selection is exact. `t1` must not select `t10`, or one experiment's
#    --stop silently ends another's.
# ============================================================================
bash "$LG" 1 600 --detach --tag "${TAG}10" >/dev/null 2>&1
eq "tag: t10 is running"                1 "$(live "${TAG}10")"
eq "tag: prefix t1 does NOT select t10" 0 "$(live "${TAG}1")"
bash "$LG" --stop "${TAG}1" >/dev/null 2>&1
eq "tag: --stop on the prefix spared t10" 1 "$(live "${TAG}10")"
bash "$LG" --stop "${TAG}10" >/dev/null 2>&1
eq "tag: --stop on the exact tag reaped it" 0 "$(live "${TAG}10")"

# ============================================================================
# 5. `-- cmd` mode: the experiment's own exit status is the tool's, and the load
#    stops when the command does — not when the deadline does.
# ============================================================================
t0=$(date +%s)
bash "$LG" 1 600 --tag "${TAG}c" -- sh -c 'exit 7' >/dev/null 2>&1
eq "cmd: exit status is the command's" 7 "$?"
[ $(( $(date +%s) - t0 )) -lt 30 ] || fail "cmd: waited for the 600s deadline instead of the command"
ok
eq "cmd: burners stopped with the command" 0 "$(live "${TAG}c")"

printf 'selftest OK: fleet-loadgen (%s assertions — caps, SIGKILL-proof expiry, status/stop, tag exactness, -- cmd)\n' "$CHECKS"
