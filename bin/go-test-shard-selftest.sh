#!/bin/bash
# go-test-shard-selftest.sh — the Go tests' cost-dealt shards (issue #4817, EPIC
# #4810 C7): bin/go-test-shard.sh and bin/go-test-durations.sh.
#
#   A  every deal partitions the list: the N shards' union is the input, no test
#      twice, no test lost — for N 1..7, with and without a table
#   B  longest first into the lightest shard: known costs give the known loads, and
#      a skewed package the round-robin stacked comes out level
#   C  count: ⌈seconds ÷ per⌉ clamped, the default with no row; sum
#   D  go-test-durations.sh: top-level tests only, given to the package line that
#      closes them, a CI prefix and a cached package read, a gone test dropped
#
# GO_SHARD_UNDER_TEST points A/B at another copy of the dealer (the BREAK-IT drill
# `go-shard-drops-test` hands it a broken one and expects A to go red).
set -u
BIN=$(cd "$(dirname "$0")" && pwd)
DEAL=${GO_SHARD_UNDER_TEST:-$BIN/go-test-shard.sh}
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — want [$2] got [$3]"; fi; }

d=$(mktemp -d "${TMPDIR:-/tmp}/go-shard-st.XXXXXX")
trap 'rm -rf "${d:?}"' EXIT

# 120 tests, a table for every other one (costs 0.1 .. 60), one other package's rows
i=1
while [ "$i" -le 120 ]; do
  printf 'Test%03d\n' "$i" >> "$d/names"
  [ $((i % 2)) = 0 ] && printf '%s\thub/api.Test%03d\n' "$(( (i * 37) % 60 )).5" "$i" >> "$d/table"
  i=$((i + 1))
done
printf '99\thub/apitest.Test001\n# a comment\n' >> "$d/table"

# --- A ---------------------------------------------------------------------
for tbl in "$d/table" ''; do
  for n in 1 2 3 7; do
    : > "$d/union"
    k=1
    while [ "$k" -le "$n" ]; do
      bash "$DEAL" deal ${tbl:+--table "$tbl"} --pkg hub/api --shard "$k/$n" < "$d/names" >> "$d/union" 2>/dev/null
      k=$((k + 1))
    done
    eq "A ${tbl:+table }N=$n: the union is the list" "$(sort "$d/names" | tr '\n' ' ')" "$(sort "$d/union" | tr '\n' ' ')"
  done
done

# --- B ---------------------------------------------------------------------
printf '10\tp.TestA\n9\tp.TestB\n8\tp.TestC\n3\tp.TestD\n2\tp.TestE\n' > "$d/t2"
loads=$(printf 'TestA\nTestB\nTestC\nTestD\nTestE\n' | bash "$DEAL" loads --table "$d/t2" --pkg p --shards 2 | tr '\n' ' ')
eq "B LPT: 10+3+2 | 9+8" "1/2 15s 3 2/2 17s 2 " "$loads"
# a package whose slow tests sit every third name: round-robin stacks them in one shard
: > "$d/names3"; : > "$d/t3"
i=1
while [ "$i" -le 30 ]; do
  printf 'Test%02d\n' "$i" >> "$d/names3"
  c=1; [ $((i % 3)) = 0 ] && c=30
  printf '%s\tq.Test%02d\n' "$c" "$i" >> "$d/t3"
  i=$((i + 1))
done
mx=$(bash "$DEAL" loads --table "$d/t3" --pkg q --shards 3 < "$d/names3" | sed -E 's/^[^ ]+ ([0-9]+)s .*/\1/' | sort -n | tail -1)
eq "B the stacked package comes out level (max shard 120s, round-robin 300s+)" 120 "$mx"
first=$(bash "$DEAL" deal --table "$d/t2" --pkg p --shard 1/2 < <(printf 'TestA\nTestB\n') 2>&1 >/dev/null)
case "$first" in predicted:*"shard 1/2"*) pass "B deal says its predicted load" ;; *) fail "B no predicted line: $first" ;; esac

# --- C ---------------------------------------------------------------------
printf '600\tr.TestA\n400\tr.TestB\n5000\tother.TestZ\n' > "$d/t4"
eq "C 1000s ÷ 240 ⇒ 5" 5 "$(bash "$BIN/go-test-shard.sh" count --table "$d/t4" --pkg r)"
eq "C clamped to --max" 2 "$(bash "$BIN/go-test-shard.sh" count --table "$d/t4" --pkg r --max 2)"
eq "C no row ⇒ the default" 3 "$(bash "$BIN/go-test-shard.sh" count --table "$d/t4" --pkg none)"
eq "C no table ⇒ the default" 3 "$(bash "$BIN/go-test-shard.sh" count --table "$d/missing" --pkg r)"
eq "C sum of two packages" 6000 "$(bash "$BIN/go-test-shard.sh" sum --table "$d/t4" --pkg "r other")"

# --- D ---------------------------------------------------------------------
M=github.com/verkyyi/claude-fleet/tokenledger
cat > "$d/run.log" <<EOF
=== RUN   TestCloseHandsOver
--- PASS: TestCloseHandsOver (0.50s)
=== RUN   TestLockAcrossReplicas
    --- PASS: TestLockAcrossReplicas/sub (9.00s)
--- PASS: TestLockAcrossReplicas (1.25s)
ok  	$M/hub/leader	2.1s
--- PASS: TestNoPackageLine (3.00s)
EOF
printf 'test (rest)\tstep\t2026-10-19T11:12:22.1Z --- PASS: TestCloseHandsOver (0.70s)\ntest (rest)\tstep\t2026-10-19T11:12:23.1Z ok  \t%s/hub/leader\t(cached)\n' "$M" > "$d/ci.log"
printf '# head\n4\thub/leader.TestGoneLongAgo\n7\thub/leader.TestLockAcrossReplicas\n' > "$d/t5"
out=$(bash "$BIN/go-test-durations.sh" --table "$d/t5" "$d/run.log" "$d/ci.log")
eq "D the tally" "go-test-durations: 1 updated, 1 added, 0 kept, 1 dropped" "$out"
eq "D the header stays" "# head" "$(head -1 "$d/t5")"
eq "D the median of two runs, the subtest not counted" "$(printf '0.60\thub/leader.TestCloseHandsOver\n1.25\thub/leader.TestLockAcrossReplicas')" "$(tail -n +2 "$d/t5")"

[ "$fails" = 0 ] || { echo "go-test-shard-selftest: $fails failure(s)"; exit 1; }
echo "go-test-shard-selftest: all passed"
