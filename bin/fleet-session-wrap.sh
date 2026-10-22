#!/bin/bash
# fleet-session-wrap.sh — the ONE door every fleet session is opened through
# (issue #1784, EPIC #1776 C8). It takes exactly fleet-claude.sh's arguments, runs
# fleet-claude.sh with them, and stays in the pane when the agent exits:
#
#   • the operator's own exit (Ctrl+C twice, Ctrl+D, /exit), a crash, a kill:
#     the window stays, @claude_state becomes `exited` (the list draws ⏏ 已退出)
#     and under the conversation's last screen — kept, as a local `claude` leaves
#     it — comes ONE line (bin/fleet-session-page.py, issue #2743):
#     「会话已结束 · ↵ 重开 · ⌘P 回列表」; the rest goes to logs/session-exit.log:
#       ↵  resume the SAME conversation (@cc_session_id / @codex_session_id)
#       r  start a new one in this window
#       q  recycle the window — the close-on-exit the SessionEnd hook used to do
#          on every exit, now only on purpose (session-end-hook.sh --recycle)
#     after the person's OWN exit (0 / 130, not a relaunch that failed) the line
#     also counts down — 「10 秒后关闭 · 按任意键取消」 (issue #3170) — and at 0
#     does what q does; any key cancels it. FLEET_EXIT_CLOSE_SECS (fleet.conf or
#     the environment, default 10) sets it, 0 = no countdown (the line as before);
#     a crash and a refused / failed launch never count.
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
#   • a personal layer written badly (issue #1862): personal hooks that kept
#     failing in this launch were switched off by fleet-hook-personal.sh (its
#     record, keyed FLEET_WRAP_LAUNCH_ID, is read here for the page and cleared);
#     with a personal layer on this login the page offers p — the same
#     conversation with FLEET_PERSONAL=0 for this window: personal hooks stand
#     down, the composer leaves the layer out.
#   • Codex with no recorded id never `resume --last` — in a shared Codex home
#     that is the latest conversation of ANY session. ↵ resumes the window's own
#     thread (@codex_thread_id, which /loop binds) or starts a new one. The last
#     id this wrapper saw is remembered too: fleet-codex.sh clears
#     @codex_session_id at launch, so a resume that failed must not forget it.
#
# Before this, one stray double Ctrl+C closed the window (the SessionEnd hook's
# kill-window), and on a machine whose last window that was, the tmux server and
# every client's view of the machine went with it (mac-a, 2026-10-05/06).
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
# The install is read-only (issue #4668): Python's bytecode for the fleet's own
# modules goes to this login's CACHE dir, never beside them in bin/ and never in
# the conf dir, which is snapshotted, moved and backed up (issue #4692) — for every
# hook and tool the session runs (the daemons' templates say the same).
if [ -z "${PYTHONPYCACHEPREFIX:-}" ]; then
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then PYTHONPYCACHEPREFIX="$HOME/Library/Caches/claude-fleet/pycache"
  else PYTHONPYCACHEPREFIX="${XDG_CACHE_HOME:-$HOME/.cache}/claude-fleet/pycache"; fi
  export PYTHONPYCACHEPREFIX
fi
# This login's TMPDIR (issue #2442): a session opened from a `sudo -u` half (a
# same-machine fleet-move) has none, and every script it runs would read the dash
# cache from /tmp every login shares. fleet-lib.sh's fleet_user_tmpdir, inline.
if [ -z "${TMPDIR:-}" ] && [ "$(uname -s 2>/dev/null)" = Darwin ]; then
  TMPDIR=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) && [ -d "$TMPDIR" ] && export TMPDIR || unset TMPDIR
fi
# The agent's `tmux` is the fleet's shim (issue #1841): every shell the session
# opens — the Bash tool, `bash -c`, Codex's, Claude's `!` — finds bin/tmux-shim
# first, and a delete aimed at a fleet's server is refused there. Only the agent
# gets it: the wrapper's own tmux calls (and the recycle) stay on the real one.
SHIM_PATH="$PATH"
[ -x "$BIN/tmux-shim/tmux" ] && case ":$PATH:" in
  *":$BIN/tmux-shim:"*) ;;
  *) SHIM_PATH="$BIN/tmux-shim:$PATH" ;;
esac

# The launch POLICY a resume / new session keeps: its Codex home and the whole
# launch group an older version rendered from a role's definition (issue #2782):
# model, effort, an appended system prompt, tools, permission mode, and the agent file a session started as (`--as`, issue
# #3122 — fleet-claude.sh finds it again). The agent is the one that just ran, @cc_agent. The rest — a seed
# prompt, a --resume + nudge, a --session-id — belonged to the first launch only.
policy=(); want=''
for a in "$@"; do
  if [ -n "$want" ]; then
    case "$want" in
      --agent) ;;
      -c) case "$a" in model_reasoning_effort=*) policy+=("$want" "$a") ;; esac ;;
      *) policy+=("$want" "$a") ;;
    esac
    want=''; continue
  fi
  case "$a" in
    --agent|--codex-home|--model|-m|--effort|-c|--append-system-prompt-file|--permission-mode|--as) want=$a ;;
    --model=*|--effort=*|--append-system-prompt-file=*|--permission-mode=*|--tools=*|--disallowedTools=*|--as=*) policy+=("$a") ;;
  esac
done

