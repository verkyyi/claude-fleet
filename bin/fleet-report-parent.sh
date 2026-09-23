#!/bin/bash
# fleet-report-parent.sh — a finished child worker PUSHES its outcome to the
# session that SPAWNED it (issue #574), instead of leaving that session to poll.
#
#   fleet-report-parent.sh --state merged|blocked|failed|reaped|stopped|waiting|idle [options]
#
# The parent/child link has existed since #503: every spawn stamps `@origin` on
# the new window (`issue-<N>` / `scratch-<N>`, empty ≡ the hub), canonicalised by
# fleet_origin_canon. But every consumer of it was DISPLAY or ARCHIVE — the dash's
# `↳#483` tag and its grouping, the ledger/history provenance column. Nothing ever
# used it as an ADDRESS, so a `--spawn`ed follow-up could merge and be reaped
# without the worker that filed it ever hearing. This is the missing step, and it
# adds NO new window state to keep in sync across migrate/restore: `@origin` is
# already there, already canonical, and already true for a scratch parent too.
#
# The channel is the one the fleet already uses to talk to live sessions:
# fleet_peer_send (#513) — the SendMessage tool's local inbox socket. Queued while
# the parent is mid-turn, delivered as its next turn. NEVER tmux send-keys (#437).
#
#   --state <s>     merged | blocked | failed | reaped | stopped | waiting | idle
#                   (required). A `stopped` whose child is still busy (issue #864)
#                   is re-filed here as `waiting` (bg job / open PR) or `idle` (the
#                   PR gate could not be read) — see TIERS below.
#   --pr <N>        the PR number, for a merged or failed report
#   --verdict <v>   the reap verdict, for a `reaped` report (unmerged, dirty, …)
#   --summary <t>   1–3 lines of what happened (the parent's whole payoff)
#   --win <target>  the CHILD window; default: the window $TMUX_PANE sits in.
#                   A REAPER passes this — it runs in its own pane, not the child's.
#   --origin <key>  override the child's @origin read (a reaper that already read it)
#   --issue <N> / --title <t> / --branch <b>   override what is read off the window
#   --key <k>       override the CHILD's own key (`issue-<N>` / `scratch-<N>`) —
#                   for a reaper running outside the child's pane, whose window may
#                   carry no @worktree to derive a scratch key from
#   -L <socket>     tmux socket label, for a caller with no $TMUX (a daemon/selftest)
#   --only-once     skip if this window already reported (@reported 1). THE REAPER
#                   FLAG: the ship path reports first, and a blunter reap-time
#                   report for the same session would be pure duplicate context.
#   --dry-run       print the resolved target + the exact envelope; send nothing
#   -h              this header
#
# EXIT 0 IS THE RULE, not the exception: no parent (hub-spawned / cross-fleet),
# the parent window already reaped, no live Claude under it, or the fleet has
# FLEET_CHILD_REPORT=0 — every one of those is a silent success. This runs on the
# child's SHIP path and must never block it or turn a landed PR into an error.
# Exit 2 is reserved for a usage mistake (bad/missing --state, unknown flag).
#
# On a delivered report the child's window is stamped `@reported 1`, which is what
# stops the reaper fallback (session-end-hook.sh / dash-reap.sh) sending a second,
# blunter report for the same session a minute later.
#
# TIERS (issue #938): every report is banded by report_tier (fleet-children-lib.sh)
# and the band is written into the ledger event. loud = someone must act (BLOCKED,
# FAILED not being fixed, REAPED unmerged/dirty, a true STOPPED, a child in
# `needs`); quiet = worth knowing (MERGED, FAILED while fixing, other reaps);
# silent = a turn boundary (WAITING, IDLE) — RECORDED, never sent, never stamped.
# FLEET_CHILD_REPORT=immediate (the default; legacy `1`) delivers loud + quiet one
# by one, exactly as before; `batch` is the digest's (C5, #939).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

