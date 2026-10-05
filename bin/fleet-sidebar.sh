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
. "$BIN/fleet-trace-lib.sh"   # the ⌂ latency trace (issue #1611): marks only on a hub-zoom.sh press
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
fleet_home_mark side
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
# The window is resolved ONCE per step and every read after it names it: a bare
# `{top-left}` under -c resolves against a different "current" window on some
# tmux releases (3.4) than the pressing client's.
win=$(tdm '#{window_id}')
wdm() { tmux display-message -p -t "$win${1:+.$1}" "$2" 2>/dev/null; }
# can_host <name> <issue> <raw> <worktree> <norepo> <remote> — the window test
# fleet-sidebar.py's sync draws the list by (keep the two in step).
can_host() {
  case "$1" in plan|dash|backlog) return 1 ;; home) return 0 ;; esac
  [ -n "$2" ] || [ "$3" = 1 ] || [ -n "$4" ] || [ "$5" = 1 ] || [ -n "$6" ]
}
# PIPE-delimited, the name LAST (it may hold a '|'): tmux < 3.5 prints a control
# character in -F output as an octal escape, so a \037 delimiter splits nothing.
HFMT='#{@issue}|#{@raw}|#{@worktree}|#{@norepo}|#{@remote}|#{window_name}'
# ONE read for everything the decision below needs (issue #1611 — it was five
# round-trips to a tmux server every other process on the box is queueing on
# too): the window's list state, its zoom, width and dragged list width, then
# HFMT. Targeted at the window's top-left pane, so `@sidebar` is that pane's
# and the window formats its window's. snap again after the window changes.
snap() {
  IFS='|' read -r sw_ zf_ sb_ cols_ manual_ i_ r_ w_ no_ re_ n_ <<EOF
$(wdm '{top-left}' "#{@sidebar_worker}|#{window_zoomed_flag}|#{@sidebar}|#{window_width}|#{@sidebar_width_manual}|$HFMT")
EOF
}
snap
view_up() {   # the current window shows the list, unzoomed — the LIVE read
  [ "$(wdm '' '#{&&:#{@sidebar_worker},#{!=:#{window_zoomed_flag},1}}')" = 1 ] &&
    [ "$(wdm '{top-left}' '#{@sidebar}')" = 1 ]
}
view_up_snap() {   # the same test on the snapshot (tmux's &&: non-empty and not 0)
  [ -n "${sw_:-}" ] && [ "${sw_:-}" != 0 ] && [ "${zf_:-}" != 1 ] && [ "${sb_:-}" = 1 ]
}

# F9 again with the keyboard already on the list: hide it.
if [ "$mode" = f9 ] && [ "$nav" = 1 ] && view_up_snap; then
  exec bash "$BIN/fleet-sidebar.sh" hide "$sess"
fi

if ! can_host "${n_:-}" "${i_:-}" "${r_:-}" "${w_:-}" "${no_:-}" "${re_:-}"; then
  pick='' best=-1
  while IFS='|' read -r wid last act i_ r_ w_ no_ re_ n_; do
    [ -n "$wid" ] || continue
    can_host "$n_" "$i_" "$r_" "$w_" "$no_" "$re_" || continue
    if [ "$last" = 1 ]; then pick=$wid; break; fi
    if [ "$n_" = home ]; then score=9999999999; else score=${act:-0}; fi
    case "$score" in ''|*[!0-9]*) score=0 ;; esac
    [ "$score" -gt "$best" ] && { best=$score; pick=$wid; }
  done <<EOF
$(tmux list-windows -t "$sess" -F "#{window_id}|#{window_last_flag}|#{window_activity}|$HFMT" 2>/dev/null)
EOF
  if [ -n "$pick" ]; then
    tmux select-window -t "$pick" 2>/dev/null || :
    win=$pick
  else
    HUB_SESSION="$sess" bash "$BIN/hub-session.sh" >/dev/null 2>&1 || :
    win=$(tmux list-windows -t "$sess" -F '#{window_id} #{window_name}' 2>/dev/null | awk '$2=="home"{print $1; exit}')
  fi
  snap
fi

# A window that can show the list: unzoom, switch it on, draw it now — unless it
# is already on screen, where focusing it is the whole press.
# A window too NARROW for the list goes straight to the popup (issue #1611):
# the draw would only conclude "not wanted" after a python start and four tmux
# reads — ~60 ms of the ⌂'s budget on the one path where the popup is the
# answer. The rule is fleet-sidebar.py's own (sync: `cols >= width + 1 + 80`,
# the dragged @sidebar_width_manual winning, both clamped 24..60) — KEEP THE TWO
# IN STEP; task-pick-latency-selftest.sh pins that no view is drawn here. A
# stale view on a window that shrank is the hooks' sync's to reap, as before.
narrow=0
if ! view_up_snap; then
  [ "${zf_:-}" = 1 ] && tmux resize-pane -Z -t "$win" 2>/dev/null
  show_on
  lw_=${FLEET_SIDEBAR_WIDTH:-30}
  case "${manual_:-}" in ''|*[!0-9]*) ;; *) lw_=$manual_ ;; esac
  case "$lw_" in ''|*[!0-9]*) lw_=30 ;; esac
  [ "$lw_" -lt 24 ] && lw_=24; [ "$lw_" -gt 60 ] && lw_=60
  case "${cols_:-}" in ''|*[!0-9]*) cols_=0 ;; esac
  if [ "$cols_" -lt $(( lw_ + 1 + 80 )) ]; then narrow=1; else py sync; fi
  fleet_home_mark sync
fi
if [ "$narrow" = 1 ] || ! view_up; then
  if [ "$nav" = 0 ]; then
    bash "$BIN/fleet-task-pick.sh" --popup --session "$sess" --cause "$mode" ${client:+--client "$client"} >/dev/null 2>&1
    [ $? = 3 ] || exit 0
  fi
  fleet_home_trace_drop   # nothing records this press
  tmux display-message ${client:+-c "$client"} "$(fleet_ui_t toast_sidebar_narrow)" 2>/dev/null || :
  exit 0
fi
tmux switch-client ${client:+-c "$client"} -T fleet-sidebar 2>/dev/null || :
# The view pins the client's own pane to the list on its next poll (#1105). An
# empty input line gets Escape (the highlight back on the task in view); a typed
# name is left as it is.
[ -z "$(wdm '{top-left}' '#{@sidebar_input}')" ] && py key Escape
tmux display-message ${client:+-c "$client"} "$(fleet_ui_t toast_sidebar_focus)" 2>/dev/null || :
fleet_home_end focus
bash "$BIN/fleet-hub-visits.sh" record '' "$sess" "$mode-sidebar" \
  "$(wdm '' '#{?#{@wid},#{@wid},#{window_id}}')" '' "$(fleet_home_extra)" >/dev/null 2>&1 || :
exit 0
