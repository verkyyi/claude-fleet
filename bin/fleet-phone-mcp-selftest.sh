#!/bin/bash
# fleet-phone-mcp-selftest.sh — pins issue #3247: the person's phone MCP runs
# ONCE (bin/fleet-phone-mcp.py serve, as the admin login) behind a Bearer proxy,
# and every one of their logins reaches it over the tailnet.
#
#   A  the proxy: no / a wrong token ⇒ 401 (and the upstream never sees it);
#      the right one ⇒ the upstream's answer, the token NOT passed on; a path
#      other than /mcp ⇒ 404
#   B  a streamed (SSE) answer comes through whole, re-chunked
#   C  rotate: the old token keeps working for --grace, then is refused; the
#      proxy reads the new book without a restart
#   D  a wildcard bind is refused
#   E  client set: Codex's config.toml gains ONE marked table (before the fleet
#      plugins block), every other line byte for byte, an older
#      [mcp_servers.phone] replaced; a second run changes nothing; unset puts
#      the file back; Claude is set by `mcp add-json` with a headersHelper —
#      never the token in argv; `client header` prints it; no token ⇒ exit 2
#   F  the token never reaches the proxy's log or `status`
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
PM="$BIN/fleet-phone-mcp.py"
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/  /' >&2; exit 1; }
ok() { CHECKS=$((CHECKS+1)); }
eq() { [ "$2" = "$3" ] || fail "$1" "want: [$2]
 got: [$3]"; ok; }
has() { case "$3" in *"$2"*) ok ;; *) fail "$1" "want a substring: [$2]
 got: [$3]" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail "$1" "must not contain: [$2]
 got: [$3]" ;; *) ok ;; esac; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-phone-selftest.XXXXXX") || exit 2
WORK="$(cd "$WORK" && pwd -P)"
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; done; [ -n "${KEEP:-}" ] || rm -rf "$WORK"; }
trap cleanup EXIT

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
UP=$(free_port); PX=$(free_port)

