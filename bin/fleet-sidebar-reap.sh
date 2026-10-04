#!/bin/bash
# fleet-sidebar-reap.sh <session> <@window-id> [client]
# Confirmed row-menu reap action. Keep this direct so a menu item does not have
# to re-enter fleet-sidebar.sh's sync/toggle preflight before calling dash-reap.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-ui-lang.sh"

sess="${1:-}"; wid="${2:-}"; client="${3:-}"
case "$wid" in @[0-9]*) ;; *) exit 0 ;; esac
[ -n "$sess" ] || exit 0
[ "$(tmux display-message -p -t "$wid" '#{?#{session_group},#{session_group},#{session_name}}' 2>/dev/null)" = "$sess" ] || exit 0

toast() { tmux display-message ${client:+-c "$client"} "$1" 2>/dev/null || :; }

out=$(bash "$BIN/dash-reap.sh" "$wid" --yes 2>/dev/null </dev/null)
token=$(printf '%s\n' "$out" | grep -E '^(reaped|skip|refused):' | tail -1)
case "$token" in
  reaped:full) toast "$(fleet_ui_t reap_done)" ;;
  reaped:keep) toast "$(fleet_ui_t reap_kept)" ;;
  skip:live)   toast "$(fleet_ui_t reap_live)" ;;
  skip:*)      toast "$(fleet_ui_t reap_skip_fmt "${token#skip:}")" ;;
  refused:*)   toast "$(fleet_ui_t reap_refused_fmt "${token#refused:}")" ;;
  *)           toast "$(fleet_ui_t reap_none)" ;;
esac
