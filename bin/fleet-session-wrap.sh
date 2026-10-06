#!/bin/bash
# fleet-session-wrap.sh — the ONE door every fleet session is opened through
# (issue #1784, EPIC #1776 C8). It takes exactly fleet-claude.sh's arguments, runs
# fleet-claude.sh with them, and stays in the pane when the agent exits:
#
#   • the operator's own exit (Ctrl+C twice, Ctrl+D, /exit), a crash, a kill:
#     the window stays, @claude_state becomes `exited` (the list draws ⏏ 已退出)
#     and the pane shows the recovery page (bin/fleet-session-page.py):
#       ↵  resume the SAME conversation (@cc_session_id / @codex_session_id)
#       r  start a new one in this window
#       q  recycle the window — the close-on-exit the SessionEnd hook used to do
#          on every exit, now only on purpose (session-end-hook.sh --recycle)
#   • the FLEET's own exit — sleep, migrate, move, stop, transfer stamp
#     the window's @wrap_quiet before they type /exit — and a launch that
#     ends within FLEET_WRAP_FAST_FAIL seconds (default 5): it returns the
#     agent's exit status, exactly as the bare launcher did, so every caller's
#     `; exec $SHELL` / `|| fallback` / @restore_exit stamp still works.
#   • outside tmux: a transparent pass-through.
#
# Before this, one stray double Ctrl+C closed the window (the SessionEnd hook's
# kill-window), and on a machine whose last window that was, the tmux server and
# every client's view of the machine went with it (m4, 2026-10-05/06).
#
# The rule bin/session-wrap-selftest.sh lints: no spawn path runs fleet-claude.sh
# directly in a new window / respawned pane — it names this script.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
LAUNCH="${FLEET_WRAP_LAUNCH:-$BIN/fleet-claude.sh}"   # selftest seam: a fake launcher
FAST="${FLEET_WRAP_FAST_FAIL:-5}"
case "$FAST" in ''|*[!0-9]*) FAST=5 ;; esac
# tmux off a bare PATH (issue #1774): the wrapper stamps the window before the
# launcher runs. fleet-lib.sh's fleet_path_fill, inline — the wrapper stays light
# (no lib) between the pane and the agent: append each tool dir PATH lacks.
for d in ${FLEET_TOOL_DIRS:-$HOME/.local/bin /opt/homebrew/bin /usr/local/bin}; do
  [ -d "$d" ] || continue
  case ":$PATH:" in *":$d:"*) ;; *) PATH="${PATH:+$PATH:}$d" ;; esac
done
export PATH

# The launch POLICY a resume / new session keeps: its Codex home and an explicit
# model (the agent is the one that just ran, @cc_agent). The rest — a seed prompt,
# a --resume + nudge, a --session-id — belonged to the first launch only.
policy=(); want=''
for a in "$@"; do
  if [ -n "$want" ]; then [ "$want" = --agent ] || policy+=("$want" "$a"); want=''; continue; fi
  case "$a" in
    --agent|--codex-home|--model) want=$a ;;
    --model=*) policy+=("$a") ;;
  esac
done

intmux=0; [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] && intmux=1
opt()  { tmux display-message -p -t "$TMUX_PANE" "#{$1}" 2>/dev/null; }
wset() { tmux set-option -w -t "$TMUX_PANE" "$@" 2>/dev/null; }

# Ctrl+C belongs to the agent: a trapped (not ignored) INT resets to default in
# the child, and the wrapper itself just keeps going when the agent returns.
trap ':' INT QUIT

