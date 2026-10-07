#!/usr/bin/env bash
# session-cred-selftest.sh — every session through this login's credential proxy,
# and an account change that closes nothing (issue #1972, EPIC #1967 C5).
#
# Drives bin/fleet-session-cred.sh, bin/fleet-claude.sh and bin/fleet-codex.sh
# (fake `claude` / `codex` on PATH that dump their environment and send one
# request), the real bin/fleet-cred-proxy.py, and ONE fake far end on 127.0.0.1
# playing the providers and the hub — sandbox HOME + FLEET_CONF_DIR.
#
#   A  FLEET_CRED_PROXY=0 — byte for byte: `on` says no, `mint` exits 3; with no
#      FLEET_CRED_SID fleet-claude.sh exports the account's own token as before and
#      no ANTHROPIC_BASE_URL; fleet-codex.sh keeps CODEX_HOME and adds no provider
#   B  Claude, trusted (direct): ANTHROPIC_BASE_URL on 127.0.0.1, an fcp1. token,
#      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1, no CLAUDE_SECURESTORAGE_CONFIG_DIR;
#      the scan: no real token anywhere in the session's environment; the request
#      reaches the provider with the account's real token
#   C  rebind (what migrate does): the SAME session's next request runs on another
#      account (a hub-leased one); revoke at exit → 401
#   D  Codex: a credential-free CODEX_HOME (no auth.json, threads linked to the
#      real home, `.fleet-real-home`), the `fleet` custom provider + plugins / apps /
#      analytics off, an fcp1. in FLEET_CODEX_SESSION_CRED, the window records the
#      real home; the request carries the account's real token + account id;
#      a recorded mirror maps back to the real home on --codex-home
#   E  central (an untrusted machine): an fcp-h1. pass from the hub (node token +
#      the session's assertion), no account needed; revoke DELETEs the pass
#   F  migrate_rebind on an isolated tmux server: the window's @fleet_id and pane
#      pid unchanged, @cc_account + the proxy's binding moved; a central window and
#      a --model move are left to the old road
#   G  the Codex daemon a session leaves behind: a PPID=1 app-server holding a file
#      in the session's home is a reap candidate only once its session is revoked
#   H  the ambient login (no account) on a trusted route: exit 4, launch as before;
#      the proxy refusing → the launch refuses (never falls back to a credential)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
SB=$(mktemp -d /tmp/scs.XXXXXX)   # short: the proxy's ctl.sock must fit a unix socket path (104 bytes on macOS)
SB=$(cd "$SB" && pwd -P)
TSOCK="$SB/tmux.sock"
cleanup() {
  kill "$(cat "$SB/conf/cred-proxy/pid" 2>/dev/null)" 2>/dev/null
  kill "$(cat "$SB/fake.pid" 2>/dev/null)" 2>/dev/null
  [ -n "${DPID:-}" ] && kill "$DPID" 2>/dev/null
  tmux -S "$TSOCK" kill-server 2>/dev/null
  rm -rf "$SB"
}
trap cleanup EXIT
export HOME="$SB/home" FLEET_CONF_DIR="$SB/conf" XDG_CONFIG_HOME="$SB/xdg"
mkdir -p "$HOME/.local/bin" "$FLEET_CONF_DIR" "$XDG_CONFIG_HOME" "$SB/out"
unset FLEET_HUB_URL CCQUOTA_HUB_URL CCQUOTA_TOKEN FLEET_PROBE_FORCE_UNREACHABLE TMUX TMUX_PANE \
      FLEET_CRED_SID FLEET_WORKER_CRED FLEET_WORKER_ASSERT CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_BASE_URL \
      CLAUDE_SECURESTORAGE_CONFIG_DIR CODEX_HOME FLEET_CODEX_HOME FLEET_CODEX_ACCOUNTS FLEET_CODEX_PROFILE
export FLEET_MCP=0 FLEET_PRETRUST=0 FLEET_AGENT_CFG=0 FLEET_MOD=0 FLEET_CODEX_VERSION_CHECK=0 \
       FLEET_CODEX_NATIVE_SKILLS=0 FLEET_CODEX_SERVER=0 FLEET_FAILOVER=0 FLEET_MODEL='' FLEET_AGENT=claude

FAIL=0
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; FAIL=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — expected [$2], got [$3]"; fi; }

