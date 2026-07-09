#!/bin/sh
# set-claude-state.sh <state> [bell]
# Stamps the current tmux window's @claude_state (semantic: working|done|needs).
# The tmux-spinner.sh daemon reads @claude_state and renders ALL the visuals
# (spinner glyph + its pulsing font color + name color) via @spin, so this hook
# only sets the semantic state and (for needs) rings the bell.
# Registered as a Claude Code hook (see hooks/settings-hooks.json).
# Always exits 0 so it never blocks a turn.
set -u  # POSIX sh: pipefail is bash-only (dash has none)
[ -n "${TMUX:-}" ] || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0

BIN=$(cd "$(dirname "$0")" && pwd)

case "${1:-}" in
  needs)
    # The Notification hook fires this path unconditionally, but Claude Code emits
    # a benign idle_prompt Notification ("Claude is waiting for your input") ~60s
    # after ANY session goes idle. Left unfiltered it flips every finished session
    # to needs+bell and re-flips the classifier's verdict — cry-wolf. Discriminate
    # on the payload (mirrors the AskUserQuestion stdin-inspection in 'busy'). The
    # payload exposes no structured type field (only `message`), so we substring
    # the wording; if Claude Code rephrases it we fall back to needs+bell — the
    # safe direction (an idle session rings, not a real prompt silently missed).
    # A benign idle prompt -> 'leave': DON'T write state, just drop the bell, so
    # whatever the Stop-hook classifier decided (done for finished, needs for a
    # real pending question) stays authoritative. A real permission/elicitation
    # prompt (and anything unrecognised) keeps needs+bell.
    sem="needs"
    if [ ! -t 0 ]; then
      case "$(cat 2>/dev/null)" in
        *'waiting for your input'*)
          sem="leave"; set -- "leave" ;;   # idle_prompt: leave state as-is, no bell
      esac
    fi
    ;;
  done)  sem="done" ;;
  busy)
    # PreToolUse heartbeat = working, EXCEPT the AskUserQuestion tool: it opens a
    # blocking multiple-choice popup mid-turn and NO Notification hook fires for it
    # (AskUserQuestion isn't a Notification matcher), so without this the window
    # would masquerade as 'working' the whole time it's really waiting on the user.
    # PreToolUse is the only caller that passes 'busy'; its stdin JSON carries the
    # tool_name. PostToolUse (arg 'working') fires when the user answers -> working.
    sem="working"
    if [ ! -t 0 ]; then
      case "$(cat 2>/dev/null)" in
        *'"tool_name":"AskUserQuestion"'*|*'"tool_name": "AskUserQuestion"'*)
          sem="needs"; set -- needs bell ;;
      esac
    fi
    ;;
  *)     sem="working" ;;   # PostToolUse / prompt submitted
esac

# 'leave' (benign idle_prompt) intentionally writes nothing — it preserves the
# existing @claude_state and its timestamp so the classifier stays authoritative.
if [ "$sem" != "leave" ]; then
  tmux set-window-option -t "$TMUX_PANE" @claude_state "$sem" 2>/dev/null
  # last-activity stamp (drives the dashboard's "Nm ago" column).
  tmux set-window-option -t "$TMUX_PANE" @claude_state_ts "$(date +%s)" 2>/dev/null
fi

[ "${2:-}" = "bell" ] && printf '\a' > /dev/tty 2>/dev/null

# Re-slot windows by urgency (lowest-index window pinned) — backgrounded, never blocks the turn.
sess=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
[ -n "$sess" ] && ( "$BIN/tmux-sort-windows.sh" "$sess" >/dev/null 2>&1 & )

exit 0
