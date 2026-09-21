#!/bin/bash
# Private, noninteractive adapter for fleet_control.py. All inputs are argv.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-lib.sh"
mode="${1:-}"
sess="${2:-}"
case "$mode" in
  inventory)
    while IFS=$'\t' read -r sess _conf; do
      [ -n "$sess" ] || continue
      (
        fleet_load_conf "$sess"
        printf '%s\0' "$sess" "${FLEET_REPO:-}" "${FLEET_MAIN:-}" "${FLEET_AGENT:-claude}" "$(fleet_conf_file "$sess")"
      )
    done < <(fleet_each_conf)
    ;;
  workers)
    sock=$(fleet_socket "$sess")
    if ! failure=$(tmux -L "$sock" has-session -t "=$sess" 2>&1); then
      case "$failure" in
        *'no server running'*|*'No such file or directory'*|*"can't find session"*) exit 3 ;;
        *) printf '%s\n' "$failure" >&2; exit 1 ;;
      esac
    fi
    # SSH forced commands often have no UTF-8 locale. Without -u, tmux
    # replaces tabs/non-ASCII in format output with underscores.
    # @worker_lifecycle (issue #808): empty = awake; preparing|sleeping|waking|failed
    # while hibernation owns the pane — a stop must not type into a parked pane.
    tmux -u -L "$sock" list-windows -t "=$sess" -F $'#{window_id}\t#{@issue}\t#{@raw}\t#{@worktree}\t#{@claude_state}\t#{@cc_agent}\t#{@wid}\t#{@worker_lifecycle}'
    ;;
  config)
    fleet_load_conf "$sess"
    printf '%s\0' "${FLEET_MAX_SESSIONS:-0}" "${FLEET_AUTOFILL:-0}" "${FLEET_AUTOFILL_MAX_PER_TICK:-1}"
    ;;
  start)
    fleet_load_conf "$sess"
    agent="${4:-${FLEET_AGENT:-claude}}"
    [ -n "$agent" ] || agent="${FLEET_AGENT:-claude}"
    bash "$BIN/fleet-diskguard.sh" --gate >&2 || exit 4
    if [ "$agent" = codex ]; then
      if [ "${FLEET_CODEX_QUOTA_GATE:-0}" = 1 ]; then
        bash "$BIN/fleet-codex-account.sh" gate --session "$sess" >&2 || exit 4
      fi
    else
      bash "$BIN/fleet-quotaguard.sh" --gate >&2 || exit 4
    fi
    exec bash "$BIN/dash-issue-session.sh" "${3:-}" "$sess" --agent "$agent" --origin hub
    ;;
  # --- worker lifecycle by DURABLE key (issue #834) ---------------------------
  # $3 is issue-<N> / scratch-<N>; the window is re-resolved on the fleet at
  # action time (fleet-worker-stop.sh / dash-restore-session.sh), never taken
  # from the caller — a window number is an observation, not an address.
  message)
    # Body on stdin. Relayed by the issue bridge (fleet-issue-bridge.sh), never
    # send-keys: the comment is the durable record AND the delivery. Exit 5 when
    # the fleet has not opted into the bridge — a post would look delivered and
    # reach nobody (issue #489).
    fleet_load_conf "$sess"
    [ "${FLEET_ISSUE_BRIDGE:-0}" = 1 ] || exit 5
    case "${3:-}" in ''|*[!0-9]*) exit 2 ;; esac
    exec bash "$BIN/fleet-comment.sh" "$3" --repo "${FLEET_REPO:-}" --to-worker --from hub --body-file -
    ;;
  stop)
    fleet_load_conf "$sess"
    exec bash "$BIN/fleet-worker-stop.sh" "$sess" "${3:-}"
    ;;
  resume)
    # The /fleet-history resume path: verdict first (REVIEW-ONLY ⇒ 5, nothing
    # attempted), the same disk/quota gates a start pays (4), then the headless
    # dash-restore-session.sh (2 = at capacity). A resumed session is a real
    # session: it holds a slot and spends tokens like a start.
    fleet_load_conf "$sess"
    case "${3:-}" in
      issue-*)   rkey="${3#issue-}";  target="landed:issue:$rkey" ;;
      scratch-*) rkey="$3";           target="landed:scratch:$3" ;;
      *) exit 2 ;;
    esac
    case "${rkey#scratch-}" in ''|*[!0-9]*) exit 2 ;; esac
    bash "$BIN/fleet-diskguard.sh" --gate >&2 || exit 4
    if [ "${FLEET_AGENT:-claude}" = codex ]; then
      if [ "${FLEET_CODEX_QUOTA_GATE:-0}" = 1 ]; then
        bash "$BIN/fleet-codex-account.sh" gate --session "$sess" >&2 || exit 4
      fi
    else
      bash "$BIN/fleet-quotaguard.sh" --gate >&2 || exit 4
    fi
    verdict=$(bash "$BIN/fleet-history.sh" resume --repo "${FLEET_REPO:-}" --main "${FLEET_MAIN:-}" "$rkey" 2>/dev/null)
    case "${verdict%%$'\t'*}" in
      RESUME|CODEX-RESUME|FROM-PR) ;;
      *) printf '%s\n' "${verdict:-no verdict}" >&2; exit 5 ;;
    esac
    exec bash "$BIN/dash-restore-session.sh" "$target" "$sess"
    ;;
  *) printf 'unsupported control adapter action\n' >&2; exit 2 ;;
esac
