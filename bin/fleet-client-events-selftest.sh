#!/bin/bash
# fleet-client-events-selftest.sh — the client's connection events for the hub
# (claude-fleet T689): bin/fleet_client_events.py (the spool, the sender, the
# report) and bin/fleet-client-events.sh (the doctor's read). A sandbox cache, a
# stand-in hub on 127.0.0.1 and a stand-in curl — never the person's hub.
#
#   A  record: every field a code / name / number — free text becomes a code or
#      goes, a home that is not a name goes, an unknown kind is not recorded;
#      FLEET_CLIENT_EVENTS=0 records nothing
#   B  flush: the hub down keeps the spool; the hub up takes it batch by batch
#      (Bearer, POST /v1/fleet/client-events, the device); the same ids again
#      after a lost answer are the hub's to drop; a 400 lets the batch go
#   C  the spool is capped (FLEET_CLIENT_EVENTS_MAX): the oldest go
#   D  record never waits for the hub: a sender that hangs costs it nothing, and
#      it starts no thread and leaves no child (the thin client forks a pty)
#   E  report: the doctor's table per device and home, and its one row —
#      PASS / WARN (a start that never came up) / INFO (no events)
#   F  fleet-client-events.sh: the operator's token goes to curl on stdin, never
#      its argv; the table / --summary / --json; a 404 says the hub predates it
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/fce.XXXXXX")"; T="$(cd "$T" && pwd -P)"
st_tally
cleanup() {
  [ -n "${HUBPID:-}" ] && kill "$HUBPID" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

export XDG_CACHE_HOME="$T/cache" HOME="$T/home" FLEET_CONF_DIR="$T/conf"
mkdir -p "$HOME" "$FLEET_CONF_DIR"
unset FLEET_HUB_URL FLEET_HUB_TOKEN FLEET_CLIENT_EVENTS_POST_CMD FLEET_CLIENT_EVENTS
SP="$T/cache/claude-fleet/client-events.ndjson"
CE="$BIN/fleet_client_events.py"
rec() { python3 "$CE" record "$@"; }

# --- A ------------------------------------------------------------------------
rec drop home=mac-d route=lan rc=255 ms=12345 'reason=Connection reset by peer' start=00ab00ab00ab00ab ver=abc123
rec fail 'home=mac d; rm -rf' 'reason=Permission denied (publickey) password=hunter2 sk-ant-xyz' phase=start
rec keystroke home=mac-d
FLEET_CLIENT_EVENTS=0 rec up home=mac-d
if python3 - "$SP" <<'PY'
import json, sys
evs = [json.loads(l) for l in open(sys.argv[1])]
assert [e["event"] for e in evs] == ["drop", "fail"], evs
d, f = evs
assert d["home"] == "mac-d" and d["route"] == "lan" and d["rc"] == 255 and d["ms"] == 12345, d
assert d["reason"] == "connection_reset_by_peer" and d["start"] == "00ab00ab00ab00ab" and d["ver"] == "abc123", d
assert "home" not in f and f["phase"] == "start", f
assert len(f["reason"]) <= 48 and " " not in f["reason"], f
assert set(d) | set(f) <= {"id", "at", "event", "start", "phase", "home", "route", "to", "ms", "rc", "reason", "ver"}
PY
then st_ok_all "A: record keeps codes, names and numbers; free text coded and cut, a bad home dropped, an unknown kind and =0 record nothing"
else st_miss "A: spool: $(cat "$SP")"; fi

# --- B ------------------------------------------------------------------------
out=$(python3 "$CE" flush); rc=$?
[ "$rc" = 1 ] && [ "$(wc -l < "$SP" | tr -d ' ')" = 2 ] && st_ok_all "B: no hub → flush keeps the spool ($out)" \
  || st_miss "B: no hub: rc=$rc $out / $(wc -l < "$SP")"

cat > "$T/hub.py" <<'PY'
import http.server, json, os, sys
T = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(T + "/hub.log", "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization"), "body": body}) + "\n")
        mode = open(T + "/hub.mode").read().strip() if os.path.exists(T + "/hub.mode") else "ok"
        code = {"ok": 200, "bad": 400, "down": 503}[mode]
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(json.dumps({"accepted": len(body["events"])}).encode())
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(T + "/hub.port", "w").write(str(s.server_port))
s.serve_forever()
PY
python3 "$T/hub.py" "$T" & HUBPID=$!
for _ in $(seq 50); do [ -s "$T/hub.port" ] && break; sleep 0.1; done
FLEET_HUB_URL="http://127.0.0.1:$(cat "$T/hub.port")"
export FLEET_HUB_URL FLEET_HUB_TOKEN=tok-test
echo down > "$T/hub.mode"
python3 "$CE" flush >/dev/null
[ "$(wc -l < "$SP" | tr -d ' ')" = 2 ] && st_ok_all "B: the hub answers 503 → the spool kept" || st_miss "B: 503 dropped the spool"
echo ok > "$T/hub.mode"; : > "$T/hub.log"
for i in 1 2 3; do rec up home=m3 phase=reconnect ms=$((i * 1000)); done
out=$(FLEET_CLIENT_EVENTS_BATCH=2 python3 "$CE" flush); rc=$?
if [ "$rc" = 0 ] && [ ! -s "$SP" ] && python3 - "$T/hub.log" <<'PY'
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1])]
assert [len(c["body"]["events"]) for c in calls] == [2, 2, 1], calls
assert all(c["path"] == "/v1/fleet/client-events" and c["auth"] == "Bearer tok-test" for c in calls), calls
assert all(c["body"]["device"] and "cert" not in c["body"] for c in calls), calls
ids = [e["id"] for c in calls for e in c["body"]["events"]]
assert len(ids) == len(set(ids)) == 5, ids
PY
then st_ok_all "B: the hub up → 5 events in batches of 2 · 2 · 1, Bearer, the device, the spool empty ($out)"
else st_miss "B: send: rc=$rc $out / $(cat "$T/hub.log")"; fi
echo bad > "$T/hub.mode"
rec up home=m3
python3 "$CE" flush >/dev/null; rc=$?
[ "$rc" = 0 ] && [ ! -s "$SP" ] && st_ok_all "B: a 400 lets the batch go (it would be refused again)" || st_miss "B: 400: rc=$rc $(cat "$SP")"
echo ok > "$T/hub.mode"

