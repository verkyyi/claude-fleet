#!/usr/bin/env bash
# fleet-cred-doctor-selftest.sh — fleet-doctor's `cred` row (issue #1975, EPIC
# #1967 C8): `bin/fleet-cred-proxy.sh doctor` read on the three kinds of machine,
# against the real bin/fleet-cred-proxy.py and a fake hub on 127.0.0.1 (sandbox
# HOME + FLEET_CONF_DIR).
#
#   A  FLEET_CRED_PROXY=0: `doctor` exits 3 and bin/fleet-doctor.sh prints no
#      cred row (the degenerate)
#   B  trusted + reachable    → PASS, Claude 走 direct 直连（trusted + reachable）
#   C  trusted + unreachable  → PASS, relay 经新加坡转发（trusted + unreachable）
#   D  untrusted              → PASS, central 交给中心代理（untrusted (hub: untrusted)）
#   E  a hub pass the hub will not renew (500) → WARN 通行证续签失败
#   F  the proxy is dead      → a client computer: INFO (fleet run starts it); a host
#      (FLEET_HOST=1) with no machine proxy: FAIL, naming machine install (#4674)
#   H  a host's login with a per-login proxy still serving → FAIL (the road is gone, #4674)
#   G  bin/fleet-doctor.sh itself carries the row (B's text, PASS)
#   U  the 上游 row (T657): bin/fleet_upstream_stats.py doctor off a stats file —
#      WARN naming the class and the latest one; nothing recorded ⇒ no row
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
SB=$(mktemp -d "${TMPDIR:-/tmp}/cred-doctor-st.XXXXXX")
cleanup() {
  kill "$(cat "$SB/conf/cred-proxy/pid" 2>/dev/null)" 2>/dev/null
  kill "$(cat "$SB/fake.pid" 2>/dev/null)" 2>/dev/null
  rm -rf "$SB"
}
trap cleanup EXIT
export HOME="$SB/home" FLEET_CONF_DIR="$SB/conf" XDG_CONFIG_HOME="$SB/xdg"
mkdir -p "$HOME" "$FLEET_CONF_DIR" "$XDG_CONFIG_HOME"
unset FLEET_HUB_URL CCQUOTA_HUB_URL CCQUOTA_TOKEN CCQUOTA_FLEET FLEET_PROBE_FORCE_UNREACHABLE FLEET_CRED_SEPARATE

st_tally
row() { FLEET_CRED_PROXY="$1" bash "$BIN/fleet-cred-proxy.sh" doctor 2>&1; }
# expect <label> <want rc> <want level> <want text…> — the row's level and every text piece
expect() {
  local label="$1" wrc="$2" wlv="$3" out rc t; shift 3
  out=$(row 1); rc=$?
  [ "$rc" = "$wrc" ] || { st_miss "$label: rc=$rc ($out)"; return; }
  [ "$(printf '%s' "$out" | cut -f1)" = "$wlv" ] || { st_miss "$label: level, wanted $wlv: $out"; return; }
  for t in "$@"; do
    case "$out" in *"$t"*) ;; *) st_miss "$label: no [$t] in: $out"; return ;; esac
  done
  st_ok_all "$label: $(printf '%s' "$out" | cut -f2-)"
  printf '%s\n' "$out" >> "$SB/rows"
}

