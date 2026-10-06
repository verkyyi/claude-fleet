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
#     the window's @wrap_quiet before they type /exit — and a FIRST launch that
#     ends within FLEET_WRAP_FAST_FAIL seconds (default 5): it returns the
#     agent's exit status, exactly as the bare launcher did, so every caller's
#     `; exec $SHELL` / `|| fallback` / @restore_exit stamp still works.
#   • outside tmux: a transparent pass-through.
#
# Never lose work, never close on a hiccup (issue #1842):
#   • a relaunch from the page (↵ / r) that dies within the fast-fail window — the
#     conversation is gone, the login lapsed — comes BACK to the page, which says
#     what failed and why (read off the pane: 找不到这个对话 / 认证失效); only the
#     first launch keeps the caller's fast-fail exit.
#   • the page itself failing (python missing, a crash) falls to a plain prompt
#     with the same three keys, never an exit.
#   • commits on the worktree's branch that are on no remote are counted on the
#     page (「未推送：N 个提交（分支 issue-N）」); q keeps them (fleet_reap_ok).
#   • Codex with no recorded id never `resume --last` — in a shared Codex home
#     that is the latest conversation of ANY session. ↵ resumes the window's own
#     thread (@codex_thread_id, which /loop binds) or starts a new one. The last
#     id this wrapper saw is remembered too: fleet-codex.sh clears
#     @codex_session_id at launch, so a resume that failed must not forget it.
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

# Ctrl+Z never freezes a session (issue #1843). The pane's process group is
# orphaned — its leader, the pane's shell, is a session leader whose parent is
# the tmux server — so the kernel discards a SIGTSTP and nothing ever stops. But
# Claude Code and Codex suspend THEMSELVES on Ctrl+Z: tear the UI down, arm a
# SIGCONT handler, `kill(0, SIGTSTP)` — and wait for an `fg` no shell here will
# ever type: alive, silent, deaf to keys. This guard sits in the same process
# group and catches that very SIGTSTP (a handler runs where a default stop is
# discarded; `wait` returns at once on a trapped signal), then SIGCONTs the whole
# group: the agent's own handler redraws it. One log line, and the clients looking
# at this pane are told. It dies with the wrapper (EXIT below, or its next look).
WRAP=$$
if [ "$intmux" = 1 ]; then
  (
    trap '' INT QUIT TTIN TTOU HUP
    log="$BIN/../logs/session-ctrl-z.log"
    ctrl_z() {
      kill -CONT 0 2>/dev/null
      wset @wrap_ctrl_z "$(date +%s)"
      [ -d "${log%/*}" ] && printf '%s pane=%s wrap=%s window=%s SIGTSTP → SIGCONT\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TMUX_PANE" "$WRAP" "$(opt window_name)" >> "$log" 2>/dev/null
      local msg='执行会话里 Ctrl+Z 不起作用' c p
      [ "${FLEET_UI_LANG:-}" = en ] && msg='Ctrl+Z does nothing in a fleet session'
      tmux list-clients -F '#{client_name}	#{pane_id}' 2>/dev/null | while IFS='	' read -r c p; do
        [ "$p" = "$TMUX_PANE" ] && tmux display-message -c "$c" -d 3000 "$msg" 2>/dev/null
      done
    }
    trap ctrl_z TSTP
    while kill -0 "$WRAP" 2>/dev/null; do sleep 5 & wait $!; done
  ) </dev/null >/dev/null 2>&1 &
  NOSTOP=$!
  trap 'kill "$NOSTOP" 2>/dev/null' EXIT
fi

# Why a relaunch died at once, read off what it left on the pane: conversation |
# auth | '' — and its last line, for the page's detail row.
fail_why=''; fail_line=''
read_failure() {
  local txt esc
  esc=$(printf '\033')
  txt=$(tmux capture-pane -p -t "$TMUX_PANE" -S -40 2>/dev/null | sed "s/$esc\[[0-9;?]*[A-Za-z]//g" | grep -v '^[[:space:]]*$')
  fail_line=$(printf '%s\n' "$txt" | tail -n 1 | cut -c1-200)
  fail_why=''
  if printf '%s' "$txt" | grep -qiE 'no conversation|conversation .*not found|session .*not found|no (saved )?session|could not find|no such (session|thread)|找不到'; then
    fail_why=conversation
  elif printf '%s' "$txt" | grep -qiE 'auth|log ?in|unauthori[sz]ed|401|403|credential|api key|expired'; then
    fail_why=auth
  fi
}

