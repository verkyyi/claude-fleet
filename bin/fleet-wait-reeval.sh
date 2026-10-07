#!/bin/bash
# fleet-wait-reeval.sh — re-ask every IDLE window "are you still waiting?" (issue #1376).
#
# The Stop hook decides `looping` + @claude_wait (loop|children|bg|tool) once, at the
# edge (issue #1370). An idle window never Stops again on its own, so without this a
# parent whose children are still running reads `done` ✓ if it stopped before #1370
# was synced, and a parent whose children all finished reads `looping` ↻ until its
# next turn. This re-runs that one decision (fleet_window_reeval) for windows whose
# state is `done`, or a `looping` that carries @claude_wait; it never changes
# working/needs, and it writes nothing at all for a window waiting on nothing.
#
# Three callers:
#   fleet-install-apply.sh `reeval` step   once per sync, every live fleet
#   fleet-sleep-daemon.sh                  every tick, after the #806 reconcile
#   set-claude-state.sh (a child's Stop)   --parent-of <win>: the parent of a window
#                                          that just stopped, so it need not wait
#                                          for the tick
#
# Usage: fleet-wait-reeval.sh [--dry-run] [--quiet] [--] [<session>...]
#        fleet-wait-reeval.sh [--dry-run] --window <win> [<session>]
#        fleet-wait-reeval.sh --parent-of <win> [<session>]
# No session = every live fleet (fleet_sockets); inside a pane the current one.
# Prints one `reeval: <sess>:<win> <old> -> <new>` line per change (unless --quiet)
# and, last, `changed=<n> windows=<m> fleets=<f>`. A change cascades — a child
# going `done` can finish its parent — so a pass that changed something is re-run,
# at most 3 times. Changes are logged to logs/reconcile.log with `via=reeval`.
# FLEET_WAIT_REEVAL=0 turns it off (exit 0, `changed=0 windows=0 fleets=0`).
# Always exits 0 except on a usage error (2).
set -uo pipefail
BIN=$(cd "$(dirname "$0")" && pwd)
. "$BIN/fleet-lib.sh"

DRY='' QUIET='' WIN='' PARENT_OF=''
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --quiet) QUIET=1 ;;
    --window) WIN=${2:-}; shift ;;
    --parent-of) PARENT_OF=${2:-}; shift ;;
    --) shift; break ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    -*) printf 'fleet-wait-reeval: unknown option %s\n' "$1" >&2; exit 2 ;;
    *) break ;;
  esac
  shift
done

if [ "${FLEET_WAIT_REEVAL:-1}" = 0 ]; then
  printf 'changed=0 windows=0 fleets=0\n'; exit 0
fi

LOG="$BIN/../logs/reconcile.log"
changed=0 windows=0 fleets=0

one() {   # <sess> <win> — reeval one window, print + log a change
  local out
  out=$(fleet_window_reeval "$1" "$2" "$DRY") || return 1
  changed=$((changed + 1))
  [ -n "$QUIET" ] || printf 'reeval: %s:%s %s\n' "$1" "$2" "$out"
  [ -n "$DRY" ] || { mkdir -p "${LOG%/*}" 2>/dev/null
    printf '%s  %-10s %s via=reeval\n' "$(date +%H:%M:%S)" "$1:$2" "$out" >> "$LOG" 2>/dev/null; }
  return 0
}

if [ -n "$WIN$PARENT_OF" ]; then
  sess=${1:-}
  [ -n "$sess" ] || sess=$(fleet_current_session)
  [ -n "$sess" ] || { printf 'fleet-wait-reeval: no session\n' >&2; exit 2; }
  if [ -n "$PARENT_OF" ]; then
    # The parent is the live window answering to this window's @origin key.
    origin=$(_fleet_tmux "$sess" display-message -p -t "$PARENT_OF" '#{@origin}' 2>/dev/null)
    WIN=''
    if [ -n "$origin" ]; then
      if [ -n "${TMUX:-}" ]; then WIN=$(fleet_win_for_key "$origin" 2>/dev/null)
      else WIN=$(fleet_win_for_key "$origin" "$(fleet_socket "$sess")" 2>/dev/null); fi
    fi
    [ -n "$WIN" ] || { printf 'changed=0 windows=0 fleets=1\n'; exit 0; }
  fi
  windows=1 fleets=1
  one "$sess" "$WIN" || :
  printf 'changed=%s windows=%s fleets=%s\n' "$changed" "$windows" "$fleets"
  exit 0
fi

if [ $# -gt 0 ]; then sessions="$*"
elif [ -n "${TMUX:-}" ]; then sessions=$(fleet_current_session)
else sessions=$(fleet_sockets 2>/dev/null); fi

for sess in $sessions; do
  # Only the windows the decision can move: `done`, or a reasoned `looping`.
  wl=$(_fleet_tmux "$sess" list-windows -t "$sess" \
         -F '#{window_id}|#{@claude_state}|#{@claude_wait}' 2>/dev/null) || continue
  fleets=$((fleets + 1))
  cand=''
  while IFS='|' read -r wid st cw; do
    [ -n "$wid" ] || continue
    case "$st" in 'done') ;; looping) [ -n "$cw" ] || continue ;; *) continue ;; esac
    cand="$cand $wid"; windows=$((windows + 1))
  done <<EOF
$wl
EOF
  pass=0
  while [ "$pass" -lt 3 ] && [ -n "$cand" ]; do
    pass=$((pass + 1)); before=$changed
    for wid in $cand; do one "$sess" "$wid" || :; done
    # a dry run changes nothing, so a second pass would only repeat itself
    [ "$changed" -gt "$before" ] && [ -z "$DRY" ] || break
  done
done
printf 'changed=%s windows=%s fleets=%s\n' "$changed" "$windows" "$fleets"
exit 0
