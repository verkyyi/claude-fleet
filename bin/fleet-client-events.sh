#!/bin/bash
# fleet-client-events.sh — the clients' connection events, read off the hub
# (claude-fleet T689, 稳定性①): what every `fleet` client of this person — of
# everyone, for the operator — reported in the last hours: drops, reconnect
# p50 / p90, open failures and their reasons, per device and per home.
#
#   fleet-client-events.sh [--hours N] [--device D]      the table (fleet doctor --clients)
#   fleet-client-events.sh --summary [--hours N]         ONE line: LEVEL<TAB>words (the doctor's row)
#   fleet-client-events.sh --json [--events] [--hours N] the hub's answer as it came (+ the rows)
#
# Who: CCQUOTA_VIEWER_TOKEN in the environment = the operator (every person's
# clients); else this login's node token (node.env, read inside the one
# subshell that calls the hub, never exported — issue #1491) = its owner's own.
# The bearer goes to curl on stdin, never in an argv.
#
# Exit: 0 answered · 1 the hub could not be asked (no token / URL, unreachable,
# refused — stderr says which) · 2 usage · 10 the hub module is off.
# Seams: FLEET_HUB_CURL (default `curl`).
set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fleet-lib.sh
. "$BIN/fleet-lib.sh"

die() { printf 'fleet-client-events: %s\n' "$2" >&2; exit "$1"; }

HOURS=24 DEVICE='' MODE=table EVENTS=''
while [ $# -gt 0 ]; do
  case "$1" in
    --hours) [ $# -ge 2 ] || die 2 '--hours N'; HOURS=$2; shift 2 ;;
    --device) [ $# -ge 2 ] || die 2 '--device D'; DEVICE=$2; shift 2 ;;
    --summary) MODE=summary; shift ;;
    --json) MODE=json; shift ;;
    --events) EVENTS=1; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die 2 "unknown argument '$1'" ;;
  esac
done
case "$HOURS" in ''|*[!0-9]*) die 2 "--hours is a number of hours, not '$HOURS'" ;; esac
[ -z "$DEVICE" ] || [[ $DEVICE =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}$ ]] || die 2 "'$DEVICE' is not a device name"

CURL=${FLEET_HUB_CURL:-curl}
TIMEOUT=${FLEET_HUB_TIMEOUT:-10}
Q="?hours=$HOURS${DEVICE:+&device=$DEVICE}${EVENTS:+&events=1}"

if [ -n "${CCQUOTA_VIEWER_TOKEN:-}" ]; then
  URL=${CCQUOTA_HUB_URL:-${FLEET_HUB_URL:-$(_fleet_node_env_val CCQUOTA_HUB_URL 2>/dev/null)}}
  [ -n "$URL" ] || die 1 'no hub URL (CCQUOTA_HUB_URL / FLEET_HUB_URL / node.env)'
  resp=$(printf 'Authorization: Bearer %s\n' "$CCQUOTA_VIEWER_TOKEN" |
         "$CURL" -sS --max-time "$TIMEOUT" -o - -w '\n%{http_code}' -H @- "${URL%/}/v1/fleet/client-events$Q" 2>/dev/null); rc=$?
else
  if [ "${CCQUOTA_FLEET:-0}" != 1 ]; then
    printf 'fleet-client-events: the hub module is off (CCQUOTA_FLEET≠1) — no hub, nothing asked\n' >&2
    exit 10
  fi
  if why=$(_fleet_hub_creds_missing); then
    die 1 "$why"
  fi
  # One subshell: the node token enters its environment and dies with it (#1491).
  resp=$(_fleet_hub_env; u="${CCQUOTA_HUB_URL%/}/v1/fleet/client-events$Q"
         printf 'Authorization: %s\n' "$(fleet_node_auth GET "$u" "$CCQUOTA_TOKEN")" |
           "$CURL" -sS --max-time "$TIMEOUT" -o - -w '\n%{http_code}' -H @- "$u" 2>/dev/null); rc=$?
  URL=${CCQUOTA_HUB_URL:-$(_fleet_node_env_val CCQUOTA_HUB_URL 2>/dev/null)}
fi
[ "$rc" -eq 0 ] && [ -n "$resp" ] || die 1 "hub unreachable (${URL:-?}): curl exit $rc"
code=$(printf '%s\n' "$resp" | tail -n 1)
json=$(printf '%s\n' "$resp" | sed '$d')
case "$code" in
  200) ;;
  401|403) die 1 "the hub refused the read ($code): $(fleet_hub_auth_fix)" ;;
  404|405) die 1 "the hub has no client-events door ($code) — its image predates T689: redeploy it" ;;
  *) die 1 "hub answered HTTP $code: $(printf '%s' "$json" | head -c 300)" ;;
esac
case "$MODE" in
  json) printf '%s\n' "$json" ;;
  summary) printf '%s' "$json" | python3 "$BIN/fleet_client_events.py" report --summary ;;
  *) printf '%s' "$json" | python3 "$BIN/fleet_client_events.py" report ;;
esac
