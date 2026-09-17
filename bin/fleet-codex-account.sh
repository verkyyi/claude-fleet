#!/bin/bash
# Native Codex account registry/quota commands. --session loads a fleet overlay.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
sess=''; args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) [ "$#" -ge 2 ] || exit 2; sess=$2; args+=("$1" "$2"); shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
[ -n "$sess" ] || sess=$(fleet_current_session 2>/dev/null)
[ -z "$sess" ] || fleet_load_conf "$sess"
export FLEET_CONF_DIR FLEET_CODEX_HOME FLEET_CODEX_ACCOUNTS FLEET_CODEX_MODEL
export FLEET_CODEX_QUOTA_TTL FLEET_CODEX_QUOTA_FLOOR FLEET_CODEX_QUOTA_GATE
export FLEET_CODEX_QUOTA_MIGRATE
export FLEET_FAILOVER FLEET_FAILOVER_AGENTS FLEET_CODEX_SERVER
export FLEET_CODEX_MODEL_FALLBACK FLEET_CODEX_MODEL_LIMIT_IDS
exec python3 "$BIN/fleet-codex-account.py" ${args[@]+"${args[@]}"}
