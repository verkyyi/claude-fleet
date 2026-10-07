#!/bin/bash
# fleet-run.sh — `fleet run claude|codex [args…]`: a Claude Code or Codex
# session on THIS computer, through its credential proxy (issue #2136, EPIC #2133 C6).
#
#   fleet run claude [claude args…]
#   fleet run codex  [codex args…]
#
# For a computer that only has the client (curl <hub>/install | sh): it runs no
# fleet, so none of a host's launchers (fleet-session-wrap → fleet-claude /
# fleet-codex) apply. This is the one launch there, and it never puts a
# subscription credential in the session:
#
#   1. `fleet-cred-proxy.sh ensure` — the local proxy, on 127.0.0.1
#   2. a worker assertion for this session, signed with this computer's node
#      token hash (node.env, read inside python, never exported — #1491) and
#      naming the computer's client fleet (uuid5(NAMESPACE_URL,
#      "fleet-client:"+hash), the hub's fleetid.ClientFleetID)
#   3. `fleet-session-cred.sh mint` — on an untrusted computer (the default) an
#      fcp-h1. pass borrowed from the hub, routed central; never a credential
#   4. the agent, wired exactly like fleet-claude.sh / fleet-codex.sh do it:
#      Claude: ANTHROPIC_BASE_URL + CLAUDE_CODE_OAUTH_TOKEN=<pass>;
#      Codex: the custom provider `fleet` (env_key FLEET_CODEX_SESSION_CRED) and
#      a credential-free CODEX_HOME mirror
#   5. at its exit: `fleet-session-cred.sh revoke` (the hub pass is DELETEd)
#
# FLEET_CRED_PROXY must be 1 (fleet.conf [common] or the environment) — off,
# this refuses (exit 3) and nothing else changes. The pass goes to the agent's
# environment only: never an argv, a file, a log (共同约定 3).
#
# Exit: the agent's own status · 1 no pass could be had · 2 usage · 3 switched off
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
CONF="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"

die() { printf 'fleet run: %s\n' "$1" >&2; exit "${2:-1}"; }

agent="${1:-}"; [ $# -gt 0 ] && shift
case "$agent" in
  claude|codex) ;;
  -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die 'say claude or codex: fleet run claude|codex [args…]' 2 ;;
esac
bash "$BIN/fleet-session-cred.sh" on \
  || die 'FLEET_CRED_PROXY is off — put FLEET_CRED_PROXY=1 in fleet.conf [common] (or the environment) first' 3
exe=$(command -v "$agent") || die "$agent is not on PATH"

# The assertion: this session, in this computer's client fleet. Five minutes is
# enough — the hub reads it once, at the pass's issue.
a=$(FSC_CONF="$CONF" python3 -I - <<'PY'
import base64, hashlib, hmac, json, os, socket, sys, time, uuid
ne = {}
try:
    for line in open(os.path.join(os.environ["FSC_CONF"], "node.env")):
        line = line.strip()
        if line.startswith("export "):
            line = line[7:]
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            ne[k.strip()] = v.strip().strip('"').strip("'")
except OSError:
    pass
tok = ne.get("CCQUOTA_TOKEN", "")
if not tok:
    sys.exit("fleet run: this computer has no node token (node.env) — run `fleet node join` first")
h = hashlib.sha256(tok.encode()).hexdigest()
fleet = str(uuid.uuid5(uuid.NAMESPACE_URL, "fleet-client:" + h))
fid = str(uuid.uuid4())
now = int(time.time())
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
body = {"v": 1, "worker_id": fleet + "/" + fid, "fleet_uuid": fleet, "fid": fid, "key": "",
        "repo": "", "issue": "", "origin": "", "node": socket.gethostname().split(".", 1)[0],
        "iat": now, "exp": now + 300}
head = "fwa1." + b64(json.dumps(body, sort_keys=True, separators=(",", ":")).encode())
print(head + "." + b64(hmac.new(h.encode(), head.encode(), hashlib.sha256).digest()))
PY
) || exit 1

sid="c-$$-$(date +%s)"
export FLEET_SESSION_WRAP=$$
px=$(FLEET_CRED_PROXY=1 FLEET_WORKER_ASSERT="$a" bash "$BIN/fleet-session-cred.sh" mint --provider "$agent" --sid "$sid" \
      ${CODEX_HOME:+--codex-home "$CODEX_HOME"})
rc=$?
unset a
case "$rc" in
  0) ;;
  4) die 'this computer is trusted but holds no account for the proxy to bind — nothing to route through' ;;
  *) die 'no session credential could be had (fleet cred-proxy doctor; logs/cred-proxy.log)' ;;
esac
IFS=$'\t' read -r route port cred <<< "$px"
unset px
done_run() { bash "$BIN/fleet-session-cred.sh" revoke --sid "$sid" >/dev/null 2>&1; }
printf 'fleet run: %s via %s (127.0.0.1:%s)\n' "$agent" "$route" "$port" >&2

unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_SECURESTORAGE_CONFIG_DIR OPENAI_API_KEY
if [ "$agent" = claude ]; then
  unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
  ANTHROPIC_BASE_URL="http://127.0.0.1:$port" CLAUDE_CODE_OAUTH_TOKEN="$cred" \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 "$exe" "$@"
  rc=$?
else
  real="${CODEX_HOME:-$HOME/.codex}"
  mkdir -p "$real" || { done_run; die "cannot make $real"; }
  home=$(bash "$BIN/fleet-session-cred.sh" codex-home --sid "$sid" --real "$real") \
    || { done_run; die 'could not make this session a credential-free CODEX_HOME'; }
  CODEX_HOME="$home" FLEET_CODEX_SESSION_CRED="$cred" "$exe" \
    -c 'model_provider="fleet"' \
    -c "model_providers.fleet={name=\"fleet\",base_url=\"http://127.0.0.1:$port/codex\",env_key=\"FLEET_CODEX_SESSION_CRED\",wire_api=\"responses\"}" \
    -c 'features.plugins=false' -c 'features.apps=false' -c 'analytics.enabled=false' "$@"
  rc=$?
fi
unset cred
done_run
exit "$rc"
