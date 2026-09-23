#!/bin/bash
# fleet-epic-backstop.sh — may /fleet-epic-run's step-2a backstop merge this
# member's READY PR, or does the worker still own it? (issue #921, EPIC #935 R2)
#
#   fleet-epic-backstop.sh <child-key> [--pr <N>] [-L <socket>] [--children-json <file>]
#
# `READY` = CI green + mergeable. It says nothing about the member's own 完成判据,
# which the worker runs LOCALLY after CI — on EPIC #875 the backstop merged PR #917
# while its worker was still `looping` through a 10× loadgen acceptance run, so
# the fix was live before its acceptance had finished. A worker mid-acceptance
# owns its merge; the backstop is only for the one that finished and went idle.
#
# Asks, in order (the first that answers wins):
#   ship      the child's latest ledger report is MERGED — its own ship report
#             exists, nothing of its run is left to protect      → clear
#   gone      no live window (reaped, never spawned by this loop,
#             or not in the ledger at all)                        → clear
#   state     @worker_lifecycle / @claude_state is working, looping
#             or waking — a turn is running                       → BUSY
#   bg        fleet_child_busy (#864) says `bg`: its turn ended but a
#             Bash-tool job is still running (a run_in_background
#             acceptance loop, a `--wait` gate waiter)            → BUSY
#   idle      anything else (done, idle, needs, sleeping)         → clear
# fleet_child_busy's `pr-open` / `pr-unknown` are ignored here: the PR is open
# and READY by construction, so they say nothing about the WORKER.
#
# Output, one line on stdout:
#   exit 0   clear: <child> <why>
#   exit 1   backstop skipped: child busy (<child> <reason>)   ← the tick log line
#   exit 2   usage mistake
#
#   <child-key>        the member's key as `fleet-children.sh` prints it (issue-N,
#                      or <slug>:issue-N in a multi-repo fleet)
#   --pr <N>           fall back to matching the ledger row by PR when the key
#                      is not found
#   -L <socket>        the fleet's socket, for a caller with no $TMUX
#   --children-json    read this `fleet-children.sh --json` output instead of
#                      running it (tests; a tick that already holds the read)
# Test seam: FLEET_EPIC_BACKSTOP_BUSY_CMD, when set, is run as `<cmd> <sess> <win>`
# in place of fleet_child_busy (its stdout is the reason).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"

CHILD='' PR='' SOCK='' CJ=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr)            shift; PR="${1:-}" ;;
    --pr=*)          PR="${1#--pr=}" ;;
    -L)              shift; SOCK="${1:-}" ;;
    -L*)             SOCK="${1#-L}" ;;
    --children-json) shift; CJ="${1:-}" ;;
    -h|--help)       sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)              printf 'fleet-epic-backstop: unknown argument %s\n' "$1" >&2; exit 2 ;;
    *)               CHILD="$1" ;;
  esac
  shift
done
[ -n "$CHILD" ] || { printf 'fleet-epic-backstop: a child key is required (issue-N)\n' >&2; exit 2; }
PR=${PR//[^0-9]/}

if [ -n "$CJ" ]; then
  json=$(cat "$CJ" 2>/dev/null) || { printf 'fleet-epic-backstop: cannot read %s\n' "$CJ" >&2; exit 2; }
else
  json=$(bash "$BIN/fleet-children.sh" --json ${SOCK:+-L "$SOCK"} 2>/dev/null) || json=''
fi

# → `<verdict>|<window>|<state>|<last-report>` for the child, one line.
row=$(printf '%s' "$json" | python3 -c '
import json, sys
child, pr = sys.argv[1], sys.argv[2]
try:
    kids = json.load(sys.stdin).get("children") or []
except Exception:
    kids = []
k = next((k for k in kids if k.get("child") == child), None)
if k is None and pr:
    k = next((k for k in kids if str(k.get("pr") or "").lstrip("#") == pr), None)
if k is None:
    print("gone|||"); sys.exit()
last = (k.get("last") or {}).get("state", "")
if last == "MERGED":
    print("ship|%s|%s|%s" % (k.get("window", ""), k.get("state", ""), last))
elif not k.get("live"):
    print("gone||gone|%s" % last)
else:
    print("live|%s|%s|%s" % (k.get("window", ""), k.get("state", ""), last))
' "$CHILD" "$PR" 2>/dev/null) || row='gone|||'

verdict=${row%%|*}; rest=${row#*|}
win=${rest%%|*};    rest=${rest#*|}
state=${rest%%|*}

busy() { printf 'backstop skipped: child busy (%s %s)\n' "$CHILD" "$1"; exit 1; }

case "$verdict" in
  ship) printf 'clear: %s ship report MERGED\n' "$CHILD"; exit 0 ;;
  gone) printf 'clear: %s no live window\n' "$CHILD"; exit 0 ;;
esac

case "$state" in working|looping|waking) busy "$state" ;; esac

if [ -n "$win" ]; then
  sess="$SOCK"
  if [ -n "${FLEET_EPIC_BACKSTOP_BUSY_CMD:-}" ]; then
    reason=$($FLEET_EPIC_BACKSTOP_BUSY_CMD "$sess" "$win" 2>/dev/null) || reason=''
  else
    # shellcheck source=/dev/null
    [ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
    # shellcheck source=/dev/null
    . "$BIN/fleet-lib.sh"
    [ -n "$sess" ] || sess=$(fleet_current_session)
    reason=$(fleet_child_busy "$sess" "$win") || reason=''
  fi
  [ "$reason" = bg ] && busy "bg job"
fi

printf 'clear: %s %s\n' "$CHILD" "${state:-idle}"
exit 0
