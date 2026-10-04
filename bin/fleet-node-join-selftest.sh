#!/bin/bash
# fleet-node-join-selftest.sh — bin/fleet-node-join.sh (issue #1418) against a
# fake hub on 127.0.0.1, hermetic: HOME is a sandbox, the hub is a tiny python
# server answering /v1/node/join, /v1/node/dist/<os>-<arch> and /v1/node/self
# the way tokenledger does (compact JSON, X-Ccquota-Sha256), and the "ccquota"
# it serves is a shell stub whose `agent` checks in with the token it was given
# — so "online" here means the agent really started with node.env's settings.
# The agent runs --service detached (never launchd/systemd from a test) and is
# killed by its pid file; the stub also ends itself (exec sleep 20).
#
# What it pins:
#   A. join      a fresh login: exit 0, `online:` line; node.env is 0600 with
#                the hub URL, the token, CCQUOTA_FLEET=1 and CCQUOTA_FLEET_ADMIN=1;
#                ccquota came from the hub; the token is never printed
#   B. rerun     a second run with a NEW code reuses the saved registration and
#                leaves the code unspent (one redemption on the hub)
#   C. refused   a code the hub refuses: exit 1, the "mint a new one" line, no
#                node.env
#   D. sha       a binary whose SHA-256 does not match the header is refused,
#                nothing installed
#   E. format    a malformed code exits 2 before any request reaches the hub
#   F. no-admin  --no-admin writes no CCQUOTA_FLEET_ADMIN line
#   G. kind      a join the hub answers with "kind":"ephemeral" (a SPOT node,
#                issue #1428) writes CCQUOTA_FLEET_NODE_KIND=ephemeral and says
#                so; a fixed join (A) writes no such line
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/fleet-join-st.XXXXXX")"
HUB_PID=""
cleanup() {
  for p in "$SB"/h*/.ccquota/agent.pid; do [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null; done
  [ -n "$HUB_PID" ] && kill "$HUB_PID" 2>/dev/null
  rm -rf "$SB"
}
trap cleanup EXIT
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

command -v python3 >/dev/null || { echo "skip: no python3"; exit 0; }
command -v curl >/dev/null || { echo "skip: no curl"; exit 0; }

# The stub ccquota the hub serves.
cat >"$SB/ccquota" <<EOF
#!/bin/sh
case "\$1" in
  version) echo "ccquota stub" ;;
  agent)
    printf '%s %s\n' "\${CCQUOTA_FLEET:-}" "\${CCQUOTA_FLEET_ADMIN:-}" > "$SB/agent-env"
    curl -fsS -H "Authorization: Bearer \$CCQUOTA_TOKEN" "\$CCQUOTA_HUB_URL/fake/hello" >/dev/null
    exec sleep 20 ;;
esac
EOF
chmod 755 "$SB/ccquota"

cat >"$SB/hub.py" <<'PY'
import hashlib, json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
SB = sys.argv[1]
BIN = open(os.path.join(SB, "ccquota"), "rb").read()
TOKEN = "ccq_testtoken0123456789abcdefXYZ"
state = {"redeemed": 0, "online": False, "requests": 0}
def flag(n): return os.path.exists(os.path.join(SB, n))
def save():
    json.dump(state, open(os.path.join(SB, "state.json"), "w"))
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, obj, headers=None):
        b = json.dumps(obj, separators=(",", ":")).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def authed(self): return self.headers.get("Authorization") == "Bearer " + TOKEN
    def do_POST(self):
        state["requests"] += 1
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/v1/node/join":
            if flag("refuse"):
                save(); return self.reply(401, {"error": "join code is unknown, used or expired"})
            state["redeemed"] += 1; state["last_join"] = body; save()
            return self.reply(200, {"endpoint_id": "ep_1", "label": body["hostname"] + "-" + body["os_user"],
                "token": TOKEN, "hub": "x", "admin": True, "ssh_ca": "ssh-ed25519 AAAA test-ca",
                "dist": ["darwin-arm64", "darwin-amd64", "linux-amd64", "linux-arm64"],
                "kind": "ephemeral" if flag("ephemeral") else "fixed"})
        self.reply(404, {"error": "no"})
    def do_GET(self):
        state["requests"] += 1
        if not self.authed():
            save(); return self.reply(401, {"error": "unrecognised enrollment token"})
        if self.path.startswith("/v1/node/dist/"):
            sha = "0" * 64 if flag("badsha") else hashlib.sha256(BIN).hexdigest()
            self.send_response(200); self.send_header("X-Ccquota-Sha256", sha)
            self.send_header("Content-Length", str(len(BIN))); self.end_headers(); self.wfile.write(BIN)
            save(); return
        if self.path == "/fake/hello":
            state["online"] = True; save(); return self.reply(200, {})
        if self.path == "/v1/node/self":
            save()
            if state["online"]:
                return self.reply(200, {"endpoint_id": "ep_1", "status": "online", "admin": True, "ssh_ca": "trusted"})
            return self.reply(200, {"endpoint_id": "ep_1", "status": "never"})
        self.reply(404, {"error": "no"})