STATE='' PR='' VERDICT='' SUMMARY='' WIN='' ORIGIN='' ISSUE='' TITLE='' BRANCH='' KEY='' SOCK='' DRY=0 ONCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --state)    shift; STATE="${1:-}" ;;
    --pr)       shift; PR="${1:-}" ;;
    --verdict)  shift; VERDICT="${1:-}" ;;
    --summary)  shift; SUMMARY="${1:-}" ;;
    --win)      shift; WIN="${1:-}" ;;
    --origin)   shift; ORIGIN="${1:-}" ;;
    --issue)    shift; ISSUE="${1:-}" ;;
    --title)    shift; TITLE="${1:-}" ;;
    --branch)   shift; BRANCH="${1:-}" ;;
    --key)      shift; KEY="${1:-}" ;;
    -L)         shift; SOCK="${1:-}" ;;
    -L*)        SOCK="${1#-L}" ;;
    --only-once) ONCE=1 ;;
    --dry-run)  DRY=1 ;;
    -h|--help)  sed -n '2,58p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          printf 'fleet-report-parent: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

STATES='merged|blocked|failed|reaped|stopped|waiting|idle'
case "$STATE" in
  merged|blocked|failed|reaped|stopped|waiting|idle) ;;
  '') printf 'fleet-report-parent: --state is required (%s)\n' "$STATES" >&2; exit 2 ;;
  *)  printf 'fleet-report-parent: unknown --state %s (%s)\n' "$STATE" "$STATES" >&2; exit 2 ;;
esac

# quiet <msg> — the "nothing to do, and that is fine" exit. Silent in production so
# a ship path prints nothing; --dry-run says WHY it would send nothing.
quiet() { [ "$DRY" = 1 ] && printf 'fleet-report-parent: %s — nothing to send\n' "$1"; exit 0; }

TM() { if [ -n "$SOCK" ]; then tmux -L "$SOCK" "$@"; else tmux "$@"; fi; }

# --- the child window: one tmux read for everything off it ---------------------
# window_name rides LAST: it is free text (a rename can put anything in it) and the
# fields are `|`-separated — a tab/0x1f separator prints as a literal `\037` on the
# tmux 3.4 that CI ships.
target="${WIN:-${TMUX_PANE:-}}"
[ -n "$target" ] || quiet 'no child window (no --win and no $TMUX_PANE)'
row=$(TM display-message -p -t "$target" \
        '#{window_id}|#{@origin}|#{@issue}|#{@reported}|#{@worktree}|#{@claude_state}|#{window_name}' 2>/dev/null)
