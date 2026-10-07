#!/bin/bash
# fleet-run-selftest.sh — a session on a client-only computer (issue #2136,
# EPIC #2133 C6): bin/fleet-run.sh with a stub fleet-session-cred.sh and stub
# agents, and bin/fleet-cred-scan.py in a sandbox HOME. No network, no tmux.
# The hub's half (fleetid.ClientFleetID, the pass for a client fleet) is pinned
# by Go: TestClientFleetIDMatchesPython, TestSessionCredClientComputer.
#
# What it pins:
#   A. usage     no agent / an unknown one → exit 2
#   B. off       FLEET_CRED_PROXY=0 → exit 3, nothing minted, no agent run
#   C. assert    the mint gets a worker assertion that verifies with the node
#                token's sha256 and names uuid5(NAMESPACE_URL, "fleet-client:"+hash)
#                — the token never in the stub's argv
#   D. claude    ANTHROPIC_BASE_URL=127.0.0.1:<port>, CLAUDE_CODE_OAUTH_TOKEN =
#                the pass, ANTHROPIC_API_KEY gone, args passed through, the
#                agent's exit status kept, revoke at exit
#   E. codex     the `fleet` provider on <port>/codex, env_key carries the pass,
#                CODEX_HOME = the mirror, revoke at exit
#   F. refused   mint fails → exit 1, no agent run
#   G. scan      a readable pool credential = 1 route (real=1); denied = 0; a
#                credential-shaped env value counts with no --hashes; `hashes`
#                prints digests, never a token
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKS=0
fail() { printf 'fleet-run selftest FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }
TMPB=${TMPDIR:-/tmp}
WORK="$(mktemp -d "${TMPB%/}/frun.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

SB="$WORK/bin"; mkdir -p "$SB" "$WORK/path" "$WORK/home" "$WORK/conf"
ln -s "$BIN/fleet-run.sh" "$SB/fleet-run.sh"
TOKEN="node-token-$$"
printf 'CCQUOTA_TOKEN=%s\nCCQUOTA_HUB_URL=http://127.0.0.1:9\n' "$TOKEN" > "$WORK/conf/node.env"
# the stub: records what mint was handed; FAKE_MINT_RC fails it
cat > "$SB/fleet-session-cred.sh" <<'SH'
#!/bin/bash
log="$FAKE_LOG"
case "$1" in
  on) [ "${FLEET_CRED_PROXY:-0}" = 1 ] ;;
  mint) printf '%s\n' "$*" >> "$log"; printf '%s\n' "${FLEET_WORKER_ASSERT:-}" > "$FAKE_ASSERT"
        [ "${FAKE_MINT_RC:-0}" = 0 ] || exit "$FAKE_MINT_RC"
        printf 'central\t4242\tfcp-h1.PASS\n' ;;
  codex-home) d="$FAKE_DIR/mirror"; mkdir -p "$d"; printf '%s\n' "$d" ;;
  revoke) printf '%s\n' "$*" >> "$log" ;;
esac
SH
chmod +x "$SB/fleet-session-cred.sh"
for a in claude codex; do
  cat > "$WORK/path/$a" <<'SH'
#!/bin/bash
{ printf 'argv=%s\n' "$*"
  printf 'base=%s\n' "${ANTHROPIC_BASE_URL:-}"
  printf 'tok=%s\n' "${CLAUDE_CODE_OAUTH_TOKEN:-}"
  printf 'apikey=%s\n' "${ANTHROPIC_API_KEY:-}"
  printf 'cx=%s\n' "${FLEET_CODEX_SESSION_CRED:-}"
  printf 'home=%s\n' "${CODEX_HOME:-}"; } > "$FAKE_OUT"
exit 7
SH
  chmod +x "$WORK/path/$a"
