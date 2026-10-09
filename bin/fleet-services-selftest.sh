#!/bin/bash
# fleet-services-selftest.sh — pins issue #2526 (EPIC #2524 C2): the background
# services and scheduled tasks a person registered are ONE table everywhere —
# `fleet ls --services`, the doctor's `services` row, the alert bar — read by
# bin/fleet-services.py off the hub's word (global/hub_services, written by
# fleet-hub-sessions.sh from `machines[].services` + the summary's `alerts`) and
# this machine's own daemon (fleet-node-supervisor.py's state.json).
#
#   A  the table: every machine's rows from the hub cache, this machine's from
#      the daemon (this login's only, its own log's last line); 上次 / 下次 as
#      a person reads them; --json carries `failed`
#   B  a machine the hub has a word for is never read twice off the daemon
#   C  the doctor line: FAIL names each failed entry and its last line · PASS
#      when all run · INFO 无登记 when nothing is registered
#   D  --alerts: one line per failed entry, since = the hub's raised_at
#   E  `fleet ls --services [--json]` (fleet-session-cli.py) prints that table
#      without the client running; a stray argument is usage (exit 2)
#   F  fleet-hub-sessions.sh --refresh writes hub_services: the machines that
#      carry a register, the service_failed alerts only
#   G  fleet-alerts.sh: a failed entry is `✖ service · failed`, action
#      `see services`; nothing registered ⇒ no row (byte for byte as before)
#   H  the doctor wires the row (fleet-doctor.sh runs fleet-services.py --doctor)
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/  /' >&2; exit 1; }
ok() { CHECKS=$((CHECKS+1)); }
eq() { [ "$2" = "$3" ] || fail "$1" "want: [$2]
 got: [$3]"; ok; }
has() { case "$3" in *"$2"*) ok ;; *) fail "$1" "want a substring: [$2]
 got: [$3]" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail "$1" "must not contain: [$2]
 got: [$3]" ;; *) ok ;; esac; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-services-selftest.XXXXXX") || exit 2
WORK="$(cd "$WORK" && pwd -P)"
[ -n "${KEEP:-}" ] || trap 'rm -rf "$WORK"' EXIT
ME=$(id -un)
NOW=1791529500   # 2026-10-09T07:05:00Z

cat > "$WORK/hub.json" <<'EOF'
{"ts": 1791529440, "machines": [{"hostname": "mini2.tail.ts.net", "label": "mini2", "services_at": "2026-10-09T07:04:00Z", "services": [
 {"name": "sms-watch", "kind": "service", "login": "verky", "state": "running", "started_at": "2026-10-09T06:05:00.123456789Z", "last_run": "2026-10-09T06:05:00Z", "last_log_line": "sent 3 texts"},
 {"name": "daily-report", "kind": "task", "login": "verky", "state": "failed", "last_run": "2026-10-09T07:00:00Z", "next_run": "2026-10-10T07:00:00Z", "last_rc": 1, "last_log_line": "give up: skill not found"}]}],
 "alerts": [{"kind": "service_failed", "subject": "mini2.tail.ts.net/verky/daily-report", "raised_at": "2026-10-09T07:01:00Z"}]}
EOF
printf 'boot\nlistening on 127.0.0.1:8080\n\n' > "$WORK/web.log"
ln -s "$WORK/web.log" "$WORK/link.log"
cat > "$WORK/state.json" <<EOF
{"version": 1, "services": [
 {"name": "web", "login": "$ME", "kind": "service", "status": "down", "started": $((NOW - 600)), "next_start": $((NOW + 30)), "last_rc": 2, "restarts": 4, "log": "$WORK/web.log"},
 {"name": "linked", "login": "$ME", "kind": "service", "status": "running", "started": $((NOW - 60)), "log": "$WORK/link.log"},
 {"name": "theirs", "login": "someone-else", "kind": "service", "status": "down"}]}
EOF
svc() { FLEET_SERVICES_CACHE="${CACHE-$WORK/hub.json}" FLEET_SERVICES_STATE="${STATE-$WORK/state.json}" \
        FLEET_SERVICES_HOST="${HOST-box}" FLEET_SERVICES_LOGIN="$ME" FLEET_SERVICES_NOW=$NOW \
        python3 "$BIN/fleet-services.py" "$@"; }