[ -n "$row" ] || quiet "child window '$target' is gone"
selfwin=${row%%|*};  row=${row#*|}
worigin=${row%%|*};  row=${row#*|}
wissue=${row%%|*};   row=${row#*|}
wreported=${row%%|*}; row=${row#*|}
wworktree=${row%%|*}; row=${row#*|}
wstate=${row%%|*};   wname=${row#*|}

[ -n "$ORIGIN" ] && worigin="$ORIGIN"
[ -n "$ISSUE" ]  && wissue="${ISSUE//[^0-9]/}"
[ -n "$TITLE" ]  && wname="$TITLE"
# The title is rendered inside "…" and the whole frame inside a
# <cross-session-message> envelope, so strip the two characters that could close
# either. A window name is operator-renameable free text (⌃e) — never trusted markup.
wname=$(printf '%s' "$wname" | tr -d '"<>')

# The ship path reports and stamps; a reaper passes --only-once so its blunter
# reap-time line is a BACKSTOP for the sessions that never got there (a crash, a
# never-shipped worker, a hand ⌃x) rather than a second report for every child.
[ "$ONCE" = 1 ] && [ "$wreported" = 1 ] && quiet "already reported (@reported 1)"

# The Stop fallback reports a stopped TURN, never a claim that an unfinished PR
# landed. Transfer/loop pauses are not completion and must not wake the parent.
if [ "$STATE" = stopped ]; then
  [ "$wstate" = "done" ] || quiet 'not done'
  [ "$(TM display-message -p -t "$target" '#{@handoff_armed}')" != 1 ] || quiet 'handoff pending'
  manifest=$(TM display-message -p -t "$target" '#{@handoff_manifest}')
  if [ -n "$manifest" ] && ! python3 - "$manifest" <<'PYLOOP'
import json, pathlib, sys
try:
    p = pathlib.Path(sys.argv[1]).parent / 'loop/state.json'
    active = p.exists() and json.loads(p.read_text()).get('status') not in ('stopped', 'complete', 'cancelled')
except (OSError, ValueError):
    active = True
sys.exit(1 if active else 0)
PYLOOP
  then quiet 'active loop'; fi
fi

# --- the switch: per-fleet conf, default ON ------------------------------------
# Read through fleet_load_conf, never off the environment: nothing exports FLEET_*
# into a hook or a run-shell job (#561), so an env read would silently see the
# default forever.
sess="$SOCK"; [ -n "$sess" ] || sess=$(fleet_current_session)
[ -n "$sess" ] && fleet_load_conf "$sess"
# shellcheck source=/dev/null
[ -f "$BIN/fleet-children-lib.sh" ] && . "$BIN/fleet-children-lib.sh"
if command -v children_report_mode >/dev/null 2>&1; then
  MODE=$(children_report_mode)
else   # a half-synced install without the lib: the historic switch
  case "${FLEET_CHILD_REPORT:-1}" in 0|no|off|false) MODE=0 ;; *) MODE=immediate ;; esac
fi
[ "$MODE" = 0 ] && quiet 'FLEET_CHILD_REPORT=0 for this fleet'

# --- rail 1: is there a parent at all? ----------------------------------------
# Empty ≡ hub (the operator spawned it — they have the dash). The literals
# `autofill` / `bridge` are daemons with no session to talk to, and a bare fleet
# NAME is #516's cross-fleet stamp — that parent lives on another socket, which
# this fleet's tmux server cannot reach. All of them: nothing to send.
case "$worigin" in
  issue-*|scratch-*) ;;
  ?*:issue-*|?*:scratch-*) ;;    # repo-qualified (issue #789) — a fleet hosting 2+ repos
  '') quiet 'hub-spawned (@origin empty)' ;;
  *)  quiet "@origin '$worigin' is not a window key (daemon / cross-fleet parent)" ;;
esac

# --- the child's own identity, for the envelope --------------------------------
selfkey="$KEY"
if [ -z "$selfkey" ]; then
  case "$wissue" in
    ''|*[!0-9]*) selfkey=$(fleet_scratch_key "$wworktree") ;;
    *)           selfkey="issue-$wissue" ;;
  esac
fi
# cwd is the LAST resort, and only useful in the child's own pane — a reaper runs
# elsewhere, which is what --key is for.
[ -n "$selfkey" ] || selfkey=$(fleet_scratch_key "$(pwd -P 2>/dev/null)")
case "$selfkey" in
  issue-*)   label="issue #${selfkey#issue-}" ;;
  scratch-*) label="scratch ~${selfkey#scratch-}" ;;
  ?*:issue-*)   label="${selfkey%%:*} issue #${selfkey##*:issue-}" ;;
  ?*:scratch-*) label="${selfkey%%:*} scratch ~${selfkey##*:scratch-}" ;;
  *)         label="session ${wname:-?}" ;;
esac
# 2+ repos (issue #789): name the child's repo, since a parent can have children in
# several; the branch itself stays the bare key.
case "$label" in
  issue\ *|scratch\ *)
    if [ -n "$sess" ] && _fleet_hosts_many "$sess" && [ -n "${selfwin:-}" ]; then
      _cr=$(fleet_window_repo "$sess" "$selfwin"); [ -n "$_cr" ] && label="$_cr $label"
    fi ;;