# ── the fake far end: providers + hub ────────────────────────────────────────
cat > "$SB/fake.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
SB = sys.argv[1]
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def reply(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self): self.any()
    def do_POST(self): self.any()
    def do_DELETE(self): self.any()
    def any(self):
        n = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(n) if n else b""
        h = {k.lower(): v for k, v in self.headers.items()}
        p = self.path
        with open(os.path.join(SB, "hits"), "a") as f:
            f.write("%s %s\n" % (self.command, p))
        if p == "/v1/node/self":
            return self.reply(200, {"endpoint_id": "e1", "trust": open(os.path.join(SB, "trust")).read().strip()})
        if p == "/v1/fleet/session-cred" and self.command == "POST":
            if h.get("authorization") != "Bearer nodetok" or not h.get("x-fleet-worker", "").startswith("fwa1."):
                return self.reply(401, {"error": "node token + assertion"})
            prov = json.loads(body or b"{}").get("providers", [])
            return self.reply(200, {"cred": "fcp-h1.PASS-%s.sig" % "-".join(prov), "id": "pass-1"})
        if p.startswith("/v1/fleet/session-cred/") and self.command == "DELETE":
            return self.reply(200, {"revoked": True})
        if p.startswith("/direct-") or p.startswith("/central"):
            return self.reply(200, {"path": p, "auth": h.get("authorization", ""),
                                    "acct_id": h.get("chatgpt-account-id", "")})
        self.reply(404, {"error": p})
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
srv.daemon_threads = True
open(os.path.join(SB, "fake.port"), "w").write(str(srv.server_address[1]))
open(os.path.join(SB, "fake.pid"), "w").write(str(os.getpid()))
srv.serve_forever()
PY
echo trusted > "$SB/trust"
python3 -I "$SB/fake.py" "$SB" & disown
i=0; while [ ! -s "$SB/fake.port" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$SB/fake.port" ] || { fail "start: the fake far end never came up"; exit 1; }
U="http://127.0.0.1:$(cat "$SB/fake.port")"
export FLEET_CRED_ANTHROPIC_URL="$U/direct-anthropic" FLEET_CRED_CODEX_URL="$U/direct-codex" \
       FLEET_CRED_CODEX_HOMES="$HOME/.codex-accounts" FLEET_CRED_CODEX_AUTH="$HOME/.codex/auth.json" \
       FLEET_CRED_CENTRAL_URL="$U/central" FLEET_CRED_PROXY_LOG="$SB/cred-proxy.log"

# accounts: a1 a plain setup token, a2 hub-leased; Codex homes default + cx1
mkdir -p "$FLEET_CONF_DIR/accounts/a2.hub" "$HOME/.codex" "$HOME/.codex-accounts/cx1/sessions"
printf 'sk-ant-oat-REAL-a1\n' > "$FLEET_CONF_DIR/accounts/a1"
printf 'hub:a2\n' > "$FLEET_CONF_DIR/accounts/a2"
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat-REAL-a2"}}' > "$FLEET_CONF_DIR/accounts/a2.hub/.credentials.json"
printf '{"tokens":{"access_token":"cx-REAL-cx1","account_id":"acct-cx1"}}' > "$HOME/.codex-accounts/cx1/auth.json"
printf 'model = "gpt-test"\n' > "$HOME/.codex-accounts/cx1/config.toml"
printf '{"tokens":{"access_token":"cx-REAL-default","account_id":"acct-default"}}' > "$HOME/.codex/auth.json"

# fake agents: dump the environment + argv, send one request through what they were given
cat > "$HOME/.local/bin/claude" <<'EOF'
#!/bin/bash
env > "$OUT/env"; printf '%s\n' "$@" > "$OUT/argv"
[ -n "${ANTHROPIC_BASE_URL:-}" ] || exit 0
python3 -I - "$OUT/resp" <<'PY'
import os, sys, urllib.request, urllib.error
req = urllib.request.Request(os.environ["ANTHROPIC_BASE_URL"] + "/v1/messages", data=b'{"m":1}', method="POST",
      headers={"Authorization": "Bearer " + os.environ["CLAUDE_CODE_OAUTH_TOKEN"], "x-api-key": "junk"})
try:
    out = urllib.request.urlopen(req, timeout=20).read().decode()
except urllib.error.HTTPError as e:
    out = "HTTP %d" % e.code
open(sys.argv[1], "w").write(out)
PY
EOF
cat > "$HOME/.local/bin/codex" <<'EOF'
#!/bin/bash
env > "$OUT/env"; printf '%s\n' "$@" > "$OUT/argv"
base=$(printf '%s\n' "$@" | sed -n 's/.*base_url="\([^"]*\)".*/\1/p' | head -n 1)
[ -n "$base" ] || exit 0
python3 -I - "$OUT/resp" "$base" <<'PY'
import os, sys, urllib.request, urllib.error
req = urllib.request.Request(sys.argv[2] + "/responses", data=b'{"m":1}', method="POST",
      headers={"Authorization": "Bearer " + os.environ["FLEET_CODEX_SESSION_CRED"], "chatgpt-account-id": "spoof"})
try:
    out = urllib.request.urlopen(req, timeout=20).read().decode()
except urllib.error.HTTPError as e:
    out = "HTTP %d" % e.code
open(sys.argv[1], "w").write(out)
PY
EOF
chmod +x "$HOME/.local/bin/claude" "$HOME/.local/bin/codex"
export PATH="$HOME/.local/bin:$PATH"
envv() { sed -n "s/^$1=//p" "$OUT/env" | head -n 1; }
has_real() { grep -c 'REAL-' "$OUT/env" | tr -d ' '; }
resp() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],""))' "$OUT/resp" "$1" 2>/dev/null || cat "$OUT/resp"; }
run_claude() { # <dir> [env…] — fleet-claude.sh --version with FLEET_ACCOUNT_LABEL etc. from the args
  OUT="$SB/out/$1"; mkdir -p "$OUT"; rm -f "$OUT"/*; shift
  env OUT="$OUT" "$@" bash "$BIN/fleet-claude.sh" --version >"$OUT/stdout" 2>"$OUT/stderr"; echo $? > "$OUT/rc"
}
run_codex() { # <dir> [env…] [-- launcher args…]
  local e=()
  OUT="$SB/out/$1"; mkdir -p "$OUT"; rm -f "$OUT"/*; shift
  while [ $# -gt 0 ] && [ "$1" != -- ]; do e+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  env OUT="$OUT" FLEET_AGENT=codex ${e[@]+"${e[@]}"} bash "$BIN/fleet-claude.sh" "$@" >"$OUT/stdout" 2>"$OUT/stderr"; echo $? > "$OUT/rc"
}

# ── A: switched off ⇒ the launch as it always was ────────────────────────────
FLEET_CRED_PROXY=0 bash "$BIN/fleet-session-cred.sh" on; check "A off: \`on\` says no" 1 "$?"
FLEET_CRED_PROXY=0 bash "$BIN/fleet-session-cred.sh" mint --provider claude --sid s1 --account a1 >/dev/null 2>&1
check "A off: mint exits 3" 3 "$?"
run_claude a0 FLEET_CRED_PROXY=0 FLEET_ACCOUNT_LABEL=a1
OUT="$SB/out/a0"
check "A off: Claude gets the account's own token (today's wiring)" "sk-ant-oat-REAL-a1" "$(envv CLAUDE_CODE_OAUTH_TOKEN)"
check "A off: no ANTHROPIC_BASE_URL" "" "$(envv ANTHROPIC_BASE_URL)"
run_codex ax0 FLEET_CRED_PROXY=0 CODEX_HOME="$HOME/.codex-accounts/cx1"
OUT="$SB/out/ax0"
check "A off: Codex keeps its account CODEX_HOME" "$HOME/.codex-accounts/cx1" "$(envv CODEX_HOME)"
check "A off: Codex gets no fleet provider" 0 "$(grep -c 'model_provider' "$OUT/argv" | tr -d ' ')"
check "A off: no proxy was started" no "$([ -e "$FLEET_CONF_DIR/cred-proxy/pid" ] && echo yes || echo no)"

export FLEET_CRED_PROXY=1

# ── B: Claude, trusted (no hub = a standalone login = trusted) → direct ──────
run_claude b FLEET_CRED_SID=sB FLEET_ACCOUNT_LABEL=a1
OUT="$SB/out/b"
check "B: launch rc" 0 "$(cat "$OUT/rc")"
case "$(envv ANTHROPIC_BASE_URL)" in http://127.0.0.1:[0-9]*) pass "B: ANTHROPIC_BASE_URL is the loopback proxy" ;; *) fail "B: ANTHROPIC_BASE_URL=$(envv ANTHROPIC_BASE_URL) ($(cat "$OUT/stderr"))" ;; esac
case "$(envv CLAUDE_CODE_OAUTH_TOKEN)" in fcp1.*) pass "B: the session holds an fcp1. session credential" ;; *) fail "B: CLAUDE_CODE_OAUTH_TOKEN is not fcp1." ;; esac
check "B: CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" 1 "$(envv CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC)"
check "B: no CLAUDE_SECURESTORAGE_CONFIG_DIR" 0 "$(grep -c '^CLAUDE_SECURESTORAGE_CONFIG_DIR=' "$OUT/env" | tr -d ' ')"
check "B: scan — no real token in the session's environment" 0 "$(has_real)"
check "B: the provider got a1's real token" "Bearer sk-ant-oat-REAL-a1" "$(resp auth)"
check "B: the session record says direct" route=direct "$(grep '^route=' "$FLEET_CONF_DIR/cred-proxy/sessions/sB")"
grep -q 'REAL-' "$FLEET_CONF_DIR/cred-proxy/sessions/sB" && fail "B: a credential in the session record" || pass "B: no credential in the session record"
TOK_B=$(envv CLAUDE_CODE_OAUTH_TOKEN); PORT=$(cat "$FLEET_CONF_DIR/cred-proxy/port")

send_b() { # → the auth the provider saw (or HTTP code) for session B's credential
  python3 -I - "$PORT" "$TOK_B" <<'PY'
import json, sys, urllib.request, urllib.error
req = urllib.request.Request("http://127.0.0.1:%s/v1/messages" % sys.argv[1], data=b"{}", method="POST",
      headers={"Authorization": "Bearer " + sys.argv[2]})
try:
    print(json.loads(urllib.request.urlopen(req, timeout=20).read())["auth"])
except urllib.error.HTTPError as e:
    print("HTTP %d" % e.code)
PY
}
# ── C: rebind, then revoke ──────────────────────────────────────────────────
bash "$BIN/fleet-session-cred.sh" rebind --sid sB --account a2
check "C: rebind exits 0" 0 "$?"
check "C: the same session's next request runs on a2 (hub-leased)" "Bearer sk-ant-oat-REAL-a2" "$(send_b)"
grep -q '"ev": "rebind".*"acct": "a2"' "$SB/cred-proxy.log" && pass "C: the proxy log names the new acct" || fail "C: no rebind/acct line in the proxy log"
bash "$BIN/fleet-session-cred.sh" revoke --sid sB
check "C: after revoke the credential is refused" "HTTP 401" "$(send_b)"
check "C: the session record is gone" no "$([ -e "$FLEET_CONF_DIR/cred-proxy/sessions/sB" ] && echo yes || echo no)"

# ── D: Codex ─────────────────────────────────────────────────────────────────
run_codex d FLEET_CRED_SID=sD CODEX_HOME="$HOME/.codex-accounts/cx1"
OUT="$SB/out/d"
check "D: launch rc" 0 "$(cat "$OUT/rc")"
CH=$(envv CODEX_HOME)
check "D: CODEX_HOME is the session's own" "$FLEET_CONF_DIR/cred-proxy/codex-homes/sD" "$CH"
check "D: no auth.json in it" no "$([ -e "$CH/auth.json" ] && echo yes || echo no)"
check "D: threads stay the account home's" "$(cd "$HOME/.codex-accounts/cx1/sessions" && pwd -P)" "$(cd "$CH/sessions" && pwd -P)"
check "D: .fleet-real-home names it" "$(cd "$HOME/.codex-accounts/cx1" && pwd -P)" "$(cat "$CH/.fleet-real-home")"
check "D: model_provider=fleet" 1 "$(grep -c '^model_provider="fleet"$' "$OUT/argv" | tr -d ' ')"
check "D: the provider is the loopback proxy by env_key" 1 "$(grep -c "base_url=\"http://127.0.0.1:$PORT/codex\",env_key=\"FLEET_CODEX_SESSION_CRED\"" "$OUT/argv" | tr -d ' ')"
for k in features.plugins=false features.apps=false analytics.enabled=false; do
  check "D: $k" 1 "$(grep -cx "$k" "$OUT/argv" | tr -d ' ')"
done
case "$(envv FLEET_CODEX_SESSION_CRED)" in fcp1.*) pass "D: FLEET_CODEX_SESSION_CRED is an fcp1." ;; *) fail "D: no fcp1. for Codex ($(cat "$OUT/stderr"))" ;; esac
check "D: scan — no real token in the session's environment" 0 "$(has_real)"
check "D: the provider got cx1's real token" "Bearer cx-REAL-cx1" "$(resp auth)"
check "D: … and cx1's account id, never the session's" acct-cx1 "$(resp acct_id)"
run_codex d2 FLEET_CRED_SID=sD2 -- --codex-home "$CH"
OUT="$SB/out/d2"
check "D: a recorded mirror maps back to the real home" "$FLEET_CONF_DIR/cred-proxy/codex-homes/sD2" "$(envv CODEX_HOME)"
check "D: … and its mirror is cx1's again" "$(cat "$CH/.fleet-real-home")" "$(cat "$FLEET_CONF_DIR/cred-proxy/codex-homes/sD2/.fleet-real-home")"

# ── E: central — the hub says untrusted ──────────────────────────────────────
printf 'CCQUOTA_HUB_URL=%s\nCCQUOTA_TOKEN=nodetok\n' "$U" > "$FLEET_CONF_DIR/node.env"
echo untrusted > "$SB/trust"
bash "$BIN/fleet-cred-proxy.sh" route --refresh >/dev/null 2>&1
run_claude e FLEET_CRED_SID=sE FLEET_WORKER_ASSERT=fwa1.test.sig
OUT="$SB/out/e"
check "E: launch rc (no account needed)" 0 "$(cat "$OUT/rc")"
check "E: the session holds the hub's pass" "fcp-h1.PASS-claude.sig" "$(envv CLAUDE_CODE_OAUTH_TOKEN)"
check "E: the request went central with the pass" "Bearer fcp-h1.PASS-claude.sig" "$(resp auth)"
check "E: the record keeps the pass id (never the pass)" "hub_id=pass-1" "$(grep '^hub_id=' "$FLEET_CONF_DIR/cred-proxy/sessions/sE")"
check "E: scan — no real token in the session's environment" 0 "$(has_real)"
bash "$BIN/fleet-session-cred.sh" rebind --sid sE --account a1 2>/dev/null; check "E: a central session is never rebound" 1 "$?"
bash "$BIN/fleet-session-cred.sh" revoke --sid sE
check "E: revoke DELETEs the pass on the hub" 1 "$(grep -c '^DELETE /v1/fleet/session-cred/pass-1$' "$SB/hits" | tr -d ' ')"
echo trusted > "$SB/trust"; rm -f "$FLEET_CONF_DIR/node.env"
bash "$BIN/fleet-cred-proxy.sh" route --refresh >/dev/null 2>&1

# ── F: migrate_rebind on an isolated tmux server ─────────────────────────────
if command -v tmux >/dev/null 2>&1; then
  tm() { tmux -S "$TSOCK" "$@"; }
  tm -f /dev/null new-session -d -s mg -n w1 'sleep 600' && tm new-window -d -t mg: -n w2 'sleep 600' && tm new-window -d -t mg: -n w3 'sleep 600'
  bash "$BIN/fleet-session-cred.sh" mint --provider claude --sid sF --account a1 >/dev/null
  for w in w1 w2 w3; do tm set-option -w -t "mg:$w" @fleet_id "fid-$w"; tm set-option -w -t "mg:$w" @cc_account a1; done
  tm set-option -w -t mg:w1 @cred_sid sF; tm set-option -w -t mg:w1 @cred_route direct
  tm set-option -w -t mg:w2 @cred_sid sX; tm set-option -w -t mg:w2 @cred_route central
  before=$(tm display-message -p -t mg:w1 '#{window_id} #{@fleet_id} #{pane_pid}')
  out=$(
    # shellcheck source=/dev/null
    . "$BIN/fleet-migrate.sh"
    TM() { tmux -S "$TSOCK" "$@"; }
    say() { printf '%s\n' "$*"; }
    ACTIVE=a2 MODEL='' CFG=0 DRY=0 ACTIVE_BENCHED=0 AGENT=claude moved=0 skipped=0 REPORT=''
    migrate_rebind "$(tm display-message -p -t mg:w1 '#{window_id}')" a1; echo "w1=$? moved=$moved"
    migrate_rebind "$(tm display-message -p -t mg:w2 '#{window_id}')" a1; echo "w2=$?"
    MODEL=sonnet; migrate_rebind "$(tm display-message -p -t mg:w1 '#{window_id}')" a2; echo "model=$?"
    MODEL=''; migrate_rebind "$(tm display-message -p -t mg:w3 '#{window_id}')" a1; echo "w3=$?"
  )
  case "$out" in *"w1=0 moved=1"*) pass "F: a direct window is rebound in place" ;; *) fail "F: w1 not rebound: $out" ;; esac
  check "F: window id, @fleet_id and pane pid unchanged" "$before" "$(tm display-message -p -t mg:w1 '#{window_id} #{@fleet_id} #{pane_pid}')"
  check "F: @cc_account moved" a2 "$(tm display-message -p -t mg:w1 '#{@cc_account}')"
  check "F: the proxy binding moved" a2 "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sF",""))' "$FLEET_CONF_DIR/cred-proxy/bind.json")"
  case "$out" in *"w2=1"*) pass "F: a central window takes the old road" ;; *) fail "F: w2: $out" ;; esac
  case "$out" in *"model=1"*) pass "F: a --model move takes the old road" ;; *) fail "F: model: $out" ;; esac
  case "$out" in *"w3=1"*) pass "F: a window with no @cred_sid takes the old road" ;; *) fail "F: w3: $out" ;; esac
  bash "$BIN/fleet-session-cred.sh" revoke --sid sF
else
  pass "F: tmux absent — SKIP"
fi

# ── G: the Codex daemon a session leaves behind ──────────────────────────────
bash "$BIN/fleet-session-cred.sh" mint --provider codex --sid sG --codex-home "$HOME/.codex-accounts/cx1" >/dev/null
GH=$(bash "$BIN/fleet-session-cred.sh" codex-home --sid sG --real "$HOME/.codex-accounts/cx1")
mkdir -p "$GH/tmp" "$SB/dbin"
cat > "$SB/dbin/fake-codex-app-server.py" <<'PY'
import sys, time
f = open(sys.argv[1], "w")
open(sys.argv[2], "w").write("up")
time.sleep(120)
PY
( python3 "$SB/dbin/fake-codex-app-server.py" "$GH/tmp/daemon.sock" "$SB/daemon.up" </dev/null >/dev/null 2>&1 & echo $! > "$SB/daemon.pid" )
DPID=$(cat "$SB/daemon.pid")
i=0; while [ ! -s "$SB/daemon.up" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
rows() { ( . "$BIN/fleet-lib.sh"; _fleet_codex_cred_daemons ) | awk -F'\t' -v p="$DPID" '$1==p {print $3 " " $4}'; }
check "G: a live session's daemon is not a candidate" "" "$(rows)"
bash "$BIN/fleet-session-cred.sh" revoke --sid sG
check "G: the session's .revoked mark" yes "$([ -e "$GH/.revoked" ] && echo yes || echo no)"
check "G: once revoked its daemon is a candidate (kind codexhome, key the sid)" "codexhome sG" "$(rows)"
kill "$DPID" 2>/dev/null; DPID=''

# ── H: the ambient login, and a proxy that will not serve ────────────────────
bash "$BIN/fleet-session-cred.sh" mint --provider claude --sid sH >/dev/null 2>&1
check "H: trusted route, no account → exit 4 (nothing to bind)" 4 "$?"
mkdir -p "$SB/no-accounts"
run_claude h FLEET_CRED_SID=sH FLEET_ACCOUNT_LABEL='' FLEET_ACCOUNTS_DIR="$SB/no-accounts"
OUT="$SB/out/h"
check "H: … and the launch goes on as before (no base URL)" "0:" "$(cat "$OUT/rc"):$(envv ANTHROPIC_BASE_URL)"
run_claude h2 FLEET_CRED_SID=sH2 FLEET_ACCOUNT_LABEL=bad/label
OUT="$SB/out/h2"
check "H: the proxy will not mint → the launch refuses" 1 "$(cat "$OUT/rc")"
check "H: … and never ran the agent" no "$([ -e "$OUT/env" ] && echo yes || echo no)"
grep -q 'REAL-' "$SB/cred-proxy.log" && fail "rails: a real token in the proxy log" || pass "rails: no real token in the proxy log"

[ "$FAIL" = 0 ] && { echo "session-cred selftest: OK"; exit 0; }
echo "session-cred selftest: FAILED"; exit 1
