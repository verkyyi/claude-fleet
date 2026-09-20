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
    tmux -u -L "$sock" list-windows -t "=$sess" -F $'#{window_id}\t#{@issue}\t#{@raw}\t#{@worktree}\t#{@claude_state}\t#{@cc_agent}\t#{@wid}'
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
  *) printf 'unsupported control adapter action\n' >&2; exit 2 ;;
esac
