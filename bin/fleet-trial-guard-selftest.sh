#!/bin/bash
# fleet-trial-guard-selftest.sh — a trial login held to its share of the machine
# (claude-fleet WACK C4): bin/fleet-trial-guard.py, bin/fleet_trial.py and
# bin/fleet-memguard.sh's rule T.
#
# The hub's list, the accounts and the process table are stubbed
# (FLEET_TRIAL_LIST · FLEET_TRIAL_PASSWD · FLEET_TRIAL_PS_CMD): the real `ps` is
# read, and each fleet-loadgen.sh burner is given the uid of the login its tag
# names — so the renice and the pause land on REAL burners, read back with
# `ps -o nice=,stat=`, and the member's burner beside them is asserted untouched.
#
#   1 a trial login over its cpu (2 burners on a 1-core share) → renice + trial_runaway;
#     still over → pause (stat T) + trial_runaway; the member's burner: nice 0, running
#   2 resume → running again, nice 0
#   3 a miner name · a pool port · a burst of new connections → pause + trial_abuse
#   4 home over its size → warn; over 120 % → pause (disk)
#   5 the hub stops naming a paused login (转正) → resumed; never a member's
#   6 memguard rule T: the uid's RSS over its line → its largest process killed, the
#     guard's next pass raises trial_runaway mem; the agent is spared
#   7 the doctor's line: OK · WARN paused · WARN stale · INFO when the guard never ran
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
G="$BIN/fleet-trial-guard.py"
LG="$BIN/fleet-loadgen.sh"
st_sandbox "${TMPDIR:-/tmp}/trial-guard.XXXXXX"
TAG="tg$$"
SPAWNED=''
cleanup() {
  for p in $SPAWNED; do kill -CONT "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; done
  # a paused burner holds its SIGTERM until it runs again
  for p in $(pgrep -f "$TAG" 2>/dev/null); do kill -CONT "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; done
  bash "$LG" --stop "${TAG}t" >/dev/null 2>&1; bash "$LG" --stop "${TAG}m" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; for f in alerts actions.log; do [ -f "$WORK/$f" ] && sed 's/^/  /' "$WORK/$f" >&2; done
  [ -f "$WORK/trial/actions.log" ] && sed 's/^/  act /' "$WORK/trial/actions.log" >&2; exit 1; }
ok() { CHECKS=$((CHECKS + 1)); }

export FLEET_NODE_TEST=1 FLEET_NODE_CORE=0 FLEET_TRIAL_DIR="$WORK/trial" FLEET_NODE_STATE="$WORK/db"
export FLEET_TRIAL_LIST="$WORK/list.json" FLEET_TRIAL_PASSWD="$WORK/passwd.json" FLEET_TRIAL_ALERT_LOG="$WORK/alerts"
export FLEET_TRIAL_NET_CMD="cat $WORK/net 2>/dev/null" FLEET_TRIAL_DU_CMD="cat $WORK/du 2>/dev/null"
mkdir -p "$WORK/db" "$WORK/home/tria" "$WORK/home/memb"
: > "$WORK/net"; echo 1 > "$WORK/du"
printf '{"tria": {"uid": 9001, "home": "%s"}, "memb": {"uid": 9002, "home": "%s"}}\n' "$WORK/home/tria" "$WORK/home/memb" > "$WORK/passwd.json"
list() {   # list <cpu> <mem_bytes> <disk_bytes> <login…> — the hub's answer
  local cpu="$1" mem="$2" disk="$3" l first=1; shift 3
  { printf '{"on": true, "limits": "cpu=%s", "cpu": %s, "mem_bytes": %s, "disk_bytes": %s, "logins": {' "$cpu" "$cpu" "$mem" "$disk"
    for l in "$@"; do [ "$first" = 1 ] || printf ', '; first=0; printf '"%s": "wx-%s"' "$l" "$l"; done
    printf '}}\n'; } > "$WORK/list.json"
}
# the real ps, each burner given its login's uid by its tag; nothing else of ours
export FLEET_TRIAL_PS_CMD="ps -A -ww -o pid=,uid=,pcpu=,rss=,args= | awk '/${TAG}t/ && !/awk/ { \$2 = 9001; print; next } /${TAG}m/ && !/awk/ { \$2 = 9002; print }'; cat $WORK/ps-extra 2>/dev/null"
: > "$WORK/ps-extra"
tick() { python3 "$G" tick || fail "tick exited $?"; }
chk() { python3 "$G" check; true; }   # WARN exits 1: the line is what is read
burners() { pgrep -f "$1" 2>/dev/null | while read -r p; do ps -o args= -p "$p" | grep -q SECONDS && echo "$p"; done; }
nice_of() { ps -o nice= -p "$1" | tr -d ' '; }
stat_of() { ps -o stat= -p "$1" | tr -d ' '; }

