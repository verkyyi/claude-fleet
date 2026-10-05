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
#   find      not in the ledger, or no live window there: look the KEY up
#             before calling it gone (issue #1110) — first this fleet's
#             windows (fleet_win_for_key: a live one is read for its state
#             like any ledger child), then, with the hub on, the hub's
#             session table (global/remote_<sess>, fleet-hub-sessions.sh) by
#             (repo, issue), every machine's rows. A ledger child whose
#             window is on ANOTHER machine (`remote` / `lost`) asks it too.
#               hub row working / looping / waking               → BUSY
#               hub row in any other state                        → clear
#               hub cache missing or older than
#               FLEET_HUB_RETAIN_SECS (600)                       → BUSY
#             a failed lookup is never "idle": the merge waits.
#   gone      no window here and none on the hub (or the hub is off:
#             a one-machine fleet answers as it always did)       → clear
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
#   exit 0   clear: <child> <why>          (… no live window (hub says gone))
#   exit 1   backstop skipped: child busy (<child> <reason>)   ← the tick log line
#                                          (… hub: working on m5)
#   exit 2   usage mistake
#
#   <child-key>        the member's key as `fleet-children.sh` prints it (issue-N,
#                      or <slug>:issue-N in a multi-repo fleet)
#   --pr <N>           fall back to matching the ledger row by PR when the key
#                      is not found
#   --parent <key>     whose ledger to read (fleet-children.sh <key>): the
#                      loop's own key when its pane has none (issue #1110)
#   -L <socket>        the fleet's socket, for a caller with no $TMUX
#   --children-json    read this `fleet-children.sh --json` output instead of
#                      running it (tests; a tick that already holds the read)
# Test seams: FLEET_EPIC_BACKSTOP_BUSY_CMD, when set, is run as `<cmd> <sess> <win>`
# in place of fleet_child_busy (its stdout is the reason);
# FLEET_EPIC_BACKSTOP_FIND_CMD as `<cmd> <key> <sock>` in place of the local
# window lookup (stdout `<wid>|<state>`, rc 1 none, rc 2 ambiguous).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"

CHILD='' PR='' SOCK='' CJ='' PARENT=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr)            shift; PR="${1:-}" ;;
    --pr=*)          PR="${1#--pr=}" ;;
    -L)              shift; SOCK="${1:-}" ;;
    -L*)             SOCK="${1#-L}" ;;
    --children-json) shift; CJ="${1:-}" ;;
    --parent)        shift; PARENT="${1:-}" ;;
    --parent=*)      PARENT="${1#--parent=}" ;;
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
  json=$(bash "$BIN/fleet-children.sh" ${PARENT:+"$PARENT"} --json ${SOCK:+-L "$SOCK"} 2>/dev/null) || json=''
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