# ------------------------------------------------------------------------- A ----
t=$(svc)
eq "A: the header" "机器 登录 名称 类型 状态 上次 下次 最近日志" "$(printf '%s\n' "$t" | head -1 | tr -s ' ')"
has "A: the hub's failed task, its last line" "daily-report  定时  失败" "$t"
has "A: …last run 5 minutes ago, next in a day" "5 分钟前" "$(printf '%s\n' "$t" | grep daily-report)"
has "A: …next run" "23 小时后" "$(printf '%s\n' "$t" | grep daily-report)"
has "A: …its log's last line" "give up: skill not found" "$t"
has "A: the hub's running service (a Go nanosecond time read)" "运行中" "$(printf '%s\n' "$t" | grep sms-watch)"
has "A: …1 hour ago" "1 小时前" "$(printf '%s\n' "$t" | grep sms-watch)"
has "A: this machine's daemon row: down, its rc, restart in 30s" "已退出·待重启（rc=2）" "$(printf '%s\n' "$t" | grep ' web ')"
has "A: …next start" "30 秒后" "$(printf '%s\n' "$t" | grep ' web ')"
has "A: …its own log's last line" "listening on 127.0.0.1:8080" "$(printf '%s\n' "$t" | grep ' web ')"
eq "A: a log reached through a link is not read" "" "$(svc --json | python3 -c 'import json,sys; print([r for r in json.load(sys.stdin) if r["name"]=="linked"][0].get("last_log_line",""))')"
hasnt "A: another login's entry is not this login's" "theirs" "$t"
eq "A: --json marks the failed ones" "daily-report web" "$(svc --json | python3 -c 'import json,sys; print(" ".join(sorted(r["name"] for r in json.load(sys.stdin) if r["failed"])))')"
eq "A: --json names the machine" "box mini2" "$(svc --json | python3 -c 'import json,sys; print(" ".join(sorted({r["machine"] for r in json.load(sys.stdin)})))')"
hasnt "A: a fresh hub reading says no age" "入口读数" "$t"
has "A: a stale hub reading says how old" "（入口读数是 1 小时前的）" "$(FLEET_SERVICES_CACHE="$WORK/hub.json" FLEET_SERVICES_STATE='' FLEET_SERVICES_NOW=$((NOW + 3600)) python3 "$BIN/fleet-services.py")"

# ------------------------------------------------------------------------- B ----
t=$(HOST=mini2 svc)
hasnt "B: the daemon is not read for a machine the hub speaks for" " web " "$t"
eq "B: …so mini2's rows are the hub's two" 2 "$(HOST=mini2 svc --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"

# ------------------------------------------------------------------------- C ----
d=$(svc --doctor)
has "C: a failed entry is FAIL" "FAIL	2/4 failed:" "$d"
has "C: …naming it and its last line" "verky/daily-report@mini2 失败「give up: skill not found」" "$d"
has "C: …and the daemon's" "$ME/web@box 已退出·待重启（rc=2）" "$d"
d=$(STATE='' CACHE="$WORK/none.json" svc --doctor)
eq "C: nothing registered is INFO 无登记" "INFO	无登记 — no background service or scheduled task registered (fleet service add)" "$d"
python3 - "$WORK/hub.json" "$WORK/ok.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for m in d["machines"]:
    for s in m["services"]:
        s["state"] = "running"
d["alerts"] = []
json.dump(d, open(sys.argv[2], "w"))
PY
d=$(STATE='' CACHE="$WORK/ok.json" svc --doctor)
has "C: all running is PASS" "PASS	2 registered, none failed: verky/daily-report@mini2 运行中, verky/sms-watch@mini2 运行中" "$d"

# ------------------------------------------------------------------------- D ----
a=$(svc --alerts)
eq "D: one line per failed entry" 2 "$(printf '%s\n' "$a" | grep -c .)"
eq "D: the hub's: since = its raised_at" "service-mini2-verky-daily-report	daily-report@mini2 失败	1791529260	give up: skill not found" \
   "$(printf '%s\n' "$a" | grep daily-report)"
has "D: the daemon's: since unknown (0)" "service-box-$ME-web	web@box 已退出·待重启	0	listening on" "$a"

# ------------------------------------------------------------------------- E ----
cli() { FLEET_SERVICES_CACHE="$WORK/hub.json" FLEET_SERVICES_STATE='' FLEET_SERVICES_HOST=mini2 FLEET_SERVICES_NOW=$NOW \
        FLEET_SHELL='' FLEET_SESSION_CLI_ROWS='' python3 "$BIN/fleet-session-cli.py" ls "$@"; }
eq "E: fleet ls --services is that table" "$(STATE='' HOST=mini2 svc)" "$(cli --services)"
eq "E: --services --json too" "$(STATE='' HOST=mini2 svc --json)" "$(cli --services --json)"
eq "E: …in either order" "$(STATE='' HOST=mini2 svc --json)" "$(cli --json --services)"
cli --services --bogus >/dev/null 2>&1; eq "E: a stray argument is usage" 2 "$?"
has "E: the usage names --services" "fleet ls --services [--json]" "$(cli --services --bogus 2>&1)"
e=$(FLEET_SERVICES_CACHE='' FLEET_SERVICES_STATE='' FLEET_SHELL='' python3 "$BIN/fleet-session-cli.py" ls --services 2>&1); rc=$?
eq "E: nothing registered: exit 0" 0 "$rc"
has "E: …and says how to register one" "没有登记的后台服务或定时任务" "$e"

