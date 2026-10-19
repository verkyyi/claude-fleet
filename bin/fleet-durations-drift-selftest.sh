#!/bin/sh
# fleet-durations-drift-selftest.sh — pins bin/fleet-durations-drift.sh (issue #4819):
# the nightly's check that bin/selftest-durations.txt still prices its shards.
#   A  every shard within ±20%            ⇒ table printed, nothing filed, exit 0
#   B  one test made slow (the drill)     ⇒ that shard flagged, ONE filing with
#      --breakage-key durations-selftests, the run and the refresh command in the body
#   C  a small shard under the floor      ⇒ «太小不判», never a filing on its own
#   D  a test with no row costs the median; a test seen twice in a shard counts once
#   E  filer exit 5 (already open)        ⇒ exit 0; filer exit 1 ⇒ exit 1
#   F  no train-times files               ⇒ exit 0, nothing filed; bad usage ⇒ exit 2
#   G  the workflows wire it: selftests-shards.yml uploads train-times.txt, the
#      nightly's report job runs the check
set -u
BIN=$(cd -- "$(dirname -- "$0")" && pwd)
SUT="$BIN/fleet-durations-drift.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/dd-selftest.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
fails=0
ok()   { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/     /'; fails=$((fails + 1)); }

cat > "$T/table.txt" <<'EOF'
# a durations table
100.0 a-selftest.sh
50.0 b-selftest.sh
50.0 c-selftest.sh
10.0 d-selftest.sh
5.0 e-selftest.sh
EOF
# the filer seam: records its argv + the body, prints a URL, exits $FILER_RC
cat > "$T/filer" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$DD_LOG"
echo "https://github.com/o/r/issues/99"
exit "${FILER_RC:-0}"
EOF
chmod +x "$T/filer"
export FLEET_DD_FILER="$T/filer" DD_LOG="$T/filed"

shard() { # <dir> <shard> <lines…>
  d="$1/train-result-Linux-$2"; shift 2; mkdir -p "$d"; printf '%s\n' "$@" > "$d/train-times.txt"
}

# A — within bounds
R="$T/a"
shard "$R" 1 'PASS  a-selftest.sh                                   104.2s'
shard "$R" 2 'PASS  b-selftest.sh                                    52.0s' 'FAIL  c-selftest.sh                                    45.1s (exit 1)'
rm -f "$T/filed"
out=$(sh "$SUT" --results "$R" --table "$T/table.txt" --repo o/r --run 123 --sha abcdef0123 2>&1); rc=$?
if [ "$rc" = 0 ] && [ ! -f "$T/filed" ] && printf '%s' "$out" | grep -q '| Linux-1 | 100s | 104s | 1 | +4% | ✓ |' \
   && printf '%s' "$out" | grep -q '0 片超出'; then ok "A within ±20%: table, nothing filed"
else fail "A within ±20%: rc=$rc" "$out"; fi

# B — the drill: b made slow (50 → 90); shard 2 is 140 against 100 = +40%
R="$T/b"
shard "$R" 1 'PASS  a-selftest.sh                                   98.0s'
shard "$R" 2 'PASS  b-selftest.sh                                    90.0s' 'PASS  c-selftest.sh                                    50.0s'
rm -f "$T/filed"
out=$(sh "$SUT" --results "$R" --table "$T/table.txt" --repo o/r --run 123 --sha abcdef0123 2>&1); rc=$?
if [ "$rc" = 0 ] && [ -f "$T/filed" ] && printf '%s' "$out" | grep -q '| Linux-2 | 100s | 140s | 2 | +40% | ⚠️ 超出 |' \
   && grep -qx 'durations-selftests' "$T/filed" && grep -qx -- '--breakage-key' "$T/filed" \
   && grep -q 'bin/selftest-durations.sh --run 123' "$T/filed" \
   && grep -q 'https://github.com/o/r/actions/runs/123' "$T/filed" \
   && grep -qx 'abcdef0123' "$T/filed" && printf '%s' "$out" | grep -q '更新单：https://github.com/o/r/issues/99'
then ok "B one test made slow ⇒ its shard flagged, ONE refresh issue with the run + command"
else fail "B drill: rc=$rc" "$out
$(cat "$T/filed" 2>/dev/null)"; fi
# B2 — a test made FAST drifts too (the table over-prices it)
R="$T/b2"
shard "$R" 1 'PASS  a-selftest.sh                                   60.0s'
rm -f "$T/filed"
out=$(sh "$SUT" --results "$R" --table "$T/table.txt" --repo o/r 2>&1); rc=$?
if [ "$rc" = 0 ] && [ -f "$T/filed" ] && printf '%s' "$out" | grep -q '| Linux-1 | 100s | 60s | 1 | -40% | ⚠️ 超出 |'
then ok "B2 a test made fast ⇒ flagged as well"; else fail "B2 fast drift: rc=$rc" "$out"; fi

# C — a shard under the floor never files on its own
R="$T/c"
shard "$R" 1 'PASS  d-selftest.sh                                   25.0s'
rm -f "$T/filed"
out=$(sh "$SUT" --results "$R" --table "$T/table.txt" --repo o/r 2>&1); rc=$?
if [ "$rc" = 0 ] && [ ! -f "$T/filed" ] && printf '%s' "$out" | grep -q '| Linux-1 | 10s | 25s | 1 | +150% | 太小不判 |'
then ok "C a shard under the floor is not judged"; else fail "C floor: rc=$rc" "$out"; fi

# D — a new test costs the median (50); a rerun line replaces the cut attempt's
R="$T/d"
shard "$R" 1 'PASS  new-selftest.sh                                 51.0s' \
             'PASS  b-selftest.sh                                   20.0s' 'PASS  b-selftest.sh                                   49.0s'
out=$(sh "$SUT" --results "$R" --table "$T/table.txt" --dry-run 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '| Linux-1 | 100s | 100s | 2 | +0% | ✓ |'
then ok "D no row ⇒ median; a test seen twice counts once"; else fail "D median/dup: rc=$rc" "$out"; fi

# E — the filer's exits
R="$T/b"
out=$(FILER_RC=5 sh "$SUT" --results "$R" --table "$T/table.txt" --repo o/r 2>&1); rc5=$?
out1=$(FILER_RC=1 sh "$SUT" --results "$R" --table "$T/table.txt" --repo o/r 2>&1); rc1=$?
if [ "$rc5" = 0 ] && printf '%s' "$out" | grep -q '更新单：' && [ "$rc1" = 1 ]
then ok "E filer 5 (already open) ⇒ 0; filer 1 ⇒ 1"; else fail "E filer exits: 5→$rc5 1→$rc1" "$out1"; fi

# F — nothing to judge, and usage
mkdir -p "$T/f"
rm -f "$T/filed"
sh "$SUT" --results "$T/f" --table "$T/table.txt" --repo o/r >/dev/null 2>&1; rcf=$?
sh "$SUT" --table "$T/table.txt" >/dev/null 2>&1; rcu=$?
sh "$SUT" --results "$T/f" --pct x >/dev/null 2>&1; rcp=$?
if [ "$rcf" = 0 ] && [ ! -f "$T/filed" ] && [ "$rcu" = 2 ] && [ "$rcp" = 2 ]
then ok "F no times ⇒ 0 · no --results / a bad --pct ⇒ 2"; else fail "F: none=$rcf usage=$rcu pct=$rcp"; fi

# G — the wiring
W="$BIN/../.github/workflows"
if [ -f "$W/selftests-shards.yml" ] && [ -f "$W/selftests-nightly.yml" ]; then
  if grep -q 'train-times.txt' "$W/selftests-shards.yml" && grep -q 'bin/fleet-durations-drift.sh --results results' "$W/selftests-nightly.yml"
  then ok "G shards upload train-times.txt, the nightly runs the check"
  else fail "G the workflows do not wire fleet-durations-drift.sh"; fi
else ok "G (no workflows beside this bin — skipped)"; fi

[ "$fails" = 0 ] || { echo "fleet-durations-drift-selftest: $fails failure(s)"; exit 1; }
echo "fleet-durations-drift-selftest: all passed"
