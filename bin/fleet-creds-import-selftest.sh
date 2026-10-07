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
IMPORT="$BIN/fleet-creds-import.sh"
[ -f "$IMPORT" ] || { printf 'selftest: %s not found\n' "$IMPORT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 required\n' >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-creds-import-selftest.XXXXXX")" || exit 2
HUB_PID=
cleanup() { if [ -n "$HUB_PID" ]; then kill "$HUB_PID" 2>/dev/null; wait "$HUB_PID" 2>/dev/null; fi; rm -rf "$WORK"; }
trap cleanup EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

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
[ -s "$WORK/port" ] || fail "fake hub did not start" "$(cat "$WORK/hub.err" 2>/dev/null)"
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
  case "$2" in *"$TOK_A"*|*"$TOK_B"*|*AAAAAAAAAAAA*|*BBBBBBBBBBBB*) fail "$1: a token leaked into the output" "$2" ;; esac
}

# --- BODY / AUTH / SKIP / QUIET: the default run ------------------------------
out=$(bash "$IMPORT" 2>&1); rc=$?
no_token "default run" "$out"
[ "$rc" = 0 ] || fail "default run exit $rc" "$out"
[ "$(nreq)" = 2 ] || fail "expected 2 puts, got $(nreq)" "$out"
[ "$(field 0 'r["path"]')" = "/v1/fleet/credentials" ] || fail "path" "$out"
[ "$(field 0 'r["auth"]')" = "Bearer viewer-SECRET-1" ] || fail "viewer token not sent as Bearer" "$(field 0 'r["auth"]')"
[ "$(field 0 'b["action"]+" "+b["principal_id"]+" "+b["provider"]+" "+b["account"]')" = "put pool claude alpha" ] || fail "alpha body" "$(field 0 'b')"
[ "$(field 1 'b["account"]')" = "beta" ] || fail "second put is not beta" "$(field 1 'b')"
[ "$(field 0 'b["secret"]["setup_token"]')" = "$TOK_A" ] || fail "alpha token not the file's" 
[ "$(field 1 'b["secret"]["setup_token"]')" = "$TOK_B" ] || fail "beta token not the file's"
want=$(python3 -c 'import datetime,sys; print((datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc)+datetime.timedelta(days=365)).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$MT")
[ "$(field 0 'b["secret"]["expires_at"]')" = "$want" ] || fail "default expires_at ≠ mtime+365d" "$(field 0 'b["secret"]["expires_at"]') vs $want"
[ "$(field 0 'sorted(b["secret"].keys())')" = "['expires_at', 'setup_token']" ] || fail "secret carries more than setup_token+expires_at" "$(field 0 'b["secret"].keys()')"
ok "BODY  two puts: pool · claude · label · the file's token · mtime+365d"
ok "AUTH  Bearer viewer token"
case "$out" in *"skip   hubbed"*"hub-managed"*) ;; *) fail "hub: marker not reported as skipped" "$out" ;; esac
case "$out" in *"skip   weird"*"not a"*) ;; *) fail "non-setup-token not reported as skipped" "$out" ;; esac
case "$out" in *alpha.conf*|*".dot"*) fail "a .conf or dotfile was considered" "$out" ;; esac
case "$out" in *"2 imported, 2 skipped, 0 failed"*) ;; *) fail "summary line" "$out" ;; esac
ok "SKIP  hub marker + non-token skipped and named; .conf/.dot/dir ignored; skips are not failures"
ok "QUIET no token in the output"

# --- GIVEN -------------------------------------------------------------------
: > "$LOG"
out=$(bash "$IMPORT" --principal wecom-alice --expires-at 2027-01-31T00:00:00Z alpha 2>&1); rc=$?
no_token "given run" "$out"
[ "$rc" = 0 ] && [ "$(nreq)" = 1 ] || fail "given: rc=$rc n=$(nreq)" "$out"
[ "$(field 0 'b["principal_id"]+" "+b["account"]+" "+b["secret"]["expires_at"]')" = "wecom-alice alpha 2027-01-31T00:00:00Z" ] || fail "given body" "$(field 0 'b')"
case "$out" in *"expires 2027-01-31T00:00:00Z (given)"*) ;; *) fail "given expiry not echoed" "$out" ;; esac
ok "GIVEN --principal / --expires-at sent as given, named label only"
: > "$LOG"
out=$(bash "$IMPORT" --expires-at yesterday alpha 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(nreq)" = 0 ] || fail "bad --expires-at: rc=$rc n=$(nreq)" "$out"
case "$out" in *RFC3339*) ;; *) fail "bad --expires-at not explained" "$out" ;; esac
ok "GIVEN a malformed --expires-at sends nothing and says so"

