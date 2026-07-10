#!/bin/bash
# classify-sessions.sh — reconcile hook-derived @claude_state with reality using
# `claude -p` (haiku). Hooks are fast but semantically blind: a Stop between loop
# iterations looks like "done"/"needs" when the session is really LOOPING. This
# reads the pane and recovers the true intent for QUIET windows only. It is the
# ONLY way the purple 'looping' state gets set. OPTIONAL — everything else works
# without it; you just won't get looping detection or false-alarm correction.
#
# Two modes:
#   --window <target>  — classify ONE window now. Fired by bin/classify-hook.sh on
#                        the Stop hook, so a stopped turn is disambiguated (done vs
#                        looping vs needs) within ~1-2s instead of waiting for the
#                        slow daemon tick. This is the real-time path.
#   (no args)          — full scan of every window. Runs from launchd/systemd
#                        (com.claude-fleet.classify, ~1800s) purely as a backstop
#                        for windows a Stop event will never revisit (e.g. a loop
#                        killed externally, left stuck on 'looping').
#
# Cost gating (lazy):
#   * ONLY classifies windows whose state is done|needs|looping (ambiguous/quiet).
#     'working' windows are skipped entirely -> the hook heartbeat already knows them.
#   * Change-detected: a window is only sent to the LLM when its pane content
#     changed since last check. A loop paused between iterations has a static
#     screen -> classified once, then skipped -> steady-state cost ~= 0.
#   * Full-scan caps LLM classifications per tick (CLASSIFY_MAX, default 8).
#   * Per-window lock so the daemon backstop and a Stop-hook fire can't double-run.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
CACHE="$BIN/../logs/.classify-cache"; mkdir -p "$CACHE"
LOG="$BIN/../logs/classify.log"
MODEL="${CLASSIFY_MODEL:-haiku}"
MAXW="${CLASSIFY_MAX:-8}"
SETTLE="${CLASSIFY_SETTLE:-0.5}"   # let the "scheduled/waiting" line render before capture

command -v claude >/dev/null 2>&1 || exit 0

# Per-fleet tmux sockets (issue #159): each fleet is its own tmux server. In
# --window mode the socket is inherited from $TMUX (the Stop hook fires in-pane)
# or handed in via CLASSIFY_SOCK (the spinner's stuck-demote fires out-of-band);
# the full-scan fans out over every live fleet socket, setting CLASSIFY_SOCK per
# fleet. TM() routes every tmux call to the right server accordingly.
# shellcheck source=/dev/null
[ -f "$BIN/fleet-lib.sh" ] && . "$BIN/fleet-lib.sh"
TM() { if [ -n "${CLASSIFY_SOCK:-}" ]; then tmux -L "$CLASSIFY_SOCK" "$@"; else tmux "$@"; fi; }

RUBRIC='You are a status classifier for a Claude Code terminal session. Based ONLY on the terminal screen below, reply with EXACTLY ONE word and nothing else:
WORKING - Claude is actively generating or a tool is running (e.g. shows "esc to interrupt", a live spinner, streaming output).
WAITING - Claude EXPLICITLY posed a question, requested specific input, or is blocked on a permission/confirmation prompt that stops progress until the user answers (e.g. "Do you want to proceed?", "Please provide the target path.", a numbered choice list awaiting a selection, "Allow this tool to run?"). This takes precedence: if the screen shows a real pending question OR permission prompt, it is WAITING even if a caret or chips are also visible. A bare idle prompt with only a recap and suggested commands is NOT waiting.
LOOPING - idle right now but a scheduled wakeup or next loop iteration is pending (mentions waiting N seconds, scheduled, will continue, /loop).
STOPPED - finished; idle with nothing pending. This INCLUDES the normal post-turn idle screen: a recap/summary of the work Claude just COMPLETED, optionally followed by suggested-command chips (lines beginning "❯ ..."). Those chips are passive hints shown after a finished turn, not a question awaiting an answer — still STOPPED.
ERROR - a crash or error state.
Screen:
-----'