# --- 1: real load, a 1-core share ------------------------------------------------
list 1 $((8 << 30)) $((20 << 30)) tria
bash "$LG" 1 120 --force --tag "${TAG}m" --detach >/dev/null 2>&1 || fail "loadgen (member) refused"
bash "$LG" 2 120 --force --tag "${TAG}t" --detach >/dev/null 2>&1 || fail "loadgen (trial) refused"
sleep 4
TB=$(burners "${TAG}t"); MB=$(burners "${TAG}m")
SPAWNED="$TB $MB"
[ "$(printf '%s\n' "$TB" | grep -c .)" = 2 ] && [ -n "$MB" ] || fail "burners not found: trial [$TB] member [$MB]"
export FLEET_TRIAL_CPU_STRIKES=2 FLEET_TRIAL_PAUSE_STRIKES=2
# macOS' %CPU is a decaying average: tick until the share is over twice running
n=0; while [ "$n" -lt 15 ]; do tick; grep -q '"renice"' "$WORK/alerts" 2>/dev/null && break; sleep 1; n=$((n + 1)); done
for p in $TB; do [ "$(nice_of "$p")" -ge 10 ] || fail "trial burner $p not reniced (nice $(nice_of "$p"))"; done; ok
for p in $MB; do [ "$(nice_of "$p")" = 0 ] || fail "the member's burner $p was reniced"; done; ok
grep -q '"what": "cpu".*' "$WORK/alerts" && grep '"action": "renice"' "$WORK/alerts" | grep -q '"kind": "runaway"' \
  || fail "no trial_runaway cpu renice alert"; ok
n=0; while [ "$n" -lt 15 ]; do tick; grep -q '"pause"' "$WORK/alerts" 2>/dev/null && break; sleep 1; n=$((n + 1)); done
for p in $TB; do case "$(stat_of "$p")" in T*) ;; *) fail "trial burner $p not paused (stat $(stat_of "$p"))" ;; esac; done; ok
for p in $MB; do case "$(stat_of "$p")" in T*) fail "the member's burner $p was paused" ;; esac; done; ok
grep '"action": "pause"' "$WORK/alerts" | grep -q '"what": "cpu"' || fail "no pause alert"; ok
chk | grep -q '^trial-limits: WARN — .*tria（cpu）' || fail "doctor line while paused: $(chk)"; ok

# --- 2: resume ----------------------------------------------------------------
python3 "$G" resume tria >/dev/null || fail "resume exited $?"
for p in $TB; do case "$(stat_of "$p")" in T*) fail "burner $p still stopped after resume" ;; esac; done; ok
bash "$LG" --stop "${TAG}t" >/dev/null 2>&1; bash "$LG" --stop "${TAG}m" >/dev/null 2>&1
tick
grep -q '"clear": true' "$WORK/alerts" || fail "resume cleared no alert"; ok

# --- 3: miner · pool · scan (acted on by record only) ---------------------------
export FLEET_TRIAL_ACT=record
reset_tria() { python3 "$G" resume tria >/dev/null; : > "$WORK/alerts"; : > "$WORK/trial/actions.log"; }
reset_tria
printf '4100001 9001 3.0 2048 ./xmrig -o pool.example:443\n' > "$WORK/ps-extra"
tick
grep '"kind": "abuse"' "$WORK/alerts" | grep -q '"what": "miner"' || fail "a miner was not written up"; ok
grep -q '^.* pause tria (miner' "$WORK/trial/actions.log" || fail "the miner's login was not paused"; ok
: > "$WORK/ps-extra"; reset_tria
printf '10.0.0.9:443\n198.51.100.7:3333\n' > "$WORK/net"
tick
grep '"kind": "abuse"' "$WORK/alerts" | grep -q '"what": "pool"' || fail "a pool port was not written up"; ok
reset_tria; : > "$WORK/net"; tick
awk 'BEGIN { for (i = 1; i <= 400; i++) printf "203.0.113.%d:%d\n", i % 250, 1000 + i }' > "$WORK/net"
tick
grep '"kind": "abuse"' "$WORK/alerts" | grep -q '"what": "scan"' || fail "400 new endpoints were not a scan"; ok

