#!/bin/bash
# fleet-start-backfill.sh <sess> <window_id> <owner/name> <title-file> <body-file> [<op-id>]
# — 手续后补 (issues #2234 / #2235, EPIC #2230 C4 → C5): the paperwork of a start
# that was answered from the warm pool. The session is already working on the
# person's words; this files its issue, binds the window to it in place and tells
# the agent — never in the middle of a turn (EPIC #2230 共同约定 6):
#
#   1. FILE — fleet-issue-file.sh (title = the first line, body = the whole text),
#      tried FLEET_BACKFILL_TRIES times (3), FLEET_BACKFILL_RETRY_SECS apart. A
#      filing that never succeeds leaves the session running and marks its window
#      `@backfill failed` (the sidebar's 「单子没建上」); nothing else changes.
#   2. BIND — fleet-bind.sh <N> --fresh, the one road a scratch becomes a worker
#      by: the `scratch-K` branch renamed `issue-N`, @issue/@repo stamped, @raw
#      dropped (so fleet_win_for_key issue-N answers it), the claim written, the
#      children's @origin healed — @fleet_id untouched. --fresh: the issue is
#      seconds old, so the duplicate-claim reads (gh issue view / pr list) are
#      skipped. Tried the same number of times; never re-files.
#   3. TELL — one message through fleet-peer-send.sh to that window: the issue,
#      the branch, finish by /fleet-claim's rules. It lands on the agent's NEXT
#      turn (queued while it is mid-turn; the fleet's peer queue when its inbox
#      cannot take it yet).
#   4. TIME — `t_filed` / `t_bound` (epoch ms) on the window (@t_filed / @t_bound)
#      and, with <op-id>, on the start's operation (fleet_control.py stamp — the
#      operation's result may still be being written, so it is retried briefly).
#
# Run DETACHED by fleet-control-read.sh `start … new` once the first turn is in,
# never on the start's clock. fleet-bind.sh acts on the CALLING pane, so it runs
# here as that window's pane: TMUX = this fleet's socket, TMUX_PANE = its pane.
# A HOME session files nothing (no repo — the caller never runs this for one).
# The two files are this script's own and removed whatever happens; every outcome
# is one line in $FLEET_CONF_DIR/control/backfill.log.
#
# Exit: 0 bound · 1 the window is gone, or filing / binding failed every try ·
# 2 usage.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
sess="${1:-}" win="${2:-}" repo="${3:-}" titlef="${4:-}" bodyf="${5:-}" op="${6:-}"
trap 'rm -f "$titlef" "$bodyf"' EXIT
log() {
  local d="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/control"
  mkdir -p "$d" 2>/dev/null
  printf '%s %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sess" "$win" "$*" >> "$d/backfill.log" 2>/dev/null
}
case "$win" in @[0-9]*) ;; *) log "refused: no window"; exit 2 ;; esac
[ -n "$sess" ] && [ -n "$repo" ] && [ -f "$titlef" ] || { log "refused: usage"; exit 2; }
case "$op" in *[!0-9a-f-]*) op='' ;; esac
title=$(cat "$titlef"); body=''
[ -f "$bodyf" ] && body=$(cat "$bodyf")
tries="${FLEET_BACKFILL_TRIES:-3}";      case "$tries" in ''|*[!0-9]*|0) tries=3 ;; esac
gap="${FLEET_BACKFILL_RETRY_SECS:-10}";  case "$gap" in ''|*[!0-9]*) gap=10 ;; esac
sock=$(fleet_socket "$sess")
sp=$(tmux -L "$sock" display-message -p '#{socket_path}' 2>/dev/null)
nt() { tmux -L "$sock" "$@" 2>/dev/null; }
pane=$(nt display-message -p -t "$win" '#{pane_id}')
case "$pane" in %[0-9]*) ;; *) log "refused: $win is gone"; exit 1 ;; esac
ms() { python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || printf '%s000\n' "$(date +%s)"; }
# As the window's own pane: the filer / binder read their seat from it.
as_pane() { TMUX="$sp,0,0" TMUX_PANE="$pane" FLEET_SESSION="$sess" "$@"; }
# The sidebar's mark (`@backfill`): filing → failed, unset once bound.
mark() {
  if [ -n "${1:-}" ]; then
    nt set-window-option -t "$win" @backfill "$1"
    nt set-window-option -t "$win" @backfill_why "${2:-}"
  else
    nt set-window-option -t "$win" -u @backfill
    nt set-window-option -t "$win" -u @backfill_why
  fi
}
# A window that closed while we waited: nothing left to do it for.
alive() { case "$(nt display-message -p -t "$win" '#{pane_id}')" in "$pane") return 0 ;; esac; return 1; }
stamp_op() {  # <name>=<ms>… — the operation's result may not be written yet
  [ -n "$op" ] || return 0
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    python3 "$BIN/fleet_control.py" stamp "$op" "$@" >/dev/null 2>&1 && return 0
    sleep 2
  done
  log "op $op: could not stamp $*"
}

