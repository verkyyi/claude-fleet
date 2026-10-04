#!/bin/bash
# fleet-await.sh — hand an issue to a worker and WAIT for its outcome (issue #812).
#
#   fleet-await.sh <N | wid:<worker_id>> [--timeout <secs>] [--interval <secs>] [--no-spawn]
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
# STALL LADDER (issue #1268). A live child that makes no progress for
# FLEET_AWAIT_STALL_SECS (default 1200; 0 = off) is escalated one rung at a time,
# each rung FLEET_AWAIT_STALL_SECS after the last:
#   1, 2  a short wake to the child                   (fleet-peer-send.sh)
#   3     its task again: re-run fleet-claim-brief.sh  (C6's brief once it lands)
#   4     the parent is told the child is stuck        (fleet-peer-send.sh)
#   5     the operator: a `● #N · stalled` alert       (fleet-alerts.sh stall)
# Every rung is a `wake` row in the parent's ledger (fleet-children.py), so a
# restarted wait climbs on from the recorded rung instead of starting over.
#   progress (ladder → 0, a `reset` row): a new child report, or the child's
#            worktree moved (HEAD or `git status`)
#   not stalled (clock restarts, rung kept): an unknown/idle state, any state
#            change, sleeping/preparing/waking/looping, or `working` with the
#            pane's process tree above FLEET_AWAIT_CPU_PCT (10) % of a core
#   stalled: `done` / `waiting`, or `working` with an idle process tree
#
#   --timeout <s>   give up after this long (default 7200 = 2h; never unbounded)
#   --interval <s>  seconds between full reads (default 60; the read is a local
#                   file + one list-windows). A report does not wait for it: the
#                   ledger file is watched every second and a change reads at
#                   once (issue #1272) — still no gh, no network.
#   --no-spawn      only wait; exit 5 when #N has no live worker
#   --parent <key>  the ledger key to report to (default: this pane's own key —
#                   fleet_origin_key; the hub/dash has none, so run it from a
#                   scratch or worker pane, or name one)
#   --repo <r>      a fleet hosting 2+ repos: which one #N belongs to
#   -L <socket>     the fleet's socket, for a caller with no $TMUX
#
# `wid:<fleet UUID>/[<slug>:]issue-<N>` (or `wid:issue-<N>`, this fleet) names the
# worker by its durable identity (issue #1420): one of THIS fleet's runs exactly as
# `<N>`; one of YOUR children on another machine is waited on through your ledger,
# which the hub feeds (#1421); anything else is NO-WORKER (5) — never a local spawn.
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
usage() { sed -n '2,85p' "$0" | sed 's/^# \{0,1\}//'; }
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
case "$NUM" in wid:?*) ;; ''|*[!0-9]*) die "usage: fleet-await.sh <issue-number> [--timeout s] [--no-spawn]" ;; esac
case "$TIMEOUT" in ''|*[!0-9]*|0) die "--timeout wants a positive number of seconds" ;; esac
case "$INTERVAL" in ''|*[!0-9]*|0) die "--interval wants a positive number of seconds" ;; esac

# Deadline #1: the kernel alarm, armed once, before anything can block. Its margin
# covers one last read after the $SECONDS bound fires; if perl is missing the
# $SECONDS bound below is the whole deadline.
if [ -z "${FLEET_AWAIT_ARMED:-}" ] && command -v perl >/dev/null 2>&1; then
  rearg=("$NUM" --timeout "$TIMEOUT" --interval "$INTERVAL")
  [ -n "$KEY" ] && rearg+=(--parent "$KEY")
  [ -n "$REPO_ARG" ] && rearg+=(--repo "$REPO_ARG")
  [ -n "$SOCK" ] && rearg+=(-L "$SOCK")
  [ "$SPAWN" = 0 ] && rearg+=(--no-spawn)
  FLEET_AWAIT_ARMED=1 exec perl -e 'alarm shift; exec @ARGV or exit 127' \
    "$((TIMEOUT + INTERVAL + 60))" bash "$0" "${rearg[@]}"
fi
SECONDS=0

# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/fleet-children-lib.sh"

