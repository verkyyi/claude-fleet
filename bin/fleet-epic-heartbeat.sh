#!/bin/bash
# fleet-epic-heartbeat.sh — «an EPIC batch is running on this login», left as a
# LOCAL mark the install-sync daemon can see (issue #953, EPIC #1117 R1).
#
#   fleet-epic-heartbeat.sh <epic> [--tick <n>] [--repo <owner/name>]
#                           [--session <sess>] [--ttl <seconds>]   # stamp — every tick
#   fleet-epic-heartbeat.sh --clear                                  # the batch ended
#   fleet-epic-heartbeat.sh --status                                 # read it back
#
# WHY. /fleet-epic-run merges to the base branch unattended for hours, on the LIVE
# install (~/.claude/fleet) that every worker beside it runs from. The install-sync
# daemon (bin/fleet-install-sync.sh, C3 #1120) fast-forwards that same install to
# `stable` whenever no window on this login is working / looping / waking. Each is
# right alone; together they let the floor move under a running batch — between
# two ticks the loop's own pane is idle and its workers sit idle while CI runs, so
# the daemon's busy gate sees a quiet machine. EPIC #883 already lost a batch this
# way by hand: C5's worker ran /fleet-sync-install after its own merge and reloaded
# a daemon under the other workers. /fleet-claim now tells a worker not to; this
# mark is the same rule for the automatic path.
#
# The mark is a LEASE, not a lock: $FLEET_CONF_DIR/global/epic-running, rewritten
# atomically by the run loop as the FIRST command of every tick, fresh for --ttl
# seconds (default 2700 = 45 min: the loop's longest planned gap between ticks is
# 30 min, and a lease has to outlive one late tick). A loop that dies without its
# closing tick leaves a mark that simply expires; a loop that ends clears it
# (--clear) so the batch-end sync is not held for the rest of the lease. Needs no
# gh and no tmux — the daemon that reads it has neither.
#
# Readers call fleet_epic_running (bin/fleet-lib.sh): exit 0 fresh / 1 stale /
# 2 none, printing `epic=<N> session=<s> tick=<n> age=<s>s ttl=<s>s`. --status is
# exactly that read. The install-sync daemon defers on 0 and says so in its state
# file's reason (the doctor's install row shows it); fleet-install-apply.sh WARNs
# on 0 — a hand sync under a running batch — but does not stop.
#
# File, one `key: value` per line:
#   epoch: <n>  iso: <UTC>  ttl: <s>  epic: <N>  repo: <owner/name|->
#   session: <sess|->  tick: <n|->
# A bare `touch` of the file (no epoch:) counts from its mtime — a hand override
# for «hold the install still for the next 45 min».
#
# Exit: 0 stamped / cleared / fresh · 1 stale (--status) · 2 usage, or no mark
# (--status).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

EPIC='' TICK='' REPO="${FLEET_REPO:-}" SESS="${FLEET_SESSION:-}" TTL="${FLEET_EPIC_RUNNING_TTL:-2700}" MODE=stamp
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tick)      shift; TICK="${1:-}" ;;
    --tick=*)    TICK="${1#--tick=}" ;;
    --repo)      shift; REPO="${1:-}" ;;
    --repo=*)    REPO="${1#--repo=}" ;;
    --session)   shift; SESS="${1:-}" ;;
    --session=*) SESS="${1#--session=}" ;;
    --ttl)       shift; TTL="${1:-}" ;;
    --ttl=*)     TTL="${1#--ttl=}" ;;
    --clear)     MODE=clear ;;
    --status)    MODE=status ;;
    -h|--help)   sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          printf 'fleet-epic-heartbeat: unknown argument %s\n' "$1" >&2; exit 2 ;;
    *)           EPIC="${1#\#}" ;;
  esac
  shift
done

F=$(fleet_epic_running_file)
case "$MODE" in
  status)
    out=$(fleet_epic_running "$F"); rc=$?
    case "$rc" in
      0) printf 'fresh %s (%s)\n' "$out" "$F"; exit 0 ;;
      1) printf 'stale %s (%s)\n' "$out" "$F"; exit 1 ;;
      *) printf 'none — no EPIC batch is marked running on this login (%s)\n' "$F"; exit 2 ;;
    esac ;;
  clear)
    if [ -f "$F" ]; then rm -f "$F"; printf 'cleared %s\n' "$F"
    else printf 'nothing to clear (%s)\n' "$F"; fi
    exit 0 ;;
esac

case "$EPIC" in ''|*[!0-9]*)
  printf 'fleet-epic-heartbeat: an EPIC issue number is required (or --clear / --status)\n' >&2; exit 2 ;;
esac
case "$TTL" in ''|*[!0-9]*|0)
  printf 'fleet-epic-heartbeat: --ttl must be a positive seconds count, got [%s]\n' "$TTL" >&2; exit 2 ;;
esac
case "$TICK" in *[!0-9]*) TICK='' ;; esac
[ -n "$SESS" ] || SESS=$(fleet_current_session 2>/dev/null || :)

d=$(dirname "$F")
[ -d "$d" ] || mkdir -p "$d" 2>/dev/null || { printf 'fleet-epic-heartbeat: cannot create %s\n' "$d" >&2; exit 1; }
tmp="$F.tmp.$$"
if ! {
  printf 'epoch: %s\n' "$(date +%s)"
  printf 'iso: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'ttl: %s\n' "$TTL"
  printf 'epic: %s\n' "$EPIC"
  printf 'repo: %s\n' "${REPO:--}"
  printf 'session: %s\n' "${SESS:--}"
  printf 'tick: %s\n' "${TICK:--}"
} > "$tmp" 2>/dev/null || ! mv -f "$tmp" "$F" 2>/dev/null; then
  rm -f "$tmp" 2>/dev/null
  printf 'fleet-epic-heartbeat: cannot write %s\n' "$F" >&2; exit 1
fi
printf 'stamped epic=%s session=%s tick=%s ttl=%ss (%s)\n' "$EPIC" "${SESS:--}" "${TICK:--}" "$TTL" "$F"
