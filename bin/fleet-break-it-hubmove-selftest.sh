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

cred_run_drills "$0"
