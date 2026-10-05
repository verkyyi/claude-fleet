#!/bin/bash
# fleet-compact-resume.sh <pane>   — submit the turn after an in-place compaction (issue #1441)
# fleet-compact-resume.sh --brief  — what /fleet-compact-resume prints for that turn
#
# THE GAP. The in-place compaction (#1269 / #1318) is three steps — prep (the Stop
# hook asks for a recovery map and ENDS the turn), compacting (bin/fleet-compact-send.sh
# types `/compact`, the REPL goes idle again), restored (bin/refocus-hook.sh's
# SessionStart(compact) adds the charter as additionalContext, which only rides the
# NEXT turn). None of them starts that next turn. Claude Code's own autocompact runs
# mid-turn and carries on by itself; ours stopped first, so the session sat idle until
# the operator (or a cron) typed something — 3 to 37+ minutes on 2026-10-03.
#
# THE FIX. refocus-hook.sh, on a FLEET compaction only (@compact_stage was
# `compacting`), stamps @compact_restored_ts and spawns this detached. After a short
# grace it submits `/fleet-compact-resume` (commands/fleet-compact-resume.md), whose
# turn runs `--brief` below: the map, git state and the seat's own "check, then
# continue" line — so the session re-checks the map against reality and resumes.
#
# Delivery, the same two paths fleet-compact-send.sh uses: the mod's command inbox
# (bin/fleet-session-command.sh — the engine queues it until idle; rc 0/6 = taken, never
# typed as well), else (rc 3/4/5) keystrokes — Esc, text, Enter as separate send-keys
# (FLEET_ALLOW_SENDKEYS=1: sanctioned plumbing, #437) behind the operator-typing hold
# (#571), bounded by FLEET_COMPACT_RESUME_TIMEOUT (default 90 s).
#
# Skipped (one `resumed skip:<why>` ladder row, nothing sent):
#   dup        @compact_resume_ts already covers this restore
#   stage      @compact_stage moved off `restored` (a new prep, a handoff)
#   codex      a Codex pane (@cc_agent codex)
#   transfer   an agent transfer is pending (@agent_transfer_pending_until)
#   needs      @claude_state=needs — the pane waits on a human, not on us
#   self-continued
#              a turn is running that STARTED AFTER the restore: @claude_state=working
#              with a @claude_state_ts newer than @compact_restored_ts (every hook
#              edge stamps it). The harness carried on by itself — whatever was
#              queued while the pane compacted (a task notification, a peer
#              message, the operator's typed line) is delivered the moment the
#              compaction lands and starts a turn within a second (issue #1572:
#              every one of the 2026-10-04 cases still on disk read so). Ours
#              would be a second resume on top of it.
#   stale      @claude_state=working whose stamp is OLDER than the restore, for the
#              whole watch (FLEET_COMPACT_RESUME_WATCH, default 600 s): the turn it
#              marks ended before /compact (the sender runs between turns), and
#              nothing — not the spinner's reconcile, not a Stop — re-stamped the
#              pane. Unreadable, so nothing is sent.
#   typing     the operator was still typing at this window at the deadline
# A stale `working` that settles (a Stop lands, or bin/tmux-spinner.sh demotes it
# after 2× FLEET_STUCK_WORKING_SECS) with no turn after the restore in between is
# the pane that really sat idle: the turn is sent THEN, row `resumed late:mod` /
# `late:send-keys` (the dup guard still holds: one restore, one resume). Before
# #1572 both shapes were one `skip:operator` row and the idle one was given up on.
# Every send logs `resumed mod|send-keys|late:<via>` to logs/context-ladder.log;
# bin/fleet-doctor.sh WARNs on a fleet `restored` row with no `resumed` row after it.
#
# Kill switch: FLEET_COMPACT_RESUME=0 (fleet.conf / the fleet overlay, read through
# fleet-hook-conf.sh) ⇒ no action and no row. Always exits 0.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"

