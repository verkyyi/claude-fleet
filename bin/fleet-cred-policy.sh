#!/bin/bash
# fleet-cred-policy.sh — which subscriptions a machine and a person may use
# (issue #3043): the hub's two allowlists and what they leave.
#
#   fleet-cred-policy.sh show [--json]                        every allowlist
#   fleet-cred-policy.sh effective [--machine M] [--principal P] [--json]
#                                                             each account: allowed, or why not
#   fleet-cred-policy.sh set   node|user <id> <subscription-id>…   only these
#   fleet-cred-policy.sh deny  node|user <id>                       none at all ([])
#   fleet-cred-policy.sh clear node|user <id>                       no list: unrestricted again
#
# effective = eligible (the person's own + the shared pool, after revocation,
# trust and separation) ∩ the machine's list ∩ the person's list. An OS login
# is not a third list: it uses its hub owner's. <id> is a machine name (node)
# or a principal ID such as gh:2718137 (user). A subscription ID is a Claude
# account UUID or a Codex codex:account:<32 hex> — `effective` prints each
# account's; an account label never matches. A credential with no recorded
# UUID matches no list (record one: POST /v1/fleet/credentials action=bind).
#
# When it takes effect: the hub's central proxy within ~30 s; a node's next
# lease (every 15 min while any list exists; an older agent, and the very first
# list ever set, within its ≤ 6 h renewal), which removes a forbidden account's
# copy. A token already handed to a machine lives until its own expiry — an
# allowlist cannot revoke it at the provider. docs/SHARED-MACHINE.md «订阅白名单».
#
# Who may: the operator — a viewer token in CCQUOTA_VIEWER_TOKEN, read from the
# ENVIRONMENT only, handed to curl on stdin (`-H @-`), never in an argv.
# The hub: CCQUOTA_HUB_URL, else FLEET_HUB_URL (fleet.conf), else node.env's.
#
# Exit status: 0 done · 1 the hub could not be asked (no token / URL /
# unreachable; nothing changed) · 2 usage · 4 the hub refused (not the
# operator, a bad id, or a hub that predates #3043).
#
# Seams: FLEET_HUB_CURL (default `curl`) is the transport, for the selftest.
set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fleet-lib.sh
. "$BIN/fleet-lib.sh"

die() { printf 'fleet-cred-policy: %s\n' "$2" >&2; exit "$1"; }
usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }

[ $# -gt 0 ] || { usage >&2; die 2 'say show, effective, set, deny or clear'; }
ACTION=$1; shift
JSON='' MACHINE='' PRINCIPAL='' SCOPE='' ID=''
IDS=()
case "$ACTION" in
  show)
    case "$#:${1:-}" in 0:) ;; 1:--json) JSON=1 ;; *) die 2 'show [--json]' ;; esac ;;
  effective)
    while [ $# -gt 0 ]; do
      case "$1" in
        --machine) MACHINE=${2:-}; shift 2 || die 2 '--machine <name>' ;;
        --principal) PRINCIPAL=${2:-}; shift 2 || die 2 '--principal <id>' ;;
        --json) JSON=1; shift ;;
        *) die 2 "effective: unknown argument '$1'" ;;
      esac
    done
    [ -n "$MACHINE$PRINCIPAL" ] || die 2 'effective needs --machine and/or --principal' ;;
  set|deny|clear)
    [ $# -ge 2 ] || die 2 "$ACTION node|user <id>…"
    SCOPE=$1 ID=$2; shift 2
    case "$SCOPE" in node|user) ;; *) die 2 "scope is node or user, not '$SCOPE'" ;; esac
    if [ "$ACTION" = set ]; then
      [ $# -ge 1 ] || die 2 'set needs at least one subscription ID (deny for none)'
      IDS=("$@")
    else
      [ $# -eq 0 ] || die 2 "$ACTION takes no subscription IDs"
    fi ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; die 2 "unknown action '$ACTION'" ;;
esac

CRED_POLICY_PATH=/v1/fleet/cred-policy
CURL=${FLEET_HUB_CURL:-curl}
TIMEOUT=${FLEET_HUB_TIMEOUT:-15}
_TOK=${CCQUOTA_VIEWER_TOKEN:-}
[ -n "$_TOK" ] || die 1 "no CCQUOTA_VIEWER_TOKEN — the operator's call reads the hub's viewer token from the environment (never from a file)"
_URL=${CCQUOTA_HUB_URL:-${FLEET_HUB_URL:-}}
[ -n "$_URL" ] || _URL=$(_fleet_node_env_val CCQUOTA_HUB_URL 2>/dev/null)
[ -n "$_URL" ] || die 1 "no hub URL — set CCQUOTA_HUB_URL (or FLEET_HUB_URL in fleet.conf)"
_URL=${_URL%/}

# _call <method> <path> [<body>] — the hub's answer as "<json>\n<code>".
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

_answer() {
  local resp=$1 rc=$2 code json
  [ "$rc" -eq 0 ] && [ -n "$resp" ] || die 1 "hub unreachable ($_URL): curl exit $rc — nothing changed"
  code=$(printf '%s\n' "$resp" | tail -n 1)
  json=$(printf '%s\n' "$resp" | sed '$d')
  case "$code" in
    200) printf '%s' "$json" ;;
    400) die 4 "the hub refused it (400): $(printf '%s' "$json" | head -c 300)" ;;
    401|403) die 4 "the hub says this is not the operator ($code) — CCQUOTA_VIEWER_TOKEN must be the hub's viewer token" ;;
    404|405) die 4 "the hub has no $CRED_POLICY_PATH ($code) — it predates issue #3043; redeploy it" ;;
    *) die 4 "hub answered HTTP $code: $(printf '%s' "$json" | head -c 300)" ;;
  esac
}

