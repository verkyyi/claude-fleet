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
. "$BIN/fleet-ui-lang.sh"
verb="${1:-sync}"; target="${2:-}"
if [ -n "$target" ]; then
  sess=$(tmux display-message -p -t "$target" '#{?#{session_group},#{session_group},#{session_name}}' 2>/dev/null) || exit 0
else
  sess=$(fleet_current_session) || exit 0
fi
[ -n "$sess" ] || exit 0
socket_path=$(tmux display-message -p -t "$sess" '#{socket_path}' 2>/dev/null) || exit 0
[ "${socket_path##*/}" = "$(fleet_socket "$sess")" ] || exit 0
conf=$(fleet_conf_file "$sess")
# The SHELL's server (bin/fleet-shell.sh, issue #1484) has no fleet conf: FLEET_SHELL=1
# in its environment is its opt-in; the list, keys and menu run as in a fleet.
[ -f "$conf" ] || [ "${FLEET_SHELL:-0}" = 1 ] || exit 0
fleet_load_conf "$sess"
export FLEET_UI_LANG="${FLEET_UI_LANG:-}"
# the auto-width ceiling (issue #1328) rides the env into the spawned view
export FLEET_SIDEBAR_WIDTH_MAX="${FLEET_SIDEBAR_WIDTH_MAX:-44}"

case "$verb" in
  toggle|hide)
    [ "${FLEET_SHELL:-0}" = 1 ] && exit 0   # the shell's list is not optional, and it has no conf to write
    enabled=1
    { [ "$verb" = hide ] || [ "${FLEET_SIDEBAR:-1}" = 1 ]; } && enabled=0
    . "$BIN/fleet-config-lib.sh"
    if ! fcfg_write "$conf" FLEET_SIDEBAR "$enabled" bool >/dev/null; then
      tmux display-message "$(fleet_ui_t sidebar_save_failed)" 2>/dev/null || :
      exit 0
    fi
    FLEET_SIDEBAR=$enabled
    if [ "$enabled" = 1 ]; then
      tmux display-message "$(fleet_ui_t sidebar_on)" 2>/dev/null || :
    else
      tmux display-message "$(fleet_ui_t sidebar_hidden)" 2>/dev/null || :
    fi
    verb=sync ;;
  sync|key) ;;
  menu|reap) . "$BIN/fleet-sidebar-menu.sh"; exit 0 ;;
  *) exit 2 ;;
esac

export FLEET_SESSION="$sess"
# The lock sits beside the fleet's conf; the shell has none (#1484), so its lock
# lives in its own $FLEET_C (the cache under the $TMPDIR it set) — the python's
# open() of a path in a missing directory is a silent exit 0, never a view.
lock="$conf.sidebar.lock"
if [ ! -d "${conf%/*}" ]; then mkdir -p "$FLEET_C" 2>/dev/null; lock="$FLEET_C/sidebar-$sess.lock"; fi
python3 "$BIN/fleet-sidebar.py" "$verb" "$sess" "$lock" \
  "${FLEET_SIDEBAR:-1}" "${FLEET_SIDEBAR_WIDTH:-30}" "${3:-}" "$conf" || :