done
export FAKE_LOG="$WORK/log" FAKE_ASSERT="$WORK/assert" FAKE_OUT="$WORK/out" FAKE_DIR="$WORK"
run() { env HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" PATH="$WORK/path:/usr/bin:/bin" \
          ANTHROPIC_API_KEY=leftover "$@" "$SB/fleet-run.sh"; }

# A. usage
run FLEET_CRED_PROXY=1 >/dev/null 2>&1; [ $? = 2 ] || fail 'A: no agent should exit 2'; ok
"$SB/fleet-run.sh" vim >/dev/null 2>&1; [ $? = 2 ] || fail 'A: unknown agent should exit 2'; ok

# B. off
: > "$FAKE_LOG"; rm -f "$FAKE_OUT"
env HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" PATH="$WORK/path:/usr/bin:/bin" FLEET_CRED_PROXY=0 \
  "$SB/fleet-run.sh" claude -p hi >/dev/null 2>&1
[ $? = 3 ] || fail 'B: switched off should exit 3'; ok
[ ! -s "$FAKE_LOG" ] && [ ! -e "$FAKE_OUT" ] || fail 'B: off still minted or ran the agent'; ok

# C + D. claude
: > "$FAKE_LOG"
env HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" PATH="$WORK/path:/usr/bin:/bin" FLEET_CRED_PROXY=1 \
  ANTHROPIC_API_KEY=leftover "$SB/fleet-run.sh" claude -p 'say PONG' 2>/dev/null
[ $? = 7 ] || fail "D: the agent's exit status was not kept"; ok
grep -q "$TOKEN" "$FAKE_LOG" && fail 'C: the node token reached an argv'; ok
python3 -I - "$TOKEN" "$(cat "$FAKE_ASSERT")" <<'PY' || fail 'C: the assertion does not verify / names the wrong fleet'
import base64, hashlib, hmac, json, sys, uuid
tok, a = sys.argv[1], sys.argv[2]
h = hashlib.sha256(tok.encode()).hexdigest()
head, _, sig = a.rpartition(".")
want = base64.urlsafe_b64encode(hmac.new(h.encode(), head.encode(), hashlib.sha256).digest()).rstrip(b"=").decode()
assert sig == want, "signature"
p = head.split(".")[1]
c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
fleet = str(uuid.uuid5(uuid.NAMESPACE_URL, "fleet-client:" + h))
assert c["v"] == 1 and c["fleet_uuid"] == fleet and c["worker_id"] == fleet + "/" + c["fid"], c
assert 0 < c["exp"] - c["iat"] <= 300, c
PY
ok
grep -q '^argv=-p say PONG$' "$FAKE_OUT" || fail 'D: args not passed through'; ok
grep -q '^base=http://127.0.0.1:4242$' "$FAKE_OUT" || fail 'D: ANTHROPIC_BASE_URL'; ok
grep -q '^tok=fcp-h1.PASS$' "$FAKE_OUT" || fail 'D: CLAUDE_CODE_OAUTH_TOKEN is not the pass'; ok
grep -q '^apikey=$' "$FAKE_OUT" || fail 'D: ANTHROPIC_API_KEY survived'; ok
grep -q '^mint --provider claude --sid c-' "$FAKE_LOG" || fail 'D: mint not asked for claude'; ok
grep -q '^revoke --sid c-' "$FAKE_LOG" || fail 'D: no revoke at exit'; ok

# E. codex
: > "$FAKE_LOG"
env HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" PATH="$WORK/path:/usr/bin:/bin" FLEET_CRED_PROXY=1 \
  "$SB/fleet-run.sh" codex exec hi 2>/dev/null
grep -q 'model_provider="fleet"' "$FAKE_OUT" || fail 'E: no fleet provider'; ok
grep -q 'base_url="http://127.0.0.1:4242/codex"' "$FAKE_OUT" || fail 'E: provider base_url'; ok
grep -q 'exec hi$' "$FAKE_OUT" || fail 'E: args not passed through'; ok
grep -q '^cx=fcp-h1.PASS$' "$FAKE_OUT" || fail 'E: env_key does not carry the pass'; ok
grep -q "^home=$WORK/mirror\$" "$FAKE_OUT" || fail 'E: CODEX_HOME is not the mirror'; ok
[ -d "$WORK/home/.codex" ] || fail 'E: the real home was not made'; ok
grep -q '^revoke --sid c-' "$FAKE_LOG" || fail 'E: no revoke at exit'; ok

# F. refused
rm -f "$FAKE_OUT"
env HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" PATH="$WORK/path:/usr/bin:/bin" FLEET_CRED_PROXY=1 FAKE_MINT_RC=1 \
  "$SB/fleet-run.sh" claude >/dev/null 2>&1
[ $? = 1 ] && [ ! -e "$FAKE_OUT" ] || fail 'F: a refused mint must exit 1 and run nothing'; ok

# G. scan
SH_HOME="$WORK/shome"; mkdir -p "$SH_HOME/.config/claude-fleet/accounts/a.hub" "$WORK/cwd"
CRED="$SH_HOME/.config/claude-fleet/accounts/a.hub/.credentials.json"
REAL="sk-ant-oat01-$(printf 'A%.0s' $(seq 1 40))"
printf '{"claudeAiOauth":{"accessToken":"%s"}}' "$REAL" > "$CRED"
scan() { (cd "$WORK/cwd" && env -u FLEET_CONF_DIR -u XDG_CONFIG_HOME HOME="$SH_HOME" "$@" python3 "$BIN/fleet-cred-scan.py" ${ARGS[@]+"${ARGS[@]}"}); }
ARGS=(hashes); scan > "$WORK/hashes" 2>/dev/null || fail 'G: hashes failed'
grep -q "$REAL" "$WORK/hashes" && fail 'G: hashes printed a token'; ok
[ "$(grep -c '^[0-9a-f]\{64\}$' "$WORK/hashes")" = 1 ] || fail 'G: hashes should print one digest'; ok
ARGS=(scan --no-hub --hashes "$WORK/hashes")
out=$(scan); [ $? = 1 ] || fail 'G: a readable pool credential must exit 1'; ok
printf '%s\n' "$out" | grep -q '^scan: routes-with-credential=1 ' || fail "G: readable: $out"; ok
printf '%s\n' "$out" | grep -q "$REAL" && fail 'G: scan printed a token'; ok
chmod 000 "$CRED"
if [ ! -r "$CRED" ]; then   # root reads anyway — the leg needs a real denial
  out=$(scan); [ $? = 0 ] || fail "G: denied should be 0 routes: $out"; ok
fi
chmod 600 "$CRED"; rm -f "$CRED"
ARGS=(scan --no-hub)
out=$(scan LEAK="sk-ant-oat01-$(printf 'B%.0s' $(seq 1 40))")
printf '%s\n' "$out" | grep -q '^scan: routes-with-credential=1 ' || fail "G: env leak not counted: $out"; ok

echo "fleet-run selftest: PASS ($CHECKS checks)"
