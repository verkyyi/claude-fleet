#!/bin/bash
# fleet-node-selftest.sh — `fleet node join` / `fleet node status` (issue #1627):
# bin/fleet → bin/fleet-node.sh → bin/fleet-login.py node (the scan) →
# bin/fleet-node-join.sh --joined --ui, against a fake hub on 127.0.0.1. Fully
# hermetic: HOME is a sandbox, the hub is a tiny python server answering the
# device flow (/v1/fleet/login/start + poll) and the node endpoints
# (/v1/node/self, /v1/node/dist/<os>-<arch>) the way tokenledger does, and the
# "ccquota" it serves is a stub whose `agent` checks in with node.env's token —
# so "online" means the agent really started on the pass the scan returned.
# The agent runs --service detached (FLEET_NODE_JOIN_ARGS, never launchd from a
# test) and is killed by its pid file.
#
# What it pins:
#   A. join      `fleet node join` with NO argument (the hub comes from
#                fleet.conf, like `fleet login`): the start carries
#                purpose=node, the login and the device name, with the key
#                `fleet login` uses (~/.ssh/fleet-cert, made here); exit 0;
#                node.env 0600 with the scan's token; the agent online;
#                FLEET_ROLE gains node; the token never printed; the output is
#                the fixed snapshot below — and its scan half is line for line
#                `fleet login`'s against the same hub
#                and (issue #1719) node.env says CCQUOTA_FLEET_COMPUTE=0, the
#                ssh snippet carries the peer-certificate Match for every other
#                machine and peer/machines lists them; and (issue #1720) the
#                join ends with the probe's line + 「可以打开：fleet node compute on」
#   B. rerun     a second `fleet node join` does not scan again (no new start)
#                and says it is already a node
#   C. resume    a run that fails mid-way (the agent's hash) prints ONE ✗ line
#                and 「重跑同一条命令即可」; the rerun of the same command
#                does not scan again and finishes only what was missing
#   D. denied    「不是我」 on the page: exit 1, no node.env
#   E. status    `fleet node status`: online → ✓ and exit 0; not a node → the
#                「fleet node join」 hint and exit 1
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/fleet-node-st.XXXXXX")"
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

for c in python3 curl ssh-keygen; do command -v "$c" >/dev/null || { echo "skip: no $c"; exit 0; }; done

cat >"$SB/ccquota" <<EOF
#!/bin/sh
case "\$1" in
  version) echo "ccquota stub" ;;
  agent)
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
TOKEN = "ccq_nodepass0123456789abcdefXYZ"
state = {"starts": 0, "polls": {}, "online": False, "last_start": None, "codes": {}}
def flag(n): return os.path.exists(os.path.join(SB, n))
def save(): json.dump(state, open(os.path.join(SB, "state.json"), "w"))
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, obj, headers=None):
        b = json.dumps(obj, separators=(",", ":")).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/v1/fleet/login/start":
            state["starts"] += 1; state["last_start"] = body
            dc = "dc%d" % state["starts"]; state["codes"][dc] = body; save()
            return self.reply(200, {"device_code": dc, "user_code": "BCDF-GHJK",
                "verification_uri": "http://hub.test/fleet/login?code=BCDF-GHJK", "expires_in": 30,
                "interval": 1, "key_fingerprint": "SHA256:testfp", "qr": ["#.#", ".#.", "#.#"]})
        if self.path == "/v1/fleet/login/poll":
            dc = body["device_code"]; n = state["polls"].get(dc, 0) + 1; state["polls"][dc] = n; save()
            if n == 1:
                return self.reply(202, {"status": "authorization_pending"})
            if flag("deny"):
                return self.reply(403, {"error": "access_denied"})
            st = state["codes"][dc]
            res = {"certificate": "ssh-ed25519-cert-v01@openssh.com AAAAfake\n", "serial": "1", "key_id": "wecom:Alice",
                   "principals": ["alice"], "valid_after": "2026-10-05T00:00:00Z", "valid_before": "2026-10-05T12:00:00Z",
                   "ssh_config": "# fleet-ssh-config v1\n\nHost m4 fleet-m4\n  HostName 127.0.0.1\n  User alice\n", "hub": "x"}
            if st.get("purpose") == "node":
                res["node"] = {"endpoint_id": "ep_1", "label": st["device_name"] + "-" + st["os_user"], "token": TOKEN,
                    "hub": "x", "admin": False, "dist": ["darwin-arm64", "darwin-amd64", "linux-amd64", "linux-arm64"], "kind": "fixed"}
            return self.reply(200, res)
        self.reply(404, {"error": "no"})
    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            return self.reply(401, {"error": "unrecognised enrollment token"})
        if self.path.startswith("/v1/node/dist/"):
            sha = "0" * 64 if flag("badsha") else hashlib.sha256(BIN).hexdigest()
            self.send_response(200); self.send_header("X-Ccquota-Sha256", sha)
            self.send_header("Content-Length", str(len(BIN))); self.end_headers(); self.wfile.write(BIN)
            return
        if self.path == "/fake/hello":
            state["online"] = True; save(); return self.reply(200, {})
        if self.path == "/v1/node/self":
            st = "online" if state["online"] else "never"
            return self.reply(200, {"endpoint_id": "ep_1", "hostname": "box", "status": st})
        self.reply(404, {"error": "no"})
