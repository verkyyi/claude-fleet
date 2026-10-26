#!/bin/bash
# fleet-break-it-hubmove-selftest.sh — the docs/dev/BREAK-IT.md row of a moved
# hub followed on an unverified word (task PNWW): a welcome's address
# (fleet.node_url) is where a machine sends its node token next. Followed as
# announced, a typo, a stale value or a hub that is not this one would take every
# machine off its hub — each to an address that refuses it — and the next move
# would again be root on every Mac by hand. The drill puts a sandbox login's and
# a sandbox machine's files on an old address, two fake hubs on 127.0.0.1 (the
# old one, and a "new" one that refuses the node's token / names another
# endpoint), runs the one writer as the agents do (bin/fleet-hub-move.py follow /
# verify), and passes when nothing was written for either refusal and a verified
# move rewrites every file. The agent half (an unverified move leaves it on its
# own hub, asked once) is go test TestPlainAgentStaysOnUnverifiedMove. Runner and
# timing helpers are bin/fleet-break-it-cred-selftest.sh's (BREAK_CRED_LIB=1);
# bin/fleet-break-it-selftest.sh's lockstep lint reads the drill names here too.
#
#   hub-moved-unverified  bin/fleet-hub-move.py (verify / follow / rewrite) +
#                         tokenledger/agent/hub_follow.go (followHub)
#   credproxy-hub-url-moved  bin/fleet-cred-proxy.py (follow_node_envs / upstream_refusal)
#                         + bin/fleet-hub-move.py (proxy_reload): the machine's shared
#                         credential proxy, started on the old hub, carries /hub/v1/
#                         to the new one after the store's node.env moved — no restart
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"

drill_hub_moved_unverified() {
  CAP=15
  local d="$WORK/hubmove" t0 rc f old good other
  mkdir -p "$d/conf" "$d/state/logins"
  cat > "$d/hub.py" <<'PY'
import http.server, json, sys
port_file, eid, want = sys.argv[1], sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path != "/v1/node/self" or self.headers.get("Authorization") != want:
            self.send_response(401); self.end_headers(); return
        b = json.dumps({"endpoint_id": eid}).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(b)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(s.server_address[1]))