# The page could not run: the same three keys on a plain prompt (10/11/12), so a
# broken page never closes the window. 1 = the pane's input is gone.
plain_page() {
  local k
  if [ "${FLEET_UI_LANG:-zh}" = en ]; then
    printf '\nThe session exited (code %s). This window stays open.\nEnter resume   r new   q recycle\n' "$1"
  else
    printf '\n会话已退出（退出码 %s）。这个窗口不会关。\n↵ 接着原对话   r 新开   q 回收这个窗口\n' "$1"
  fi
  while IFS= read -rsn1 k; do
    case "$k" in '') return 10 ;; r|R) return 11 ;; q|Q) return 12 ;; esac
  done
  return 1
}

cmd=("$@")
first=1; last=''; last_sid=''; last_agent=''
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
  # A relaunch from the page that dies as fast is a lost conversation or a lapsed
  # login, not a caller's failure path: back to the page, saying why (#1842).
  dur=$(( $(date +%s) - t0 ))
  failed=''
  if [ "$dur" -lt "$FAST" ]; then
    tmux set-option -p -t "$TMUX_PANE" @wrap_last_rc "$rc" 2>/dev/null
    [ "$first" = 1 ] && exit "$rc"
    failed=$last; read_failure
  fi
  first=0

  agent=$(opt @cc_agent); [ "$agent" = codex ] || agent=claude
  if [ "$agent" = codex ]; then sid=$(opt @codex_session_id); else sid=$(opt @cc_session_id); fi
  # The launcher may have cleared the id before it died (fleet-codex.sh does at
  # launch): keep the last one this window had.
  if [ -n "$sid" ]; then last_sid=$sid; last_agent=$agent
  elif [ "$agent" = "$last_agent" ]; then sid=$last_sid; fi
  # Codex with no id: the window's own thread, never the home's latest (#1842 ④).
  [ "$agent" = codex ] && [ -z "$sid" ] && sid=$(opt @codex_thread_id)
  # Commits on no remote, so the page can say they are still here (#1842 ①).
  unp=0; br=''
  wtd=$(opt @worktree); [ -n "$wtd" ] && [ -d "$wtd" ] || wtd=$PWD
  if [ -n "$(git -C "$wtd" remote 2>/dev/null)" ]; then
    unp=$(git -C "$wtd" rev-list --count HEAD --not --remotes 2>/dev/null) || unp=0
    br=$(git -C "$wtd" symbolic-ref -q --short HEAD 2>/dev/null)
  fi
  case "$unp" in ''|*[!0-9]*) unp=0 ;; esac
  wset @wrap_exit_rc "$rc"
  wset @claude_needs ''
  wset @claude_state_ts "$(date +%s)"
  wset @claude_state exited          # last: a reader that sees it sees the rest
  pargs=(--rc "$rc" --agent "$agent" --sid "$sid" --title "$(opt window_name)")
  [ "$unp" -gt 0 ] && pargs+=(--unpushed "$unp" --branch "$br")
  [ -n "$failed" ] && pargs+=(--failed "$failed" --why "$fail_why" --detail "$fail_line" --secs "$dur")
  python3 "$BIN/fleet-session-page.py" ${pargs[@]+"${pargs[@]}"}
  act=$?
  case "$act" in 10|11|12) ;; *) plain_page "$rc"; act=$? ;; esac
  # Back from the page: a relaunch is a fresh turn as far as the list knows.
  wset -u @wrap_exit_rc
  case "$act" in
    10)  # ↵ — the same conversation; a Codex window with none starts a new one
      last=resume
      cmd=(--agent "$agent" ${policy[@]+"${policy[@]}"})
      if [ "$agent" = codex ]; then
        if [ -n "$sid" ]; then cmd+=(resume "$sid"); else last=new; fi
      else
        if [ -n "$sid" ]; then cmd+=(--resume "$sid"); else cmd+=(--continue); fi
      fi ;;
    11)  last=new; cmd=(--agent "$agent" ${policy[@]+"${policy[@]}"}) ;;   # r — a new conversation
    12)  # q — recycle: the SessionEnd hook's reap + close, asked for on purpose
      wset @claude_state "done"
      bash "$BIN/session-end-hook.sh" --recycle
      exit 0 ;;
    *)   exit "$rc" ;;                          # the pane's input is gone: nothing to resume into
  esac
  wset @claude_state ''
  wset @claude_state_ts "$(date +%s)"
done
