#!/bin/bash
# fleet-await.sh — hand an issue to a worker and WAIT for its outcome (issue #812).
#
#   fleet-await.sh <N> [--timeout <secs>] [--interval <secs>] [--no-spawn]
#                      [--parent <key>] [--repo <owner/name>] [-L <socket>]
#
# The one thing a subagent gave that a worker did not: a result that comes BACK.
# #811 blocks writing subagents in every fleet pane; this is the primitive that
# replaces them. It
#   1. finds #N's live worker window — or, when there is none, spawns one through
#      the ONE spawn choke point (dash-issue-session.sh: session caps + the
#      cross-machine claim dedup apply unchanged), with THIS pane as its parent;
#   2. blocks until the worker reaches an outcome, reading the child-report LEDGER
#      (C3 #937, `fleet-children.sh --json`) plus the child's live window state —
#      no gh, no network, no PR/comment polling of its own;
#   3. prints a verdict block you can carry straight back into your context:
#
#        MERGED
#        issue: #812 · fleet-await.sh：派单并等它回话
#        pr: #970
#        summary: one or two lines from the worker's own report
#        waited: 23m · ledger scratch-29
#
# Run it with the Bash tool's `run_in_background: true`: the harness wakes you
# when it exits, zero turns spent in between.
#
# Outcomes (first stdout line → exit code):
#   MERGED              0  the worker landed its PR (or was reaped after merging)
#   BLOCKED / FAILED /  1  someone must act: a `⛔ blocked` report, a red gate the
#   STOPPED / NEEDS        worker is not fixing, a turn that ended with unshipped
#                          work, or a window sitting in `needs` across two polls
#   TIMEOUT             3  --timeout ran out; the worker is still going (re-run to
#                          keep waiting — nothing is spawned twice)
#   REAPED / GONE       4  the window went away without landing
#   NO-WORKER           5  no live worker and none could be spawned (--no-spawn,
#                          at capacity, claimed elsewhere) — stderr says which
#   (usage)             2
# A FAILED report whose summary says the worker is fixing it (the tier-quiet one,
# report_tier in fleet-children-lib.sh) and a WAITING/IDLE turn boundary are NOT
# outcomes: the wait goes on.
#
#   --timeout <s>   give up after this long (default 7200 = 2h; never unbounded)
#   --interval <s>  seconds between ledger reads (default 60; the read is a local
#                   file + one list-windows, but nothing here needs faster)
#   --no-spawn      only wait; exit 5 when #N has no live worker
#   --parent <key>  the ledger key to report to (default: this pane's own key —
#                   fleet_origin_key; the hub/dash has none, so run it from a
#                   scratch or worker pane, or name one)
#   --repo <r>      a fleet hosting 2+ repos: which one #N belongs to
#   -L <socket>     the fleet's socket, for a caller with no $TMUX
#
# A live worker spawned by SOMEONE ELSE keeps its parent: the wait reads that
# parent's ledger instead of stealing its reports. A live worker with no parent at
# all (hub-spawned) is adopted — its @origin is set to yours, so its report lands
# in your ledger.
#
# No orphans, no bare trap (the fleet-loadgen.sh rule, issue #697): nothing runs in
# the background — every wait is a FOREGROUND `sleep` capped at the time left, so a
# SIGINT to the process group takes the sleep with it, and the loop is bounded by
# `$SECONDS`. Under that, the whole process re-execs itself behind a kernel
# alarm(2) (`perl -e 'alarm N; exec …'`), preserved across exec, set a little past
# --timeout: even a wedged read cannot outlive its deadline.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
usage() { sed -n '2,62p' "$0" | sed 's/^# \{0,1\}//'; }
die()   { printf 'fleet-await: %s\n' "$1" >&2; exit "${2:-2}"; }

NUM='' TIMEOUT=7200 INTERVAL=60 SPAWN=1 KEY='' REPO_ARG='' SOCK=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --timeout)    shift; TIMEOUT="${1:-}" ;;
    --timeout=*)  TIMEOUT="${1#--timeout=}" ;;
    --interval)   shift; INTERVAL="${1:-}" ;;
    --interval=*) INTERVAL="${1#--interval=}" ;;
    --no-spawn)   SPAWN=0 ;;
    --parent)     shift; KEY="${1:-}" ;;
    --parent=*)   KEY="${1#--parent=}" ;;
    --repo)       shift; REPO_ARG="${1:-}" ;;
    --repo=*)     REPO_ARG="${1#--repo=}" ;;
    -L)           shift; SOCK="${1:-}" ;;
    -L*)          SOCK="${1#-L}" ;;
    -h|--help)    usage; exit 0 ;;
    -*)           die "unknown argument $1" ;;
    *)            [ -z "$NUM" ] || die "one issue number, got '$NUM' and '$1'"; NUM="${1#\#}" ;;
  esac
  shift
done
case "$NUM" in ''|*[!0-9]*) die "usage: fleet-await.sh <issue-number> [--timeout s] [--no-spawn]" ;; esac
case "$TIMEOUT" in ''|*[!0-9]*|0) die "--timeout wants a positive number of seconds" ;; esac
case "$INTERVAL" in ''|*[!0-9]*|0) die "--interval wants a positive number of seconds" ;; esac

