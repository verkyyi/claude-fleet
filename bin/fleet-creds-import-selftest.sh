#!/bin/bash
# fleet-creds-import-selftest.sh — bin/fleet-creds-import.sh puts this machine's
# setup-tokens into the hub vault as pool accounts (issue #1463) without the
# token ever appearing anywhere but the request body.
#
# Drives the real script against a fake hub on 127.0.0.1 (python3, one-shot,
# alarm-bounded so it cannot leak) and asserts:
#   • BODY      one `put` per plain setup-token file: principal "pool", provider
#               claude, account = label, secret.setup_token = the file's token,
#               secret.expires_at = mtime + 365d
#   • AUTH      the viewer token rides as a Bearer header
#   • SKIP      a `hub:` marker, a non-setup-token file, .conf / dotfiles / a
#               directory are skipped and named, and are not failures
#   • QUIET     stdout + stderr never contain a token — on success OR failure
#   • GIVEN     --expires-at and --principal are sent as given, for the named
#               label only
#   • DRY       --dry-run sends nothing
#   • FAIL      a hub 400 → exit 1, the hub's message shown
#   • NOAUTH    no viewer token → exit 2, nothing sent
#   • UUID      (issue #2127) one label sends this login's oauthAccount.accountUuid
#               as secret.account_uuid and names it; --account-uuid as given,
#               `none` none; several labels none; --account-uuid needs one label
#   • CODEX     --codex reads ~/.codex/auth.json (tokens.refresh_token +
#               account_id + id_token) into one `put` of pool/codex/default; a
#               named profile reads <codex-homes>/<profile>/auth.json under its
#               own label; a `hub-managed` home is skipped; --dry-run sends
#               nothing; no token in the output; --expires-at is refused
#   • BYNAME    (issue #1666) a name ccquota has registered resolves through
#               `ccquota codex list --json`: a profile living in ~/.codex
#               imports under the hub label `default` and the mapping is shown;
#               one at <codex-homes>/<name> keeps its label; a put is followed
#               by the stop-refreshing reminder; without ccquota (or an
#               unregistered name) the <codex-homes>/<name> rule is byte for byte
#
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
IMPORT="$BIN/fleet-creds-import.sh"
[ -f "$IMPORT" ] || { printf 'selftest: %s not found\n' "$IMPORT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 required\n' >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-creds-import-selftest.XXXXXX")" || exit 2
HUB_PID=
cleanup() { if [ -n "$HUB_PID" ]; then kill "$HUB_PID" 2>/dev/null; wait "$HUB_PID" 2>/dev/null; fi; rm -rf "$WORK"; }
trap cleanup EXIT

pass=0

export TMPDIR="$WORK"
export HOME="$WORK/home"
export FLEET_ACCOUNTS_DIR="$WORK/accounts"
mkdir -p "$HOME" "$FLEET_ACCOUNTS_DIR/hubbed.hub"
TOK_A='sk-ant-oat01-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
TOK_B='sk-ant-oat01-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
printf '%s\n' "$TOK_A" > "$FLEET_ACCOUNTS_DIR/alpha"
printf '%s\n' "$TOK_B" > "$FLEET_ACCOUNTS_DIR/beta"
printf 'hub:hubbed\n'  > "$FLEET_ACCOUNTS_DIR/hubbed"
printf 'tok-plain\n'   > "$FLEET_ACCOUNTS_DIR/weird"
printf 'CCQUOTA_ACCOUNT="x"\n' > "$FLEET_ACCOUNTS_DIR/alpha.conf"
printf 'x\n' > "$FLEET_ACCOUNTS_DIR/.dot"
chmod 600 "$FLEET_ACCOUNTS_DIR"/alpha "$FLEET_ACCOUNTS_DIR"/beta
# A known mtime, so the default expiry is checkable: 2026-01-01T00:00:00Z.
touch -t 202601010000 "$FLEET_ACCOUNTS_DIR/alpha" "$FLEET_ACCOUNTS_DIR/beta"
# touch -t is local time; read the real epoch back for the assertion.
MT=$(python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$FLEET_ACCOUNTS_DIR/alpha")

# --- the fake hub: records every request as one JSON line --------------------
LOG="$WORK/hub.log"; : > "$LOG"
python3 - "$WORK/port" "$LOG" <<'PY' 2>"$WORK/hub.err" &
import json, signal, socketserver, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
portfile, log = sys.argv[1:3]
signal.alarm(60)  # cannot outlive the test
class Hub(HTTPServer):
    # HTTPServer.server_bind resolves the host with socket.getfqdn(), which on a
    # macOS CI runner can stall for longer than this whole test (reverse DNS of
    # 127.0.0.1). Bind without it: the name is never used here.
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = '127.0.0.1', self.server_address[1]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(n).decode()
        with open(log, 'a') as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get('Authorization', ''), "body": body}) + "\n")
        try:
            acct = json.loads(body).get("account")
        except ValueError:
            acct = None
        if acct == "bad":
            self.send_response(400); self.end_headers()
            self.wfile.write(b'{"error":"claude setup_token must be the sk-ant-oat01-\xe2\x80\xa6 token"}')
            return
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"ok":"put"}')
srv = Hub(('127.0.0.1', 0), H)
with open(portfile, 'w') as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PY
HUB_PID=$!
# A cold python3 on a CI macOS runner takes seconds to get here: wait up to 20s.
i=0
while [ ! -s "$WORK/port" ] && [ "$i" -lt 100 ]; do
  kill -0 "$HUB_PID" 2>/dev/null || break
  sleep 0.2; i=$((i+1))