STALL="${FLEET_AWAIT_STALL_SECS:-1200}"; case "$STALL" in ''|*[!0-9]*) STALL=1200 ;; esac
CPU_PCT="${FLEET_AWAIT_CPU_PCT:-10}";   case "$CPU_PCT" in ''|*[!0-9]*) CPU_PCT=10 ;; esac

TM() { if [ -n "$SOCK" ]; then tmux -L "$SOCK" "$@"; else tmux "$@"; fi; }
sess="$SOCK"; [ -n "$sess" ] || sess=$(fleet_current_session)
[ -n "$sess" ] || die "not inside a fleet — run it from a fleet pane, or pass -L <socket>"
[ -n "$KEY" ] || KEY=$(fleet_origin_key)
[ -n "$KEY" ] || die "no parent key — run it from a scratch or worker pane (the hub has none), or pass --parent issue-N|scratch-N"
KEY=$(fleet_origin_canon "$KEY" '')

# A worker_id target (issue #1420) → this fleet's issue number, or a refusal.
case "$NUM" in wid:*)
  WID=$NUM
  home=$(fleet_wid_home "$WID" "$sess"); hrc=$?
  [ "$hrc" -eq 2 ] && die "bad worker id '$WID' (want wid:<fleet UUID>/issue-<N> or wid:issue-<N>)"
  if [ "$hrc" -eq 0 ]; then
    [ "$home" = "$sess" ] || die "'$WID' belongs to fleet $home on this machine — run it there (-L $home)"
    k=${WID#wid:}; k=${k#*/}
    case "${k##*:}" in
      issue-*) NUM=${k##*:}; NUM=${NUM#issue-} ;;
      *) die "'$WID' is a scratch session — fleet-await waits on an issue worker" ;;
    esac
    case "$k" in ?*:*)
      [ -n "$REPO_ARG" ] || REPO_ARG=$(fleet_repo_for_slug "$sess" "${k%%:*}") \
        || die "'$WID' names repo ${k%%:*}, which this fleet does not host" ;;
    esac
  else
    loc=$(fleet_worker_locate "$WID" "$sess"); note=''
    case "$loc" in
      remote\ *)
        # Another machine (issue #1421): its reports are pushed back here by the
        # hub, into THIS parent's ledger — so the wait reads that ledger, and asks
        # the hub map (never the network) whether the child is still alive. Only
        # for one of OUR children: another parent's child reports to that parent.
        RNODE=${loc#remote }; RNODE=${RNODE%:lost}
        sp=$(_fleet_wid_split "$WID"); k=${sp#*$'\t'}
        RWID=$(fleet_hub_wid "${sp%%$'\t'*}" "$k" 2>/dev/null) || RWID=''
        rorigin=''
        [ -n "$RWID" ] && rorigin=$(awk -F'\t' -v w="$RWID" '$1 == w { print $3; exit }' "$(fleet_hub_cache)" 2>/dev/null)
        me=$(fleet_uuid "$sess" 2>/dev/null)/$KEY
        case "${k##*:}" in issue-*) NUM=${k##*:issue-} ;; *) note="'$WID' is a scratch session — fleet-await waits on an issue worker" ;; esac
        if [ -z "$note" ] && [ -z "$RWID" ]; then note="'$WID' lives on $RNODE, but the hub map has no full worker_id for it"
        elif [ -z "$note" ] && [ "$rorigin" != "$me" ]; then
          note="'$WID' lives on $RNODE and reports to ${rorigin:-nobody (hub-spawned)}, not to $KEY — its outcome is not pushed here"
        fi
        [ -n "$note" ] || REMOTE=$k ;;
      *) note="no worker '$WID' on this machine, and the hub cannot place it" ;;
    esac
    if [ -z "${REMOTE:-}" ]; then
      printf 'fleet-await: %s\n' "$note" >&2
      printf 'NO-WORKER\nworker: %s\nnote: %s\n' "${WID#wid:}" "$note"
      exit 5
    fi
  fi ;;
esac

# The child's key, spelled the way its @origin-keyed ledger rows spell it.
CKEY="issue-$NUM"
if [ -n "${REMOTE:-}" ]; then
  CKEY=$REMOTE      # as the child's own machine spells it — what its reports carry
elif _fleet_hosts_many "$sess"; then
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
  # The child moved (or is gone): the operator's stall alert is over. A TIMEOUT
  # leaves it — the stall is still real, and a re-run picks the ladder back up.
  [ "$1" = TIMEOUT ] || [ "${L_LEVEL:-0}" -lt 5 ] || unstall
  exit "$rc"
}

