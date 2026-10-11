#!/usr/bin/env bash
# fleet-release-stats-selftest.sh — `fleet release stats` (bin/fleet-release-stats.py,
# claude-fleet#3140) against a fake hub on 127.0.0.1, reached through bin/fleet
# the way a person types it.
#
#   A  an empty ledger → 还没有带账的发布, every number —, exit 0
#   B  a ledger with trains → GET /v1/fleet/release/stats?days=7 with the
#      operator's bearer; the three rows, the stages, the last trains
#   C  --days 3 --json → ?days=3, the hub's answer as JSON
#   D  no credential → exit 3, nothing sent; --days 0 → exit 2
set -u
BIN=$(cd "$(dirname "$0")" && pwd -P)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/release-stats-selftest.XXXXXX")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $*"; }

cat > "$WORK/empty.json" <<'J'
{"days":7,"since":"2026-10-04T08:00:00Z","trains":0,"trains_reached":0,
 "merge_to_all":{"n":0,"median_secs":null,"p90_secs":null},"merges_pending":0,
 "releases_per_hour":{"releases":0,"active_hours":0,"rate":null},
 "macos_queue":{"n":0,"median_secs":null,"p90_secs":null},"stages":[],"recent":[]}
J
cat > "$WORK/full.json" <<'J'
{"days":7,"since":"2026-10-04T08:00:00Z","trains":3,"trains_reached":2,
 "merge_to_all":{"n":2,"median_secs":3000,"p90_secs":4800},"merges_pending":1,
 "releases_per_hour":{"releases":3,"active_hours":4,"rate":0.75},
 "macos_queue":{"n":3,"median_secs":120,"p90_secs":600},
 "stages":[{"name":"linux tests","n":3,"median_secs":300,"p90_secs":360}],
 "recent":[
  {"sha":"3333333333333333333333333333333333333333","published_at":"2026-10-11T07:12:00Z","merges":1,"machines":3,"reached":2,"missing":["m3"]},
  {"sha":"2222222222222222222222222222222222222222","published_at":"2026-10-11T05:27:00Z","merges":2,"machines":3,"reached":3,"all_at":"2026-10-11T05:47:00.123456789Z"}]}
J

LOG="$WORK/requests.ndjson"; PORTF="$WORK/port"
# the fake hub: the ledger's route only, each request logged; alarm(60) bounds it
cat > "$WORK/hub.py" <<'PY'
import json, os, signal, socketserver, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse
signal.alarm(60)
log, portf, answer = sys.argv[1], sys.argv[2], sys.argv[3]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        u = urlparse(self.path)
        with open(log, "a") as f:
            f.write(json.dumps({"path": u.path, "query": u.query, "auth": self.headers.get("Authorization", "")}) + "\n")
        code, raw = (200, open(answer, "rb").read()) if u.path == "/v1/fleet/release/stats" else (404, b'{"error":"no"}')
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw))); self.end_headers(); self.wfile.write(raw)
class Server(HTTPServer):
    def server_bind(self):  # no reverse-DNS lookup (getfqdn) on a CI runner
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "127.0.0.1", self.server_address[1]
s = Server(("127.0.0.1", 0), H)
with open(portf + ".tmp", "w") as f:
    f.write(str(s.server_address[1]))
os.rename(portf + ".tmp", portf)
s.serve_forever()
PY
python3 "$WORK/hub.py" "$LOG" "$PORTF" "$WORK/full.json" 2>"$WORK/hub.err" &
HUBPID=$!
trap 'kill "$HUBPID" 2>/dev/null; wait "$HUBPID" 2>/dev/null; rm -rf "$WORK"' EXIT
python3 - "$PORTF" <<'PY'
import os, sys, time
end = time.time() + 15
while time.time() < end and not (os.path.exists(sys.argv[1]) and os.path.getsize(sys.argv[1]) > 0):
    time.sleep(0.05)
PY
[ -s "$PORTF" ] || { echo "FAIL the fake hub did not start: $(cat "$WORK/hub.err" 2>/dev/null)"; exit 1; }
HUB="http://127.0.0.1:$(cat "$PORTF")"