done
[ -s "$WORK/port" ] || st_fail "fake hub did not start" "$(cat "$WORK/hub.err" 2>/dev/null)"
CCQUOTA_HUB_URL="http://127.0.0.1:$(cat "$WORK/port")"
export CCQUOTA_HUB_URL
export CCQUOTA_VIEWER_TOKEN='viewer-SECRET-1'

# req <n> <jq-ish python expr> — field of the n-th logged request
nreq() { wc -l < "$LOG" | tr -d ' '; }
field() { python3 -c '
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
r=rows[int(sys.argv[2])]
b=json.loads(r["body"]) if r["body"] else {}
print(eval(sys.argv[3], {"r": r, "b": b}))' "$LOG" "$1" "$2"; }
no_token() { # <name> <text> — the tokens never appear
  case "$2" in *"$TOK_A"*|*"$TOK_B"*|*AAAAAAAAAAAA*|*BBBBBBBBBBBB*) st_fail "$1: a token leaked into the output" "$2" ;; esac
}

# --- BODY / AUTH / SKIP / QUIET: the default run ------------------------------
out=$(bash "$IMPORT" 2>&1); rc=$?
no_token "default run" "$out"
[ "$rc" = 0 ] || st_fail "default run exit $rc" "$out"
[ "$(nreq)" = 2 ] || st_fail "expected 2 puts, got $(nreq)" "$out"
[ "$(field 0 'r["path"]')" = "/v1/fleet/credentials" ] || st_fail "path" "$out"
[ "$(field 0 'r["auth"]')" = "Bearer viewer-SECRET-1" ] || st_fail "viewer token not sent as Bearer" "$(field 0 'r["auth"]')"
[ "$(field 0 'b["action"]+" "+b["principal_id"]+" "+b["provider"]+" "+b["account"]')" = "put pool claude alpha" ] || st_fail "alpha body" "$(field 0 'b')"
[ "$(field 1 'b["account"]')" = "beta" ] || st_fail "second put is not beta" "$(field 1 'b')"
[ "$(field 0 'b["secret"]["setup_token"]')" = "$TOK_A" ] || st_fail "alpha token not the file's" 
[ "$(field 1 'b["secret"]["setup_token"]')" = "$TOK_B" ] || st_fail "beta token not the file's"
want=$(python3 -c 'import datetime,sys; print((datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc)+datetime.timedelta(days=365)).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$MT")
[ "$(field 0 'b["secret"]["expires_at"]')" = "$want" ] || st_fail "default expires_at ≠ mtime+365d" "$(field 0 'b["secret"]["expires_at"]') vs $want"
[ "$(field 0 'sorted(b["secret"].keys())')" = "['expires_at', 'setup_token']" ] || st_fail "secret carries more than setup_token+expires_at" "$(field 0 'b["secret"].keys()')"
st_pass "BODY  two puts: pool · claude · label · the file's token · mtime+365d"
st_pass "AUTH  Bearer viewer token"
case "$out" in *"skip   hubbed"*"hub-managed"*) ;; *) st_fail "hub: marker not reported as skipped" "$out" ;; esac
case "$out" in *"skip   weird"*"not a"*) ;; *) st_fail "non-setup-token not reported as skipped" "$out" ;; esac
case "$out" in *alpha.conf*|*".dot"*) st_fail "a .conf or dotfile was considered" "$out" ;; esac
case "$out" in *"2 imported, 2 skipped, 0 failed"*) ;; *) st_fail "summary line" "$out" ;; esac
st_pass "SKIP  hub marker + non-token skipped and named; .conf/.dot/dir ignored; skips are not failures"
st_pass "QUIET no token in the output"

