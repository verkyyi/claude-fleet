#!/bin/bash
# real-check.sh — the ONE command that confirms doc §10's open points on a machine
# with a VALID ChatGPT login (issue #1912). Research only; not part of the install.
#
#   extras/cred-proxy/sim/real-check.sh [ACCOUNT] [CODEX]
#
# ACCOUNT = whose auth.json the proxy reads: `default` (~/.codex/auth.json, the
# default) or a label under ~/.codex-accounts/. CODEX = the codex CLI (default:
# `codex` on PATH). It never logs in, never refreshes, never writes an auth.json:
# it reads one in the proxy's memory per request. The session gets a fresh
# CODEX_HOME with no auth.json and only the proxy's fcp1 credential.
#
# Runs two turns through the proxy — `Reply with exactly: PONG`, then one shell
# tool call — and prints the redacted proxy log: status, which headers went up,
# which x-codex-* headers came back. Everything binds 127.0.0.1 and stops on exit.
#
# Seam (selftest only): CRED_PROXY_CODEX_UPSTREAM / CRED_PROXY_CODEX_HOMES /
# CRED_PROXY_CODEX_AUTH point it at sim/fake_chatgpt.py instead.
set -uo pipefail
ACCT=${1:-default}
CODEX=${2:-$(command -v codex || true)}
[ -n "$CODEX" ] || { echo "real-check: no codex CLI (pass its path as the 2nd argument)" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
PROXY="$HERE/../cred_proxy.py"
D=$(mktemp -d "${TMPDIR:-/tmp}/cxreal.XXXXXX")
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 -I "$PROXY" serve --port "$PORT" --state "$D/px" --log "$D/proxy.log" --max-seconds 600 \
  --codex-upstream "${CRED_PROXY_CODEX_UPSTREAM:-https://chatgpt.com/backend-api/codex}" \
  --codex-homes "${CRED_PROXY_CODEX_HOMES:-$HOME/.codex-accounts}" \
  --codex-auth "${CRED_PROXY_CODEX_AUTH:-$HOME/.codex/auth.json}" 2>/dev/null &
PXPID=$!
stop() { kill "$PXPID" 2>/dev/null; wait "$PXPID" 2>/dev/null; rm -rf "$D"; }
for _ in 1 2 3 4 5 6 7 8 9 10; do
  python3 -c "import socket; socket.create_connection(('127.0.0.1',$PORT),0.2)" 2>/dev/null && break
  python3 -c 'import time; time.sleep(0.2)'
done
TOK=$(python3 -I "$PROXY" mint --state "$D/px" --account "$ACCT" --sid real-check --ttl 900)
mkdir -p "$D/home" "$D/work"
cat > "$D/home/config.toml" <<EOF
model_provider = "fleetproxy"
check_for_update_on_startup = false

[model_providers.fleetproxy]
name = "fleet cred proxy"
base_url = "http://127.0.0.1:$PORT/codex"
wire_api = "responses"
env_key = "FLEET_PROXY_CRED"

[features]
plugins = false
apps = false

[analytics]
enabled = false
EOF
run() {
  (cd "$D/work" && perl -e 'alarm shift; exec @ARGV' 180 env -i HOME="$HOME" PATH="$PATH" \
    CODEX_HOME="$D/home" FLEET_PROXY_CRED="$TOK" "$CODEX" exec --skip-git-repo-check "$@" </dev/null)
}
echo "== 1. codex exec 'Reply with exactly: PONG'   (account: $ACCT, through 127.0.0.1:$PORT)"
run 'Reply with exactly: PONG' 2>"$D/err1"; rc1=$?
echo "rc=$rc1"; [ "$rc1" = 0 ] || grep -E 'ERROR|error' "$D/err1" | tail -3
echo "== 2. one shell tool call"
run --sandbox workspace-write 'Run the shell command `echo REAL-CHECK-$((6*7))` and reply with only its output.' 2>"$D/err2"; rc2=$?
echo "rc=$rc2"; [ "$rc2" = 0 ] || grep -E 'ERROR|error' "$D/err2" | tail -3
echo "== proxy log (credentials redacted)"
python3 - "$D/proxy.log" <<'PY'
import json, sys
for l in open(sys.argv[1]):
    d = json.loads(l)
    if d.get("ev") == "fwd":
        print("%s %s -> %s %s  ttfb=%sms  up_hdrs=%s" % (d["m"], d["path"], d["up"], d["status"], d["ttfb_ms"], ",".join(d["sent"])))
        print("   back: %s" % (", ".join(d["rl"]) or "(no x-codex-* / ratelimit header)"))
    else:
        print({k: v for k, v in d.items() if k != "hdrs"})
PY
echo "== rate limits in the session's rollout (the fleet's Codex reading)"
f=$(ls -t "$D"/home/sessions/*/*/*/rollout-*.jsonl 2>/dev/null | head -1)
[ -n "$f" ] && grep '"token_count"' "$f" | tail -1 | python3 -c 'import sys,json; p=json.loads(sys.stdin.read())["payload"]; print(json.dumps(p.get("rate_limits")))' || echo "(no rollout)"
stop
[ "$rc1" = 0 ] && [ "$rc2" = 0 ]