# classify_one <target> — classify a single window (target = any tmux -t spec,
# e.g. a window id "@7" or "session:idx"). Honours the state gate, change-hash
# and a per-window lock. Returns 10 iff an LLM call was actually made (so the
# full-scan can cap on real classifications), 0 otherwise. Never fails the caller.
classify_one() {
  target="$1"
  st=$(TM display-message -p -t "$target" '#{@claude_state}' 2>/dev/null)
  case "$st" in
    done|needs|looping) : ;;   # quiet/ambiguous -> candidate
    *) return 0 ;;             # working / empty -> skip (free)
  esac

  # stable key for lock + hash: prefer the window id (survives re-slotting).
  wid=$(TM display-message -p -t "$target" '#{window_id}' 2>/dev/null)
  key=$(printf '%s' "${wid:-$target}" | tr '/:@' '___')
  lock="$CACHE/$key.lock"
  mkdir "$lock" 2>/dev/null || return 0            # someone else is on this window
  # shellcheck disable=SC2064
  trap "rmdir '$lock' 2>/dev/null" RETURN

  cap=$(TM capture-pane -p -t "$target" 2>/dev/null | sed '/^[[:space:]]*$/d' | tail -35)
  [ -z "$cap" ] && return 0

  h=$(printf '%s' "$cap" | cksum | awk '{print $1}')
  hf="$CACHE/$key.hash"
  [ "$h" = "$(cat "$hf" 2>/dev/null)" ] && return 0    # unchanged screen -> no LLM call

  raw=$(printf '%s\n%s\n' "$RUBRIC" "$cap" | claude -p --model "$MODEL" 2>/dev/null)
  label=$(printf '%s' "$raw" | tr -d '[:space:].' | tr '[:lower:]' '[:upper:]')
  echo "$h" > "$hf"     # remember we've seen this screen regardless of parse

  new=""
  case "$label" in
    *WAITING*) new="needs" ;;
    *LOOPING*) new="looping" ;;
    *STOPPED*) new="done" ;;
    *ERROR*)   new="needs" ;;
    *WORKING*) new="working" ;;
    *) printf '%s  %-10s unparsed [%s]\n' "$(date +%H:%M:%S)" "$target" "${raw:0:40}" >> "$LOG" ;;
  esac

  if [ -n "$new" ] && [ "$new" != "$st" ]; then
    TM set-window-option -t "$target" @claude_state "$new" 2>/dev/null
    TM set-window-option -t "$target" @claude_state_ts "$(date +%s)" 2>/dev/null
    printf '%s  %-10s %-8s -> %s\n' "$(date +%H:%M:%S)" "$target" "$st" "$new" >> "$LOG"
  fi
  return 10           # an LLM call was made this pass
}

# ---- single-window mode (event / Stop-hook path) ----------------------------
if [ "${1:-}" = "--window" ]; then
  [ -n "${2:-}" ] || exit 0
  sleep "$SETTLE" 2>/dev/null   # settle: let post-turn scheduling text land
  classify_one "$2"
  [ -f "$LOG" ] && { tail -n 300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; }
  exit 0
fi

# ---- full-scan mode (daemon backstop) ---------------------------------------
# Fan out over every live fleet socket (issue #159); window ids are per-server, so
# CLASSIFY_SOCK is set per fleet and routes classify_one's tmux calls there. The
# MAXW cap is applied ACROSS all fleets so one busy tick can't blow the budget.
n=0
for sock in $(command -v fleet_sockets >/dev/null 2>&1 && fleet_sockets); do
  [ "$n" -ge "$MAXW" ] && break
  export CLASSIFY_SOCK="$sock"
  while IFS= read -r win; do
    [ "$n" -ge "$MAXW" ] && break   # cap hit: stop, don't keep scanning the rest
    classify_one "$win"; rc=$?
    [ "$rc" -eq 10 ] && n=$((n + 1))
  done < <(TM list-windows -a -F '#{window_id}')
done

[ -f "$LOG" ] && { tail -n 300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; }
exit 0