intmux=0; [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] && intmux=1
opt()  { tmux display-message -p -t "$TMUX_PANE" "#{$1}" 2>/dev/null; }
# The agent adapter table (T620, EPIC T580 C4) — which option holds a window's
# conversation id, how a resume is spelled — beside this script, else beside its
# link's target (the generated shell copy: no lib, no python, between pane and agent).
_ad="$BIN/fleet-agent-adapter.sh"
[ -f "$_ad" ] || { [ -L "$0" ] && _ad="$(cd "$(dirname "$0")" && cd "$(dirname "$(readlink "$0")")" && pwd)/fleet-agent-adapter.sh"; }
# shellcheck source=fleet-agent-adapter.sh
. "$_ad"; unset _ad
wset() { tmux set-option -w -t "$TMUX_PANE" "$@" 2>/dev/null; }
# C1: only a running wrapper with this holding page is eligible for parking.
if [ "$intmux" = 1 ]; then
  wset @park_wrap_ver 3
  [ -n "$(opt @park_presence)" ] || wset @park_presence 0
fi

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
    log="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/logs/session-ctrl-z.log"
    ctrl_z() {
      kill -CONT 0 2>/dev/null
      wset @wrap_ctrl_z "$(date +%s)"
      [ -d "${log%/*}" ] && printf '%s pane=%s wrap=%s window=%s SIGTSTP → SIGCONT\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TMUX_PANE" "$WRAP" "$(opt window_name)" >> "$log" 2>/dev/null
      local msg='执行会话里 Ctrl+Z 不起作用' c p
      [ "${FLEET_UI_LANG:-}" = en ] && msg='Ctrl+Z does nothing in a fleet session'
      tmux list-clients -F '#{client_name}	#{pane_id}' 2>/dev/null | while IFS='	' read -r c p; do
        [ "$p" = "$TMUX_PANE" ] && python3 "$BIN/fleet_notice.py" notify info "$msg" --client "$c" \
          --source session </dev/null >/dev/null 2>&1
      done
    }
    trap ctrl_z TSTP
    # A trapped TSTP ends the `wait` at once whatever the sleep, so the sleep only
    # paces noticing a wrapper that died without its EXIT trap: a minute, not 5 s —
    # two forks a minute a session, not 24 (issue #4261). The EXIT trap's TERM takes
    # the pending sleep with it, never an orphan left counting down.
    _zs=''
    trap '[ -n "$_zs" ] && kill "$_zs" 2>/dev/null; exit 0' TERM
    while kill -0 "$WRAP" 2>/dev/null; do sleep 60 & _zs=$!; wait "$_zs"; done
  ) </dev/null >/dev/null 2>&1 &
  NOSTOP=$!
  # Out of the job table: bash 3.2 prints a killed job's "Terminated ( … )"
  # notice onto the pane when the EXIT trap runs anything after the kill, and
  # the sleep page then reads that as what the launcher said (issue #2495).
  disown "$NOSTOP" 2>/dev/null
  trap 'kill "$NOSTOP" 2>/dev/null' EXIT
fi
# Whatever the pane runs after this wrapper is gone — the caller's `exec $SHELL`,
# a fallback — is no agent (issue #2404): stamp it, so the session caps
# (fleet_window_has_agent) stop counting the window. The next wrapper clears it.
if [ "$intmux" = 1 ]; then
  trap 'kill "${NOSTOP:-}" 2>/dev/null; tmux set-option -p -t "$TMUX_PANE" @wrap_gone 1 2>/dev/null' EXIT
fi

# Why a relaunch died at once, read off what it left on the pane: conversation |
# auth | '' — and its last line, for the page's detail row.
fail_why=''; fail_line=''; fail_told=''
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

# A session that did not come up — or, bound to a task record, an agent that went
# down — is SAID, never left for a reader to guess (T642). Not started: one line in
# logs/start-fail.log whatever the window; on a window bound to a record (@task)
# also the progress word 「未起来：<why>」 on its ID (fleet_id.py start-word, mirrored
# to the hub: the record's read, the EPIC tick and `await` see it — the agent's
# next SessionStart answers 「起来了」), and when that word is new — once a cause —
# a child report to whoever dispatched it; a window with an issue and no record
# tells its parent as #4702 did. Dropped (a record's agent exited, the window on
# the page): the word 「已掉」 on its ID only. In the background: the page, or the
# caller's shell, never waits on it.
# A test's process never writes the login's real logs (T909): a selftest run by hand
# has no conf of its own, so its windows would land in the operator's
# session-exit.log / start-fail.log — fleet_notice.py's one rule says (rc 3 = no).
book_ok() {  # <log path>
  python3 "$BIN/fleet_notice.py" guard "$1" 2>/dev/null
  [ "$?" != 3 ]
}

say_start() {  # <not_started|dropped> <why, one line> <the parent's summary> [word|force]
  # 4th: word = the record's word and the log line only, no child report (a refusal
  # the page retries by itself — T915); force = the report even when the word is not new
  [ "$intmux" = 1 ] || return 0
  local fid task iss why slog
  fid=$(opt @fleet_id); task=$(opt @task); iss=$(opt @issue)
  case "$task" in T[1-9]*) ;; *) task='' ;; esac
  why=$(printf '%s' "$2" | tr '\n\t' '  ' | cut -c1-240)
  if [ "$1" = not_started ]; then
    slog="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/logs/start-fail.log"
    [ -d "${slog%/*}" ] && book_ok "$slog" && printf '%s window=%s pane=%s id=%s task=%s issue=%s why=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(opt window_name | tr ' ' '_')" "$TMUX_PANE" "${fid:--}" "${task:--}" \
      "${iss:--}" "$why" >> "$slog" 2>/dev/null
  elif [ -z "$task" ]; then
    return 0
  fi
  [ -n "$task" ] || [ -n "$iss" ] || return 0
  ( told=''
    if [ -n "$task" ] && [ -n "$fid" ] \
       && [ "$(python3 "$BIN/fleet_id.py" start-word "$fid" --word "$1" --why "$why" 2>/dev/null)" = WRITTEN ]; then
      told=1
    fi
    [ "$1" = not_started ] || exit 0
    [ "${4:-}" = word ] && exit 0
    [ "${4:-}" = force ] || [ -n "$told" ] || { [ -z "$task" ] && [ -n "$iss" ]; } || exit 0
    bash "$BIN/fleet-report-parent.sh" --state failed --win "$TMUX_PANE" --summary "$3" ) </dev/null >/dev/null 2>&1 &
  disown "$!" 2>/dev/null
  return 0
}

