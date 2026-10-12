#!/bin/bash
# fleet-sidebar.sh sync|toggle|hide|show|key [session-target] [key]
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
socket_path=''
if [ -n "$target" ]; then
  sess=$(tmux display-message -p -t "$target" '#{?#{session_group},#{session_group},#{session_name}}' 2>/dev/null) || exit 0
else
  # The session and the server's socket in ONE read (issue #1611) — the same
  # pane-bound $FLEET_SESSION_FMT fleet_current_session reads, which stays the
  # fallback when the pane read says nothing.
  IFS='|' read -r socket_path sess <<EOF
$(tmux display-message -p -t "${TMUX_PANE:-}" "#{socket_path}|$FLEET_SESSION_FMT" 2>/dev/null)
EOF
  [ -n "${sess:-}" ] || { sess=$(fleet_current_session) || exit 0; socket_path=''; }
fi
[ -n "$sess" ] || exit 0
[ -n "$socket_path" ] || { socket_path=$(tmux display-message -p -t "$sess" '#{socket_path}' 2>/dev/null) || exit 0; }
[ "${socket_path##*/}" = "$(fleet_socket "$sess")" ] || exit 0
conf=$(fleet_conf_file "$sess")
# The SHELL's server (bin/fleet-shell.sh, issue #1484) has no fleet conf: FLEET_SHELL=1
# in its environment is its opt-in; the list, keys and menu run as in a fleet.
[ -f "$conf" ] || [ "${FLEET_SHELL:-0}" = 1 ] || exit 0
fleet_load_conf "$sess"
# The list is the CLIENT's (issue #1713, EPIC #1710 C3): it is drawn only on the
# shell's server (FLEET_SHELL=1). A node's fleet session draws none — every sync
# there runs as "off", which also takes away a list an older version drew, so a
# viewer arriving or leaving never changes a pane on the node. FLEET_SIDEBAR_NODE=1
# is the drawer's selftest seam (its tests drive it on a fleet socket), never a
# setting: nothing writes it, and the gate's runner strips every FLEET_* variable.
node_list=1
[ "${FLEET_SHELL:-0}" = 1 ] || [ "${FLEET_SIDEBAR_NODE:-0}" = 1 ] || node_list=0
[ "$node_list" = 1 ] || FLEET_SIDEBAR=0
export FLEET_UI_LANG="${FLEET_UI_LANG:-}"
# the auto-width ceiling (issue #1328) rides the env into the spawned view
export FLEET_SIDEBAR_WIDTH_MAX="${FLEET_SIDEBAR_WIDTH_MAX:-44}"

# show_on — switch the list back on (FLEET_SIDEBAR=1 in the conf) when prefix e
# or F9 turned it off; a no-op when it is on, and in the shell, which has no off.
show_on() {
  [ "${FLEET_SHELL:-0}" = 1 ] && return 0
  [ "$node_list" = 1 ] || return 0   # a node has no list to switch on (#1713)
  [ "${FLEET_SIDEBAR:-1}" = 1 ] && return 0
  . "$BIN/fleet-config-lib.sh"
  if ! fcfg_write "$conf" FLEET_SIDEBAR 1 bool >/dev/null; then
    fleet_ui_fail "$(fleet_ui_t sidebar_save_failed)" "$(fleet_ui_t sidebar_save_next)"
    return 0
  fi
  FLEET_SIDEBAR=1   # no toast: the list appearing is the answer (issue #1618)
}

case "$verb" in
  show) show_on; verb=sync ;;
  toggle|hide)
    [ "${FLEET_SHELL:-0}" = 1 ] && exit 0   # the shell's list is not optional, and it has no conf to write
    if [ "$node_list" = 1 ]; then   # a node has nothing to write: the sync reaps (#1713)
      enabled=1
      { [ "$verb" = hide ] || [ "${FLEET_SIDEBAR:-1}" = 1 ]; } && enabled=0
      . "$BIN/fleet-config-lib.sh"
      if ! fcfg_write "$conf" FLEET_SIDEBAR "$enabled" bool >/dev/null; then
        fleet_ui_fail "$(fleet_ui_t sidebar_save_failed)" "$(fleet_ui_t sidebar_save_next)"
        exit 0
      fi
      FLEET_SIDEBAR=$enabled   # no toast: the list coming or going is the answer (issue #1618)
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
