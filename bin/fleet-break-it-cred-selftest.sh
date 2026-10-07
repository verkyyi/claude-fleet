#!/bin/bash
# fleet-break-it-cred-selftest.sh — the cred-* rows of docs/BREAK-IT.md, done
# for real (issue #1975, EPIC #1967 C8): the credential proxy breaking in every
# way the batch added, and the session coming back.
#
# Split from bin/fleet-break-it-selftest.sh so that run stays under the per-test
# cap on macOS; that script's lockstep lint still reads the drill_cred_* names
# here, so a cred row with no drill (or a drill with no row) reds there.
#
#   cred-proxy-dead                                 bin/fleet-cred-proxy.sh run (the daemon's entry)
#   cred-relay-down / cred-central-down / cred-probe-wrong
#                                                   bin/fleet-cred-proxy.py (Router, send: route_switch)
#   cred-session-expire                             bin/fleet-cred-proxy.py (hub pass renewal, live fcp1),
#                                                   bin/fleet-session-cred.sh (--wrap)
#   cred-pass-lapsed                                bin/fleet-cred-proxy.py (HubPasses: a lapsed pass renewed
#                                                   on the next request; HUB_RENEW_GRACE)
#   cred-relay-hub-restart                          extras/cred-relay/fleet-relay-check.py (the relay's
#                                                   forward_auth gate: cache + grace while the hub restarts)
#   cred-shared-down                                in bin/fleet-break-it-cred-shared-selftest.sh, which
#                                                   sources this file's helpers (BREAK_CRED_LIB=1): this
#                                                   run is at the macOS per-test cap already
#
# Each prints `PASS <id> <secs>s ≤<cap>s <what came back>` like its parent.
# python3 / curl absent → SKIP. BREAK_KEEP=1 keeps the work dir; BREAK_ONLY
# narrows to those ids.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
DOC="$ROOT/docs/BREAK-IT.md"
command -v python3 >/dev/null 2>&1 || { printf 'fleet-break-it-cred: python3 absent — SKIP\n'; exit 0; }
command -v curl >/dev/null 2>&1 || { printf 'fleet-break-it-cred: curl absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/brkc.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
cleanup() {
  [ -f "$WORK/cred-pids" ] && while read -r s; do kill "$s" 2>/dev/null; done < "$WORK/cred-pids"
  pkill -f "$WORK/" 2>/dev/null
  [ -n "${BREAK_KEEP:-}" ] && { printf 'kept %s\n' "$WORK" >&2; return; }
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

now() { python3 -c 'import time; print("%.3f" % time.time())'; }
since() { python3 -c 'import sys, time; print("%.1f" % (time.time() - float(sys.argv[1])))' "$1"; }
le() { python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)' "$1" "$2"; }
until_ok() {
  local secs="$1" _; shift
  for _ in $(seq 1 $((secs * 10))); do "$@" && return 0; sleep 0.1; done
  "$@"
}

# ============================================ credential proxy (EPIC #1967) =====
# The cred half (issue #1975, C8): bin/fleet-cred-proxy.{sh,py} on loopback only,
# a sandbox FLEET_CONF_DIR per drill and ONE fake far end playing the hub
# (/v1/node/self, /v1/fleet/session-cred/renew), the providers (direct-*), the
# Singapore relay and the cluster's central proxy. A road that is "down" is a
# loopback port nothing listens on. Every hit lands in <dir>/hits as `<via> <path>`.
cred_fake() {   # <dir> → <dir>/fake.port
  local d="$1"
  cat > "$d/fake.py" <<'PY'
import base64, json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
D = sys.argv[1]
def has(n): return os.path.exists(os.path.join(D, n))
def claims(tok):
    p = tok.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
def mint(cid, ttl):
    now = int(time.time())
    c = json.dumps({"v": 1, "id": cid, "iat": now, "exp": now + ttl}).encode()
    return "fcp-h1." + base64.urlsafe_b64encode(c).rstrip(b"=").decode() + ".sig"
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
        body = self.rfile.read(n) if n else b""
        h = {k.lower(): v for k, v in self.headers.items()}
        p = self.path
        via = p.split("/")[1]
        with open(os.path.join(D, "hits"), "a") as f:
            f.write("%s %s\n" % (via, p))
        if p == "/v1/node/self":
            return self.reply(200, {"trust": open(os.path.join(D, "trust")).read().strip()})
        if p == "/v1/fleet/session-cred/renew":
            if h.get("authorization") != "Bearer nodetok":
                return self.reply(401, {"error": "node token"})
            c = claims(json.loads(body or b"{}").get("cred", ""))
            if c["exp"] < time.time() - 7 * 86400:   # the hub's renewal grace (#2012)
                return self.reply(403, {"error": "invalid", "reason": "past the renewal grace"})
            return self.reply(200, {"cred": mint(c["id"], 3600), "id": c["id"]})
        if via == "direct-anthropic":
            if has("region-direct"):
                return self.reply(403, {"type": "error", "error": {"type": "forbidden", "message": "Request not allowed"}})
            return self.reply(200, {"via": "direct", "auth": h.get("authorization", "")[:20]})
        if via == "relay":
            if h.get("x-fleet-relay") != "relaytok":
                return self.reply(401, {"error": "relay credential"})
            return self.reply(200, {"via": "relay"})
        if via == "central":
            a = h.get("authorization", "")
            if not a.startswith("Bearer fcp-h1."):
                return self.reply(401, {"error": "central wants a hub pass"})
            c = claims(a[7:])
            if c["exp"] < time.time():
                return self.reply(401, {"error": "pass expired", "id": c["id"]})
            return self.reply(200, {"via": "central", "id": c["id"], "exp": c["exp"]})
        self.reply(404, {"error": p})
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
srv.daemon_threads = True
open(os.path.join(D, "fake.port.tmp"), "w").write(str(srv.server_address[1]))
os.replace(os.path.join(D, "fake.port.tmp"), os.path.join(D, "fake.port"))
srv.serve_forever()
PY
  python3 -I "$d/fake.py" "$d" 2>"$d/fake.err" &
  printf '%s\n' "$!" >> "$WORK/cred-pids"
  until_ok 30 test -s "$d/fake.port"
}
cred_deadport() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }
# cred_rig <name> <trust> <probe> — a sandbox login: accounts, node.env, probe,
# the fake far end; sets CD (its conf dir) and CU (the fake's URL)
cred_rig() {
  CD="$WORK/cred-$1"; mkdir -p "$CD/accounts/a1.hub"
  printf '%s\n' "$2" > "$CD/trust"
  printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat-REAL-a1"}}' > "$CD/accounts/a1.hub/.credentials.json"
  printf '{"anthropic":"%s","openai":"%s"}\n' "$3" "$3" > "$CD/node-probe.json"
  cred_fake "$CD" || { WHY="the fake far end did not start: $(tail -2 "$CD/fake.err" | tr '\n' ' ')"; return 1; }
  CU="http://127.0.0.1:$(cat "$CD/fake.port")"
  printf 'CCQUOTA_HUB_URL=%s\nCCQUOTA_TOKEN=nodetok\n' "$CU" > "$CD/node.env"
}
# cred_env — the environment a proxy of this rig runs in (roads may be overridden after)
cred_env() {
  export FLEET_CONF_DIR="$CD" HOME="$CD" FLEET_CRED_PROXY=1 FLEET_CRED_PROXY_LOG="$CD/proxy.log" \
    FLEET_CRED_ANTHROPIC_URL="${CRED_DIRECT:-$CU/direct-anthropic}" FLEET_CRED_CODEX_URL="$CU/direct-codex" \
    FLEET_CRED_RELAY_URL="${CRED_RELAY:-$CU/relay}" FLEET_CRED_RELAY_TOKEN=relaytok \
    FLEET_CRED_CENTRAL_URL="${CRED_CENTRAL:-$CU/central}" FLEET_CRED_PROXY_TIMEOUT=10
  unset FLEET_HUB_URL FLEET_CRED_SEPARATE FLEET_CRED_CTL_DIR FLEET_PROBE_FORCE_UNREACHABLE FLEET_CRED_PROBE
}
cred_serve() {   # start a bare proxy for the rig; → CP (its port)
  ( cred_env; exec python3 -I "$BIN/fleet-cred-proxy.py" serve --max-seconds 300 ) 2>"$CD/proxy.err" &
  printf '%s\n' "$!" >> "$WORK/cred-pids"
  until_ok 30 test -S "$CD/cred-proxy/ctl.sock" || { WHY="the proxy did not start: $(tail -2 "$CD/proxy.err" | tr '\n' ' ')"; return 1; }
  until_ok 5 test -s "$CD/cred-proxy/port"; CP=$(cat "$CD/cred-proxy/port")
}
cred_ctl() { ( cred_env; python3 -I "$BIN/fleet-cred-proxy.py" "$@" ); }
# cred_req <token> <outfile> → the HTTP status; the body lands in <outfile>
cred_req() {
  curl -s -m 30 -o "$2" -w '%{http_code}' -X POST -H "Authorization: Bearer $1" \
    -H 'content-type: application/json' -d '{"model":"m","messages":[]}' "http://127.0.0.1:$CP/v1/messages" 2>/dev/null
}
cred_hubpass() {   # <id> <iat offset> <exp offset> — a pass the way the hub spells one
  python3 -c 'import base64, json, sys, time; n = int(time.time())
c = json.dumps({"v": 1, "id": sys.argv[1], "iat": n + int(sys.argv[2]), "exp": n + int(sys.argv[3])}).encode()
print("fcp-h1." + base64.urlsafe_b64encode(c).rstrip(b"=").decode() + ".sig")' "$@"
}

drill_cred_proxy_dead() {
  CAP=10   # kill → the launcher has a new proxy process; a busy macOS runner takes seconds to start a python: the start is not timed
  cred_rig dead trusted reachable || return 1
  local st="$CD/cred-proxy" tok code pid1 pid2 t0
  # the daemon's own entry, its defaults untouched: launchd / systemd run exactly this
  local run
  ( cred_env; exec bash "$BIN/fleet-cred-proxy.sh" run ) 2>"$CD/run.err" &
  run=$!; printf '%s\n' "$run" >> "$WORK/cred-pids"
  until_ok 30 test -S "$st/ctl.sock" || { WHY="the launcher did not start a proxy: $(tail -2 "$CD/run.err" | tr '\n' ' ')"; return 1; }
  until_ok 5 test -s "$st/pid"; CP=$(cat "$st/port"); pid1=$(cat "$st/pid")
  tok=$(cred_ctl mint --account a1 --sid s-dead) || { WHY="mint failed"; return 1; }
  code=$(cred_req "$tok" "$CD/r1")
  [ "$code" = 200 ] || { WHY="before the kill the session got $code: $(cat "$CD/r1")"; return 1; }
  kill -9 "$pid1"; t0=$(now)
  # timed: the launcher sees the death and starts a new proxy
  until_ok 60 sh -c 'p=$(pgrep -P "$1" -f fleet-cred-proxy.py | head -n 1); [ -n "$p" ] && [ "$p" != "$2" ]' _ "$run" "$pid1" \
    || { WHY="the launcher never started a new proxy after the kill -9"; return 1; }
  SECS=$(since "$t0")
  # untimed: it binds the same port and the session's next request comes back
  until_ok 60 sh -c '[ "$(curl -s -m 5 -o /dev/null -w "%{http_code}" -X POST -H "Authorization: Bearer $1" -d "{}" "http://127.0.0.1:$2/v1/messages")" = 200 ]' _ "$tok" "$CP" \
    || { WHY="a new proxy started, but the session's next request never came back (pid now: $(cat "$st/pid" 2>/dev/null))"; return 1; }
  pid2=$(cat "$st/pid" 2>/dev/null)
  [ "$pid2" != "$pid1" ] || { WHY="the same pid answers — nothing was killed?"; return 1; }
  WHAT="代理 kill -9 后自动拉起（同一端口 ${CP}），会话原凭据下一请求 200"
}

drill_cred_relay_down() {
  CAP=10
  cred_rig relay trusted unreachable || return 1
  local tok code t0
  CRED_RELAY="http://127.0.0.1:$(cred_deadport)"
  cred_serve || { unset CRED_RELAY; return 1; }
  tok=$(cred_ctl mint --account a1 --sid s-relay)
  t0=$(now)
  code=$(cred_req "$tok" "$CD/r1")
  SECS=$(since "$t0")
  case "$code:$(cat "$CD/r1")" in 200:*'"via": "direct"'*) ;; *)
    unset CRED_RELAY; WHY="relay down, direct allowed: got $code $(cat "$CD/r1")"; return 1 ;; esac
  grep -q '"ev": "route_switch".*"frm": "relay".*"to": "direct"' "$CD/proxy.log" \
    || { unset CRED_RELAY; WHY="no route_switch relay → direct in the log"; return 1; }
  # the probe was right: direct is region-blocked too → one clear refusal, naming both roads
  : > "$CD/region-direct"
  code=$(cred_req "$tok" "$CD/r2"); unset CRED_RELAY
  case "$code:$(cat "$CD/r2")" in 403:*cred-proxy*relay*direct*) ;; *)
    WHY="relay down and direct region-blocked: wanted a 403 from cred-proxy naming relay and direct, got $code $(cat "$CD/r2")"; return 1 ;; esac
  WHAT="新加坡转发连不上 → 同一请求切 direct 成功；direct 也被地区拒 → 403 写明两条路各自怎么了"
}