srv = HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(SB, "port"), "w").write(str(srv.server_port))
srv.serve_forever()
PY
python3 "$SB/hub.py" "$SB" & HUB_PID=$!
for _ in $(seq 300); do [ -s "$SB/port" ] && break; sleep 0.1; done
[ -s "$SB/port" ] || { echo "FAIL fake hub never started"; exit 1; }
HUB="http://127.0.0.1:$(cat "$SB/port")"
hubstate() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$SB/state.json" "$1" 2>/dev/null; }

# fleet <home> <args…> — the installed entry point, in a sandbox HOME whose
# fleet.conf already names the hub (what the install line leaves behind:
# fleet-conf.sh set-hub, issue #1623).
# The probe a join ends with (issue #1720) sees a supported egress where both
# providers answer — no network from a test.
cat >"$SB/probe-curl" <<'EOF'
#!/bin/sh
for a in "$@"; do case "$a" in
  *cdn-cgi/trace) echo loc=US; exit 0 ;;
  *ipinfo.io*) echo US; exit 0 ;;
  https://api.*) printf 401; exit 0 ;;
esac; done
EOF
chmod 755 "$SB/probe-curl"

fleet_in() {
  local h="$SB/$1"; shift
  mkdir -p "$h/.config/claude-fleet"
  [ -f "$h/.config/claude-fleet/fleet.conf" ] || HOME="$h" FLEET_CONF_DIR="$h/.config/claude-fleet" \
    "$BIN/fleet-conf.sh" set-hub "$HUB" --role client >/dev/null 2>&1
  HOME="$h" FLEET_CONF_DIR="$h/.config/claude-fleet" XDG_CONFIG_HOME="$h/.config" FLEET_HUB_URL="" \
    FLEET_JOIN_POLL=1 FLEET_JOIN_SUDO="" FLEET_NODE_JOIN_ARGS="--no-deps --no-fleet --service detached --wait 15" \
    FLEET_PROBE_CURL="$SB/probe-curl" FLEET_PROBE_PMSET=false FLEET_PROBE_OS=Darwin \
    "$BIN/fleet" "$@" >"$SB/out" 2>&1 </dev/null
  echo $? >"$SB/rc"
}
# norm — what varies run to run (home, hub port, host, login) → placeholders;
# the QR block rows → one <QR> line.
norm() {
  sed -e "s#$SB/h[0-9]#<HOME>#g" -e "s#$HUB#<HUB>#g" -e "s#$(hostname -s 2>/dev/null || hostname)#<HOST>#g" \
      -e "s#$(id -un)#<ME>#g" | awk '/^  [ █▀▄]+$/ { if (!q) print "<QR>"; q=1; next } { q=0; print }'
}

