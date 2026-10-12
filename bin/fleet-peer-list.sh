#!/bin/bash
# fleet-peer-list.sh — this login's person's OTHER logins, each with every way in
# (issue #3482): the hub's GET /v1/node/peers, asked with THIS login's node token
# (node.env, read inside the one subshell that calls the hub — never exported,
# issue #1491). fleet-peerlink.py reads it to keep one standing connection to each,
# and to dial each by a route the hub knows (tailnet name, LAN address, the entry
# port the hub reached) instead of a bare machine name only a tailnet resolves.
#
#   fleet-peer-list.sh            the hub's JSON on stdout:
#     {"hostname","login","peers":[{"hostname","alias","login","routes":[{"name","host","port"}],"last_seen"}]}
#
# Exit status (fleet-peer-cert.sh's convention):
#   0   answered — JSON on stdout
#   1   the hub was asked and could not be reached, or refused — stderr says which;
#       the caller keeps what it last had
#   3   not applicable: no node token here, or the hub predates #3482 (404/405)
#
# Seams: FLEET_HUB_CURL (default `curl`), FLEET_PEER_LIST_CONNECT_SECS (2),
# FLEET_HUB_TIMEOUT (10).
set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fleet-lib.sh
. "$BIN/fleet-lib.sh"

_fleet_hub_creds_missing >/dev/null && exit 3
CURL=${FLEET_HUB_CURL:-curl}
resp=$(_fleet_hub_env
  "$CURL" -sS --connect-timeout "${FLEET_PEER_LIST_CONNECT_SECS:-2}" --max-time "${FLEET_HUB_TIMEOUT:-10}" -o - -w '\n%{http_code}' \
    -H "Authorization: Bearer $CCQUOTA_TOKEN" "${CCQUOTA_HUB_URL%/}/v1/node/peers" 2>/dev/null); rc=$?
if [ "$rc" -ne 0 ] || [ -z "$resp" ]; then
  printf 'fleet-peer-list: the hub could not be reached (curl exit %s)\n' "$rc" >&2
  exit 1
fi
code=$(printf '%s\n' "$resp" | tail -n 1)
json=$(printf '%s\n' "$resp" | sed '$d')
case "$code" in
  200) printf '%s\n' "$json"; exit 0 ;;
  404|405) printf 'fleet-peer-list: the hub has no /v1/node/peers (it predates #3482)\n' >&2; exit 3 ;;
  *) printf 'fleet-peer-list: the hub refused (HTTP %s): %s\n' "$code" "$(printf '%s' "$json" | head -c 300)" >&2; exit 1 ;;
esac
