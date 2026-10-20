#!/bin/bash
# fleet-sleep.sh — worker hibernation was deleted (T548, EPIC T542 C8). This
# name answers for one version: an older tmux conf's navigation hook, an older
# sidebar's 唤醒 / 保持唤醒 and an older reconcile tick still call `wake` /
# `keep-awake` / `scan` here, and each exits 0 doing nothing; the life
# subcommands (deliver · busy · …) go to fleet_worker_life.py. # compat-1v: 下一批删
action=${1:-}
case "$action" in
  hook|busy|holds-exit|deliver|dispose|restore|hold|release) ;;
  *) exit 0 ;;
esac
BIN=$(cd "$(dirname "$0")" && pwd)
. "$BIN/fleet-lib.sh"
shift
session=${1:-$(fleet_current_session)}; [ $# -eq 0 ] || shift
session=$(fleet_session_canon "$session")
[ -n "$session" ] || { echo 'usage: fleet-sleep.sh action session [window]' >&2; exit 2; }
fleet_load_conf "$session"
export FLEET_CONF_DIR FLEET_MAIN FLEET_SLEEP_MCP_RESTARTABLE
exec python3 "$BIN/fleet_worker_life.py" "$action" --session "$session" "$@"