# ── A. join ──────────────────────────────────────────────────────────────
fleet_in h1 node join
rc=$(cat "$SB/rc")
ENVF="$SB/h1/.config/claude-fleet/node.env"
[ "$rc" = 0 ] && ok "A fleet node join (no argument) exits 0" || bad "A rc=$rc: $(cat "$SB/out")"
python3 - "$SB/state.json" "$SB/h1/.ssh/fleet-cert.pub" <<'PY' && ok "A the scan is purpose=node, with fleet login's key, the login and the device name" || bad "A start body: $(hubstate last_start)"
import json, sys
st = json.load(open(sys.argv[1]))["last_start"]
pub = open(sys.argv[2]).read().strip()
sys.exit(0 if st["purpose"] == "node" and st["os_user"] and st["device_name"] and st["public_key"] == pub else 1)
PY
mode=$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$ENVF" 2>/dev/null)
grep -qx 'CCQUOTA_TOKEN=ccq_nodepass0123456789abcdefXYZ' "$ENVF" 2>/dev/null && grep -qx "CCQUOTA_HUB_URL=$HUB" "$ENVF" && [ "$mode" = 600 ] \
  && ok "A node.env (0600) holds the scan's node pass" || bad "A node.env mode=$mode: $(cat "$ENVF" 2>/dev/null)"
[ "$(hubstate online)" = True ] && ok "A the agent checked in with it" || bad "A the agent never checked in"
grep -q 'ccq_nodepass' "$SB/out" && bad "A the token was printed" || ok "A the token is never printed"
role=$(sed -n 's/^ *FLEET_ROLE="\{0,1\}\([^"]*\)"\{0,1\}/\1/p' "$SB/h1/.config/claude-fleet/fleet.conf")
case ",$role," in *,node,*) ok "A FLEET_ROLE has node ($role)" ;; *) bad "A FLEET_ROLE=$role: $(cat "$SB/h1/.config/claude-fleet/fleet.conf")" ;; esac
# issue #1719: a first join only coordinates, and the scan wrote the
# machine-to-machine Match for every other machine (here m4, from a hub that
# predates `machines`: the alias stands for the hostname).
grep -qx 'CCQUOTA_FLEET_COMPUTE=0' "$ENVF" 2>/dev/null && ok "A node.env says CCQUOTA_FLEET_COMPUTE=0 (只协调)" \
  || bad "A node.env compute: $(grep COMPUTE "$ENVF" 2>/dev/null)"
SNIP="$SB/h1/.ssh/fleet-ssh-config"
PBIN=$(cd "$BIN" && pwd -P)   # `fleet` runs its siblings by their physical path (/var → /private/var on macOS)
if grep -qF "Match originalhost m4,m4-*,fleet-m4,fleet-m4-* exec \"'$PBIN/fleet-peer-cert.sh' m4 view" "$SNIP" 2>/dev/null \
   && grep -q '^  IdentityFile ~/.ssh/fleet-peer$' "$SNIP" && grep -qx 'm4 m4' "$SB/h1/.config/claude-fleet/peer/machines" 2>/dev/null; then
  ok "A the ssh snippet carries the peer Match for m4; peer/machines lists it"
else bad "A peer section: $(cat "$SNIP" 2>/dev/null) / $(cat "$SB/h1/.config/claude-fleet/peer/machines" 2>/dev/null)"; fi
norm <"$SB/out" >"$SB/node.out"
cat >"$SB/node.want" <<'EOF'

用企业微信扫码，确认验证码 BCDF-GHJK：

<QR>

  或在已登录企业微信的浏览器打开：http://hub.test/fleet/login?code=BCDF-GHJK
  密钥指纹 SHA256:testfp · 30 秒内有效

