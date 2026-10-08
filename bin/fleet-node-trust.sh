#!/bin/bash
# fleet-node-trust.sh — which machines the hub trusts with subscription
# credentials (issue #1968, EPIC #1967 C1).
#
#   fleet-node-trust.sh set <machine> trusted|untrusted   the operator marks a machine
#   fleet-node-trust.sh status [<machine>]                every machine's trust (or one)
#   fleet-node-trust.sh self                              this machine's, as the hub tells its node
#   fleet-node-trust.sh self --json                       the hub's whole word on this login
#                                                         (GET /v1/node/self as it came: trust,
#                                                         compute_off / compute_why — fleet-doctor's
#                                                         `compute` row, issue #2480)
#
# What trust does: POST /v1/node/credentials answers only a machine the
# operator marked trusted; any other gets 403 untrusted_node (and a deny row in
# the hub's credential audit). The word is the hub's record, the setting
# `fleet.node_trust.<machine>`, and the operator's alone: a machine has no route
# that sets it, for itself or another. No setting = untrusted — a machine that
# joins later, a computer that only holds a connection certificate. When this
# shipped, every machine with an active fleet account was marked trusted once
# (m4 / m5 lease exactly what they leased before).
#
# Who may:
#   set / status  the operator: a viewer token in CCQUOTA_VIEWER_TOKEN, read from
#                 the ENVIRONMENT only — this script never writes it anywhere,
#                 and hands it to curl on stdin (`-H @-`), never in an argv
#   self          this login's node token (node.env, read inside the one
#                 subshell that calls the hub, never exported: issue #1491)
#
# The hub: CCQUOTA_HUB_URL, else FLEET_HUB_URL (fleet.conf), else node.env's.
#
# Exit status (issue #683's convention):
#   0   done — the SET line / the status lines printed
#   1   the hub could not be asked: no token, no hub URL, or unreachable —
#       nothing changed (stderr says which)
#   2   usage
#   4   the hub refused: not the operator (401/403), a bad name / value (400),
#       or a hub that predates #1968 (no trust in its answer)
#   10  `self` with the hub module off (CCQUOTA_FLEET≠1): no hub, nothing asked
#
# Output, one line per machine on stdout:
#   trust: SET m9 trusted
#   trust: m4 trusted
#   trust: m9 untrusted
#
# Seams: FLEET_HUB_CURL (default `curl`) is the transport, for the selftest.
set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fleet-lib.sh
. "$BIN/fleet-lib.sh"

die() { printf 'fleet-node-trust: %s\n' "$2" >&2; exit "$1"; }
usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; }

ACTION='' MACHINE='' VALUE='' SELF_JSON=''
[ $# -gt 0 ] || { usage >&2; die 2 'say set, status or self'; }
case "$1" in
  set)
    [ $# -eq 3 ] || die 2 'set <machine> trusted|untrusted'
    ACTION=set MACHINE=$2 VALUE=$3 ;;
  status)
    [ $# -le 2 ] || die 2 'status [<machine>]'
    ACTION=status MACHINE=${2:-} ;;
  self)
    SELF_JSON=''
    case "$#:${2:-}" in 1:) ;; 2:--json) SELF_JSON=1 ;; *) die 2 'self takes no argument but --json' ;; esac
    ACTION=self ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; die 2 "unknown action '$1'" ;;
esac
if [ -n "$MACHINE" ]; then
  printf '%s' "$MACHINE" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$' || die 2 "'$MACHINE' is not a machine name"
fi
case "$ACTION:$VALUE" in
  set:trusted|set:untrusted|status:|self:) ;;
  *) die 2 "a machine is trusted or untrusted, not '$VALUE'" ;;
esac

CURL=${FLEET_HUB_CURL:-curl}
TIMEOUT=${FLEET_HUB_TIMEOUT:-15}

# _call <method> <path> [<body>] — the hub's answer as "<json>\n<code>". The
# bearer goes to curl on stdin, never in its argv.
_call() {
  local method=$1 pth=$2 body=${3:-}
  if [ -n "$body" ]; then
    printf 'Authorization: Bearer %s\n' "$_TOK" | "$CURL" -sS --max-time "$TIMEOUT" -o - -w '\n%{http_code}' \
      -H @- -H 'Content-Type: application/json' -X "$method" --data-binary "$body" "$_URL$pth" 2>/dev/null
  else
    printf 'Authorization: Bearer %s\n' "$_TOK" | "$CURL" -sS --max-time "$TIMEOUT" -o - -w '\n%{http_code}' \
      -H @- "$_URL$pth" 2>/dev/null
  fi
}

