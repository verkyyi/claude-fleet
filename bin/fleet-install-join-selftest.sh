#!/bin/bash
# fleet-install-join-selftest.sh — the install line joins the hub as a node
# that only coordinates (issue #1719, EPIC #1718 C1): bin/fleet-install.sh, as
# the hub serves it, against ONE fake hub (stdlib python3 on 127.0.0.1) that
# serves /install/*, the device flow (/v1/fleet/login/start + poll, purpose=node
# answered with a node pass and the machine list), the node endpoints
# (/v1/node/dist, /v1/node/self) and /v1/node/peer-cert. HOME is a sandbox; the
# agent is a stub run --service detached (the FLEET_NODE_JOIN_ARGS seam, never
# launchd from a test) and killed by its pid file; `fleet` itself is not run
# (FLEET_INSTALL_NO_RUN=1).
#
# What it pins (the issue's 完成判据, selftest half):
#   A. one line   the install exits 0 and, in the same run, the computer is a
#                 node: ONE scan (purpose=node), node.env 0600 with the pass,
#                 CCQUOTA_FLEET_COMPUTE=0 and no CCQUOTA_FLEET_ADMIN; the agent
#                 checked in; the output says 只协调
#   B. ssh        ~/.ssh/fleet-ssh-config carries a Match per OTHER machine
#                 (m4 = mini2 on the hub, s9 = spare9; never this one) that runs the INSTALLED
#                 fleet-peer-cert.sh with the hub's hostname; peer/machines lists
#                 them; ~/.ssh/config Includes it once; the hand-written m5 block
#                 (`Match originalhost m4,m4-*,mini2 exec "…fleet-peer-cert.sh…"`)
#                 is gone from ~/.ssh/config with its comment, kept in a
#                 .fleet-bak-*, and everything else in the file is untouched;
#                 `ssh -G` parses the snippet and, for m4-lan, picks the peer key
#                 and mini2's certificate
#   C. one cert   the installed fleet-peer-cert.sh, for m4 / m4-lan / mini2:
#                 the hub asked ONCE, for mini2; every name the same file
#   D. again      a second install: 「入口: 这台已登记在 …」, no new scan, node.env
#                 unchanged
#   E. no node    --no-node: no scan, no node.env (the degenerate case)
#   F. no tty     stderr not a terminal (CI, a log): no scan, no wait — the
#                 line says to run `fleet node join` later
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-install-join-st.XXXXXX") || exit 2
HUB_PID=""
cleanup() {
  for p in "$WORK"/h*/.ccquota/agent.pid; do [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null; done
  [ -n "$HUB_PID" ] && kill "$HUB_PID" 2>/dev/null
  rm -rf "${WORK:?}"
}
trap cleanup EXIT INT TERM HUP
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
for c in python3 curl ssh ssh-keygen; do command -v "$c" >/dev/null || { echo "skip: no $c"; exit 0; }; done

# $BIN may be a shadow of symlinks (run-selftests.sh, #660): the manifest sits
# beside the LIVE bin/.
real="$BIN/fleet-install.sh"
while [ -L "$real" ]; do
  link="$(readlink "$real")"
  case "$link" in /*) real="$link" ;; *) real="$(dirname "$real")/$link" ;; esac
done
REPO="$(cd "$(dirname "$real")/.." && pwd)"
MANIFEST="$REPO/tokenledger/internal/api/fleetclient/manifest"
[ -f "$MANIFEST" ] || { echo "FAIL no manifest at $MANIFEST"; exit 1; }

cat >"$WORK/ccquota" <<'EOF'
#!/bin/sh
case "$1" in
  version) echo "ccquota stub" ;;
  agent)
    curl -fsS -H "Authorization: Bearer $CCQUOTA_TOKEN" "$CCQUOTA_HUB_URL/fake/hello" >/dev/null
    exec sleep 30 ;;
esac
EOF
chmod 755 "$WORK/ccquota"

cat >"$WORK/hub.py" <<'PY'
import hashlib, json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
REPO, MAN, W, ME = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
BIN = open(os.path.join(W, "ccquota"), "rb").read()
TOKEN = "ccq_nodepass0123456789abcdefXYZ"
names = [l.split()[0] for l in open(MAN) if l.strip() and not l.lstrip().startswith("#")
         and not (len(l.split()) > 1 and l.split()[1] == "installer")]
state = {"starts": 0, "polls": {}, "online": False, "codes": {}, "peer": []}
def save(): json.dump(state, open(os.path.join(W, "state.json"), "w"))
save()
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, obj):
        b = json.dumps(obj, separators=(",", ":")).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def raw(self, b, sha=None):
        self.send_response(200); self.send_header("X-Ccquota-Sha256", sha or hashlib.sha256(b).hexdigest())
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/v1/fleet/login/start":
            state["starts"] += 1
            dc = "dc%d" % state["starts"]; state["codes"][dc] = body; save()
            return self.reply(200, {"device_code": dc, "user_code": "BCDF-GHJK",
                "verification_uri": "http://hub.test/fleet/login?code=BCDF-GHJK", "expires_in": 30,
                "interval": 1, "key_fingerprint": "SHA256:testfp", "qr": ["#.#", ".#.", "#.#"]})
        if self.path == "/v1/fleet/login/poll":
            dc = body["device_code"]; st = state["codes"][dc]
            res = {"certificate": "ssh-ed25519-cert-v01@openssh.com AAAAfake\n", "serial": "1", "key_id": "wecom:Alice",
                   "principals": ["alice"], "valid_after": "2026-10-05T00:00:00Z", "valid_before": "2026-10-05T12:00:00Z",
                   "ssh_config": "# fleet-ssh-config v1\n\nHost m4 fleet-m4 fleet-m4-public\n  HostName 127.0.0.1\n  User alice\n"
                                 "\nHost s9 fleet-s9 fleet-s9-public\n  HostName 127.0.0.2\n  User alice\n",
                   "machines": [{"hostname": "mini2", "alias": "m4"}, {"hostname": "spare9", "alias": "s9"},
                                {"hostname": ME, "alias": "self7"}], "hub": "x"}
            if st.get("purpose") == "node":
                res["node"] = {"endpoint_id": "ep_1", "label": st["device_name"] + "-" + st["os_user"], "token": TOKEN,
                    "hub": "x", "admin": False, "dist": ["darwin-arm64", "darwin-amd64", "linux-amd64", "linux-arm64"], "kind": "fixed"}
            return self.reply(200, res)
        if self.path == "/v1/node/peer-cert":
            if self.headers.get("Authorization") != "Bearer " + TOKEN:
                return self.reply(401, {"error": "unrecognised enrollment token"})
            state["peer"].append(body["target"]); save()
            return self.reply(200, {"certificate": "ssh-ed25519-cert-v01@openssh.com AAAApeer\n", "serial": "9",
                "key_id": "peer", "login": "alice", "target": body["target"], "ttl_sec": 300})
        self.reply(404, {"error": "no"})
    def do_GET(self):
        if self.path.startswith("/install/"):
            name = self.path[len("/install/"):]
            if name == "manifest":
                return self.raw(open(MAN, "rb").read())
            if name in names:
                return self.raw(open(os.path.join(REPO, name), "rb").read())
            self.send_response(404); self.end_headers(); return
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            return self.reply(401, {"error": "unrecognised enrollment token"})
        if self.path.startswith("/v1/node/dist/"):
            return self.raw(BIN)
        if self.path == "/fake/hello":
            state["online"] = True; save(); return self.reply(200, {})
        if self.path == "/v1/node/self":
            return self.reply(200, {"endpoint_id": "ep_1", "hostname": "box", "status": "online" if state["online"] else "never"})
        self.reply(404, {"error": "no"})
srv = HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(W, "port.tmp"), "w").write(str(srv.server_port)); os.rename(os.path.join(W, "port.tmp"), os.path.join(W, "port"))
srv.serve_forever()
PY
ME=$(hostname -s 2>/dev/null || hostname); ME=${ME%%.*}
python3 "$WORK/hub.py" "$REPO" "$MANIFEST" "$WORK" "$ME" & HUB_PID=$!
for _ in $(seq 1 300); do [ -s "$WORK/port" ] && break; sleep 0.1; done
[ -s "$WORK/port" ] || { echo "FAIL fake hub never started"; exit 1; }
HUB="http://127.0.0.1:$(cat "$WORK/port")"
hubstate() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$WORK/state.json" "$1" 2>/dev/null; }
sed "s|__FLEET_HUB_URL__|$HUB|g" "$BIN/fleet-install.sh" > "$WORK/install.sh"

unset FLEET_CONF_DIR FLEET_HUB_URL FLEET_INSTALL_BIN FLEET_INSTALL_HOME FLEET_INSTALL_RC XDG_DATA_HOME XDG_CACHE_HOME \
      FLEET_INSTALL_NO_NODE FLEET_NODE_ALIASES CCQUOTA_TOKEN CCQUOTA_HUB_URL FLEET_HUB_CURL
# install <home> [args…] — the line, piped like `curl … | sh`, in a sandbox HOME
install_in() {
  local h="$WORK/$1"; shift
  mkdir -p "$h"
  HOME="$h" XDG_CONFIG_HOME="$h/.config" SHELL=/bin/sh FLEET_INSTALL_NO_RUN=1 FLEET_INSTALL_NO_DEPS=1 FLEET_INSTALL_ASK=0 \
    FLEET_INSTALL_RC="$h/.profile" FLEET_JOIN_POLL=1 FLEET_JOIN_SUDO="" \
    FLEET_NODE_JOIN_ARGS="--service detached --wait 15" FLEET_INSTALL_NODE_FORCE="${FORCE-1}" \
    FLEET_PROBE_CURL=false FLEET_PROBE_PMSET=false \
    sh -s -- "$@" < "$WORK/install.sh" >"$WORK/out" 2>&1
  echo $? >"$WORK/rc"
}

# The hand-written block m5 carried before #1719, with what surrounds it.
H1="$WORK/h1"
mkdir -p "$H1/.ssh"
cat >"$H1/.ssh/config" <<'EOF'
# claude-fleet: reach m4 with a hub-signed 5-minute certificate (personal m5<->m4
# trust removed 2026-10-05, EPIC verkyyi/claude-fleet#1615 C9).
Match originalhost m4,m4-*,mini2 exec "$HOME/.claude/fleet/bin/fleet-peer-cert.sh mini2 view >/dev/null 2>&1"
  IdentityFile ~/.ssh/fleet-peer
  CertificateFile ~/.config/claude-fleet/peer/mini2.view-cert.pub

Include ~/.ssh/config.d/*.conf

# macbook over Tailscale
Host macbook
  HostName 100.110.252.40
EOF
cp "$H1/.ssh/config" "$WORK/config.orig"

# ── A. one line ─────────────────────────────────────────────────────────────
install_in h1
CONF="$H1/.config/claude-fleet"
ROOT="$H1/.claude/fleet"   # the one fleet directory (#1804)
ENVF="$CONF/node.env"
[ "$(cat "$WORK/rc")" = 0 ] && ok "A install exit 0" || bad "A install rc=$(cat "$WORK/rc"): $(cat "$WORK/out")"
[ "$(hubstate starts)" = 1 ] && python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if s["codes"]["dc1"]["purpose"]=="node" else 1)' "$WORK/state.json" \
  && ok "A one scan, purpose=node" || bad "A scans: $(cat "$WORK/state.json")"
mode=$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$ENVF" 2>/dev/null)
if [ "$mode" = 600 ] && grep -qx 'CCQUOTA_TOKEN=ccq_nodepass0123456789abcdefXYZ' "$ENVF" && grep -qx "CCQUOTA_HUB_URL=$HUB" "$ENVF" \
   && grep -qx 'CCQUOTA_FLEET_COMPUTE=0' "$ENVF" && ! grep -q 'CCQUOTA_FLEET_ADMIN' "$ENVF"; then
  ok "A node.env (0600): the pass, CCQUOTA_FLEET_COMPUTE=0, no admin"
else bad "A node.env mode=$mode: $(sed 's/TOKEN=.*/TOKEN=…/' "$ENVF" 2>/dev/null)"; fi
[ "$(hubstate online)" = True ] && ok "A the agent checked in" || bad "A the agent never checked in: $(cat "$WORK/out")"
grep -q '✓ 只协调' "$WORK/out" && grep -q '✓ 已登记到入口' "$WORK/out" && ok "A the output says 已登记 + 只协调" || bad "A output: $(cat "$WORK/out")"
grep -q 'ccq_nodepass' "$WORK/out" && bad "A the token was printed" || ok "A the token is never printed"

# ── B. ssh ──────────────────────────────────────────────────────────────────
SNIP="$H1/.ssh/fleet-ssh-config"
PC="$(cd "$ROOT/bin" && pwd -P)/fleet-peer-cert.sh"   # `fleet` runs its siblings by their physical path
if grep -qF "Match originalhost m4,m4-*,mini2,mini2-*,fleet-m4,fleet-m4-* exec \"'$PC' mini2 view >/dev/null 2>&1\"" "$SNIP" \
   && grep -qF "Match originalhost s9,s9-*,spare9,spare9-*,fleet-s9,fleet-s9-* exec \"'$PC' spare9 view >/dev/null 2>&1\"" "$SNIP" \
   && ! grep -q 'self7' "$SNIP" \
   && grep -qF 'CertificateFile "~/.config/claude-fleet/peer/mini2.view-cert.pub"' "$SNIP" && grep -q '^Host m4 fleet-m4' "$SNIP"; then
  ok "B the snippet: a Match per OTHER machine (not this one) through the installed fleet-peer-cert.sh, keyed on the hub's hostname"
else bad "B snippet: $(cat "$SNIP" 2>/dev/null)"; fi
[ "$(cat "$CONF/peer/machines" 2>/dev/null)" = "$(printf 'mini2 m4\nspare9 s9\n%s self7' "$ME")" ] && ok "B peer/machines lists the hub's machines" \
  || bad "B peer/machines: $(cat "$CONF/peer/machines" 2>/dev/null)"
[ "$(grep -c '^Include ~/.ssh/fleet-ssh-config$' "$H1/.ssh/config")" = 1 ] && ok "B ~/.ssh/config Includes the snippet once" \
  || bad "B config: $(cat "$H1/.ssh/config")"
bak=$(ls "$H1/.ssh/"config.fleet-bak-* 2>/dev/null | head -n 1)
if ! grep -q 'fleet-peer-cert' "$H1/.ssh/config" && ! grep -q 'personal m5<->m4' "$H1/.ssh/config" \
   && grep -q '^Include ~/.ssh/config.d/\*.conf$' "$H1/.ssh/config" && grep -q '^Host macbook$' "$H1/.ssh/config" \
   && grep -q '^# macbook over Tailscale$' "$H1/.ssh/config" && [ -n "$bak" ] && cmp -s "$bak" "$WORK/config.orig"; then
  ok "B the hand-written block is taken over (comment too), the rest kept, the original backed up"
else bad "B takeover: config=$(cat "$H1/.ssh/config") bak=$bak"; fi
grep -q '接管' "$WORK/out" && ok "B the takeover is said" || bad "B no takeover line: $(cat "$WORK/out")"
G=$(HOME="$H1" FLEET_CONF_DIR="$CONF" ssh -G -F "$SNIP" m4-lan 2>&1)
case "$G" in
  *"identityfile ~/.ssh/fleet-peer"*mini2.view-cert.pub*|*"/.ssh/fleet-peer"*"mini2.view-cert.pub"*)
    ok "B ssh -G m4-lan: the Match applies — the peer key and mini2's certificate" ;;
  *) bad "B ssh -G m4-lan: $(printf '%s\n' "$G" | grep -Ei 'identityfile|certificatefile|error|bad|line')" ;;
