#!/bin/bash
# Read verified Claude account rows: window-id<TAB>pane-id<TAB>account label<TAB>repair-needed.
# --socket LABEL scans that fleet; --pane TARGET reads only the caller's socket.
# No stamps are trusted or changed here. Batch the process walk once per scan.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
acct_dir="${FLEET_ACCOUNTS_DIR:-$FLEET_CONF_DIR/accounts}"
[ -d "$acct_dir" ] || exit 0
case "${1:-}" in
  --socket)
    [ -n "${2:-}" ] || exit 2
    rows=$(tmux -L "$2" list-windows -a -F '#{window_id} #{pane_id} #{pane_pid} #{@cc_account}' 2>/dev/null) ;;
  --pane)
    [ -n "${TMUX:-}" ] && [ -n "${2:-}" ] || exit 2
    rows=$(tmux display-message -p -t "$2" '#{window_id} #{pane_id} #{pane_pid} #{@cc_account}' 2>/dev/null) ;;
  *) exit 2 ;;
esac
pids=()
while read -r _ _ pid _; do
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  pids+=("$pid")
done <<< "$rows"
[ "${#pids[@]}" -gt 0 ] || exit 0
processes=$(fleet_pane_claude_pids ${pids[@]+"${pids[@]}"})
[ -n "$processes" ] || exit 0
{ printf '%s\n' "$rows"; printf '%s\n' '---PROCESSES---' "$processes"; } \
  | python3 "$BIN/fleet-account-truth.py" "$acct_dir"
