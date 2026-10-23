#!/bin/bash
# fleet-wait-reeval.sh — re-ask every IDLE window "are you still waiting?" (issue #1376).
#
# Re-check the current session's native loop/bg/tool/human reasons for windows
# stamped done or looping with @claude_wait. Old children-only waits clear here;
# working/needs and reasonless looping observations are never rewritten.
# Called by fleet-reconcile-tick.sh and the install-apply reeval step.
#
# Usage: fleet-wait-reeval.sh [--dry-run] [--quiet] [--] [<session>...]
#        fleet-wait-reeval.sh [--dry-run] --window <win> [<session>]
# No session = every live fleet (fleet_sockets); inside a pane the current one.
# Prints one reeval line per change plus changed/windows/fleets counts. Logs to
# logs/reconcile.log with via=reeval. FLEET_WAIT_REEVAL=0 disables the pass.
# Legacy --parent-of remains a no-op for callers started before retirement.
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
    --parent-of) PARENT_OF=1; [ "$#" -gt 1 ] && shift ;;
    --) shift; break ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    -*) printf 'fleet-wait-reeval: unknown option %s\n' "$1" >&2; exit 2 ;;
    *) break ;;
  esac
  shift
done

if [ "${FLEET_WAIT_REEVAL:-1}" = 0 ]; then
  printf 'changed=0 windows=0 fleets=0\n'; exit 0
fi

LOG="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/logs/reconcile.log"
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

# compat-1v: 下一批删 — old Stop hooks may invoke it, but no other Task is read.
if [ -n "$PARENT_OF" ]; then
  printf 'changed=0 windows=0 fleets=0\n'; exit 0
fi

if [ -n "$WIN" ]; then
  sess=${1:-}
  [ -n "$sess" ] || sess=$(fleet_current_session)
  [ -n "$sess" ] || { printf 'fleet-wait-reeval: no session\n' >&2; exit 2; }
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
  for wid in $cand; do one "$sess" "$wid" || :; done
done
printf 'changed=%s windows=%s fleets=%s\n' "$changed" "$windows" "$fleets"
exit 0