# --- DRY -----------------------------------------------------------------------
: > "$LOG"
out=$(bash "$IMPORT" --dry-run 2>&1); rc=$?
no_token "dry run" "$out"
[ "$rc" = 0 ] && [ "$(nreq)" = 0 ] || fail "dry-run sent $(nreq) request(s)" "$out"
case "$out" in *"would  alpha"*"would  beta"*"nothing sent"*) ;; *) fail "dry-run plan" "$out" ;; esac
ok "DRY   --dry-run plans, sends nothing"

# --- FAIL --------------------------------------------------------------------
: > "$LOG"
printf 'sk-ant-oat01-BAD-BAD-BAD-BAD-BAD-BAD-BAD-BAD\n' > "$FLEET_ACCOUNTS_DIR/bad"
out=$(bash "$IMPORT" bad alpha 2>&1); rc=$?
no_token "failing run" "$out"
[ "$rc" = 1 ] || fail "hub 400 should exit 1, got $rc" "$out"
case "$out" in *"FAIL   bad"*"HTTP 400"*"setup_token must be"*) ;; *) fail "hub's message not shown" "$out" ;; esac
case "$out" in *"put    alpha"*"1 imported, 0 skipped, 1 failed"*) ;; *) fail "the other label still imported" "$out" ;; esac
case "$out" in *BAD-BAD*) fail "the failing token leaked" "$out" ;; esac
ok "FAIL  hub 400 → exit 1 with the hub's reason; others still land; no token shown"

# --- NOAUTH --------------------------------------------------------------------
: > "$LOG"
out=$(env -u CCQUOTA_VIEWER_TOKEN bash "$IMPORT" alpha 2>&1); rc=$?
[ "$rc" = 2 ] && [ "$(nreq)" = 0 ] || fail "no viewer token: rc=$rc n=$(nreq)" "$out"
case "$out" in *"no viewer token"*) ;; *) fail "noauth message" "$out" ;; esac
ok "NOAUTH no viewer token → exit 2, nothing sent"

