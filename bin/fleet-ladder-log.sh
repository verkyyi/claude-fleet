#!/bin/sh
# fleet-ladder-log.sh — one ledger line per step of the context ladder (issue #1320,
# EPIC #1315 C5): every compaction and every handoff a session goes through.
#
# THE GAP. Checking "did auto-handoff fire?" could be answered from
# logs/handoff-cycle.log, but an in-place compaction (#1269) left no record at all
# — it lived only on tmux options that the next step overwrites, so the only way
# to know a session had been compacted was to read its transcript. This ledger is
# that record: six steps, each written by the one script that performs it.
#
#   prep              bin/set-claude-state.sh   Stop blocked: write the recovery map
#   compacting        bin/fleet-compact-send.sh `/compact …` typed into the pane
#   restored          bin/refocus-hook.sh       SessionStart(compact) — reason
#                                               `fleet` (ours) or `auto` (Claude
#                                               Code's own auto-compaction)
#   handoff-nudge     bin/set-claude-state.sh   Stop blocked: run /fleet-handoff —
#                                               reason `pct`, `cap` (#1316) or `codex`
#   handoff-complete  bin/fleet-handoff-cycle.sh pane cleared and resumed
#   hub-warn          bin/set-claude-state.sh   the HUB reached the handoff line:
#                                               warned + notified, never blocked (#1319)
#
# Usage:
#   fleet-ladder-log.sh <step> [--pane P] [--socket S] [--ctx N] [--count N] [--reason TEXT]
#   fleet-ladder-log.sh --trim <file>     # the shared size cap (see ROTATION)
#
# --pane defaults to $TMUX_PANE; session, window name, @ctx_pct and @compact_count
# come from that pane in ONE tmux read (--ctx / --count override, for a caller that
# captured them before the step changed them — the handoff cycle's /clear zeroes the
# count). --socket targets `tmux -L S` for a caller outside the pane's $TMUX.
#
# THE FILE. `$FLEET_HANDOFF_LOG_DIR/context-ladder.log`, else `<bin>/../logs/` — the
# same directory as handoff-cycle.log (on an install both are ~/.claude/fleet/logs;
# under the selftest shadow root it is the shadow's empty logs/). Tab-separated,
# one row per step, the column list in the `#` header written when it is created:
#
#   epoch  time  step  session  pane  window  ctx_pct  count  reason
#
# ctx_pct / count are `-` when unknown. bin/fleet-doctor.sh's `context` row reads it
# (read-only) — 24h counts plus the live window highest on the ladder.
#
# ROTATION. Size-capped, the same cap handoff-cycle.log gets (that script calls
# `--trim` on its own log at start): over FLEET_LADDER_LOG_MAX_BYTES (default 1 MiB)
# the file is cut to the newest rows filling half the cap, `#` header lines kept,
# via a temp + mv.
#
# Never fails its caller: always exits 0 and prints nothing (a Stop hook's stdout
# is its JSON decision).
set -u

BIN=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
MAX="${FLEET_LADDER_LOG_MAX_BYTES:-1048576}"
case "$MAX" in ''|*[!0-9]*) MAX=1048576 ;; esac

# ladder_trim <file> — once the file passes $MAX bytes, keep the `#` header + the
# newest whole rows that fit in half of it. 0 = no cap.
ladder_trim() {
  _f="$1"
  [ "$MAX" -gt 0 ] && [ -f "$_f" ] || return 0
  _sz=$(wc -c < "$_f" 2>/dev/null | tr -d ' ')
  case "$_sz" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_sz" -gt "$MAX" ] || return 0
  _tmp="$_f.trim.$$"
  # tail -c may start mid-row: drop that first, partial line.
  { grep '^#' "$_f"; grep -v '^#' "$_f" | tail -c $(( MAX / 2 )) | sed 1d; } > "$_tmp" 2>/dev/null \
    && mv -f "$_tmp" "$_f" 2>/dev/null
  rm -f "$_tmp" 2>/dev/null
  return 0
}

if [ "${1:-}" = --trim ]; then
  [ -n "${2:-}" ] && ladder_trim "$2"
  exit 0
fi

STEP="${1:-}"
case "$STEP" in
  prep|compacting|restored|handoff-nudge|handoff-complete|hub-warn) shift ;;
  *) exit 0 ;;
esac
PANE="${TMUX_PANE:-}" SOCKET='' CTX='' COUNT='' REASON=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pane)   PANE="${2:-}"; shift 2 ;;
    --socket) SOCKET="${2:-}"; shift 2 ;;
    --ctx)    CTX="${2:-}"; shift 2 ;;
    --count)  COUNT="${2:-}"; shift 2 ;;
    --reason) REASON="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

sess='' win=''
if [ -n "$PANE" ]; then
  # window_name LAST: it is the one field that may itself contain a `|`.
  _fmt='#{session_name}|#{@ctx_pct}|#{@compact_count}|#{window_name}'
  if [ -n "$SOCKET" ]; then
    _v=$(tmux -L "$SOCKET" display-message -p -t "$PANE" "$_fmt" 2>/dev/null)
  else
    _v=$(tmux display-message -p -t "$PANE" "$_fmt" 2>/dev/null)
  fi
  if [ -n "$_v" ]; then
    sess=${_v%%|*}; _v=${_v#*|}
    [ -n "$CTX" ] || CTX=${_v%%|*}; _v=${_v#*|}
    [ -n "$COUNT" ] || COUNT=${_v%%|*}
    win=${_v#*|}
  fi
fi
case "$CTX" in ''|*[!0-9]*) CTX=- ;; esac
case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac
# One row per line, one field per tab: flatten both out of the free-text fields.
clean() { printf '%s' "$1" | tr '\t\n\r' '   '; }
sess=$(clean "${sess:--}"); win=$(clean "${win:--}"); REASON=$(clean "${REASON:--}")
[ -n "$sess" ] || sess=-; [ -n "$win" ] || win=-; [ -n "$REASON" ] || REASON=-

DIR="${FLEET_HANDOFF_LOG_DIR:-$BIN/../logs}"
mkdir -p "$DIR" 2>/dev/null || exit 0
LOG="$DIR/context-ladder.log"
if [ ! -s "$LOG" ]; then
  printf '# context-ladder.log — one row per compaction / handoff step (issue #1320; writer: bin/fleet-ladder-log.sh)\n# epoch\ttime\tstep\tsession\tpane\twindow\tctx_pct\tcount\treason\n' \
    >> "$LOG" 2>/dev/null || exit 0
fi
now=$(date +%s 2>/dev/null || echo 0)
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)" \
  "$STEP" "$sess" "${PANE:--}" "$win" "$CTX" "$COUNT" "$REASON" >> "$LOG" 2>/dev/null
ladder_trim "$LOG"
exit 0