# The relay's own gate while the hub restarts (issue #2048, EPIC #2119 C7): the
# forwarder's local checker (extras/cred-relay/fleet-relay-check.py) in front of
# a fake hub that answers 503 (an ingress with no ready pod), then not at all.
# The windows are scaled down (cache 1s, grace 10s); production is 30s / 600s.
relay_hub() {   # <dir> <port|0> — a fake hub: 200 for a pass listed in <dir>/allow, 503 while <dir>/hub-503 exists
  cat > "$1/hub.py" <<'PY'
import os, signal, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
signal.alarm(120)
D = sys.argv[1]
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        with open(os.path.join(D, "hub-hits"), "a") as f: f.write("check\n")
        if os.path.exists(os.path.join(D, "hub-503")): code = 503
        else:
            allow = open(os.path.join(D, "allow")).read().split() if os.path.exists(os.path.join(D, "allow")) else []
            code = 200 if self.headers.get("X-Fleet-Relay", "") in allow else 403
        b = b"" if code == 200 else b'{"error":"x"}'
        self.send_response(code); self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
ThreadingHTTPServer.allow_reuse_address = True
s = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), H)
open(os.path.join(D, "hub.port.tmp"), "w").write(str(s.server_address[1])); os.rename(os.path.join(D, "hub.port.tmp"), os.path.join(D, "hub.port"))
s.serve_forever()
PY
  rm -f "$1/hub.port"
  python3 -I "$1/hub.py" "$1" "$2" 2>>"$1/hub.err" &
  RH=$!; printf '%s\n' "$RH" >> "$WORK/cred-pids"
  until_ok 30 test -s "$1/hub.port"
}
# relay_ask <pass> [<path>] → the checker's status for one forward_auth subrequest
relay_ask() {
  curl -s -m 10 -o /dev/null -w '%{http_code}' -H "X-Fleet-Relay: $1" \
    -H "X-Forwarded-Uri: ${2:-/anthropic/v1/messages}" -H 'X-Forwarded-Method: POST' \
    "http://127.0.0.1:$RCP/v1/relay/check" 2>/dev/null
}
relay_is() { [ "$(relay_ask "$2")" = "$1" ]; }   # <status> <pass> — for until_ok
drill_cred_relay_hub_restart() {
  CAP=3   # revoke → the checker refuses the pass: ≤ the cache window (1s here) + one poll
  local d="$WORK/relay-check" code tok t0 tA hp
  mkdir -p "$d"; printf 'frl1.A\nfrl1.R\n' > "$d/allow"
  relay_hub "$d" 0 || { WHY="the fake hub did not start: $(tail -2 "$d/hub.err" | tr '\n' ' ')"; return 1; }
  hp=$(cat "$d/hub.port"); RCP=$(cred_deadport)
  local chk="$ROOT/extras/cred-relay/fleet-relay-check.py"
  [ -f "$chk" ] || { WHY="no local checker on the relay ($chk): Caddy asks the hub per request and refuses while it restarts"; return 1; }
  FLEET_HUB_URL="http://127.0.0.1:$hp" FLEET_RELAY_CHECK_LISTEN="127.0.0.1:$RCP" RELAY_CHECK_CACHE_S=1 RELAY_CHECK_GRACE_S=10 \
    RELAY_CHECK_TIMEOUT_S=2 FLEET_RELAY_CHECK_LOG="$d/check.log" FLEET_RELAY_CHECK_MAX_SECONDS=120 \
    python3 -I "$chk" 2>"$d/check.err" &
  printf '%s\n' "$!" >> "$WORK/cred-pids"
  until_ok 30 sh -c 'curl -s -m 2 -o /dev/null "http://127.0.0.1:$1/healthz"' _ "$RCP" \
    || { WHY="the checker did not start: $(tail -2 "$d/check.err" | tr '\n' ' ')"; return 1; }
  # hub up: A and R pass, U was never issued
  for tok in frl1.A frl1.R; do
    code=$(relay_ask "$tok"); [ "$code" = 200 ] || { WHY="hub up: $tok → $code"; return 1; }
  done
  tA=$(now)
  code=$(relay_ask frl1.U); [ "$code" = 403 ] || { WHY="hub up: an unknown pass → $code"; return 1; }
  # revoke R on the hub: the checker refuses it within its cache window (timed)
  printf 'frl1.A\n' > "$d/allow"; t0=$(now)
  until_ok 10 relay_is 403 frl1.R || { WHY="a revoked pass still passes after 10s"; return 1; }
  SECS=$(since "$t0")
  # the hub restarts — first an ingress 503, then nothing listening
  : > "$d/hub-503"; sleep 1.2
  code=$(relay_ask frl1.A); [ "$code" = 200 ] || { WHY="hub 503: a pass the hub checked → $code (the relay refuses while the hub restarts)"; return 1; }
  code=$(relay_ask frl1.U); case "$code" in 2*) WHY="hub 503: a never-checked pass → $code"; return 1 ;; esac
  code=$(relay_ask frl1.R); case "$code" in 2*) WHY="hub 503: the revoked pass → $code"; return 1 ;; esac
  code=$(relay_ask frl1.A /chatgpt/codex/x); case "$code" in 2*) WHY="hub 503: A on a prefix the hub never checked it for → $code"; return 1 ;; esac
  kill "$RH" 2>/dev/null; wait "$RH" 2>/dev/null
  code=$(relay_ask frl1.A); [ "$code" = 200 ] || { WHY="hub gone: a pass the hub checked → $code"; return 1; }
  code=$(relay_ask frl1.U); case "$code" in 2*) WHY="hub gone: a never-checked pass → $code"; return 1 ;; esac
  grep -q ' grace ' "$d/check.log" || { WHY="no grace line in the checker's log"; return 1; }
  grep -q ' refused-unavailable ' "$d/check.log" || { WHY="no refused-unavailable line in the checker's log"; return 1; }
  ! grep -q 'frl1\.' "$d/check.log" || { WHY="the checker's log carries a pass"; return 1; }
  # the window is bounded: 10s after the hub last said yes, A is refused too
  while ! le 10.5 "$(since "$tA")"; do sleep 0.2; done
  code=$(relay_ask frl1.A); case "$code" in 2*) WHY="hub gone past the grace window: A still → $code"; return 1 ;; esac
  # the hub comes back (same port): A passes again, asked for real
  rm -f "$d/hub-503"; relay_hub "$d" "$hp" || { WHY="the fake hub did not come back"; return 1; }
  until_ok 5 relay_is 200 frl1.A || { WHY="hub back: A still refused"; return 1; }
  WHAT="入口 503 / 停掉期间：核过的通行证照常放行（记 grace），没核过的、被吊销的、换前缀的拒；吊销 ${SECS}s 内生效；窗口过了也拒；入口回来照常"
}