# Deadline #1: the kernel alarm, armed once, before anything can block. Its margin
# covers one last read after the $SECONDS bound fires; if perl is missing the
# $SECONDS bound below is the whole deadline.
if [ -z "${FLEET_AWAIT_ARMED:-}" ] && command -v perl >/dev/null 2>&1; then
  FLEET_AWAIT_ARMED=1 exec perl -e 'alarm shift; exec @ARGV or exit 127' \
    "$((TIMEOUT + INTERVAL + 60))" bash "$0" "$NUM" --timeout "$TIMEOUT" --interval "$INTERVAL" \
    ${KEY:+--parent "$KEY"} ${REPO_ARG:+--repo "$REPO_ARG"} ${SOCK:+-L "$SOCK"} \
    $([ "$SPAWN" = 0 ] && printf -- '--no-spawn')
fi
SECONDS=0

# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

TM() { if [ -n "$SOCK" ]; then tmux -L "$SOCK" "$@"; else tmux "$@"; fi; }
sess="$SOCK"; [ -n "$sess" ] || sess=$(fleet_current_session)
[ -n "$sess" ] || die "not inside a fleet — run it from a fleet pane, or pass -L <socket>"
[ -n "$KEY" ] || KEY=$(fleet_origin_key)
[ -n "$KEY" ] || die "no parent key — run it from a scratch or worker pane (the hub has none), or pass --parent issue-N|scratch-N"
KEY=$(fleet_origin_canon "$KEY" '')

# The child's key, spelled the way its @origin-keyed ledger rows spell it.
CKEY="issue-$NUM"
if _fleet_hosts_many "$sess"; then
  [ -n "$REPO_ARG" ] || die "this fleet hosts several repos — pass --repo <owner/name>"
  CKEY="$(fleet_slug "$(fleet_norm_repo "$REPO_ARG")"):issue-$NUM"
fi

# `wid|@origin` of #N's live window on this fleet, or nothing.
child_win() {
  TM list-windows -t "$sess" -F '#{@issue}|#{window_id}|#{@origin}' 2>/dev/null \
    | awk -F'|' -v n="$NUM" '$1==n { print $2 "|" $3; exit }'
}

# One ledger read → `live|state|needs|seq|STATE|pr|verdict|tier|title|summary` for
# the child (summary last: free text, one line). No row at all = nothing known.
LEDGER=''
probe() {
  local args=("$LEDGER" --json)
  [ -n "$SOCK" ] && args+=(-L "$SOCK")
  bash "$BIN/fleet-children.sh" "${args[@]}" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for c in d.get("children") or []:
    if c.get("child") != sys.argv[1]:
        continue
    l = c.get("last") or {}
    f = [1 if c.get("live") else 0, c.get("state", ""), c.get("needs", ""), l.get("seq") or 0,
         l.get("state", ""), l.get("pr") or c.get("pr") or "", l.get("verdict", ""),
         l.get("tier", ""), (c.get("title") or l.get("title") or ""),
         " ".join(str(l.get("summary") or "").split())]
    print("|".join(str(x).replace("|", "/") for x in f))
    break
' "$CKEY"
}

# Split a probe row into globals.
P_LIVE=0 P_STATE='' P_NEEDS='' P_SEQ=0 P_EV='' P_PR='' P_VERDICT='' P_TIER='' P_TITLE='' P_SUM=''
split() {
  local r="$1"
  P_LIVE=0 P_STATE='' P_NEEDS='' P_SEQ=0 P_EV='' P_PR='' P_VERDICT='' P_TIER='' P_TITLE='' P_SUM=''
  [ -n "$r" ] || return 1
  P_LIVE=${r%%|*};  r=${r#*|}
  P_STATE=${r%%|*}; r=${r#*|}
  P_NEEDS=${r%%|*}; r=${r#*|}
  P_SEQ=${r%%|*};   r=${r#*|}
  P_EV=${r%%|*};    r=${r#*|}
  P_PR=${r%%|*};    r=${r#*|}
  P_VERDICT=${r%%|*}; r=${r#*|}
  P_TIER=${r%%|*};  r=${r#*|}
  P_TITLE=${r%%|*}; P_SUM=${r#*|}
  return 0
}

# The outcome an EVENT names, or nothing when it is a turn boundary / a red gate
# the worker says it is fixing.
event_outcome() {
  case "$P_EV" in
    MERGED)  printf 'MERGED' ;;
    REAPED)  case "$P_VERDICT" in merged*) printf 'MERGED' ;; *) printf 'REAPED' ;; esac ;;
    BLOCKED) printf 'BLOCKED' ;;
    STOPPED) printf 'STOPPED' ;;
    FAILED)  [ "$P_TIER" = quiet ] || printf 'FAILED' ;;
  esac
}

fmt_age() { local s=$1; if [ "$s" -lt 60 ]; then printf '%ds' "$s"; elif [ "$s" -lt 3600 ]; then printf '%dm' $((s / 60)); else printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60)); fi; }