✓ 证书已写入 <HOME>/.ssh/fleet-cert-cert.pub（2026-10-05T12:00:00Z 前有效，账号 alice）
✓ ssh 配置 <HOME>/.ssh/fleet-ssh-config（已在 ~/.ssh/config 末尾 Include）
✓ 到其它机器的 ssh 段已写好（1 台，每次连接先向入口要 5 分钟证书）
✓ 已登记为节点 <HOST>-<ME>（ep_1）
✓ agent 已装好：<HOME>/.local/bin/ccquota
! agent 已在后台运行，但重启后不会自己起来（--service detached）
✓ 入口看到它在线：<HUB>/nodes
! 入口没把 <ME> 列为管理登录：这台机器不开账号、不装 SSH CA（要的话在入口的 CCQUOTA_FLEET_ADMIN_USERS 里加上它）
✓ 只协调：入口不往这台派会话、不借账号（本机跑会话用自己的账号）
✓ 已上线：<HOST>/<ME> 是 <HUB> 的节点
本机判断：合适 — 出口 US，Anthropic / OpenAI 都能直连
可以打开：fleet node compute on
EOF
diff "$SB/node.want" "$SB/node.out" >"$SB/diff" && ok "A output matches the snapshot" || bad "A output snapshot:
$(cat "$SB/diff")"
# The scan half is fleet login's own, line for line.
fleet_in h9 login
norm <"$SB/out" >"$SB/login.out"
if [ "$(cat "$SB/rc")" = 0 ] && [ "$(head -n 10 "$SB/login.out")" = "$(head -n 10 "$SB/node.out")" ]; then
  ok "A the scan and certificate lines are fleet login's, line for line"
else bad "A fleet login vs fleet node join:
$(diff <(head -n 10 "$SB/login.out") <(head -n 10 "$SB/node.out"))"; fi

# ── B. rerun ─────────────────────────────────────────────────────────────
kill "$(cat "$SB/h1/.ccquota/agent.pid")" 2>/dev/null
starts=$(hubstate starts)
fleet_in h1 node join
if [ "$(cat "$SB/rc")" = 0 ] && [ "$(hubstate starts)" = "$starts" ] && grep -q "^✓ 已是 $HUB 的节点" "$SB/out" \
   && ! grep -q 用企业微信扫码 "$SB/out"; then
  ok "B a rerun does not scan again"
else bad "B rc=$(cat "$SB/rc") starts $starts→$(hubstate starts): $(cat "$SB/out")"; fi

# ── C. resume ────────────────────────────────────────────────────────────
touch "$SB/badsha"
fleet_in h2 node join
if [ "$(cat "$SB/rc")" = 1 ] && [ "$(grep -c '^✗' "$SB/out")" = 1 ] && grep -q '^✗ 装 agent失败：' "$SB/out" \
   && grep -q '^  重跑同一条命令即可：fleet node join' "$SB/out" && ! grep -q '^agent:' "$SB/out"; then
  ok "C a mid-way failure is one ✗ line + 重跑同一条命令即可"
else bad "C rc=$(cat "$SB/rc"): $(cat "$SB/out")"; fi
rm -f "$SB/badsha"
starts=$(hubstate starts)
fleet_in h2 node join
if [ "$(cat "$SB/rc")" = 0 ] && [ "$(hubstate starts)" = "$starts" ] && grep -q '^✓ 已上线' "$SB/out"; then
  ok "C the same command again finishes it without a new scan"
else bad "C rerun rc=$(cat "$SB/rc") starts $starts→$(hubstate starts): $(cat "$SB/out")"; fi

# ── D. denied ────────────────────────────────────────────────────────────
touch "$SB/deny"
fleet_in h3 node join
if [ "$(cat "$SB/rc")" = 1 ] && [ ! -e "$SB/h3/.config/claude-fleet/node.env" ]; then
  ok "D a denied scan exits 1, writes no node.env"
else bad "D rc=$(cat "$SB/rc"): $(cat "$SB/out")"; fi
rm -f "$SB/deny"

# ── E. status ────────────────────────────────────────────────────────────
fleet_in h1 node status
[ "$(cat "$SB/rc")" = 0 ] && grep -q "^✓ .* 是 $HUB 的节点：在线" "$SB/out" && ok "E status: online" || bad "E status rc=$(cat "$SB/rc"): $(cat "$SB/out")"
fleet_in h4 node status
[ "$(cat "$SB/rc")" = 1 ] && grep -q '还不是节点 — 运行：fleet node join' "$SB/out" && ok "E status: not a node" || bad "E status (none) rc=$(cat "$SB/rc"): $(cat "$SB/out")"

[ "$fail" = 0 ] && echo "PASS fleet-node-selftest" || echo "FAIL fleet-node-selftest"
exit "$fail"