esac
branch_arg="$BRANCH"
[ -n "$BRANCH" ] || BRANCH="${selfkey##*:}"

# --- a turn boundary is not a stop (issue #864) -------------------------------
# The Stop fallback fires on EVERY done turn of a child that has not reported. A
# child that opened its PR and parked a gate waiter in the background (or left a
# test running) ended its turn, not its work — two monorepo EPICs saw 15/15 such
# STOPPED reports, every one of them false. So a busy child is re-filed: WAITING
# (bg job / open PR) or IDLE (gh could not read the gate — undetermined). Both are
# tier silent: the ledger records the transition, nothing is sent, nothing is
# stamped, so a later Stop that finds the child genuinely idle still reports once.
# Before the ledger (it must record the RIGHT state), after the cheap rails: this
# walks processes and may ask GitHub.
busy=''
if [ "$STATE" = stopped ] && busy=$(fleet_child_busy "$sess" "$selfwin" "$branch_arg"); then
  case "$busy" in pr-unknown) STATE=idle ;; *) STATE=waiting ;; esac
  VERDICT="$busy"
fi

# --- the tier (issue #938): does this report need to wake anyone? ---------------
if command -v report_tier >/dev/null 2>&1; then
  TIER=$(report_tier "$STATE" "$SUMMARY" "$VERDICT" "$wstate")
else
  TIER=loud
fi
UST=$(printf '%s' "$STATE" | tr '[:lower:]' '[:upper:]')

# --- the ledger (issue #937): every report is RECORDED, delivered or not --------
# Written here — a parent key is known, nothing is sent yet — so a report the rails
# below drop (parent reaped, no live Claude, no reachable inbox) still lands in the
# parent's book, and `fleet-children.sh` can answer "what are my children doing"
# without a `gh pr` + capture-pane per child. Keyed by the parent's KEY, not its
# window id, so a migrated/restored parent reads the same file. Deduped on
# (child, state, pr) against that child's latest event; never fails, prints nothing.
if [ "$DRY" != 1 ] && command -v children_append >/dev/null 2>&1; then
  children_append "$worigin" "$(python3 -c 'import json,sys; print(json.dumps(dict(zip(("child","state","pr","verdict","summary","title","tier"), sys.argv[1:]))))' \
    "$selfkey" "$UST" "${PR//[^0-9]/}" "$VERDICT" "$SUMMARY" "$wname" "$TIER" 2>/dev/null)" "$sess" || :
fi

# silent = ledger only, in every mode: a parent is never woken for a turn boundary.
# The `child busy (<reason>)` wording is #864's, kept for whoever greps for it.
[ "$TIER" = silent ] && quiet "tier=silent · $UST${busy:+ · child busy ($busy)} — ledger only"

# --- rail 2: the parent window, and a live Claude under it ---------------------
pwin=$(fleet_win_for_key "$worigin" "$SOCK") \
  || quiet "parent $worigin has no window on this fleet (reaped, or another fleet)"
[ -n "$pwin" ] || quiet "parent $worigin has no window on this fleet (reaped, or another fleet)"
# Defensive: a window whose @origin names ITSELF would otherwise message its own
# pane and wake the child that is about to stop.
[ "$pwin" = "$selfwin" ] && quiet "@origin $worigin resolves to this very window"

parent_agent=$(TM display-message -p -t "$pwin" '#{@cc_agent}' 2>/dev/null)
ppid=''
parent_sleep=$(TM display-message -p -t "$pwin" '#{@worker_lifecycle}' 2>/dev/null)
parent_evidence=$(TM display-message -p -t "$pwin" '#{@sleep_evidence}' 2>/dev/null)
if [ "$parent_agent" != codex ] && [ -z "$parent_sleep$parent_evidence" ]; then
  ppid=$(fleet_pane_claude_pid "$pwin" "$SOCK" 2>/dev/null) \
    || quiet "parent $worigin ($pwin) has no live Claude under it"
  [ -n "$ppid" ] || quiet "parent $worigin ($pwin) has no live Claude under it"
fi

# --- the envelope: FIXED shape, 4 lines typical, 6 at its widest ---------------
# Fixed because it is read by two audiences with opposite needs: the parent model,
# which must be able to judge it at a glance and get straight back to its OWN
# issue, and whatever later wants to parse it. `no reply needed` is load-bearing —
# without it a fan-out of five children costs the parent five REPLIES on top of
# five interrupts, and a parent near its handoff can least afford them.
case "$STATE" in
  merged)  st="MERGED${PR:+ (PR #${PR//[^0-9]/})}" ;;
  blocked) st="BLOCKED${PR:+ (PR #${PR//[^0-9]/})}" ;;
  failed)  st="FAILED${PR:+ (PR #${PR//[^0-9]/})}" ;;
  stopped) st="STOPPED (no ship report)" ;;
  reaped)  st="REAPED${VERDICT:+ ($VERDICT)}" ;;
  # only reached when a `needs` child lifts a silent state to loud (report_tier)
  waiting) st="WAITING${VERDICT:+ ($VERDICT)}" ;;
  idle)    st="IDLE${VERDICT:+ ($VERDICT)}" ;;