# _answer <resp> <rc> — check the transport and the code; the JSON on stdout.
_answer() {
  local resp=$1 rc=$2 code json
  [ "$rc" -eq 0 ] && [ -n "$resp" ] || die 1 "hub unreachable (${_URL:-?}): curl exit $rc — nothing changed"
  code=$(printf '%s\n' "$resp" | tail -n 1)
  json=$(printf '%s\n' "$resp" | sed '$d')
  case "$code" in
    200) printf '%s' "$json" ;;
    400) die 4 "the hub refused it (400): $(printf '%s' "$json" | head -c 300)" ;;
    401|403) die 4 "the hub says this is not the operator ($code) — CCQUOTA_VIEWER_TOKEN must be the hub's viewer token, not a person's or a node's" ;;
    404|405) die 4 "the hub has no such route ($code) — is the hub module on (CCQUOTA_FLEET=1)?" ;;
    *) die 4 "hub answered HTTP $code: $(printf '%s' "$json" | head -c 300)" ;;
  esac
}

if [ "$ACTION" = self ]; then
  if [ "${CCQUOTA_FLEET:-0}" != 1 ]; then
    printf 'fleet-node-trust: the hub module is off (CCQUOTA_FLEET≠1) — no hub, nothing asked\n' >&2
    exit 10
  fi
  if why=$(_fleet_hub_creds_missing); then
    die 1 "$why"
  fi
  # One subshell: the node token enters its environment and dies with it (#1491).
  resp=$(_fleet_hub_env; _TOK=$CCQUOTA_TOKEN _URL=${CCQUOTA_HUB_URL%/}; _call GET /v1/node/self); rc=$?
  _URL=${CCQUOTA_HUB_URL:-$(_fleet_node_env_val CCQUOTA_HUB_URL)}
  json=$(_answer "$resp" "$rc") || exit $?
  [ -z "$SELF_JSON" ] || { printf '%s\n' "$json"; exit 0; }
  printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
host = (d.get("hostname") or "").split(".")[0] or "this machine"
t = d.get("trust")
if t not in ("trusted", "untrusted"):
    sys.stderr.write("fleet-node-trust: the hub answered without a trust word — it predates issue #1968; redeploy it\n")
    sys.exit(4)
print("trust: %s %s" % (host, t))
' || exit 4
  exit 0
fi

_TOK=${CCQUOTA_VIEWER_TOKEN:-}
[ -n "$_TOK" ] || die 1 "no CCQUOTA_VIEWER_TOKEN — the operator's call reads the hub's viewer token from the environment (never from a file)"
_URL=${CCQUOTA_HUB_URL:-${FLEET_HUB_URL:-}}
[ -n "$_URL" ] || _URL=$(_fleet_node_env_val CCQUOTA_HUB_URL 2>/dev/null)
[ -n "$_URL" ] || die 1 "no hub URL — set CCQUOTA_HUB_URL (or FLEET_HUB_URL in fleet.conf)"
_URL=${_URL%/}

if [ "$ACTION" = set ]; then
  key="fleet.node_trust.$(printf '%s' "$MACHINE" | tr 'A-Z' 'a-z' | cut -d. -f1)"
  body=$(printf '{"key":"%s","value":"%s"}' "$key" "$VALUE")
  resp=$(_call PUT /v1/fleet/settings "$body"); rc=$?
  json=$(_answer "$resp" "$rc") || exit $?
  printf '%s' "$json" | python3 -c '
import json, sys
k, v = sys.argv[1], sys.argv[2]
eff = (json.load(sys.stdin).get("effective") or {})
if eff.get(k) != v:
    sys.stderr.write("fleet-node-trust: the hub took the call but does not hold %s=%s — it predates issue #1968; redeploy it\n" % (k, v))
    sys.exit(4)
print("trust: SET %s %s" % (k[len("fleet.node_trust."):], v))
' "$key" "$VALUE" || exit 4
  exit 0
fi

# status: the roster's machines (each carries trust) + any machine the
# settings name that is not on the roster (marked before it ever connected).
resp=$(_call GET /v1/nodes); rc=$?
nodes=$(_answer "$resp" "$rc") || exit $?
resp=$(_call GET /v1/fleet/settings); rc=$?
settings=$(_answer "$resp" "$rc") || exit $?
python3 - "$MACHINE" "$nodes" "$settings" <<'PY' || exit 4
import json, sys
want, nodes, settings = sys.argv[1].lower().split(".")[0], json.loads(sys.argv[2]), json.loads(sys.argv[3])
pre = "fleet.node_trust."
out, seen_trust = {}, False
for n in nodes.get("nodes") or []:
    m = (n.get("hostname") or "").lower().split(".")[0]
    if not m:
        continue
    t = n.get("trust")
    if t:
        seen_trust = True
    out.setdefault(m, t or "?")
for k, v in (settings.get("settings") or {}).items():
    if k.startswith(pre) and v:
        out.setdefault(k[len(pre):], v if v == "trusted" else "untrusted")
if nodes.get("nodes") and not seen_trust:
    sys.stderr.write("fleet-node-trust: the hub's roster carries no trust — it predates issue #1968; redeploy it\n")
    sys.exit(4)
rows = sorted(out.items())
if want:
    rows = [r for r in rows if r[0] == want] or [(want, "untrusted")]
for m, t in rows:
    print("trust: %s %s" % (m, t))
PY