# --- C ------------------------------------------------------------------------
kill "$HUBPID" 2>/dev/null; wait "$HUBPID" 2>/dev/null; HUBPID=''
for i in $(seq 1 40); do FLEET_CLIENT_EVENTS_MAX=10 rec up home=m3 ms="$i"; done
n=$(wc -l < "$SP" | tr -d ' ')
last=$(tail -n 1 "$SP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ms"])')
[ "$n" -le 20 ] && [ "$last" = 40 ] && st_ok_all "C: capped at FLEET_CLIENT_EVENTS_MAX ($n kept of 40, the newest last)" || st_miss "C: n=$n last=$last"

# --- D ------------------------------------------------------------------------
printf '#!/bin/sh\ncat >/dev/null; sleep 5\n' > "$T/slow.sh"; chmod +x "$T/slow.sh"
t=$(FLEET_CLIENT_EVENTS_POST_CMD="$T/slow.sh" python3 -c '
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("ce", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
t0 = time.time()
for _ in range(5):
    m.record("up", home="m3")
import os, subprocess, threading
kids = subprocess.run(["pgrep", "-P", str(os.getpid())], capture_output=True, text=True).stdout.split()
print("%.2f %d %d" % (time.time() - t0, threading.active_count(), len(kids)))' "$CE")
set -- $t
python3 -c "import sys; sys.exit(0 if float('$1') < 1.5 else 1)" && [ "$2" = 1 ] && [ "$3" = 0 ] \
  && st_ok_all "D: five records with a hanging hub take ${1}s — never waits, no thread, no child left" || st_miss "D: record: $t (secs threads children)"
pkill -f "$T/slow.sh" 2>/dev/null

# --- E ------------------------------------------------------------------------
cat > "$T/rep.json" <<'EOF'
{"at":"2026-10-20T07:00:00Z","hours":24,
 "total":{"starts":2,"ups":4,"drops":2,"drop_reasons":{"timeout":1,"reset":1},"reconnects":2,"reconnect_p50_ms":4000,"reconnect_p90_ms":12000,"fails":1,"starts_failed":1,"fail_reasons":{"home:no_machine_online":1},"rehomes":1,"offline":0},
 "devices":[{"device":"alice-mbp","starts":2,"ups":4,"drops":2,"drop_reasons":{"timeout":1,"reset":1},"reconnects":2,"reconnect_p50_ms":4000,"reconnect_p90_ms":12000,"fails":1,"starts_failed":1,"fail_reasons":{"home:no_machine_online":1},"rehomes":1}],
 "by":[{"device":"alice-mbp","home":"m3","ups":1,"reconnects":1,"reconnect_p50_ms":12000,"reconnect_p90_ms":12000},
       {"device":"alice-mbp","home":"mac-d","ups":3,"drops":2,"drop_reasons":{"timeout":1,"reset":1},"reconnects":1,"reconnect_p50_ms":4000,"reconnect_p90_ms":4000,"fails":1,"starts_failed":1,"fail_reasons":{"home:no_machine_online":1}}]}
EOF
tab=$(python3 "$CE" report < "$T/rep.json")
case $tab in *alice-mbp*（全部）*mac-d*"home:no_machine_online×1"*"合计：启动 2 · 断线 2 · 重连 p50 4.0s / p90 12s"*)
  st_ok_all "E: the table — a device, its homes, the reasons, the totals" ;; *) st_miss "E: table: $tab" ;; esac
