#!/bin/bash
# tmux-summarize.sh — write a short LLM summary of what each Claude session is
# doing, for the dash's summary column. The prompt is grounded in the session's
# BOUND ISSUE (its goal) + window name/state (its identity) + the recent screen
# (its current activity), so the one-liner reads as progress-against-the-task.
# Change-gated + capped so steady-state token cost stays tiny (a static screen is
# never re-summarized). Keyed by window-id (stable across reorders): $C/summary_<idnum>.
#
# Two modes:
#   (default)       — daemon sweep of ALL windows (launchd com.claude-fleet.summarize, ~180s)
#   --window <wid>  — summarize ONE window now. Fired by bin/summarize-hook.sh on
#                     the Stop / SessionStart Claude hooks, so the column refreshes
#                     the instant a turn ends or a session starts — not just on the
#                     180s tick. Debounced + locked so bursts/daemon don't pile up.
# OPTIONAL — the dash works without it; the summary column just stays empty.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/fleet-lib.sh" ] && . "$BIN/fleet-lib.sh"   # fleet_cache_dir / fleet_sessmap_file (#181)
C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"
G="$C/global"; mkdir -p "$G"                          # summary_<id> + sumhash live here (#181)
CACHE="$G/sumhash"; mkdir -p "$CACHE"
LOGDIR="$BIN/../logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/summarize.log"
MODEL="${SUMMARIZE_MODEL:-haiku}"
MAXW="${SUMMARIZE_MAX:-8}"
DEBOUNCE="${SUMMARIZE_DEBOUNCE:-15}"   # min seconds between summaries of ONE window
command -v claude >/dev/null 2>&1 || exit 0

# Per-fleet tmux sockets (issue #159): each fleet is its own tmux server. In
# --window mode the socket is inherited from $TMUX (the Stop/SessionStart hook
# fires in-pane); the daemon sweep fans out over every live fleet socket, setting
# SUMMARIZE_SOCK per fleet. TM() routes every tmux call to the right server.
# shellcheck source=/dev/null
[ -f "$BIN/fleet-lib.sh" ] && . "$BIN/fleet-lib.sh"
TM() { if [ -n "${SUMMARIZE_SOCK:-}" ]; then tmux -L "$SUMMARIZE_SOCK" "$@"; else tmux "$@"; fi; }

RUBRIC='You are labeling a Claude Code session for a dashboard row. Using the bound issue (the goal) and the recent terminal screen (current activity), reply with ONE short line (max ~14 words): concretely what this session is doing now and its status — progress plus any blocker or question. No preamble, no markdown, no quotes, no trailing period. If the screen is idle or empty, reply "idle".'

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# issue_title <session> <num> — the bound issue's title from the collector cache
# (issues_<slug>: milestone \t #num \t assignee \t title), resolving slug via
# sessmap (session \t slug \t repo). Empty if uncached — the prompt still gets #num.
issue_title() {
  local sess="$1" num="$2" slug sm issf
  sm=$(fleet_sessmap_file 2>/dev/null); [ -n "$sm" ] || sm="$C/sessmap"
  slug=$(awk -F'\t' -v s="$sess" '$1==s{print $2; exit}' "$sm" 2>/dev/null)
  [ -n "$slug" ] || return 0
  issf="$(fleet_cache_dir "$slug" 2>/dev/null)/issues"; [ -f "$issf" ] || issf="$C/issues_$slug"
  awk -F'\t' -v n="$num" '{g=$2; gsub(/#/,"",g); if(g==n){print $4; exit}}' "$issf" 2>/dev/null
}

