#!/bin/bash
# fleet-window-reap.sh — a closed window takes the process trees it started with
# it (issue #1298). See fleet_orphan_trees in fleet-lib.sh for what is a target.
#
#   fleet-window-reap.sh --hook [<session>]  tmux window-unlinked / pane-exited entry
#                                   point: backgrounds itself, sweeps on a short
#                                   schedule (the closing agent may take seconds to
#                                   exit and orphan its children), logs what it
#                                   reaped. <session> is window-unlinked's
#                                   `#{hook_session_name}`: a shell's view session
#                                   (`<fleet>@view-<id>`, issue #1489) unlinks every
#                                   window when it goes — nothing closed, no sweep
#   fleet-window-reap.sh --once     one sweep now, print what was reaped
#   fleet-window-reap.sh --dry      print what a sweep would reap, kill nothing
#
# Knobs:
#   FLEET_WINDOW_REAP=0             turn the close-time sweep off (--hook no-ops)
#   FLEET_WINDOW_REAP_PASSES        seconds after the close to sweep at (default "2 6 20")
#   FLEET_WINDOW_REAP_EXEMPT_RE     extra argv ERE that is never reaped
#
# One sweeper at a time per login: a close that lands while one runs leaves a
# rerun mark, and the running sweeper starts its schedule over — so a burst of
# closes costs one schedule, and none is missed.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-lib.sh"

DIR="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/diskguard"
LOG="$DIR/window-reap.log"
LOCK="$DIR/window-reap.lock"
RERUN="$DIR/window-reap.rerun"

sweep() {   # $1 = kill|dry
  local out; out="$(fleet_reap_orphan_trees "$1" 2)"
  [ -n "$out" ] || return 0
  printf '%s\n' "$out"
  [ "$1" = kill ] || return 0
  mkdir -p "$DIR" 2>/dev/null
  printf '%s\n' "$out" | sed "s/^/$(date '+%Y-%m-%dT%H:%M:%S%z') /" >> "$LOG" 2>/dev/null
  return 0
}

hook() {
  [ "${FLEET_WINDOW_REAP:-1}" = 0 ] && return 0
  mkdir -p "$DIR" 2>/dev/null || return 0
  if ! mkdir "$LOCK" 2>/dev/null; then
    # A sweeper is running: ask it for another schedule — unless its lock is stale
    # (a SIGKILLed sweeper), which is taken over rather than waited on forever.
    local holder; holder="$(cat "$LOCK/pid" 2>/dev/null)"
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
      : > "$RERUN" 2>/dev/null; return 0
    fi
    rm -f "$LOCK/pid" 2>/dev/null; rmdir "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || return 0
  fi
  printf '%s\n' "$$" > "$LOCK/pid"
  trap 'rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null' EXIT
  local passes="${FLEET_WINDOW_REAP_PASSES:-2 6 20}" at prev t
  while :; do
    rm -f "$RERUN" 2>/dev/null
    prev=0
    for at in $passes; do
      case "$at" in ''|*[!0-9]*) continue ;; esac
      t=$((at - prev)); [ "$t" -gt 0 ] && sleep "$t"; prev="$at"
      sweep kill >/dev/null
    done
    [ -e "$RERUN" ] || break
  done
}

case "${1:-}" in
  --hook)
    # A view session's windows are still the fleet's: its going is no close.
    fleet_is_view_session "${2:-}" && exit 0
    # tmux's run-shell -b already detaches us; nohup + & keeps a direct caller's
    # shell from waiting on the schedule either.
    if [ "${FLEET_WINDOW_REAP_FG:-0}" = 1 ]; then hook
    else FLEET_WINDOW_REAP_FG=1 nohup "$0" --hook >/dev/null 2>&1 & fi ;;
  --once) sweep kill ;;
  --dry)  sweep dry ;;
  *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
exit 0