# ------------------------------------------------------------------------- F ----
H="$WORK/hubs"; mkdir -p "$H/tmp" "$H/conf"
cat > "$H/nodes.json" <<'EOF'
{"machines":[{"hostname":"mini2.x","status":"online","ncpu":4,"services_at":"2026-10-09T07:00:00Z","services":[{"name":"daily-report","kind":"task","login":"verky","state":"failed","last_log_line":"give up"}]},
             {"hostname":"m4","status":"online","ncpu":4}],
 "alerts":[{"kind":"service_failed","subject":"mini2.x/verky/daily-report","raised_at":"2026-10-09T07:01:00Z"},{"kind":"node_lost","subject":"x"}]}
EOF
printf '{"sessions":[]}\n' > "$H/s.json"; printf '{"per_account":[]}\n' > "$H/l.json"
TMPDIR="$H/tmp/" FLEET_CONF_DIR="$H/conf" CCQUOTA_FLEET=1 FLEET_HUB_SESSIONS_CLIENT=fleet-shell \
  FLEET_HUB_SESSIONS_CMD="cat '$H/s.json'" FLEET_HUB_NODES_CMD="cat '$H/nodes.json'" FLEET_HUB_LIMITS_CMD="cat '$H/l.json'" \
  FLEET_HUB_SUMMARY_EVERY=0 FLEET_LIVE_DIR="$H/none" bash "$BIN/fleet-hub-sessions.sh" --refresh 2>"$H/err" ||
  fail "F: --refresh failed" "$(cat "$H/err")"
HS="$H/tmp/.claude-dash/global/hub_services"
[ -s "$HS" ] || fail "F: no hub_services written" "$(ls "$H/tmp/.claude-dash/global")"; ok
eq "F: the machine with a register, labelled; the one without is not listed" "mini2 daily-report" \
   "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join(m["label"]+" "+s["name"] for m in d["machines"] for s in m["services"]))' "$HS")"
eq "F: the service_failed alerts only" "service_failed" \
   "$(python3 -c 'import json,sys; print(" ".join(a["kind"] for a in json.load(open(sys.argv[1]))["alerts"]))' "$HS")"
eq "F: …which the reader then reads" "daily-report@mini2 失败" \
   "$(FLEET_STATUS_G="${HS%/*}" FLEET_SERVICES_STATE='' python3 "$BIN/fleet-services.py" --alerts | cut -f2)"

# ------------------------------------------------------------------------- G ----
A="$WORK/alerts"; G="$A/.claude-dash/global"; mkdir -p "$G"
fa() { TMPDIR="$A" FLEET_CONF_DIR="$A/conf" FLEET_STATUS_DISK=0 FLEET_ALERTS_MACHINE=0 FLEET_NODE_STATE="$A/none" \
       CCQUOTA_HUB_URL='' FLEET_STATUS_G='' bash "$BIN/fleet-alerts.sh" "$@"; }
fa write; base=$(fa counts)
eq "G: nothing registered ⇒ no service row" "" "$(fa list --plain 2>/dev/null | grep 'service ·')"
cp "$WORK/hub.json" "$G/hub_services"
fa write
eq "G: a failed entry is one more alarm" "$(( ${base%% *} + 1 ))" "$(fa counts | cut -d' ' -f1)"
r=$(fa list --plain 2>/dev/null | grep 'service ·')
has "G: ✖ service · failed · <name>@<machine>" "service · failed · daily-report@mini2 失败" "$r"
has "G: …its action" "see services" "$r"
grep -q '"id":"service-mini2-verky-daily-report","severity":"alarm"' "$G/alerts.ndjson" || fail "G: the row's id/severity" "$(cat "$G/alerts.ndjson")"; ok
grep -q '"since":1791529260,' "$G/alerts.ndjson" || fail "G: since is the hub's raised_at" "$(grep service "$G/alerts.ndjson")"; ok
cp "$WORK/ok.json" "$G/hub_services"
fa write
eq "G: back up ⇒ the alarm goes" "${base%% *}" "$(fa counts | cut -d' ' -f1)"
has "G: …leaving a ↻ healed trace" "↻  service · failed" "$(fa list --plain 2>/dev/null | grep 'service ·')"
cp "$WORK/hub.json" "$G/hub_services"; rm -f "$G"/alerts.*
FLEET_ALERTS_SERVICES=0 fa write
eq "G: FLEET_ALERTS_SERVICES=0 turns it off" "" "$(fa list --plain 2>/dev/null | grep 'service ·')"

# ------------------------------------------------------------------------- H ----
grep -q 'fleet-services.py' "$BIN/fleet-doctor.sh" && grep -q 'fail services' "$BIN/fleet-doctor.sh" &&
  grep -q 'info services' "$BIN/fleet-doctor.sh" || fail "H: fleet-doctor.sh has no services row"; ok
grep -qx 'bin/fleet-services.py' "$BIN/../tokenledger/internal/api/fleetclient/manifest" ||
  fail "H: fleet-services.py is not on the client manifest (fleet ls --services runs there)"; ok

echo "fleet-services-selftest: OK ($CHECKS checks)"
