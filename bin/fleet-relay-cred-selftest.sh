#!/bin/bash
# fleet-relay-cred-selftest.sh — the Singapore relay road end to end (issue
# #1974, EPIC #1967 C7): bin/fleet-relay-cred.sh against a fake hub, and the
# relay itself — extras/cred-relay/Caddyfile under a real Caddy when one is on
# PATH (or FLEET_RELAY_CADDY names it), else a fake forwarder with the same
# rules — in front of a fake upstream. Everything binds 127.0.0.1; no network,
# no tmux. The hub's real check is pinned by Go (fleet_relay_cred_test.go);
# the relay asks it through its local checker (extras/cred-relay/fleet-relay-check.py).
#
# What it pins:
#   A. usage     no action / unknown / extra args / bad machine: exit 2
#   B. fetch     module off → 10, nothing asked; no node token → 1; fetch →
#                `ISSUED m4/alice`, the pass kept 0600 in a 0700 dir; the node
#                token and the pass never in a curl argv
#   C. keep      check → OK; fetch again → KEPT (no new mint); --force → a new
#                pass, and the old one no longer passes
#   D. relay     a Claude request through the relay with the subscription's
#                Authorization + X-Fleet-Relay → 200 PONG streamed; upstream saw
#                the Authorization byte for byte, no X-Fleet-Relay, no
#                X-Forwarded-*; Codex /chatgpt/codex/… → /backend-api/codex/…;
#                the hub's check never saw an Authorization
#   E. refused   no pass / forged pass / revoked pass → 403 and the upstream is
#                never reached; check → exit 3 REFUSED
#   F. not open  any other path → 404, upstream not reached
#   G. log       the relay's log has the prefix, status and bytes — and no
#                subscription fragment, no pass, no path past the prefix
#   H. operator  revoke / status: the viewer token on curl's stdin; status
#                shows logins, never a hash
#   I. proxy     the machine's own proxy (fleet-cred-proxy, C3) on the relay
#                road: FLEET_CRED_RELAY_URL and no FLEET_CRED_RELAY_TOKEN →
#                `ensure` mints the pass, and a Claude and a Codex session reach
#                the upstream through the relay with the real credential
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$BIN/fleet-relay-cred.sh"
CADDYFILE="$BIN/../extras/cred-relay/Caddyfile"
CHECKS=0
fail() { printf 'fleet-relay-cred selftest FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }

# Short: the proxy's ctl.sock lives under it, and a unix socket path is capped
# at 104 bytes on macOS.
TMPB=${TMPDIR:-/tmp}; [ "${#TMPB}" -le 40 ] || TMPB=/tmp
WORK="$(mktemp -d "${TMPB%/}/frc.XXXXXX")" || exit 2
PIDS=''
cleanup() {
  local p
  exec 2>/dev/null   # no "Terminated" job notices for the fakes we stop
  for p in $PIDS $(cat "$WORK/conf/cred-proxy/pid" 2>/dev/null); do kill "$p" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1
mkdir -p "$HOME" "$FLEET_CONF_DIR"
unset CCQUOTA_FLEET CCQUOTA_TOKEN CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_HUB_URL FLEET_HUB_CURL FLEET_HUB_TIMEOUT

SUB='sk-ant-oat01-FAKESUBSCRIPTION-0123456789'
NODE_TOK='ccq_node-token-for-m4'
VIEWER='viewer-token-xyz'

# ---- the fakes: hub, upstream, and (without Caddy) the relay ---------------
cat > "$WORK/fakes.py" <<'PY'
import hashlib, http.client, http.server, json, os, secrets, signal, socketserver, sys, threading, time
signal.alarm(int(os.environ.get("FAKE_TTL", "180")))   # never outlive the test
work, mode = sys.argv[1], sys.argv[2]
NODE, VIEWER = os.environ["NODE_TOK"], os.environ["VIEWER"]
PREFIXES = ("/anthropic/", "/chatgpt/", "/openai-auth/")

def jlog(name, row):
    with open(os.path.join(work, name), "a") as f:
        f.write(json.dumps(row) + "\n")

class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

class Base(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""
    def send(self, code, obj=None, raw=None, hdrs=()):
        b = raw if raw is not None else json.dumps(obj or {}).encode()
        self.send_response(code)
        for k, v in hdrs: self.send_header(k, v)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

HASHES = {}   # hash -> machine
SETTINGS = {}

class Hub(Base):
    def do_POST(self):
        self.body()
        auth = self.headers.get("Authorization", "")
        if self.path == "/v1/node/relay-credential":
            if auth != "Bearer " + NODE:
                return self.send(401, {"error": "unrecognised enrollment token"})
            if os.path.exists(os.path.join(work, "hub-untrusted")):
                return self.send(403, {"error": "untrusted_node", "message": "m4 is not a trusted machine"})
            tok = "frl1." + secrets.token_urlsafe(32)
            for h in [h for h, m in HASHES.items() if m == "m4"]:
                del HASHES[h]
            HASHES[hashlib.sha256(tok.encode()).hexdigest()] = "m4"
            SETTINGS["fleet.node_relay.m4"] = "alice"
            jlog("hub.log", {"route": "mint"})
            return self.send(200, {"token": tok, "machine": "m4", "login": "alice", "issued_at": "now"})
        if self.path == "/test/revoke":
            HASHES.clear(); SETTINGS.clear()
            return self.send(200, {})
        self.send(404, {})
    def do_PUT(self):
        b = json.loads(self.body() or b"{}")
        if self.headers.get("Authorization") != "Bearer " + VIEWER:
            return self.send(403, {"error": "operator only"})
        if self.path == "/v1/fleet/settings" and b.get("key", "").startswith("fleet.node_relay.") and b.get("value") == "":
            HASHES.clear(); SETTINGS.pop(b["key"], None)
            jlog("hub.log", {"route": "revoke", "key": b["key"]})
            return self.send(200, {"settings": SETTINGS, "effective": {}})
        self.send(400, {})
    def do_GET(self):
        if self.path == "/v1/node/self":
            if self.headers.get("Authorization") != "Bearer " + NODE:
                return self.send(401, {})
            return self.send(200, {"hostname": "m4", "trust": "trusted"})
        if self.path == "/v1/relay/check":
            jlog("hub.log", {"route": "check", "authorization": "Authorization" in self.headers,
                             "cookie": "Cookie" in self.headers, "uri": self.headers.get("X-Forwarded-Uri", "")})
            p = self.headers.get("X-Fleet-Relay", "")
            uri = self.headers.get("X-Forwarded-Uri", "")
            if uri and not uri.startswith(PREFIXES):
                return self.send(403, {"error": "relay_refused", "message": "bad path"})
            if hashlib.sha256(p.encode()).hexdigest() in HASHES:
                return self.send(200, raw=b"")
            return self.send(403, {"error": "relay_refused", "message": "unknown or revoked relay credential"})
        if self.path == "/v1/fleet/settings":
            if self.headers.get("Authorization") != "Bearer " + VIEWER:
                return self.send(403, {})
            return self.send(200, {"settings": SETTINGS, "effective": {}})
        self.send(404, {})

class Up(Base):
    def handle_any(self):
        b = self.body()
        jlog("upstream.log", {"path": self.path, "authorization": self.headers.get("Authorization"),
                              "relay": self.headers.get("X-Fleet-Relay"),
                              "fwd": sorted(k for k in self.headers.keys() if k.lower().startswith("x-forwarded") or k.lower() in ("forwarded", "x-real-ip")),
                              "len": len(b)})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        for part in (b"PO", b"NG"):
            self.wfile.write(b"%x\r\n%s\r\n" % (len(part), part)); self.wfile.flush(); time.sleep(0.05)
        self.wfile.write(b"0\r\n\r\n")
    do_POST = do_GET = handle_any

class Relay(Base):
    """The fake forwarder: extras/cred-relay/Caddyfile's rules, in Python."""
    def handle_any(self):
        b = self.body()
        path = self.path
        if path == "/healthz":
            return self.send(200, raw=b"ok")
        if not path.startswith(PREFIXES):
            return self.send(404, raw=b"")
        hub = http.client.HTTPConnection("127.0.0.1", int(os.environ["CHECK_PORT"]), timeout=10)
        h = {k: v for k, v in self.headers.items()
             if k.lower() not in ("authorization", "cookie", "chatgpt-account-id", "x-api-key", "content-length")}
        h["X-Forwarded-Uri"] = path
        h["X-Forwarded-Method"] = self.command
        hub.request("GET", "/v1/relay/check", headers=h)
        r = hub.getresponse(); rb = r.read()
        if r.status // 100 != 2:
            self.log_row(path, r.status, len(rb))
            return self.send(r.status, raw=rb)
        pre = path.split("/")[1]
        rest = path[len(pre) + 1:]
        if pre == "chatgpt":
            rest = "/backend-api" + rest
        up = http.client.HTTPConnection("127.0.0.1", int(os.environ["UP_PORT"]), timeout=10)
        uh = {k: v for k, v in self.headers.items()
              if k.lower() not in ("x-fleet-relay", "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto",
                                   "x-real-ip", "forwarded", "host")}
        up.request(self.command, rest, body=b, headers=uh)
        ur = up.getresponse()
        self.send_response(ur.status)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        n = 0
        while True:
            c = ur.read1(65536) if hasattr(ur, "read1") else ur.read(65536)
            if not c: break
            n += len(c)
            self.wfile.write(b"%x\r\n%s\r\n" % (len(c), c)); self.wfile.flush()
        self.wfile.write(b"0\r\n\r\n")
        self.log_row(path, ur.status, n)
    def log_row(self, path, status, size):
        with open(os.environ["RELAY_LOG"], "a") as f:
            f.write(json.dumps({"request": {"uri": "/" + path.split("/")[1] + "/"}, "status": status, "size": size}) + "\n")
    do_POST = do_GET = handle_any

cls = {"hub": Hub, "up": Up, "relay": Relay}[mode]
srv = S(("127.0.0.1", 0), cls)
with open(os.path.join(work, mode + ".port"), "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PY

export NODE_TOK VIEWER
# start_fake <name> — in THIS shell (never inside $(…), or its pid is lost to
# the cleanup); its port lands in $WORK/<name>.port.
start_fake() {
  python3 "$WORK/fakes.py" "$WORK" "$1" >/dev/null 2>"$WORK/$1.err" &
  PIDS="$PIDS $!"
  local i=0
  while [ ! -s "$WORK/$1.port" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done   # a CI mac can take seconds
  [ -s "$WORK/$1.port" ] || fail "fake $1 did not start: $(cat "$WORK/$1.err")"
}
start_fake hub; HUB_PORT=$(cat "$WORK/hub.port")
start_fake up; UP_PORT=$(cat "$WORK/up.port")
HUB="http://127.0.0.1:$HUB_PORT"
# The relay's local checker (issue #2048) between the forwarder and the hub, as
# deployed. Its yes-cache is OFF here: E pins that a revoked pass is refused on
# the very next request; the cache and the restart grace are drilled by
# bin/fleet-break-it-cred-selftest.sh (cred-relay-hub-restart).
CHECK_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
FLEET_HUB_URL="$HUB" FLEET_RELAY_CHECK_LISTEN="127.0.0.1:$CHECK_PORT" RELAY_CHECK_CACHE_S=0 \
  FLEET_RELAY_CHECK_LOG="$WORK/check.log" FLEET_RELAY_CHECK_MAX_SECONDS=180 \
  python3 -I "$BIN/../extras/cred-relay/fleet-relay-check.py" 2>"$WORK/check.err" &
PIDS="$PIDS $!"
i=0
until curl -fsS "http://127.0.0.1:$CHECK_PORT/healthz" >/dev/null 2>&1 || [ $i -ge 300 ]; do sleep 0.1; i=$((i + 1)); done
[ $i -lt 300 ] || fail "the relay checker did not start: $(cat "$WORK/check.err")"
export HUB_PORT UP_PORT CHECK_PORT
export RELAY_LOG="$WORK/relay.log"

# A curl that logs its argv, so B can prove no token rides in one.
REAL_CURL=$(command -v curl)
cat > "$WORK/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/curl-argv.log"
exec "$REAL_CURL" "\$@"
EOF
chmod +x "$WORK/curl"

# ---- A. usage -------------------------------------------------------------
for args in '' 'bogus' 'fetch --now' 'check extra' 'revoke' 'revoke bad!name' 'status a b'; do
  # shellcheck disable=SC2086
  "$SUT" $args >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "A: '$args' exit $rc, want 2"; ok
done
[ "$("$SUT" path)" = "$FLEET_CONF_DIR/cred-proxy/relay.token" ] || fail "A: path"; ok

# ---- B. fetch -------------------------------------------------------------
export FLEET_HUB_CURL="$WORK/curl"
"$SUT" fetch >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] || fail "B: module off exit $rc, want 10"; ok
[ ! -s "$WORK/hub.log" ] || fail "B: module off still asked the hub"; ok
export CCQUOTA_FLEET=1 CCQUOTA_HUB_URL="$HUB"
"$SUT" fetch >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'no node token' "$WORK/err" || fail "B: no node token exit $rc: $(cat "$WORK/err")"; ok
printf 'CCQUOTA_TOKEN=%s\nCCQUOTA_HUB_URL=%s\n' "$NODE_TOK" "$HUB" > "$FLEET_CONF_DIR/node.env"
chmod 600 "$FLEET_CONF_DIR/node.env"
out=$("$SUT" fetch 2>"$WORK/err"); rc=$?
[ "$rc" -eq 0 ] || fail "B: fetch exit $rc: $(cat "$WORK/err")"; ok
case "$out" in "relay: ISSUED m4/alice → $FLEET_CONF_DIR/cred-proxy/relay.token") ok ;; *) fail "B: fetch said '$out'" ;; esac
TOKFILE="$FLEET_CONF_DIR/cred-proxy/relay.token"
PASS1=$(cat "$TOKFILE")
case "$PASS1" in frl1.?*) ok ;; *) fail "B: kept pass is not frl1." ;; esac
perm() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
[ "$(perm "$TOKFILE")" = 600 ] || fail "B: pass mode $(perm "$TOKFILE")"; ok
[ "$(perm "$FLEET_CONF_DIR/cred-proxy")" = 700 ] || fail "B: dir mode $(perm "$FLEET_CONF_DIR/cred-proxy")"; ok

