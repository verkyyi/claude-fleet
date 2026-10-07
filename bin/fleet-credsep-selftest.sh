#!/usr/bin/env bash
# fleet-credsep-selftest.sh — separated credentials (issue #1971, EPIC #1967 C4),
# in a sandbox: bin/fleet-credsep.sh + fleet-credsep.py + fleet-credsep-launch.py
# + fleet-cred-proxy.py, with every root path moved under a temp dir
# (FLEET_CREDSEP_* seams), no sudo, the role account played by this user and no
# launchctl / systemctl run. The OS half — a real role account, and a session
# that gets "Permission denied" — is the issue's on-machine evidence, not this.
#
#   A  FLEET_CRED_SEPARATE=0: apply does nothing, every file byte for byte
#   B  install: leased credentials, hub-managed Codex auth.json and node.env
#      move into the store (same bytes); a personal Codex login stays; node.env
#      becomes a symlink, node.pub.env holds no token; the agent's service now
#      starts the launcher, its agent argv comes from run-agent.sh
#   C  the launcher starts the proxy against the store: a minted session reads
#      the moved credential; `store` (the agent's lease) lands in the store
#   D  the hub broker: fcpn1. → the real node token on the way out; POST
#      /v1/node/credentials (any spelling) refused before the hub sees it; no
#      credential → 401; node-hash = sha256(token); fleet-lib's
#      _fleet_node_env_val / _fleet_hub_env hand a session the broker pair
#   E  the ctl socket answers ONE peer uid (another uid is refused)
#   F  the launcher's agent mode: the token arrives on fd 3, never in the env
#   G  uninstall: every file back where it was, byte for byte; the store, the
#      record and the service changes gone
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
SB=$(mktemp -d "/tmp/credsep-st.XXXXXX")
ME=$(id -un)
cleanup() {
  kill "$(cat "$SB/run/$ME/pid" 2>/dev/null)" 2>/dev/null
  [ -n "${LPID:-}" ] && kill "$LPID" 2>/dev/null
  [ -n "${P2:-}" ] && kill "$P2" 2>/dev/null
  kill "$(cat "$SB/fake.pid" 2>/dev/null)" 2>/dev/null
  rm -rf "$SB"
}
trap cleanup EXIT
export HOME="$SB/home" FLEET_CONF_DIR="$SB/home/.config/claude-fleet" XDG_CONFIG_HOME="$SB/home/.config"
export FLEET_CREDSEP_ROOT_BASE="$SB/db" FLEET_CREDSEP_RUN_BASE="$SB/run" FLEET_CREDSEP_LOG_BASE="$SB/log" \
       FLEET_CREDSEP_LIB="$SB/lib" FLEET_CREDSEP_DAEMON_DIR="$SB/daemons" FLEET_CREDSEP_ROLE="$ME" \
       FLEET_CREDSEP_SVC=0 FLEET_CREDSEP_TEST=1 FLEET_CREDSEP_SUDO=''
unset CCQUOTA_TOKEN CCQUOTA_HUB_URL FLEET_HUB_URL FLEET_CRED_SEPARATE
C=$FLEET_CONF_DIR R="$SB/db/$ME"
mkdir -p "$C/accounts/main.hub" "$HOME/.codex" "$HOME/.codex-accounts/work" "$HOME/.codex-accounts/mine" \
         "$HOME/.ccquota" "$SB/daemons"

FAIL=0
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; FAIL=1; }

# ── the login as a node leaves it today ────────────────────────────────────────
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-MAIN","refreshToken":null,"expiresAt":4102444800000,"scopes":["user:inference"]}}' \
  > "$C/accounts/main.hub/.credentials.json"
