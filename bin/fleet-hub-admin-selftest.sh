#!/usr/bin/env bash
# fleet-hub-admin-selftest.sh — `fleet users …` and `fleet hub set|get|unset|
# settings` (bin/fleet-hub-admin.py, claude-fleet#1986) against a fake hub on
# 127.0.0.1: the request each sends (method, path, body, credential), what it
# prints, and its exit codes. Reached through bin/fleet (fleet users) and
# bin/fleet-hub.py (fleet hub set …), the way a person types them.
#
#   A  no credential → exit 3, nothing sent
#   B  fleet users add alice --machine-login alice2 → POST {login, machine_login}, Bearer
#   C  a refusal (GitHub has no such user) → exit 1, the hub's reason on stderr
#   D  fleet users remove alice → DELETE ?login=alice; devices revoked printed
#   E  fleet hub set pool.skip_pct 90 → PUT {key, value}; prints the new value
#   F  fleet hub get / unset / settings
#   G  FLEET_HUB_SESSION → the ccq_sess cookie, no bearer
#   H  no hub configured → exit 3
set -u
BIN=$(cd "$(dirname "$0")" && pwd -P)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/hub-admin-selftest.XXXXXX")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $*"; }

LOG="$WORK/requests.ndjson"; PORTF="$WORK/port"
# The fake hub: answers like /v1/fleet/users and /v1/fleet/settings, logs each
# request. alarm(60) bounds it even if this script is killed.
# Written to a file and run from it: a heredoc on a backgrounded command is
# not something bash 3.2 (macOS) can be trusted with.
cat > "$WORK/hub.py" <<'PY'
import json, os, signal, socketserver, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
signal.alarm(60)
log, portf = sys.argv[1], sys.argv[2]
settings = {}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def answer(self, code, body):
        raw = json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw))); self.end_headers(); self.wfile.write(raw)
    def handle_any(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() if n else ""
        u = urlparse(self.path)
        with open(log, "a") as f:
            f.write(json.dumps({"method": self.command, "path": u.path, "query": u.query, "body": body,
                                "auth": self.headers.get("Authorization", ""),
                                "cookie": self.headers.get("Cookie", "")}) + "\n")
        users = {"users": [{"github_id": 100, "login": "verkyyi", "role": "admin", "deploy": True}], "admins": []}
        if u.path == "/v1/fleet/users":
            if self.command == "POST":
                b = json.loads(body)
                if b["login"] == "ghost":
                    return self.answer(400, {"error": "GitHub has no user named ghost — nobody was added"})
                if b.get("machine_login") == "24haowan":
                    return self.answer(200, dict(users, added=b["login"], github_id=300, created=False,
                                                 moved_login={"login": "24haowan", "hosts": ["macmini"],
                                                              "from": "CaoJian", "to": "gh:300"}))
                return self.answer(201, dict(users, added=b["login"], github_id=200, created=True))
            if self.command == "DELETE":
                return self.answer(200, dict(users, removed=parse_qs(u.query)["login"][0], github_id=200, devices_revoked=2))
            return self.answer(200, users)
        if u.path == "/v1/fleet/accounts":
            if self.command == "POST":
                b = json.loads(body)
                if b.get("action") == "rekey":
                    return self.answer(200, {"from": b["principal_id"], "to": "gh:" + b["to_principal_id"].replace("gh:", ""),
                                             "login": "zx", "hosts": ["macmini", "mini2"], "moved": {}})
                return self.answer(200, {"accounts": []})
            return self.answer(200, {"principals": [{"principal_id": "zx", "login": "zx", "display_name": ""}],
                                     "accounts": [{"principal_id": "zx", "hostname": "macmini", "state": "active"}]})
        if u.path == "/v1/fleet/settings":
            if self.command == "PUT":
                b = json.loads(body)
                if b["value"]:
                    settings[b["key"]] = b["value"]
                else:
                    settings.pop(b["key"], None)
            hub = [{"key": "pool.skip_pct", "value": settings.get("pool.skip_pct", "85"),
                    "source": "set" if "pool.skip_pct" in settings else "default"}]
            return self.answer(200, {"settings": settings, "hub": hub})
        self.answer(404, {"error": "no such route"})
    do_GET = do_POST = do_PUT = do_DELETE = handle_any
class Server(HTTPServer):
    # HTTPServer.server_bind asks socket.getfqdn() — a reverse-DNS lookup
    # that stalls for tens of seconds on a macOS CI runner. Not needed here.
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "127.0.0.1", self.server_address[1]
s = Server(("127.0.0.1", 0), H)
with open(portf + ".tmp", "w") as f:
    f.write(str(s.server_address[1]))
os.rename(portf + ".tmp", portf)
s.serve_forever()
PY
python3 "$WORK/hub.py" "$LOG" "$PORTF" 2>"$WORK/hub.err" &
HUBPID=$!
trap 'kill "$HUBPID" 2>/dev/null; wait "$HUBPID" 2>/dev/null; rm -rf "$WORK"' EXIT
# up to 15s: a busy CI runner can take seconds to start python3
python3 - "$PORTF" <<'PY'
import os, sys, time
end = time.time() + 15
while time.time() < end and not (os.path.exists(sys.argv[1]) and os.path.getsize(sys.argv[1]) > 0):
    time.sleep(0.05)
PY
[ -s "$PORTF" ] || { echo "FAIL the fake hub did not start: $(cat "$WORK/hub.err" 2>/dev/null)"; exit 1; }
HUB="http://127.0.0.1:$(cat "$PORTF")"

# a clean environment: no operator config, the fake hub only
run() { env -i PATH="$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" XDG_CONFIG_HOME="$WORK/xdg" "$@"; }
last() { tail -n 1 "$LOG" 2>/dev/null; }
field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2], ""))' "$1" "$2"; }