# --- 4: disk ------------------------------------------------------------------
reset_tria; : > "$WORK/net"; list 1 $((8 << 30)) $((1 << 30)) tria
export FLEET_TRIAL_DISK_EVERY=0
echo $(( 1100 * 1024 )) > "$WORK/du"       # KB: 1.07 GiB, over 1 G
tick
grep '"what": "disk"' "$WORK/alerts" | grep -q '"action": "warn"' || fail "home over its size: no warning"; ok
grep -q 'pause tria' "$WORK/trial/actions.log" && fail "a warning paused"; ok
echo $(( 1300 * 1024 )) > "$WORK/du"       # 1.27 GiB, past 120 %
tick
grep '"what": "disk"' "$WORK/alerts" | grep -q '"action": "pause"' || fail "home past 120%: not paused"; ok

# --- 5: no longer named (转正) ---------------------------------------------------
: > "$WORK/trial/actions.log"; echo 1 > "$WORK/du"
list 1 $((8 << 30)) $((20 << 30)) memb
tick
grep -q 'resume tria (no longer a trial login)' "$WORK/trial/actions.log" || fail "the converted login stayed paused"; ok
grep -q ' memb ' "$WORK/trial/actions.log" && fail "a quiet trial login was acted on"; ok

# --- 6: memguard rule T ---------------------------------------------------------
unset FLEET_TRIAL_ACT
list 1 $((100 << 20)) $((20 << 30)) tria
: > "$WORK/alerts"; tick
grep -q $'^9001\t100\ttria$' "$WORK/trial/mem.tsv" || fail "mem.tsv: $(cat "$WORK/trial/mem.tsv")"; ok
( exec sleep 300 ) & V=$!; disown "$V" 2>/dev/null; SPAWNED="$SPAWNED $V"
( exec sleep 300 ) & A=$!; disown "$A" 2>/dev/null; SPAWNED="$SPAWNED $A"
export FLEET_MEM_TRIAL_PS_CMD="printf '9001 $V 81920 sleep\n9001 $A 409600 claude\n9001 1 4 launchd\n9002 4100099 999999 big\n'"
export FLEET_MEM_PS_CMD="true" FLEET_MEM_PROBE_CMD="echo 1 50 0 0" FLEET_MEM_TOTAL_MB=65536 FLEET_CONF_DIR="$WORK/conf"
out=$(bash "$BIN/fleet-memguard.sh" --once --dry-run 2>&1)
printf '%s\n' "$out" | grep -q "trial	would-kill	$V	80MB" || fail "memguard dry-run: $out"; ok
kill -0 "$V" 2>/dev/null || fail "dry-run killed"; ok
bash "$BIN/fleet-memguard.sh" --once >/dev/null 2>&1
sleep 0.3
kill -0 "$V" 2>/dev/null && fail "rule T left the trial login's largest process"; ok
kill -0 "$A" 2>/dev/null || fail "rule T killed the agent"; ok
tick
grep '"what": "mem"' "$WORK/alerts" | grep -q '"action": "kill"' || fail "the guard did not report memguard's stop"; ok
list 1 $((100 << 20)) $((20 << 30))       # nobody on trial: no line, memguard reads nothing
tick; [ ! -s "$WORK/trial/mem.tsv" ] || fail "mem.tsv kept a line nobody is named for"; ok

# --- 7: the doctor's line -------------------------------------------------------
list 1 $((8 << 30)) $((20 << 30)) tria; python3 "$G" resume tria >/dev/null; tick
chk | grep -q '^trial-limits: OK — cpu=1 · 试用登录 1 个' || fail "doctor OK line: $(chk)"; ok
python3 - "$WORK/trial/status.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["at"] -= 3600; json.dump(s, open(p, "w"))
PY
chk | grep -q '^trial-limits: WARN — .*上次巡检 60 分钟前' || fail "stale doctor line: $(chk)"; ok
FLEET_TRIAL_DIR="$WORK/none" chk | grep -q '^trial-limits: INFO' || fail "no guard: not INFO"; ok

echo "fleet-trial-guard-selftest: $CHECKS checks passed"