srv = HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(SB, "port"), "w").write(str(srv.server_port))
srv.serve_forever()
PY
python3 "$SB/hub.py" "$SB" & HUB_PID=$!
for _ in $(seq 300); do [ -s "$SB/port" ] && break; sleep 0.1; done
[ -s "$SB/port" ] || { echo "FAIL fake hub never started"; exit 1; }
HUB="http://127.0.0.1:$(cat "$SB/port")"
CODE1=fj_abcdefghijklmnopqrstuvwxyz
CODE2=fj_zyxwvutsrqponmlkjihgfedcba
hubstate() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$SB/state.json" "$1" 2>/dev/null; }

run_join() { # $1 = home dir name, rest = extra args
  local h="$SB/$1"; shift
  mkdir -p "$h"
  HOME="$h" FLEET_CONF_DIR="$h/.config/claude-fleet" FLEET_JOIN_POLL=1 FLEET_JOIN_SUDO="" "$BIN/fleet-node-join.sh" --hub "$HUB" \
    --no-deps --no-fleet --service detached --wait 15 "$@" >"$SB/out" 2>&1
  echo $? > "$SB/rc"
}

# ── A. join ──────────────────────────────────────────────────────────────
run_join h1 --token "$CODE1"
rc=$(cat "$SB/rc")
ENVF="$SB/h1/.config/claude-fleet/node.env"
if [ "$rc" = 0 ] && grep -q '^online: the hub sees this login · admin agent · ssh CA: trusted' "$SB/out"; then ok "A join exits 0 and reports online"; else bad "A join rc=$rc: $(cat "$SB/out")"; fi
mode=$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$ENVF")
[ "$mode" = 600 ] && ok "A node.env is 0600" || bad "A node.env mode $mode"
if grep -qx "CCQUOTA_HUB_URL=$HUB" "$ENVF" && grep -qx 'CCQUOTA_TOKEN=ccq_testtoken0123456789abcdefXYZ' "$ENVF" \
   && grep -qx 'CCQUOTA_FLEET=1' "$ENVF" && grep -qx 'CCQUOTA_FLEET_ADMIN=1' "$ENVF"; then
  ok "A node.env carries hub, token, fleet + admin"
else bad "A node.env: $(cat "$ENVF")"; fi
grep -q NODE_KIND "$ENVF" && bad "A a fixed join wrote a node kind: $(grep NODE_KIND "$ENVF")" || ok "A a fixed join writes no node kind"
[ "$(cat "$SB/agent-env" 2>/dev/null)" = "1 1" ] && ok "A the agent started with node.env's settings" || bad "A agent env: $(cat "$SB/agent-env" 2>/dev/null)"
cmp -s "$SB/ccquota" "$SB/h1/.local/bin/ccquota" && grep -q '^agent: ccquota-.* from the hub (sha256 ' "$SB/out" \
  && ok "A ccquota installed from the hub, hash checked" || bad "A ccquota not from the hub: $(grep '^agent:' "$SB/out")"