cmd=("$@")
while :; do
  if [ "$intmux" = 1 ]; then
    wset -u @wrap_quiet
    tmux set-option -p -t "$TMUX_PANE" @session_wrap "$$" 2>/dev/null
    # The window this agent's identity lives on (issue #1844): when the pane is
    # broken out (prefix !), fleet-window-carry.sh sees it arrive elsewhere and
    # moves the identity after it.
    tmux set-option -p -t "$TMUX_PANE" @wrap_win "$(opt window_id)" 2>/dev/null
  fi
  export FLEET_SESSION_WRAP=$$
  # The session's own credential (issue #1809, docs/FLEET-MCP.md «Identity»): minted
  # fresh for every launch, handed to the agent — and so to the fleet tool service —
  # through the environment ONLY (never argv, a file or a log), revoked when the
  # agent exits. No tool service (FLEET_MCP=0), outside tmux, or a mint that fails:
  # none — the tools then know the session by its window's options, as before.
  unset FLEET_WORKER_CRED
  if [ "$intmux" = 1 ] && [ "${FLEET_MCP:-1}" != 0 ] && [ -f "$BIN/fleet-mcp.py" ]; then
    FLEET_WORKER_CRED=$(python3 "$BIN/fleet-mcp.py" --cred mint 2>/dev/null) && [ -n "$FLEET_WORKER_CRED" ] \
      && export FLEET_WORKER_CRED || unset FLEET_WORKER_CRED
  fi
  t0=$(date +%s)
  "$LAUNCH" ${cmd[@]+"${cmd[@]}"}
  rc=$?
  if [ -n "${FLEET_WORKER_CRED:-}" ]; then
    python3 "$BIN/fleet-mcp.py" --cred revoke 2>/dev/null
    unset FLEET_WORKER_CRED
  fi
  [ "$intmux" = 1 ] || exit "$rc"
  # The fleet made it exit (it stamped @wrap_quiet), or a sleep is under way.
  if [ "$(opt @wrap_quiet)" = 1 ]; then wset -u @wrap_quiet; exit "$rc"; fi
  case "$(opt @worker_lifecycle)" in preparing|sleeping) exit "$rc" ;; esac
  # A launch that never came up (claude missing, a refused resume, a one-shot
  # `--version`): the caller's own failure path decides, as it always did.
  # Its rc stays on the pane too: tmux ≤3.4 can leave #{pane_dead_status} empty
  # when it misses the SIGCHLD (#1801), and fleet-transfer's rollback names it.
  if [ $(( $(date +%s) - t0 )) -lt "$FAST" ]; then
    tmux set-option -p -t "$TMUX_PANE" @wrap_last_rc "$rc" 2>/dev/null; exit "$rc"
  fi

  agent=$(opt @cc_agent); [ "$agent" = codex ] || agent=claude
  if [ "$agent" = codex ]; then sid=$(opt @codex_session_id); else sid=$(opt @cc_session_id); fi
  wset @wrap_exit_rc "$rc"
  wset @claude_needs ''
  wset @claude_state_ts "$(date +%s)"
  wset @claude_state exited          # last: a reader that sees it sees the rest
  python3 "$BIN/fleet-session-page.py" --rc "$rc" --agent "$agent" --sid "$sid" --title "$(opt window_name)"
  act=$?
  # Back from the page: a relaunch is a fresh turn as far as the list knows.
  wset -u @wrap_exit_rc
  case "$act" in
    10)  # ↵ — the same conversation
      cmd=(--agent "$agent" ${policy[@]+"${policy[@]}"})
      if [ "$agent" = codex ]; then
        if [ -n "$sid" ]; then cmd+=(resume "$sid"); else cmd+=(resume --last); fi
      else
        if [ -n "$sid" ]; then cmd+=(--resume "$sid"); else cmd+=(--continue); fi
      fi ;;
    11)  cmd=(--agent "$agent" ${policy[@]+"${policy[@]}"}) ;;   # r — a new conversation
    12)  # q — recycle: the SessionEnd hook's reap + close, asked for on purpose
      wset @claude_state "done"
      bash "$BIN/session-end-hook.sh" --recycle
      exit 0 ;;
    *)   exit "$rc" ;;                          # the page died (hangup): nothing to resume into
  esac
  wset @claude_state ''
  wset @claude_state_ts "$(date +%s)"
done
