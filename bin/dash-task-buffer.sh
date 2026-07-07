#!/bin/bash
# dash-task-buffer.sh "<query>" — debounce buffer for the dash new-task box,
# so a MULTI-LINE PASTE becomes ONE issue instead of one per line.
#
# fzf fires the enter binding once per pasted newline. Depending on how our
# emitted clear-query interleaves with the queued input, each enter's {q} is
# either just the new line or the CUMULATIVE text so far (observed in the
# #661–#665 incident: cumulative). Reconstruct the original lines either way:
#   * q starts with the previous q  -> the new line is the suffix
#   * otherwise                     -> q itself is a fresh line
# Lines accumulate in $BUF; after a quiet window with no new enters, a single
# finalizer creates ONE issue: title = first line, body = full text
# (dash-new-session.sh already supports multi-line input).
C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"
BUF="$C/newtask_text"; PREV="$C/newtask_prev"; TS="$C/newtask_ts"; LOCK="$C/newtask.lock"
QUIET="${DASH_TASK_QUIET:-2}"   # seconds of silence before the task is finalized
q="$1"; [ -z "$q" ] && exit 0

prev=""; [ -f "$PREV" ] && prev=$(cat "$PREV")
line="$q"
if [ -n "$prev" ]; then case "$q" in "$prev"*) line="${q#"$prev"}";; esac; fi
[ -n "$line" ] && printf '%s\n' "$line" >> "$BUF"
printf '%s' "$q" > "$PREV"
touch "$TS"

mt() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# Single background finalizer per burst (lockdir); waits for the quiet window,
# then hands the whole buffered text to dash-new-session.sh.
mkdir "$LOCK" 2>/dev/null || exit 0
BIN="$(cd "$(dirname "$0")" && pwd)"
(
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
  while :; do
    sleep "$QUIET"
    [ $(( $(date +%s) - $(mt "$TS") )) -ge "$QUIET" ] && break
  done
  text=$(cat "$BUF" 2>/dev/null)
  rm -f "$BUF" "$PREV" "$TS"
  [ -n "$text" ] && bash "$BIN/dash-new-session.sh" "$text"
) >/dev/null 2>&1 &
exit 0