# ---- C. keep / check / force ----------------------------------------------
out=$("$SUT" check) || fail "C: check exit $?"
case "$out" in 'relay: OK '*) ok ;; *) fail "C: check said '$out'" ;; esac
mints() { grep -c '"route": "mint"' "$WORK/hub.log"; }
before=$(mints)
out=$("$SUT" fetch) || fail "C: second fetch exit $?"
case "$out" in 'relay: KEPT '*) ok ;; *) fail "C: second fetch said '$out'" ;; esac
[ "$(mints)" = "$before" ] || fail "C: a kept pass was re-minted"; ok
out=$("$SUT" fetch --force) || fail "C: --force exit $?"
case "$out" in 'relay: ISSUED '*) ok ;; *) fail "C: --force said '$out'" ;; esac
PASS=$(cat "$TOKFILE")
[ "$PASS" != "$PASS1" ] || fail "C: --force kept the same pass"; ok

# ---- the relay: real Caddy, or the fake forwarder ----------------------------
CADDY=${FLEET_RELAY_CADDY:-$(command -v caddy 2>/dev/null)}
if [ -n "$CADDY" ] && [ -x "$CADDY" ]; then
  RELAY_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  mkdir -p "$WORK/xdg/data" "$WORK/xdg/config"
  FLEET_RELAY_SITE="http://127.0.0.1:$RELAY_PORT" FLEET_RELAY_CHECK="127.0.0.1:$CHECK_PORT" FLEET_RELAY_LOG="$RELAY_LOG" FLEET_RELAY_ADMIN=off \
    FLEET_RELAY_ANTHROPIC="http://127.0.0.1:$UP_PORT" FLEET_RELAY_CHATGPT="http://127.0.0.1:$UP_PORT" \
    FLEET_RELAY_OPENAI_AUTH="http://127.0.0.1:$UP_PORT" XDG_DATA_HOME="$WORK/xdg/data" XDG_CONFIG_HOME="$WORK/xdg/config" \
    "$CADDY" run --config "$CADDYFILE" --adapter caddyfile >"$WORK/caddy.out" 2>&1 &
  PIDS="$PIDS $!"
  KIND=caddy
  i=0
  until curl -fsS "http://127.0.0.1:$RELAY_PORT/healthz" >/dev/null 2>&1 || [ $i -ge 300 ]; do sleep 0.1; i=$((i + 1)); done
  [ $i -lt 300 ] || fail "caddy did not come up: $(tail -5 "$WORK/caddy.out")"