printf 'hub:main\n' > "$C/accounts/main"
printf '{"tokens":{"access_token":"at-DEFAULT","refresh_token":"hub-managed","account_id":"acct-d"}}' > "$HOME/.codex/auth.json"
printf '{"tokens":{"access_token":"at-WORK","refresh_token":"hub-managed","account_id":"acct-w"}}' > "$HOME/.codex-accounts/work/auth.json"
printf '{"tokens":{"access_token":"at-MINE","refresh_token":"rt-personal","account_id":"acct-m"}}' > "$HOME/.codex-accounts/mine/auth.json"
cat > "$C/node.env" <<'EOF'
# claude-fleet node-join (issue #1418) — this login's ccquota agent. Holds a credential: 0600.
CCQUOTA_HUB_URL=http://127.0.0.1:1
CCQUOTA_TOKEN=ccq_NODE_SECRET_0123
CCQUOTA_FLEET=1
CCQUOTA_FLEET_CREDS=1
EOF
chmod 600 "$C"/node.env "$C/accounts/main.hub/.credentials.json"
cat > "$HOME/.ccquota/run-agent.sh" <<EOF
#!/bin/sh
PATH="/usr/bin:/bin"
export PATH
set -a
. "$C/node.env"
set +a
cd "\$HOME" || exit 1
exec "$SB/fake-agent" agent --state "$HOME/.ccquota"
EOF
if [ "$(uname)" = Darwin ]; then
  AGENT_DEF="$SB/daemons/com.ccquota.agent.$ME.plist"
  python3 - "$AGENT_DEF" "$HOME/.ccquota/run-agent.sh" "$ME" <<'PY'
import plistlib, sys
plistlib.dump({"Label": "com.ccquota.agent." + sys.argv[3], "ProgramArguments": [sys.argv[2]],
               "RunAtLoad": True, "KeepAlive": True, "UserName": sys.argv[3]}, open(sys.argv[1], "wb"))
PY
else
  AGENT_DEF="$SB/daemons/ccquota-agent-$ME.service"
  printf '[Service]\nUser=%s\nExecStart=%s\n' "$ME" "$HOME/.ccquota/run-agent.sh" > "$AGENT_DEF"
fi
# the "agent": proves where its token came from
cat > "$SB/fake-agent" <<'EOF'
#!/bin/sh
{ printf 'fd3=%s\n' "$(head -n 1 <&3 2>/dev/null)"; env | grep -c ccq_NODE_SECRET | sed 's/^/envhits=/'
  printf 'store=%s\n' "$CCQUOTA_FLEET_CRED_STORE"; printf 'args=%s\n' "$*"; } > "$HOME/agent.out"
EOF
chmod +x "$SB/fake-agent"

snap() { # every file under the login's tree + the service dir: path, kind, bytes
  (cd "$SB" && find home daemons -path home/Library -prune -o \( -type f -o -type l \) -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
     if [ -L "$f" ]; then printf '%s L %s\n' "$f" "$(readlink "$f")"
     else printf '%s F %s\n' "$f" "$(cksum < "$f" | tr -s ' ' ' ')"; fi
   done)
}
BEFORE=$(snap)

# ── A: off ⇒ nothing ───────────────────────────────────────────────────────────
out=$(FLEET_CRED_SEPARATE=0 bash "$BIN/fleet-credsep.sh" apply 2>&1)
if [ "$out" = "credsep: skip — off (FLEET_CRED_SEPARATE=0)" ] && [ "$(snap)" = "$BEFORE" ] && [ ! -e "$SB/db" ]; then
  pass "A off: apply skips, every file byte for byte, no store"
else fail "A off: '$out'"; fi
out=$(FLEET_CRED_SEPARATE=0 bash "$BIN/fleet-credsep.sh" check 2>&1)
case "$out" in "credsep: INFO — off"*) pass "A off: check is INFO off (the doctor prints no row)" ;; *) fail "A check: $out" ;; esac

# ── B: install ─────────────────────────────────────────────────────────────────
out=$(FLEET_CRED_SEPARATE=1 bash "$BIN/fleet-credsep.sh" apply 2>&1); rc=$?
[ "$rc" = 0 ] && case "$out" in "credsep: ok — credsep: ON"*) true ;; *) false ;; esac \
  && pass "B install via apply: $out" || fail "B apply rc=$rc: $out"
same() { [ -f "$2" ] && [ "$(cksum < "$2")" = "$1" ]; }
ck() { cksum < "$1"; }
[ ! -e "$C/accounts/main.hub/.credentials.json" ] && grep -q sk-ant-oat01-MAIN "$R/accounts/main.hub/.credentials.json" \
  && pass "B claude credential moved into the store" || fail "B claude credential"
[ "$(cat "$C/accounts/main")" = "hub:main" ] && pass "B the label marker (no credential) stays" || fail "B marker"
[ ! -e "$HOME/.codex/auth.json" ] && grep -q at-DEFAULT "$R/codex/default/auth.json" \
  && [ ! -e "$HOME/.codex-accounts/work/auth.json" ] && grep -q at-WORK "$R/codex/work/auth.json" \
  && pass "B hub-managed codex auth.json moved (default + work)" || fail "B codex"