# The page could not run: the same one line and keys on a plain prompt (10/11/12),
# so a broken page never closes the window. 1 = the pane's input is gone. With
# $close_n > 0 it counts down like the page (issue #3170): 14 at 0, any key cancels.
plain_line() {  # <seconds left, 0 = no countdown>
  local c=''
  if [ "${FLEET_UI_LANG:-zh}" = en ]; then
    [ "$1" -gt 0 ] && c="closing in ${1}s · any key cancels · "
    printf '\r\033[KSession ended · %sEnter reopen · ⌘P list   r new chat · q close window' "$c"
  else
    [ "$1" -gt 0 ] && c="${1} 秒后关闭 · 按任意键取消 · "
    printf '\r\033[K会话已结束 · %s↵ 重开 · ⌘P 回列表   r 新对话 · q 关窗口' "$c"
  fi
}
plain_page() {
  local k n=${close_n:-0} r t
  printf '\n'; plain_line "$n"
  while :; do
    if [ "$n" -gt 0 ]; then
      t=$SECONDS; IFS= read -rsn1 -t 1 k; r=$?
      # a second went by, no key: bash 4+ says >128, 3.2 says 1 — as an EOF does,
      # which returns at once, so the clock tells them apart
      if [ "$r" -gt 128 ] || { [ "$r" != 0 ] && [ "$SECONDS" -gt "$t" ]; }; then
        n=$((n - 1)); [ "$n" -gt 0 ] || return 14
        plain_line "$n"; continue
      fi
      [ "$r" = 0 ] || return 1
      n=0; plain_line 0                   # any key cancels — and still does what it says
    else
      IFS= read -rsn1 k || return 1
    fi
    case "$k" in '') return 10 ;; r|R) return 11 ;; q|Q) return 12 ;; p|P) [ "$pers" = on ] && return 13 ;; esac
  done
}

# How long the line waits before it closes the window by itself (issue #3170):
# FLEET_EXIT_CLOSE_SECS from the environment, else the machine's fleet.conf (the
# install's, then the login's — fleet-claude.sh's order), else 10. 0 = never.
close_secs() {
  local v
  if [ -n "${FLEET_EXIT_CLOSE_SECS+x}" ]; then v=$FLEET_EXIT_CLOSE_SECS
  else
    v=$( [ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf" >/dev/null 2>&1
         [ -f "$PCONF/fleet.conf" ] && . "$PCONF/fleet.conf" >/dev/null 2>&1
         printf '%s' "${FLEET_EXIT_CLOSE_SECS-10}" )
  fi
  case "$v" in ''|*[!0-9]*) v=10 ;; esac
  printf '%s' "$v"
}

# How the agent's last own word reads (E101): `transient` — its 7501 report is
# `error` and its words a temporary server error (a 5xx, an overload, a connection
# that broke or never came up); `error` — any other error; nothing — no error.
agent_error() {  # <@agent_status JSON>
  printf '%s' "$1" | python3 -c 'import json, re, sys
try: r = json.load(sys.stdin)
except Exception: sys.exit(0)
if not isinstance(r, dict) or r.get("state") != "error": sys.exit(0)
t = re.search(r"API Error: 5[0-9][0-9]|overloaded|ECONNRESET|ETIMEDOUT|ECONNREFUSED|socket hang up|unreachable|"
              r"timed? ?out|network|connection (?:error|reset|refused)|SSLCertVerification", str(r.get("msg") or ""), re.I)
print("transient" if t else "error")' 2>/dev/null
}

# How long the page waits before its one automatic retry (E101): close_secs's
# road — FLEET_AUTO_RESUME_SECS from the environment, else the machine's
# fleet.conf, else 300. 0 = never by itself.
auto_resume_secs() {
  local v
  if [ -n "${FLEET_AUTO_RESUME_SECS+x}" ]; then v=$FLEET_AUTO_RESUME_SECS
  else
    v=$( [ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf" >/dev/null 2>&1
         [ -f "$PCONF/fleet.conf" ] && . "$PCONF/fleet.conf" >/dev/null 2>&1
         printf '%s' "${FLEET_AUTO_RESUME_SECS-300}" )
  fi
  case "$v" in ''|*[!0-9]*) v=300 ;; esac
  printf '%s' "$v"
}

PCONF="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"