# --- the stall ladder (issue #1268) ------------------------------------------------
L_LEVEL=0 L_ANCHOR=0 L_SIG='' L_STATE='' L_CPU='' L_CPU_T=0
STALL_ID="$sess-$CKEY"

ledger_wake() { children_wake "$LEDGER" "$CKEY" "$1" "$2" "$3" "$sess" || true; }
unstall() { bash "$BIN/fleet-alerts.sh" unstall "$STALL_ID" >/dev/null 2>&1 || true; }

# Total CPU (centiseconds) of the child pane's process tree. `ps -o time=` is
# `M:SS.ss` on BSD and `[D-]HH:MM:SS` on procps; awk folds both.
cpu_cs() {
  local pp pids
  pp=$(TM display-message -p -t "$wid" '#{pane_pid}' 2>/dev/null)
  pids=$(_fleet_proc_tree "$pp" | tr '\n' ','); pids=${pids%,}
  [ -n "$pids" ] || { printf '0'; return; }
  ps -o time= -p "$pids" 2>/dev/null | awk '{
    t = $1; d = 0
    if (index(t, "-")) { d = substr(t, 1, index(t, "-") - 1); t = substr(t, index(t, "-") + 1) }
    n = split(t, f, ":"); s = 0
    for (i = 1; i <= n; i++) s = s * 60 + f[i]
    sum += s + d * 86400
  } END { printf "%d", sum * 100 }'
}

# What counts as progress: a new report, or the child's worktree changing.
progress_sig() {
  local wt h=''
  wt=$(TM display-message -p -t "$wid" '#{@worktree}' 2>/dev/null)
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    h="$(git -C "$wt" rev-parse HEAD 2>/dev/null)/$(git -C "$wt" status --porcelain 2>/dev/null | cksum)"
  fi
  printf '%s|%s' "$P_SEQ" "$h"
}

# Climb to rung <level>; prints the rung's outcome for the ledger row.
ladder_fire() {
  local lv=$1 idle msg pw out rc r=()
  idle=$(fmt_age "$(( $(date +%s) - L_ANCHOR ))")
  [ -n "$SOCK" ] && r+=(-L "$SOCK")
  case "$lv" in
    1|2) msg="[fleet-await] #$NUM: no progress for $idle (state: $P_STATE) — wake $lv/5. Carry on with your task; if you are stuck, say why on the issue (⛔ blocked) instead of waiting."
         out=$(bash "$BIN/fleet-peer-send.sh" ${r[@]+"${r[@]}"} ${REPO_ARG:+--repo "$REPO_ARG"} "issue:$NUM" "$msg" 2>&1); rc=$? ;;
    3)   msg="[fleet-await] #$NUM: still no progress after 2 wakes — wake 3/5. Re-read your task: run $BIN/fleet-claim-brief.sh (the issue + every comment), then continue, or post ⛔ blocked with the reason."
         out=$(bash "$BIN/fleet-peer-send.sh" ${r[@]+"${r[@]}"} ${REPO_ARG:+--repo "$REPO_ARG"} "issue:$NUM" "$msg" 2>&1); rc=$? ;;
    4)   pw=$(fleet_win_for_key "$LEDGER" "$SOCK" 2>/dev/null | head -1)
         msg="[fleet-await] your child #$NUM${P_TITLE:+ ($P_TITLE)} has made no progress for $idle through 3 wakes (state: $P_STATE) — wake 4/5. Look at it: unblock it or make the call; the operator is alerted next."
         if [ -n "$pw" ]; then
           out=$(bash "$BIN/fleet-peer-send.sh" ${r[@]+"${r[@]}"} "$pw" "$msg" 2>&1); rc=$?
         else
           out="no live window for parent $LEDGER"; rc=1
         fi ;;
    *)   out=$(bash "$BIN/fleet-alerts.sh" stall "$STALL_ID" "#$NUM" "$sess:$wid" \
               "no progress for $idle through 4 wakes (parent $LEDGER)" 2>&1); rc=$?
         [ "$rc" = 0 ] && out="alert stall-$STALL_ID" ;;
  esac
  out=$(printf '%s' "$out" | tr '\n' ' ' | sed 's/ *$//' | cut -c1-110)
  if [ "$rc" = 0 ]; then printf 'sent%s' "${out:+: $out}"; else printf 'failed%s' "${out:+: $out}"; fi
}