esac

# ── C. one cert ─────────────────────────────────────────────────────────────
certs=""
for n in m4 m4-lan mini2; do
  o=$(HOME="$H1" FLEET_CONF_DIR="$CONF" bash "$PC" "$n" view 2>"$WORK/err") || { bad "C $n: exit $?: $(cat "$WORK/err")"; continue; }
  certs="$certs $(printf '%s\n' "$o" | sed -n 's/^CertificateFile=//p')"
done
# ssh -G above may already have asked once; the three names add nothing
peer=$(hubstate peer)
set -- $certs
if [ "$#" = 3 ] && [ "$1" = "$CONF/peer/mini2.view-cert.pub" ] && [ "$1" = "$2" ] && [ "$2" = "$3" ] && [ "$peer" = "['mini2']" ]; then
  ok "C m4 / m4-lan / mini2: one ask, for mini2 — the same certificate"
else bad "C certs=$certs hub asked for $peer"; fi

# ── D. again ────────────────────────────────────────────────────────────────
kill "$(cat "$H1/.ccquota/agent.pid")" 2>/dev/null
cp "$ENVF" "$WORK/env.before"
install_in h1
if [ "$(cat "$WORK/rc")" = 0 ] && [ "$(hubstate starts)" = 1 ] && grep -q "入口: 这台已登记在 $HUB" "$WORK/out" && cmp -s "$ENVF" "$WORK/env.before"; then
  ok "D a second install leaves the node alone (no scan, node.env unchanged)"
