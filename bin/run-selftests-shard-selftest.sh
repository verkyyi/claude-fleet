#!/bin/bash
# run-selftests-shard-selftest.sh — hermetic test for the sharded selftest gate (#681).
#
# The gate stopped being one 9-minute job and became four ~2-minute ones:
# `bin/run-selftests.sh --shard K/N` runs every N-th test of the sorted list, and
# .github/workflows/selftests.yml fans that over a matrix. That buys margin, and it
# buys a new way to be wrong that no existing test would notice: a stride that
# skips a test leaves the gate GREEN while something goes untested, which is worse
# than the timeout the sharding was introduced to avoid.
#
# So the load-bearing assertion here is the PARTITION — every discovered test lands
# in exactly one shard, for several N, including an N that does not divide the count
# evenly. Everything else follows from it.
#
# Asserted:
#   • PARTITION      the N shards together cover every test exactly once (N=1..4,
#                    over a count that divides evenly and one that does not).
#   • STRIDE         adjacent names land in DIFFERENT shards. The list is sorted and
#                    cost clusters by name — the eight `fleet-collect-*` tests are
#                    neighbours AND among the slowest — so a contiguous split would
#                    pile them into one shard and undo the balance.
#   • GROWTH         adding a test re-deals the shards by itself: no width to bump,
#                    no timeout to raise (the issue's third acceptance criterion).
#   • EMPTY SHARD    a shard with no tests is exit 2, never a silent all-green.
#   • BAD SPEC       K/N garbage and K out of range are exit 2, before anything runs.
#   • RED            a failing test still fails its shard and is named in `failed:`.
#   • TIMINGS        every PASS/FAIL line carries a duration, the slowest table is
#                    ordered slowest-first, and FLEET_SELFTEST_SLOWEST=0 drops it.
#   • WORKFLOW       the shipped workflow really passes --shard, and takes N from
#                    `strategy.job-total` rather than a literal — so editing the
#                    `shard:` list cannot leave the runner splitting by a stale N
#                    and quietly skipping a third of the suite.
#
# Hermetic: a sandbox install root holding only the runner, the shadow builder and a
# handful of trivial fake selftests. No network, no tmux, no real test is ever run.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$BIN/run-selftests.sh"
MK="$BIN/selftest-shadow-root.sh"
WF="$BIN/../.github/workflows/selftests.yml"
[ -f "$RUNNER" ] || { printf 'selftest: %s missing\n' "$RUNNER" >&2; exit 2; }
[ -f "$MK" ]     || { printf 'selftest: %s missing\n' "$MK" >&2; exit 2; }

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '  %s\n' "$2" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); printf 'ok   %s\n' "$1"; }
eq()   { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; printf 'ok   %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/run-selftests-shard.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'rm -rf "$WORK"; exit 130' INT TERM HUP

# A sandbox install root: the runner + the shadow builder it re-execs through, and
# nothing else. Symlinked, so `$BIN` stays logical and the runner resolves its own
# dir to this sandbox exactly as it would to a real bin/.
mkdir -p "$WORK/bin" "$WORK/logs"
ln -s "$RUNNER" "$WORK/bin/run-selftests.sh"
ln -s "$MK"     "$WORK/bin/selftest-shadow-root.sh"

# mkfake <name> [exit-code] [sleep-secs] — a trivial selftest the runner will discover.
mkfake() {
  printf '#!/bin/bash\n[ -z "%s" ] || sleep %s\nexit %s\n' \
    "${3:-}" "${3:-0}" "${2:-0}" > "$WORK/bin/$1-selftest.sh"
  chmod +x "$WORK/bin/$1-selftest.sh"
}

# The outer suite has already set FLEET_SELFTEST_ROOT (it is running us from inside
# its own shadow). Left in place it would tell the inner runner "you are already
# isolated" and skip the re-exec this test drives, so strip the family every time.
run() {
  ( cd "$WORK/bin" \
    && env -u FLEET_SELFTEST_ROOT -u FLEET_SELFTEST_NO_SHADOW -u FLEET_CONF_DIR \
           -u FLEET_SKIP_GLOBAL_CONF -u FLEET_SELFTEST_SLOWEST \
           sh ./run-selftests.sh "$@" </dev/null 2>&1 )
}
# The test names a run actually executed, one per line, in the order they ran.
ran() { printf '%s\n' "$1" | grep -E '^(PASS|FAIL)  ' | awk '{print $2}'; }

# ---------------------------------------------------------------------------
# PARTITION + STRIDE
# ---------------------------------------------------------------------------
# 12 tests: divides evenly by 1, 2, 3 and 4. f01 sleeps so the timing assertions
# below have something to order.
mkfake f01 0 0.4
for n in 02 03 04 05 06 07 08 09 10 11 12; do mkfake "f$n"; done

ALL=$(cd "$WORK/bin" && ls ./*-selftest.sh | sed 's|^\./||' | sort)
eq "the fixture is the 12 fakes and nothing else (the runner discovers by glob)" \
   12 "$(printf '%s\n' "$ALL" | wc -l | tr -d ' ')"

for N in 1 2 3 4; do
  union=''
  k=1
  while [ "$k" -le "$N" ]; do
    out=$(run --shard "$k/$N") || fail "shard $k/$N went red on all-passing fakes" "$out"
    got=$(ran "$out")
    [ -n "$got" ] || fail "shard $k/$N ran nothing" "$out"
    union="$union$got
"
    k=$((k + 1))
  done
  # Exactly once each: the sorted union must equal the discovered list, and a
  # duplicate would show up as a longer list even when the sets look equal.
  usort=$(printf '%s' "$union" | sed '/^$/d' | sort)
  eq "N=$N — the shards cover every test exactly once" "$ALL" "$usort"
  eq "N=$N — and no test runs twice" \
     "$(printf '%s\n' "$ALL" | wc -l | tr -d ' ')" \
     "$(printf '%s\n' "$usort" | wc -l | tr -d ' ')"
done

# STRIDE, not contiguous blocks: with N=4, shard 1 must be f01 f05 f09 — neighbours
# spread across shards. A block split would hand it f01 f02 f03.
out=$(run --shard 1/4) || fail "shard 1/4 went red" "$out"
eq "the split strides (every Nth), so adjacent names land in different shards" \
   "f01-selftest.sh
f05-selftest.sh
f09-selftest.sh" "$(ran "$out")"

# ---------------------------------------------------------------------------
# GROWTH — the issue's third acceptance criterion
# ---------------------------------------------------------------------------
# 13 does not divide by 4: the remainder must not fall off the end.
mkfake f13
ALL13=$(cd "$WORK/bin" && ls ./*-selftest.sh | sed 's|^\./||' | sort)
union=''
for k in 1 2 3 4; do
  out=$(run --shard "$k/4") || fail "shard $k/4 went red after a test was added" "$out"
  union="$union$(ran "$out")
"
done
eq "a NEW selftest re-deals the shards by itself — nothing to bump, remainder included" \
   "$ALL13" "$(printf '%s' "$union" | sed '/^$/d' | sort)"

# No --shard at all = the whole suite, unchanged from before sharding existed.
out=$(run) || fail "an unsharded run went red" "$out"
eq "no --shard runs everything" "$ALL13" "$(ran "$out" | sort)"

# ---------------------------------------------------------------------------
# REFUSALS — a shard that runs nothing must never read as green
# ---------------------------------------------------------------------------
out=$(run --shard 2/2 f01); rc=$?
eq "an EMPTY shard is exit 2, not an all-green" 2 "$rc"
case "$out" in *empty*) ok "…and says so" ;; *) fail "the empty-shard refusal must name the shard" "$out" ;; esac
case "$out" in *"all green"*) fail "an empty shard printed 'all green'" "$out" ;; *) ok "…and never prints 'all green'" ;; esac

for spec in abc 1 1/ /4 1/4/5 1/x 0/4 5/4; do
  out=$(run --shard "$spec"); rc=$?
  CHECKS=$((CHECKS + 1))
  [ "$rc" = 2 ] || fail "--shard '$spec' must be refused with exit 2, got $rc" "$out"
  case "$out" in *"all green"*) fail "--shard '$spec' ran the suite instead of refusing" "$out" ;; esac
done
ok "every malformed or out-of-range --shard K/N is exit 2, before any test runs"

out=$(run --bogus); rc=$?
eq "an unknown option is exit 2 (not mistaken for a test name)" 2 "$rc"

# ---------------------------------------------------------------------------
# RED still reads as red
# ---------------------------------------------------------------------------
mkfake f05 3           # f05 is in shard 1 of 4, per the stride asserted above
out=$(run --shard 1/4); rc=$?
eq "a failing test fails its shard" 1 "$rc"
case "$out" in *"failed: f05-selftest.sh"*|*"failed: "*f05*) ok "…and is named in the failed: line" ;;
  *) fail "the failed: line must name the test" "$out" ;; esac
case "$out" in *"FAIL  f05-selftest.sh"*) ok "…with its exit code on the FAIL line" ;;
  *) fail "no FAIL line for f05" "$out" ;; esac
# A red in one shard says nothing about the others: they must still pass on their own.
out=$(run --shard 2/4) || fail "a sibling shard went red because shard 1 did" "$out"
ok "a red shard does not redden its siblings"
mkfake f05             # back to green

# ---------------------------------------------------------------------------
# TIMINGS (#681: the number that names the slow test before it eats the budget)
# ---------------------------------------------------------------------------
out=$(run --shard 1/4) || fail "shard 1/4 went red" "$out"
CHECKS=$((CHECKS + 1))
printf '%s\n' "$out" | grep -qE '^PASS  f01-selftest\.sh +[0-9]+\.[0-9]s$' \
  || fail "every PASS line must carry the test's duration" "$(printf '%s\n' "$out" | grep '^PASS')"
ok "each PASS/FAIL line carries a duration"

CHECKS=$((CHECKS + 1))
slow=$(printf '%s\n' "$out" | sed -n '/slowest/,/^$/p' | sed -n '2p' | awk '{print $2}')
[ "$slow" = "f01-selftest.sh" ] \
  || fail "the slowest table must lead with the slowest test (f01 sleeps 0.4s), got [$slow]" "$out"
ok "the slowest table is ordered slowest-first"

CHECKS=$((CHECKS + 1))
out=$( ( cd "$WORK/bin" && env -u FLEET_SELFTEST_ROOT -u FLEET_SELFTEST_NO_SHADOW \
           FLEET_SELFTEST_SLOWEST=0 sh ./run-selftests.sh --shard 1/4 </dev/null 2>&1 ) )
case "$out" in *slowest*) fail "FLEET_SELFTEST_SLOWEST=0 must drop the table" "$out" ;; esac
case "$out" in *"all green"*) ok "FLEET_SELFTEST_SLOWEST=0 drops the table and still reports the verdict" ;;
  *) fail "FLEET_SELFTEST_SLOWEST=0 broke the run" "$out" ;; esac

# ---------------------------------------------------------------------------
# THE SHIPPED WORKFLOW — the two ways CI and the runner can silently disagree
# ---------------------------------------------------------------------------
if [ ! -f "$WF" ]; then
  printf 'selftest: %s absent — SKIP the workflow half\n' "$WF" >&2
else
  CHECKS=$((CHECKS + 1))
  grep -q -- '--shard' "$WF" || fail "the workflow no longer shards the gate — it is back to one ~9-minute job against its timeout (#681)"
  ok "the shipped workflow runs the gate sharded"

  # N must come from strategy.job-total, not a literal, ON THE --shard LINE ITSELF.
  # Bump `shard:` to 6 while the command still says /4 and two shards' worth of
  # tests stop running — green, with nothing to say otherwise. That silent hole is
  # what this line exists to prevent, so it checks the argument, not the file.
  CHECKS=$((CHECKS + 1))
  grep -A2 -- '--shard' "$WF" | grep -q 'strategy\.job-total' \
    || fail "the --shard argument must take N from strategy.job-total, so editing the shard: matrix cannot leave the runner splitting by a stale N" \
            "$(grep -n -A2 -- '--shard' "$WF")"
  ok "the shard width has one source of truth (strategy.job-total)"

  CHECKS=$((CHECKS + 1))
  grep -qE '^\s*fail-fast:\s*false' "$WF" \
    || fail "fail-fast must stay false: one red shard cancelling its siblings hides whether the rest were green, which is what makes people re-run instead of read"
  ok "a red shard does not cancel the others (fail-fast: false)"
fi

printf '%s checks\n' "$CHECKS"
printf 'run-selftests-shard-selftest: OK\n'
exit 0
