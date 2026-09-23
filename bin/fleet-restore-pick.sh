#!/bin/bash
# fleet-restore-pick.sh [--session S] — pick a finished session and bring it back
# (issue #901). The hub's ⌃t landed view + ⌃o restore, as ONE popup any window
# can open: the task sidebar's row menu (「恢复已收工…」) and its ⌃o
# (dash-keymap.sh --panel sidebar `restore`) both land here.
#
#   fleet-restore-pick.sh [--session S]          open the picker in a popup
#                                                (dash-popup.sh: client resolved,
#                                                @popup_open raised then cleared,
#                                                inline when no popup can open)
#   fleet-restore-pick.sh --pick [--session S]   the popup's body: fzf over the rows
#   fleet-restore-pick.sh --select <target> [--session S]
#                                                the step after a pick, no fzf —
#                                                the selftest drives this; the
#                                                #543 answer is read from stdin
#
# Nothing here is new logic (EPIC #894 convention 1): the rows are the landed
# view's own (`fleet-history.sh rows`, what tmux-dashboard-rows.sh execs into on
# ⌃t) and a pick hands its `landed:…` target to dash-restore-session.sh, exactly
# as the hub's ⌃o does. The one difference is focus: the operator picked this
# session to work on it, so the restored window becomes current
# (FLEET_SPAWN_FOCUS=1) — the hub's spawn stays non-invasive.
#
# A CLOSED-unmerged PR (#543/#544): fleet-cleanup reaps an issue-<N> window whose
# PR is CLOSED once it has sat silent past FLEET_CLEANUP_CLOSED_GRACE, so a
# restored worker left to think would be killed under the operator. Such a row
# asks first: reopen the PR, restore anyway, or cancel. Only a `landed:issue:<N>`
# row can carry one — a `landed:<pr>` row is a MERGED PR, a scratch has no issue
# head — and only that pick costs a `gh` round-trip.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"

MODE=open; SESS=""; TARGET=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session)   SESS="${2:-}"; [ "$#" -gt 1 ] && shift ;;
    --session=*) SESS="${1#--session=}" ;;
    --pick)      MODE=pick ;;
    --select)    MODE=select; TARGET="${2:-}"; [ "$#" -gt 1 ] && shift ;;
    *) printf 'usage: fleet-restore-pick.sh [--session S] [--pick | --select <target>]\n' >&2; exit 2 ;;
  esac
  shift
done

if [ "$MODE" = open ]; then
  exec bash "$BIN/dash-popup.sh" -w 90% -h 70% -- \
    bash "$BIN/fleet-restore-pick.sh" --pick ${SESS:+--session "$SESS"}
fi

# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
SESS="${SESS:-${FLEET_SESSION:-$(fleet_current_session)}}"
[ -n "$SESS" ] || { printf 'fleet-restore-pick: no fleet session\n' >&2; exit 1; }
fleet_load_conf "$SESS"
export FLEET_SESSION="$SESS"   # fleet-history.sh rows scopes its ledger by it

say() { printf '%s\n' "$*"; }
# One key from the operator. stdin is the popup's terminal (fzf only ever read the
# pipe it was handed), and the selftest's pipe under --select.
ask() { local k=''; printf '%s ' "$1"; IFS= read -r -n1 k || :; printf '\n'; REPLY_KEY="$k"; }

if [ "$MODE" = pick ]; then
  command -v fzf >/dev/null 2>&1 || { say 'restore: fzf is missing'; ask '按任意键关闭'; exit 1; }
  US=$'\x1f'
  rows=$(bash "$BIN/fleet-history.sh" rows 2>/dev/null)
  [ -n "$rows" ] || { say 'restore: no finished sessions recorded'; ask '按任意键关闭'; exit 0; }
  # Field 1 is the restore target, field 2 a stable key, field 3 the drawn row —
  # the landed view's own layout, header line included.
  sel=$(printf '%s\n' "$rows" | fzf --ansi --no-sort --layout=reverse --delimiter="$US" \
    --with-nth=3.. --header-lines=1 --prompt='恢复 ▸ ' \
    --header='↵ 恢复并切过去 · esc 取消 · 子任务折叠在父任务下（hub ⌃t 可展开）' \
    2>/dev/null) || exit 0
  TARGET=${sel%%"$US"*}
fi

case "$TARGET" in
  landed:*) ;;
  *) exit 0 ;;   # the header / the "(no landed sessions…)" filler / nothing picked
esac

# #543: a PR-less issue row whose issue-<N> head has a CLOSED-unmerged PR.
case "$TARGET" in
  landed:issue:*)
    n=${TARGET#landed:issue:}
    repo=$(fleet_repo_cached "$SESS" 2>/dev/null); repo=${repo:-${FLEET_REPO:-}}
    closed=""
    [ -n "$repo" ] && closed=$(gh pr list --repo "$repo" --head "issue-$n" --state all \
      --json number,state --jq 'sort_by(.number) | last | select(.state == "CLOSED") | .number' 2>/dev/null)
    if [ -n "$closed" ]; then
      grace=${FLEET_CLEANUP_CLOSED_GRACE:-900}
      case "$grace" in ''|*[!0-9]*) grace=900 ;; esac
      say "#$n 的 PR #$closed 已关闭（未合并）。"
      say "恢复后它若静默超过 $((grace / 60)) 分钟，清理会把窗口回收（#543/#544）。"
      ask '[y] 先 reopen PR 再恢复 · [r] 直接恢复 · 其它键取消 ›'
      case "$REPLY_KEY" in
        y|Y)
          if ! err=$(gh pr reopen "$closed" --repo "$repo" 2>&1 >/dev/null); then
            say "reopen 失败：${err:-gh gave no reason}"
            say '（分支若已删：先把 refs/pull/'"$closed"'/head 推回 issue-'"$n"'，再 reopen。）'
            ask '[r] 仍然直接恢复 · 其它键取消 ›'
            case "$REPLY_KEY" in r|R) ;; *) exit 0 ;; esac
          fi ;;
        r|R) ;;
        *) exit 0 ;;
      esac
    fi ;;
esac

# The hub's ⌃o, with focus: the window comes back AND becomes current.
FLEET_SPAWN_FOCUS=1 FLEET_RESTORE_SESS="$SESS" bash "$BIN/dash-restore-session.sh" "$TARGET" </dev/null