row=$(python3 "$CE" report --summary < "$T/rep.json")
case $row in WARN$'\t'*"断线 2"*"p90 12s"*"起不来 1 次（1 次启动）"*) st_ok_all "E: a start that never came up → WARN" ;; *) st_miss "E: row: $row" ;; esac
row=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["total"]["starts_failed"]=0; print(json.dumps(d))' "$T/rep.json" | python3 "$CE" report --summary)
case $row in PASS$'\t'*) st_ok_all "E: no failed start, p90 under a minute → PASS" ;; *) st_miss "E: pass row: $row" ;; esac
row=$(printf '{"hours":24,"total":{},"devices":[],"by":[]}' | python3 "$CE" report --summary)
case $row in INFO$'\t'*没有收到*) st_ok_all "E: no events → INFO" ;; *) st_miss "E: info row: $row" ;; esac

# --- F ------------------------------------------------------------------------
cat > "$T/curl.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/curl.argv"
cat >> "$T/curl.stdin"
if [ -f "$T/curl.404" ]; then printf '{"error":"no"}\n404'; exit 0; fi
cat "$T/rep.json"; printf '\n200'
EOF
chmod +x "$T/curl.sh"
export FLEET_HUB_CURL="$T/curl.sh" CCQUOTA_VIEWER_TOKEN=viewer-secret-123 CCQUOTA_HUB_URL=https://hub.example
out=$(bash "$BIN/fleet-client-events.sh" --hours 6 --device alice-mbp); rc=$?
case "$rc:$out" in 0:*alice-mbp*合计*) st_ok_all "F: the table off the hub's answer" ;; *) st_miss "F: rc=$rc $out" ;; esac
grep -q 'viewer-secret-123' "$T/curl.argv" && st_miss "F: the token is in curl's argv" || st_ok_all "F: the token never in curl's argv"
grep -q 'Bearer viewer-secret-123' "$T/curl.stdin" && st_ok_all "F: the token on curl's stdin" || st_miss "F: no token on stdin"
grep -q 'https://hub.example/v1/fleet/client-events?hours=6&device=alice-mbp' "$T/curl.argv" && st_ok_all "F: GET ?hours=6&device=alice-mbp" || st_miss "F: url: $(cat "$T/curl.argv")"
out=$(bash "$BIN/fleet-client-events.sh" --summary); case $out in WARN$'\t'*) st_ok_all "F: --summary → the doctor's row" ;; *) st_miss "F: summary: $out" ;; esac
out=$(bash "$BIN/fleet-client-events.sh" --json); python3 -c 'import json,sys; json.loads(sys.argv[1])' "$out" && st_ok_all "F: --json is the hub's JSON" || st_miss "F: json: $out"
touch "$T/curl.404"
out=$(bash "$BIN/fleet-client-events.sh" 2>&1); rc=$?
case "$rc:$out" in 1:*"predates T689"*) st_ok_all "F: a hub without the door → rc 1, said" ;; *) st_miss "F: 404: rc=$rc $out" ;; esac
out=$(bash "$BIN/fleet-client-events.sh" --hours x 2>&1); [ $? = 2 ] && st_ok_all "F: --hours x → usage (2)" || st_miss "F: usage: $out"

echo
st_done