else
  start_fake relay; RELAY_PORT=$(cat "$WORK/relay.port")
  KIND=fake
fi
RELAY="http://127.0.0.1:$RELAY_PORT"
ups() { [ -f "$WORK/upstream.log" ] && wc -l < "$WORK/upstream.log" | tr -d ' ' || echo 0; }

# through <path> [<pass>] — status + body through the relay, the subscription
# in Authorization (the pass on stdin, like the proxy keeps it out of argv).
through() {
  local pth=$1 pass=${2:-}
  { printf 'Authorization: Bearer %s\n' "$SUB"; [ -n "$pass" ] && printf 'X-Fleet-Relay: %s\n' "$pass"; } |
    curl -sS -N --max-time 10 -o "$WORK/through.body" -w '%{http_code}' -H @- -H 'Content-Type: application/json' \
      --data-binary '{"model":"x","messages":[{"role":"user","content":"ping"}]}' "$RELAY$pth"
}

# ---- D. the relay road ------------------------------------------------------
code=$(through /anthropic/v1/messages "$PASS")
[ "$code" = 200 ] && [ "$(cat "$WORK/through.body")" = PONG ] || fail "D[$KIND]: claude through the relay: $code $(cat "$WORK/through.body")"; ok
row=$(tail -n 1 "$WORK/upstream.log")
python3 - "$row" "$SUB" <<'PY' || fail "D[$KIND]: upstream saw the wrong request: $row"
import json, sys
r = json.loads(sys.argv[1])
assert r["path"] == "/v1/messages", r
assert r["authorization"] == "Bearer " + sys.argv[2], r
assert r["relay"] is None, r
assert r["fwd"] == [], r
assert r["len"] > 0, r
PY
ok
code=$(through /chatgpt/codex/responses "$PASS")
[ "$code" = 200 ] || fail "D[$KIND]: codex through the relay: $code"; ok
grep -q '"path": "/backend-api/codex/responses"' "$WORK/upstream.log" || fail "D[$KIND]: codex path not /backend-api/codex/…"; ok
code=$(through /openai-auth/oauth/token "$PASS")
[ "$code" = 200 ] && grep -q '"path": "/oauth/token"' "$WORK/upstream.log" || fail "D[$KIND]: openai-auth route: $code"; ok
grep '"route": "check"' "$WORK/hub.log" | grep -q '"authorization": true' && fail "D[$KIND]: the hub's check saw an Authorization header"; ok
grep '"route": "check"' "$WORK/hub.log" | grep -q '"uri": "/anthropic/v1/messages"' || fail "D[$KIND]: the check was not told the original path"; ok

