#!/usr/bin/env bash
# fleet-cred-proxy-selftest.sh — the credential proxy's three routes, on loopback
# only (issue #1970, EPIC #1967 C3). Drives bin/fleet-cred-proxy.sh +
# bin/fleet-cred-proxy.py against ONE fake server playing every far end:
# the providers (direct), the Singapore relay, the cluster's central proxy and
# the hub's /v1/node/self — all on 127.0.0.1, sandbox HOME + FLEET_CONF_DIR.
#
#   A  FLEET_CRED_PROXY=0: no proxy process, no port, no socket (the degenerate)
#   B  direct  — trusted + reachable: Claude + Codex, real token put in, x-api-key
#                dropped, chatgpt-account-id overwritten, body byte for byte, streamed
#   C  relay   — probe unreachable: Claude + Codex via the relay with X-Fleet-Relay
#   D  central — the hub says untrusted: Claude + Codex with the hub credential and
#                the credential files unreadable; no hub credential → 403
#   E  a region 403 on direct moves the SAME request to relay (route_switch logged)
#   F  three sessions at once never cross accounts; rebind / revoke
#   G  rails: ctl.sock 0600, 127.0.0.1 only, no token in the log
#   H  the daemon entry (`run`): starts the proxy when on, stops it when the
#      config turns off, and a SIGKILLed launcher takes the proxy with it
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
SB=$(mktemp -d "${TMPDIR:-/tmp}/cred-proxy-st.XXXXXX")
PROXY_PID=''
cleanup() {
  [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null
  [ -n "${RUNPID:-}" ] && kill "$RUNPID" 2>/dev/null
  kill "$(cat "$SB/conf/cred-proxy/pid" 2>/dev/null)" 2>/dev/null
  kill "$(cat "$SB/fake.pid" 2>/dev/null)" 2>/dev/null
  rm -rf "$SB"
}
trap cleanup EXIT
export HOME="$SB/home" FLEET_CONF_DIR="$SB/conf" XDG_CONFIG_HOME="$SB/xdg"
mkdir -p "$HOME" "$FLEET_CONF_DIR" "$XDG_CONFIG_HOME"
unset FLEET_HUB_URL CCQUOTA_HUB_URL CCQUOTA_TOKEN FLEET_PROBE_FORCE_UNREACHABLE

FAIL=0
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; FAIL=1; }

# ── A: switched off ⇒ no process ─────────────────────────────────────────────
out=$(FLEET_CRED_PROXY=0 bash "$BIN/fleet-cred-proxy.sh" ensure 2>&1); rc=$?
[ "$rc" = 3 ] && pass "A off: ensure refuses (exit 3)" || fail "A off: ensure rc=$rc ($out)"
FLEET_CRED_PROXY=0 FLEET_CRED_PROXY_IDLE_SECS=1 bash "$BIN/fleet-cred-proxy.sh" run >/dev/null 2>&1 &
RUNPID=$!
sleep 3
kids=$(pgrep -P "$RUNPID" -f fleet-cred-proxy.py 2>/dev/null | wc -l | tr -d ' ')
if [ "$kids" = 0 ] && [ ! -e "$FLEET_CONF_DIR/cred-proxy/port" ] && [ ! -e "$FLEET_CONF_DIR/cred-proxy/ctl.sock" ]; then
  pass "A off: run starts no proxy (no port, no socket)"
else fail "A off: run started something (kids=$kids)"; ls -la "$FLEET_CONF_DIR/cred-proxy" 2>&1; fi
kill "$RUNPID" 2>/dev/null; wait "$RUNPID" 2>/dev/null

