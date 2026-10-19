#!/bin/bash
# fleet-idle-cost-selftest.sh — bin/fleet-idle-cost.sh, bin/fleet-idle-cost.py,
# the idle predicate fleet_idle_now (bin/fleet-lib.sh) and the doctor's
# `idle-cost` row (bin/fleet-doctor.sh) — issue #4355, EPIC #4354 C1.
#
#   A  fleet_idle_now: a worker window @claude_state working on a fleet socket ⇒
#      busy; the caller's own window (FLEET_IDLE_SELF_WIN) does not count; done ⇒
#      idle; a CI job (a process carrying FLEET_CI_WORKER_PAT) ⇒ busy
#   B  busy ⇒ fleet-idle-cost.sh measures nothing: exit 3, `idle-cost<TAB>busy`,
#      the JSON says state busy, no reading kept
#   C  a fake background program starting `true` every 0.1 s is ranked FIRST,
#      and its rate is within 30% of what it really started
#   D  idle ⇒ the wrapper keeps the reading (--last prints it); --json is JSON
#   E  the doctor row: busy ⇒ INFO 「未量」; a kept reading over the threshold ⇒
#      WARN naming the top source; under ⇒ PASS
#
# Isolated: its own tmux socket (tmux -L), a sandbox FLEET_CONF_DIR, a CI pattern
# no real runner carries (GitHub's own job runs under a Runner.Worker).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
for f in fleet-idle-cost.sh fleet-idle-cost.py fleet-lib.sh fleet-client-core.sh fleet-doctor.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done
command -v tmux >/dev/null 2>&1 || { echo "SKIP: no tmux"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/idle-cost-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SOCK="idlecost$$"
PIDS=''
cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null
  for p in $PIDS; do kill "$p" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT
export FLEET_CONF_DIR="$WORK/conf"
export FLEET_MACHINE_SESSIONS_DIR="$WORK/sessions"
export FLEET_MACHINE_SESSIONS_OWNER_CHECK=0
mkdir -p "$FLEET_MACHINE_SESSIONS_DIR"
# The fixture owns one simulated login. Real neighbours on a shared Mac must
# not leak into it; peer-state and missing-inventory cases are exercised below
# and in acceptance.py. Other ps formats (the doctor / load harness) stay real.
IDLE_TEST_PS="$(command -v ps)"; IDLE_TEST_UID="$(id -u)"
export IDLE_TEST_PS IDLE_TEST_UID
mkdir -p "$WORK/bin"
cat > "$WORK/bin/ps" <<'PS_SHIM'
#!/bin/sh
if [ "$*" = '-axo pid=,ppid=,uid=,etime=,time=,command=' ]; then
  "$IDLE_TEST_PS" "$@" | awk -v uid="$IDLE_TEST_UID" '$3 == uid'
else exec "$IDLE_TEST_PS" "$@"; fi
PS_SHIM
chmod +x "$WORK/bin/ps"
export PATH="$WORK/bin:$PATH"
export FLEET_CI_WORKER_PAT="idlecost-ci-$$-marker"
mkdir -p "$FLEET_CONF_DIR/fleets/$SOCK"
printf 'FLEET_SESSION=%s\n' "$SOCK" > "$FLEET_CONF_DIR/fleets/$SOCK/conf"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; printf -- '--- got ---\n%s\n' "${2:-(none)}" >&2; exit 1; }
has()  { CHECKS=$((CHECKS + 1)); case "$2" in *"$1"*) ;; *) fail "$3" "$2" ;; esac; }
idle() { ( unset TMUX TMUX_PANE; . "$BIN/fleet-lib.sh"; fleet_idle_now ); }