grep -q ccq_testtoken "$SB/out" && bad "A the token was printed" || ok "A the token is never printed"
[ "$(hubstate redeemed)" = 1 ] && ok "A one redemption" || bad "A redemptions: $(hubstate redeemed)"
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]))["last_join"];sys.exit(0 if d["code"]==sys.argv[2] and d["os_user"] else 1)' "$SB/state.json" "$CODE1" \
  && ok "A join sent the code, hostname and login" || bad "A join body: $(hubstate last_join)"

# ── B. rerun ─────────────────────────────────────────────────────────────
kill "$(cat "$SB/h1/.ccquota/agent.pid")" 2>/dev/null
run_join h1 --token "$CODE2"
rc=$(cat "$SB/rc")
if [ "$rc" = 0 ] && grep -q '^join: already registered' "$SB/out" && [ "$(hubstate redeemed)" = 1 ]; then
  ok "B rerun reuses the registration, code unspent"
else bad "B rerun rc=$rc redeemed=$(hubstate redeemed): $(cat "$SB/out")"; fi

# ── C. refused ───────────────────────────────────────────────────────────
touch "$SB/refuse"
run_join h2 --token "$CODE1"
rc=$(cat "$SB/rc")
if [ "$rc" = 1 ] && grep -q 'refused the code.*Mint a new one' "$SB/out" && [ ! -e "$SB/h2/.config/claude-fleet/node.env" ]; then
  ok "C a refused code exits 1, writes nothing"
else bad "C rc=$rc: $(cat "$SB/out")"; fi
rm -f "$SB/refuse"

# ── D. sha ───────────────────────────────────────────────────────────────
touch "$SB/badsha"
run_join h3 --token "$CODE1"
rc=$(cat "$SB/rc")
if [ "$rc" = 1 ] && grep -q 'did not match its SHA-256' "$SB/out" && [ ! -e "$SB/h3/.local/bin/ccquota" ]; then
  ok "D a hash mismatch is refused, nothing installed"
else bad "D rc=$rc: $(cat "$SB/out")"; fi
rm -f "$SB/badsha"

# ── E. format ────────────────────────────────────────────────────────────
before=$(hubstate requests)
run_join h4 --token "fj_TOO-short"
rc=$(cat "$SB/rc")
if [ "$rc" = 2 ] && [ "$(hubstate requests)" = "$before" ]; then ok "E a malformed code exits 2, no request"; else bad "E rc=$rc: $(cat "$SB/out")"; fi

# ── F. no-admin ──────────────────────────────────────────────────────────
run_join h5 --token "$CODE1" --no-admin
if [ "$(cat "$SB/rc")" = 0 ] && ! grep -q ADMIN "$SB/h5/.config/claude-fleet/node.env"; then
  ok "F --no-admin writes no admin line"
else bad "F rc=$(cat "$SB/rc"): $(cat "$SB/h5/.config/claude-fleet/node.env" 2>/dev/null)"; fi

# ── G. kind ──────────────────────────────────────────────────────────────
touch "$SB/ephemeral"
run_join h6 --token "$CODE1"
if [ "$(cat "$SB/rc")" = 0 ] && grep -qx 'CCQUOTA_FLEET_NODE_KIND=ephemeral' "$SB/h6/.config/claude-fleet/node.env" \
   && grep -q 'SPOT node (ephemeral)' "$SB/out"; then
  ok "G an ephemeral join writes CCQUOTA_FLEET_NODE_KIND=ephemeral and says so"
else bad "G rc=$(cat "$SB/rc"): $(cat "$SB/h6/.config/claude-fleet/node.env" 2>/dev/null; grep join: "$SB/out")"; fi
# A rerun keeps the kind: load_env reads it back before write_env rewrites.
rm -f "$SB/ephemeral"
run_join h6 --token "$CODE2"
if [ "$(cat "$SB/rc")" = 0 ] && grep -qx 'CCQUOTA_FLEET_NODE_KIND=ephemeral' "$SB/h6/.config/claude-fleet/node.env"; then
  ok "G a rerun keeps the saved kind"
else bad "G rerun rc=$(cat "$SB/rc"): $(cat "$SB/h6/.config/claude-fleet/node.env" 2>/dev/null)"; fi

[ "$fail" = 0 ] && echo "PASS fleet-node-join-selftest" || echo "FAIL fleet-node-join-selftest"
exit "$fail"
