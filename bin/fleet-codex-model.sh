#!/bin/bash
# Native model switch / quota-limit inspection. Always route the explicit socket.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
sess=''; args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) [ "$#" -ge 2 ] || exit 2; sess=$2; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
[ -n "$sess" ] || sess=$(fleet_current_session 2>/dev/null)
[ -n "$sess" ] || { echo 'fleet-codex-model: --session is required' >&2; exit 2; }
fleet_load_conf "$sess"
export FLEET_CONF_DIR FLEET_CODEX_MODEL_FALLBACK FLEET_CODEX_MODEL_LIMIT_IDS
export FLEET_CODEX_QUOTA_FLOOR FLEET_CODEX_QUOTA_TTL
exec python3 "$BIN/fleet-codex-model.py" --session "$sess" ${args[@]+"${args[@]}"}