# park_hold — a parked window (task HHV0): the agent's process is gone, the window,
# its ID, its conversation and its credential stay, and every list reads it idle
# (@claude_state done). It waits for a wake — the gate's @park_wake (a seed file the
# wake claims by renaming it, the gate cancelling with the same rename, so exactly
# one side wins: the first sentence rides the start, never twice), or a sentence
# submitted with ↵ here. Switching windows only shows the saved screen. Sets
# park_seed (the first turn's words, may be empty) and park_act (wake | quit).
park_hold() {
  park_act=wake; park_seed=''
  wset @claude_needs ''
  wset @claude_state_src wrapper
  wset @claude_state "done"
  local w page_rc fid draft screen reply
  local page_args=()
  fid=$(opt @fleet_id)
  draft="${FLEET_GATE_DIR:-$PCONF/session-gate}/$fid/park-input.txt"
  screen=$(opt @park_screen)
  [ -n "$screen" ] || screen="${draft%/*}/park-screen.txt"
  [ "$park_failed" = 1 ] || park_new=''
  while :; do
    w=$(opt @park_wake)
    if [ -n "$w" ] && { [ "$park_keyboard" = 1 ] || [ ! -s "$draft" ]; }; then
      if mv "$w" "$w.taken" 2>/dev/null; then
        park_seed=$(cat "$w.taken" 2>/dev/null; printf .)
        park_seed=${park_seed%.}
        if [ -f "$w.meta" ]; then
          # First native 7501 report acknowledges a new gate's owned seed.
          wset @park_start "$w.meta"
          park_attempt="$w.meta"
        else
          # HHV0 callers handed a seed directly, before metadata existed.
          : > "$w.launched" 2>/dev/null
          rm -f "$w.taken" 2>/dev/null
        fi
        wset -u @park_wake
        break
      fi
      wset -u @park_wake
    fi
    page_args=(--screen "$screen" --draft "$draft")
    [ "$park_failed" != 1 ] || page_args+=(--failed)
    FLEET_PARK_ERROR="$(opt @park_error)" python3 "$BIN/fleet-park-page.py" ${page_args[@]+"${page_args[@]}"}
    page_rc=$?
    case "$page_rc" in
      12) continue ;;  # external seed, claimed by the same rename above
      10|11)
        [ "$page_rc" != 11 ] || park_new=1
        reply=$( . "$BIN/fleet-lib.sh"; fleet_park_wake "$fid" --why 键盘 --seed-file "$draft" --request-only )
        case "$reply" in
          *'"ok":true'*) park_keyboard=1; park_failed='' ;;
          *) park_failed=1 ;;
        esac ;;
      1) park_act=quit; break ;;
      *)
        # A broken editor must not turn a sentence into a single-key command.
        printf '\n接回页面不可用 · 输入整句后回车重试 / Resume page unavailable · type then Enter: '
        wset @park_held "$(date +%s)"
        IFS= read -r park_seed || { park_act=quit; break; }
        mkdir -p "${draft%/*}"
        ( umask 077; printf '%s' "$park_seed" > "$draft" )
        reply=$( . "$BIN/fleet-lib.sh"; fleet_park_wake "$fid" --why 键盘 --seed-file "$draft" --request-only )
        case "$reply" in *'"ok":true'*) park_keyboard=1 ;; *) park_failed=1 ;; esac ;;
    esac
  done
  wset -u @parked; wset -u @park_since; wset -u @park_why; wset -u @park_held
}
cmd=("$@")
first=1; last=''; last_sid=''; last_agent=''
# The conversation this wrapper was opened to resume (issue #4728) is the last id
# it saw, before any launch stamps one: a resume that dies before its first hook
# (fleet-codex.sh clears the window's ids at launch) comes back on ↵ as itself.
_pv=''; _ag=claude
for a in "$@"; do
  case "$_pv" in
    --agent) _ag=$a ;;
    resume|--resume)
      if printf '%s' "$a" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
        last_sid=$a; last_agent=$_ag
      fi ;;
  esac
  _pv=$a
done
unset _pv _ag
park_sid=''    # a parked session's credential sid, kept for its wake (task HHV0)
park_keyboard=''; park_attempt=''; park_failed=''; park_new=''
park_seed=''   # the first sentence a wake carries into the resumed conversation
# C3: restore brings back the holding wrapper without starting the native engine
# ahead of its deadline. The disk contract is bound to both fid and conversation.
if [ "$intmux" = 1 ] && [ -n "${FLEET_PARK_RESTORE_FID:-}" ] \
   && python3 "$BIN/fleet_park_wake.py" restore --fid "$FLEET_PARK_RESTORE_FID" --sid "$last_sid"; then
  wset @fleet_id "$FLEET_PARK_RESTORE_FID"
  wset @loop "park=$FLEET_PARK_RESTORE_FID"
  wset "$(fleet_agent_get "${last_agent:-claude}" sid_window)" "$last_sid"
  wset @parked "$(date +%s)"
  park_hold
  [ "$park_act" = quit ] && exit 0
