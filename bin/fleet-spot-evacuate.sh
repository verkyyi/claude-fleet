#!/bin/bash
# fleet-spot-evacuate.sh — move every idle session off THIS machine through
# the hub, because the machine is about to go (issue #1428, EPIC #1419 R1).
#
#   fleet-spot-evacuate.sh [--session <sess>]… [--dry-run]
#
# Who runs it: the ccquota agent on a SPOT node, on the kubelet's SIGTERM —
# the cloud is taking the machine back and the pod has its grace period
# (terminationGracePeriodSeconds, 300s by default) to act. The agent has
# already told the hub (/v1/node/reclaim), so the hub's placement avoids this
# node from here on and every `move plan` below answers with another machine.
# It can also be run by hand on any fleet machine that is about to go down —
# the planned-outage half of #1427: FIRST `fleet-node-maintenance.sh enter`
# (so the hub stops placing on this machine and every `move plan` below
# answers with another one), THEN this, once per login; docs/MULTI-MACHINE-OPS.md
# is the runbook.
#
# What it does: for every live fleet of this login (fleet_sockets; or the
# --session ones), `fleet-move.sh --rebalance --max all` — the ordinary hub
# move, oldest-idle first. Only `done` sessions move; a session mid-turn is
# never cut (that is fleet-move.sh's rule, not a choice made here), so what
# is still here when the pod goes is what the hub records as lost (意外下线).
#
# Deadline: FLEET_SPOT_EVACUATE_SECS (the agent passes its own; default 240)
# bounds the whole run — no new fleet is started once FLEET_SPOT_EVACUATE_MARGIN
# (30s) remains, so the last move has room to finish. The agent kills the
# process group at its own deadline anyway; this is what keeps a move from
# being started that cannot complete.
#
# Exit status (issue #683's convention):
#   0   every idle session moved (or there was nothing to move)
#   1   something is still here: a move failed, the deadline cut the run, or
#       a session was working and could not move
#   2   usage error
#   10  the hub module is off (CCQUOTA_FLEET≠1): nothing touched — a SPOT
#       node is a hub node by construction, so this is a misconfiguration,
#       and single-machine fleets never reach here
#
# Output: one `evacuate:` line per fleet, fleet-move.sh's own lines indented,
# and a last `evacuate: moved N, left M` summary — the agent logs every line.
#
# Seams: FLEET_MOVE_CMD (default: this bin's fleet-move.sh) is how the
# selftest stubs the move; FLEET_SPOT_EVACUATE_SESSIONS (space-separated) is
# how it names the fleets without a tmux server.
set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fleet-lib.sh
. "$BIN/fleet-lib.sh"

die() { printf 'fleet-spot-evacuate: %s\n' "$1" >&2; exit "${2:-2}"; }
say() { printf 'evacuate: %s\n' "$*"; }

SESSIONS=() DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --session) [ -n "${2:-}" ] || die '--session needs a fleet name'; SESSIONS+=("$2"); shift 2 ;;
    --session=*) SESSIONS+=("${1#--session=}"); shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

if [ "${CCQUOTA_FLEET:-0}" != 1 ]; then
  say "the hub module is off (CCQUOTA_FLEET≠1) — nothing to move through, nothing touched" >&2
  exit 10
fi

DEADLINE="${FLEET_SPOT_EVACUATE_SECS:-240}"
MARGIN="${FLEET_SPOT_EVACUATE_MARGIN:-30}"
case "$DEADLINE" in ''|*[!0-9]*) die "FLEET_SPOT_EVACUATE_SECS must be seconds, not '$DEADLINE'" ;; esac
case "$MARGIN" in ''|*[!0-9]*) MARGIN=30 ;; esac
MOVE="${FLEET_MOVE_CMD:-$BIN/fleet-move.sh}"
T0=$SECONDS

if [ "${#SESSIONS[@]}" -eq 0 ]; then
  if [ -n "${FLEET_SPOT_EVACUATE_SESSIONS:-}" ]; then
    # shellcheck disable=SC2206
    SESSIONS=($FLEET_SPOT_EVACUATE_SESSIONS)
  else
    while IFS= read -r s; do [ -n "$s" ] && SESSIONS+=("$s"); done <<EOF
$(fleet_sockets)
EOF
  fi
fi
if [ "${#SESSIONS[@]}" -eq 0 ]; then
  say "no live fleet on this machine — nothing to move"
  say "moved 0, left 0"
  exit 0
fi

moved=0 left=0 cut=0
for sess in ${SESSIONS[@]+"${SESSIONS[@]}"}; do
  remaining=$(( DEADLINE - (SECONDS - T0) ))
  if [ "$remaining" -le "$MARGIN" ]; then
    say "$sess: deadline (${DEADLINE}s) too close to start another move — skipped"
    cut=1
    continue
  fi
  say "$sess: moving idle sessions off (${remaining}s left)"
  dry=()
  [ "$DRY" = 1 ] && dry=(--dry-run)
  out=$("$MOVE" --rebalance --max all --session "$sess" ${dry[@]+"${dry[@]}"} 2>&1); rc=$?
  printf '%s\n' "$out" | sed 's/^/  │ /'
  # fleet-move.sh's own summary: "fleet-move: rebalance moved N[, M failed]"
  n=$(printf '%s\n' "$out" | sed -n 's/^fleet-move: rebalance moved \([0-9]*\).*/\1/p' | tail -n 1)
  f=$(printf '%s\n' "$out" | sed -n 's/^fleet-move: rebalance moved [0-9]*, \([0-9]*\) failed.*/\1/p' | tail -n 1)
  moved=$(( moved + ${n:-0} ))
  left=$(( left + ${f:-0} ))
  [ "$rc" -eq 0 ] || [ -n "$n" ] || { say "$sess: fleet-move exited $rc"; left=$(( left + 1 )); }
done

# What is still here: every non-panel window that is not the hub — the
# working ones fleet-move refused, the failed ones, the ones the deadline
# left. Counted from tmux when there is one; the stubbed selftest has none.
here=0
for sess in ${SESSIONS[@]+"${SESSIONS[@]}"}; do
  sock=$(fleet_socket "$sess")
  c=$(tmux -L "$sock" list-windows -t "=$sess" -F '#{@hub}|#{window_name}' 2>/dev/null \
    | awk -F'|' '$1 != "1" && $2 !~ /^(plan|dash|backlog)$/ { n++ } END { print n+0 }')
  here=$(( here + ${c:-0} ))
done
[ "$here" -gt "$left" ] && left=$here

say "moved $moved, left $left$( [ "$cut" = 1 ] && printf ' (deadline cut the run)' )$( [ "$DRY" = 1 ] && printf ' (dry-run)' )"
[ "$left" -eq 0 ] && [ "$cut" = 0 ] && exit 0
exit 1
