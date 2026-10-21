#!/usr/bin/env bash
# fleet-console-ticket-selftest.sh — bin/fleet-console-ticket.sh (task T844):
# a session asks the hub, as itself, for a one-time read-only link into its
# person's /app. The hub is a fake on 127.0.0.1 (one python process, gone with
# the test); the hub half — owner only, one use, reads only, an admin's a
# member's, audited — is the Go gate's: TestConsoleTicket* (console_ticket_test.go).
#
#   A. no assertion      FLEET_WORKER_ASSERT empty, no worker credential: exit 4,
#                        the hub never asked
#   B. no node token     no node.env: exit 3, nothing on stdout
#   C. granted           POST /v1/node/console-ticket with the node token as the
#                        bearer AND X-Fleet-Worker, body {next, ttl_sec}; stdout
#                        = the link, one line; the token never on stdout
#   D. refused           a 403 → exit 1, the hub's words on stderr, nothing on stdout
#   E. usage             --next outside /app, a bad --ttl: exit 2, the hub never asked
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/fct-selftest.XXXXXX")
fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

cat > "$T/hub.py" <<'PY'
import http.server, json, os, sys
log = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode()
        with open(log, "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization", ""),
                                "worker": self.headers.get("X-Fleet-Worker", ""), "body": body}) + "\n")
        if os.path.exists(log + ".refuse"):
            out, code = {"error": "no active fleet account is nobody on box"}, 403
        else:
            out, code = {"url": "http://127.0.0.1/auth/ticket?t=fct1.abc.def", "path": "/auth/ticket?t=fct1.abc.def",
                         "id": "ct_1", "person": "gh:1", "session_ttl_sec": 900}, 200
        b = json.dumps(out).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(log + ".port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 -I "$T/hub.py" "$T/calls" &
HUBPID=$!
cleanup() { kill "$HUBPID" 2>/dev/null; wait "$HUBPID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
for _ in $(seq 1 50); do [ -s "$T/calls.port" ] && break; sleep 0.1; done
PORT=$(cat "$T/calls.port" 2>/dev/null)
[ -n "$PORT" ] || { echo "FAIL the fake hub did not start"; exit 1; }

C="$T/conf"; mkdir -p "$C"
run() { env -u FLEET_WORKER_CRED FLEET_CONF_DIR="$C" FLEET_HUB_URL= "$@"; }
calls() { [ -f "$T/calls" ] && wc -l < "$T/calls" | tr -d ' ' || echo 0; }

# A
out=$(run FLEET_WORKER_ASSERT= bash "$BIN/fleet-console-ticket.sh" 2>/dev/null); rc=$?
[ "$rc" = 4 ] && [ -z "$out" ] && [ "$(calls)" = 0 ] && ok "A no assertion: exit 4" || bad "A rc=$rc out=$out calls=$(calls)"

# B
out=$(run FLEET_WORKER_ASSERT=fwa1.x.y bash "$BIN/fleet-console-ticket.sh" 2>/dev/null); rc=$?
[ "$rc" = 3 ] && [ -z "$out" ] && [ "$(calls)" = 0 ] && ok "B no node token: exit 3" || bad "B rc=$rc out=$out"

# C
printf 'CCQUOTA_HUB_URL=http://127.0.0.1:%s\nCCQUOTA_TOKEN=tok-secret\n' "$PORT" > "$C/node.env"
out=$(run FLEET_WORKER_ASSERT=fwa1.x.y bash "$BIN/fleet-console-ticket.sh" --next /app/sessions --ttl 600); rc=$?
last=$(tail -n 1 "$T/calls" 2>/dev/null)
if [ "$rc" = 0 ] && [ "$out" = "http://127.0.0.1:$PORT/auth/ticket?t=fct1.abc.def" ] && ! printf '%s' "$out" | grep -q tok-secret &&
   printf '%s' "$last" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); b=json.loads(d["body"]);
sys.exit(0 if d["path"]=="/v1/node/console-ticket" and d["auth"]=="Bearer tok-secret" and d["worker"]=="fwa1.x.y" and b=={"next":"/app/sessions","ttl_sec":600} else 1)'; then
  ok "C granted: the link, token + assertion sent"
else
  bad "C rc=$rc out=$out last=$last"
fi
out=$(run FLEET_WORKER_ASSERT=fwa1.x.y bash "$BIN/fleet-console-ticket.sh" --json); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q '"id": "ct_1"' && ok "C --json: the whole answer" || bad "C --json rc=$rc out=$out"

# D
: > "$T/calls.refuse"
err=$(run FLEET_WORKER_ASSERT=fwa1.x.y bash "$BIN/fleet-console-ticket.sh" 2>&1 >/dev/null); rc=$?
out=$(run FLEET_WORKER_ASSERT=fwa1.x.y bash "$BIN/fleet-console-ticket.sh" 2>/dev/null)
[ "$rc" = 1 ] && [ -z "$out" ] && printf '%s' "$err" | grep -q '403: no active fleet account' && ok "D refused: exit 1, the hub's words" || bad "D rc=$rc err=$err out=$out"
rm -f "$T/calls.refuse"

# E
n=$(calls)
run FLEET_WORKER_ASSERT=fwa1.x.y bash "$BIN/fleet-console-ticket.sh" --next https://evil/app >/dev/null 2>&1; r1=$?
run FLEET_WORKER_ASSERT=fwa1.x.y bash "$BIN/fleet-console-ticket.sh" --ttl 9m >/dev/null 2>&1; r2=$?
[ "$r1" = 2 ] && [ "$r2" = 2 ] && [ "$(calls)" = "$n" ] && ok "E usage: exit 2, the hub never asked" || bad "E r1=$r1 r2=$r2"

exit "$fail"
