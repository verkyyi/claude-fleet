#!/bin/bash
# fleet-stream-resume.sh — a turn an API error cut off is picked up again by itself
# (issue #4714). Wired to Claude Code's `StopFailure` hook (≥ 2.1.29x: the turn
# ended on an API error, `error` names its kind; the hook's output is ignored).
#
# Before: «API Error: Connection lost mid-response» left the session at its prompt
# (the 7501 relay reads `error` → exited) until a person typed something — three
# times in one day on one managed Mac, each a stream the machine's credential proxy cut when
# it restarted. Now a TRANSIENT kind (server_error · overloaded · unknown — the
# stream cut, a 5xx, an overloaded API) books one resume: after
# FLEET_STREAM_RESUME_SECS (20) the session is told, over its own inbox
# (bin/fleet-peer-send.sh %<pane> — never send-keys), to carry on where it left off.
# It is not sent when, by then, anything else moved the session: a person's prompt
# (state working / busy / needs), or a later failure (it books its own).
#
# A budget per window, so a dead upstream is not a loop: at most
# FLEET_STREAM_RESUME_MAX (3) resumes per FLEET_STREAM_RESUME_WINDOW (1800 s) —
# past it the session stays where it stopped, for a person, and the log says so.
# Never for a quota (rate_limit — the quota rotation's), an auth / billing /
# request error, or a headless `claude -p`.
#
# Where it gives up — a kind it does not resume (but a quota), or the budget spent —
# a WORKER (a window bound to an issue) tells the session that spawned it, once per
# budget window (issue #4702): `failed` through bin/fleet-report-parent.sh, «idle at
# its prompt, not done». Before, an EPIC driver saw only a quiet window with no PR,
# took it for a worker that had exited, and reaped and re-spawned the ticket.
#
#   FLEET_STREAM_RESUME=0   off (the session stops at its prompt, as before)
#   log: $FLEET_CONF_DIR/logs/stream-resume.log
#
# Test seams: FLEET_STREAM_RESUME_FG=1 waits in the foreground;
# FLEET_STREAM_RESUME_SEND_CMD replaces fleet-peer-send.sh (gets the pane, the text);
# FLEET_STREAM_RESUME_REPORT_CMD replaces fleet-report-parent.sh (gets its options).
# Always exits 0.
set -u
[ "${FLEET_STREAM_RESUME:-1}" = 0 ] && exit 0
[ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || exit 0
case "${CLAUDE_CODE_ENTRYPOINT:-cli}" in cli) : ;; *) exit 0 ;; esac   # headless child → not this pane's
BIN="$(cd "$(dirname "$0")" && pwd)"

payload=''
[ -t 0 ] || payload=$(cat 2>/dev/null)
err=$(printf '%s' "$payload" | python3 -c 'import json, sys
try:
    e = json.load(sys.stdin).get("error")
except Exception:
    e = ""
print(e if isinstance(e, str) else "")' 2>/dev/null)

logd="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/logs"
log() { mkdir -p "$logd" 2>/dev/null && printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TMUX_PANE" "$*" >> "$logd/stream-resume.log" 2>/dev/null; }

now=$(date +%s)
max="${FLEET_STREAM_RESUME_MAX:-3}"; win="${FLEET_STREAM_RESUME_WINDOW:-1800}"

# tell_parent <why> — a worker that will stay stopped says so to its parent, once
# per budget window (@stream_told = the window's start); never a person's session
tell_parent() {
  local told st sum
  [ -n "$(tmux display-message -p -t "$TMUX_PANE" '#{@issue}' 2>/dev/null)" ] || return 0
  st=$(tmux show-options -wqv -t "$TMUX_PANE" @stream_resume 2>/dev/null)
  case "$st" in *' '*) st=${st#* } ;; *) st='' ;; esac
  case "$st" in ''|*[!0-9]*) st='' ;; esac
  # no budget window open yet (or it lapsed): this give-up opens one, so the next
  # failure in it finds the same start and says nothing again
  if [ -z "$st" ] || [ $((now - st)) -ge "$win" ]; then
    st=$now; tmux set-option -wq -t "$TMUX_PANE" @stream_resume "0 $st" 2>/dev/null
  fi
  told=$(tmux show-options -wqv -t "$TMUX_PANE" @stream_told 2>/dev/null)
  [ "$told" = "$st" ] && { log "parent already told for the window since $st"; return 0; }
  tmux set-option -wq -t "$TMUX_PANE" @stream_told "$st" 2>/dev/null
  sum="its turn ended on an API error ($err) and $1 — the session is idle at its prompt, not done: resume it or reap it"
  log "told parent error=$err: $1"
  if [ -n "${FLEET_STREAM_RESUME_REPORT_CMD:-}" ]; then
    $FLEET_STREAM_RESUME_REPORT_CMD --state failed --win "$TMUX_PANE" --summary "$sum"
  else
    ( bash "$BIN/fleet-report-parent.sh" --state failed --win "$TMUX_PANE" --summary "$sum" ) </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
}

case "$err" in
  server_error|overloaded|unknown) : ;;
  rate_limit) log "skip error=$err: not a transient kind"; exit 0 ;;
  *) log "skip error=${err:--}: not a transient kind"; tell_parent "it is not one that is resumed by itself"; exit 0 ;;
esac

# @stream_resume = "<count> <since>": the resumes booked in the window that began at <since>
book=$(tmux show-options -wqv -t "$TMUX_PANE" @stream_resume 2>/dev/null)
n=${book%% *}; since=${book#* }
case "$n" in ''|*[!0-9]*) n=0 ;; esac
case "$since" in ''|*[!0-9]*) since=$now ;; esac
[ $((now - since)) -lt "$win" ] || { n=0; since=$now; }
if [ "$n" -ge "$max" ]; then
  log "skip error=$err: $n resumes since $since (max $max per ${win}s) — left for a person"
  tell_parent "$n automatic resumes in $((win / 60)) min did not get it going"
  exit 0
fi
tmux set-option -wq -t "$TMUX_PANE" @stream_resume "$((n + 1)) $since" 2>/dev/null
tmux set-option -wq -t "$TMUX_PANE" @stream_fail_ts "$now" 2>/dev/null
log "booked error=$err: resume $((n + 1))/$max in ${FLEET_STREAM_RESUME_SECS:-20}s"

resume() {
  sleep "${FLEET_STREAM_RESUME_SECS:-20}"
  [ "$(tmux show-options -wqv -t "$TMUX_PANE" @stream_fail_ts 2>/dev/null)" = "$now" ] \
    || { log "dropped error=$err: a later failure booked its own"; return; }
  st=$(tmux show-options -wqv -t "$TMUX_PANE" @claude_state 2>/dev/null)
  case "$st" in working|busy|needs*) log "dropped error=$err: the session moved on (state $st)"; return ;; esac
  tmux set-option -wqu -t "$TMUX_PANE" @stream_fail_ts 2>/dev/null
  text="Your last response was cut off by an API error ($err) before it finished. Continue the task from where it stopped — re-check anything that may not have completed."
  if [ -n "${FLEET_STREAM_RESUME_SEND_CMD:-}" ]; then
    $FLEET_STREAM_RESUME_SEND_CMD "$TMUX_PANE" "$text"; rc=$?
  else
    bash "$BIN/fleet-peer-send.sh" "$TMUX_PANE" "$text" >/dev/null 2>&1; rc=$?
  fi
  log "sent error=$err: rc $rc"
}
if [ "${FLEET_STREAM_RESUME_FG:-0}" = 1 ]; then
  resume
else
  ( resume ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi
exit 0
