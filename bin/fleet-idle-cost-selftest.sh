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
for f in fleet-idle-cost.sh fleet-idle-cost.py fleet-lib.sh fleet-doctor.sh; do
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
out=$(FLEET_IDLE_SELF_WIN="$W" idle); rc=$?
[ "$rc" = 0 ] || fail "A2: the caller's own window is not someone working" "$out"
has idle "$out" "A2: idle says so"
tmux -L "$SOCK" set-option -w -t "$W" @claude_state done
out=$(idle); rc=$?
[ "$rc" = 0 ] || fail "A3: a done worker is idle" "$out"
tmux -L "$SOCK" set-option -w -t "$W" @fleet_role panel
tmux -L "$SOCK" set-option -w -t "$W" @claude_state working
out=$(idle); rc=$?
[ "$rc" = 0 ] || fail "A4: only a worker window counts (a panel's state is not work)" "$out"
tmux -L "$SOCK" set-option -w -t "$W" @fleet_role worker
tmux -L "$SOCK" set-option -w -t "$W" @claude_state done
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
tmux -L "$SOCK" set-option -w -t "$W" @claude_state done

# --- C: the fake spawner is ranked first, its rate within 30% -----------------
# A ranking can only be pinned on a quiet box — the condition the tool measures
# in. A 3 s baseline over FLEET_IDLE_COST_SELFTEST_NOISE (30 a second: a busy
# worker's Mac) skips this leg with one line; a CI runner is quiet and runs it.
python3 "$BIN/fleet-idle-cost.py" sample --secs 3 --min-age 1 --out "$WORK/base.json" || fail "C0: the sampler failed"
base=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rate"])' "$WORK/base.json")
if awk -v b="$base" -v n="${FLEET_IDLE_COST_SELFTEST_NOISE:-30}" 'BEGIN{ exit !(b > n) }'; then
  echo "SKIP C: this machine starts $base processes a second on its own — too busy to pin a ranking"
else
cat > "$WORK/fake.sh" <<'SH'
n=0; while :; do /usr/bin/true; n=$((n+1)); echo "$n" > "$1.tmp"; mv -f "$1.tmp" "$1"; sleep 0.1; done
SH
bash "$WORK/fake.sh" "$WORK/cnt" & fp=$!; PIDS="$PIDS $fp"
sleep 2
n0=$(cat "$WORK/cnt"); t0=$(python3 -c 'import time; print(time.time())')
python3 "$BIN/fleet-idle-cost.py" sample --secs 8 --min-age 1 --out "$WORK/r.json" || fail "C: the sampler failed"
n1=$(cat "$WORK/cnt"); t1=$(python3 -c 'import time; print(time.time())')
kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
# each loop turn starts two processes: true and sleep
read -r top_pid top_rate truth <<EOF
$(python3 - "$WORK/r.json" "$n0" "$n1" "$t0" "$t1" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
n0, n1, t0, t1 = int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
top = r["spawn_top"][0] if r["spawn_top"] else {"pid": 0, "rate": 0}
print(top["pid"], top["rate"], round(2 * (n1 - n0) / (t1 - t0), 2))
PY
)
EOF
CHECKS=$((CHECKS + 1))
[ "$top_pid" = "$fp" ] || fail "C1: the fake program (pid $fp) must rank first" "$(python3 "$BIN/fleet-idle-cost.py" render "$WORK/r.json")"
CHECKS=$((CHECKS + 1))
awk -v r="$top_rate" -v t="$truth" 'BEGIN{ d = r - t; if (d < 0) d = -d; exit !(t > 0 && d <= 0.3 * t) }' \
  || fail "C2: its rate $top_rate/s must be within 30% of the real $truth/s" "$(python3 "$BIN/fleet-idle-cost.py" render "$WORK/r.json")"
out=$(python3 "$BIN/fleet-idle-cost.py" render "$WORK/r.json")
has "$(printf 'spawn\t1\t')" "$out" "C3: the TSV lists the ranking"
has "$(printf 'idle-cost\t')" "$out" "C3: the TSV leads with the rate line"
fi

# --- D: idle ⇒ the wrapper keeps the reading ---------------------------------
out=$(bash "$BIN/fleet-idle-cost.sh" --secs 1 --top 3); rc=$?
[ "$rc" = 0 ] || fail "D1: idle must measure (exit 0)" "$out"
has "$(printf 'idle-cost\t')" "$out" "D1: a measured reading"
[ -f "$FLEET_CONF_DIR/idle-cost/last.json" ] || fail "D2: the reading is kept"
out=$(bash "$BIN/fleet-idle-cost.sh" --last --json)
printf '%s' "$out" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["state"] == "idle" and "rate" in r' \
  || fail "D3: --last --json prints the kept reading as JSON" "$out"

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