# ---- E. refused -------------------------------------------------------------
n=$(ups)
code=$(through /anthropic/v1/messages '')
[ "$code" = 403 ] || fail "E[$KIND]: no pass → $code"; ok
code=$(through /anthropic/v1/messages "frl1.$(printf 'A%.0s' $(seq 1 43))")
[ "$code" = 403 ] || fail "E[$KIND]: forged pass → $code"; ok
code=$(through /anthropic/v1/messages "$PASS1")
[ "$code" = 403 ] || fail "E[$KIND]: replaced pass → $code"; ok
[ "$(ups)" = "$n" ] || fail "E[$KIND]: a refused request reached the upstream"; ok

# ---- F. not an open proxy -----------------------------------------------------
code=$(through /v1/messages "$PASS")
[ "$code" = 404 ] || fail "F[$KIND]: unrouted path → $code"; ok
code=$(through /anthropicx/v1/messages "$PASS")
[ "$code" = 404 ] || fail "F[$KIND]: lookalike prefix → $code"; ok
[ "$(ups)" = "$n" ] || fail "F[$KIND]: an unrouted request reached the upstream"; ok

# ---- H. operator: status, revoke --------------------------------------------
unset CCQUOTA_VIEWER_TOKEN
"$SUT" revoke m4 >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 1 ] && grep -q CCQUOTA_VIEWER_TOKEN "$WORK/err" || fail "H: revoke with no viewer token exit $rc"; ok
export CCQUOTA_VIEWER_TOKEN="$VIEWER"
out=$("$SUT" status) || fail "H: status exit $?"
[ "$out" = 'relay: m4 alice' ] || fail "H: status said '$out'"; ok
out=$("$SUT" revoke M4.local) || fail "H: revoke exit $?"
[ "$out" = 'relay: REVOKED m4' ] || fail "H: revoke said '$out'"; ok
grep -q '"key": "fleet.node_relay.m4"' "$WORK/hub.log" || fail "H: revoke did not PUT fleet.node_relay.m4"; ok
code=$(through /anthropic/v1/messages "$PASS")
[ "$code" = 403 ] || fail "E[$KIND]: revoked pass → $code"; ok
"$SUT" check >"$WORK/out" 2>&1; rc=$?
[ "$rc" -eq 3 ] && grep -q 'relay: REFUSED' "$WORK/out" || fail "E: check of a revoked pass exit $rc: $(cat "$WORK/out")"; ok
touch "$WORK/hub-untrusted"
"$SUT" fetch >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 4 ] && grep -q 'not a trusted machine' "$WORK/err" || fail "E: fetch on an untrusted machine exit $rc: $(cat "$WORK/err")"; ok
[ "$(ups)" = "$n" ] || fail "E[$KIND]: a revoked request reached the upstream"; ok

