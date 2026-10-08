#!/bin/bash
# Automatic done-raw window cleanup. Keeps worktree/branch/transcript for restore.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
FLEET_SESSION="${1:?session required}"; shift
fleet_load_conf "$FLEET_SESSION"
# FLEET_CLEANUP is switched per repo (issue #978) — in the loop below.
# Automatic sleep retains idle tasks in their original windows. Do not race its
# observation/exit policy with the older raw-window disposal timer — but a session
# that chose WHEN it is closed (@reap_policy, issue #1902) chose it over sleep:
# with sleep on, only those are considered (--policy-only).
only=()
[ "${FLEET_SLEEP:-observe}" != on ] || only=(--policy-only)
set -- ${only[@]+"${only[@]}"} "$@"
export FLEET_SESSION
export FLEET_REAP_MIN_AGE="${FLEET_REAP_MIN_AGE:-300}"
export FLEET_REAP_IDLE_DONE_MIN="${FLEET_REAP_IDLE_DONE_MIN:-30}"
# One pass per hosted repo (issues #791, #1941), each with THAT repo's MAIN/base,
# sharing the caller's --limit. The pass only considers windows stamped with its
# repo; a window whose repo is unknown or none is never closed here.
limit=4; rest=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --limit) shift; limit="${1:-4}" ;;
    *) rest+=("$1") ;;
  esac
  shift
done
case "$limit" in ''|*[!0-9]*) limit=4 ;; esac
# Resolve every window's repo ONCE first — @repo is the only field the per-repo
# pass reads. fleet_window_repo stamps it from the window's @worktree; a worktree
# window it answers by the fleet's ONLY repo (a worktree with no origin) is
# stamped here too, so adding a second repo later cannot orphan it (#1941).
_sock=$(fleet_socket "$FLEET_SESSION")
while IFS='|' read -r w wr wt; do   # '|', not a space: an empty @repo must not collapse
  [ -n "$w" ] && [ -z "$wr" ] || continue
  r=$(fleet_window_repo "$FLEET_SESSION" "$w")
  [ -n "$r" ] && [ -n "$wt" ] && tmux -L "$_sock" set-option -w -t "$w" @repo "$r" 2>/dev/null
done <<EOF
$(tmux -L "$_sock" list-windows -t "$FLEET_SESSION" -F '#{window_id}|#{@repo}|#{@worktree}' 2>/dev/null)
EOF
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