case "$ACTION" in
  set|deny|clear)
    body=$(python3 -c '
import json, sys
act, scope, ident, ids = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
allow = ids if act == "set" else ([] if act == "deny" else None)
print(json.dumps({"scope": scope, "id": ident, "allow": allow}))
' "$ACTION" "$SCOPE" "$ID" ${IDS[@]+"${IDS[@]}"})
    resp=$(_call PUT "$CRED_POLICY_PATH" "$body"); rc=$?
    json=$(_answer "$resp" "$rc") || exit $?
    printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
a = d.get("allow")
what = "unrestricted" if a is None else ("deny all" if a == [] else " ".join(a))
print("cred-policy: SET %s %s: %s" % (sys.argv[1], sys.argv[2], what))
' "$SCOPE" "$ID" || exit 4
    exit 0 ;;
  show)
    resp=$(_call GET "$CRED_POLICY_PATH"); rc=$?
    json=$(_answer "$resp" "$rc") || exit $?
    [ -z "$JSON" ] || { printf '%s\n' "$json"; exit 0; }
    printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
n = 0
for scope, key in (("node", "nodes"), ("user", "users")):
    for s in d.get(key) or []:
        n += 1
        if s.get("error"):
            print("cred-policy: %s %s MALFORMED (denies all): %s" % (scope, s["id"], s["error"]))
        else:
            print("cred-policy: %s %s %s" % (scope, s["id"], " ".join(s["allow"]) or "(deny all)"))
if not n:
    print("cred-policy: no allowlists — every eligible subscription is usable (as before #3043)")
' || exit 4
    exit 0 ;;
  effective)
    q=$(python3 -c 'import sys, urllib.parse as u; print(u.urlencode({k: v for k, v in (("machine", sys.argv[1]), ("principal", sys.argv[2])) if v}))' "$MACHINE" "$PRINCIPAL")
    resp=$(_call GET "$CRED_POLICY_PATH?$q"); rc=$?
    json=$(_answer "$resp" "$rc") || exit $?
    [ -z "$JSON" ] || { printf '%s\n' "$json"; exit 0; }
    printf '%s' "$json" | python3 -c '
import json, sys
e = json.load(sys.stdin).get("effective") or {}
print("cred-policy: effective machine=%s principal=%s %s" % (e.get("machine") or "-", e.get("principal") or "-",
      "restricted" if e.get("restricted") else "unrestricted"))
for a in e.get("accounts") or []:
    who = "pool" if a["owner"] == "pool" else a["owner"]
    print("  %-5s %s/%s · %s · %s%s" % ("ALLOW" if a["allowed"] else "DENY", who, a["account"], a["provider"],
          a.get("account_uuid") or "(no account UUID)", "" if a["allowed"] else " — " + a.get("reason", "")))
' || exit 4
    exit 0 ;;
esac
