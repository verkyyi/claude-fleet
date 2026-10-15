#!/bin/bash
# fleet-term-attach.sh --view web-<id> --target personal|worker:<fleet_id>
#
# A browser terminal's one command (claude-fleet#3838, EPIC #3836 C1): run by
# `ccquota term-pty` AS the login, on the terminal it opened, after the hub's
# grant verified. It attaches that terminal to a grouped view of this login's
# fleet session — `<fleet>@view-<view>`, the same windows, its own current
# window (the shape of fleet-remote-view.sh's 看台, issue #1489) — on the target:
#
#   worker:<fleet_id>  the window wearing that @fleet_id, or nothing (exit 4)
#   personal           where a 看台 with nowhere to go lands: the orchestrator's
#                      window, else the session's current one (C4 keeps one of
#                      its own)
#
# It starts nothing — no agent, no session, no orchestrator — and the view is
# the ONLY thing it makes: `destroy-unattached on` once the client is on, and
# its own kill on the way out (a hang-up included), so the view never outlives
# the terminal while every window of the fleet does. A view name that is taken
# is refused (exit 5): one relay, one view.
#
# Exit: the tmux client's code · 2 usage · 3 no fleet here · 4 no such session
# here · 5 view taken.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-lib.sh
. "$BIN/fleet-lib.sh"

say() { printf '%s\r\n' "$*"; }
view='' target=''
while [ $# -gt 0 ]; do
  case "$1" in
    --view) view="${2:-}"; shift 2 ;;
    --target) target="${2:-}"; shift 2 ;;
    *) say "fleet-term-attach: unknown argument $1"; exit 2 ;;
  esac
done
case "$view" in web-*) ;; *) say "fleet-term-attach: --view is web-<id>"; exit 2 ;; esac
case "${view#web-}" in ''|*[!A-Za-z0-9-]*) say "fleet-term-attach: bad --view"; exit 2 ;; esac
case "$target" in
  personal) ;;
  worker:*) case "${target#worker:}" in ''|*[!A-Za-z0-9-]*) say "fleet-term-attach: bad --target"; exit 2 ;; esac ;;
  *) say "fleet-term-attach: --target is personal or worker:<fleet id>"; exit 2 ;;
esac

s=$(fleet_sockets | head -n 1)
[ -n "$s" ] || { say "这台机器上没有在运行的 fleet（no fleet session is live here）"; exit 3; }
sock=$(fleet_socket "$s")
T() { tmux -L "$sock" "$@"; }

case "$target" in
  worker:*)
    w=$(T list-windows -t "=$s" -F '#{window_id}|#{@fleet_id}' 2>/dev/null \
      | awk -F '|' -v f="${target#worker:}" '$2 == f { print $1; exit }')
    [ -n "$w" ] || { say "这个会话不在这台机器上运行（that session is not running here）"; exit 4; } ;;
  *)
    w=$(fleet_role_holder orchestrator "$sock" 2>/dev/null) || w=''
    [ -n "$w" ] && T list-windows -t "=$s" -F '#{window_id}' 2>/dev/null | grep -qxF "$w" || w=''
    [ -n "$w" ] || w=$(T display-message -p -t "=$s:" '#{window_id}' 2>/dev/null) ;;
esac

g="$s@view-$view" gid=''
T has-session -t "=$g" 2>/dev/null && { say "fleet-term-attach: view $view is taken"; exit 5; }
gone() {
  # Only ever this terminal's own view: a grouped session's kill unlinks its
  # windows from it alone — the fleet session keeps every one.
  case "$g:$gid" in *@view-web-*:\$*) T kill-session -t "$gid" 2>/dev/null ;; esac
}
# Every later target is the view's session id: a name holding `@` is read as a
# window id by tmux's target parser past has-session's exact match.
gid=$(T new-session -d -P -F '#{session_id}' -t "=$s" -s "$g" 2>/dev/null) \
  || { say "fleet-term-attach: cannot open a view"; exit 1; }
trap 'gone; exit 129' HUP
trap 'gone; exit 143' TERM
trap gone EXIT
T set-option -t "$gid" @view_web 1 \; select-window -t "$gid:$w" 2>/dev/null
# destroy-unattached once the client is on: set before, the server would take
# the still-unattached view at once.
T attach-session -t "$gid" \; set-option -t "$gid" destroy-unattached on
rc=$?
exit "$rc"
