#!/bin/bash
# fleet-epic-heartbeat.sh — «an EPIC batch is running on this login», left as a
# LOCAL mark the install-sync daemon can see (issue #953, EPIC #1117 R1) — one
# mark PER BATCH (issue #2062, EPIC #2074 C1).
#
#   fleet-epic-heartbeat.sh <epic> [--tick <n>] [--repo <owner/name>]
#                           [--session <sess>] [--ttl <seconds>]
#                           [--landed <k> --members <n>] [--title <parent title>]
#                           [--live <n> --inflight <n>]
#                           [--short <简称>]                        # stamp — every tick
#   fleet-epic-heartbeat.sh --clear <epic>                           # THIS batch ended
#   fleet-epic-heartbeat.sh --status                                 # every mark, one line each
#
# WHY. /fleet-epic-run merges to the base branch unattended for hours, on the LIVE
# install (~/.claude/fleet) that every worker beside it runs from. The install-sync
# daemon (bin/fleet-install-sync.sh, C3 #1120) switches that same install to
# `stable` whenever it moves. Each is right alone; together they let the floor
# move under a running batch — between two ticks the loop's own pane is idle and
# its workers sit idle while CI runs, so no busy gate can see the batch. EPIC #883
# already lost a batch this way by hand: C5's worker ran /fleet-sync-install after
# its own merge and reloaded a daemon under the other workers. /fleet-claim now
# tells a worker not to; this mark is the same rule for the automatic path.
#
# ONE MARK PER BATCH (issue #2062). On 2026-10-07 two loops (#1935, #1982) ran on
# one login and shared ONE file: whichever wrote last was the only batch anyone
# could see, and the first loop to end cleared both. So every batch writes its
# own file, $FLEET_CONF_DIR/global/epic-running.d/<repo slug>-<N>, rewritten
# atomically as the FIRST command of every tick; `--clear <N>` removes that one
# file and no other; a bare `--clear` is refused while several batches are marked.
# The pre-#2062 single file global/epic-running is still read for one version
# (never written); `--clear <N>` removes it too when it names <N>.
#
# The mark is a LEASE, not a lock: fresh for --ttl seconds (default 2700 = 45 min:
# the loop's longest planned gap between ticks is 30 min, and a lease has to
# outlive one late tick). A loop that dies without its closing tick leaves a mark
# that simply expires; a loop that ends clears its own (--clear <N>) so the
# batch-end sync is not held for the rest of the lease. Needs no gh and no tmux —
# the daemon that reads it has neither.
#
# Readers call fleet_epic_running_fresh (bin/fleet-lib.sh): exit 0 when ANY mark
# is fresh (every fresh one printed, `; `-joined) / 1 all stale / 2 none. The
# install-sync daemon defers the whole switch on 0 (`deferred`, never `switched`
# — issue #2062 put the gate back BEFORE the switch; #1894 had left only the
# node-agent half behind it), fleet-install-apply.sh WARNs on 0 (a hand sync
# under a running batch) but does not stop, fleet-doctor's `epic` row lists every
# batch. --status prints every mark: `fresh|stale epic=… (path)`, one per line.
#
# File, one `key: value` per line:
#   epoch: <n>  iso: <UTC>  ttl: <s>  epic: <N>  repo: <owner/name|->
#   session: <sess|->  tick: <n|->  [landed: <k>  members: <n>]
#   [live: <n>  inflight: <n>]
#
# ONLY A BATCH WITH WORK HOLDS THE INSTALL (issue #2247). An idle batch — no
# member session running, no member PR in flight, the loop only waiting on the
# operator's answer — still stamps every tick, and on 2026-10-07 EPIC #2140 held
# m4 at an old version for hours that way. So the stamp carries --live (member
# sessions alive this tick) and --inflight (member PRs open and not yet merged),
# and fleet_epic_holding (bin/fleet-lib.sh) reads a fresh mark with live 0 AND
# inflight 0 as `idle`: install-sync switches under it. A mark without the two
# fields (an older loop) is `active` — the conservative reading, byte for byte
# what it did before. install-sync also caps a hold (FLEET_EPIC_HOLD_CAP_SECS) —
# and since issue #2934 holds nothing at all unless that cap is set: a switch
# stops no running session, so the mark is a batch's presence, not a lock.
#
# ONE EPIC, ONE ROW (issue #1958). The mark is also what the task list reads to
# draw a running batch as ONE row: the stamp marks the window it runs in — the
# driver's own pane ($TMUX_PANE) — `@epic <owner/name>#<N>` (`#<N>` with no repo),
# and tmux-dashboard-rows.sh names that row after the parent issue and badges it
# `landed/members` off this file (--landed / --members, the loop's count of the
# core members that merged / it has). The members already hang under it by their
# @origin. `--clear <N>` unsets the window's @epic again when it names <N>. No
# pane (a daemon, a test) ⇒ no window is touched; no counts ⇒ no badge.
#
# THE DRIVER WEARS ITS BATCH'S NAME (issue #2544). A driver opened by
# `dash-raw-session.sh --prompt '/fleet-epic-run <N>'` was named `scratch-<N>`, and
# five batches at once were five `scratch-N` rows nobody could tell apart — on
# another machine, whose row has no title to fall back on, not even a theme.
# `--short <简称>` (the charter's `<!-- fleet:epic … short=… -->`, which the loop
# reads every tick) renames the stamping pane's window `<简称>·批次` — the word its
# members' names already start with — and the task list draws that name beside
# the landed/members badge. Only a name the fleet gave it is replaced
# (`scratch-<N>` · `issue-<N>` · `EPIC <N>` · an older `…·批次`); a name the
# person typed is theirs. Keys resolve by @worktree, never the name, so a member's
# @origin still finds its driver. The 简称 goes through fleet_epic_short: letters
# and digits only, at most 4.
# THE MARK CARRIES ITS BATCH'S TITLE (issue #2833, EPIC #2831 C2). `--title` (the
# parent issue's title, which the loop already read) is written as one `title:`
# line, a leading `EPIC: ` / `EPIC:` dropped, newlines folded, ≤ 120 characters —
# the orchestrator's batches pane names the row with it (mod/fleet/hooks/batches.tsx)
# and shows `#<N>` for a mark without one. No reader of the lease looks at it
# (fleet_epic_running reads epoch / ttl / epic / session / tick / live / inflight).
# A bare `touch` of a mark (no epoch:) counts from its mtime — a hand override
# for «hold the install still for the next 45 min».
#
# Exit: 0 stamped / cleared / any fresh (--status) · 1 all stale (--status) ·
# 2 usage, no mark (--status), or a bare --clear with several batches marked.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

