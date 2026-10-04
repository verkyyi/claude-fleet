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
python3 - "$WORK/port" "$LOG" <<'PY' &
import json, signal, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
portfile, log = sys.argv[1:3]
signal.alarm(60)  # cannot outlive the test
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
srv = HTTPServer(('127.0.0.1', 0), H)
with open(portfile, 'w') as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PY
HUB_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$WORK/port" ] && break; sleep 0.1; done
[ -s "$WORK/port" ] || fail "fake hub did not start"
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

printf 'fleet-creds-import-selftest: %d checks passed\n' "$pass"