# --- A: the predicate ---------------------------------------------------------
tmux -L "$SOCK" -f /dev/null new-session -d -s "$SOCK" -n home 'sleep 600' || fail "A: cannot start a test tmux server"
W=$(tmux -L "$SOCK" new-window -d -P -F '#{window_id}' -t "$SOCK" -n issue-1 'sleep 600')
tmux -L "$SOCK" set-option -w -t "$W" @fleet_role worker
tmux -L "$SOCK" set-option -w -t "$W" @claude_state working
out=$(idle); rc=$?
[ "$rc" = 1 ] || fail "A1: a working worker window must read busy (rc 1)" "$out"
has "working: 1" "$out" "A1: the reason names the working session"
SP=$(tmux -L "$SOCK" display-message -p -t "$W" '#{socket_path}')
out=$(FLEET_IDLE_SELF_WIN="$W" FLEET_IDLE_SELF_SOCKET="$SP" idle); rc=$?
[ "$rc" = 0 ] || fail "A2: the caller's own window is not someone working" "$out"
has idle "$out" "A2: idle says so"
tmux -L "$SOCK" set-option -w -t "$W" @claude_state 'done'
out=$(idle); rc=$?
[ "$rc" = 0 ] || fail "A3: a done worker is idle" "$out"
tmux -L "$SOCK" set-option -w -t "$W" @fleet_role panel
tmux -L "$SOCK" set-option -w -t "$W" @claude_state working
out=$(idle); rc=$?
[ "$rc" = 0 ] || fail "A4: only a worker window counts (a panel's state is not work)" "$out"
tmux -L "$SOCK" set-option -w -t "$W" @fleet_role worker
tmux -L "$SOCK" set-option -w -t "$W" @claude_state 'done'
sh -c "sleep 30; : $FLEET_CI_WORKER_PAT" & cip=$!; PIDS="$PIDS $cip"
sleep 0.3
out=$(idle); rc=$?
[ "$rc" = 1 ] || fail "A5: a running CI job must read busy" "$out"
has "ci: 1" "$out" "A5: the reason names the CI job"
kill "$cip" 2>/dev/null; wait "$cip" 2>/dev/null
out=$(bash "$BIN/fleet-idle-cost.sh" --idle); rc=$?
[ "$rc" = 0 ] || fail "A6: --idle is the same predicate" "$out"

# --- B: busy ⇒ nothing measured ----------------------------------------------
tmux -L "$SOCK" set-option -w -t "$W" @claude_state working
out=$(bash "$BIN/fleet-idle-cost.sh" --secs 1); rc=$?
[ "$rc" = 3 ] || fail "B1: busy must exit 3, unmeasured" "$out"
has "$(printf 'idle-cost\tbusy\tworking: 1')" "$out" "B1: one busy line with the reason"
[ ! -f "$FLEET_CONF_DIR/idle-cost/last.json" ] || fail "B2: a busy run keeps no reading"
out=$(bash "$BIN/fleet-idle-cost.sh" --secs 1 --json); rc=$?
[ "$rc" = 3 ] || fail "B3: --json busy exits 3" "$out"
has '"state": "busy"' "$out" "B3: the JSON says busy"
tmux -L "$SOCK" set-option -w -t "$W" @claude_state 'done'

# --- C: bounded real spawner, isolated counter + attribution regression --------
# The supported load harness owns the experiment; its command gives the fake
# spawner its own kernel deadline too. No noise-based skip of the 30% assertion.
bash "$BIN/fleet-loadgen.sh" 1 20 -- python3 "$BIN/../tests/idle-cost/acceptance.py" "$WORK" "$BIN" \
  || fail "C: bounded spawner / sampler acceptance failed"

# --- D: idle ⇒ the wrapper keeps the reading ---------------------------------
out=$(bash "$BIN/fleet-idle-cost.sh" --secs 1 --top 3); rc=$?
[ "$rc" = 0 ] || fail "D1: idle must measure (exit 0)" "$out"
has "$(printf 'idle-cost\t')" "$out" "D1: a measured reading"
[ -f "$FLEET_CONF_DIR/idle-cost/last.json" ] || fail "D2: the reading is kept"
out=$(bash "$BIN/fleet-idle-cost.sh" --last --json)
printf '%s' "$out" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["state"] == "idle" and "rate" in r' \
  || fail "D3: --last --json prints the kept reading as JSON" "$out"