esac
msg="[child-report] $label${wname:+ \"$wname\"}"$'\n'"state: $st · branch $BRANCH"
if [ -n "$SUMMARY" ]; then
  # ≤3 lines, ≤200 chars each: the cap is the point of the envelope, not a
  # formatting nicety — every line here is context the parent did not choose to
  # spend. header + state + summary + `no reply needed` ⇒ 4 lines for the usual
  # one-line summary, 6 at the absolute widest.
  # `<`/`>` stripped for the same reason the title is: a summary is model-written
  # text and must not be able to close the peer envelope it rides inside.
  sum=$(printf '%s' "$SUMMARY" | tr -d '<>' | head -3 | cut -c1-200)
  [ -n "$sum" ] && msg="$msg"$'\n'"summary: $sum"
fi
# The language rule (issue #620) rides ON the `no reply needed` line rather than
# taking a fifth: the envelope's size is the point of the envelope, and a parent
# near its handoff can least afford an extra line. `no reply needed` still LEADS
# the line, which is what both audiences read first.
msg="$msg"$'\n'"no reply needed${FLEET_LANG_RULE_NOTICE:+ — $FLEET_LANG_RULE_NOTICE}"

if [ "$DRY" = 1 ]; then
  printf 'fleet-report-parent: would send to %s (%s, pid %s) tier=%s\n--- envelope ---\n%s\n' \
    "$worigin" "$pwin" "$ppid" "$TIER" "$msg"
  exit 0
fi

send_report() {
  if [ -n "$parent_sleep$parent_evidence" ] && [ -f "$BIN/fleet-sleep.py" ]; then
    printf '%s' "$msg" | python3 "$BIN/fleet-sleep.py" deliver --session "$sess" "$pwin"
    return $?
  fi
  if [ "$parent_agent" = codex ]; then
    printf '%s' "$msg" | python3 "$BIN/fleet-codex-session.py" send --pane "$pwin" --socket "$SOCK"
  else
    fleet_peer_send "$ppid" "$msg" "${FLEET_REPORT_FROM:-fleet-report}"
  fi
}
if send_report; then
  # The stamp is what keeps the reaper fallback from sending a second, blunter
  # report for the same session ~a minute later.
  TM set-window-option -t "$selfwin" @reported 1 2>/dev/null
  printf 'reported → %s (%s): %s\n' "$worigin" "$pwin" "$st"
  exit 0
fi
# A parent that is alive but unreachable (no registry record / no key / no socket)
# is still not the child's problem to solve.
printf 'fleet-report-parent: parent %s (%s, pid %s) has no reachable inbox — not reported\n' \
  "$worigin" "$pwin" "$ppid" >&2
exit 0