fi
unset FLEET_PARK_RESTORE_FID
cred_tries=0   # refused launches in a row for want of a session credential (#4112)
cred_since=0   # when that streak began (T915: its child report waits FLEET_CRED_REPORT_SECS)
while :; do
  if [ "$intmux" = 1 ]; then
    wset -u @wrap_quiet
    tmux set-option -p -t "$TMUX_PANE" @session_wrap "$$" 2>/dev/null
    tmux set-option -pu -t "$TMUX_PANE" @wrap_gone 2>/dev/null
    tmux set-option -pu -t "$TMUX_PANE" @launch_refused 2>/dev/null
    # The window this agent's identity lives on (issue #1844): when the pane is
    # broken out (prefix !), fleet-window-carry.sh sees it arrive elsewhere and
    # moves the identity after it.
    tmux set-option -p -t "$TMUX_PANE" @wrap_win "$(opt window_id)" 2>/dev/null
  fi
  export FLEET_SESSION_WRAP=$$
  # The session's own credential (issue #1809, docs/dev/FLEET-MCP.md «Identity»): minted
  # fresh for every launch, handed to the agent — and so to the fleet tool service —
  # through the environment ONLY (never argv, a file or a log), revoked when the
  # agent exits. No tool service (FLEET_MCP=0), outside tmux, or a mint that fails:
  # none — the tools then know the session by its window's options, as before.
  # A parked credential stays only in this wrapper's environment. Expired ones
  # remint before the resumed MCP mounts; initial launches never inherit a peer.
  if [ "$first" = 1 ] || ! python3 "$BIN/fleet-mcp.py" --cred check >/dev/null 2>&1; then
    unset FLEET_WORKER_CRED
  fi
  if [ -z "${FLEET_WORKER_CRED:-}" ] && [ "$intmux" = 1 ] && [ "${FLEET_MCP:-1}" != 0 ] && [ -f "$BIN/fleet-mcp.py" ]; then
    FLEET_WORKER_CRED=$(python3 "$BIN/fleet-mcp.py" --cred mint 2>/dev/null) && [ -n "$FLEET_WORKER_CRED" ] \
      && export FLEET_WORKER_CRED || unset FLEET_WORKER_CRED
  fi
  t0=$(date +%s)
  export FLEET_WRAP_LAUNCH_ID="$$-$t0"     # the session a personal hook's strikes count in (#1862)
  # The session's SUBSCRIPTION credential goes through this login's proxy (issue
  # #1972, EPIC #1967 C5): with FLEET_CRED_PROXY=1 every launch gets its own
  # FLEET_CRED_SID, the launcher (fleet-claude.sh / fleet-codex.sh) has the proxy
  # mint a session credential for it — an fcp1. bound to the picked account, or on
  # an untrusted machine an fcp-h1. pass from the hub — and it is revoked here when
  # the agent exits. `fleet-account.sh migrate` then rebinds the sid: no closed
  # window. Switched off: nothing is set — the launch is what it always was.
  unset FLEET_CRED_SID
  if [ -n "$park_sid" ]; then
    # a parked session's wake (task HHV0): the credential it parked with was
    # never revoked — the same sid, the same binding at the proxy
    export FLEET_CRED_SID=$park_sid; park_sid=''
    [ "$intmux" = 1 ] && wset @cred_sid "$FLEET_CRED_SID"
  elif [ -f "$BIN/fleet-session-cred.sh" ] && bash "$BIN/fleet-session-cred.sh" on 2>/dev/null; then
    export FLEET_CRED_SID="w-$$-$t0"
    [ "$intmux" = 1 ] && wset @cred_sid "$FLEET_CRED_SID"
  fi
  # A new agent says its own state afresh (issue #2537, EPIC #2535 C2): the last
  # one's OSC 7501 report — a resume, a cfg-restart, a migrated window's first
  # launch — must not hold the hooks off for two minutes, nor make a carried
  # state look like the new agent's word. Cleared before every launch — and so is
  # the last one's working directory (@agent_cwd, issue #3183): a new agent starts
  # where it is launched.
  [ "$intmux" = 1 ] && { wset -u @agent_status; wset -u @agent_status_ts; wset -u @agent_cwd; }
  # The new session's clock (T716) is its FIRST agent's: a relaunch here (a
  # resume off the recovery page, a cfg-restart) is not that start's 能打字. The
  # first launch carries the ↵ to its launcher (FLEET_TIMING_T0, unset before the
  # agent runs) and writes `wrap` — its launcher about to run, inline (no lib here).
  unset FLEET_TIMING_T0 FLEET_TIMING_WHAT
  if [ "$intmux" = 1 ]; then
    _tm=$(tmux display-message -p -t "$TMUX_PANE" '#{@timing_t0}:#{@timing_ready}:#{@timing_what}' 2>/dev/null)
    _t0=${_tm%%:*}; _tw=${_tm##*:}
    case "$_tm" in
      *[0-9]:*[0-9]:*) wset -u @timing_t0; wset -u @timing_ready ;;
      *[0-9]::*) export FLEET_TIMING_T0=$_t0
               [ "$_tw" = session.node ] && export FLEET_TIMING_WHAT=session.node
               _tw=${FLEET_TIMING_WHAT:-session}; _td="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/timing"
               mkdir -p "$_td" 2>/dev/null && perl -MTime::HiRes=time -e 'my ($t0, $w) = @ARGV; my $ms = (time() - $t0) * 1000;
                 printf "{\"ts\": %.3f, \"what\": \"%s\", \"seg\": \"wrap\", \"ms\": %.1f}\n", $t0, $w, $ms if $ms >= 0 && $ms < 3600000' \
                 "$_t0" "$_tw" >> "$_td/$_tw.ndjson" 2>/dev/null ;;
    esac
    unset _tm _t0 _tw _td
  fi
  # A durable task handover that rewrites this HOME's native task table holds
  # every new Claude here until it is settled (issue #4280): the launch gate.
  if [ -f "$PCONF/transfer-durable/launch.gate" ]; then
    launch_agent=claude; prev=''
    for a in ${cmd[@]+"${cmd[@]}"}; do [ "$prev" = --agent ] && launch_agent=$a; prev=$a; done
    [ "$launch_agent" != claude ] || python3 "$BIN/fleet_transfer_durable.py" gate-wait "$PWD" || :
  fi
  if [ "$intmux" = 1 ]; then
    # A window stamped @launch before the ID switch reopens as itself (EPIC T497
    # C8): the launch proof is retired, its options come off, its ID stays.
    if [ -n "$(opt @launch)" ]; then
      for o in @launch @launch_receipt @launch_seed @launch_started @launch_error @launch_hook_error; do wset -u "$o"; done
    fi
    # The launcher as it is, without the environment a retired layer (EPIC T497
    # C8) may have handed a session started before it — fleet_repo_authority.py's
    # --supervise did this with a Python start (T716: env -u, no start).
    wake_guard=()
    [ -z "$park_attempt" ] || wake_guard=(python3 "$BIN/fleet_wake_guard.py" run --meta "$park_attempt" --)
    PATH="$SHIM_PATH" ${wake_guard[@]+"${wake_guard[@]}"} env -u FLEET_LAUNCH -u FLEET_LAUNCH_CONTEXT -u FLEET_LAUNCH_SUPERVISOR -u FLEET_LAUNCH_NATIVE \
      -u FLEET_LAUNCH_WORKTREE -u FLEET_LAUNCH_CREATE -u FLEET_LAUNCH_DELIVERY -u FLEET_AUTHORITY_CONTEXT \
      -u FLEET_AUTHORITY_ADMISSION -u FLEET_AUTHORITY_START -u FLEET_AUTHORITY_EXPECTED \
      -u FLEET_AUTHORITY_RESUME_SID -u FLEET_ID_DISPATCH "$LAUNCH" ${cmd[@]+"${cmd[@]}"} ${park_seed:+"$park_seed"}
  else
    PATH="$SHIM_PATH" "$LAUNCH" ${cmd[@]+"${cmd[@]}"}
  fi
  rc=$?
  # A keyboard wake owns its words until a native report claims the metadata.
  # A launcher exiting before that confirmation returns to the parked editor.
  if [ -n "$park_attempt" ] && python3 "$BIN/fleet-park-page.py" --fail-meta "$park_attempt"; then
    park_failed=1
  else
    park_failed=''
  fi
  park_attempt=''; park_keyboard=''; park_seed=''
  unset FLEET_AUTHORITY_START FLEET_AUTHORITY_EXPECTED FLEET_AUTHORITY_RESUME_SID  # retired (C8): an old spawner's never rides a resume
  # Parked (task HHV0, bin/fleet_session_gate.py park): the gate stamped @parked
  # before it asked the agent to /exit. The session credential is NOT revoked —
  # minting one again is the slow part of a start — and the window waits below.
  parked=''
  [ "$intmux" = 1 ] && [ -n "$(opt @parked)" ] && parked=1
  [ -n "$parked" ] && [ -n "${FLEET_CRED_SID:-}" ] && park_sid=$FLEET_CRED_SID
  if [ -n "${FLEET_WORKER_CRED:-}" ] && [ -z "$parked" ]; then
    python3 "$BIN/fleet-mcp.py" --cred revoke >/dev/null 2>&1
    unset FLEET_WORKER_CRED
  fi
  if [ -n "${FLEET_CRED_SID:-}" ] && [ -z "$parked" ]; then
    bash "$BIN/fleet-session-cred.sh" revoke --sid "$FLEET_CRED_SID" >/dev/null 2>&1
    [ "$intmux" = 1 ] && { wset -u @cred_sid; wset -u @cred_route; }
    unset FLEET_CRED_SID
  fi
  [ "$intmux" = 1 ] || exit "$rc"
  # The fleet made it exit (it stamped @wrap_quiet).
  if [ "$(opt @wrap_quiet)" = 1 ]; then wset -u @wrap_quiet; exit "$rc"; fi
  # Parked: the window holds the same conversation until a wake, and looks idle.
  if [ -n "$parked" ]; then
    while :; do
      park_hold
      [ "$park_act" != quit ] || exit "$rc"
      first=0; last=resume
      agent=$(fleet_agent_or_default "$(opt @cc_agent)")
      sid=$(fleet_agent_session_id "$agent" opt window)
      [ -n "$sid" ] || sid=$last_sid
      cmd=(--agent "$agent" ${policy[@]+"${policy[@]}"})
      if [ "$park_new" = 1 ]; then break; fi
      if [ -n "$sid" ]; then
        last_sid=$sid; last_agent=$agent
        cmd+=("$(fleet_agent_get "$agent" resume_flag)" "$sid")
        break
      fi
      # Never fall back to another window's latest conversation. The same
      # recovery page retains the words and offers an explicit new conversation.
      python3 "$BIN/fleet-park-page.py" --fail-meta "$park_attempt" || :
      park_failed=1
    done
    wset @id_next_trigger "reopen:$(date +%s)"
    wset @claude_state ''
    wset @claude_state_ts "$(date +%s)"
    continue
  fi
  # Handed to WebChat (task T810, fleet-webchat-handoff.sh): the conversation goes on
  # there — the page says so and ↵ takes it back once WebChat is not answering.
  handed=$(opt @handoff_web)
  # A launch that never came up (claude missing, a refused resume, a one-shot
  # `--version`): the caller's own failure path decides, as it always did.
  # Its rc stays on the pane too: tmux ≤3.4 can leave #{pane_dead_status} empty
  # when it misses the SIGCHLD (#1801), and fleet-transfer's rollback names it.
  # A relaunch from the page that dies as fast is a lost conversation or a lapsed
  # login, not a caller's failure path: back to the page, saying why (#1842).
  # The LAUNCHER refusing to start the agent at all (issue #2404: no session
  # credential from the proxy, a pinned subscription gone) stamps @launch_refused
  # first: no fallback of the caller's can do better — a new session would be
  # refused the same — so even a first launch stops on the page, saying why, and
  # ↵ retries the very same launch. Before this the window fell to a bare shell
  # and held a session slot with nothing in it.
  dur=$(( $(date +%s) - t0 ))
  failed=''; refused=$(tmux show-options -pqv -t "$TMUX_PANE" @launch_refused 2>/dev/null)
  if [ -n "$refused" ]; then
    tmux set-option -p -t "$TMUX_PANE" @wrap_last_rc "$rc" 2>/dev/null
    failed=launch; read_failure; fail_why=$refused
  elif [ "$dur" -lt "$FAST" ]; then
    tmux set-option -p -t "$TMUX_PANE" @wrap_last_rc "$rc" 2>/dev/null
    if [ "$first" = 1 ]; then
      # the caller's own failure path decides (its `exec $SHELL`) — and the
      # session that never came up is said first (T642: C1 / R8 sat as bare shells)
      read_failure
      say_start not_started "启动 ${dur} 秒就退出（rc ${rc}）${fail_line:+：$fail_line}" \
        "the session did not start: the agent exited ${dur}s into its first launch (rc $rc)${fail_line:+ — $(printf '%s' "$fail_line" | cut -c1-160)}; its window fell back to a bare shell — start it again on its record (fleet-task-record.sh respawn) or reap it"
      exit "$rc"
    fi
    failed=$last; read_failure
  fi
  retry=$first; first=0

  agent=$(fleet_agent_or_default "$(opt @cc_agent)")
  # The window's conversation id: the table's one reader (T629, C5).
  sid=$(fleet_agent_session_id "$agent" opt window)
  # The launcher may have cleared the id before it died (fleet-codex.sh does at
  # launch): keep the last one this window had.
  if [ -n "$sid" ]; then last_sid=$sid; last_agent=$agent
  elif [ "$agent" = "$last_agent" ]; then sid=$last_sid; fi
  # A resume that never reached its first hook (a review page, a fast death) still
  # names the thread it was opened for (the table's sid_pending — @codex_pending,
  # issue #4728): ↵ resumes THAT, never a new conversation in its place; with no id
  # at all, the window's own thread (sid_thread), never the home's latest (#1842 ④).
  [ -n "$sid" ] || sid=$(fleet_agent_session_id "$agent" opt fallback)
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
  wset @claude_state_src wrapper
  wset @claude_state exited          # last: a reader that sees it sees the rest
  pargs=(--rc "$rc" --agent "$agent" --sid "$sid" --title "$(opt window_name)")
  [ "$unp" -gt 0 ] && pargs+=(--unpushed "$unp" --branch "$br")
  [ -n "$failed" ] && pargs+=(--failed "$failed" --why "$fail_why" --detail "$fail_line" --secs "$dur")
  [ "$failed" = launch ] && [ "$retry" = 1 ] && pargs+=(--retry)
  # No session credential (issue #4112): the hub / the egress may be a moment
  # behind a pod's restart, so the page presses ↵ by itself — 15 s, doubling to
  # 5 min — instead of holding the window for a person who is not there.
  case "$refused" in
    cred|cred_unknown)
      if [ "$retry" = 1 ]; then
        [ "$cred_tries" = 0 ] && cred_since=$(date +%s)
        cred_tries=$((cred_tries + 1)); rin=15; i=1
        while [ "$i" -lt "$cred_tries" ] && [ "$rin" -lt 300 ]; do rin=$((rin * 2)); i=$((i + 1)); done
        [ "$rin" -gt 300 ] && rin=300
        pargs+=(--retry-in "$rin")
      fi ;;
    *) cred_tries=0; cred_since=0 ;;
  esac
  # The countdown (issue #3170): only the person's own exit — never a crash, a
  # failed relaunch or a refused launch (the page must stay to say why). Every
  # session alike: nothing reopens a role's window any more (issue #4341).
  close_n=0
  aerr=$(agent_error "$(opt @agent_status)")
  case "$rc" in 0|130)
    # an agent its error stopped did not exit on its person's word (E101)
    [ -z "$failed" ] && [ -z "$aerr" ] && close_n=$(close_secs) ;;
  esac
  # A temporary server error (E101: FQBW's 502 sat 16 h on this page): the page
  # presses ↵ by itself once — FLEET_AUTO_RESUME_SECS (300) on, the same
  # conversation in the same window; a second one, or any other error, waits for
  # its person (the list's 等你 · 出错停住). @auto_resume_at is the clock the idle
  # reaper's 「为什么还没收」 counts down to, @auto_resumed the one retry spent.
  auto=''
  if [ "$aerr" = transient ] && [ -z "$failed" ] && [ "$handed" != 1 ] && [ "$(opt @auto_resumed)" != 1 ]; then
    ain=$(auto_resume_secs)
    if [ "$ain" -gt 0 ]; then
      auto=1; pargs+=(--resume-in "$ain")
      wset @auto_resume_at "$(( $(date +%s) + ain ))"
    fi
  fi
  [ "$handed" = 1 ] && close_n=0 && pargs+=(--handed web)
  [ "$close_n" -gt 0 ] && pargs+=(--close-in "$close_n")
  # The personal layer (#1862): absent on this login → nothing passed, the page as before.
  pers=''
  if [ -e "$PCONF/person-bundle.json" ] || [ -e "$PCONF/person-bundle.good.json" ]; then
    pers=on; [ "${FLEET_PERSONAL:-}" = 0 ] && pers=off
    pargs+=(--personal "$pers")
  fi
  hdir="$PCONF/personal-hook-strikes/$FLEET_WRAP_LAUNCH_ID"
  if [ -d "$hdir" ]; then
    hoff=0; hwhat=''
    for f in "$hdir"/*.off; do
      [ -f "$f" ] || continue
      hoff=$((hoff + 1))
      [ -n "$hwhat" ] || hwhat=$(head -n 1 "$f" | cut -f1-2 | tr '\t' ' ' | cut -c1-80)
    done
    [ "$hoff" -gt 0 ] && pargs+=(--hooks-off "$hoff" --hooks-off-what "$hwhat")
    rm -rf "$hdir"
  fi
  # what the line under the conversation no longer says (issue #2743) — the exit
  # status, the id, how long it ran, why a relaunch failed and the agent's last
  # words — is kept here, one line a stop
  xlog="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/logs/session-exit.log"
  [ -d "${xlog%/*}" ] && book_ok "$xlog" && printf '%s window=%s pane=%s agent=%s sid=%s rc=%s secs=%s failed=%s why=%s unpushed=%s detail=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(opt window_name | tr ' ' '_')" "$TMUX_PANE" "$agent" "${sid:--}" "$rc" "$dur" \
    "${failed:--}" "${fail_why:--}" "$unp" "$(printf '%s' "${fail_line:-}" | tr '\n' ' ' | cut -c1-200)" >> "$xlog" 2>/dev/null
  # A worker that did not come up tells whoever spawned it (issue #4702) — once a
  # streak: a refused launch presses ↵ by itself every 15 s–5 min, and a launch
  # that runs again ends the streak. Before this the parent heard nothing and took
  # the silent window for one that had finished.
  # A task record's agent that went down is 「已掉」 on its ID (T642) — the fleet's
  # own exits (@wrap_quiet) returned above, so this is a crash, a kill or a person.
  if [ "$handed" = 1 ]; then
    fail_told=''
  elif [ -z "$failed" ]; then
    fail_told=''
    say_start dropped "agent 退出（rc ${rc}，跑了 ${dur} 秒），窗口停在恢复页" ''
  elif [ -z "$fail_told" ]; then
    # No credential this once (T915): the page presses ↵ by itself and the next
    # launch usually comes up — a FAILED report now would be the parent's answer for
    # a session that went on to finish. The record's word and the log line are
    # written at once; the report waits until the streak is FLEET_CRED_REPORT_SECS
    # (300) old, and then goes even though the word is not new.
    smode=''
    if [ "$cred_tries" -gt 0 ]; then
      cgrace=${FLEET_CRED_REPORT_SECS:-300}; case "$cgrace" in ''|*[!0-9]*) cgrace=300 ;; esac
      if [ $(( $(date +%s) - cred_since )) -lt "$cgrace" ]; then smode=word
      elif [ "$cred_tries" -gt 1 ]; then smode=force; fi
    fi
    [ "$smode" = word ] || fail_told=1
    case "$failed" in launch) _w="启动被拒" ;; *) _w="重开 ${dur} 秒就退出" ;; esac
    say_start not_started "${_w}（${fail_why:-rc $rc}）${fail_line:+：$fail_line}" \
      "the session did not start: ${failed} failed (${fail_why:-rc $rc})${fail_line:+ — $(printf '%s' "$fail_line" | cut -c1-160)}; its window waits on the recovery page — retry it there or reap it" \
      "$smode"
  fi
  hnote=()
  while :; do
    python3 "$BIN/fleet-session-page.py" ${pargs[@]+"${pargs[@]}"} ${hnote[@]+"${hnote[@]}"}
    act=$?
    case "$act" in 10|11|12|13|14) ;; *) plain_page "$rc"; act=$? ;; esac
    # ↵ on a handed page: back to the terminal only while WebChat is not answering
    if [ "$act" = 10 ] && [ "$(opt @handoff_web)" = 1 ]; then
      if hsay=$(bash "$BIN/fleet-webchat-handoff.sh" to-terminal --agent "$agent" --sid "$sid" --fid "$(opt @fleet_id)" 2>&1); then
        wset -u @handoff_web; break
      fi
      hnote=(--note "$(printf '%s' "$hsay" | tail -n 1)")
      continue
    fi
    break
  done
  # 14 — the countdown ran out: what q does, logged as such (issue #3170)
  if [ "$act" = 14 ]; then
    [ -d "${xlog%/*}" ] && book_ok "$xlog" && printf '%s window=%s pane=%s auto-close after=%ss\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(opt window_name | tr ' ' '_')" "$TMUX_PANE" "$close_n" >> "$xlog" 2>/dev/null
    act=12
  fi
  # Back from the page: a relaunch is a fresh turn as far as the list knows.
  wset -u @wrap_exit_rc
  # the one automatic retry (E101) is spent once the page resumed after offering it
  if [ -n "$auto" ]; then
    wset -u @auto_resume_at
    [ "$act" = 10 ] && wset @auto_resumed 1
    [ -d "${xlog%/*}" ] && book_ok "$xlog" && printf '%s window=%s pane=%s auto-resume act=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(opt window_name | tr ' ' '_')" "$TMUX_PANE" "$act" >> "$xlog" 2>/dev/null
  fi
  # p — ↵ without the personal layer, for this window from now on (#1862)
  [ "$act" = 13 ] && { export FLEET_PERSONAL=0; act=10; }
  # ↵ after a refused FIRST launch — the agent never ran: the same launch again.
  if [ "$act" = 10 ] && [ "$failed" = launch ] && [ "$retry" = 1 ]; then
    first=1; wset @claude_state ''; wset @claude_state_ts "$(date +%s)"; continue
  fi
  case "$act" in
    10)  # ↵ — the same conversation; a Codex window with none starts a new one
      last=resume
      # …as a new segment of the same ID (EPIC T644 C2): its SessionStart hook reads
      # `reopen` (fleet_id.py hook_hint) even when the conversation id is the same
      wset @id_next_trigger "reopen:$(date +%s)"
      cmd=(--agent "$agent" ${policy[@]+"${policy[@]}"})
      # the table's spelling: a resume by id; no id ⇒ its continue, or (none) a new one
      _o=$(fleet_agent_get "$agent" continue_flag)
      if [ -n "$sid" ]; then cmd+=("$(fleet_agent_get "$agent" resume_flag)" "$sid")
      elif [ -n "$_o" ]; then cmd+=("$_o")
      else last=new; fi ;;
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