# ── the fake far end ─────────────────────────────────────────────────────────
cat > "$SB/fake.py" <<'PY'
import hashlib, json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
SB = sys.argv[1]
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def reply(self, code, obj, chunks=1):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()
        n = max(1, len(b) // chunks + 1)
        for i in range(0, len(b), n):
            self.wfile.write(b"%x\r\n%s\r\n" % (len(b[i:i+n]), b[i:i+n])); self.wfile.flush()
            time.sleep(0.02)
        self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
    def do_GET(self): self.handle_any()
    def do_POST(self): self.handle_any()
    def handle_any(self):
        n = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(n) if n else b""
        p = self.path
        h = {k.lower(): v for k, v in self.headers.items()}
        if p == "/v1/node/self":
            if h.get("authorization") != "Bearer nodetok":
                return self.reply(401, {"error": "node token"})
            t = open(os.path.join(SB, "trust")).read().strip()
            return self.reply(200, {"endpoint_id": "e1"} if t == "absent" else {"endpoint_id": "e1", "trust": t})
        via = p.split("/")[1]
        prov = "codex" if ("codex" in p) else "claude"
        if via == "direct-anthropic" or via == "direct-codex":
            if os.path.exists(os.path.join(SB, "region-direct")):
                if prov == "codex":
                    return self.reply(403, {"detail": {"code": "unsupported_country_region_territory"}})
                return self.reply(403, {"type": "error", "error": {"type": "forbidden", "message": "Request not allowed"}})
            via = "direct"
        elif via == "relay":
            if h.get("x-fleet-relay") != "relaytok":
                return self.reply(401, {"error": "relay credential"})
        elif via == "central":
            if not h.get("authorization", "").startswith("Bearer fcp-h1."):
                return self.reply(401, {"error": "central wants a hub credential"})
        else:
            return self.reply(404, {"error": p})
        self.reply(200, {"via": via, "prov": prov, "path": p, "auth": h.get("authorization", ""),
                         "xkey": "x-api-key" in h, "acct_id": h.get("chatgpt-account-id", ""),
                         "relay_hdr": h.get("x-fleet-relay", ""), "beta": h.get("anthropic-beta", ""),
                         "sha": hashlib.sha256(body).hexdigest()}, chunks=4)
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
srv.daemon_threads = True
open(os.path.join(SB, "fake.port"), "w").write(str(srv.server_address[1]))
open(os.path.join(SB, "fake.pid"), "w").write(str(os.getpid()))
srv.serve_forever()
PY
echo trusted > "$SB/trust"
python3 -I "$SB/fake.py" "$SB" & disown
i=0; while [ ! -s "$SB/fake.port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
FP=$(cat "$SB/fake.port")
U="http://127.0.0.1:$FP"

# accounts: a1..a3 for Claude (the hub lease layout) and Codex (codex homes)
for a in a1 a2 a3; do
  mkdir -p "$FLEET_CONF_DIR/accounts/$a.hub" "$SB/codex-homes/$a"
  printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat-REAL-%s"}}' "$a" > "$FLEET_CONF_DIR/accounts/$a.hub/.credentials.json"
  printf '{"tokens":{"access_token":"cx-REAL-%s","account_id":"acct-%s"}}' "$a" "$a" > "$SB/codex-homes/$a/auth.json"
done
printf 'CCQUOTA_HUB_URL=%s\nCCQUOTA_TOKEN=nodetok\n' "$U" > "$FLEET_CONF_DIR/node.env"
probe() { printf '{"loc":"US","anthropic":"%s","openai":"%s","verdict":"ok"}\n' "$1" "$1" > "$FLEET_CONF_DIR/node-probe.json"; }
probe reachable
cat > "$FLEET_CONF_DIR/fleet.conf" <<EOF
FLEET_CRED_PROXY=1
FLEET_CRED_ANTHROPIC_URL=$U/direct-anthropic
FLEET_CRED_CODEX_URL=$U/direct-codex
FLEET_CRED_RELAY_URL=$U/relay
FLEET_CRED_CENTRAL_URL=$U/central
FLEET_CRED_CODEX_HOMES=$SB/codex-homes
FLEET_CRED_PROXY_LOG=$SB/proxy.log
EOF
printf 'FLEET_CRED_RELAY_TOKEN=relaytok\n' > "$FLEET_CONF_DIR/secrets.env"
printf '. "%s/secrets.env"\n' "$FLEET_CONF_DIR" >> "$FLEET_CONF_DIR/fleet.conf"

PORT=$(bash "$BIN/fleet-cred-proxy.sh" ensure --max-seconds 300 2>"$SB/ensure.err") \
  || { cat "$SB/ensure.err"; fail "start: ensure"; exit 1; }
PROXY_PID=$(cat "$FLEET_CONF_DIR/cred-proxy/pid")
CP() { bash "$BIN/fleet-cred-proxy.sh" "$@"; }

# ── the driver: one request, its JSON verdict ────────────────────────────────
cat > "$SB/req.py" <<'PY'
import hashlib, http.client, json, sys
port, path, tok = int(sys.argv[1]), sys.argv[2], sys.argv[3]
extra = dict(a.split("=", 1) for a in sys.argv[4:])
body = (b'{"model":"m","messages":[{"role":"user","content":"Reply: PONG \xe4\xb8\xad"}]}' * 3)
h = {"content-type": "application/json", "authorization": "Bearer " + tok, "x-api-key": tok}
h.update(extra)
c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
c.request("POST", path, body=body, headers=h)
r = c.getresponse()
chunks, data = 0, b""
while True:
    d = r.read1(65536)
    if not d: break
    chunks += 1; data += d
try: j = json.loads(data)
except ValueError: j = {"raw": data.decode("utf-8", "replace")}
j["_status"], j["_chunks"], j["_sent_sha"] = r.status, chunks, hashlib.sha256(body).hexdigest()
print(json.dumps(j))
PY
R() { python3 -I "$SB/req.py" "$PORT" "$@"; }
jf() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get(sys.argv[2], ""))' "$1" "$2"; }

check() { # check <leg> <route> <provider> <json> <acct>
  local leg="$1" want="$2" prov="$3" j="$4" a="$5" st via auth
  st=$(jf "$j" _status); via=$(jf "$j" via); auth=$(jf "$j" auth)
  if [ "$st" != 200 ] || [ "$via" != "$want" ]; then fail "$leg $want $prov: status=$st via=$via ($j)"; return 1; fi
  [ "$(jf "$j" sha)" = "$(jf "$j" _sent_sha)" ] || { fail "$leg $want $prov: body changed"; return 1; }
  [ "$(jf "$j" xkey)" = False ] || { fail "$leg $want $prov: x-api-key reached upstream"; return 1; }
  case "$want" in
    central) case "$auth" in "Bearer fcp-h1."*) ;; *) fail "$leg central $prov: auth=$auth"; return 1 ;; esac ;;
    *) if [ "$prov" = codex ]; then
         [ "$auth" = "Bearer cx-REAL-$a" ] && [ "$(jf "$j" acct_id)" = "acct-$a" ] \
           || { fail "$leg $want codex: auth=$auth acct=$(jf "$j" acct_id)"; return 1; }
       else
         [ "$auth" = "Bearer sk-ant-oat-REAL-$a" ] || { fail "$leg $want claude: auth=$auth"; return 1; }
         case "$(jf "$j" beta)" in *oauth-2025-04-20*) ;; *) fail "$leg $want claude: no oauth beta"; return 1 ;; esac
       fi ;;
  esac
  [ "$want" = relay ] && { [ "$(jf "$j" relay_hdr)" = relaytok ] || { fail "$leg relay: no X-Fleet-Relay"; return 1; }; }
  return 0
}

