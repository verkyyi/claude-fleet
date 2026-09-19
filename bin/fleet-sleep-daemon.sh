#!/bin/bash
# One bounded machine-wide scan; all state and tmux calls stay on fleet sockets.
set -uo pipefail
BIN=$(cd "$(dirname "$0")" && pwd)
. "$BIN/fleet-lib.sh"
. "$BIN/fleet-daemon-lib.sh"
fleet_daemon_stamp_tick sleep "$BIN/.."
deadline=$((SECONDS + 55))
cursor="$(fleet_cache_global)/sleep.cursor"
sockets=$(fleet_sockets)
# State truth first (issue #806): a `working` window whose agent is natively idle
# (Claude's session registry, a bound Codex's RPC) past the grace is demoted here,
# so a Stop hook that never fired cannot pin the dash — or gate hibernation on
# "worker is not done" — forever. It lives on this tick, not in the spinner, so a
# wedged spinner no longer takes state truth down with it. Bounded so the sleep
# scan keeps most of the tick; its heartbeat feeds fleet-doctor's `state` line.
# shellcheck disable=SC2086  # the socket list is newline-separated words by design
fleet_timebox 15 python3 "$BIN/fleet-state-reconcile.py" --cache-dir "$(fleet_cache_global)" -- $sockets || :
last=$(cat "$cursor" 2>/dev/null || :)
# Rotate after the previous fleet so a slow fleet cannot starve later sockets.
ordered=$(printf '%s\n' "$sockets" | awk -v last="$last" '
  {a[NR]=$0; if ($0==last) start=NR}
  END {for(i=start+1;i<=NR;i++)print a[i]; for(i=1;i<=start;i++)print a[i]}')
for session in $ordered; do
  [ "$SECONDS" -lt "$deadline" ] || break
  printf '%s\n' "$session" > "$cursor"
  fleet_timebox "$((deadline - SECONDS))" bash "$BIN/fleet-sleep.sh" scan "$session" "$@" || :
done