# One ladder step per poll, for a LIVE child.
ladder_tick() {
  [ "$STALL" -gt 0 ] || return 0
  local now sig cpu dt act out lrow
  now=$(date +%s)
  lrow=$(child_win); [ -n "$lrow" ] && wid=${lrow%%|*}
  sig=$(progress_sig)
  if [ "$sig" != "$L_SIG" ]; then
    if [ -n "$L_SIG" ] && [ "$L_LEVEL" -gt 0 ]; then
      ledger_wake 0 reset progress
      printf 'fleet-await: #%s made progress — stall ladder reset\n' "$NUM" >&2
      [ "$L_LEVEL" -ge 5 ] && unstall
      L_LEVEL=0
    fi
    [ -n "$L_SIG" ] && L_ANCHOR=$now
    L_SIG=$sig
  fi
  # Any state change is activity: the clock restarts, the rung stays.
  [ "$P_STATE" = "$L_STATE" ] || { L_STATE=$P_STATE; L_ANCHOR=$now; L_CPU=''; return 0; }
  case "$P_STATE" in
    done|waiting) : ;;
    working)
      cpu=$(cpu_cs); dt=$((now - L_CPU_T)); act=1
      [ -n "$L_CPU" ] && [ "$dt" -gt 0 ] && [ $((cpu - L_CPU)) -lt $((dt * CPU_PCT)) ] && act=0
      L_CPU=$cpu L_CPU_T=$now
      [ "$act" = 0 ] || { L_ANCHOR=$now; return 0; } ;;
    *) L_ANCHOR=$now; return 0 ;;   # unknown / idle / sleeping … — never a stall
  esac
  [ $((now - L_ANCHOR)) -ge "$STALL" ] && [ "$L_LEVEL" -lt 5 ] || return 0
  L_LEVEL=$((L_LEVEL + 1))
  case "$L_LEVEL" in 1|2) act=nudge ;; 3) act=brief ;; 4) act=parent ;; *) act=alert ;; esac
  out=$(ladder_fire "$L_LEVEL")
  ledger_wake "$L_LEVEL" "$act" "$out"
  printf 'fleet-await: #%s stalled %s — wake %s/5 (%s): %s\n' "$NUM" \
    "$(fmt_age $((now - L_ANCHOR)))" "$L_LEVEL" "$act" "$out" >&2
  L_ANCHOR=$now
}

# A child on another machine (issue #1421): alive ⇔ the hub map still holds it.
# rc 0 alive · 1 gone · 2 the map is stale (the hub is out of reach: say nothing).
remote_alive() {
  local f m
  f=$(fleet_hub_cache)
  m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || return 2
  [ $(( $(date +%s) - ${m:-0} )) -le "${FLEET_HUB_CACHE_SECS:-30}" ] || return 2
  awk -F'\t' -v w="$RWID" '$1 == w { f = 1; exit } END { exit !f }' "$f" 2>/dev/null
}