T1=$(CP mint --account a1 --sid s1)
case "$T1" in fcp1.*) ;; *) fail "mint: $T1"; exit 1 ;; esac

# ── B: direct ────────────────────────────────────────────────────────────────
r=$(CP route); case "$r" in direct*) ;; *) fail "B route: $r" ;; esac
jc=$(R /v1/messages "$T1"); jx=$(R /codex/responses "$T1" chatgpt-account-id=acct-EVIL)
if check B direct claude "$jc" a1 && check B direct codex "$jx" a1; then
  [ "$(jf "$jc" _chunks)" -ge 2 ] && pass "route direct: Claude + Codex (real token in, x-api-key out, account id pinned, body intact, streamed)" \
    || fail "B direct: response not streamed (chunks=$(jf "$jc" _chunks))"
fi

# ── C: relay ─────────────────────────────────────────────────────────────────
probe unreachable
r=$(CP route); case "$r" in relay*) ;; *) fail "C route: $r" ;; esac
r=$(CP route --provider codex); case "$r" in relay*) ;; *) fail "C route codex: $r" ;; esac
jc=$(R /v1/messages "$T1"); jx=$(R /codex/responses "$T1")
check C relay claude "$jc" a1 && check C relay codex "$jx" a1 \
  && pass "route relay: Claude + Codex (probe unreachable → relay, X-Fleet-Relay carried)"