# ── the fake hub ─────────────────────────────────────────────────────────────
cat > "$SB/fake.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
SB = sys.argv[1]
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def reply(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_GET(self): self.any()
    def do_POST(self): self.any()
    def any(self):
        n = int(self.headers.get("content-length") or 0)
        if n: self.rfile.read(n)
        if self.path == "/v1/node/self":
            return self.reply(200, {"trust": open(os.path.join(SB, "trust")).read().strip()})
        if self.path == "/v1/fleet/session-cred/renew":
            return self.reply(500, {"error": "the hub is having a day"})
        if self.path == "/v1/node/usage":
            # the usage report (issue #3407): a hub that refuses it is a doctor WARN
            return self.reply(200, {"principal": "gh:1", "over": False})
        self.reply(404, {"error": self.path})
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(os.path.join(SB, "fake.pid"), "w").write(str(os.getpid()))
open(os.path.join(SB, "fake.port.tmp"), "w").write(str(srv.server_address[1]))
os.replace(os.path.join(SB, "fake.port.tmp"), os.path.join(SB, "fake.port"))
srv.serve_forever()
PY
echo trusted > "$SB/trust"
python3 -I "$SB/fake.py" "$SB" & disown
i=0; while [ ! -s "$SB/fake.port" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$SB/fake.port" ] || { st_miss "start: the fake hub never came up"; exit 1; }
U="http://127.0.0.1:$(cat "$SB/fake.port")"
DEAD=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
printf 'CCQUOTA_HUB_URL=%s\nCCQUOTA_TOKEN=nodetok\n' "$U" > "$FLEET_CONF_DIR/node.env"
probe() { printf '{"anthropic":"%s","openai":"%s"}\n' "$1" "$1" > "$FLEET_CONF_DIR/node-probe.json"; }
probe reachable
cat > "$FLEET_CONF_DIR/fleet.conf" <<EOF
FLEET_CRED_ANTHROPIC_URL=$U/direct-anthropic
FLEET_CRED_CODEX_URL=$U/direct-codex
FLEET_CRED_RELAY_URL=$U/relay
FLEET_CRED_RELAY_TOKEN=relaytok
FLEET_CRED_CENTRAL_URL=http://127.0.0.1:$DEAD
FLEET_CRED_PROXY_LOG=$SB/proxy.log
EOF

# ── A: off ───────────────────────────────────────────────────────────────────
out=$(row 0); rc=$?
[ "$rc" = 3 ] && [ -z "$out" ] && st_ok_all "A off: doctor exits 3, says nothing" || st_miss "A off: rc=$rc ($out)"
dr=$(FLEET_CRED_PROXY=0 sh "$BIN/fleet-doctor.sh" 2>/dev/null | grep -E '^[[:space:]]*(PASS|WARN|FAIL|INFO)[[:space:]]+cred([[:space:]]|$)')
[ -z "$dr" ] && st_ok_all "A off: fleet-doctor prints no cred row" || st_miss "A off: fleet-doctor printed [$dr]"

# ── the proxy ────────────────────────────────────────────────────────────────
out=$(FLEET_CRED_PROXY=1 bash "$BIN/fleet-cred-proxy.sh" ensure 2>&1) || { st_miss "start: ensure: $out"; exit 1; }
PORT=$out

# ── B / C / D: the three kinds of machine ────────────────────────────────────
expect "B trusted + reachable" 0 PASS "可信（hub: trusted）" "Claude 走 direct 直连（trusted + reachable）" "Codex 同路" \
  "代理 pid" "127.0.0.1:$PORT" "client 客户端 fleet run 代理" "续签 正常"
probe unreachable
expect "C trusted + unreachable" 0 PASS "Claude 走 relay 经新加坡转发（trusted + unreachable）"
echo untrusted > "$SB/trust"
FLEET_CRED_PROXY=1 bash "$BIN/fleet-cred-proxy.sh" route --refresh >/dev/null 2>&1
expect "D untrusted" 0 PASS "不可信（hub: untrusted）" "Claude 走 central 交给中心代理（untrusted (hub: untrusted) → central"

# ── E: a renewal the hub refuses with a 500 ──────────────────────────────────
pass_due=$(python3 -c 'import base64, json, time; n = int(time.time())
c = json.dumps({"v": 1, "id": "p-due", "iat": n - 1000, "exp": n + 60}).encode()
print("fcp-h1." + base64.urlsafe_b64encode(c).rstrip(b"=").decode() + ".sig")')
curl -s -m 20 -o /dev/null -X POST -H "Authorization: Bearer $pass_due" -d '{}' "http://127.0.0.1:$PORT/v1/messages"
expect "E renewal failing" 0 WARN "通行证续签失败 1 次" "hub answered 500"
grep -q 'fcp-h1\.' "$SB/proxy.log" && st_miss "E: a hub pass in the proxy log" || st_ok_all "E: no hub pass in the proxy log"

# ── G: fleet-doctor carries the row (B again) ────────────────────────────────
echo trusted > "$SB/trust"; probe reachable
FLEET_CRED_PROXY=1 bash "$BIN/fleet-cred-proxy.sh" route --refresh >/dev/null 2>&1
dr=$(FLEET_CRED_PROXY=1 sh "$BIN/fleet-doctor.sh" 2>/dev/null | grep -E '^[[:space:]]*(PASS|WARN|FAIL|INFO)[[:space:]]+cred([[:space:]]|$)')
case "$dr" in *WARN*cred*'Claude 走 direct 直连（trusted + reachable）'*) st_ok_all "G fleet-doctor: $(printf '%s' "$dr" | sed 's/^ *//')" ;;
  *) st_miss "G fleet-doctor: wanted the cred row (WARN — E's failed renewal is the newest), got [$dr]" ;; esac

# ── U: the 上游 row off the proxy's upstream stats (T657) ─────────────────────
mkdir -p "$SB/ups"
python3 -c 'import json, sys, time
m = int(time.time() // 60) * 60 - 120
f = [{"t": m + 5 + i, "c": "reset", "acct": "a1", "login": "me", "sid": "s1", "route": "direct", "ms": 3, "st": "ConnectionResetError"} for i in range(4)]
print(json.dumps({"m": m, "n": 10, "c": {"ok": 6, "reset": 4}, "a": {"a1": {"ok": 6, "reset": 4}}, "ms_max": 9, "ms_sum": 40, "f": f}))' \
  > "$SB/ups/upstream-stats.ndjson"
dr=$(FLEET_UPSTREAM_STATS_DIR="$SB/ups" sh "$BIN/fleet-doctor.sh" 2>/dev/null | grep -E '^[[:space:]]*(PASS|WARN)[[:space:]]+上游')
case "$dr" in *WARN*上游*'近 1 小时 4 次失败 / 10 次请求（连接被重置 4）'*'最近一次'*'连接被重置'*) st_ok_all "U fleet-doctor 上游: WARN naming the resets" ;;
  *) st_miss "U fleet-doctor 上游: wanted WARN with 连接被重置 4, got [$dr]" ;; esac