# --- 1. find the worker (or spawn one) -------------------------------------------
if [ -n "${REMOTE:-}" ]; then
  row='' LEDGER=$KEY wid=''
  split "$(probe)" || true
  BASE=$P_SEQ
  out=$(event_outcome)
  [ "$out" = MERGED ] && finish "$out" 'already reported before this wait began'
  printf 'fleet-await: #%s lives on %s — waiting on its reports via the hub, up to %s\n' \
    "$NUM" "$RNODE" "$(fmt_age "$TIMEOUT")" >&2
  LFILE=$(children_file "$LEDGER" "$sess" 2>/dev/null)
  TICK="${FLEET_AWAIT_TICK:-1}"; case "$TICK" in ''|*[!0-9]*|0) TICK=1 ;; esac
  lsize() { [ -n "$LFILE" ] && wc -c < "$LFILE" 2>/dev/null | tr -d ' '; }
  gone_polls=0
  while :; do
    left=$((TIMEOUT - SECONDS))
    [ "$left" -gt 0 ] || finish TIMEOUT "still running on $RNODE — re-run fleet-await.sh wid:$RWID to keep waiting"
    n=$([ "$INTERVAL" -lt "$left" ] && echo "$INTERVAL" || echo "$left"); s0=$(lsize)
    while [ "$n" -gt 0 ]; do
      t=$TICK; [ "$t" -gt "$n" ] && t=$n
      sleep "$t"; n=$((n - t))
      [ "$(lsize)" = "$s0" ] || break
    done
    split "$(probe)" || true
    if [ "$P_SEQ" -gt "$BASE" ] 2>/dev/null; then
      out=$(event_outcome)
      [ -n "$out" ] && finish "$out"
    fi
    remote_alive; ra=$?
    case "$ra" in
      0) gone_polls=0 ;;
      1) gone_polls=$((gone_polls + 1))
         [ "$gone_polls" -ge 2 ] && finish GONE "the session on $RNODE closed without a report" ;;
    esac
  done
fi
row=$(child_win)
wid=${row%%|*}; worigin=${row#*|}; [ -n "$row" ] || { wid=''; worigin=''; }
if [ -n "$wid" ]; then
  if [ -z "$worigin" ]; then
    # Hub-spawned: nobody will ever read its report. Make it ours.
    TM set-window-option -t "$wid" @origin "$KEY" 2>/dev/null \
      && printf 'fleet-await: #%s had no parent — adopted (@origin %s)\n' "$NUM" "$KEY" >&2
    fleet_stamp_origin_wid "$sess" "$wid" "$KEY" "$SOCK"
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
# pause <secs> — the gap between reads, cut short the moment the ledger changes
# (issue #1272): a child's report is an append to $LEDGER's file, so the wait
# answers within ~1s of it instead of up to --interval later. Watching it is a
# local `wc -c` per FLEET_AWAIT_TICK (1s); the full read (fleet-children.sh +
# list-windows + the ladder) still runs only once per --interval or per change.
LFILE=$(children_file "$LEDGER" "$sess" 2>/dev/null)
TICK="${FLEET_AWAIT_TICK:-1}"; case "$TICK" in ''|*[!0-9]*|0) TICK=1 ;; esac
lsize() { [ -n "$LFILE" ] && wc -c < "$LFILE" 2>/dev/null | tr -d ' '; }
pause() {
  local n=$1 s0 t
  s0=$(lsize)
  while [ "$n" -gt 0 ]; do
    t=$TICK; [ "$t" -gt "$n" ] && t=$n
    sleep "$t"; n=$((n - t))
    [ "$(lsize)" = "$s0" ] || return 0
  done
}
# The ladder resumes from the rung a previous wait recorded (issue #1268).
read -r L_LEVEL L_ANCHOR <<< "$(children_wake_state "$LEDGER" "$CKEY" "$sess")"
case "$L_LEVEL" in ''|*[!0-9]*) L_LEVEL=0 ;; esac
case "$L_ANCHOR" in ''|*[!0-9]*|0) L_ANCHOR=$(date +%s) ;; esac
[ "$L_LEVEL" -gt 0 ] && printf 'fleet-await: #%s stall ladder resumes at wake %s/5\n' "$NUM" "$L_LEVEL" >&2
# Deadline #2: $SECONDS. Every sleep is foreground and capped at the time left.
needs_polls=0 gone_polls=0
while :; do
  left=$((TIMEOUT - SECONDS))
  [ "$left" -gt 0 ] || finish TIMEOUT "still running — re-run fleet-await.sh $NUM to keep waiting"
  pause "$([ "$INTERVAL" -lt "$left" ] && echo "$INTERVAL" || echo "$left")"

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
    ladder_tick
  else
    # Gone with no new report: give the reaper's backstop REAPED one more poll.
    gone_polls=$((gone_polls + 1))
    [ "$gone_polls" -ge 2 ] && finish GONE "the window closed without a report"
  fi
done
