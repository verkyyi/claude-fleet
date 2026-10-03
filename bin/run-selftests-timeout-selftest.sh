#!/bin/bash
# run-selftests-timeout-selftest.sh — the gate's per-test ceiling + heavy queue (#1150).
#
# On 2026-09-24 one test sat on a `cat` of an open stdin for 77 minutes; nothing
# after it ran and the worker waiting on the backgrounded gate was never woken. The
# runner now supervises every test. Asserted, against a sandbox bin/ of fake tests:
#
#   • TIMEOUT     a test that never ends (`sleep 99999`, plus a background child) is
#                 killed at FLEET_SELFTEST_TEST_TIMEOUT, printed as TIMEOUT with its
#                 stuck process group, counted a failure, listed in the slowest
#                 table — and the tests AFTER it still run. No process survives.
#   • STUBBORN    a test that ignores SIGTERM is still gone (KILL after the grace).
#   • STDIN       a test reads EOF on stdin, never the runner's open pipe — the
#                 exact 9-24 hang, which needed no load at all, only that pipe.
#   • OFF         FLEET_SELFTEST_TEST_TIMEOUT=0 runs with no ceiling.
#   • BACKSTOP    SIGKILL the supervisor and the test still dies, on the alarm(2) it
#                 armed before exec (the deadline lives in the child, #697).
#   • HEAVY       the gate (no arg / a glob) runs under `fleet-heavy.sh --label selftests --`
#                 — a run of NAMED tests is light and skips it (#1313) — the
#                 suite sees FLEET_HEAVY_HELD=1 (a nested gate passes through
#                 instead of queueing behind its parent) and none of the wrapper's
#                 other FLEET_HEAVY_* — and FLEET_HEAVY=0 skips it.
#
# Hermetic: a sandbox install root (the runner, the shadow builder, a fake
# fleet-heavy.sh, fake tests). No network, no tmux. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$BIN/run-selftests.sh"
MK="$BIN/selftest-shadow-root.sh"
[ -f "$RUNNER" ] || { printf 'selftest: %s missing\n' "$RUNNER" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "selftest: SKIP — no perl, the runner runs tests unsupervised"; exit 0; }

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/  /' >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); printf 'ok   %s\n' "$1"; }
has()  { printf '%s\n' "$2" | grep -qE -- "$3" || fail "$1" "$2"; ok "$1"; }
hasnt() { printf '%s\n' "$2" | grep -qE -- "$3" && fail "$1" "$2"; ok "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/run-selftests-timeout-selftest.XXXXXX")" || exit 2
# A unique sleep length marks every process this test starts, so the residue check
# (and the cleanup) can find exactly ours and nothing else on the machine.
MARK=$((99000 + $$ % 900))
cleanup() { pkill -KILL -f "sleep $MARK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

mkdir -p "$WORK/bin" "$WORK/logs"
ln -s "$RUNNER" "$WORK/bin/run-selftests.sh"
ln -s "$MK"     "$WORK/bin/selftest-shadow-root.sh"
mk() { printf '#!/bin/bash\n%s\n' "$2" > "$WORK/bin/$1-selftest.sh"; chmod +x "$WORK/bin/$1-selftest.sh"; }

# In place (no shadow) unless a leg says otherwise; the outer gate's knobs stripped.
run() {
  ( cd "$WORK/bin" \
    && env -u FLEET_SELFTEST_ROOT -u FLEET_CONF_DIR -u FLEET_SKIP_GLOBAL_CONF \
           -u FLEET_SELFTEST_SLOWEST -u FLEET_HEAVY -u FLEET_HEAVY_HELD \
           FLEET_SELFTEST_NO_SHADOW=1 "$@" 2>&1 )
}
residue() { pgrep -f "sleep $MARK" 2>/dev/null | tr '\n' ' '; }

# ---- TIMEOUT: a hung test is killed, named, counted, and the run goes on -----------
mk a-first  'echo first ran'
mk b-hang   "echo hanging; ( sleep $MARK ) & sleep $MARK"
mk c-after  'echo after ran'
t0=$(date +%s)
out=$(run env FLEET_SELFTEST_TEST_TIMEOUT=2 sh ./run-selftests.sh </dev/null); rc=$?
el=$(( $(date +%s) - t0 ))
[ "$rc" -eq 1 ] || fail "a timed-out test must fail the gate (exit 1), got $rc" "$out"; ok "TIMEOUT fails the gate"
has   "TIMEOUT line names the test and the limit" "$out" '^TIMEOUT b-hang-selftest\.sh +[0-9]+\.[0-9]s \(limit 2s\)$'
has   "the stuck process group is printed (pid, argv)" "$out" "pid [0-9]+ .*sleep $MARK"
has   "the test after it still ran" "$out" '^PASS  c-after-selftest\.sh'
has   "failed: names the timed-out test" "$out" '^failed: b-hang-selftest\.sh$'
has   "summary counts it as a failure" "$out" '^3 test\(s\): 2 passed, 1 failed$'
has   "the timed-out test heads the slowest table" "$out" '^ +[0-9]+\.[0-9]s  b-hang-selftest\.sh$'
[ "$el" -lt 15 ] || fail "the gate took ${el}s with a 2s ceiling" "$out"; ok "the run ends near the ceiling (${el}s)"
sleep 0.3; r=$(residue)
[ -z "$r" ] || fail "processes from the timed-out test survived: $r"; ok "no process of the hung test survives"
rm -f "$WORK/bin/"[abc]-*-selftest.sh

# ---- STUBBORN: SIGTERM ignored → still killed ----------------------------------------
mk stubborn "trap '' TERM; sleep $MARK"
out=$(run env FLEET_SELFTEST_TEST_TIMEOUT=1 sh ./run-selftests.sh </dev/null)
has "a TERM-ignoring test is still a TIMEOUT" "$out" '^TIMEOUT stubborn-selftest\.sh'
sleep 0.3; r=$(residue)
[ -z "$r" ] || fail "a TERM-ignoring test survived: $r"; ok "…and KILL after the grace takes it"
rm -f "$WORK/bin/stubborn-selftest.sh"

# ---- STDIN: an open pipe on the runner's stdin never reaches a test ------------------
mk reads 'x=$(cat); echo "stdin=[$x]"'
for to in 5 0; do
  out=$( { sleep 3; echo leaked; } | run env FLEET_SELFTEST_TEST_TIMEOUT=$to sh ./run-selftests.sh )
  has "a test reading stdin gets EOF at once (timeout=$to)" "$out" '^PASS  reads-selftest\.sh +0\.[0-9]s'
  hasnt "…never the runner's stdin (timeout=$to)" "$out" 'leaked'
done
rm -f "$WORK/bin/reads-selftest.sh"

# ---- OFF: 0 = no ceiling --------------------------------------------------------------
mk slow 'sleep 2'
out=$(run env FLEET_SELFTEST_TEST_TIMEOUT=1 sh ./run-selftests.sh </dev/null)
has "control: a 2s test under a 1s ceiling is a TIMEOUT" "$out" '^TIMEOUT slow-selftest\.sh'
out=$(run env FLEET_SELFTEST_TEST_TIMEOUT=0 sh ./run-selftests.sh </dev/null)
has "FLEET_SELFTEST_TEST_TIMEOUT=0 lets it finish" "$out" '^PASS  slow-selftest\.sh'
rm -f "$WORK/bin/slow-selftest.sh"

# ---- BACKSTOP: a SIGKILLed supervisor still cannot leave the test running ----------
mk orphan "echo \$\$ > '$WORK/orphan.pid'; sleep $MARK"
run env FLEET_SELFTEST_TEST_TIMEOUT=1 sh ./run-selftests.sh </dev/null > "$WORK/orphan.out" &
for _ in $(seq 1 50); do [ -s "$WORK/orphan.pid" ] && break; sleep 0.1; done
tpid=$(cat "$WORK/orphan.pid" 2>/dev/null)
[ -n "$tpid" ] || fail "the backstop fixture never started"
sup=$(ps -o ppid= -p "$tpid" | tr -d ' ')
kill -KILL "$sup" 2>/dev/null || fail "could not SIGKILL the supervisor ($sup)"
gone=0
for _ in $(seq 1 300); do kill -0 "$tpid" 2>/dev/null || { gone=1; break; }; sleep 0.1; done
[ "$gone" -eq 1 ] || fail "the test outlived its SIGKILLed supervisor by 30s — no in-test deadline"
ok "the test dies on its own alarm after its supervisor is SIGKILLed"
wait
pkill -KILL -f "sleep $MARK" 2>/dev/null   # its child sleep is an orphan by design here
rm -f "$WORK/bin/orphan-selftest.sh"

# ---- HEAVY: the whole gate queues on fleet-heavy.sh ---------------------------------
cat > "$WORK/bin/fleet-heavy.sh" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/heavy.log"
while [ "\$1" != "--" ]; do shift; done; shift
FLEET_HEAVY_HELD=1 FLEET_HEAVY_DIR=/nonexistent FLEET_HEAVY_SLOTS=3 exec "\$@"
EOF
chmod +x "$WORK/bin/fleet-heavy.sh"
mk env-probe 'echo "probe HELD=${FLEET_HEAVY_HELD:-unset} DIR=${FLEET_HEAVY_DIR:-unset} SLOTS=${FLEET_HEAVY_SLOTS:-unset}"'
shadow_run() { ( cd "$WORK/bin" && env -u FLEET_SELFTEST_ROOT -u FLEET_SELFTEST_NO_SHADOW \
  -u FLEET_CONF_DIR -u FLEET_HEAVY_HELD -u FLEET_HEAVY "$@" sh ./run-selftests.sh "${PROBE_ARG:-env-probe*}" </dev/null 2>&1 ); }
out=$(shadow_run env)
has "the gate runs under fleet-heavy.sh --label selftests" "$(cat "$WORK/heavy.log" 2>/dev/null)" '^--label selftests -- env '
has "the suite sees FLEET_HEAVY_HELD=1, the wrapper's other keys scrubbed" "$out" '^probe HELD=1 DIR=unset SLOTS=unset$'
rm -f "$WORK/heavy.log"
out=$(shadow_run env FLEET_HEAVY=0)
[ ! -e "$WORK/heavy.log" ] || fail "FLEET_HEAVY=0 must skip the queue" "$(cat "$WORK/heavy.log")"; ok "FLEET_HEAVY=0 skips the queue"
has "…and the gate still runs" "$out" '^PASS  env-probe-selftest\.sh'
# A NAMED run (no glob, no option) is light (issue #1313): it never queues.
rm -f "$WORK/heavy.log"
out=$(PROBE_ARG=env-probe shadow_run env)
[ ! -e "$WORK/heavy.log" ] || fail "a named test run must skip the queue" "$(cat "$WORK/heavy.log")"; ok "a named test run skips the queue"
has "…and it still runs" "$out" '^PASS  env-probe-selftest\.sh'

printf 'selftest: run-selftests timeout PASS (%s checks)\n' "$CHECKS"