EPIC='' TICK='' SHORT='' TITLE='' LANDED='' MEMBERS='' LIVE='' INFLIGHT='' REPO="${FLEET_REPO:-}" SESS="${FLEET_SESSION:-}" TTL="${FLEET_EPIC_RUNNING_TTL:-2700}" MODE=stamp
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tick)      shift; TICK="${1:-}" ;;
    --tick=*)    TICK="${1#--tick=}" ;;
    --repo)      shift; REPO="${1:-}" ;;
    --repo=*)    REPO="${1#--repo=}" ;;
    --session)   shift; SESS="${1:-}" ;;
    --session=*) SESS="${1#--session=}" ;;
    --landed)    shift; LANDED="${1:-}" ;;
    --landed=*)  LANDED="${1#--landed=}" ;;
    --members)   shift; MEMBERS="${1:-}" ;;
    --members=*) MEMBERS="${1#--members=}" ;;
    --live)      shift; LIVE="${1:-}" ;;
    --live=*)    LIVE="${1#--live=}" ;;
    --inflight)  shift; INFLIGHT="${1:-}" ;;
    --inflight=*) INFLIGHT="${1#--inflight=}" ;;
    --title)     shift; TITLE="${1:-}" ;;
    --title=*)   TITLE="${1#--title=}" ;;
    --short)     shift; SHORT="${1:-}" ;;
    --short=*)   SHORT="${1#--short=}" ;;
    --ttl)       shift; TTL="${1:-}" ;;
    --ttl=*)     TTL="${1#--ttl=}" ;;
    --clear)     MODE=clear ;;
    --clear=*)   MODE=clear; EPIC="${1#--clear=}"; EPIC="${EPIC#\#}" ;;
    --status)    MODE=status ;;
    -h|--help)   sed -n '2,88p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          printf 'fleet-epic-heartbeat: unknown argument %s\n' "$1" >&2; exit 2 ;;
    *)           EPIC="${1#\#}" ;;
  esac
  shift
done

# mark_epic <file> — the `epic:` line of one mark ('' when it has none).
mark_epic() { sed -n 's/^epic: //p' "$1" 2>/dev/null | head -1; }

# The driver's own window (issue #1958): only from inside a pane — bare tmux is
# that pane's own fleet server. Never fatal: the mark is the heartbeat's job.
win_epic() {
  [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || return 0
  if [ "$1" = set ]; then
    tmux set-option -wq -t "$TMUX_PANE" @epic "$2" 2>/dev/null || :
  else
    local cur; cur=$(tmux display-message -p -t "$TMUX_PANE" '#{@epic}' 2>/dev/null) || return 0
    case "$cur" in *"#$2") tmux set-option -wqu -t "$TMUX_PANE" @epic 2>/dev/null || : ;; esac
  fi
}

# The driver's window wears its batch (issue #2544): `<简称>·批次`, from a name the
# fleet gave it only. Same rail as win_epic: a pane, bare tmux, never fatal.
win_name() {
  [ -n "$1" ] && [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || return 0
  local cur want="$1·批次"
  cur=$(tmux display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null) || return 0
  [ "$cur" = "$want" ] && return 0
  case "$cur" in
    scratch-[0-9]*|issue-[0-9]*|'EPIC '[0-9]*|?*·批次) ;;
    *) return 0 ;;
  esac
  tmux rename-window -t "$TMUX_PANE" -- "$want" 2>/dev/null || :
}