# --- UUID (issue #2127) ---------------------------------------------------------
# One label: the importing login's oauthAccount.accountUuid rides along, printed.
U1='6f1c2d3e-0000-4000-8000-000000000001'
printf '{"oauthAccount":{"accountUuid":"%s","emailAddress":"a@example.com"}}\n' "$U1" > "$HOME/.claude.json"
: > "$LOG"
out=$(bash "$IMPORT" alpha 2>&1); rc=$?
no_token "uuid run" "$out"
[ "$rc" = 0 ] && [ "$(nreq)" = 1 ] || fail "uuid: rc=$rc n=$(nreq)" "$out"
[ "$(field 0 'b["secret"].get("account_uuid","")')" = "$U1" ] || fail "login's account uuid not sent" "$(field 0 'b["secret"].keys()')"
case "$out" in *"uuid   alpha"*"$U1"*".claude.json"*) ;; *) fail "assumed uuid not printed" "$out" ;; esac
ok "UUID  one label: this login's oauthAccount.accountUuid sent and named"
: > "$LOG"
out=$(bash "$IMPORT" --account-uuid u-given alpha 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(field 0 'b["secret"].get("account_uuid","")')" = "u-given" ] || fail "--account-uuid not sent as given" "$out"
: > "$LOG"
out=$(bash "$IMPORT" --account-uuid none alpha 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(field 0 '"account_uuid" in b["secret"]')" = "False" ] || fail "--account-uuid none still sent one" "$out"
: > "$LOG"
out=$(bash "$IMPORT" alpha beta 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(field 0 '"account_uuid" in b["secret"]')" = "False" ] && [ "$(field 1 '"account_uuid" in b["secret"]')" = "False" ] || fail "several labels each got the login's uuid" "$out"
: > "$LOG"
out=$(bash "$IMPORT" --account-uuid u-x alpha beta 2>&1); rc=$?
[ "$rc" = 2 ] && [ "$(nreq)" = 0 ] || fail "--account-uuid with two labels: rc=$rc n=$(nreq)" "$out"
rm -f "$HOME/.claude.json"
ok "UUID  --account-uuid as given · none sends none · several labels send none · --account-uuid needs one label"

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
no_codex_token() { case "$2" in *"$RT"*|*"$IDT"*|*CODEXSECRET*|*IDTOKEN-IDTOKEN*) fail "$1: a codex token leaked into the output" "$2" ;; esac; }

: > "$LOG"
out=$(bash "$IMPORT" --codex 2>&1); rc=$?
no_codex_token "codex default" "$out"
[ "$rc" = 0 ] || fail "codex default exit $rc" "$out"
[ "$(nreq)" = 1 ] || fail "codex: expected 1 put, got $(nreq)" "$out"
[ "$(field 0 'b["action"]+" "+b["principal_id"]+" "+b["provider"]+" "+b["account"]')" = "put pool codex default" ] || fail "codex body" "$(field 0 'b')"
[ "$(field 0 'b["secret"]["refresh_token"]')" = "$RT" ] || fail "codex refresh_token not auth.json's"
[ "$(field 0 'b["secret"]["account_id"]+" "+b["secret"]["id_token"]')" = "acct-1 $IDT" ] || fail "codex account_id / id_token" "$(field 0 'b["secret"]')"
[ "$(field 0 'sorted(b["secret"].keys())')" = "['account_id', 'id_token', 'refresh_token']" ] || fail "codex secret carries more than the three" "$(field 0 'b["secret"].keys()')"
case "$out" in *"put    default"*"pool · refresh_token"*"1 imported, 0 skipped, 0 failed"*) ;; *) fail "codex summary" "$out" ;; esac
ok "CODEX --codex: one put pool · codex · default · refresh_token + account_id + id_token from ~/.codex/auth.json"

: > "$LOG"
out=$(bash "$IMPORT" --codex --principal wecom-alice work hubbed apikey nohome 2>&1); rc=$?
no_codex_token "codex profiles" "$out"
[ "$rc" = 0 ] || fail "codex profiles exit $rc" "$out"
[ "$(nreq)" = 1 ] || fail "codex profiles: expected 1 put, got $(nreq)" "$out"
[ "$(field 0 'b["principal_id"]+" "+b["account"]+" "+b["secret"]["refresh_token"]+" "+b["secret"]["account_id"]')" = "wecom-alice work $RT-work acct-2" ] || fail "codex work body" "$(field 0 'b')"
[ "$(field 0 '"id_token" in b["secret"]')" = "False" ] || fail "codex: an absent id_token must not be sent"
case "$out" in *"skip   hubbed"*"hub-managed"*) ;; *) fail "hub-managed codex home not skipped" "$out" ;; esac
case "$out" in *"skip   apikey"*"no tokens"*) ;; *) fail "API-key home not skipped" "$out" ;; esac
case "$out" in *"skip   nohome"*"no "*"/nohome/auth.json"*) ;; *) fail "missing home not skipped by path" "$out" ;; esac
case "$out" in *"1 imported, 3 skipped, 0 failed"*) ;; *) fail "codex profiles summary" "$out" ;; esac
ok "CODEX named profiles under <codex-homes>/<profile>; hub-managed / API-key / missing homes skipped and named"

: > "$LOG"
out=$(bash "$IMPORT" --codex --dry-run 2>&1); rc=$?
no_codex_token "codex dry" "$out"
[ "$rc" = 0 ] && [ "$(nreq)" = 0 ] || fail "codex dry-run sent $(nreq) request(s)" "$out"
case "$out" in *"would  default"*"pool · refresh_token"*"nothing sent"*) ;; *) fail "codex dry-run plan" "$out" ;; esac
ok "CODEX --dry-run plans the one row, sends nothing"