drill_cred_central_down() {
  CAP=10
  cred_rig central untrusted reachable || return 1
  local pass tok code t0
  CRED_CENTRAL="http://127.0.0.1:$(cred_deadport)"
  cred_serve || { unset CRED_CENTRAL; return 1; }
  unset CRED_CENTRAL
  pass=$(cred_hubpass h-central -60 3600)
  t0=$(now)
  code=$(cred_req "$pass" "$CD/r1")
  SECS=$(since "$t0")
  case "$code:$(cat "$CD/r1")" in 502:*cred-proxy*central*) ;; *)
    WHY="central down: wanted a 502 from cred-proxy naming central, got $code $(cat "$CD/r1")"; return 1 ;; esac
  # a local session credential on an untrusted machine: never a credential file
  tok=$(cred_ctl mint --account a1 --sid s-central)
  code=$(cred_req "$tok" "$CD/r2")
  [ "$code" = 403 ] || { WHY="an fcp1 session on an untrusted machine got $code (wanted 403): $(cat "$CD/r2")"; return 1; }
  if grep -Eq '^(direct-|relay )' "$CD/hits" 2>/dev/null || grep -q '"cred": "file"' "$CD/proxy.log" 2>/dev/null; then
    WHY="an untrusted machine reached a provider with a credential file: $(grep -v '^v1 ' "$CD/hits" | head -3 | tr '\n' ' ')"; return 1
  fi
  WHAT="中心代理全挂 → 不可信会话 502 写明 central 连不上；本地会话凭据 403；没有一个请求带着凭据文件出去"
}