finish() {  # <OUTCOME> [<note>]
  local rc
  case "$1" in
    MERGED) rc=0 ;; BLOCKED|FAILED|STOPPED|NEEDS) rc=1 ;; TIMEOUT) rc=3 ;;
    REAPED|GONE) rc=4 ;; NO-WORKER) rc=5 ;; *) rc=1 ;;
  esac
  printf '%s\n' "$1"
  printf 'issue: #%s%s\n' "$NUM" "${P_TITLE:+ · $P_TITLE}"
  [ -n "$P_PR" ] && printf 'pr: #%s\n' "${P_PR#\#}"
  [ -n "$P_SUM" ] && printf 'summary: %s\n' "$P_SUM"
  [ -n "${2:-}" ] && printf 'note: %s\n' "$2"
  printf 'waited: %s · ledger %s\n' "$(fmt_age "$SECONDS")" "${LEDGER:-$KEY}"
  exit "$rc"
}

# --- 1. find the worker (or spawn one) -------------------------------------------
row=$(child_win)
wid=${row%%|*}; worigin=${row#*|}; [ -n "$row" ] || { wid=''; worigin=''; }
if [ -n "$wid" ]; then
  if [ -z "$worigin" ]; then
    # Hub-spawned: nobody will ever read its report. Make it ours.
    TM set-window-option -t "$wid" @origin "$KEY" 2>/dev/null \
      && printf 'fleet-await: #%s had no parent — adopted (@origin %s)\n' "$NUM" "$KEY" >&2
    worigin=$KEY
  fi
  LEDGER=$(fleet_origin_canon "$worigin" '')
  [ "$LEDGER" = "$KEY" ] || printf 'fleet-await: #%s belongs to %s — reading its ledger\n' "$NUM" "$LEDGER" >&2
else
  LEDGER=$KEY
fi

split "$(probe)" || true
BASE=$P_SEQ
out=$(event_outcome)
# Already over? A MERGED report is final even while the window waits out its reap
# grace; any other outcome counts only once the window is gone (a live window may
# have been resumed past it).
if [ "$out" = MERGED ] || { [ -z "$wid" ] && [ -n "$out" ]; }; then
  finish "$out" 'already reported before this wait began'
fi

if [ -z "$wid" ]; then
  [ "$SPAWN" = 1 ] || finish NO-WORKER "#$NUM has no live worker (--no-spawn)"
  sargs=("$NUM" "$sess" --origin "$KEY")
  [ -n "$REPO_ARG" ] && sargs+=(--repo "$REPO_ARG")
  err=$(bash "$BIN/dash-issue-session.sh" "${sargs[@]}" 2>&1 >/dev/null); rc=$?
  case "$rc" in
    0) : ;;
    2) finish NO-WORKER "spawn refused — at capacity, retry later: ${err##*$'\n'}" ;;
    3) finish NO-WORKER "spawn refused — already claimed (another machine, or an open PR): ${err##*$'\n'}" ;;
    *) finish NO-WORKER "spawn failed (rc $rc): ${err##*$'\n'}" ;;
  esac
  row=$(child_win); wid=${row%%|*}
  [ -n "$row" ] && [ -n "$wid" ] || finish NO-WORKER "spawn returned but no issue-$NUM window appeared on $sess"
  printf 'fleet-await: spawned #%s (%s) — waiting up to %s\n' "$NUM" "$wid" "$(fmt_age "$TIMEOUT")" >&2
else
  printf 'fleet-await: #%s is live (%s) — waiting up to %s\n' "$NUM" "$wid" "$(fmt_age "$TIMEOUT")" >&2
fi

# --- 2. wait ----------------------------------------------------------------------
# Deadline #2: $SECONDS. Every sleep is foreground and capped at the time left.
needs_polls=0 gone_polls=0
while :; do
  left=$((TIMEOUT - SECONDS))
  [ "$left" -gt 0 ] || finish TIMEOUT "still running — re-run fleet-await.sh $NUM to keep waiting"
  sleep "$([ "$INTERVAL" -lt "$left" ] && echo "$INTERVAL" || echo "$left")"

  split "$(probe)" || true
  if [ "$P_SEQ" -gt "$BASE" ] 2>/dev/null; then
    out=$(event_outcome)
    [ -n "$out" ] && finish "$out"
  fi
  if [ "$P_LIVE" = 1 ]; then
    gone_polls=0
    # `needs` twice running: someone must answer it, and it is not answering itself.
    case "$P_STATE" in
      needs*|failed) needs_polls=$((needs_polls + 1))
              [ "$needs_polls" -ge 2 ] && finish NEEDS "the worker is waiting on a human${P_NEEDS:+ ($P_NEEDS)}" ;;
      *)      needs_polls=0 ;;
    esac
  else
    # Gone with no new report: give the reaper's backstop REAPED one more poll.
    gone_polls=$((gone_polls + 1))
    [ "$gone_polls" -ge 2 ] && finish GONE "the window closed without a report"
  fi
done
