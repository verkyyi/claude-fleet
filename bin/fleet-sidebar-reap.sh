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
[ "$(tmux display-message -p -t "$wid" '#{session_name}' 2>/dev/null)" = "$sess" ] || exit 0

toast() { tmux display-message ${client:+-c "$client"} "$1" 2>/dev/null || :; }

out=$(bash "$BIN/dash-reap.sh" "$wid" --yes 2>/dev/null </dev/null)
token=$(printf '%s\n' "$out" | grep -E '^(reaped|skip|refused):' | tail -1)
if [ "$(fleet_ui_lang)" = zh ]; then
  case "$token" in
    reaped:full) toast "fleet: 已回收" ;;
    reaped:keep) toast "fleet: 已回收 — 脏 worktree 已保留在磁盘" ;;
    skip:live)   toast "fleet: 未回收 — agent 仍在运行（或太新）" ;;
    skip:*)      toast "fleet: 未回收（${token#skip:}）" ;;
    refused:*)   toast "fleet: 未回收 — ${token#refused:}" ;;
    *)           toast "fleet: 回收没有返回结果 — 请查看 hub" ;;
  esac
else
  case "$token" in
    reaped:full) toast "fleet: reaped" ;;
    reaped:keep) toast "fleet: reaped — dirty worktree kept on disk" ;;
    skip:live)   toast "fleet: not reaped — the agent is still live (or too young)" ;;
    skip:*)      toast "fleet: not reaped (${token#skip:})" ;;
    refused:*)   toast "fleet: not reaped — ${token#refused:}" ;;
    *)           toast "fleet: reap gave no result — check the hub" ;;
  esac
fi