mark filing
# ---- 1. file ------------------------------------------------------------------
num='' out='' n=0
while [ "$n" -lt "$tries" ]; do
  n=$((n + 1))
  alive || { log "gone before filing (try $n)"; exit 1; }
  out=$(as_pane bash "$BIN/fleet-issue-file.sh" --repo "$repo" --from hub --title "$title" ${body:+--body "$body"} 2>&1)
  rc=$?
  url=$(printf '%s\n' "$out" | grep -Eo 'https://[^[:space:]]+/issues/[0-9]+' | tail -1)
  num="${url##*/}"; num="${num//[^0-9]/}"
  [ "$rc" = 0 ] && [ -n "$num" ] && break
  num=''
  log "file try $n/$tries rc=$rc $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
  [ "$n" -lt "$tries" ] && sleep "$gap"
done
if [ -z "$num" ]; then
  mark failed "file: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"
  log "failed: the issue was not filed after $tries tries — the session keeps working"
  exit 1
fi
t_filed=$(ms)
nt set-window-option -t "$win" @t_filed "$t_filed"
log "filed #$num ($url)"

# ---- 2. bind ------------------------------------------------------------------
n=0 bound=0
while [ "$n" -lt "$tries" ]; do
  n=$((n + 1))
  alive || { log "gone before binding #$num (try $n) — it is on the backlog"; exit 1; }
  out=$(as_pane bash "$BIN/fleet-bind.sh" "$num" --title "$title" --fresh 2>&1); rc=$?
  [ "$rc" = 0 ] && { bound=1; break; }
  log "bind try $n/$tries rc=$rc $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
  # 3 = this is not a scratch window any more (already bound, or never one) and
  # 4 = another window holds #N: trying again cannot change either.
  case "$rc" in 3|4) break ;; esac
  [ "$n" -lt "$tries" ] && sleep "$gap"
done
if [ "$bound" != 1 ]; then
  mark failed "bind #$num: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"
  stamp_op "t_filed=$t_filed"
  log "failed: filed #$num but the window was not bound — the session keeps working"
  exit 1
fi
t_bound=$(ms)
nt set-window-option -t "$win" @t_bound "$t_bound"
mark ''
log "bound #$num"

# ---- 3. tell the agent, on its next turn --------------------------------------
note="单子补好了：这是 ${repo}#${num}，分支已改名为 issue-${num}（worktree 不变，接着在这里干）。"
note="${note}按 /fleet-claim 的规矩收尾：运行 /fleet-claim 读单子和规矩，做完开 PR（正文写 Closes #${num}），检查全绿后自己合并，再报告。"
pout=$(bash "$BIN/fleet-peer-send.sh" -L "$sock" --expect-issue "$num" "$win" "$note" 2>&1); prc=$?
log "told rc=$prc $(printf '%s' "$pout" | tr '\n' ' ' | cut -c1-160)"

# ---- 4. the clock -------------------------------------------------------------
stamp_op "t_filed=$t_filed" "t_bound=$t_bound"
exit 0
