#!/usr/bin/env bash
# fleet-cred-hub-moved-selftest.sh — the machine's shared credential proxy
# follows a moved hub (2026-10-26). PR #5471 (task PNWW) rewrote every login's
# root-owned node.env (bin/fleet-hub-move.py rewrite --scope machine) to the new
# hub's https address; a shared proxy started before that computed its
# allow-list (ALLOWED) once at start and refused every /hub/v1/… call with 403
# «hub URL is neither https nor loopback» — so `fleet_repo_authority_guard` failed
# every session start on that node until the proxy was restarted by hand.
#
# A sandbox (the FLEET_CREDSEP_* seams of fleet-cred-shared-selftest.sh: every
# root path under a temp dir, no sudo, no launchctl) with one login, alpha, a
# tenant of the shared proxy (bin/fleet-credsep.sh machine install +
# bin/fleet-credsep-launch.py shared + bin/fleet-cred-proxy.py serve --shared),
# whose store's node.env names https://old-hub.example. The hub is a fake
# forwarder on a unix socket (CCQUOTA_HUB_SOCK, the broker's warm road — plain
# HTTP there, X-Fleet-Hub names the hub), so an https name needs no TLS.
#
#   A  the hub as joined: /hub/v1/node/self is forwarded to old-hub.example
#   B  bin/fleet-hub-move.py rewrite --scope machine moves the store's node.env to
#      https://new-hub.example; the SAME proxy process (no restart: no machine
#      daemon here, the reload is only printed) forwards the next call there
#   C  a node.env nobody but root / the proxy may write is the only one followed:
#      group-writable, its new host is NOT added — the 403 says «https, but its host
#      … is not on this proxy's allow-list (allowed: …)», never «neither https nor
#      loopback»; made 0600 again, the next call follows it
#   D  the old hosts stay allowed for the process's life (only ever added)
#   E  the repo-authority guard's words for the proxy's refusal say what to do
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
SB=$(mktemp -d "/tmp/hubmv-st.XXXXXX")
ME=$(id -un); MYUID=$(id -u); MYGID=$(id -g)
cleanup() {
  kill "$(cat "$SB/fwd.pid" 2>/dev/null)" 2>/dev/null
  kill "$(cat "$SB/run/.shared/pid" 2>/dev/null)" 2>/dev/null
  rm -rf "$SB"
}
trap cleanup EXIT
export FLEET_CREDSEP_ROOT_BASE="$SB/db" FLEET_CREDSEP_RUN_BASE="$SB/run" FLEET_CREDSEP_LOG_BASE="$SB/log" \
       FLEET_CREDSEP_LIB="$SB/lib" FLEET_CREDSEP_DAEMON_DIR="$SB/daemons" FLEET_CREDSEP_ROLE="$ME" \
       FLEET_CREDSEP_SVC=0 FLEET_CREDSEP_TEST=1 FLEET_CREDSEP_PREFLIGHT=0 FLEET_CREDSEP_SUDO='' \
       FLEET_CREDSEP_PW="$SB/pw" FLEET_CREDSEP_USERS="$SB/users" FLEET_CREDSEP_HOMES="$SB/homes" \
       FLEET_NODE_STATE="$SB/node"   # never this machine's own daemon state
unset CCQUOTA_TOKEN CCQUOTA_HUB_URL FLEET_HUB_URL FLEET_CRED_SEPARATE FLEET_CRED_PROXY FLEET_CRED_AS FLEET_HUB_INTERNAL_URL
FAIL=0
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; FAIL=1; }
freeport() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
export FLEET_CRED_SHARED_PORT; FLEET_CRED_SHARED_PORT=$(freeport)
P1=$(freeport) P2=$(freeport)   # nothing listens: no provider call is made here
export FLEET_CRED_ANTHROPIC_URL="http://127.0.0.1:$P1" FLEET_CRED_CODEX_URL="http://127.0.0.1:$P2/codex"
OLD=https://old-hub.example NEW=https://new-hub.example
mkdir -p "$SB/daemons" "$SB/node"

# ── the hub: a fake forwarder on a unix socket, logging the hub each call names ──
cat > "$SB/fwd.py" <<'PY'
import json, os, socket, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        with open(sys.argv[2], "a") as f:
            f.write("%s %s %s\n" % (self.path, self.headers.get("X-Fleet-Hub", "-"), self.headers.get("Authorization", "-")))
        b = json.dumps({"endpoint_id": "e1"}).encode()
        self.send_response(200); self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