drill_cred_probe_wrong() {
  CAP=10
  cred_rig probe trusted reachable || return 1
  local tok code t0
  : > "$CD/region-direct"     # the probe said reachable; the provider says otherwise
  cred_serve || return 1
  tok=$(cred_ctl mint --account a1 --sid s-probe)
  t0=$(now)
  code=$(cred_req "$tok" "$CD/r1")
  SECS=$(since "$t0")
  case "$code:$(cat "$CD/r1")" in 200:*'"via": "relay"'*) ;; *)
    WHY="probe wrong (direct region-blocked): wanted the same request on relay, got $code $(cat "$CD/r1")"; return 1 ;; esac
  : > "$CD/hits"
  code=$(cred_req "$tok" "$CD/r2")
  [ "$code" = 200 ] && ! grep -q '^direct-' "$CD/hits" \
    || { WHY="the next request went back to direct ($code; hits: $(tr '\n' ' ' < "$CD/hits"))"; return 1; }
  WHAT="探测说能直连、上游按地区拒 → 同一请求切 relay 成功，之后的请求不再先试 direct"
}

drill_cred_session_expire() {
  CAP=10
  cred_rig expire untrusted reachable || return 1
  local pass tok code t0 w
  export FLEET_CRED_PROXY_TTL=2
  cred_serve || { unset FLEET_CRED_PROXY_TTL; return 1; }
  unset FLEET_CRED_PROXY_TTL
  # central: a hub pass three seconds from its end, the session keeps sending it
  pass=$(cred_hubpass h-exp -100 3)
  code=$(cred_req "$pass" "$CD/r1")
  [ "$code" = 200 ] || { WHY="the hub pass did not work while fresh: $code $(cat "$CD/r1")"; return 1; }
  sleep 4; t0=$(now)
  code=$(cred_req "$pass" "$CD/r2")
  SECS=$(since "$t0")
  [ "$code" = 200 ] || { WHY="the session's hub pass ran out mid-session and the proxy did not renew it: $code $(cat "$CD/r2")"; return 1; }
  grep -q '^v1 /v1/fleet/session-cred/renew' "$CD/hits" || { WHY="200, but no renewal reached the hub"; return 1; }
  # local: an fcp1 that lives 2s, its session's wrapper still alive
  sleep 600 & w=$!; printf '%s\n' "$w" >> "$WORK/cred-pids"
  tok=$(cred_ctl mint --account a1 --sid s-exp --wrap "$w" 2>&1) || { WHY="mint --wrap: $tok"; return 1; }
  sleep 3
  printf 'trusted\n' > "$CD/trust"; cred_ctl route --refresh >/dev/null 2>&1
  code=$(cred_req "$tok" "$CD/r3")
  [ "$code" = 200 ] || { WHY="a live session's fcp1 ran out and the proxy refused it: $code $(cat "$CD/r3")"; return 1; }
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  code=$(cred_req "$tok" "$CD/r4")
  [ "$code" = 401 ] || { WHY="its session is over, yet the expired fcp1 still works ($code)"; return 1; }
  WHAT="会话中途凭据到期：入口通行证由代理续签（会话还拿着旧的照常 200），本地会话凭据随会话续期；会话结束即失效"
}