# ---- G. the relay's log ---------------------------------------------------------
[ -s "$RELAY_LOG" ] || fail "G[$KIND]: no relay log"; ok
grep -q 'FAKESUB' "$RELAY_LOG" && fail "G[$KIND]: the subscription is in the relay log"; ok
grep -q 'frl1\.' "$RELAY_LOG" && fail "G[$KIND]: a pass is in the relay log"; ok
grep -q 'v1/messages\|codex/responses\|oauth/token' "$RELAY_LOG" && fail "G[$KIND]: the relay log has a path past the prefix: $(grep 'v1/messages\|codex/responses\|oauth/token' "$RELAY_LOG" | head -1)"; ok
grep -q '127.0.0.1' "$RELAY_LOG" && fail "G[$KIND]: the relay log has an address"; ok
python3 - "$RELAY_LOG" <<'PY' || fail "G[$KIND]: log rows lack prefix / status / size"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
uris = {r["request"]["uri"] for r in rows}
assert "/anthropic/" in uris and "/chatgpt/" in uris, uris
assert all("status" in r and "size" in r for r in rows), rows
PY
ok

# ---- B (cont.): no token in any argv, the viewer token in no file ---------------
grep -q "$NODE_TOK" "$WORK/curl-argv.log" && fail "B: the node token rode in a curl argv"; ok
grep -q 'frl1\.' "$WORK/curl-argv.log" && fail "B: a pass rode in a curl argv"; ok
grep -q "$VIEWER" "$WORK/curl-argv.log" && fail "H: the viewer token rode in a curl argv"; ok
grep -rq "$VIEWER" "$HOME" "$FLEET_CONF_DIR" 2>/dev/null && fail "H: the viewer token was written to a file"; ok