else bad "D rc=$(cat "$WORK/rc") starts=$(hubstate starts): $(cat "$WORK/out")"; fi

# ── F. no terminal ──────────────────────────────────────────────────────────
# output to a file and no FORCE: nobody could scan, so no join — one line instead
FORCE='' install_in h3
if [ "$(cat "$WORK/rc")" = 0 ] && [ "$(hubstate starts)" = 1 ] && [ ! -e "$WORK/h3/.config/claude-fleet/node.env" ] \
   && grep -q '入口: 这里没有终端可显示二维码' "$WORK/out"; then
  ok "F no terminal: no scan, no wait, the fleet node join line"
else bad "F rc=$(cat "$WORK/rc") starts=$(hubstate starts): $(cat "$WORK/out")"; fi

# ── E. no node ──────────────────────────────────────────────────────────────
install_in h2 --no-node
if [ "$(cat "$WORK/rc")" = 0 ] && [ "$(hubstate starts)" = 1 ] && [ ! -e "$WORK/h2/.config/claude-fleet/node.env" ] \
   && ! grep -q '入口:' "$WORK/out"; then
  ok "E --no-node: no scan, no node.env"
else bad "E rc=$(cat "$WORK/rc") starts=$(hubstate starts): $(cat "$WORK/out")"; fi

[ "$fail" = 0 ] && echo "PASS fleet-install-join-selftest" || echo "FAIL fleet-install-join-selftest"
exit "$fail"