class U(ThreadingHTTPServer):
    address_family = socket.AF_UNIX
    def server_bind(self): self.socket.bind(self.server_address)
    def get_request(self):
        r, _ = self.socket.accept(); return r, ("unix", 0)
U(sys.argv[1], H).serve_forever()
PY
python3 "$SB/fwd.py" "$SB/hub.sock" "$SB/fwd.log" 2>"$SB/fwd.err" & echo $! > "$SB/fwd.pid"
for _ in $(seq 1 100); do [ -S "$SB/hub.sock" ] && break; sleep 0.1; done
[ -S "$SB/hub.sock" ] || { echo "FAIL the fake forwarder did not start: $(cat "$SB/fwd.err")"; exit 1; }
export CCQUOTA_HUB_SOCK="$SB/hub.sock"

# ── one login, a tenant of the shared proxy, joined to the OLD hub ─────────────
printf 'alpha:%s:%s:%s\n' "$MYUID" "$MYGID" "$SB/homes/alpha" > "$SB/pw"
printf 'alpha:%s\n' "$SB/homes/alpha" > "$SB/users"
H="$SB/homes/alpha"; CA="$H/.config/claude-fleet"
mkdir -p "$CA/accounts/main.hub" "$H/.claude/fleet/bin"
: > "$H/.claude/fleet/bin/fleet-credsep.sh"
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-alpha","refreshToken":null,"expiresAt":4102444800000}}' \
  > "$CA/accounts/main.hub/.credentials.json"
printf 'hub:main\n' > "$CA/accounts/main"
printf '# claude-fleet\n# ---- [common] ----\nexport FLEET_HOST=1\n' > "$CA/fleet.conf"
printf 'CCQUOTA_HUB_URL=%s\nCCQUOTA_TOKEN=ccq_NODE_alpha_0123\nCCQUOTA_FLEET=1\n' "$OLD" > "$CA/node.env"
chmod 600 "$CA/node.env"
out=$(bash "$BIN/fleet-credsep.sh" machine install --logins alpha 2>&1) \
  || { echo "FAIL machine install: $(printf '%s' "$out" | tail -3)"; exit 1; }
STORE="$SB/db/alpha/node.env"
grep -qx "CCQUOTA_HUB_URL=$OLD" "$STORE" || { echo "FAIL the store's node.env: $(cat "$STORE" 2>&1)"; exit 1; }
python3 -I "$SB/lib/fleet-credsep-launch.py" shared 2>>"$SB/launch.err" &
for _ in $(seq 1 300); do [ -S "$SB/run/.shared/ctl.sock" ] && [ -s "$SB/run/.shared/pid" ] && break; sleep 0.1; done
[ -S "$SB/run/.shared/ctl.sock" ] || { echo "FAIL the shared proxy did not start: $(tail -3 "$SB/launch.err")"; exit 1; }
PID=$(cat "$SB/run/.shared/pid")

pair=$(FLEET_CONF_DIR="$CA" python3 -I "$BIN/fleet_cred_ctl.py" node-token 2>&1)
BURL=${pair%%	*} BTOK=${pair#*	}
case "$BTOK" in fcpn1.*) pass "node-token: the broker pair" ;; *) echo "FAIL node-token: $pair"; exit 1 ;; esac
call() { # → the HTTP status; the body in $SB/body
  curl -s --max-time 30 -o "$SB/body" -w '%{http_code}' -H "Authorization: Bearer $BTOK" "$BURL/v1/node/self"
}
hub_seen() { tail -n 1 "$SB/fwd.log" 2>/dev/null | cut -d' ' -f2; }

# ── A: the hub as joined ────────────────────────────────────────────────────
c=$(call)
[ "$c" = 200 ] && [ "$(hub_seen)" = "$OLD" ] && pass "A the hub as joined: forwarded to $OLD" \
  || fail "A HTTP $c $(cat "$SB/body") · forwarder saw: $(tail -n 1 "$SB/fwd.log" 2>/dev/null)"
tail -n 1 "$SB/fwd.log" 2>/dev/null | grep -q ' Bearer ccq_NODE_alpha_0123$' \
  && pass "A the node token is put in on the way out" || fail "A no node token on the forwarded call"

