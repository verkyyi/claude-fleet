#!/bin/bash
# fleet-degenerate.sh — interrupt ONE worker whose output has degenerated (issue #1557).
#
#   fleet-degenerate.sh -L <sock> --win <@wid> [--pane <%pane>] [--rows N] [--sample <unit>]
#   fleet-degenerate.sh --detect [--rows N]     # stdin: a pane capture → HIT line, rc 0/1
#
# The spinner's degenerate sweep (bin/tmux-spinner.sh, degen_check) calls this when
# bin/fleet-degenerate.awk named the same window on two consecutive sweeps. It does,
# in this order, and only while the window is still `working` and its last
# interrupt is older than FLEET_DEGENERATE_COOLDOWN_SECS (300):
#   1. `send-keys Escape` to the agent pane — once. Claude Code and Codex both stop
#      the turn on it; the session itself is untouched and carries on (#1498 merged
#      its PR right after a human's Esc).
#   2. stamp @degenerate_ts <epoch> on the window — the cooldown, and the sidebar's
#      `⟲` (bin/tmux-dashboard-rows.sh, FLEET_DEGENERATE_MARK_SECS).
#   3. one line in logs/degenerate.log.
#   4. a DEGENERATE row in the parent's child ledger, through fleet-report-parent.sh
#      (tier silent: recorded, never sent — the parent is not woken for it). A
#      hub-spawned window has no parent book; the log line is its record.
# Never touches any other window, never more than one key.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"

SOCK='' WIN='' PANE='' ROWS='' SAMPLE='' DETECT=0
while [ $# -gt 0 ]; do
  case "$1" in
    -L)        shift; SOCK="${1:-}" ;;
    --win)     shift; WIN="${1:-}" ;;
    --pane)    shift; PANE="${1:-}" ;;
    --rows)    shift; ROWS="${1:-}" ;;
    --sample)  shift; SAMPLE="${1:-}" ;;
    --detect)  DETECT=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) printf 'fleet-degenerate: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$DETECT" = 1 ]; then
  { printf '@@fleet-degenerate@@ stdin -\n'; cat; } \
    | LC_ALL=C awk -v min="${ROWS:-${FLEET_DEGENERATE_LINES:-12}}" -f "$BIN/fleet-degenerate.awk" | grep . && exit 0
  exit 1
fi

[ -n "$SOCK" ] && [ -n "$WIN" ] || { printf 'fleet-degenerate: need -L <sock> --win <@wid>\n' >&2; exit 2; }
TM() { tmux -L "$SOCK" "$@"; }

COOLDOWN="${FLEET_DEGENERATE_COOLDOWN_SECS:-300}"
case "$COOLDOWN" in ''|*[!0-9]*) COOLDOWN=300 ;; esac
now=$(date +%s)

row=$(TM display-message -p -t "$WIN" '#{window_id}|#{@claude_state}|#{@degenerate_ts}|#{@sidebar_worker}|#{pane_id}' 2>/dev/null) \
  || exit 0                                             # the window is gone
IFS='|' read -r wid st dts worker apane <<<"$row"
[ "$wid" = "$WIN" ] || exit 0
[ "$st" = working ] || exit 0                           # its turn already ended
case "$dts" in ''|*[!0-9]*) dts=0 ;; esac
[ $(( now - dts )) -ge "$COOLDOWN" ] || exit 0          # interrupted recently: once per cooldown
[ -n "$PANE" ] && [ "$PANE" != - ] || PANE="${worker:-$apane}"

# Stamp FIRST: a sweep racing this one reads the stamp and stays its hand.
TM set-window-option -t "$WIN" @degenerate_ts "$now" 2>/dev/null
TM send-keys -t "$PANE" Escape 2>/dev/null || exit 0

mkdir -p "$BIN/../logs" 2>/dev/null
LOG="$BIN/../logs/degenerate.log"
printf '%s  %-24s Escape -> %s  rows=%s unit=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" \
  "$SOCK:$WIN" "$PANE" "${ROWS:-?}" "${SAMPLE:-?}" >> "$LOG" 2>/dev/null
[ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 300 ] && \
  { tail -n 300 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null; }

bash "$BIN/fleet-report-parent.sh" -L "$SOCK" --win "$WIN" --state degenerate \
  --rows "${ROWS:-}" --sample "${SAMPLE:-}" \
  --summary "output degenerated (${ROWS:-?} rows of ${SAMPLE:-?}); interrupted with one Escape" >/dev/null 2>&1 || :
exit 0
