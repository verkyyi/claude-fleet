#!/bin/bash
# fleet-account-add-selftest.sh — `fleet account add` (bin/fleet-account-add.sh,
# issue #2084) signs a subscription in, hands it to the hub through
# bin/fleet-creds-import.sh, and keeps no local copy.
#
# Drives the real script through bin/fleet (the dispatcher → fleet-account.sh →
# fleet-account-add.sh) with fake `claude` / `codex` CLIs and a fake hub on
# 127.0.0.1 (python3, alarm-bounded), and asserts:
#   • CLAUDE   setup-token runs, the pasted token is put as pool/claude/<label>
#              with the viewer token as Bearer; nothing lands in the accounts dir
#   • CODEX    `codex login` into a fresh CODEX_HOME, its refresh token put as
#              pool/codex/<label>; ~/.codex-accounts untouched; no «stop
#              refreshing» reminder; a registered ccquota name is NOT consulted;
#              --device-auth over ssh, the browser flow otherwise
#   • GONE     no fleet-account-add.* temp dir survives — success, a bad paste,
#              a failed sign-in or a refused import
#   • QUIET    no token in stdout / stderr
#   • READY    no viewer token / no hub URL → exit 2 BEFORE the CLI runs
#   • USAGE    a bad provider, a bad label, codex `default` → exit 2
#   • FAIL     a hub 400 → exit 1
#
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
FLEET="$BIN/fleet"
[ -x "$BIN/fleet-account-add.sh" ] || { printf 'selftest: fleet-account-add.sh not found / not executable\n' >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 required\n' >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-account-add-selftest.XXXXXX")" || exit 2
HUB_PID=
cleanup() { if [ -n "$HUB_PID" ]; then kill "$HUB_PID" 2>/dev/null; wait "$HUB_PID" 2>/dev/null; fi; rm -rf "$WORK"; }
trap cleanup EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

export HOME="$WORK/home"
export TMPDIR="$WORK/tmp"
export FLEET_CONF_DIR="$HOME/.config/claude-fleet"
export FLEET_ACCOUNTS_DIR="$FLEET_CONF_DIR/accounts"
mkdir -p "$HOME" "$TMPDIR" "$FLEET_ACCOUNTS_DIR" "$HOME/.codex-accounts" "$WORK/fake"
unset SSH_CONNECTION SSH_TTY FLEET_HUB_URL CCQUOTA_VIEWER_TOKEN
TOK='sk-ant-oat01-ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ'
RT='rt-QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ'

# --- fake CLIs: each logs its argv to $WORK/cli.log ---------------------------
cat > "$WORK/fake/claude" <<EOF
#!/bin/bash
printf 'claude %s\n' "\$*" >> "$WORK/cli.log"
[ "\${FAKE_FAIL:-0}" = 1 ] && exit 1
echo 'Your OAuth token (valid for 1 year): (shown here)'
EOF
cat > "$WORK/fake/codex" <<EOF
#!/bin/bash
printf 'codex %s home=%s\n' "\$*" "\$CODEX_HOME" >> "$WORK/cli.log"
[ "\${FAKE_FAIL:-0}" = 1 ] && exit 1
printf '{"tokens":{"refresh_token":"$RT","account_id":"acct-1","id_token":"idt"}}' > "\$CODEX_HOME/auth.json"
EOF
# a ccquota that claims every name lives in ~/.codex — must never be asked
cat > "$WORK/fake/ccquota" <<EOF
#!/bin/bash
printf 'ccquota %s\n' "\$*" >> "$WORK/cli.log"
echo '[{"name":"cx2","home":"$HOME/.codex"}]'
EOF
chmod +x "$WORK/fake/"*
export PATH="$WORK/fake:$PATH"
export FLEET_ACCOUNT_ADD_CLAUDE_BIN="$WORK/fake/claude" FLEET_ACCOUNT_ADD_CODEX_BIN="$WORK/fake/codex"

# --- the fake hub ---------------------------------------------------------------
LOG="$WORK/hub.log"; : > "$LOG"
python3 - "$WORK/port" "$LOG" <<'PY' 2>"$WORK/hub.err" &
import json, signal, socketserver, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
portfile, log = sys.argv[1:3]
signal.alarm(60)
class Hub(HTTPServer):
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = '127.0.0.1', self.server_address[1]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length') or 0)).decode()
        with open(log, 'a') as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get('Authorization', ''), "body": body}) + "\n")
        if json.loads(body).get("account") == "bad":
            self.send_response(400); self.end_headers(); self.wfile.write(b'{"error":"refused"}'); return
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"ok":"put"}')
srv = Hub(('127.0.0.1', 0), H)
open(portfile, 'w').write(str(srv.server_address[1]))
srv.serve_forever()
PY
HUB_PID=$!
i=0
while [ ! -s "$WORK/port" ] && [ "$i" -lt 100 ]; do kill -0 "$HUB_PID" 2>/dev/null || break; sleep 0.2; i=$((i+1)); done
[ -s "$WORK/port" ] || fail "fake hub did not start" "$(cat "$WORK/hub.err" 2>/dev/null)"
HUBURL="http://127.0.0.1:$(cat "$WORK/port")"
# the hub URL the way a machine has it: in fleet.conf, not the environment
printf 'FLEET_HUB_URL="%s"\n' "$HUBURL" > "$FLEET_CONF_DIR/fleet.conf"
mkdir -p "$HOME/.ccquota"; printf 'viewer-SECRET-1\n' > "$HOME/.ccquota/viewer-token"