# do_window <wid> <name> <state> <sess> <iss> — summarize one window. Returns 0
# iff it wrote a fresh summary. Skips panels, non-Claude windows, unchanged
# screens (hash), and very recent re-summaries (debounce). A per-window lock keeps
# the daemon sweep and a hook-fired run (or two rapid hooks) from racing.
do_window() {
  local wid="$1" name="$2" state="$3" sess="$4" iss="$5" id out lock cap h hf sum meta ititle rc=1
  case "$name" in dash|plan|backlog) return 1;; esac
  [ -z "$state" ] && return 1                       # non-Claude window
  id=${wid//[^0-9]/}; [ -z "$id" ] && return 1
  out="$G/summary_$id"
  # debounce: skip if summarized within DEBOUNCE seconds (coalesces turn bursts)
  if [ -f "$out" ] && [ "$(( $(date +%s) - $(mtime "$out") ))" -lt "$DEBOUNCE" ]; then return 1; fi
  lock="$CACHE/$id.lock"
  mkdir "$lock" 2>/dev/null || return 1             # someone else is on this window
  cap=$(TM capture-pane -p -S -120 -t "$wid" 2>/dev/null | sed '/^[[:space:]]*$/d' | tail -60)
  if [ -n "$cap" ]; then
    h=$(printf '%s' "$cap" | cksum | awk '{print $1}')   # gate on screen content only
    hf="$CACHE/$id.hash"
    if [ "$h" != "$(cat "$hf" 2>/dev/null)" ]; then
      meta="Session window: ${name}  (state: ${state})"
      if [ -n "$iss" ]; then
        ititle=$(issue_title "$sess" "$iss")
        meta="${meta}"$'\n'"Bound GitHub issue #${iss}${ititle:+: ${ititle}}"
      fi
      # tolerant: `head -1` closes the pipe early, so claude/sed may exit via
      # SIGPIPE (141) under pipefail — harmless, only the captured text is used.
      sum=$(printf '%s\n\n%s\n\nRecent screen:\n-----\n%s\n' "$RUBRIC" "$meta" "$cap" \
            | claude -p --model "$MODEL" 2>/dev/null \
            | sed 's/^[[:space:]]*//; /^[[:space:]]*$/d' | head -1 | cut -c1-120)
      echo "$h" > "$hf"
      if [ -n "$sum" ]; then
        printf '%s' "$sum" > "$out"
        printf '%s  %-12s %s\n' "$(date +%H:%M:%S)" "$name" "$(printf '%s' "$sum" | tr '\n' ' ' | cut -c1-70)" >> "$LOG"
        rc=0
      fi
    fi
  fi
  rmdir "$lock" 2>/dev/null
  return $rc
}

# --- single-window mode (hook-driven) ---
if [ "${1:-}" = "--window" ]; then
  wid="${2:-}"; [ -n "$wid" ] || exit 0
  info=$(TM display-message -p -t "$wid" \
        "#{window_name}"$'\t'"#{@claude_state}"$'\t'"#{session_name}"$'\t'"#{@issue}" 2>/dev/null) || exit 0
  IFS=$'\t' read -r name state sess iss <<EOF
$info
EOF
  [ -n "$state" ] || state="working"    # hook fired from a live claude → treat as Claude even pre-first-state
  do_window "$wid" "$name" "$state" "$sess" "$iss" || true
  [ -f "$LOG" ] && { tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; }
  exit 0
fi

# --- daemon sweep (default) ---
# Fan out over every live fleet socket (issue #159); window ids are per-server, so
# SUMMARIZE_SOCK is set per fleet and routes do_window's tmux calls there. The
# MAXW cap is applied ACROSS all fleets so one tick can't blow the token budget.
n=0
for sock in $(command -v fleet_sockets >/dev/null 2>&1 && fleet_sockets); do
  [ "$n" -ge "$MAXW" ] && break
  export SUMMARIZE_SOCK="$sock"
  while IFS=$'\t' read -r wid name state sess iss; do
    [ -z "$wid" ] && continue
    [ "$n" -ge "$MAXW" ] && break
    do_window "$wid" "$name" "$state" "$sess" "$iss" && n=$((n+1))
  done < <(TM list-windows -a -F "#{window_id}"$'\t'"#{window_name}"$'\t'"#{@claude_state}"$'\t'"#{session_name}"$'\t'"#{@issue}")
done

[ -f "$LOG" ] && { tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; }
exit 0