mkdir -p "$SB/ups-none"
dr=$(FLEET_UPSTREAM_STATS_DIR="$SB/ups-none" sh "$BIN/fleet-doctor.sh" 2>/dev/null | grep -E '^[[:space:]]*(PASS|WARN|FAIL|INFO)[[:space:]]+上游')
[ -z "$dr" ] && st_ok_all "U nothing recorded: no 上游 row" || st_miss "U nothing recorded: a row anyway [$dr]"

# ── H: a host's login still on a per-login proxy (#4674) ─────────────────────
out=$(FLEET_HOST=1 row 1)
case "$out" in "FAIL	"*"per-login 每登录代理（已删，#4674"*) st_ok_all "H host + per-login proxy: FAIL — $(printf '%s' "$out" | cut -f2- | cut -c1-80)" ;;
  *) st_miss "H host + per-login proxy: $out" ;; esac

# ── F: the proxy is dead ─────────────────────────────────────────────────────
kill "$(cat "$FLEET_CONF_DIR/cred-proxy/pid")" 2>/dev/null
i=0; while kill -0 "$(cat "$FLEET_CONF_DIR/cred-proxy/pid" 2>/dev/null)" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
expect "F proxy dead (client)" 0 INFO "代理没在跑" "fleet run"
out=$(FLEET_HOST=1 row 1)
case "$out" in "FAIL	"*"没接整机代理"*"machine install"*) st_ok_all "F proxy dead (host): FAIL naming machine install" ;;
  *) st_miss "F proxy dead (host): $out" ;; esac

[ -n "${CRED_DOCTOR_OUT:-}" ] && cp "$SB/rows" "$CRED_DOCTOR_OUT"
st_done