last() { python3 -c '
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
r=rows[-1]; b=json.loads(r["body"])
print(eval(sys.argv[2], {"r": r, "b": b}))' "$LOG" "$1"; }
nreq() { wc -l < "$LOG" | tr -d ' '; }
gone() { [ -z "$(ls -A "$TMPDIR" 2>/dev/null)" ] || fail "$1: a temp dir survived" "$(ls -la "$TMPDIR")"; }
quiet() { case "$2" in *ZZZZZZZZZZ*|*QQQQQQQQQQ*|*viewer-SECRET*) fail "$1: a secret leaked into the output" "$2" ;; esac; }

# --- CLAUDE ------------------------------------------------------------------
out=$(printf '%s\n' "$TOK" | bash "$FLEET" account add --provider claude --label max-e 2>&1); rc=$?
[ "$rc" = 0 ] || fail "CLAUDE: exit $rc" "$out"
grep -q '^claude setup-token$' "$WORK/cli.log" || fail "CLAUDE: setup-token did not run" "$(cat "$WORK/cli.log")"
[ "$(nreq)" = 1 ] || fail "CLAUDE: expected 1 request, got $(nreq)"
[ "$(last 'r["path"]')" = /v1/fleet/credentials ] || fail "CLAUDE: path"
[ "$(last 'r["auth"]')" = 'Bearer viewer-SECRET-1' ] || fail "CLAUDE: auth"
[ "$(last 'b["provider"]+"/"+b["account"]+"/"+b["principal_id"]')" = claude/max-e/pool ] || fail "CLAUDE: body" "$(cat "$LOG")"
[ "$(last 'b["secret"]["setup_token"]')" = "$TOK" ] || fail "CLAUDE: token"
[ -z "$(ls -A "$FLEET_ACCOUNTS_DIR")" ] || fail "CLAUDE: something landed in the accounts dir" "$(ls -la "$FLEET_ACCOUNTS_DIR")"
gone CLAUDE; quiet CLAUDE "$out"
case "$out" in *'3/3'*) ;; *) fail "CLAUDE: no removal line" "$out" ;; esac
ok "CLAUDE: one command → setup-token, put pool/claude/max-e, no local copy, no token printed"