run() { env -i PATH="$PATH" HOME="$WORK/home" TZ=UTC FLEET_CONF_DIR="$WORK/conf" XDG_CONFIG_HOME="$WORK/xdg" "$@"; }
last() { tail -n 1 "$LOG" 2>/dev/null; }
field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2], ""))' "$1" "$2"; }

# A — empty
out=$(run "$BIN/fleet" release stats --from "$WORK/empty.json" 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '^发布账 · 近 7 天 · 还没有带账的发布' \
   && printf '%s\n' "$out" | grep -q '合并后到所有机器都用上 *中位 — · p90 — · 0 个合并$' \
   && printf '%s\n' "$out" | grep -q '每小时发出的版本 *—$' \
   && printf '%s\n' "$out" | grep -q 'macOS 测试排队 *中位 — · p90 — · 0 次$' \
   && ! printf '%s\n' "$out" | grep -q '最近几趟'; then
  ok "A empty ledger → 还没有带账的发布, every number —"
else bad "A rc=$rc out=$out"; fi

# B — through the hub
out=$(run FLEET_HUB_URL="$HUB" CCQUOTA_VIEWER_TOKEN=tok "$BIN/fleet" release stats 2>&1); rc=$?
r=$(last)
if [ "$rc" = 0 ] && [ "$(field "$r" path)" = /v1/fleet/release/stats ] && [ "$(field "$r" query)" = days=7 ] \
   && [ "$(field "$r" auth)" = "Bearer tok" ] \
   && printf '%s\n' "$out" | grep -q '^发布账 · 近 7 天 · 3 趟车（2 趟所有机器都已用上）$' \
   && printf '%s\n' "$out" | grep -q '合并后到所有机器都用上 *中位 50 分 · p90 80 分 · 2 个合并（另 1 个还在路上）$' \
   && printf '%s\n' "$out" | grep -q '每小时发出的版本 *0\.75（3 趟 / 4 个 master 在动的小时）$' \
   && printf '%s\n' "$out" | grep -q 'macOS 测试排队 *中位 2 分 · p90 10 分 · 3 次$' \
   && printf '%s\n' "$out" | grep -q '^  linux tests *5 分 / 6 分 · 3 趟$' \
   && printf '%s\n' "$out" | grep -q '^  3333333  10-11 07:12  1 个合并  机器 2/3 · 差 m3$' \
   && printf '%s\n' "$out" | grep -q '^  2222222  10-11 05:27  2 个合并  机器 3/3 · 全部用上 10-11 05:47$'; then
  ok "B fleet release stats → GET …/release/stats?days=7 with the bearer; three rows, stages, last trains"
else bad "B rc=$rc req=$r out=$out"; fi

# C — --days, --json
out=$(run FLEET_HUB_URL="$HUB" CCQUOTA_VIEWER_TOKEN=tok "$BIN/fleet" release stats --days 3 --json 2>&1); rc=$?
r=$(last)
if [ "$rc" = 0 ] && [ "$(field "$r" query)" = days=3 ] \
   && printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["trains"] == 3 and d["merge_to_all"]["p90_secs"] == 4800'; then
  ok "C --days 3 --json → ?days=3, the answer as JSON"
else bad "C rc=$rc req=$r out=$out"; fi

# D — no credential; a bad --days
n0=$(wc -l <"$LOG")
run FLEET_HUB_URL="$HUB" "$BIN/fleet" release stats >"$WORK/out" 2>"$WORK/err"; rc=$?
run FLEET_HUB_URL="$HUB" CCQUOTA_VIEWER_TOKEN=tok "$BIN/fleet" release stats --days 0 >/dev/null 2>&1; rc2=$?
if [ "$rc" = 3 ] && [ "$rc2" = 2 ] && [ "$(wc -l <"$LOG")" = "$n0" ] && grep -q 'no credential' "$WORK/err"; then
  ok "D no credential → exit 3, --days 0 → exit 2, nothing sent"
else bad "D rc=$rc rc2=$rc2 err=$(cat "$WORK/err")"; fi

echo "fleet-release-stats-selftest: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
