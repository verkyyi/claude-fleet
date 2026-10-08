#!/bin/bash
# fleet-pane-submit.sh <socket> <window|pane> <text-file> — submit <text-file> as
# the NEXT TURN of the agent idling in that pane (issue #2234, EPIC #2230 C4):
# the first sentence a start sends into a session claimed from the warm pool.
#
# A warm window is past its TUI's input-mount flush (scratch-pool.sh), so the one
# deterministic channel left is the issue bridge's two-step injection: a bracketed
# paste of the whole (multi-line) text, then a SEPARATE Enter — an Enter inside the
# same send-keys is eaten by the paste (fleet-issue-bridge.sh bridge_inject).
# Nothing is typed until the pane is an agent at rest with an EMPTY input box
# (fleet-input.py --busy), so a person's half-typed draft is never glued onto.
#
# stdout, on success: two epoch-ms stamps `<t_ready>\t<t_prompt>` — when the input
# was seen empty and idle, and when the Enter went in (EPIC #2230 共同约定 3).
# Exit: 0 submitted (the turn started, or the input emptied) · 3 never ready within
# FLEET_SUBMIT_WAIT_SECS (5) — NOTHING was typed · 4 typed but not confirmed (the
# text sits in the input; one more Enter was tried) · 2 usage · 1 tmux failed.
# The text file is the caller's; it is read, never removed.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
sock="${1:-}" target="${2:-}" tf="${3:-}"
[ -n "$sock" ] && [ -n "$target" ] && [ -f "$tf" ] || { echo "usage: fleet-pane-submit.sh <socket> <window|pane> <text-file>" >&2; exit 2; }
TM() { tmux -L "$sock" "$@"; }
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
text=$(cat "$tf")
[ -n "${text//[[:space:]]/}" ] || { echo "fleet-pane-submit: nothing to submit" >&2; exit 2; }

pane=$(TM display-message -p -t "$target" '#{pane_id}' 2>/dev/null)
case "$pane" in %[0-9]*) ;; *) echo "fleet-pane-submit: no pane at $target" >&2; exit 1 ;; esac
state() { TM display-message -p -t "$pane" '#{pane_dead}#{pane_in_mode} #{@claude_state}' 2>/dev/null; }
busy() { python3 "$BIN/fleet-input.py" --socket "$sock" --pane "$pane" --busy; }

wait="${FLEET_SUBMIT_WAIT_SECS:-5}"; case "$wait" in ''|*[!0-9]*) wait=5 ;; esac
t=0 ready=0
while [ "$t" -le $((wait * 10)) ]; do
  st=$(state)
  case "$st" in
    00\ working*|00\ looping*|00\ needs*|00\ waking*) ;;
    00\ *) busy || { ready=1; break; } ;;
    *) ;;   # a dead pane or one in copy mode: never type into it
  esac
  sleep 0.1; t=$((t + 1))
done
[ "$ready" = 1 ] || { echo "fleet-pane-submit: $target never showed an idle, empty input — nothing typed" >&2; exit 3; }
t_ready=$(now_ms)

buf="fleet-submit-$$"
TM set-buffer -b "$buf" -- "$text" 2>/dev/null || { echo "fleet-pane-submit: set-buffer failed" >&2; exit 1; }
TM paste-buffer -t "$pane" -b "$buf" -d -p 2>/dev/null || { TM delete-buffer -b "$buf" 2>/dev/null; echo "fleet-pane-submit: paste failed" >&2; exit 1; }
sleep 0.15
# FLEET_ALLOW_SENDKEYS=1: the sanctioned two-step injection (issue #437), prefixed.
FLEET_ALLOW_SENDKEYS=1 tmux -L "$sock" send-keys -t "$pane" Enter 2>/dev/null || { echo "fleet-pane-submit: Enter failed" >&2; exit 1; }
t_prompt=$(now_ms)

# Confirm: the turn began, or the input emptied. A text still sitting in the box
# after a moment got its Enter eaten — one more, never a second paste.
t=0 again=0
while [ "$t" -lt 30 ]; do
  sleep 0.1; t=$((t + 1))
  case "$(state)" in 00\ working*) printf '%s\t%s\n' "$t_ready" "$t_prompt"; exit 0 ;; esac
  if busy; then
    if [ "$again" = 0 ] && [ "$t" -ge 6 ]; then
      again=1; FLEET_ALLOW_SENDKEYS=1 tmux -L "$sock" send-keys -t "$pane" Enter 2>/dev/null
    fi
  elif [ "$t" -ge 3 ]; then
    printf '%s\t%s\n' "$t_ready" "$t_prompt"; exit 0
  fi
done
echo "fleet-pane-submit: the text was typed into $target but the turn did not start" >&2
exit 4