# a stand-in for mcp-server-mobile: echoes whether it saw an Authorization
# header; /mcp/sse streams three events with no Content-Length
cat > "$WORK/up.py" <<'PY'
import http.server, json, sys, time
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        if self.path == "/mcp/sse":
            self.send_response(200); self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
            for i in range(3):
                d = b"data: ev%d\n\n" % i
                self.wfile.write(b"%x\r\n%s\r\n" % (len(d), d)); self.wfile.flush(); time.sleep(0.05)
            self.wfile.write(b"0\r\n\r\n"); return
        out = json.dumps({"auth_seen": "Authorization" in self.headers, "echo": body.decode()}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
python3 "$WORK/up.py" "$UP" & PIDS="$PIDS $!"
export FLEET_PHONE_DIR="$WORK/srv"
python3 "$PM" serve --no-child --bind 127.0.0.1 --port "$PX" --up-port "$UP" 2>"$WORK/px.log" & PIDS="$PIDS $!"
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PX/" 2>/dev/null && break; sleep 0.1
done
TOK=$(python3 "$PM" token) || fail "token prints the minted token"
[ "${#TOK}" -ge 32 ] || fail "a token of at least 32 chars" "$TOK"; ok
eq "the book is 0600" "600" "$(stat -f %Lp "$FLEET_PHONE_DIR/tokens.json" 2>/dev/null || stat -c %a "$FLEET_PHONE_DIR/tokens.json")"

post() {  # post <path> [token] → "<code> <body>"
  local h=()
  [ -n "${2:-}" ] && h=(-H "Authorization: Bearer $2")
  curl -s -w ' %{http_code}' -X POST ${h[@]+"${h[@]}"} -H 'Content-Type: application/json' \
    -d '{"q":1}' "http://127.0.0.1:$PX$1"
}

# --- A
has "A: no token ⇒ 401" " 401" "$(post /mcp)"
has "A: a wrong token ⇒ 401" " 401" "$(post /mcp wrong-token)"
R=$(post /mcp "$TOK")
has "A: the right token ⇒ 200" " 200" "$R"
has "A: the upstream's answer comes through" '"echo": "{\"q\":1}"' "$R"
has "A: the token is not passed on" '"auth_seen": false' "$R"
has "A: another path ⇒ 404" " 404" "$(post /other "$TOK")"

# --- B
R=$(post /mcp/sse "$TOK")
has "B: a stream comes through whole" "data: ev0

data: ev1

data: ev2" "$R"
has "B: … with its status" " 200" "$R"

# --- C
python3 "$PM" rotate --grace 2 >/dev/null || fail "rotate exits 0"
NEW=$(python3 "$PM" token)
[ "$NEW" != "$TOK" ] || fail "rotate mints a new token"; ok
has "C: the new token works at once" " 200" "$(post /mcp "$NEW")"
has "C: the old one still works inside the grace" " 200" "$(post /mcp "$TOK")"
sleep 3
has "C: the old one is refused after the grace" " 401" "$(post /mcp "$TOK")"
has "C: the new one still works" " 200" "$(post /mcp "$NEW")"

# --- D
OUT=$(python3 "$PM" serve --no-child --bind 0.0.0.0 --port "$(free_port)" 2>&1); RC=$?
[ "$RC" -ne 0 ] || fail "D: a wildcard bind exits non-zero"; ok
has "D: … and says why" "refusing to bind" "$OUT"

# --- E
export CODEX_HOME="$WORK/codex"; mkdir -p "$CODEX_HOME"
cat > "$CODEX_HOME/config.toml" <<'TOML'
model_reasoning_effort = "high"

[mcp_servers.phone]
command = "/Users/x/bin/phone-mcp"

[mcp_servers.phone.env]
A = "1"

[mcp_servers.context7]
command = "npx"
# >>> fleet plugins — bin/fleet-codex-plugins.py sync writes this block; edit outside it >>>
[mcp_servers.fleet-orch]
command = "bash"
# <<< fleet plugins <<<
TOML
cat > "$WORK/fake-claude" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/claude.argv"
SH
chmod +x "$WORK/fake-claude"
export FLEET_PHONE_DIR="$WORK/cl"
URL="http://mini2.example:47230/mcp"
eq "E: no token on stdin ⇒ exit 2" "2" "$(python3 "$PM" client set --url "$URL" --claude "$WORK/fake-claude" </dev/null >/dev/null 2>&1; echo $?)"
printf '%s\n' "$NEW" | python3 "$PM" client set --url "$URL" --claude "$WORK/fake-claude" >/dev/null || fail "E: client set exits 0"
C=$(cat "$CODEX_HOME/config.toml")
WANT='model_reasoning_effort = "high"

[mcp_servers.context7]
command = "npx"
# >>> fleet phone >>>
[mcp_servers.phone]
url = "http://mini2.example:47230/mcp"
http_headers = { "Authorization" = "Bearer '"$NEW"'" }
# <<< fleet phone <<<
# >>> fleet plugins — bin/fleet-codex-plugins.py sync writes this block; edit outside it >>>
[mcp_servers.fleet-orch]
command = "bash"
# <<< fleet plugins <<<'
eq "E: config.toml — one marked table before the plugins block, the rest byte for byte" "$WANT" "$C"
printf '%s\n' "$NEW" | python3 "$PM" client set --url "$URL" --claude "$WORK/fake-claude" >/dev/null
eq "E: a second run changes nothing" "$WANT" "$(cat "$CODEX_HOME/config.toml")"
A=$(cat "$WORK/claude.argv")
has "E: claude: the old phone removed first" "mcp remove phone -s user" "$A"
has "E: claude: added as http with a headersHelper" '"type": "http", "url": "http://mini2.example:47230/mcp", "headersHelper":' "$A"
hasnt "E: claude: never the token in argv" "$NEW" "$A"
eq "E: client header prints the bearer" "{\"Authorization\": \"Bearer $NEW\"}" "$(python3 "$PM" client header)"
eq "E: client.json is 0600" "600" "$(stat -f %Lp "$FLEET_PHONE_DIR/client.json" 2>/dev/null || stat -c %a "$FLEET_PHONE_DIR/client.json")"
python3 "$PM" client unset --claude "$WORK/fake-claude" >/dev/null
C=$(cat "$CODEX_HOME/config.toml")
hasnt "E: unset takes the table out" "mcp_servers.phone" "$C"
has "E: … and leaves the rest" "[mcp_servers.context7]" "$C"
eq "E: unset removes client.json" "no" "$([ -e "$FLEET_PHONE_DIR/client.json" ] && echo yes || echo no)"

# --- F
export FLEET_PHONE_DIR="$WORK/srv"
S=$(python3 "$PM" status --port "$PX" --up-port "$UP")
has "F: status sees the proxy" "127.0.0.1:$PX up" "$S"
hasnt "F: status never prints the token" "$NEW" "$S"
L=$(cat "$WORK/px.log")
has "F: a refusal is logged" "denied 127.0.0.1 POST /mcp" "$L"
hasnt "F: the log never carries a token (new)" "$NEW" "$L"
hasnt "F: the log never carries a token (old)" "$TOK" "$L"

echo "fleet-phone-mcp-selftest: PASS ($CHECKS checks)"