# An entire busy interval inside the window invalidates it. The old reading
# must survive. Drive only this test's isolated socket, with a bounded helper.
cp "$FLEET_CONF_DIR/idle-cost/last.json" "$WORK/kept.json"
python3 - "$SOCK" "$W" <<'PY_BUSY' &
import subprocess, sys, time
sock, win = sys.argv[1:]
time.sleep(0.8)
subprocess.run(["tmux", "-L", sock, "set-option", "-w", "-t", win, "@claude_state", "working"], check=True)
time.sleep(0.6)
subprocess.run(["tmux", "-L", sock, "set-option", "-w", "-t", win, "@claude_state", "done"], check=True)
PY_BUSY
bpid=$!; PIDS="$PIDS $bpid"
out=$(bash "$BIN/fleet-idle-cost.sh" --secs 3); rc=$?
wait "$bpid"
[ "$rc" = 3 ] || fail "D4: busy wholly inside the window must invalidate it" "$out"
cmp -s "$WORK/kept.json" "$FLEET_CONF_DIR/idle-cost/last.json" || fail "D5: rejected sample replaced the last good reading"

# Another login, and absent / stale / old publishers, never certify idle.
python3 - "$FLEET_MACHINE_SESSIONS_DIR/peer" <<'PY_PEER'
import json, sys, time
with open(sys.argv[1], "w") as f:
    f.write("1 %d 0\nidle-v1 %s\n" % (time.time(), json.dumps({"ts": time.time(), "working": 1, "unknown": False, "changed": 0})))
PY_PEER
out=$(idle); rc=$?
[ "$rc" = 1 ] || fail "D6: another login's working session must refuse idle" "$out"
has "login peer" "$out" "D6: busy reason names the login"
printf '1 %s 0\n' "$(date +%s)" > "$FLEET_MACHINE_SESSIONS_DIR/peer"
out=$(idle); rc=$?
[ "$rc" = 1 ] || fail "D7: old publisher without working state is unknown" "$out"
has unknown "$out" "D7: unknown is explicit"
printf '0 1 0\n' > "$FLEET_MACHINE_SESSIONS_DIR/peer"
out=$(idle); rc=$?
[ "$rc" = 1 ] || fail "D8: a stale zero is not idle" "$out"
rm "$FLEET_MACHINE_SESSIONS_DIR/peer"

# --- E: the doctor row ---------------------------------------------------------
doc_row() {
  ( unset TMUX TMUX_PANE
    HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_DOCTOR_IDLE_COST=1 FLEET_DOCTOR_IDLE_COST_SECS=1 "$@" \
      sh "$BIN/fleet-doctor.sh" 2>/dev/null ) | grep -aE '^[[:space:]]+(PASS|WARN|INFO|FAIL)[[:space:]]+idle-cost' | head -1
}
python3 - "$FLEET_CONF_DIR/idle-cost/last.json" <<'PY'
import json, sys, time
json.dump({"ts": int(time.time()), "state": "idle", "secs": 60, "rate": 180.5, "new": 10830,
           "method": "pid", "spawn_top": [{"rank": 1, "pid": 42, "who": "bash tmux-spinner.sh", "seen": 9, "rate": 90.1},
                                          {"rank": 2, "pid": 43, "who": "ccquota agent", "seen": 5, "rate": 50.0}],
           "cpu_top": [], "fleet_cpu_pct": 3.0, "load": [1, 1, 1], "cores": 8}, open(sys.argv[1], "w"))
PY
l=$(doc_row env)
has WARN "$l" "E1: a kept reading over 50/s must WARN"
has "180.5" "$l" "E1: the WARN states the rate"
has "tmux-spinner.sh" "$l" "E1: the WARN names the biggest source"
l=$(doc_row env FLEET_IDLE_COST_WARN=500)
has PASS "$l" "E2: under the threshold ⇒ PASS"
tmux -L "$SOCK" set-option -w -t "$W" @claude_state working
l=$(doc_row env)
has INFO "$l" "E3: busy ⇒ INFO, unmeasured"
has "未量" "$l" "E3: busy says 未量"
l=$( ( unset TMUX TMUX_PANE; HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_DOCTOR_IDLE_COST=0 sh "$BIN/fleet-doctor.sh" 2>/dev/null ) | grep -aE '^[[:space:]]+(PASS|WARN|INFO|FAIL)[[:space:]]+idle-cost' | head -1)
[ -z "$l" ] || fail "E4: FLEET_DOCTOR_IDLE_COST=0 silences the row" "$l"

echo "PASS fleet-idle-cost-selftest ($CHECKS checks)"