if [ "${1:-}" = --brief ]; then
  # shellcheck source=/dev/null
  . "$BIN/fleet-lib.sh" 2>/dev/null || { echo 'fleet-compact-resume: fleet-lib.sh missing'; exit 0; }
  pane="${TMUX_PANE:-}"
  cwd=$(pwd -P 2>/dev/null)
  ir=''
  [ -n "$pane" ] && [ -n "${TMUX:-}" ] && ir=$(tmux display-message -p -t "$pane" '#{@issue}|#{@raw}' 2>/dev/null)
  issue="${ir%%|*}"; issue="${issue//[^0-9]/}"; raw="${ir#*|}"
  if [ -z "$issue" ]; then
    case "$cwd" in */*issue-[0-9]*) issue="${cwd##*issue-}"; issue="${issue%%/*}"; issue="${issue//[^0-9]/}" ;; esac
  fi
  map=''
  [ -n "$pane" ] && map=$(fleet_recovery_map_path "$pane" "$cwd" 2>/dev/null)
  if [ -n "$issue" ]; then
    printf '[fleet compact-resume] worker #%s\n' "$issue"
    printf 'The fleet compacted you in place to avoid a handoff. CHECK FIRST: compare your recovery map with `git status`, `git log -3` and the PR; fix any drift, then resume its next step.\n'
    printf 'One issue, one worktree, one PR: work ONLY on #%s. Done = verify → push → PR (Closes #%s) → fleet-pr-verdict.sh → fleet-pr-merge.sh → fleet-report-parent.sh → stop.\n' "$issue" "$issue"
  elif [ "$raw" = 1 ]; then
    printf '[fleet compact-resume] scratch\n'
    printf 'The fleet compacted you in place to avoid a handoff. CHECK FIRST: compare this recovery map with `git status`, `git log -3` and any PR it names; fix any drift, then resume its next step.\n'
  else
    printf '[fleet compact-resume]\n'
    printf 'Context was compacted. Re-check the state below, then continue where you left off.\n'
  fi
  if [ -n "$map" ] && [ -f "$map" ]; then
    printf -- '--- recovery map (%s) ---\n' "$map"
    head -c 4000 "$map" 2>/dev/null; printf '\n'
  else
    printf -- '--- recovery map: none on disk — use the one in the compaction summary ---\n'
  fi
  if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    printf -- '--- git status -sb ---\n'; git -C "$cwd" status -sb 2>/dev/null | head -30
    printf -- '--- git log -3 ---\n'; git -C "$cwd" log -3 --oneline 2>/dev/null
  fi
  exit 0
fi

PANE="${1:-}"
[ -n "$PANE" ] || exit 0

conf=$(bash "$BIN/fleet-hook-conf.sh" FLEET_COMPACT_RESUME FLEET_HANDOFF_DEFER_SECS 2>/dev/null)
on=$(printf '%s\n' "$conf" | sed -n 1p)
[ "${on:-1}" = 0 ] && exit 0
DEFER=$(printf '%s\n' "$conf" | sed -n 2p)
GRACE="${FLEET_COMPACT_RESUME_GRACE:-3}"
TIMEOUT="${FLEET_COMPACT_RESUME_TIMEOUT:-90}"
WATCH="${FLEET_COMPACT_RESUME_WATCH:-600}"
case "$GRACE" in ''|*[!0-9]*) GRACE=3 ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=90 ;; esac
case "$WATCH" in ''|*[!0-9]*) WATCH=600 ;; esac
case "$DEFER" in ''|*[!0-9]*) DEFER=30 ;; esac

ladder() { [ -f "$BIN/fleet-ladder-log.sh" ] && sh "$BIN/fleet-ladder-log.sh" resumed --pane "$PANE" --reason "$1" </dev/null >/dev/null 2>&1; }
skip() { ladder "skip:$1"; exit 0; }
num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }

sleep "$GRACE"
watch_end=$(( $(date +%s) + WATCH ))
deadline=''    # the typing hold's bound: TIMEOUT from the first time the pane reads idle
late=''        # the pane read a stale `working` first — it settled with no turn after the restore
while :; do
  v=$(tmux display-message -p -t "$PANE" \
    '#{@compact_stage}|#{@compact_restored_ts}|#{@compact_resume_ts}|#{@claude_state}|#{@claude_state_ts}|#{@cc_agent}|#{@agent_transfer_pending_until}|#{window_id}' 2>/dev/null)
  [ -n "$v" ] || exit 0                                   # the pane is gone
  IFS='|' read -r stage rts sts st cts agent tpu wid <<EOF
$v
EOF
  rts=$(num "$rts"); sts=$(num "$sts"); cts=$(num "$cts"); tpu=$(num "$tpu")
  now=$(date +%s)
  [ "$rts" -gt 0 ] && [ "$sts" -ge "$rts" ] && skip dup
  [ "$stage" = restored ] || skip stage
  [ "$agent" = codex ] && skip codex
  [ "$tpu" -gt "$now" ] && skip transfer
  [ "$st" = needs ] && skip needs
  if [ "$st" = working ]; then
    # Stamped after the restore ⇒ a turn started after /compact: the harness went on
    # by itself (see the header). Stamped before it ⇒ stale: watch until the pane
    # settles, then send — a resume that is late beats one that never comes.
    [ "$cts" -gt "$rts" ] && skip self-continued
    [ "$now" -lt "$watch_end" ] || skip stale
    late=1; sleep 2; continue
  fi
  [ -n "$deadline" ] || deadline=$(( now + TIMEOUT ))
  held=''
  if [ "$DEFER" -gt 0 ] && [ -n "$wid" ]; then
    held=$(tmux list-clients -F '#{client_activity} #{window_id}' 2>/dev/null \
      | awk -v w="$wid" -v now="$now" -v ds="$DEFER" \
          '$2 == w && $1 ~ /^[0-9]+$/ && (now - $1) <= ds { print 1; exit }')
  fi
  [ "$held" = 1 ] || break
  [ "$now" -lt "$deadline" ] || skip typing
  sleep 2
done

tmux set-window-option -t "$PANE" @compact_resume_ts "$(date +%s)" 2>/dev/null
cmd=$(bash -c '. "$1/fleet-lib.sh" >/dev/null 2>&1 && fleet_cmd fleet-compact-resume' _ "$BIN" 2>/dev/null)
case "$cmd" in /*) : ;; *) cmd=/fleet-compact-resume ;; esac
rc=3
[ -f "$BIN/fleet-session-command.sh" ] && { bash "$BIN/fleet-session-command.sh" --from compact-resume "$PANE" "$cmd" </dev/null >/dev/null 2>&1; rc=$?; }
case "$rc" in
  0|6) via=mod ;;   # ran, or running: typing it too would resume twice
  *) via=send-keys
     FLEET_ALLOW_SENDKEYS=1 tmux send-keys -t "$PANE" Escape 2>/dev/null
     sleep 0.3 2>/dev/null || sleep 1
     FLEET_ALLOW_SENDKEYS=1 tmux send-keys -t "$PANE" -l -- "$cmd" 2>/dev/null
     sleep 0.3 2>/dev/null || sleep 1
     FLEET_ALLOW_SENDKEYS=1 tmux send-keys -t "$PANE" Enter 2>/dev/null ;;
esac
ladder "${late:+late:}$via"
exit 0