LIB=0
lib() {
  [ "$LIB" = 1 ] && return 0
  # shellcheck source=/dev/null
  [ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
  # shellcheck source=/dev/null
  . "$BIN/fleet-lib.sh"
  LIB=1
}
fsess() { if [ -n "$SOCK" ]; then printf '%s' "$SOCK"; else fleet_current_session 2>/dev/null; fi; }

# find_local → `<wid>|<state>` of the live window in THIS fleet that answers to
# $CHILD (rc 1 none, rc 2 ambiguous). Asked only from inside a fleet (a $TMUX, or
# -L): outside one a bare tmux would read the default socket, which is no fleet.
find_local() {
  local wid st loop
  if [ -n "${FLEET_EPIC_BACKSTOP_FIND_CMD:-}" ]; then
    $FLEET_EPIC_BACKSTOP_FIND_CMD "$CHILD" "$SOCK" 2>/dev/null; return
  fi
  [ -n "$SOCK" ] || [ -n "${TMUX:-}" ] || return 1
  lib
  wid=$(fleet_win_for_key "$CHILD" "$SOCK" 2>/dev/null) || return
  st=$(if [ -n "$SOCK" ]; then tmux -L "$SOCK" display-message -p -t "$wid" \
         '#{?@worker_lifecycle,#{@worker_lifecycle},#{@claude_state}}|#{@loop}'
       else tmux display-message -p -t "$wid" '#{?@worker_lifecycle,#{@worker_lifecycle},#{@claude_state}}|#{@loop}'; fi 2>/dev/null) || st='|'
  loop=${st#*|}; st=${st%%|*}
  # a `done` window whose @loop still holds a round is looping (issue #1331)
  if [ "$st" = 'done' ] && [ -n "$loop" ] && python3 "$BIN/fleet_loop_mark.py" status --value "$loop" >/dev/null 2>&1; then
    st=looping
  fi
  printf '%s|%s' "$wid" "${st:-idle}"
}

# hub_state → what the hub's session table says of $CHILD's (repo, issue):
#   rc 0 `<state> on <node>`  a row answers       rc 1  the hub has no such row
#   rc 2 `<why>`              cannot tell         rc 10 the hub is off for this fleet
hub_state() {
  local sess num repo='' slug f ts now ttl age row rrc
  lib
  sess=$(fsess)
  fleet_hub_on "$sess" || return 10
  case "$CHILD" in *issue-*) num=${CHILD##*issue-} ;; *) num='' ;; esac
  case "$num" in ''|*[!0-9]*) printf 'not an issue key'; return 2 ;; esac
  case "$CHILD" in
    ?*:issue-*) slug=${CHILD%%:*}; repo=$(fleet_repo_for_slug "$sess" "$slug") || { printf 'unknown repo %s' "$slug"; return 2; } ;;
    *) [ "$(fleet_repos "$sess" | grep -c .)" = 1 ] && repo=$(fleet_repos "$sess") ;;   # 2+ repos, bare key: any repo's #N
  esac
  f="$FLEET_C/global/remote_$sess"
  [ -s "$f" ] || { printf 'no hub session cache'; return 2; }
  # shellcheck disable=SC2034  # read by fleet-status-lib.sh
  FLEET_STATUS_G="$FLEET_C/global"; . "$BIN/fleet-status-lib.sh"
  fleet_status_remote_head "$sess"; fleet_status_hub_ok "$FSR_TS"; ts=$FSH_TS
  now=$(date +%s); age=$((now - ts)); [ "$age" -lt 0 ] && age=0
  ttl="${FLEET_HUB_RETAIN_SECS:-600}"; case "$ttl" in ''|*[!0-9]*) ttl=600 ;; esac
  # A busy row wins over an idle one (two machines, or a stale twin of a move).
  row=$(LC_ALL=C awk -F $'\037' -v n="$num" -v r="$repo" '
    $1 ~ /^wid:/ && $4 == n && (r == "" || $5 == r) {
      s = ($6 == "" ? "idle" : $6); h = s " on " $2
      if (s == "working" || s == "looping" || s == "waking") { print h; f = 1; exit }
      if (!any) any = h
    }
    END { if (!f && any != "") print any; exit !(f || any != "") }' "$f"); rrc=$?
  [ "$age" -le "$ttl" ] || { printf 'hub silent %ss, last seen %s' "$age" "${row:-nothing}"; return 2; }
  printf '%s' "$row"
  return "$rrc"
}

# Not in the ledger, or its window is not HERE: find it before calling it gone.
case "$verdict|$state" in
  gone\|*|live\|remote|live\|lost)
    [ "$verdict" = live ] && win=''     # a remote row's `window` is its machine
    frc=1
    if [ "$verdict" = gone ]; then hit=$(find_local); frc=$?; fi
    if [ "$frc" = 0 ]; then
      verdict=live; win=${hit%%|*}; state=${hit#*|}
    elif [ "$frc" = 2 ]; then
      busy "ambiguous key in this fleet (two windows, or a bare issue-N in a multi-repo fleet)"
    else
      hs=$(hub_state); hrc=$?
      case "$hrc" in
        0)  case "$hs" in working\ *|looping\ *|waking\ *) busy "hub: $hs" ;; esac
            printf 'clear: %s hub: %s\n' "$CHILD" "$hs"; exit 0 ;;
        1)  printf 'clear: %s no live window (hub says gone)\n' "$CHILD"; exit 0 ;;
        2)  busy "cannot rule out a session elsewhere: $hs" ;;
        *)  verdict=gone ;;             # hub off: the one-machine answer, as before
      esac
    fi ;;
esac

case "$verdict" in
  ship) printf 'clear: %s ship report MERGED\n' "$CHILD"; exit 0 ;;
  gone) printf 'clear: %s no live window\n' "$CHILD"; exit 0 ;;
esac

# `looping` includes a `done` child whose @loop mark still holds a round —
# fleet-children.sh reports it as looping (issue #1331).
case "$state" in working|looping|waking) busy "$state" ;; esac

if [ -n "$win" ]; then
  sess="$SOCK"
  if [ -n "${FLEET_EPIC_BACKSTOP_BUSY_CMD:-}" ]; then
    reason=$($FLEET_EPIC_BACKSTOP_BUSY_CMD "$sess" "$win" 2>/dev/null) || reason=''
  else
    lib
    [ -n "$sess" ] || sess=$(fleet_current_session)
    reason=$(fleet_child_busy "$sess" "$win") || reason=''
  fi
  [ "$reason" = bg ] && busy "bg job"
fi

printf 'clear: %s %s\n' "$CHILD" "${state:-idle}"
exit 0