# cred-sep-sudo-root (issue #2135): the operator types what fleet-credsep.sh
# itself says — `sudo bash …/fleet-credsep.sh install`. Under sudo `id` says
# root; the install must still separate THE LOGIN (SUDO_USER) — its store, its
# record, its agent — never a `root` store beside an agent left reading node.env.
# Sandbox: every root path under the work dir (FLEET_CREDSEP_* seams), an `id`
# shim playing root, the role account played by this user, no launchctl.
drill_cred_pass_lapsed() {
  CAP=10
  cred_rig lapsed untrusted reachable || return 1
  local pass old code t0
  cred_serve || return 1
  # the laptop slept through the renew window: its session's pass ran out 10 h ago
  pass=$(cred_hubpass h-lap -86400 -36000)
  t0=$(now)
  code=$(cred_req "$pass" "$CD/r1")
  SECS=$(since "$t0")
  case "$code:$(cat "$CD/r1")" in 200:*'"via": "central"'*) ;; *)
    WHY="a pass lapsed while the machine slept: wanted the proxy to renew it and 200, got $code $(cat "$CD/r1")"; return 1 ;; esac
  grep -q '"ev": "renew", "kind": "hub", "pass_id": "h-lap"' "$CD/proxy.log" \
    || { WHY="200, but no hub renewal of the lapsed pass in the log"; return 1; }
  code=$(cred_req "$pass" "$CD/r2")
  [ "$code" = 200 ] || { WHY="the next request after the renewal got $code: $(cat "$CD/r2")"; return 1; }
  # past the hub's grace: refused and dropped, never forwarded as live
  old=$(cred_hubpass h-old -700000 -691200)
  code=$(cred_req "$old" "$CD/r3")
  [ "$code" = 401 ] || { WHY="a pass 8 days lapsed came back $code (wanted the central's 401): $(cat "$CD/r3")"; return 1; }
  grep -q '"ev": "renew_drop", "kind": "hub", "pass_id": "h-old"' "$CD/proxy.log" \
    || { WHY="the pass past the grace was not dropped"; return 1; }
  WHAT="机器睡过续签窗口、入口通行证已过期 10 小时 → 会话下一请求由代理补签照常 200；过期超 7 天的入口拒签、代理丢掉"
}

