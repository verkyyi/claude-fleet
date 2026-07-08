#!/bin/bash
# tmux-summarize.sh — write a short LLM summary of what each Claude session is
# doing, for the dash's summary column. Change-gated + capped so steady-state
# token cost stays tiny (a static screen is never re-summarized). Keyed by
# window-id (stable across reorders): $C/summary_<idnum>.
# Run from launchd (com.claude-fleet.summarize) every ~180s. OPTIONAL — the
# dash works without it; the summary column just stays empty.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"
CACHE="$C/sumhash"; mkdir -p "$CACHE"
LOGDIR="$BIN/../logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/summarize.log"
MODEL="${SUMMARIZE_MODEL:-haiku}"
MAXW="${SUMMARIZE_MAX:-8}"
command -v claude >/dev/null 2>&1 || exit 0
tmux info >/dev/null 2>&1 || exit 0

RUBRIC='Below is a Claude Code terminal session. In ONE short line (max ~14 words), say concretely what this session is doing right now and its status — task + blocker/question if any. No preamble, no markdown, no quotes, no trailing period. If the screen is idle/empty, reply "idle".
Screen:
-----'

n=0
while IFS=$'\t' read -r wid name state; do
  [ -z "$wid" ] && continue
  case "$name" in dash|plan|backlog) continue;; esac
  [ -z "$state" ] && continue            # non-Claude window → no summary
  [ "$n" -ge "$MAXW" ] && continue
  id=${wid//[^0-9]/}
  cap=$(tmux capture-pane -p -S -120 -t "$wid" 2>/dev/null | sed '/^[[:space:]]*$/d' | tail -60)
  [ -z "$cap" ] && continue
  h=$(printf '%s' "$cap" | cksum | awk '{print $1}')
  hf="$CACHE/$id.hash"
  [ "$h" = "$(cat "$hf" 2>/dev/null)" ] && continue   # unchanged screen → skip (no LLM call)
  # tolerant by design: `head -1` closes the pipe early, so claude/sed may exit
  # via SIGPIPE (141) under pipefail — harmless here, the status is discarded and
  # only the captured text ($sum) is used.
  sum=$(printf '%s\n%s\n' "$RUBRIC" "$cap" | claude -p --model "$MODEL" 2>/dev/null \
        | sed 's/^[[:space:]]*//; /^[[:space:]]*$/d' | head -1 | cut -c1-120)
  echo "$h" > "$hf"
  [ -z "$sum" ] && continue
  printf '%s' "$sum" > "$C/summary_$id"
  printf '%s  %-12s %s\n' "$(date +%H:%M:%S)" "$name" "$(printf '%s' "$sum" | tr '\n' ' ' | cut -c1-70)" >> "$LOG"
  n=$((n+1))
done < <(tmux list-windows -a -F "#{window_id}"$'\t'"#{window_name}"$'\t'"#{@claude_state}")

[ -f "$LOG" ] && { tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; }
exit 0
