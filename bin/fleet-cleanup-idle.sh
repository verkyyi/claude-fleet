#!/bin/bash
# Automatic done-raw window cleanup. Keeps worktree/branch/transcript for restore.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
FLEET_SESSION="${1:?session required}"; shift
fleet_load_conf "$FLEET_SESSION"
# A multi-repo fleet switches this per repo (issue #978) — in the loop below.
fleet_has_repo_overlays "$FLEET_SESSION" || [ "${FLEET_CLEANUP:-1}" != 0 ] || exit 0
# Automatic sleep retains idle tasks in their original windows. Do not race its
# observation/exit policy with the older raw-window disposal timer.
[ "${FLEET_SLEEP:-observe}" != on ] || exit 0
export FLEET_SESSION
export FLEET_REAP_MIN_AGE="${FLEET_REAP_MIN_AGE:-1800}"
export FLEET_REAP_IDLE_DONE_MIN="${FLEET_REAP_IDLE_DONE_MIN:-30}"
if ! fleet_has_repo_overlays "$FLEET_SESSION"; then
  exec python3 "$BIN/fleet-cleanup-idle.py" --session "$FLEET_SESSION" \
    --socket-name "$(fleet_socket "$FLEET_SESSION")" --main "${FLEET_MAIN:-}" \
    --repo "${FLEET_REPO:-}" --base "${FLEET_BASE_BRANCH:-master}" "$@"
fi
# A multi-repo fleet (issue #791): one pass per hosted repo, each with THAT repo's
# MAIN/base, sharing the caller's --limit. The pass only considers windows stamped
# with its repo; a window whose repo is unknown or none is never closed here.
limit=4; rest=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --limit) shift; limit="${1:-4}" ;;
    *) rest+=("$1") ;;
  esac
  shift
done
case "$limit" in ''|*[!0-9]*) limit=4 ;; esac
# Resolve every window's repo ONCE first: fleet_window_repo stamps @repo from the
# window's @worktree, which is the only field the per-repo pass reads.
for w in $(tmux -L "$(fleet_socket "$FLEET_SESSION")" list-windows -t "$FLEET_SESSION" \
             -F '#{window_id}' 2>/dev/null); do
  fleet_window_repo "$FLEET_SESSION" "$w" >/dev/null
done
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  [ "$limit" -gt 0 ] || break
  out=$( fleet_load_repo_conf "$FLEET_SESSION" "$repo" || exit 0
    [ "${FLEET_CLEANUP:-1}" != 0 ] || exit 0
    python3 "$BIN/fleet-cleanup-idle.py" --session "$FLEET_SESSION" \
      --socket-name "$(fleet_socket "$FLEET_SESSION")" --main "${FLEET_MAIN:-}" \
      --repo "$repo" --base "${FLEET_BASE_BRANCH:-master}" --window-repo \
      --limit "$limit" ${rest[@]+"${rest[@]}"} )
  rc=$?
  [ -z "$out" ] || printf '%s\n' "$out"
  [ "$rc" = 75 ] && exit 75
  limit=$(( limit - $(printf '%s\n' "$out" | grep -c '^reaped-idle:') ))
done <<EOF
$(fleet_repos "$FLEET_SESSION")
EOF
exit 0
