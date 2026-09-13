#!/bin/bash
# dash-answer.sh <row target> — the dash's answer-a-worker's-question popup (issue #605).
#
# Runs INSIDE a dash popup (bin/dash-popup.sh), so it owns the terminal: it renders
# the pending `AskUserQuestion` as a tappable fzf list per question and hands the
# picks to bin/fleet-answer.sh. One tap per question; nothing is typed at the worker
# until every question has a pick, and Esc anywhere aborts having sent nothing.
#
# This is the tap-first front end for the deadlock fleet-answer.sh documents: a
# `SendMessage` cannot answer a question, because it is only delivered once the
# question has been answered. The dash row is where the operator already notices the
# `needs` flag, so it is where the answer belongs.
#
# The row's {1} is the dash target: a live row gives `<sess>:<idx>` — exactly the
# grammar fleet-answer.sh takes. A landed/header row has nothing to answer and is a
# quiet no-op, so the key is safe to bind unconditionally.
#
# Inside a pane $TMUX already points at THIS fleet's socket (issue #159), so no -L.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ANSWER="$BIN/fleet-answer.sh"
target="${1:-}"

pause() { printf '\n按任意键关闭…' >&2; read -r -n 1 -s _ 2>/dev/null || read -r _ 2>/dev/null || true; }
note()  { printf '%s\n' "$1" >&2; pause; exit 0; }

case "$target" in
  ''|landed:*) exit 0 ;;                    # nothing to answer on a landed/empty row
  *:*) : ;;
  *) exit 0 ;;                              # a header or anything else — quiet no-op
esac
[ -x "$ANSWER" ] || note "dash-answer: 找不到 $ANSWER"
command -v python3 >/dev/null 2>&1 || note "dash-answer: 需要 python3"
command -v fzf >/dev/null 2>&1 || note "dash-answer: 需要 fzf"

JSON=$("$ANSWER" --show "$target" --json 2>/dev/null) || note \
  "这个窗口没有待回答的 AskUserQuestion。
（needs 也可能是在等一个权限确认 —— 那个得进窗口自己按，
  fleet-answer 只答 AskUserQuestion，绝不去碰别的弹窗。）"

NQ=$(printf '%s' "$JSON" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["questions"]))' 2>/dev/null)
case "$NQ" in ''|*[!0-9]*) note "dash-answer: 解析不出问题（--show --json 输出异常）" ;; esac
[ "$NQ" -gt 0 ] || note "dash-answer: 没有问题可答"

PICKS=()
qi=0
while [ "$qi" -lt "$NQ" ]; do
  # header / question / multiSelect for the prompt, then one TAB row per option.
  meta=$(printf '%s' "$JSON" | QI="$qi" python3 -c '
import json, os, sys
q = json.load(sys.stdin)["questions"][int(os.environ["QI"])]
print("%s\t%s\t%s" % (q.get("header") or "", "multi" if q.get("multiSelect") else "one",
                      (q.get("question") or "").replace("\t", " ")))')
  hdr=$(printf '%s' "$meta" | cut -f1)
  mode=$(printf '%s' "$meta" | cut -f2)
  qtext=$(printf '%s' "$meta" | cut -f3)

  rows=$(printf '%s' "$JSON" | QI="$qi" python3 -c '
import json, os, sys
q = json.load(sys.stdin)["questions"][int(os.environ["QI"])]
for i, o in enumerate(q["options"], 1):
    d = (o.get("description") or "").replace("\t", " ").replace("\n", " ")
    lab = o["label"].replace("\t", " ")
    print("%d\t%s%s" % (i, lab, ("  —  " + d) if d else ""))')
  # Cancelling the whole dialog is offered on the FIRST question only: past that,
  # earlier tabs already carry picks and a cancel would throw them away silently.
  [ "$qi" = 0 ] && rows="$rows
x	⨯ 取消这个提问（给 worker 发 Esc）"

  hint='↵ 选一个'
  # Always a non-empty array: an empty one would break `set -u` on bash 3.2 (macOS).
  MULTI=(--no-multi)
  [ "$mode" = multi ] && { hint='Tab 多选 · ↵ 确认'; MULTI=(--multi); }
  sel=$(printf '%s\n' "$rows" | fzf --ansi --delimiter=$'\t' --with-nth=2.. \
          --layout=reverse --info=inline --no-sort --height=100% \
          "${MULTI[@]}" \
          --header="[$((qi + 1))/$NQ] $hdr — $qtext
$hint · esc 放弃（什么都不发）" \
          --prompt='答 ▸ ' 2>/dev/null | cut -f1 | paste -sd, -)
  [ -n "$sel" ] || note "已放弃 —— 一个按键都没发给 worker。"
  case "$sel" in
    x|x,*|*,x|*,x,*) "$ANSWER" --cancel "$target" >&2 2>&1; pause; exit 0 ;;
  esac
  PICKS+=("$sel")
  qi=$((qi + 1))
done

printf '正在回答 %s …\n' "$target" >&2
if "$ANSWER" --answer "$target" "${PICKS[@]}" >&2 2>&1; then
  printf '\n✔ 已送达并在 transcript 里确认。\n' >&2
else
  printf '\n⚠ 没有确认成功 —— 进窗口看一眼（上面有原因）。\n' >&2
fi
pause
exit 0
