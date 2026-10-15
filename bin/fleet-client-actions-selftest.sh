#!/bin/bash
# fleet-client-actions-selftest.sh — shared node send and lease-key contracts.
# The device action loop retired with #3008. Current device delivery is covered
# by fleet-thin-open/notify; this fake hub exercises the preserved send endpoint,
# no-client fallback, forward/file payload and private acquisition key.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { printf 'fleet-client-actions selftest: python3 absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fca-st.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
export HOME="$WORK/home"; mkdir -p "$HOME/.config/claude-fleet" "$WORK/fakebin" "$WORK/client"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" FLEET_CONF_DIR="$HOME/.config/claude-fleet"
unset TMUX TMUX_PANE FLEET_HUB_URL CCQUOTA_HUB_URL CCQUOTA_TOKEN FLEET_HUB_TOKEN SSH_CONNECTION FLEET_NODE_ALIASES
unset FLEET_CLIENT_WHERE_CMD FLEET_OPEN_WHERE_CMD FLEET_REMOTE_SSH
export NO_PROXY='*' no_proxy='*'   # a runner's proxy must not stand between us and 127.0.0.1
HUBPID=''

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 (want '$2')" "$3"; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 (want '$3')" "$2" ;; esac; }
hasnt() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 (must not hold '$3')" "$2" ;; esac; }
cleanup() { [ -n "$HUBPID" ] && kill "$HUBPID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# --- the fake hub: the Go hub's two action doors + the lease read, same signing ---
KEY=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
LEASE=lease-$$
cat > "$WORK/hub.py" <<'PY'
import json, os, sys, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
work, key, lease = sys.argv[1:4]


def where():
    try:
        return json.load(open(work + "/where.json"))
    except (OSError, ValueError):
        return None

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def reply(self, d, code=200):
        b = json.dumps(d).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def body(self):
        return json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
    def do_GET(self):
        if self.path == "/v1/node/client" and self.headers.get("Authorization") == "Bearer NODETOK":
            w = where()
            return self.reply({"state": "active", "lease": dict(w, id=lease)} if w else {"state": "none"})
        self.reply({}, 404)
    def do_POST(self):
        auth = self.headers.get("Authorization")
        d = self.body()
        if self.path == "/v1/node/client/actions" and auth == "Bearer NODETOK":
            w = where()
            if not w:
                return self.reply({"state": "none"})
            a = {k: v for k, v in d.items() if k != "wait"}
            a.update(id=uuid.uuid4().hex[:12], lease=lease, ts=int(time.time()), machine="otherbox", host="otherbox.lan")
            open(work + "/sent.log", "a").write(json.dumps(a) + "\n")
            return self.reply({"state": "queued", "id": a["id"], "client": w})
        if self.path in ("/v1/fleet/client", "/v1/fleet/client/test") and auth == "Bearer CLIENTTOK":
            return self.reply({"state": "active", "lease": {"id": lease, "device": "MacBook"}, "action_key": key})
        self.reply({}, 404)

s = ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(work + "/hub.port.tmp", "w") as f:
    f.write(str(s.server_address[1]))
os.replace(work + "/hub.port.tmp", work + "/hub.port")
s.serve_forever()
PY
python3 "$WORK/hub.py" "$WORK" "$KEY" "$LEASE" & HUBPID=$!
n=300; while [ ! -s "$WORK/hub.port" ] && [ "$n" -gt 0 ]; do sleep 0.1; n=$((n - 1)); done
PORT=$(cat "$WORK/hub.port" 2>/dev/null)
[ -n "$PORT" ] || { fail "the fake hub never listened"; exit 1; }
HUB="http://127.0.0.1:$PORT"

# The node's side: node.env carries the hub + this node's token (read, never sourced).
printf 'CCQUOTA_HUB_URL=%s\nCCQUOTA_TOKEN=NODETOK\n' "$HUB" > "$FLEET_CONF_DIR/node.env"

printf '{"device":"MacBook","caps":["open_url","show_file"]}\n' > "$WORK/where.json"
send() { python3 "$BIN/fleet-client-actions.py" send "$@"; }
out=$(send --kind open_url --url https://example.com/report)
has "A queued response" "$out" '"state": "queued"'
has "A target client retained" "$out" '"device": "MacBook"'
has "A URL sent" "$(cat "$WORK/sent.log")" '"url": "https://example.com/report"'
out=$(send --kind open_url --from-addr '{"kind":"forward","rport":8765,"path":"/d/x/","scheme":"http"}' --tailnet-link https://tail.example/d/x/)
has "B forward port" "$(tail -n 1 "$WORK/sent.log")" '"rport": 8765'
has "B forward path" "$(tail -n 1 "$WORK/sent.log")" '"path": "/d/x/"'
has "B fallback link" "$(tail -n 1 "$WORK/sent.log")" '"tailnet": "https://tail.example/d/x/"'
printf 'file-bytes' > "$WORK/report.txt"
out=$(send --kind show_file --file "$WORK/report.txt" --inline)
has "C file metadata" "$(tail -n 1 "$WORK/sent.log")" '"name": "report.txt", "size": 10, "inline": true'
before=$(wc -l < "$WORK/sent.log")
send --kind show_file --file "$WORK/missing" >/dev/null 2>&1; rc=$?
eq "C missing file refuses before sending" 2 "$rc"
eq "C missing file made no request" "$before" "$(wc -l < "$WORK/sent.log")"
rm -f "$WORK/where.json"
out=$(send --kind open_url --url https://example.com/report)
has "D no client" "$out" '"state": "none"'
mv "$FLEET_CONF_DIR/node.env" "$WORK/node.env.away"
eq "D no hub" '{"state": "nohub"}' "$(send --kind open_url --url https://example.com/report)"
mv "$WORK/node.env.away" "$FLEET_CONF_DIR/node.env"
# --- H. the key: written 0600 by the acquire, never printed ----------------------------
rm -f "$WORK/k"
out=$(env FLEET_HUB_URL="$HUB" FLEET_HUB_TOKEN=CLIENTTOK FLEET_CLIENT_KEY_FILE="$WORK/k" python3 "$BIN/fleet-client-lease.py" acquire --device MacBook 2>&1)
eq "H the key file holds the hub's key" "$KEY" "$(cat "$WORK/k" 2>/dev/null)"
mode=$(python3 -c 'import os, sys; print("%o" % (os.stat(sys.argv[1]).st_mode & 0o777))' "$WORK/k" 2>/dev/null)
eq "H … mode 0600" "600" "$mode"
hasnt "H … and is never printed" "$out" "$KEY"
has "H the lease line as before" "$out" "active	$LEASE"

if [ "$FAIL" -gt 0 ]; then
  printf 'fleet-client-actions selftest: %d of %d checks FAILED\n' "$FAIL" "$CHECKS" >&2
  exit 1
fi
printf 'fleet-client-actions selftest: %d checks passed\n' "$CHECKS"