grep -q at-MINE "$HOME/.codex-accounts/mine/auth.json" && [ ! -e "$R/codex/mine" ] \
  && pass "B a personal codex login (own refresh token) stays put" || fail "B personal codex moved"
[ -L "$C/node.env" ] && [ "$(readlink "$C/node.env")" = "$R/node.env" ] && grep -q ccq_NODE_SECRET "$R/node.env" \
  && pass "B node.env → symlink into the store" || fail "B node.env"
grep -q '^CCQUOTA_HUB_URL=' "$C/node.pub.env" && ! grep -q TOKEN "$C/node.pub.env" \
  && pass "B node.pub.env: the token-less lines" || fail "B node.pub.env: $(cat "$C/node.pub.env")"
[ -f "$C/credsep.json" ] && [ -f "$SB/lib/fleet-credsep-launch.py" ] && [ -f "$SB/lib/fleet-cred-proxy.py" ] \
  && pass "B record + the code copy" || fail "B record/lib"
python3 - "$R/meta.json" "$SB/fake-agent" <<'PY' && pass "B meta: agent argv from run-agent.sh" || fail "B meta"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["agent_argv"][0] == sys.argv[2] and m["agent_argv"][1] == "agent", m
assert m["path"] == "/usr/bin:/bin", m
PY
if grep -q "^ExecStart=.*fleet-credsep-launch.py.* agent $ME\$" "$AGENT_DEF.d/credsep.conf" 2>/dev/null \
     && grep -q '^User=root$' "$AGENT_DEF.d/credsep.conf" \
   || python3 -c 'import plistlib,sys; p=plistlib.load(open(sys.argv[1],"rb")); sys.exit(0 if "UserName" not in p and p["ProgramArguments"][-2:]==["agent",sys.argv[2]] else 1)' "$AGENT_DEF" "$ME" 2>/dev/null; then
  pass "B the agent's service starts the launcher (root, no UserName)"
else fail "B agent service: $(cat "$AGENT_DEF" "$AGENT_DEF.d/credsep.conf" 2>/dev/null | head -20)"; fi
{ [ -e "$SB/daemons/com.claude-fleet.credsep.$ME.plist" ] || [ -e "$SB/daemons/claude-fleet-credsep-$ME.service" ]; } && pass "B the proxy service is written" || fail "B proxy service"
out=$(FLEET_CRED_SEPARATE=1 bash "$BIN/fleet-credsep.sh" apply 2>&1)
case "$out" in *"credsep: ON"*) pass "B apply again: idempotent" ;; *) fail "B re-apply: $out" ;; esac
grep -q at-DEFAULT "$R/codex/default/auth.json" && [ -L "$C/node.env" ] && pass "B re-apply moved nothing twice" || fail "B re-apply damage"

# ── C: the proxy, started by the launcher ──────────────────────────────────────
cat > "$SB/fake.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
SB = sys.argv[1]
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def any(self):
        n = int(self.headers.get("content-length") or 0)
        if n: self.rfile.read(n)
        with open(SB + "/fake.log", "a") as f:
            f.write("%s %s auth=%s\n" % (self.command, self.path, self.headers.get("authorization", "")))
        b = json.dumps({"trust": "trusted"} if self.path.endswith("/v1/node/self") else {"ok": True}).encode()
        self.send_response(200); self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    do_GET = do_POST = any
s = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(SB + "/fake.port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 "$SB/fake.py" "$SB" & echo $! > "$SB/fake.pid"
for _ in $(seq 1 50); do [ -s "$SB/fake.port" ] && break; sleep 0.1; done
FP=$(cat "$SB/fake.port")
sed -i.bak "s#^CCQUOTA_HUB_URL=.*#CCQUOTA_HUB_URL=http://127.0.0.1:$FP#" "$R/node.env" && rm -f "$R/node.env.bak"
printf 'FLEET_CRED_ANTHROPIC_URL=http://127.0.0.1:%s\nFLEET_CRED_CODEX_URL=http://127.0.0.1:%s/codex\n' "$FP" "$FP" >> "$C/fleet.conf"
python3 -I "$BIN/fleet-credsep-launch.py" proxy "$ME" 2>"$SB/launch.err" &
LPID=$!
for _ in $(seq 1 100); do [ -S "$SB/run/$ME/ctl.sock" ] && [ -s "$SB/run/$ME/port" ] && break; sleep 0.1; done
PORT=$(cat "$SB/run/$ME/port" 2>/dev/null)
[ -n "$PORT" ] && pass "C the launcher started the proxy (127.0.0.1:$PORT, run dir)" \
  || { fail "C proxy did not start: $(cat "$SB/launch.err")"; }
m=$(ls -l "$SB/run/$ME/ctl.sock" 2>/dev/null | cut -c1-10)
[ "$m" = srw-rw-rw- ] && pass "C ctl.sock 0666 (the peer-uid gate decides)" || fail "C ctl.sock mode $m"
m=$(ls -l "$SB/run/$ME/port" 2>/dev/null | cut -c1-10)
[ "$m" = -rw-r--r-- ] && pass "C port 0644 (the login is another uid)" || fail "C port mode $m"
[ "$(bash "$BIN/fleet-cred-proxy.sh" port 2>&1)" = "$PORT" ] && pass "C fleet-cred-proxy.sh port reads the run dir" \
  || fail "C port: $(bash "$BIN/fleet-cred-proxy.sh" port 2>&1)"
tok=$(bash "$BIN/fleet-cred-proxy.sh" mint --account main --sid s1 2>&1)
curl -s -o /dev/null -H "Authorization: Bearer $tok" -H 'content-type: application/json' -d '{}' "http://127.0.0.1:$PORT/v1/messages"
grep -q "POST /v1/messages auth=Bearer sk-ant-oat01-MAIN" "$SB/fake.log" \
  && pass "C a session's request carries the credential from the store" || fail "C direct: $(tail -3 "$SB/fake.log")"
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-RENEWED"}}' | bash "$BIN/fleet-cred-proxy.sh" store --kind claude --label main
grep -q RENEWED "$R/accounts/main.hub/.credentials.json" && [ ! -e "$C/accounts/main.hub/.credentials.json" ] \
  && pass "C store: the agent's lease lands in the store, not the login" || fail "C store"
printf 'x' | bash "$BIN/fleet-cred-proxy.sh" store --kind claude --label ../evil 2>/dev/null \
  && fail "C store accepted ../evil" || pass "C store refuses a path-like label"

# ── D: the hub broker ─────────────────────────────────────────────────────────
pair=$(bash "$BIN/fleet-cred-proxy.sh" node-token 2>&1)
burl=${pair%%	*} btok=${pair#*	}
case "$btok" in fcpn1.*) pass "D node-token: $burl + fcpn1." ;; *) fail "D node-token: $pair" ;; esac
: > "$SB/fake.log"
curl -s -o /dev/null -H "Authorization: Bearer $btok" "$burl/v1/node/self"
grep -q "GET /v1/node/self auth=Bearer ccq_NODE_SECRET_0123" "$SB/fake.log" \
  && pass "D broker: the node token is put in on the way out" || fail "D broker fwd: $(cat "$SB/fake.log")"
: > "$SB/fake.log"
for p in /v1/node/credentials /v1/node/credentials/ //v1/node/credentials /v1/node/./credentials /v1/node/%63redentials /V1/NODE/CREDENTIALS; do
  c=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $btok" "$burl$p")
  [ "$c" = 403 ] || { fail "D broker let $p through ($c)"; }
done
[ ! -s "$SB/fake.log" ] && pass "D broker: /v1/node/credentials refused in every spelling, the hub never asked" \
  || fail "D the hub saw: $(cat "$SB/fake.log")"
c=$(curl -s -o /dev/null -w '%{http_code}' "$burl/v1/node/self")
[ "$c" = 401 ] && pass "D broker: no credential → 401" || fail "D no cred → $c"
c=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $tok" "$burl/v1/node/self")
[ "$c" = 401 ] && pass "D broker: a session credential (fcp1.) is not a node credential" || fail "D fcp1 → $c"
want=$(printf 'ccq_NODE_SECRET_0123' | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')
[ "$(bash "$BIN/fleet-cred-proxy.sh" node-hash)" = "$want" ] && pass "D node-hash = sha256(node token)" || fail "D node-hash"
# a session's view: node.env unreadable (here: a dangling link) + the record
S="$SB/session-conf"; mkdir -p "$S"; ln -s "$SB/nowhere/node.env" "$S/node.env"
cp "$C/credsep.json" "$C/node.pub.env" "$S/"
v=$(FLEET_CONF_DIR="$S" bash -c ". '$BIN/fleet-lib.sh'; _fleet_node_env_val CCQUOTA_TOKEN")
case "$v" in fcpn1.*) pass "D fleet-lib: _fleet_node_env_val CCQUOTA_TOKEN → the broker's credential" ;; *) fail "D lib token: '$v'" ;; esac
v=$(FLEET_CONF_DIR="$S" bash -c ". '$BIN/fleet-lib.sh'; _fleet_node_env_val CCQUOTA_FLEET")
[ "$v" = 1 ] && pass "D fleet-lib: other keys from node.pub.env" || fail "D lib key: '$v'"
v=$(FLEET_CONF_DIR="$S" bash -c ". '$BIN/fleet-lib.sh'; _fleet_hub_env; printf '%s %s' \"\$CCQUOTA_HUB_URL\" \"\${CCQUOTA_TOKEN%%.*}\"")
[ "$v" = "$burl fcpn1" ] && pass "D fleet-lib: _fleet_hub_env exports the broker PAIR" || fail "D hub_env: '$v'"

