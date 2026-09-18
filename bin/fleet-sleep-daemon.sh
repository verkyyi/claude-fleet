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
