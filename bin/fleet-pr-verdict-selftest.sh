#!/bin/bash
# fleet-pr-verdict-selftest.sh — hermetic tests for the issue #441 merge gate: the
# deterministic "may I merge this yet?" read a SELF-LANDING worker runs before it
# squash-merges its own PR.
#
# Two layers, tested where each lives:
#   FOLD — land_verdict (bin/fleet-land-lease.sh): (state, mergeable,
#          mergeStateStatus, draft, checks) → ONE verdict token. Pure function,
#          table-driven, no fakes. The strictness that separates a GATE from the
#          dash's glance lives here: a RED or still-RUNNING check outranks a CLEAN
#          mergeStateStatus (a repo whose CI is not a REQUIRED check reports CLEAN
#          while it is red), and MERGED/CLOSED report as themselves, not GONE.
#   CLI  — bin/fleet-pr-verdict.sh: the one `gh` read + exit-code contract
#          (0 READY · 1 any other verdict · 2 error), driven with `gh` faked on
#          PATH. No network, no git, no tmux.
#   WAIT — --wait / --until-merged (issue #950): a fake `gh` that serves one JSON
#          fixture per poll through the script's REAL --jq program (system jq),
#          and a fake `sleep` that returns at once but is logged — the loop's
#          clock is the sum of its sleeps, so every bound is tested in ~0s.
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + detail).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CLI="$BIN/fleet-pr-verdict.sh"
[ -x "$CLI" ] || { echo "selftest: $CLI missing/not executable" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/prverdict-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# ===== FOLD: land_verdict ======================================================
# shellcheck source=/dev/null
. "$BIN/fleet-land-lease.sh"

v() { land_verdict "$1" "$2" "$3" "$4" "$5"; }
expect() {  # expect <want> <state> <mergeable> <mss> <draft> <checks>
  local want="$1"; shift
  local got; got=$(v "$@")
  [ "$got" = "$want" ] || fail "land_verdict($*) = $got, want $want"
}

# green + mergeable + up to date, with checks actually passing → the merge case.
expect READY   OPEN MERGEABLE CLEAN     '' pass
expect READY   OPEN MERGEABLE HAS_HOOKS '' pass
# No checks configured at all: nothing to wait for.
expect READY   OPEN MERGEABLE CLEAN     '' none
ok "READY only when the PR is mergeable AND its checks aren't red/running"

# THE #441 STRICTNESS: CLEAN means "nothing REQUIRED blocks the merge" — it does
# NOT mean CI is green. A non-required check that is red/running must still stop
# the gate, or a self-landing worker ships red.
expect FAILING OPEN MERGEABLE CLEAN     '' fail
expect PENDING OPEN MERGEABLE CLEAN     '' pending
expect FAILING OPEN MERGEABLE HAS_HOOKS '' fail
expect FAILING OPEN MERGEABLE UNSTABLE  '' fail
ok "a red/running check outranks a CLEAN mergeStateStatus (never ship red)"

# The rest of the taxonomy passes straight through land_classify.
expect BEHIND   OPEN MERGEABLE   BEHIND  '' pass
expect CONFLICT OPEN CONFLICTING BLOCKED '' pass
expect CONFLICT OPEN MERGEABLE   DIRTY   '' pass
expect BLOCKED  OPEN MERGEABLE   BLOCKED '' pass
expect FAILING  OPEN MERGEABLE   BLOCKED '' fail
expect PENDING  OPEN MERGEABLE   BLOCKED '' pending
expect DRAFT    OPEN MERGEABLE   CLEAN   DRAFT pass
ok "behind / conflict / blocked / draft fold through the shared taxonomy"

# Non-OPEN reports as ITSELF — the confirm-after-merge read must be able to tell
# "already landed" from "closed unmerged" (land_classify folds both to GONE).
expect MERGED MERGED '' '' '' pass
expect CLOSED CLOSED '' '' '' pass
[ "$(land_classify MERGED '' '' '' pass)" = GONE ] \
  || fail "land_classify should still fold non-OPEN to GONE (unchanged)"
ok "MERGED/CLOSED report as themselves; land_classify keeps its GONE fold"

# ===== CLI: bin/fleet-pr-verdict.sh ============================================
mkdir -p "$WORK/fakebin"
# fake gh: emits the 5-field TSV the real `gh pr view --jq` produces. GH_ROW is
# the canned row; GH_RC forces a non-zero exit (unknown PR / auth failure).
cat > "$WORK/fakebin/gh" <<'GHFAKE'
#!/bin/bash
[ "${GH_RC:-0}" != 0 ] && exit "${GH_RC}"
printf '%s\n' "${GH_ROW-}"
exit 0
GHFAKE
chmod +x "$WORK/fakebin/gh"

# Hermetic env: a private TMPDIR (the fleet runtime cache lives under it) and no
# global conf leaking in, so repo resolution is decided by --repo alone.
run_cli() {  # run_cli <args…> → sets OUT/ERR/RC
  OUT=$(env PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
            GH_ROW="${GH_ROW-}" GH_RC="${GH_RC:-0}" \
            bash "$CLI" "$@" 2>"$WORK/err"); RC=$?
  ERR=$(cat "$WORK/err")
}

# The five fields exactly as the real `gh … --jq` emits them: ONE PER LINE, so an
# empty mergeable/mss/draft stays its own field (a tab-separated row would collapse
# adjacent empties — tab is IFS whitespace — and shift `checks` onto `draft`).
row() { printf '%s\n%s\n%s\n%s\n%s' "$1" "$2" "$3" "$4" "$5"; }

GH_ROW=$(row OPEN MERGEABLE CLEAN '' pass); run_cli 77 --repo acme/widgets
[ "$OUT" = READY ] || fail "CLI should print READY for a green PR" "$OUT / $ERR"
[ "$RC" = 0 ]      || fail "CLI should exit 0 on READY (got $RC)" "$ERR"
ok "CLI prints READY and exits 0 for a green, mergeable PR"

GH_ROW=$(row OPEN MERGEABLE CLEAN '' fail); run_cli 77 --repo acme/widgets
[ "$OUT" = FAILING ] || fail "CLI should print FAILING for a red check" "$OUT / $ERR"
[ "$RC" = 1 ]        || fail "CLI should exit 1 on a non-READY verdict (got $RC)" "$ERR"
GH_ROW=$(row OPEN MERGEABLE BEHIND '' pass); run_cli 77 --repo acme/widgets
[ "$OUT" = BEHIND ] && [ "$RC" = 1 ] \
  || fail "CLI should print BEHIND / exit 1 for an out-of-date PR" "$OUT rc=$RC"
GH_ROW=$(row MERGED '' '' '' pass); run_cli 77 --repo acme/widgets
[ "$OUT" = MERGED ] && [ "$RC" = 1 ] \
  || fail "CLI should print MERGED / exit 1 once the PR has landed" "$OUT rc=$RC"
ok "CLI exit code is the gate: 0 only for READY, 1 for every other verdict"

# stdout stays ONE bare token even with -q; diagnostics are stderr-only.
GH_ROW=$(row OPEN MERGEABLE CLEAN '' pending); run_cli 77 --repo acme/widgets -q
[ "$OUT" = PENDING ] || fail "-q must still print the verdict token" "$OUT"
[ -z "$ERR" ]        || fail "-q must suppress the stderr note" "$ERR"
GH_ROW=$(row OPEN MERGEABLE CLEAN '' pending); run_cli 77 --repo acme/widgets
[ -n "$ERR" ] || fail "without -q the CLI should explain the verdict on stderr"
ok "stdout is the bare token; the human note is stderr-only (-q silences it)"

# Error contract: exit 2, and NOTHING on stdout that could read as a verdict.
GH_RC=1 GH_ROW='' run_cli 77 --repo acme/widgets
[ "$RC" = 2 ] || fail "a failed gh read must exit 2 (got $RC)" "$ERR"
[ -z "$OUT" ] || fail "a failed gh read must print no verdict" "$OUT"
GH_RC=0 GH_ROW='' run_cli 77 --repo acme/widgets
[ "$RC" = 2 ] || fail "an empty gh read (no such PR) must exit 2 (got $RC)" "$ERR"
GH_ROW=$(row OPEN MERGEABLE CLEAN '' pass); run_cli --repo acme/widgets
[ "$RC" = 2 ] || fail "a missing PR number must exit 2 (got $RC)" "$ERR"
GH_ROW=$(row OPEN MERGEABLE CLEAN '' pass); run_cli 77 --repo acme/widgets --bogus
[ "$RC" = 2 ] || fail "an unknown flag must exit 2 (got $RC)" "$ERR"
ok "errors (bad args, unreadable PR) exit 2 with an empty stdout"

# gh absent → exit 2, never a verdict guess. A PATH with no `gh` on it at all: the
# only external the CLI needs before that check is `dirname` (it resolves its own
# bin dir), so link just that in and invoke bash by absolute path — PATH is empty
# of everything else on purpose.
mkdir -p "$WORK/nogh"
ln -sf "$(command -v dirname)" "$WORK/nogh/dirname"
OUT=$(env PATH="$WORK/nogh" TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
          "$(command -v bash)" "$CLI" 77 --repo acme/widgets 2>"$WORK/err"); RC=$?
[ "$RC" = 2 ] || fail "no gh on PATH must exit 2 (got $RC)" "$(cat "$WORK/err")"
[ -z "$OUT" ] || fail "no gh on PATH must print no verdict" "$OUT"
ok "gh missing → exit 2, no verdict invented"

# ===== WAIT: --wait / --until-merged (issue #950) ==============================
if ! command -v jq >/dev/null 2>&1; then
  printf 'skip WAIT layer: no jq on PATH to run the real --jq program\n'
  printf '\nfleet-pr-verdict-selftest: %d checks passed\n' "$pass"; exit 0
fi
mkdir -p "$WORK/waitbin"
# fake gh: call N serves $GH_SEQ/N.json (the LAST fixture once N runs past the
# end) through the --jq program the script passed; a fixture reading RC=1 is a
# failed read. Every call is counted in $GH_SEQ/calls.
cat > "$WORK/waitbin/gh" <<'GHFAKE'
#!/bin/bash
prog=''; while [ "$#" -gt 0 ]; do [ "$1" = --jq ] && { shift; prog="$1"; }; shift; done
n=$(( $(cat "$GH_SEQ/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$GH_SEQ/calls"
k=$n; while [ "$k" -gt 1 ] && [ ! -f "$GH_SEQ/$k.json" ]; do k=$((k - 1)); done
f="$GH_SEQ/$k.json"
[ "$(cat "$f")" = RC=1 ] && exit 1
jq -r "$prog" < "$f"
GHFAKE
cat > "$WORK/waitbin/sleep" <<'SLEEPFAKE'
#!/bin/bash
echo "$1" >> "$GH_SEQ/sleeps"
SLEEPFAKE
chmod +x "$WORK/waitbin/gh" "$WORK/waitbin/sleep"

# Check-run fragments, in the CheckRun shape the rollup returns.
C_PASS='{"status":"COMPLETED","conclusion":"SUCCESS"}'
C_FAIL='{"status":"COMPLETED","conclusion":"FAILURE"}'
C_RUN='{"status":"IN_PROGRESS","conclusion":null}'
seq_reset() { rm -rf "$WORK/seq"; mkdir -p "$WORK/seq"; }
# fx <n> <state> <mss> <checks-json-list> [auto] — the n-th poll's PR JSON.
fx() {
  local am=null; [ "${5:-}" = auto ] && am='{"mergeMethod":"SQUASH"}'
  printf '{"state":"%s","mergeable":"MERGEABLE","mergeStateStatus":"%s","isDraft":false,"statusCheckRollup":[%s],"autoMergeRequest":%s}\n' \
    "$2" "$3" "$4" "$am" > "$WORK/seq/$1.json"
}
run_wait() {  # run_wait <args…> → OUT/ERR/RC, CALLS (gh reads), SLEPT (sum of sleeps)
  OUT=$(env PATH="$WORK/waitbin:$PATH" TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 GH_SEQ="$WORK/seq" \
            bash "$CLI" 77 --repo acme/widgets "$@" 2>"$WORK/err"); RC=$?
  ERR=$(cat "$WORK/err"); CALLS=$(cat "$WORK/seq/calls" 2>/dev/null || echo 0)
  SLEPT=$(awk '{s+=$1} END {print s+0}' "$WORK/seq/sleeps" 2>/dev/null || echo 0)
}

# pending → pass → READY, exit 0.
seq_reset; fx 1 OPEN BLOCKED "$C_PASS,$C_RUN"; fx 2 OPEN BLOCKED "$C_PASS,$C_RUN"; fx 3 OPEN CLEAN "$C_PASS,$C_PASS"
run_wait --wait
[ "$OUT" = READY ] && [ "$RC" = 0 ] && [ "$CALLS" = 3 ] \
  || fail "--wait: pending→pass should end READY/0 on the 3rd read" "out=$OUT rc=$RC calls=$CALLS $ERR"
ok "--wait blocks through PENDING and returns READY when CI goes green"

# pending → ONE red lane while another still runs → FAILING at once (fail fast).
seq_reset; fx 1 OPEN BLOCKED "$C_RUN,$C_RUN"; fx 2 OPEN BLOCKED "$C_FAIL,$C_RUN"; fx 3 OPEN BLOCKED "$C_FAIL,$C_PASS"
run_wait --wait
[ "$OUT" = FAILING ] && [ "$RC" = 1 ] && [ "$CALLS" = 2 ] \
  || fail "--wait: a red lane beside a running one must be FAILING on that read" "out=$OUT rc=$RC calls=$CALLS $ERR"
ok "--wait fails fast: one red check ends the wait while other lanes still run"

# Already red when the wait starts → FAILING with no sleep at all (defect 1).
seq_reset; fx 1 OPEN UNSTABLE "$C_FAIL,$C_RUN"
run_wait --wait
[ "$OUT" = FAILING ] && [ "$CALLS" = 1 ] && [ "$SLEPT" = 0 ] \
  || fail "--wait on an already-red PR must return FAILING without a probe delay" "out=$OUT calls=$CALLS slept=$SLEPT $ERR"
ok "--wait on an already-red PR answers FAILING immediately (no probe loop)"

# Empty rollup — even with mss=CLEAN, which the one-shot reads as READY — keeps
# waiting, and its bound ends UNDETERMINED (TIMEOUT/3), never red (defect 2).
seq_reset; fx 1 OPEN CLEAN ""
run_wait --wait --no-checks-timeout 60
[ "$OUT" = TIMEOUT ] && [ "$RC" = 3 ] \
  || fail "--wait with no checks should end TIMEOUT/3" "out=$OUT rc=$RC $ERR"
[ "$SLEPT" -ge 60 ] && [ "$CALLS" -gt 1 ] || fail "--wait gave up on no-checks before its bound" "slept=$SLEPT calls=$CALLS"
case "$ERR" in *UNDETERMINED*mss=CLEAN*) : ;; *) fail "no-checks timeout must say UNDETERMINED + the mss" "$ERR" ;; esac
seq_reset; fx 1 OPEN CLEAN ""; fx 2 OPEN BLOCKED "$C_RUN"; fx 3 OPEN CLEAN "$C_PASS"
run_wait --wait
[ "$OUT" = READY ] && [ "$CALLS" = 3 ] || fail "late-registering CI should be waited for, then READY" "out=$OUT calls=$CALLS $ERR"
ok "no checks yet = keep waiting (not READY, not red); its bound is TIMEOUT/3 + mss"

# A rebase/re-run resets the check set mid-wait → keep waiting, don't flip.
seq_reset; fx 1 OPEN BLOCKED "$C_RUN"; fx 2 OPEN CLEAN ""; fx 3 OPEN BLOCKED "$C_RUN,$C_RUN"; fx 4 OPEN CLEAN "$C_PASS,$C_PASS"
run_wait --wait
[ "$OUT" = READY ] && [ "$CALLS" = 4 ] || fail "a mid-wait check reset must keep waiting" "out=$OUT calls=$CALLS $ERR"
ok "a check set reset mid-wait (pending→empty→pending) keeps waiting"

# The whole-wait bound: PENDING forever → TIMEOUT/3.
seq_reset; fx 1 OPEN BLOCKED "$C_RUN"
run_wait --wait --timeout 100
[ "$OUT" = TIMEOUT ] && [ "$RC" = 3 ] && [ "$SLEPT" -ge 100 ] \
  || fail "--timeout should end a stuck PENDING as TIMEOUT/3" "out=$OUT rc=$RC slept=$SLEPT $ERR"
ok "--timeout bounds the whole wait → TIMEOUT, exit 3"

# API budget: never below 10s; 20s while CI is young; --interval after.
seq_reset; fx 1 OPEN BLOCKED "$C_RUN"
run_wait --wait --timeout 300 --interval 1
[ "$(awk '$1<10' "$WORK/seq/sleeps" | wc -l | tr -d ' ')" = 0 ] || fail "a poll went below the 10s floor" "$(cat "$WORK/seq/sleeps")"
[ "$(head -1 "$WORK/seq/sleeps")" = 20 ] || fail "young CI should poll every 20s" "$(cat "$WORK/seq/sleeps")"
[ "$(tail -1 "$WORK/seq/sleeps")" = 10 ] || fail "--interval should apply after the first 2 minutes" "$(cat "$WORK/seq/sleeps")"
ok "polling respects the shared API budget: ≥10s always, 20s while CI is young"

# BEHIND mid-wait leaves the wait (update-branch is the worker's move).
seq_reset; fx 1 OPEN BLOCKED "$C_RUN"; fx 2 OPEN BEHIND "$C_PASS"
run_wait --wait
[ "$OUT" = BEHIND ] && [ "$RC" = 1 ] || fail "--wait should return BEHIND" "out=$OUT rc=$RC"
# A transient read failure mid-wait is retried, not fatal.
seq_reset; fx 1 OPEN BLOCKED "$C_RUN"; echo RC=1 > "$WORK/seq/2.json"; fx 3 OPEN CLEAN "$C_PASS"
run_wait --wait
[ "$OUT" = READY ] && [ "$RC" = 0 ] || fail "one failed read mid-wait must be retried" "out=$OUT rc=$RC $ERR"
seq_reset; fx 1 OPEN BLOCKED "$C_RUN"; echo RC=1 > "$WORK/seq/2.json"
run_wait --wait
[ "$RC" = 2 ] && [ -z "$OUT" ] || fail "5 failed reads in a row must exit 2 with no verdict" "out=$OUT rc=$RC"
ok "--wait returns any non-PENDING verdict; flaky reads retry, a dead read exits 2"

# --until-merged: READY with auto-merge ARMED keeps waiting → MERGED, exit 0.
seq_reset; fx 1 OPEN BLOCKED "$C_RUN"; fx 2 OPEN CLEAN "$C_PASS" auto; fx 3 OPEN CLEAN "$C_PASS" auto; fx 4 MERGED "" "$C_PASS"
run_wait --until-merged
[ "$OUT" = MERGED ] && [ "$RC" = 0 ] && [ "$CALLS" = 4 ] \
  || fail "--until-merged should wait an armed READY out to MERGED/0" "out=$OUT rc=$RC calls=$CALLS $ERR"
seq_reset; fx 1 OPEN CLEAN "$C_PASS"
run_wait --until-merged
[ "$OUT" = READY ] && [ "$RC" = 0 ] && [ "$CALLS" = 1 ] \
  || fail "--until-merged with nothing armed should hand READY back" "out=$OUT rc=$RC calls=$CALLS"
ok "--until-merged: an armed READY waits to MERGED; unarmed READY returns (you merge)"

# Duration flags are validated like everything else: exit 2.
seq_reset; fx 1 OPEN CLEAN "$C_PASS"
run_wait --wait --timeout soon
[ "$RC" = 2 ] || fail "a non-numeric --timeout must exit 2 (got $RC)"
ok "a malformed duration is an error (exit 2)"

printf '\nfleet-pr-verdict-selftest: %d checks passed\n' "$pass"
exit 0