# ── E: one peer uid ──────────────────────────────────────────────────────────────
mkdir -p "$SB/e/state" "$SB/e/run"
FLEET_CONF_DIR="$SB/e" FLEET_CRED_CTL_DIR="$SB/e/run" FLEET_CRED_CTL_UID=99999 FLEET_CRED_PROXY_LOG="$SB/e/log" \
  python3 -I "$BIN/fleet-cred-proxy.py" --state "$SB/e/state" serve --max-seconds 30 2>/dev/null &
P2=$!
for _ in $(seq 1 100); do [ -S "$SB/e/run/ctl.sock" ] && break; sleep 0.1; done
out=$(FLEET_CRED_CTL_DIR="$SB/e/run" python3 -I "$BIN/fleet-cred-proxy.py" --state "$SB/e/state" status 2>&1); rc=$?
[ "$rc" != 0 ] && case "$out" in *"not this login"*) true ;; *) false ;; esac \
  && pass "E ctl refuses a peer that is not the login's uid" || fail "E ctl answered uid $(id -u): $out"
kill "$P2" 2>/dev/null; P2=''

# ── F: the agent's launch ────────────────────────────────────────────────────────
python3 -I "$BIN/fleet-credsep-launch.py" agent "$ME" 2>"$SB/agent.err"
grep -q '^fd3=ccq_NODE_SECRET_0123$' "$HOME/agent.out" && grep -q '^envhits=0$' "$HOME/agent.out" \
  && grep -q "^store=$SB/run/$ME/ctl.sock$" "$HOME/agent.out" \
  && pass "F agent: token on fd 3, not in its environment; the store socket handed over" \
  || fail "F agent: $(cat "$HOME/agent.out" "$SB/agent.err" 2>/dev/null)"
rm -f "$HOME/agent.out"

# ── G: uninstall ───────────────────────────────────────────────────────────────
kill "$(cat "$SB/run/$ME/pid" 2>/dev/null)" 2>/dev/null; kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null; LPID=''
# the renewal C stored goes back too; put the original bytes back in the store
# so the before/after comparison is exact
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-MAIN","refreshToken":null,"expiresAt":4102444800000,"scopes":["user:inference"]}}' \
  > "$R/accounts/main.hub/.credentials.json"
sed -i.bak "s#^CCQUOTA_HUB_URL=.*#CCQUOTA_HUB_URL=http://127.0.0.1:1#" "$R/node.env" && rm -f "$R/node.env.bak"
rm -f "$C/fleet.conf"
out=$(FLEET_CRED_SEPARATE=0 bash "$BIN/fleet-credsep.sh" apply 2>&1); rc=$?
case "$rc:$out" in "0:credsep: ok — credsep: OFF"*) pass "G uninstall via apply: $out" ;; *) fail "G rc=$rc: $out" ;; esac
AFTER=$(snap)
if [ "$AFTER" = "$BEFORE" ]; then pass "G every file back where it was, byte for byte (and the service definition)"
else fail "G differs:"; diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"); fi
[ ! -e "$R" ] && [ ! -e "$C/credsep.json" ] && [ ! -e "$SB/lib" ] && [ ! -e "$SB/daemons/com.claude-fleet.credsep.$ME.plist" ] \
  && [ ! -e "$SB/daemons/claude-fleet-credsep-$ME.service" ] \
  && pass "G the store, the record, the code copy and the proxy service are gone" || fail "G leftovers: $(ls "$SB/db" "$SB/daemons" 2>&1)"

[ "$FAIL" = 0 ] && echo "fleet-credsep selftest PASS" || { echo "fleet-credsep selftest FAIL"; exit 1; }