s.serve_forever()
PY
  # old: this node's hub · good: the same hub at a new address · other: a hub
  # that is not this one (another endpoint) · refuse: one that will not take the token
  for h in old:e1:tok good:e1:tok other:e9:tok refuse:e1:nope; do
    python3 -I "$d/hub.py" "$d/${h%%:*}.port" "$(printf '%s' "$h" | cut -d: -f2)" "Bearer ${h##*:}" &
    printf '%s\n' "$!" >> "$WORK/cred-pids"
  done
  for h in old good other refuse; do
    for _ in $(seq 1 50); do [ -s "$d/$h.port" ] && break; sleep 0.1; done
    [ -s "$d/$h.port" ] || { WHY="fake hub $h did not start"; return 1; }
  done
  old="http://127.0.0.1:$(cat "$d/old.port")"
  printf 'export FLEET_HUB_URL="%s"\n' "$old" > "$d/conf/fleet.conf"
  printf 'CCQUOTA_HUB_URL=%s\nCCQUOTA_TOKEN=tok\n' "$old" > "$d/conf/node.env"
  printf 'CCQUOTA_HUB_URL=%s\nCCQUOTA_TOKEN=mtok\n' "$old" > "$d/state/machine.env"
  printf 'CCQUOTA_HUB_URL=%s\n' "$old" > "$d/state/logins/alice.env"
  ( cd "$d" && cat conf/fleet.conf conf/node.env state/machine.env state/logins/alice.env ) > "$d/before"
  t0=$(now)
  export FLEET_HUB_MOVE_TEST_HTTP=1
  for bad in other refuse; do
    printf 'Bearer tok\nBearer tok\n' | python3 -I "$BIN/fleet-hub-move.py" follow --scope login \
      --from "$old" --to "http://127.0.0.1:$(cat "$d/$bad.port")" --conf-dir "$d/conf" > "$d/out.$bad" 2>&1
    rc=$?
    [ "$rc" = 3 ] || { WHY="follow to the $bad hub exited $rc, want 3 (refused): $(cat "$d/out.$bad")"; return 1; }
    printf 'Bearer tok\nBearer tok\n' | python3 -I "$BIN/fleet-hub-move.py" verify \
      --from "$old" --to "http://127.0.0.1:$(cat "$d/$bad.port")" > "$d/vout.$bad" 2>&1
    [ $? = 3 ] || { WHY="the machine's verify of the $bad hub did not refuse: $(cat "$d/vout.$bad")"; return 1; }
  done
  ( cd "$d" && cat conf/fleet.conf conf/node.env state/machine.env state/logins/alice.env ) > "$d/after"
  cmp -s "$d/before" "$d/after" || { WHY="an unverified move wrote: $(diff "$d/before" "$d/after" | head -n 4)"; return 1; }
  for f in "$d"/conf/*.hub-prev "$d"/state/*.hub-prev; do
    [ -e "$f" ] && { WHY="an unverified move left a backup: $f"; return 1; }
  done
  # the verified move: every file follows, machine.env last
  good="http://127.0.0.1:$(cat "$d/good.port")"
  printf 'Bearer tok\nBearer tok\n' | python3 -I "$BIN/fleet-hub-move.py" follow --scope login \
    --from "$old" --to "$good" --conf-dir "$d/conf" > "$d/out.good" 2>&1 \
    || { WHY="the verified follow failed: $(cat "$d/out.good")"; return 1; }
  python3 -I "$BIN/fleet-hub-move.py" rewrite --scope machine --from "$old" --to "$good" --state "$d/state" \
    --cred-base "$d/no-store" > "$d/out.m" 2>&1 || { WHY="the machine rewrite failed: $(cat "$d/out.m")"; return 1; }
  unset FLEET_HUB_MOVE_TEST_HTTP
  SECS=$(since "$t0")
  grep -qx "export FLEET_HUB_URL=\"$good\"" "$d/conf/fleet.conf" && grep -qx "CCQUOTA_HUB_URL=$good" "$d/conf/node.env" \
    && grep -qx "CCQUOTA_HUB_URL=$good" "$d/state/machine.env" && grep -qx "CCQUOTA_HUB_URL=$good" "$d/state/logins/alice.env" \
    || { WHY="a verified move did not reach every file"; return 1; }
  WHAT="新地址不认这台的通行证 / 是别的入口：一个文件都没写；同一入口的新地址：每个文件跟过去，machine.env 最后"
}

# credproxy-hub-url-moved (2026-10-26, after PR #5471): the hub moved and the one
# writer rewrote every login's root-owned node.env, but the machine's shared
# credential proxy had computed its allow-list once at start: every /hub/v1/ call
# was a 403 «hub URL is neither https nor loopback» (an https URL, really: its new
# host was not on the list), so the repo-authority check failed every session
# start and cross-machine restore on that node until someone restarted the proxy.
# Now the proxy re-reads a changed root-owned node.env when a host misses and adds
# its hub's host. The drill: one tenant on a sandboxed shared proxy (the
# FLEET_CREDSEP_* seams), its hub a fake forwarder (CCQUOTA_HUB_SOCK) so an https
# name needs no TLS; the store moved by bin/fleet-hub-move.py; no machine daemon,
# so nothing restarts the proxy — the next /hub/v1/ call must reach the new hub.
drill_credproxy_hub_url_moved() {
  CAP=10
  local d res
  d=$(mktemp -d "/tmp/brkhm.XXXXXX")
  res=$( (
    set -u
    old=https://old-hub.example new=https://new-hub.example me=$(id -un)
    fp() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
    p0=$(fp) p1=$(fp) p2=$(fp)
    export FLEET_CREDSEP_ROOT_BASE="$d/db" FLEET_CREDSEP_RUN_BASE="$d/run" FLEET_CREDSEP_LOG_BASE="$d/log" \
      FLEET_CREDSEP_LIB="$d/lib" FLEET_CREDSEP_DAEMON_DIR="$d/daemons" FLEET_CREDSEP_ROLE="$me" \
      FLEET_CREDSEP_SVC=0 FLEET_CREDSEP_TEST=1 FLEET_CREDSEP_PREFLIGHT=0 FLEET_CREDSEP_SUDO='' \
      FLEET_CREDSEP_PW="$d/pw" FLEET_CREDSEP_USERS="$d/users" FLEET_CREDSEP_HOMES="$d/homes" \
      FLEET_NODE_STATE="$d/node" FLEET_CRED_SHARED_PORT="$p0" CCQUOTA_HUB_SOCK="$d/hub.sock" \
      FLEET_CRED_ANTHROPIC_URL="http://127.0.0.1:$p1" FLEET_CRED_CODEX_URL="http://127.0.0.1:$p2/codex"
    unset CCQUOTA_TOKEN CCQUOTA_HUB_URL FLEET_HUB_URL FLEET_CRED_SEPARATE FLEET_CRED_PROXY FLEET_CRED_AS FLEET_HUB_INTERNAL_URL
    mkdir -p "$d/daemons" "$d/node"
    cat > "$d/fwd.py" <<'PY'
import socket, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        open(sys.argv[2], "a").write(self.headers.get("X-Fleet-Hub", "-") + "\n")
        b = b'{"endpoint_id":"e1"}'
        self.send_response(200); self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
class U(ThreadingHTTPServer):
    address_family = socket.AF_UNIX
    def server_bind(self): self.socket.bind(self.server_address)
    def get_request(self):
        r, _ = self.socket.accept(); return r, ("unix", 0)
U(sys.argv[1], H).serve_forever()
PY
    # (every background job off the $(…) pipe, or the substitution waits for it)
    python3 "$d/fwd.py" "$d/hub.sock" "$d/fwd.log" >/dev/null 2>&1 & printf '%s\n' "$!" >> "$WORK/cred-pids"
    until_ok 10 test -S "$d/hub.sock" || { echo "WHY the fake hub forwarder did not start"; exit; }
    printf 'alpha:%s:%s:%s\n' "$(id -u)" "$(id -g)" "$d/homes/alpha" > "$d/pw"
    printf 'alpha:%s\n' "$d/homes/alpha" > "$d/users"
    c="$d/homes/alpha/.config/claude-fleet"; mkdir -p "$c/accounts/main.hub" "$d/homes/alpha/.claude/fleet/bin"
    : > "$d/homes/alpha/.claude/fleet/bin/fleet-credsep.sh"
    printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-a","expiresAt":4102444800000}}' > "$c/accounts/main.hub/.credentials.json"
    printf 'hub:main\n' > "$c/accounts/main"
    printf 'export FLEET_HOST=1\n' > "$c/fleet.conf"
    printf 'CCQUOTA_HUB_URL=%s\nCCQUOTA_TOKEN=ccq_drill_node\n' "$old" > "$c/node.env"; chmod 600 "$c/node.env"
    bash "$BIN/fleet-credsep.sh" machine install --logins alpha > "$d/install.out" 2>&1 \
      || { echo "WHY machine install failed: $(tail -2 "$d/install.out" | tr '\n' ' ')"; exit; }
    python3 -I "$d/lib/fleet-credsep-launch.py" shared >/dev/null 2>>"$d/launch.err" &
    until_ok 30 test -S "$d/run/.shared/ctl.sock" || { echo "WHY the shared proxy did not start: $(tail -2 "$d/launch.err" | tr '\n' ' ')"; exit; }
    until_ok 5 test -s "$d/run/.shared/pid"; printf '%s\n' "$(cat "$d/run/.shared/pid")" >> "$WORK/cred-pids"
    pair=$(FLEET_CONF_DIR="$c" python3 -I "$BIN/fleet_cred_ctl.py" node-token 2>&1)
    burl=${pair%%	*} btok=${pair#*	}
    call() { curl -s -m 20 -o "$d/body" -w '%{http_code}' -H "Authorization: Bearer $btok" "$burl/v1/node/self"; }
    [ "$(call)" = 200 ] && [ "$(tail -n 1 "$d/fwd.log")" = "$old" ] \
      || { echo "WHY the hub as joined was not reached: $(cat "$d/body")"; exit; }
    t0=$(now)
    python3 -I "$BIN/fleet-hub-move.py" rewrite --scope machine --from "$old" --to "$new" \
      --state "$d/nstate" --cred-base "$d/db" > "$d/move.out" 2>&1 \
      || { echo "WHY the writer failed: $(tail -2 "$d/move.out" | tr '\n' ' ')"; exit; }
    code=$(call)
    [ "$code" = 200 ] && [ "$(tail -n 1 "$d/fwd.log")" = "$new" ] \
      || { echo "WHY after the move the proxy answered HTTP $code: $(cat "$d/body")"; exit; }
    echo "OK $(since "$t0")"
  ) )
  kill "$(cat "$d/run/.shared/pid" 2>/dev/null)" 2>/dev/null
  pkill -f "$d/" 2>/dev/null
  rm -rf "$d"
  case "$res" in "OK "*) SECS=${res#OK } ;; *) WHY=${res#WHY }; return 1 ;; esac
  WHAT="入口搬家、唯一写入者改了凭据存储里的 node.env：共享代理不重启，下一次 /hub/v1/ 就转到新入口（新 host 进允许名单），不再 403"
}

cred_run_drills "$0"
