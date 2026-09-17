#!/bin/bash
# Automatic done-raw window cleanup. Keeps worktree/branch/transcript for restore.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
FLEET_SESSION="${1:?session required}"; shift
fleet_load_conf "$FLEET_SESSION"
[ "${FLEET_CLEANUP:-1}" != 0 ] || exit 0
export FLEET_SESSION
export FLEET_REAP_MIN_AGE="${FLEET_REAP_MIN_AGE:-1800}"
export FLEET_REAP_IDLE_DONE_MIN="${FLEET_REAP_IDLE_DONE_MIN:-30}"
exec python3 "$BIN/fleet-cleanup-idle.py" --session "$FLEET_SESSION" \
  --socket-name "$(fleet_socket "$FLEET_SESSION")" --main "${FLEET_MAIN:-}" \
  --repo "${FLEET_REPO:-}" --base "${FLEET_BASE_BRANCH:-master}" "$@"