# --- GIVEN -------------------------------------------------------------------
: > "$LOG"
out=$(bash "$IMPORT" --principal wecom-alice --expires-at 2027-01-31T00:00:00Z alpha 2>&1); rc=$?
no_token "given run" "$out"
[ "$rc" = 0 ] && [ "$(nreq)" = 1 ] || st_fail "given: rc=$rc n=$(nreq)" "$out"
[ "$(field 0 'b["principal_id"]+" "+b["account"]+" "+b["secret"]["expires_at"]')" = "wecom-alice alpha 2027-01-31T00:00:00Z" ] || st_fail "given body" "$(field 0 'b')"
case "$out" in *"expires 2027-01-31T00:00:00Z (given)"*) ;; *) st_fail "given expiry not echoed" "$out" ;; esac
st_pass "GIVEN --principal / --expires-at sent as given, named label only"
: > "$LOG"
out=$(bash "$IMPORT" --expires-at yesterday alpha 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(nreq)" = 0 ] || st_fail "bad --expires-at: rc=$rc n=$(nreq)" "$out"
case "$out" in *RFC3339*) ;; *) st_fail "bad --expires-at not explained" "$out" ;; esac
st_pass "GIVEN a malformed --expires-at sends nothing and says so"

# --- DRY -----------------------------------------------------------------------
: > "$LOG"
out=$(bash "$IMPORT" --dry-run 2>&1); rc=$?
no_token "dry run" "$out"
[ "$rc" = 0 ] && [ "$(nreq)" = 0 ] || st_fail "dry-run sent $(nreq) request(s)" "$out"
case "$out" in *"would  alpha"*"would  beta"*"nothing sent"*) ;; *) st_fail "dry-run plan" "$out" ;; esac
st_pass "DRY   --dry-run plans, sends nothing"

# --- FAIL --------------------------------------------------------------------
: > "$LOG"
printf 'sk-ant-oat01-BAD-BAD-BAD-BAD-BAD-BAD-BAD-BAD\n' > "$FLEET_ACCOUNTS_DIR/bad"
out=$(bash "$IMPORT" bad alpha 2>&1); rc=$?
no_token "failing run" "$out"
[ "$rc" = 1 ] || st_fail "hub 400 should exit 1, got $rc" "$out"
case "$out" in *"FAIL   bad"*"HTTP 400"*) ;; *) st_fail "hub refusal status not shown" "$out" ;; esac
case "$out" in *"put    alpha"*"1 imported, 0 skipped, 1 failed"*) ;; *) st_fail "the other label still imported" "$out" ;; esac
case "$out" in *BAD-BAD*) st_fail "the failing token leaked" "$out" ;; esac
st_pass "FAIL  hub 400 → exit 1 with its status only; others still land; no token shown"

# --- NOAUTH --------------------------------------------------------------------
: > "$LOG"
out=$(env -u CCQUOTA_VIEWER_TOKEN bash "$IMPORT" alpha 2>&1); rc=$?
[ "$rc" = 2 ] && [ "$(nreq)" = 0 ] || st_fail "no viewer token: rc=$rc n=$(nreq)" "$out"
case "$out" in *"no viewer token"*) ;; *) st_fail "noauth message" "$out" ;; esac
st_pass "NOAUTH no viewer token → exit 2, nothing sent"