case "$MODE" in
  status)
    any=0 fresh=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      out=$(fleet_epic_running "$f"); rc=$?
      case "$rc" in
        0) any=1; fresh=1; printf 'fresh %s (%s)\n' "$out" "$f" ;;
        1) any=1; printf 'stale %s (%s)\n' "$out" "$f" ;;
      esac
    done <<MARKS
$(fleet_epic_running_marks)
MARKS
    [ "$any" = 1 ] || { printf 'none — no EPIC batch is marked running on this login (%s/)\n' "$(fleet_epic_running_dir)"; exit 2; }
    [ "$fresh" = 1 ] && exit 0
    exit 1 ;;
  clear)
    marks=$(fleet_epic_running_marks)
    case "$EPIC" in
      '')
        # A bare --clear is the pre-#2062 form: one batch marked = that one; more
        # than one = refuse, never all of them (the other loop is still running).
        n=$(printf '%s\n' "$marks" | sed '/^$/d' | wc -l | tr -d ' ')
        if [ "$n" -gt 1 ]; then
          printf 'fleet-epic-heartbeat: %s batches are marked running on this login — --clear <epic> clears ONE, never all (issue #2062):\n' "$n" >&2
          printf '%s\n' "$marks" | sed '/^$/d' | while IFS= read -r f; do printf '  epic=%s (%s)\n' "$(mark_epic "$f")" "$f" >&2; done
          exit 2
        fi ;;
      *[!0-9]*) printf 'fleet-epic-heartbeat: --clear takes an EPIC issue number, got [%s]\n' "$EPIC" >&2; exit 2 ;;
    esac
    cleared=''
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -z "$EPIC" ] || [ "$(mark_epic "$f")" = "$EPIC" ] || continue
      rm -f "$f" && cleared="$cleared $f"
    done <<MARKS
$marks
MARKS
    [ -n "$EPIC" ] && win_epic unset "$EPIC"
    if [ -n "$cleared" ]; then printf 'cleared%s\n' "$cleared"
    else printf 'nothing to clear%s (%s/)\n' "${EPIC:+ for epic=$EPIC}" "$(fleet_epic_running_dir)"; fi
    exit 0 ;;
esac

case "$EPIC" in ''|*[!0-9]*)
  printf 'fleet-epic-heartbeat: an EPIC issue number is required (or --clear <epic> / --status)\n' >&2; exit 2 ;;
esac
case "$TTL" in ''|*[!0-9]*|0)
  printf 'fleet-epic-heartbeat: --ttl must be a positive seconds count, got [%s]\n' "$TTL" >&2; exit 2 ;;
esac
case "$TICK" in *[!0-9]*) TICK='' ;; esac
case "$LANDED$MEMBERS" in *[!0-9]*) LANDED='' MEMBERS='' ;; esac
{ [ -n "$LANDED" ] && [ -n "$MEMBERS" ]; } || LANDED='' MEMBERS=''
# live / inflight go together (#2247): one without the other is no reading, and a
# mark with no reading holds the install as before.
case "$LIVE$INFLIGHT" in *[!0-9]*) LIVE='' INFLIGHT='' ;; esac
{ [ -n "$LIVE" ] && [ -n "$INFLIGHT" ]; } || LIVE='' INFLIGHT=''
[ -n "$SESS" ] || SESS=$(fleet_current_session 2>/dev/null || :)
# One line: newlines/tabs folded, `EPIC:` dropped, trimmed, ≤ 120 characters.
TITLE=$(printf '%s' "$TITLE" | tr '\n\t\r' '   ' | sed -e 's/^ *//' -e 's/^EPIC: *//' -e 's/^ *//' -e 's/ *$//' | cut -c1-120)

F=$(fleet_epic_mark_file "$REPO" "$EPIC")
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
  [ -z "$MEMBERS" ] || printf 'landed: %s\nmembers: %s\n' "$LANDED" "$MEMBERS"
  [ -z "$LIVE" ] || printf 'live: %s\ninflight: %s\n' "$LIVE" "$INFLIGHT"
  [ -z "$TITLE" ] || printf 'title: %s\n' "$TITLE"
} > "$tmp" 2>/dev/null || ! mv -f "$tmp" "$F" 2>/dev/null; then
  rm -f "$tmp" 2>/dev/null
  printf 'fleet-epic-heartbeat: cannot write %s\n' "$F" >&2; exit 1
fi
case "$REPO" in ''|-) win_epic set "#$EPIC" ;; *) win_epic set "$REPO#$EPIC" ;; esac
[ -z "$SHORT" ] || win_name "$(fleet_epic_short "$SHORT")"
printf 'stamped epic=%s session=%s tick=%s ttl=%ss%s (%s)\n' "$EPIC" "${SESS:--}" "${TICK:--}" "$TTL" \
  "${LIVE:+ live=$LIVE inflight=$INFLIGHT}" "$F"