drill_cred_sep_sudo_root() {
  CAP=30
  local me sb t0 out
  me=$(id -un); sb="$WORK/sep"
  mkdir -p "$sb/shim" "$sb/home/.config/claude-fleet/accounts/a1.hub" "$sb/daemons" "$sb/home/.ccquota"
  cat > "$sb/shim/id" <<'EOF'
#!/bin/sh
case "$*" in -u) echo 0 ;; -un|"-u -n"|"-n -u") echo root ;; *) exec /usr/bin/id "$@" ;; esac
EOF
  chmod +x "$sb/shim/id"
  printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-SEP","refreshToken":null}}' \
    > "$sb/home/.config/claude-fleet/accounts/a1.hub/.credentials.json"
  printf 'CCQUOTA_HUB_URL=http://127.0.0.1:1\nCCQUOTA_TOKEN=ccq_SEP_SECRET\n' > "$sb/home/.config/claude-fleet/node.env"
  printf 'export FLEET_CRED_SEPARATE=1\n' > "$sb/home/.config/claude-fleet/fleet.conf"
  t0=$(now)
  out=$(PATH="$sb/shim:$PATH" SUDO_USER="$me" HOME="$sb/home" FLEET_CONF_DIR="$sb/home/.config/claude-fleet" \
    FLEET_CREDSEP_ROOT_BASE="$sb/db" FLEET_CREDSEP_RUN_BASE="$sb/run" FLEET_CREDSEP_LOG_BASE="$sb/log" \
    FLEET_CREDSEP_LIB="$sb/lib" FLEET_CREDSEP_DAEMON_DIR="$sb/daemons" FLEET_CREDSEP_ROLE="$me" \
    FLEET_CREDSEP_SVC=0 FLEET_CREDSEP_TEST=1 FLEET_CREDSEP_SUDO='' \
    bash "$BIN/fleet-credsep.sh" install 2>&1)
  SECS=$(since "$t0")
  [ ! -e "$sb/db/root" ] || { WHY="under sudo the login was taken as root: the credentials went to $sb/db/root ($(printf '%s' "$out" | tail -1))"; return 1; }
  [ -f "$sb/db/$me/node.env" ] && [ -f "$sb/db/$me/accounts/a1.hub/.credentials.json" ] \
    || { WHY="the login's store $sb/db/$me was not filled: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; return 1; }
  grep -q "\"root\": \"$sb/db/$me\"" "$sb/home/.config/claude-fleet/credsep.json" 2>/dev/null \
    || { WHY="credsep.json does not name the login's store"; return 1; }
  # root with neither SUDO_USER nor --login: refused, nothing touched
  out=$(PATH="$sb/shim:$PATH" SUDO_USER='' HOME="$sb/home" FLEET_CREDSEP_SUDO='' FLEET_CREDSEP_TEST=1 \
    bash "$BIN/fleet-credsep.sh" install 2>&1); local rc=$?
  [ "$rc" = 2 ] || { WHY="root without SUDO_USER / --login was not refused (rc $rc): $out"; return 1; }
  WHAT="sudo 下照提示敲 install：凭据进的是登录 ${me} 自己的存储，不是 root 的；root 没 SUDO_USER 又没 --login 直接拒"
}