# ---- I. the machine's own proxy on the relay road --------------------------------
rm -f "$WORK/hub-untrusted" "$TOKFILE"
mkdir -p "$FLEET_CONF_DIR/accounts/a1.hub" "$WORK/codex-homes/a1"
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat-REAL-a1"}}' > "$FLEET_CONF_DIR/accounts/a1.hub/.credentials.json"
printf '{"tokens":{"access_token":"cx-REAL-a1","account_id":"acct-a1"}}' > "$WORK/codex-homes/a1/auth.json"
printf '{"loc":"CN","anthropic":"unreachable","openai":"unreachable","verdict":"blocked"}\n' > "$FLEET_CONF_DIR/node-probe.json"
cat > "$FLEET_CONF_DIR/fleet.conf" <<CONF
FLEET_CRED_PROXY=1
CCQUOTA_FLEET=1
FLEET_CRED_ANTHROPIC_URL=http://127.0.0.1:9/unreachable
FLEET_CRED_CODEX_URL=http://127.0.0.1:9/unreachable
FLEET_CRED_RELAY_URL=$RELAY
FLEET_CRED_CENTRAL_URL=http://127.0.0.1:9/central
FLEET_CRED_CODEX_HOMES=$WORK/codex-homes
FLEET_CRED_PROXY_LOG=$WORK/proxy.log
CONF
unset FLEET_CRED_RELAY_TOKEN FLEET_HUB_CURL
PPORT=$(bash "$BIN/fleet-cred-proxy.sh" ensure --max-seconds 120 2>"$WORK/ensure.err") || fail "I: proxy ensure: $(cat "$WORK/ensure.err")"
[ -s "$TOKFILE" ] || fail "I: ensure minted no relay pass"; ok
r=$(bash "$BIN/fleet-cred-proxy.sh" route)
case "$r" in relay*) ok ;; *) fail "I: the proxy routes '$r', want relay" ;; esac
ST=$(bash "$BIN/fleet-cred-proxy.sh" mint --account a1 --sid s1)
case "$ST" in fcp1.*) ok ;; *) fail "I: session mint '$ST'" ;; esac
viaproxy() { # viaproxy <path> → status; the session's token on stdin
  printf 'Authorization: Bearer %s\n' "$ST" | curl -sS -N --max-time 20 -o "$WORK/proxy.body" -w '%{http_code}' -H @- \
    -H 'Content-Type: application/json' --data-binary '{"model":"m","messages":[{"role":"user","content":"Reply: PONG"}]}' \
    "http://127.0.0.1:$PPORT$1"
}
code=$(viaproxy /v1/messages)
[ "$code" = 200 ] && [ "$(cat "$WORK/proxy.body")" = PONG ] || fail "I[$KIND]: claude via proxy → relay: $code $(cat "$WORK/proxy.body")"; ok
tail -n 1 "$WORK/upstream.log" | grep -q '"path": "/v1/messages", "authorization": "Bearer sk-ant-oat-REAL-a1", "relay": null, "fwd": \[\]' \
  || fail "I[$KIND]: upstream saw $(tail -n 1 "$WORK/upstream.log")"; ok
code=$(viaproxy /codex/responses)
[ "$code" = 200 ] || fail "I[$KIND]: codex via proxy → relay: $code $(cat "$WORK/proxy.body")"; ok
tail -n 1 "$WORK/upstream.log" | grep -q '"path": "/backend-api/codex/responses", "authorization": "Bearer cx-REAL-a1", "relay": null' \
  || fail "I[$KIND]: upstream saw $(tail -n 1 "$WORK/upstream.log")"; ok
grep -q 'frl1\.' "$WORK/proxy.log" && fail "I: the relay pass is in the proxy log"; ok
grep -q 'REAL-a1' "$RELAY_LOG" && fail "I[$KIND]: a subscription is in the relay log"; ok

printf 'fleet-relay-cred selftest: PASS (%d checks, relay=%s)\n' "$CHECKS" "$KIND"