: > "$LOG"
out=$(bash "$IMPORT" --codex --expires-at 2027-01-01T00:00:00Z 2>&1); rc=$?
[ "$rc" = 2 ] && [ "$(nreq)" = 0 ] || fail "codex --expires-at: rc=$rc n=$(nreq)" "$out"
case "$out" in *"does not apply to --codex"*) ;; *) fail "codex --expires-at refusal" "$out" ;; esac
ok "CODEX --expires-at is refused (a refresh token rotates)"

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
[ "$rc" = 0 ] || fail "codex personal exit $rc" "$out"
[ "$(nreq)" = 1 ] || fail "codex personal: expected 1 put, got $(nreq)" "$out"
[ "$(field 0 'b["provider"]+" "+b["account"]+" "+b["secret"]["account_id"]')" = "codex default acct-1" ] || fail "personal (= ~/.codex) must import under the hub label default" "$(field 0 'b')"
case "$out" in *"note   personal"*"~/.codex → hub label default"*) ;; *) fail "name → label mapping not shown" "$out" ;; esac
case "$out" in *"put    personal → default"*) ;; *) fail "put line does not carry the mapping" "$out" ;; esac
case "$out" in *"NOW this machine must stop refreshing"*"CCQUOTA_FLEET_CREDS=1"*) ;; *) fail "no stop-refreshing reminder after a codex put" "$out" ;; esac
ok "BYNAME --codex personal (registered at ~/.codex) → put pool · codex · default, mapping shown, stop-refreshing reminder"

: > "$LOG"
out=$(FLEET_QUOTA_BIN=ccquota PATH="$WORK/fakebin:$PATH" bash "$IMPORT" --codex work 2>&1); rc=$?
no_codex_token "codex by name work" "$out"
[ "$rc" = 0 ] && [ "$(nreq)" = 1 ] || fail "codex work by name: rc=$rc n=$(nreq)" "$out"
[ "$(field 0 'b["account"]+" "+b["secret"]["account_id"]')" = "work acct-2" ] || fail "a profile at <codex-homes>/<name> keeps its own label" "$(field 0 'b')"
case "$out" in *"note   "*) fail "no mapping note for a plain <codex-homes>/<name> profile" "$out" ;; esac
ok "BYNAME a registered profile at <codex-homes>/<name> keeps its label, no note"

: > "$LOG"
out=$(FLEET_QUOTA_BIN=ccquota PATH="$WORK/fakebin:$PATH" bash "$IMPORT" --codex --dry-run personal 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(nreq)" = 0 ] || fail "codex by-name dry-run sent $(nreq)" "$out"
case "$out" in *"note   personal"*"would  personal → default"*"nothing sent"*) ;; *) fail "by-name dry-run plan" "$out" ;; esac
case "$out" in *"stop refreshing"*) fail "dry-run must not print the reminder" "$out" ;; esac
ok "BYNAME --dry-run shows the mapping, sends nothing, no reminder"

: > "$LOG"
out=$(FLEET_QUOTA_BIN="$WORK/no-such-ccquota" bash "$IMPORT" --codex personal 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(nreq)" = 0 ] || fail "no-ccquota personal: rc=$rc n=$(nreq)" "$out"
case "$out" in *"skip   personal"*"/personal/auth.json"*"0 imported, 1 skipped"*) ;; *) fail "without ccquota the <codex-homes>/<name> rule must hold" "$out" ;; esac
case "$out" in *"note   "*|*"stop refreshing"*) fail "degenerate run printed a note or reminder" "$out" ;; esac
ok "BYNAME without ccquota, <codex-homes>/<name> is byte for byte what it was"

# The Claude mode is byte-for-byte what it was: a codex home on the machine
# changes nothing about a plain run.
: > "$LOG"
out=$(bash "$IMPORT" --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(nreq)" = 0 ] || fail "claude dry-run after codex setup" "$out"
case "$out" in *"would  alpha"*"setup_token · expires"*) ;; *) fail "claude plan changed" "$out" ;; esac
case "$out" in *default*|*codex*) fail "claude mode considered a codex home" "$out" ;; esac
ok "CODEX the Claude mode is unchanged beside a codex home"

printf 'fleet-creds-import-selftest: %d checks passed\n' "$pass"