# ── D: central ───────────────────────────────────────────────────────────────
probe reachable
echo untrusted > "$SB/trust"
r=$(CP route --refresh); case "$r" in central*) ;; *) fail "D route: $r" ;; esac
TD=$(CP mint --account a1 --sid sd)
jn=$(R /v1/messages "$TD")
[ "$(jf "$jn" _status)" = 403 ] && pass "D central with no hub credential → 403 (not retried)" || fail "D no hub cred: $jn"
printf 'fcp-h1.hubsigned.sd\n' | CP attach --sid sd >/dev/null || fail "D attach"
chmod 000 "$FLEET_CONF_DIR/accounts/a1.hub/.credentials.json" "$SB/codex-homes/a1/auth.json"
mv "$FLEET_CONF_DIR/accounts" "$FLEET_CONF_DIR/accounts.away"; mv "$SB/codex-homes" "$SB/codex-homes.away"
jc=$(R /v1/messages "$TD"); jx=$(R /codex/responses "$TD")
jh=$(R /v1/messages "fcp-h1.direct-hub-cred")
if check D central claude "$jc" a1 && check D central codex "$jx" a1 && check D central claude "$jh" a1; then
  if grep '"ev": "fwd"' "$SB/proxy.log" | grep '"route": "central"' | grep -q '"cred": "file"'; then
    fail "D central: a central request read a credential file"
  else pass "route central: Claude + Codex (untrusted → central, no credential file read)"; fi
fi
mv "$FLEET_CONF_DIR/accounts.away" "$FLEET_CONF_DIR/accounts"; mv "$SB/codex-homes.away" "$SB/codex-homes"
chmod 600 "$FLEET_CONF_DIR/accounts/a1.hub/.credentials.json" "$SB/codex-homes/a1/auth.json"

# ── E: a region refusal switches the same session's route ───────────────────
echo absent > "$SB/trust"      # a hub with no trust record = trusted (the degenerate)
r=$(CP route --refresh); case "$r" in direct*) ;; *) fail "E route (no trust record): $r" ;; esac
touch "$SB/region-direct"
TE=$(CP mint --account a2 --sid se)
jc=$(R /v1/messages "$TE"); jx=$(R /codex/responses "$TE")
if check E relay claude "$jc" a2 && check E relay codex "$jx" a2 \
   && grep '"ev": "route_switch"' "$SB/proxy.log" | grep -q '"sid": "se"'; then
  n0=$(grep -c '"route": "direct"' "$SB/proxy.log")
  jc=$(R /v1/messages "$TE")
  n1=$(grep -c '"route": "direct"' "$SB/proxy.log")
  check E relay claude "$jc" a2 && [ "$n0" = "$n1" ] \
    && pass "E region 403 → same request on relay, route_switch logged, session stays on relay" \
    || fail "E session went back to direct"
else fail "E no route_switch"; fi
rm -f "$SB/region-direct"

# ── F: concurrency, rebind, revoke ──────────────────────────────────────────
T2=$(CP mint --account a2 --sid s2); T3=$(CP mint --account a3 --sid s3)
cpids=''
for s in 1 2 3; do
  eval "tok=\$T$s"
  ( for k in 1 2 3 4; do R /v1/messages "$tok"; R /codex/responses "$tok"; done > "$SB/conc.$s" ) &
  cpids="$cpids $!"
done
for p in $cpids; do wait "$p"; done   # never a bare `wait`: the fake server is a child too
bad=0
for s in 1 2 3; do
  while read -r line; do
    a=$(jf "$line" auth)
    case "$a" in "Bearer sk-ant-oat-REAL-a$s"|"Bearer cx-REAL-a$s") ;; *) bad=$((bad + 1)) ;; esac
  done < "$SB/conc.$s"
  [ "$(wc -l < "$SB/conc.$s" | tr -d ' ')" = 8 ] || bad=$((bad + 1))