# ── B: the hub moves (the one writer rewrites the store), the proxy follows ───
out=$(python3 -I "$BIN/fleet-hub-move.py" rewrite --scope machine --from "$OLD" --to "$NEW" \
  --state "$SB/nstate" --cred-base "$SB/db" 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qx "CCQUOTA_HUB_URL=$NEW" "$STORE" && grep -qx 'CCQUOTA_TOKEN=ccq_NODE_alpha_0123' "$STORE" \
  && pass "B fleet-hub-move.py moved the store's node.env (token kept)" || fail "B rewrite rc $rc: $out"
printf '%s\n' "$out" | grep -q '^credential proxy reload: rc 0' \
  && pass "B the writer asked for the shared proxy's reload" || fail "B no reload asked: $out"
c=$(call)
[ "$c" = 200 ] && [ "$(hub_seen)" = "$NEW" ] && pass "B the next /hub/v1/ call is forwarded to $NEW, not refused" \
  || fail "B HTTP $c $(cat "$SB/body") · forwarder saw: $(tail -n 1 "$SB/fwd.log" 2>/dev/null)"
[ "$(cat "$SB/run/.shared/pid")" = "$PID" ] && kill -0 "$PID" 2>/dev/null \
  && pass "B the same proxy process (pid $PID) — followed, not restarted" || fail "B the proxy was restarted"

# ── C: only a file nobody else may write is followed ───────────────────────
EVIL=https://evil-hub.example
printf 'CCQUOTA_HUB_URL=%s\nCCQUOTA_TOKEN=ccq_NODE_alpha_0123\nCCQUOTA_FLEET=1\n' "$EVIL" > "$STORE"
chmod 620 "$STORE"
: > "$SB/fwd.log"
c=$(call)
[ "$c" = 403 ] && [ ! -s "$SB/fwd.log" ] && pass "C a group-writable node.env is not followed: 403, the hub never asked" \
  || fail "C HTTP $c $(cat "$SB/body") · forwarder saw: $(cat "$SB/fwd.log")"
grep -q "https, but its host evil-hub.example is not on this proxy's allow-list (allowed: " "$SB/body" \
  && ! grep -q 'neither https nor loopback' "$SB/body" \
  && pass "C the 403 says https-but-not-allowed, naming the host and the list" || fail "C the words: $(cat "$SB/body")"
grep -q "not followed: its file is group/other-writable" "$SB/log/shared.log" "$SB/launch.err" 2>/dev/null \
  && pass "C the proxy says why it did not follow" || fail "C no line saying why: $(tail -n 3 "$SB/launch.err")"
chmod 600 "$STORE"
c=$(call)
[ "$c" = 200 ] && [ "$(hub_seen)" = "$EVIL" ] && pass "C made 0600 again (root's own), it is followed on the next call" \
  || fail "C after chmod 600: HTTP $c $(cat "$SB/body")"

# ── D: the old hosts stay allowed for the process's life ──────────────────
printf 'CCQUOTA_HUB_URL=%s\nCCQUOTA_TOKEN=ccq_NODE_alpha_0123\nCCQUOTA_FLEET=1\n' "$OLD" > "$STORE"; chmod 600 "$STORE"
c=$(call)
[ "$c" = 200 ] && [ "$(hub_seen)" = "$OLD" ] && pass "D back to the old address: still allowed (hosts are only added)" \
  || fail "D HTTP $c $(cat "$SB/body")"
grep -q '"allow_follow"' "$SB/log/shared.log" 2>/dev/null && pass "D the follow is logged (allow_follow)" \
  || fail "D no allow_follow in the shared log"

# ── E: the repo-authority guard's words ────────────────────────────────────
w=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import fleet_repo_authority as r
print(r.error_reason(ValueError(sys.argv[2])))' "$BIN" \
  "the hub refused (HTTP 403): cred-proxy: hub URL https://x.example refused: https, but its host x.example is not on this proxy's allow-list (allowed: a)" 2>&1)
case "$w" in *"credential proxy refused the hub address, not the Hub"*"machine reload"*) pass "E repo authority names the proxy and the reload" ;;
  *) fail "E repo authority: $w" ;; esac

if [ "$FAIL" != 0 ]; then
  echo "fleet-cred-hub-moved selftest: FAILED"; exit 1
fi
echo "fleet-cred-hub-moved selftest: OK"
