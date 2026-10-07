#!/bin/bash
# fleet-node-revoke.sh — take a machine's enrollment back (issue #1403, EPIC
# #1967 R5): its node token stops working everywhere, at once.
#
#   fleet-node-revoke.sh <machine>[:<login>] [--reason <text>]   by the roster's name
#   fleet-node-revoke.sh <ep_id> [--reason <text>]               by enrollment id
#
# What it does: POST /v1/fleet/nodes/revoke — the hub retires the endpoint
# (every route that takes its token answers it exactly like a token it never
# saw), closes the control link already open, revokes the session passes the
# node issued and its relay credential, and writes one `node_revoke` row to
# fleet_audit. There is no un-revoke: re-enroll the machine with a join code
# for a new token. `ccquota endpoint retire <id>` on the hub does the same
# minus the relay credential, which the hub drops when the link next speaks.
#
# A machine with several logins enrolled needs `<machine>:<login>`; an
# enrollment that never connected (a shipper token) is not on the roster —
# name it by id (`ccquota endpoint list` on the hub, or the dashboard).
#
# Who may: the operator — a viewer token in CCQUOTA_VIEWER_TOKEN, read from the
# ENVIRONMENT only, handed to curl on stdin (`-H @-`), never in an argv or a file.
# The hub: CCQUOTA_HUB_URL, else FLEET_HUB_URL (fleet.conf), else node.env's.
#
# Exit status (issue #683's convention):
#   0   revoked (or already was) — one `revoke:` line on stdout
#   1   the hub could not be asked: no token, no hub URL, or unreachable —
#       nothing changed (stderr says which)
#   2   usage
#   4   the hub refused: not the operator (401/403), no such enrollment (404),
#       a bad request (400), or a hub that predates #1403
#   5   the name is ambiguous or not on the roster — nothing was revoked
#
# Output:
#   revoke: REVOKED m9:alice ep_123 passes=2 relay=yes link=closed
#   revoke: ALREADY m9:alice ep_123
#
# Seams: FLEET_HUB_CURL (default `curl`) is the transport, for the selftest.
set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fleet-lib.sh
. "$BIN/fleet-lib.sh"

die() { printf 'fleet-node-revoke: %s\n' "$2" >&2; exit "$1"; }
usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; }

TARGET='' REASON=''
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --reason) [ $# -ge 2 ] || die 2 '--reason needs a text'; REASON=$2; shift 2 ;;
    -*) usage >&2; die 2 "unknown option '$1'" ;;
    *) [ -z "$TARGET" ] || die 2 'one machine (or enrollment id) at a time'; TARGET=$1; shift ;;
  esac
done
[ -n "$TARGET" ] || { usage >&2; die 2 'say which machine'; }
printf '%s' "$TARGET" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,63})?$' \
  || die 2 "'$TARGET' is not <machine>[:<login>] or an enrollment id"
[ "${#REASON}" -le 200 ] || die 2 '--reason is at most 200 characters'

_TOK=${CCQUOTA_VIEWER_TOKEN:-}
[ -n "$_TOK" ] || die 1 "no CCQUOTA_VIEWER_TOKEN — the operator's call reads the hub's viewer token from the environment (never from a file)"
_URL=${CCQUOTA_HUB_URL:-${FLEET_HUB_URL:-}}
[ -n "$_URL" ] || _URL=$(_fleet_node_env_val CCQUOTA_HUB_URL 2>/dev/null)
[ -n "$_URL" ] || die 1 "no hub URL — set CCQUOTA_HUB_URL (or FLEET_HUB_URL in fleet.conf)"
_URL=${_URL%/}

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
    404) die 4 "the hub knows no such enrollment, or has no revoke route (404: $(printf '%s' "$json" | head -c 200)) — a hub before #1403 needs a redeploy" ;;
    405) die 4 "the hub has no revoke route (405) — it predates #1403; redeploy it" ;;
    *) die 4 "hub answered HTTP $code: $(printf '%s' "$json" | head -c 300)" ;;
  esac
}

# The enrollment id: given (ep_…), or the roster's one row for machine[:login].
case "$TARGET" in
  ep_*) EPID=$TARGET ;;
  *)
    resp=$(_call GET /v1/nodes); rc=$?
    nodes=$(_answer "$resp" "$rc") || exit $?
    EPID=$(python3 - "$TARGET" "$nodes" <<'PY'
import json, sys
target, nodes = sys.argv[1], json.loads(sys.argv[2])
machine, _, login = target.partition(":")
machine = machine.lower().split(".")[0]
hits = []
for n in nodes.get("nodes") or []:
    m = (n.get("hostname") or "").lower().split(".")[0]
    if m == machine and (not login or n.get("os_user") == login) and n.get("endpoint_id"):
        hits.append(n)
ids = sorted({n["endpoint_id"] for n in hits})
if not ids:
    sys.stderr.write("fleet-node-revoke: %s is not on the hub's roster — name it by enrollment id (ep_…)\n" % target)
    sys.exit(5)
if len(ids) > 1:
    rows = ", ".join("%s:%s=%s" % (machine, n.get("os_user") or "?", n["endpoint_id"]) for n in hits)
    sys.stderr.write("fleet-node-revoke: %s names %d enrollments (%s) — say <machine>:<login> or the id\n" % (target, len(ids), rows))
    sys.exit(5)
print(ids[0])
PY
) || exit $?
    ;;
esac

body=$(python3 -c 'import json,sys; d={"endpoint_id": sys.argv[1]}; r=sys.argv[2]
if r: d["reason"]=r
print(json.dumps(d))' "$EPID" "$REASON")
resp=$(_call POST /v1/fleet/nodes/revoke "$body"); rc=$?
json=$(_answer "$resp" "$rc") || exit $?
printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if "already" not in d or d.get("endpoint_id") != sys.argv[1]:
    sys.stderr.write("fleet-node-revoke: the hub answered without a revoke verdict — it predates issue #1403; redeploy it\n")
    sys.exit(4)
who = ((d.get("hostname") or "").split(".")[0] or "?") + ":" + (d.get("os_user") or "?")
if d["already"]:
    print("revoke: ALREADY %s %s" % (who, d["endpoint_id"]))
else:
    print("revoke: REVOKED %s %s passes=%d relay=%s link=%s" % (who, d["endpoint_id"], d.get("passes") or 0,
          "yes" if d.get("relay") else "no", "closed" if d.get("link_closed") else "none"))
' "$EPID" || exit 4
