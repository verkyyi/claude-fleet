#!/bin/bash
# fleet-reconcile-tick.sh — the state-reconcile unit's one bounded tick (T544,
# EPIC T542 C6): every 60 s, over every live fleet socket of this login,
#   1. fleet-state-reconcile.py  — a `working` window the agent itself says is
#      idle is demoted (#806)                                         ≤ 15 s
#   2. fleet-wait-reeval.sh      — an idle window's done ↔ looping + @claude_wait
#      is re-asked (#1376, #1880)                                     ≤ 15 s
#   3. fleet-cfg-restart.sh      — a session on an old configuration, idle long
#      enough, is reopened onto the current one (#1783)               ≤ 10 s
# then, until the worker-sleep half is deleted (C8), the per-fleet sleep scan
# that this tick used to hang off (fleet-sleep-daemon.sh, which now forwards
# here). Unit `reconcile` (com.claude-fleet.reconcile / claude-fleet-reconcile.timer);
# heartbeat global/reconcile.heartbeat; logs/reconcile.log holds only the lines
# that changed something. The whole tick stays ≤ 55 s under the 60 s interval.
# All state and tmux calls stay on fleet sockets.
set -uo pipefail
BIN=$(cd "$(dirname "$0")" && pwd)
. "$BIN/fleet-lib.sh"
. "$BIN/fleet-daemon-lib.sh"
fleet_daemon_stamp_tick reconcile "$BIN/.."
deadline=$((SECONDS + 55))
sockets=$(fleet_sockets)
# State truth first (issue #806): a `working` window whose agent is natively idle
# (Claude's session registry, a bound Codex's RPC) past the grace is demoted here,
# so a Stop hook that never fired cannot pin the dash forever. It lives on its own
# tick, not in the spinner, so a wedged spinner no longer takes state truth down
# with it. Its heartbeat feeds fleet-doctor's `state` line.
# shellcheck disable=SC2086  # the socket list is newline-separated words by design
fleet_timebox 15 python3 "$BIN/fleet-state-reconcile.py" --cache-dir "$(fleet_cache_global)" -- $sockets || :
# …and the other half of that truth (issue #1376): an IDLE window's `done` ↔
# `looping` + @claude_wait, decided once at its Stop, is re-asked here — a child
# that finished, a background job that ended, a fleet tool call that returned
# (#1880), a window that stopped before #1370.
# shellcheck disable=SC2086
fleet_timebox 15 bash "$BIN/fleet-wait-reeval.sh" --quiet -- $sockets >/dev/null 2>&1 || :
# A session on an OLD configuration (issue #1783) that has been idle long enough
# is reopened onto the current one — same conversation, new window; the move
# itself runs detached (fleet-migrate.sh --cfg-stale), so this only picks.
# shellcheck disable=SC2086
fleet_timebox 10 bash "$BIN/fleet-cfg-restart.sh" --quiet -- $sockets >/dev/null 2>&1 || :

# --- the worker-sleep scan, still carried here until C8 deletes it -----------
# Its judgments go to logs/sleep.log as before (fleet-doctor's sleep-judgment
# row and install-sync's settle read it), never into reconcile.log.
[ -f "$BIN/fleet-sleep.sh" ] || exit 0
logd="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/logs"
[ -d "$logd" ] || mkdir -p "$logd" 2>/dev/null || :
slog="$logd/sleep.log"
cursor="$(fleet_cache_global)/sleep.cursor"
last=$(cat "$cursor" 2>/dev/null || :)
# Rotate after the previous fleet so a slow fleet cannot starve later sockets.
ordered=$(printf '%s\n' "$sockets" | awk -v last="$last" '
  {a[NR]=$0; if ($0==last) start=NR}
  END {for(i=start+1;i<=NR;i++)print a[i]; for(i=1;i<=start;i++)print a[i]}')
# Divide the remaining budget across the fleets still to visit (issue #850): the
# cursor rotation above gives fairness ACROSS ticks, this gives it within one. A
# truncated fleet scan resumes from fleet-sleep.sh's own per-window cursor next
# tick. No single-flight lock is needed: launchd/systemd never start a second
# copy of a unit whose previous tick is still running, and this tick is bounded
# to 55s under the 60s interval.
count=$(printf '%s\n' "$ordered" | awk 'NF' | wc -l | tr -d ' ')
for session in $ordered; do
  [ "$SECONDS" -lt "$deadline" ] || break
  budget=$(fleet_daemon_fair_budget "$((deadline - SECONDS))" "$count" 5)
  count=$((count - 1))
  printf '%s\n' "$session" > "$cursor"
  fleet_timebox "$budget" bash "$BIN/fleet-sleep.sh" scan "$session" "$@" >> "$slog" 2>&1 || :
done
exit 0