# A — no credential
run FLEET_HUB_URL="$HUB" "$BIN/fleet" users list >"$WORK/out" 2>"$WORK/err"; rc=$?
if [ "$rc" = 3 ] && [ ! -s "$LOG" ] && grep -q 'no credential' "$WORK/err"; then ok "A no credential → exit 3, nothing sent"
else bad "A rc=$rc err=$(cat "$WORK/err")"; fi

# B — add, with a machine login
run FLEET_HUB_URL="$HUB" CCQUOTA_VIEWER_TOKEN=tok "$BIN/fleet" users add alice --machine-login alice2 >"$WORK/out" 2>"$WORK/err"; rc=$?
r=$(last)
if [ "$rc" = 0 ] && [ "$(field "$r" method)" = POST ] && [ "$(field "$r" path)" = /v1/fleet/users ] \
   && [ "$(field "$r" auth)" = "Bearer tok" ] \
   && [ "$(field "$r" body)" = '{"login": "alice", "machine_login": "alice2"}' ] \
   && grep -q 'added alice (GitHub ID 200)' "$WORK/out" && grep -q 'verkyyi' "$WORK/out"; then
  ok "B fleet users add → POST {login, machine_login} with the token; prints the list"
else bad "B rc=$rc req=$r out=$(cat "$WORK/out") err=$(cat "$WORK/err")"; fi

# C — a refusal
run FLEET_HUB_URL="$HUB" CCQUOTA_VIEWER_TOKEN=tok "$BIN/fleet" users add ghost >"$WORK/out" 2>"$WORK/err"; rc=$?
if [ "$rc" = 1 ] && grep -q 'answered 400: GitHub has no user named ghost' "$WORK/err"; then ok "C a refusal → exit 1 with the hub's reason"
else bad "C rc=$rc err=$(cat "$WORK/err")"; fi

# D — remove
run FLEET_HUB_URL="$HUB" CCQUOTA_VIEWER_TOKEN=tok "$BIN/fleet-users.py" remove alice >"$WORK/out" 2>"$WORK/err"; rc=$?
r=$(last)
if [ "$rc" = 0 ] && [ "$(field "$r" method)" = DELETE ] && [ "$(field "$r" query)" = login=alice ] \
   && grep -q '2 device(s) revoked' "$WORK/out"; then ok "D fleet users remove → DELETE ?login=; devices revoked printed"
else bad "D rc=$rc req=$r out=$(cat "$WORK/out")"; fi

