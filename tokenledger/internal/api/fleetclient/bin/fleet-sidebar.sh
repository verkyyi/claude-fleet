#!/bin/bash
# fleet-sidebar.sh sync|toggle|hide|show|key [session-target] [key]
# fleet-sidebar.sh home [session-target] <home|f9|g> [client] [nav 0|1]   # ⌂ / F9 / prefix g
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

# show_on — switch the list back on (FLEET_SIDEBAR=1 in the conf) when prefix e
# or F9 turned it off; a no-op when it is on, and in the shell, which has no off.
show_on() {
  [ "${FLEET_SHELL:-0}" = 1 ] && return 0
  [ "${FLEET_SIDEBAR:-1}" = 1 ] && return 0
  . "$BIN/fleet-config-lib.sh"
  if ! fcfg_write "$conf" FLEET_SIDEBAR 1 bool >/dev/null; then
    tmux display-message "$(fleet_ui_t sidebar_save_failed)" 2>/dev/null || :
    return 0
  fi
  FLEET_SIDEBAR=1
  tmux display-message "$(fleet_ui_t sidebar_on)" 2>/dev/null || :
}

case "$verb" in
  show) show_on; verb=sync ;;
  home) ;;
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
py() {
  python3 "$BIN/fleet-sidebar.py" "$1" "$sess" "$lock" \
    "${FLEET_SIDEBAR:-1}" "${FLEET_SIDEBAR_WIDTH:-30}" "${2:-}" "$conf" || :
}
[ "$verb" = home ] || { py "$verb" "${3:-}"; exit 0; }

# ---- home: where ⌂ / F9 / prefix g land (issue #1533) ---------------------------
# The full-screen list window retired; all three keys end on THIS list, with the
# keyboard on it — the navigation state prefix E enters:
#   the window shows the list    → focus it (a name half-typed on its input line
#                                  is kept: no Escape is sent to clear it)
#   it can, but doesn't          → zoomed: unzoom · switched off: switch it on ·
#                                  then draw it and focus it
#   it can't (a panel, a shell)  → the window the operator was in last when that
#                                  one can, else the fleet's `home` window, else
#                                  the most recently busy task; nothing anywhere
#                                  can → hub-session.sh builds `home`
# F9 is three-state: shown → focused → (F9 again: the fleet-sidebar table's bind
# passes nav=1) hidden, exactly prefix e's off. ⌂ and g never hide.
# A window too narrow for the list (an iPad in portrait) opens the same list as
# a popup instead (fleet-task-pick.sh, issue #902) — a press is never a dead key.
# FLEET_DASH_WINDOW=1 never gets here: hub-zoom.sh / dash-zoom.sh keep the hub.
mode="${3:-home}" client="${4:-}" nav="${5:-0}"
case "$mode" in home|f9|g) ;; *) mode=home ;; esac
tdm() { tmux display-message ${client:+-c "$client"} -p "$@" 2>/dev/null; }
US=$(printf '\037')
# can_host <name> <issue> <raw> <worktree> <norepo> <remote> — the window test
# fleet-sidebar.py's sync draws the list by (keep the two in step).
can_host() {
  case "$1" in plan|dash|backlog) return 1 ;; home) return 0 ;; esac
  [ -n "$2" ] || [ "$3" = 1 ] || [ -n "$4" ] || [ "$5" = 1 ] || [ -n "$6" ]
}
HFMT="#{window_name}$US#{@issue}$US#{@raw}$US#{@worktree}$US#{@norepo}$US#{@remote}"
view_up() {   # the current window shows the list, unzoomed
  [ "$(tdm '#{&&:#{@sidebar_worker},#{!=:#{window_zoomed_flag},1}}')" = 1 ] &&
    [ "$(tdm -t '{top-left}' '#{@sidebar}')" = 1 ]
}

# F9 again with the keyboard already on the list: hide it.
if [ "$mode" = f9 ] && [ "$nav" = 1 ] && view_up; then
  exec bash "$BIN/fleet-sidebar.sh" hide "$sess"
fi

IFS="$US" read -r n_ i_ r_ w_ no_ re_ <<EOF
$(tdm "$HFMT")
EOF
if ! can_host "${n_:-}" "${i_:-}" "${r_:-}" "${w_:-}" "${no_:-}" "${re_:-}"; then
  pick='' best=-1
  while IFS="$US" read -r wid last act n_ i_ r_ w_ no_ re_; do
    [ -n "$wid" ] || continue
    can_host "$n_" "$i_" "$r_" "$w_" "$no_" "$re_" || continue
    if [ "$last" = 1 ]; then pick=$wid; break; fi
    if [ "$n_" = home ]; then score=9999999999; else score=${act:-0}; fi
    case "$score" in ''|*[!0-9]*) score=0 ;; esac
    [ "$score" -gt "$best" ] && { best=$score; pick=$wid; }
  done <<EOF
$(tmux list-windows -t "$sess" -F "#{window_id}$US#{window_last_flag}$US#{window_activity}$US$HFMT" 2>/dev/null)
EOF
  if [ -n "$pick" ]; then
    tmux select-window -t "$pick" 2>/dev/null || :
  else
    HUB_SESSION="$sess" bash "$BIN/hub-session.sh" >/dev/null 2>&1 || :
  fi
fi

# A window that can show the list: unzoom, switch it on, draw it now.
[ "$(tdm '#{window_zoomed_flag}')" = 1 ] && tmux resize-pane -Z -t "$(tdm '#{pane_id}')" 2>/dev/null
show_on
py sync
if ! view_up; then
  if [ "$nav" = 0 ]; then
    bash "$BIN/fleet-task-pick.sh" --popup --session "$sess" --cause "$mode" ${client:+--client "$client"} >/dev/null 2>&1
    [ $? = 3 ] || exit 0
  fi
  tmux display-message ${client:+-c "$client"} "$(fleet_ui_t toast_sidebar_narrow)" 2>/dev/null || :
  exit 0
fi
tmux switch-client ${client:+-c "$client"} -T fleet-sidebar 2>/dev/null || :
# The view pins the client's own pane to the list on its next poll (#1105). An
# empty input line gets Escape (the highlight back on the task in view); a typed
# name is left as it is.
[ -z "$(tdm -t '{top-left}' '#{@sidebar_input}')" ] && py key Escape
tmux display-message ${client:+-c "$client"} "$(fleet_ui_t toast_sidebar_focus)" 2>/dev/null || :
bash "$BIN/fleet-hub-visits.sh" record '' "$sess" "$mode-sidebar" \
  "$(tdm '#{?#{@wid},#{@wid},#{window_id}}')" '' >/dev/null 2>&1 || :
exit 0