# ================================================================ run ===========
# cred_run_drills <file> — every drill_cred_* in <file>, each checked for its row
cred_run_drills() {
FAILS=0; PASSES=0
for fn in $(sed -n 's/^\(drill_cred_[a-z0-9_]*\)() *{.*/\1/p' "$1"); do
  r=$(printf '%s' "${fn#drill_}" | tr _ -)
  grep -qF -- "| \`$r\` |" "$DOC" || { FAILS=$((FAILS + 1)); printf 'FAIL  lint: %s has no row in docs/BREAK-IT.md\n' "$fn"; continue; }
  if [ -n "${BREAK_ONLY:-}" ]; then case " $BREAK_ONLY " in *" $r "*) ;; *) continue ;; esac; fi
  SECS='' CAP='' WHY='' WHAT=''
  if "$fn" && [ -n "$SECS" ] && le "$SECS" "$CAP"; then
    PASSES=$((PASSES + 1))
    printf 'PASS  %-20s %5ss ≤%ss  %s\n' "$r" "$SECS" "$CAP" "$WHAT"
  else
    FAILS=$((FAILS + 1))
    [ -n "$WHY" ] || WHY="recovered in ${SECS:-?}s, over the ${CAP}s bound"
    printf 'FAIL  %-20s %s\n' "$r" "$WHY"
  fi
done
if [ "$FAILS" -gt 0 ]; then
  printf '%s selftest: %d FAILED, %d passed\n' "$(basename "$1" -selftest.sh)" "$FAILS" "$PASSES" >&2
  exit 1
fi
printf '%s selftest: OK (%d drills green)\n' "$(basename "$1" -selftest.sh)" "$PASSES"
}
[ -n "${BREAK_CRED_LIB:-}" ] && return 0
cred_run_drills "$0"
