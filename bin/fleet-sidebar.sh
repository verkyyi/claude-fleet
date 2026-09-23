#!/bin/bash
# fleet-sidebar.sh sync|toggle|hide|key [session-target] [key]
# fleet-sidebar.sh menu <session> <@window-id> [--print]   # a row's action menu
# fleet-sidebar.sh reap <session> <@window-id>             # the menu's confirmed reap
# In-pane / tmux-hook entry point: bare tmux inherits this fleet's socket.
# Only fleet-up-created sessions (a durable conf) opt in, never ad-hoc sessions.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -n "${TMUX:-}" ] || exit 0
. "$BIN/fleet-lib.sh"
verb="${1:-sync}"; target="${2:-}"
if [ -n "$target" ]; then
  sess=$(tmux display-message -p -t "$target" '#{session_name}' 2>/dev/null) || exit 0
else
  sess=$(fleet_current_session) || exit 0
fi
[ -n "$sess" ] || exit 0
socket_path=$(tmux display-message -p -t "$sess" '#{socket_path}' 2>/dev/null) || exit 0
[ "${socket_path##*/}" = "$(fleet_socket "$sess")" ] || exit 0
conf=$(fleet_conf_file "$sess")
[ -f "$conf" ] || exit 0
fleet_load_conf "$sess"

case "$verb" in
  toggle|hide)
    enabled=1
    { [ "$verb" = hide ] || [ "${FLEET_SIDEBAR:-1}" = 1 ]; } && enabled=0
    . "$BIN/fleet-config-lib.sh"
    if ! fcfg_write "$conf" FLEET_SIDEBAR "$enabled" bool >/dev/null; then
      tmux display-message 'fleet: could not save sidebar preference' 2>/dev/null || :
      exit 0
    fi
    FLEET_SIDEBAR=$enabled
    if [ "$enabled" = 1 ]; then
      tmux display-message 'fleet: task sidebar on — shown when the worker has room' 2>/dev/null || :
    else
      tmux display-message 'fleet: task sidebar hidden' 2>/dev/null || :
    fi
    verb=sync ;;
  sync|key) ;;
  menu|reap) . "$BIN/fleet-sidebar-menu.sh"; exit 0 ;;
  *) exit 2 ;;
esac

export FLEET_SESSION="$sess"
python3 "$BIN/fleet-sidebar.py" "$verb" "$sess" "$conf.sidebar.lock" \
  "${FLEET_SIDEBAR:-1}" "${FLEET_SIDEBAR_WIDTH:-30}" "${3:-}" || :