done
[ "$bad" = 0 ] && pass "F 3 sessions × 8 concurrent requests: no account crossed" || fail "F crossed/missing: $bad"
CP rebind --sid s1 --account a3 >/dev/null
j=$(R /v1/messages "$T1"); [ "$(jf "$j" auth)" = "Bearer sk-ant-oat-REAL-a3" ] && pass "F rebind: next request on the new account" || fail "F rebind: $j"
CP revoke --sid s1 >/dev/null
j=$(R /v1/messages "$T1"); [ "$(jf "$j" _status)" = 401 ] && pass "F revoke → 401" || fail "F revoke: $j"
j=$(R /v1/messages "fcp1.forged.sig"); [ "$(jf "$j" _status)" = 401 ] || fail "F forged: $j"
CP mint --account a9 --sid s9 > "$SB/t9"; j=$(R /v1/messages "$(cat "$SB/t9")")
[ "$(jf "$j" _status)" = 403 ] && pass "F no credential for the account → 403 (permanent, never 503)" || fail "F nocred: $j"

# ── G: rails ─────────────────────────────────────────────────────────────────
mode=$(stat -c %a "$FLEET_CONF_DIR/cred-proxy/ctl.sock" 2>/dev/null || stat -f %Lp "$FLEET_CONF_DIR/cred-proxy/ctl.sock")   # GNU first: GNU `stat -f` is filesystem status
[ "$mode" = 600 ] && pass "G ctl.sock 0600" || fail "G ctl.sock mode $mode"
if command -v lsof >/dev/null 2>&1; then
  l=$(lsof -nP -a -p "$PROXY_PID" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}')
  case "$l" in "127.0.0.1:$PORT") pass "G listens on 127.0.0.1 only" ;; *) fail "G listen: $l" ;; esac
fi
if grep -Eq 'REAL-a|relaytok|nodetok|fcp1\.|fcp-h1\.' "$SB/proxy.log"; then
  fail "G a credential reached the log"; grep -Eo '.{40}(REAL-a|relaytok|nodetok|fcp1\.|fcp-h1\.).{10}' "$SB/proxy.log" | head -3
else pass "G no credential in the log (redacted)"; fi

# ── H: the daemon entry ──────────────────────────────────────────────────────
kill "$PROXY_PID" 2>/dev/null; PROXY_PID=''
i=0; while [ -e "$FLEET_CONF_DIR/cred-proxy/ctl.sock" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
up() { [ -S "$FLEET_CONF_DIR/cred-proxy/ctl.sock" ] && kill -0 "$(cat "$FLEET_CONF_DIR/cred-proxy/pid" 2>/dev/null)" 2>/dev/null; }
waitfor() { local i=0; while [ "$i" -lt 60 ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done; return 1; }
FLEET_CRED_PROXY_IDLE_SECS=1 bash "$BIN/fleet-cred-proxy.sh" run --max-seconds 120 >/dev/null 2>&1 & RUNPID=$!
if waitfor up && [ "$(cat "$FLEET_CONF_DIR/cred-proxy/port")" = "$PORT" ]; then
  pass "H run: on → proxy up, on the same port as before ($PORT)"
else fail "H run did not start the proxy (or moved its port)"; fi
sed -i.bak 's/^FLEET_CRED_PROXY=1$/FLEET_CRED_PROXY=0/' "$FLEET_CONF_DIR/fleet.conf"
if waitfor sh -c "! kill -0 \$(cat '$FLEET_CONF_DIR/cred-proxy/pid' 2>/dev/null) 2>/dev/null" && kill -0 "$RUNPID" 2>/dev/null; then
  pass "H run: config turned off → proxy stopped, launcher idles"
else fail "H run: the proxy outlived FLEET_CRED_PROXY=0"; fi
mv "$FLEET_CONF_DIR/fleet.conf.bak" "$FLEET_CONF_DIR/fleet.conf"
waitfor up || fail "H run: did not come back on"
pp=$(cat "$FLEET_CONF_DIR/cred-proxy/pid" 2>/dev/null)
kill -9 "$RUNPID" 2>/dev/null; wait "$RUNPID" 2>/dev/null; RUNPID=''
if waitfor sh -c "! kill -0 $pp 2>/dev/null"; then pass "H a SIGKILLed launcher takes its proxy with it"
else fail "H proxy $pp outlived its launcher"; kill "$pp" 2>/dev/null; fi

[ "$FAIL" = 0 ] && echo "fleet-cred-proxy-selftest: OK" || echo "fleet-cred-proxy-selftest: FAILED"
exit "$FAIL"