# --- UUID (issue #2127) ---------------------------------------------------------
# One label: a pasted token never borrows the importing machine's identity.
U1='6f1c2d3e-0000-4000-8000-000000000001'
printf '{"oauthAccount":{"accountUuid":"%s","emailAddress":"a@example.com"}}\n' "$U1" > "$HOME/.claude.json"
: > "$LOG"
out=$(bash "$IMPORT" alpha 2>&1); rc=$?
no_token "uuid run" "$out"
[ "$rc" = 0 ] && [ "$(nreq)" = 1 ] || st_fail "uuid: rc=$rc n=$(nreq)" "$out"
[ "$(field 0 '"account_uuid" in b["secret"]')" = "False" ] || st_fail "local identity was attached to an unrelated token" "$out"
case "$out" in *"$U1"*) st_fail "local uuid leaked into import plan" "$out" ;; esac
st_pass "UUID  single label: no implicit local identity"
: > "$LOG"
out=$(bash "$IMPORT" --account-uuid u-given alpha 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(field 0 'b["secret"].get("account_uuid","")')" = "u-given" ] || st_fail "--account-uuid not sent as given" "$out"
: > "$LOG"
out=$(bash "$IMPORT" --account-uuid none alpha 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(field 0 '"account_uuid" in b["secret"]')" = "False" ] || st_fail "--account-uuid none still sent one" "$out"
: > "$LOG"
out=$(bash "$IMPORT" alpha beta 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(field 0 '"account_uuid" in b["secret"]')" = "False" ] && [ "$(field 1 '"account_uuid" in b["secret"]')" = "False" ] || st_fail "several labels each got the login's uuid" "$out"
: > "$LOG"
out=$(bash "$IMPORT" --account-uuid u-x alpha beta 2>&1); rc=$?
[ "$rc" = 2 ] && [ "$(nreq)" = 0 ] || st_fail "--account-uuid with two labels: rc=$rc n=$(nreq)" "$out"
rm -f "$HOME/.claude.json"
st_pass "UUID  --account-uuid as given · none sends none · several labels send none · --account-uuid needs one label"

# --- CODEX (issue #1490) --------------------------------------------------------
RT='rt-CODEXSECRETCODEXSECRETCODEXSECRET'
IDT='eyJ-IDTOKEN-IDTOKEN-IDTOKEN'
export CCQUOTA_FLEET_CODEX_HOMES="$WORK/codex-homes"
mkdir -p "$HOME/.codex" "$CCQUOTA_FLEET_CODEX_HOMES/work" "$CCQUOTA_FLEET_CODEX_HOMES/hubbed" "$CCQUOTA_FLEET_CODEX_HOMES/apikey"
printf '{"auth_mode":"chatgpt","tokens":{"id_token":"%s","access_token":"at-x","refresh_token":"%s","account_id":"acct-1"},"last_refresh":"2026-10-04T00:00:00Z"}\n' "$IDT" "$RT" > "$HOME/.codex/auth.json"
printf '{"tokens":{"access_token":"at-y","refresh_token":"%s-work","account_id":"acct-2"}}\n' "$RT" > "$CCQUOTA_FLEET_CODEX_HOMES/work/auth.json"
printf '{"tokens":{"access_token":"at-z","refresh_token":"hub-managed","account_id":"acct-3"}}\n' > "$CCQUOTA_FLEET_CODEX_HOMES/hubbed/auth.json"
printf '{"OPENAI_API_KEY":"sk-NOTATOKEN"}\n' > "$CCQUOTA_FLEET_CODEX_HOMES/apikey/auth.json"
chmod 600 "$HOME/.codex/auth.json" "$CCQUOTA_FLEET_CODEX_HOMES"/*/auth.json
no_codex_token() { case "$2" in *"$RT"*|*"$IDT"*|*CODEXSECRET*|*IDTOKEN-IDTOKEN*) st_fail "$1: a codex token leaked into the output" "$2" ;; esac; }

: > "$LOG"
out=$(bash "$IMPORT" --codex 2>&1); rc=$?
no_codex_token "codex default" "$out"
[ "$rc" = 0 ] || st_fail "codex default exit $rc" "$out"
[ "$(nreq)" = 1 ] || st_fail "codex: expected 1 put, got $(nreq)" "$out"
[ "$(field 0 'b["action"]+" "+b["principal_id"]+" "+b["provider"]+" "+b["account"]')" = "put pool codex default" ] || st_fail "codex body" "$(field 0 'b')"
[ "$(field 0 'b["secret"]["refresh_token"]')" = "$RT" ] || st_fail "codex refresh_token not auth.json's"
[ "$(field 0 'b["secret"]["account_id"]+" "+b["secret"]["id_token"]')" = "acct-1 $IDT" ] || st_fail "codex account_id / id_token" "$(field 0 'b["secret"]')"
[ "$(field 0 'sorted(b["secret"].keys())')" = "['account_id', 'id_token', 'refresh_token']" ] || st_fail "codex secret carries more than the three" "$(field 0 'b["secret"].keys()')"
case "$out" in *"put    default"*"pool · refresh_token"*"1 imported, 0 skipped, 0 failed"*) ;; *) st_fail "codex summary" "$out" ;; esac
st_pass "CODEX --codex: one put pool · codex · default · refresh_token + account_id + id_token from ~/.codex/auth.json"

: > "$LOG"
out=$(bash "$IMPORT" --codex --principal wecom-alice work hubbed apikey nohome 2>&1); rc=$?
no_codex_token "codex profiles" "$out"
[ "$rc" = 0 ] || st_fail "codex profiles exit $rc" "$out"
[ "$(nreq)" = 1 ] || st_fail "codex profiles: expected 1 put, got $(nreq)" "$out"
[ "$(field 0 'b["principal_id"]+" "+b["account"]+" "+b["secret"]["refresh_token"]+" "+b["secret"]["account_id"]')" = "wecom-alice work $RT-work acct-2" ] || st_fail "codex work body" "$(field 0 'b')"
[ "$(field 0 '"id_token" in b["secret"]')" = "False" ] || st_fail "codex: an absent id_token must not be sent"
case "$out" in *"skip   hubbed"*"hub-managed"*) ;; *) st_fail "hub-managed codex home not skipped" "$out" ;; esac
case "$out" in *"skip   apikey"*"no tokens"*) ;; *) st_fail "API-key home not skipped" "$out" ;; esac
case "$out" in *"skip   nohome"*"no "*"/nohome/auth.json"*) ;; *) st_fail "missing home not skipped by path" "$out" ;; esac
case "$out" in *"1 imported, 3 skipped, 0 failed"*) ;; *) st_fail "codex profiles summary" "$out" ;; esac
st_pass "CODEX named profiles under <codex-homes>/<profile>; hub-managed / API-key / missing homes skipped and named"

: > "$LOG"
out=$(bash "$IMPORT" --codex --dry-run 2>&1); rc=$?
no_codex_token "codex dry" "$out"
[ "$rc" = 0 ] && [ "$(nreq)" = 0 ] || st_fail "codex dry-run sent $(nreq) request(s)" "$out"
case "$out" in *"would  default"*"pool · refresh_token"*"nothing sent"*) ;; *) st_fail "codex dry-run plan" "$out" ;; esac
st_pass "CODEX --dry-run plans the one row, sends nothing"

: > "$LOG"
out=$(bash "$IMPORT" --codex --expires-at 2027-01-01T00:00:00Z 2>&1); rc=$?
[ "$rc" = 2 ] && [ "$(nreq)" = 0 ] || st_fail "codex --expires-at: rc=$rc n=$(nreq)" "$out"
case "$out" in *"does not apply to --codex"*) ;; *) st_fail "codex --expires-at refusal" "$out" ;; esac
st_pass "CODEX --expires-at is refused (a refresh token rotates)"

# --- BYNAME (issue #1666): a ccquota-registered profile name -------------------
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/ccquota" <<EOF
#!/bin/sh
# fake ccquota: answers only "codex list --json", two registered profiles.
[ "\$1 \$2 \$3" = "codex list --json" ] || exit 2
printf '[{"name":"personal","home":"%s","default":true,"managed":true,"login":{"state":"valid","source":"local"}},{"name":"work","home":"%s","login":{"state":"valid"}}]\n' "$HOME/.codex" "$CCQUOTA_FLEET_CODEX_HOMES/work"
EOF
chmod +x "$WORK/fakebin/ccquota"

: > "$LOG"
out=$(FLEET_QUOTA_BIN=ccquota PATH="$WORK/fakebin:$PATH" bash "$IMPORT" --codex personal 2>&1); rc=$?
no_codex_token "codex by name" "$out"
[ "$rc" = 0 ] || st_fail "codex personal exit $rc" "$out"
[ "$(nreq)" = 1 ] || st_fail "codex personal: expected 1 put, got $(nreq)" "$out"
[ "$(field 0 'b["provider"]+" "+b["account"]+" "+b["secret"]["account_id"]')" = "codex default acct-1" ] || st_fail "personal (= ~/.codex) must import under the hub label default" "$(field 0 'b')"
case "$out" in *"note   personal"*"~/.codex → hub label default"*) ;; *) st_fail "name → label mapping not shown" "$out" ;; esac
case "$out" in *"put    personal → default"*) ;; *) st_fail "put line does not carry the mapping" "$out" ;; esac
case "$out" in *"NOW this machine must stop refreshing"*"CCQUOTA_FLEET_CREDS=1"*) ;; *) st_fail "no stop-refreshing reminder after a codex put" "$out" ;; esac
st_pass "BYNAME --codex personal (registered at ~/.codex) → put pool · codex · default, mapping shown, stop-refreshing reminder"

: > "$LOG"
out=$(FLEET_QUOTA_BIN=ccquota PATH="$WORK/fakebin:$PATH" bash "$IMPORT" --codex work 2>&1); rc=$?
no_codex_token "codex by name work" "$out"
[ "$rc" = 0 ] && [ "$(nreq)" = 1 ] || st_fail "codex work by name: rc=$rc n=$(nreq)" "$out"
[ "$(field 0 'b["account"]+" "+b["secret"]["account_id"]')" = "work acct-2" ] || st_fail "a profile at <codex-homes>/<name> keeps its own label" "$(field 0 'b')"
case "$out" in *"note   "*) st_fail "no mapping note for a plain <codex-homes>/<name> profile" "$out" ;; esac
st_pass "BYNAME a registered profile at <codex-homes>/<name> keeps its label, no note"

: > "$LOG"
out=$(FLEET_QUOTA_BIN=ccquota PATH="$WORK/fakebin:$PATH" bash "$IMPORT" --codex --dry-run personal 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(nreq)" = 0 ] || st_fail "codex by-name dry-run sent $(nreq)" "$out"
case "$out" in *"note   personal"*"would  personal → default"*"nothing sent"*) ;; *) st_fail "by-name dry-run plan" "$out" ;; esac
case "$out" in *"stop refreshing"*) st_fail "dry-run must not print the reminder" "$out" ;; esac
st_pass "BYNAME --dry-run shows the mapping, sends nothing, no reminder"

: > "$LOG"
out=$(FLEET_QUOTA_BIN="$WORK/no-such-ccquota" bash "$IMPORT" --codex personal 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(nreq)" = 0 ] || st_fail "no-ccquota personal: rc=$rc n=$(nreq)" "$out"
case "$out" in *"skip   personal"*"/personal/auth.json"*"0 imported, 1 skipped"*) ;; *) st_fail "without ccquota the <codex-homes>/<name> rule must hold" "$out" ;; esac
case "$out" in *"note   "*|*"stop refreshing"*) st_fail "degenerate run printed a note or reminder" "$out" ;; esac
st_pass "BYNAME without ccquota, <codex-homes>/<name> is byte for byte what it was"

# The Claude mode is byte-for-byte what it was: a codex home on the machine
# changes nothing about a plain run.
: > "$LOG"
out=$(bash "$IMPORT" --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(nreq)" = 0 ] || st_fail "claude dry-run after codex setup" "$out"
case "$out" in *"would  alpha"*"setup_token · expires"*) ;; *) st_fail "claude plan changed" "$out" ;; esac
case "$out" in *default*|*codex*) st_fail "claude mode considered a codex home" "$out" ;; esac
st_pass "CODEX the Claude mode is unchanged beside a codex home"

printf 'fleet-creds-import-selftest: %d checks passed\n' "$pass"
