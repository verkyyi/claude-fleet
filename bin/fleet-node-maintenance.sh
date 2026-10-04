#!/bin/bash
# fleet-node-maintenance.sh — mark THIS machine 维护中 on the hub, or end it
# (issue #1427, EPIC #1419 C8).
#
#   fleet-node-maintenance.sh enter [--reason '<why>']   flag this machine
#   fleet-node-maintenance.sh leave                       clear the flag
#   fleet-node-maintenance.sh status                      what the hub says
#
# What 维护中 does (docs/MULTI-MACHINE-OPS.md is the runbook this is one step
# of): the hub keeps placing nothing new on a flagged machine — not a spawn's
# `--node auto`, not a start that names it, not a `move plan` — so
# `fleet-spot-evacuate.sh` (= `fleet-move.sh --rebalance --max all` per fleet)
# run right after finds every idle session a better home, and the sessions
# still working here finish on their own. The flag is the hub's record, not
# this machine's: it survives the outage and a hub restart, the machine comes
# back as 维护中 until `leave`, and the roster (/nodes), the sidebar's machine
# line (◐) and `fleet connect` all read it. Lost still wins: once the agent
# here stops reporting the hub says lost, and the 30-minute lease release
# runs as for any lost node.
#
# Who may: the machine itself — this script speaks with the login's node
# token (node.env, read inside the one subshell that calls the hub, never
# exported: issue #1491), and the hub flags the machine that token's agent
# reports from. The operator flags ANY machine from the /nodes page (the
# card's button) or `PUT /v1/fleet/settings {key: fleet.node_maintenance.<m>}`.
#
# Exit status (issue #683's convention):
#   0   done — ENTERED / LEFT / the status line printed
#   1   the hub could not be asked: no node token, or unreachable — nothing
#       changed on the hub (stderr says which)
#   2   usage
#   4   the hub refused: this hub predates #1427 (no /v1/node/maintenance —
#       redeploy it), or the node has never reported (409)
#   10  the hub module is off (CCQUOTA_FLEET≠1): nothing touched — a
#       single-machine fleet has no hub to tell, and no other machine to spare
#
# Output, one line on stdout:
#   maintenance: ENTERED m5 · 升级 macOS · since 2026-10-05T12:00:00Z · by node:verkyyi@m5
#   maintenance: LEFT m5
#   maintenance: m5 online | maintenance · <reason> · since … | lost
#
# Seams: FLEET_HUB_CURL (default `curl`) is the transport, for the selftest;
# FLEET_CONF_DIR/node.env is where the token comes from (fleet_node_env_file).
set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fleet-lib.sh
. "$BIN/fleet-lib.sh"

die() { printf 'fleet-node-maintenance: %s\n' "$2" >&2; exit "$1"; }
usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; }

ACTION='' REASON=''
while [ $# -gt 0 ]; do
  case "$1" in
    enter|leave|status) [ -z "$ACTION" ] || die 2 "one action only (got $ACTION and $1)"; ACTION=$1; shift ;;
    --reason) [ -n "${2:-}" ] || die 2 '--reason needs text'; REASON=$2; shift 2 ;;
    --reason=*) REASON=${1#--reason=}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die 2 "unknown argument '$1'" ;;
  esac
done
[ -n "$ACTION" ] || { usage >&2; die 2 'say enter, leave or status'; }
[ -z "$REASON" ] || [ "$ACTION" = enter ] || die 2 "--reason goes with enter"
[ "${#REASON}" -le 200 ] || die 2 'the reason is at most 200 characters'

if [ "${CCQUOTA_FLEET:-0}" != 1 ]; then
  printf 'fleet-node-maintenance: the hub module is off (CCQUOTA_FLEET≠1) — no hub to flag this machine on, nothing touched\n' >&2
  exit 10
fi
if why=$(_fleet_hub_creds_missing); then
  die 1 "$why"
fi

CURL=${FLEET_HUB_CURL:-curl}
# One subshell: the token enters its environment and dies with it (#1491).
# The body is JSON built by python3 so a reason with quotes survives.
body=''
case "$ACTION" in
  enter) body=$(python3 -c 'import json,sys; print(json.dumps({"action":"enter","reason":sys.argv[1]}, ensure_ascii=False))' "$REASON") ;;
  leave) body='{"action":"leave"}' ;;
esac
resp=$(_fleet_hub_env
  url="${CCQUOTA_HUB_URL%/}/v1/node/maintenance"
  if [ -n "$body" ]; then
    "$CURL" -sS --max-time "${FLEET_HUB_TIMEOUT:-15}" -o - -w '\n%{http_code}' \
      -H "Authorization: Bearer $CCQUOTA_TOKEN" -H 'Content-Type: application/json' \
      -X POST --data-binary "$body" "$url" 2>/dev/null
  else
    "$CURL" -sS --max-time "${FLEET_HUB_TIMEOUT:-15}" -o - -w '\n%{http_code}' \
      -H "Authorization: Bearer $CCQUOTA_TOKEN" "$url" 2>/dev/null
  fi); rc=$?
[ "$rc" -eq 0 ] && [ -n "$resp" ] || die 1 "hub unreachable (${CCQUOTA_HUB_URL:-$(_fleet_node_env_val CCQUOTA_HUB_URL)}): curl exit $rc — nothing changed"
code=$(printf '%s\n' "$resp" | tail -n 1)
json=$(printf '%s\n' "$resp" | sed '$d')
case "$code" in
  200) ;;
  404|405) die 4 "the hub has no /v1/node/maintenance — it predates issue #1427; redeploy the hub, then retry" ;;
  401) case "$json" in
         *'viewer token'*) die 4 "the hub has no /v1/node/maintenance (the path fell through to its viewer gate) — it predates issue #1427; redeploy the hub, then retry" ;;
         *) die 4 "the hub does not know this node token (401): re-join with fleet-node-join.sh, or fleet-hub-node.sh env --write" ;;
       esac ;;
  409) die 4 "the hub has never heard this node report (409): is the ccquota agent running here?" ;;
  *) die 4 "hub answered HTTP $code: $(printf '%s' "$json" | head -c 300)" ;;
esac

# Render the one line from the hub's answer.
printf '%s' "$json" | python3 -c '
import json, sys
act = sys.argv[1]
d = json.load(sys.stdin)
m = d.get("machine") or "?"
rec = d.get("maintenance") or None
st = d.get("status") or "?"
def tail(r):
    parts = []
    if r.get("reason"): parts.append(r["reason"])
    if r.get("since"): parts.append("since " + r["since"])
    if r.get("by"): parts.append("by " + r["by"])
    return (" · " + " · ".join(parts)) if parts else ""
if act == "enter":
    print("maintenance: ENTERED %s%s" % (m, tail(rec or {})))
elif act == "leave":
    print("maintenance: LEFT %s" % m)
else:
    print("maintenance: %s %s%s" % (m, st, tail(rec) if rec else ""))
' "$ACTION" || die 4 "the hub answered 200 but not with JSON this script knows: $(printf '%s' "$json" | head -c 300)"
