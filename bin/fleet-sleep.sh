#!/bin/bash
# Worker hibernation. Explicit session/socket; no default-server discovery.
set -uo pipefail
BIN=$(cd "$(dirname "$0")" && pwd)
. "$BIN/fleet-lib.sh"
action=${1:-status}; shift || :
session=${1:-$(fleet_current_session)}; [ $# -eq 0 ] || shift
[ -n "$session" ] || { echo 'usage: fleet-sleep.sh action session [window] [--dry-run]' >&2; exit 2; }
fleet_load_conf "$session"
export FLEET_CONF_DIR FLEET_MAIN
export FLEET_SLEEP="${FLEET_SLEEP:-observe}"
export FLEET_SLEEP_AFTER="${FLEET_SLEEP_AFTER:-1800}"
export FLEET_SLEEP_WAKE="${FLEET_SLEEP_WAKE:-confirm}"
export FLEET_SLEEP_WAKE_ARM="${FLEET_SLEEP_WAKE_ARM:-3}"
# The navigation/attach hooks pass --nav (issue #1050): under the default
# `confirm` arriving on a sleeper only shows its page — exit before python.
if [ "$action" = wake ] && [ "$FLEET_SLEEP_WAKE" != dwell ]; then
  case " $* " in *" --nav "*) exit 0 ;; esac
fi
export FLEET_SLEEP_MCP_RESTARTABLE="${FLEET_SLEEP_MCP_RESTARTABLE:-}"
# The sleeping page's language + DONE/NEXT digest knobs (issue #1237), when a conf sets them.
export FLEET_UI_LANG FLEET_SLEEP_DIGEST FLEET_SLEEP_DIGEST_MODEL FLEET_SLEEP_DIGEST_SECS
export FLEET_FAILOVER="${FLEET_FAILOVER:-0}"
export FLEET_FAILOVER_AGENTS="${FLEET_FAILOVER_AGENTS:-claude,codex}"
# The quota wake policy must see the same per-fleet inputs as reconciliation.
export FLEET_C FLEET_ACCOUNTS_DIR FLEET_QUOTA_BIN FLEET_ACCOUNT_CEILING FLEET_ACCOUNT_QUOTA_TTL
export CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_MODEL FLEET_MODEL_FALLBACK
export FLEET_CODEX_ACCOUNTS FLEET_CODEX_HOME FLEET_CODEX_MODEL FLEET_CODEX_SERVER
export FLEET_CODEX_MODEL_LIMIT_IDS FLEET_CODEX_MODEL_FALLBACK
exec python3 "$BIN/fleet-sleep.py" "$action" --session "$session" "$@"