# E — fleet hub set, through bin/fleet-hub.py's forward
run FLEET_HUB_URL="$HUB" CCQUOTA_VIEWER_TOKEN=tok python3 "$BIN/fleet-hub.py" set pool.skip_pct 90 >"$WORK/out" 2>"$WORK/err"; rc=$?
r=$(last)
if [ "$rc" = 0 ] && [ "$(field "$r" method)" = PUT ] && [ "$(field "$r" body)" = '{"key": "pool.skip_pct", "value": "90"}' ] \
   && [ "$(cat "$WORK/out")" = 'pool.skip_pct = 90' ]; then ok "E fleet hub set → PUT {key, value}; prints the value now"
else bad "E rc=$rc req=$r out=$(cat "$WORK/out") err=$(cat "$WORK/err")"; fi

# F — get, unset, settings
g=$(run FLEET_HUB_URL="$HUB" CCQUOTA_VIEWER_TOKEN=tok "$BIN/fleet" hub get pool.skip_pct 2>&1)
u=$(run FLEET_HUB_URL="$HUB" CCQUOTA_VIEWER_TOKEN=tok "$BIN/fleet" hub unset pool.skip_pct 2>&1)
l=$(run FLEET_HUB_URL="$HUB" CCQUOTA_VIEWER_TOKEN=tok "$BIN/fleet" hub settings 2>&1)
if [ "$g" = 90 ] && [ "$u" = 'pool.skip_pct = 85' ] && printf '%s\n' "$l" | grep -q '^pool.skip_pct  default  85$'; then
  ok "F fleet hub get / unset / settings"
else bad "F get=$g unset=$u settings=$l"; fi

# G — the session cookie instead of the token
run FLEET_HUB_URL="$HUB" FLEET_HUB_SESSION=sessval "$BIN/fleet" users list >"$WORK/out" 2>"$WORK/err"; rc=$?
r=$(last)
if [ "$rc" = 0 ] && [ "$(field "$r" cookie)" = ccq_sess=sessval ] && [ -z "$(field "$r" auth)" ]; then
  ok "G FLEET_HUB_SESSION → the ccq_sess cookie, no bearer"
else bad "G rc=$rc req=$r"; fi

# H — no hub anywhere
run CCQUOTA_VIEWER_TOKEN=tok "$BIN/fleet" users list >"$WORK/out" 2>"$WORK/err"; rc=$?
if [ "$rc" = 3 ] && grep -q 'no hub configured' "$WORK/err"; then ok "H no hub → exit 3"
else bad "H rc=$rc err=$(cat "$WORK/err")"; fi

# I — add onto a login an old identity held (claude-fleet#2094): the move is printed
run FLEET_HUB_URL="$HUB" CCQUOTA_VIEWER_TOKEN=tok "$BIN/fleet" users add cjilyy --machine-login 24haowan >"$WORK/out" 2>"$WORK/err"; rc=$?
if [ "$rc" = 0 ] && grep -q '已把 24haowan（macmini）从旧身份 CaoJian 转给 cjilyy' "$WORK/out"; then
  ok "I users add onto an old identity's login → the move is printed"
else bad "I rc=$rc out=$(cat "$WORK/out") err=$(cat "$WORK/err")"; fi

# J — fleet hub accounts rekey / list (through bin/fleet-hub.py's forward)
run FLEET_HUB_URL="$HUB" CCQUOTA_VIEWER_TOKEN=tok python3 "$BIN/fleet-hub.py" accounts rekey zx 4001 >"$WORK/out" 2>"$WORK/err"; rc=$?
r=$(last)
l=$(run FLEET_HUB_URL="$HUB" CCQUOTA_VIEWER_TOKEN=tok python3 "$BIN/fleet-hub.py" accounts 2>&1)
if [ "$rc" = 0 ] && [ "$(field "$r" method)" = POST ] && [ "$(field "$r" path)" = /v1/fleet/accounts ] \
   && [ "$(field "$r" body)" = '{"action": "rekey", "principal_id": "zx", "to_principal_id": "4001"}' ] \
   && grep -q '已把 zx（macmini、mini2）从旧身份 zx 转给 gh:4001' "$WORK/out" \
   && printf '%s\n' "$l" | grep -q '^zx .*macmini:active$'; then
  ok "J fleet hub accounts rekey → POST {action: rekey}; accounts lists the records"
else bad "J rc=$rc req=$r out=$(cat "$WORK/out") err=$(cat "$WORK/err") list=$l"; fi

echo "fleet-hub-admin-selftest: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
