#!/bin/bash
# tokenledger-flaky-selftest.sh — the Go tests red by luck, counted and held out
# (issue #4679, EPIC #4810 C8): bin/tokenledger-flaky.sh (the before / after
# table) against a stub `gh`, and bin/tokenledger-quarantine.sh (the one reader
# of tokenledger/test-quarantine.txt) against sample lists and the real one.
set -u

BIN=$(cd -- "$(dirname -- "$0")" && pwd)
. "$BIN/selftest-lib.sh"
ROOT=$(cd -- "$BIN/.." && pwd)
FAILS=0
fail() { printf 'FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }

T=$(mktemp -d "${TMPDIR:-/tmp}/tokenledger-flaky-selftest.XXXXXX") || exit 1
trap 'rm -rf "${T:?}"' EXIT

# --- A. quarantine reader ---------------------------------------------------
Q="$BIN/tokenledger-quarantine.sh"
printf '# a comment\n\nTestA #1 red on a busy runner\nTestB #22 times out  \nbad line\nTestC 7 no hash\n' > "$T/q.txt"
got=$("$Q" skip "$T/q.txt" 2>"$T/q.err")
[ "$got" = '^(TestA|TestB)$' ] && st_ok_all "A1 skip pattern names the well-formed lines" || fail "A1 skip = [$got]"
[ "$(grep -c 'not `' "$T/q.err")" = 2 ] && st_ok_all "A2 each malformed line said on stderr" || fail "A2 stderr: $(cat "$T/q.err")"
"$Q" check "$T/q.txt" 2>/dev/null && fail "A3 check passed a malformed list" || st_ok_all "A3 check refuses a malformed list"
printf '# only comments\n' > "$T/empty.txt"
got=$("$Q" skip "$T/empty.txt")
[ -z "$got" ] && st_ok_all "A4 an empty list skips nothing" || fail "A4 empty list: [$got]"
[ -z "$("$Q" skip "$T/none.txt")" ] && st_ok_all "A5 no list skips nothing" || fail "A5 no list"
"$Q" check "$ROOT/tokenledger/test-quarantine.txt" && st_ok_all "A6 the repo's list is well formed" || fail "A6 tokenledger/test-quarantine.txt malformed"
# The workflow's PR legs read it through the reader, never by hand.
WF="$ROOT/.github/workflows/tokenledger.yml"
[ "$(grep -c 'tokenledger-quarantine.sh skip' "$WF")" = 2 ] && st_ok_all "A7 both PR legs skip the list" || fail "A7 tokenledger.yml does not read the list in both legs"

# --- B. the flaky table, off a stub gh --------------------------------------
mkdir -p "$T/stub"
cat > "$T/stub/gh" <<'EOF'
#!/bin/sh
# gh api <path> [--jq …]: canned answers by path.
for a in "$@"; do case "$a" in repos/*) path=$a ;; esac; done
case "$path" in
  */workflows/tokenledger.yml/runs*created=2026-10-01*)
    printf '101\t2\tsuccess\t2026-10-01\n102\t1\tsuccess\t2026-10-01\n103\t3\tsuccess\t2026-10-01\n104\t2\tfailure\t2026-10-01\n' ;;
  */workflows/tokenledger.yml/runs*) : ;;
  */workflows/ci.yml/runs*created=2026-10-01*)
    printf '201\t2\tsuccess\t2026-10-01\tci.yml\n202\t2\tsuccess\t2026-10-01\tci.yml\n' ;;
  */workflows/ci.yml/runs*) : ;;
  */runs/201/attempts/1/jobs*) printf '9101\ttokenledger / test (api-1)\n9102\tselftests / selftests / shard 1\n' ;;
  */runs/202/attempts/1/jobs*) printf '9103\tselftests / selftests / shard 2\n' ;;
  */jobs/9101/logs) printf -- '--- FAIL: TestFlaky (1.5s)\n' ;;
  */runs/101/attempts/1/jobs*) printf '9001\ttest (api-1)\n' ;;
  */runs/103/attempts/1/jobs*) printf '9002\ttokenledger-pg (api-2)\n' ;;
  */runs/103/attempts/2/jobs*) printf '9003\ttest (rest)\n' ;;
  */jobs/9001/logs) printf -- '--- FAIL: TestFlaky (1.0s)\n--- FAIL: TestOther (0.1s)\n' ;;
  */jobs/9002/logs) printf -- '--- FAIL: TestFlaky (2.0s)\n    --- FAIL: TestFlaky/sub (0.1s)\n' ;;
  */jobs/9003/logs) printf 'panic: test timed out after 20m0s\n' ;;
  *) echo "stub gh: unexpected $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/stub/gh"
out=$(PATH="$T/stub:$PATH" TMPDIR="$T" "$BIN/tokenledger-flaky.sh" --since 2026-10-01 --repo o/r 2>"$T/err")
rc=$?
[ "$rc" = 0 ] && st_ok_all "B1 runs off the stub" || fail "B1 rc=$rc: $(cat "$T/err")"
echo "$out" | grep -q '^retried-green runs: 3 ' && st_ok_all "B2 counts only runs green on a later attempt (a ci.yml run only for a tokenledger job)" || fail "B2 header: $out"
echo "$out" | grep -qE '^ +3 TestFlaky  2026-10-01\.\.2026-10-01  go=2 pg=1$' && st_ok_all "B3 one per (job, test), legs apart, subtests folded, ci.yml's tokenledger jobs counted" || fail "B3 table: $out"
echo "$out" | grep -qE '^ +1 panic:_test_timed_out_after_20m0s ' && st_ok_all "B4 a job with no FAIL line counts as its timeout" || fail "B4 table: $out"
[ "$(echo "$out" | sed -n 2p | awk '{print $2}')" = TestFlaky ] && st_ok_all "B5 most frequent first" || fail "B5 order: $out"

[ "$FAILS" = 0 ] && { echo "tokenledger-flaky-selftest: all passed"; exit 0; }
echo "tokenledger-flaky-selftest: $FAILS failed"; exit 1