# a bad paste: nothing sent, nothing kept
n0=$(nreq)
out=$(printf 'not-a-token\n' | bash "$FLEET" account add --provider claude --label max-f 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$(nreq)" = "$n0" ] || fail "CLAUDE bad paste: rc=$rc requests $(nreq)" "$out"
gone "CLAUDE bad paste"
# a failed sign-in
out=$(FAKE_FAIL=1 bash "$FLEET" account add --provider claude --label max-f </dev/null 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$(nreq)" = "$n0" ] || fail "CLAUDE failed login: rc=$rc" "$out"
gone "CLAUDE failed login"
# a refused import
out=$(printf '%s\n' "$TOK" | bash "$FLEET" account add --provider claude --label bad 2>&1); rc=$?
[ "$rc" = 1 ] || fail "FAIL: hub 400 should exit 1, got $rc" "$out"
gone FAIL; quiet FAIL "$out"
ok "GONE/FAIL: a bad paste, a failed sign-in, a refused import → exit 1, nothing kept"

# --- CODEX ------------------------------------------------------------------
: > "$WORK/cli.log"
out=$(bash "$FLEET" account add --provider codex --label cx2 2>&1 </dev/null); rc=$?
[ "$rc" = 0 ] || fail "CODEX: exit $rc" "$out"
grep -q '^codex login home=.*/codex/cx2$' "$WORK/cli.log" || fail "CODEX: browser login into a temp home" "$(cat "$WORK/cli.log")"
grep -q '^ccquota' "$WORK/cli.log" && fail "CODEX: ccquota was consulted" "$(cat "$WORK/cli.log")"
[ "$(last 'b["provider"]+"/"+b["account"]+"/"+b["principal_id"]')" = codex/cx2/pool ] || fail "CODEX: body" "$(tail -1 "$LOG")"
[ "$(last 'b["secret"]["refresh_token"]')" = "$RT" ] || fail "CODEX: refresh token"
[ -z "$(ls -A "$HOME/.codex-accounts")" ] && [ ! -e "$HOME/.codex" ] || fail "CODEX: a codex home was touched"
case "$out" in *'stop refreshing'*) fail "CODEX: the holder reminder printed" "$out" ;; esac
gone CODEX; quiet CODEX "$out"
: > "$WORK/cli.log"
out=$(SSH_CONNECTION='1 2 3 4' bash "$FLEET" account add --provider codex --label cx3 2>&1 </dev/null); rc=$?
[ "$rc" = 0 ] && grep -q '^codex login --device-auth ' "$WORK/cli.log" || fail "CODEX: --device-auth over ssh" "$out$(cat "$WORK/cli.log")"
gone "CODEX ssh"
ok "CODEX: codex login in a temp home → put pool/codex/cx2, no ccquota, no reminder, device-auth over ssh"

# --- READY / USAGE: refused before any CLI runs --------------------------------
: > "$WORK/cli.log"; n0=$(nreq)
mv "$HOME/.ccquota/viewer-token" "$WORK/vt"
out=$(bash "$FLEET" account add --provider claude --label max-g 2>&1 </dev/null); rc=$?
[ "$rc" = 2 ] || fail "READY: no viewer token should exit 2, got $rc" "$out"
mv "$WORK/vt" "$HOME/.ccquota/viewer-token"
mv "$FLEET_CONF_DIR/fleet.conf" "$WORK/fc"
out=$(bash "$FLEET" account add --provider claude --label max-g 2>&1 </dev/null); rc=$?
[ "$rc" = 2 ] || fail "READY: no hub URL should exit 2, got $rc" "$out"
mv "$WORK/fc" "$FLEET_CONF_DIR/fleet.conf"
for a in "--provider gemini --label x" "--provider claude --label .dot" "--provider claude --label a/b" \
         "--provider codex --label default" "--label x" "--provider claude"; do
  # shellcheck disable=SC2086
  bash "$FLEET" account add $a </dev/null >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] || fail "USAGE: '$a' should exit 2, got $rc"
done
[ ! -s "$WORK/cli.log" ] && [ "$(nreq)" = "$n0" ] || fail "READY/USAGE: a CLI ran or a request went out" "$(cat "$WORK/cli.log")"
gone READY
ok "READY/USAGE: no token / no hub / bad args → exit 2 before any sign-in"

printf 'PASS fleet-account-add-selftest (%d checks)\n' "$pass"
