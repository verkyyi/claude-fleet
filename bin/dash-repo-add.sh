#!/bin/bash
# dash-repo-add.sh [--session <sess>] [<owner/name>] — add a repo to this fleet from
# the UI (issue #1103, EPIC #1096 C7).
#
# Two entries, one script (EPIC #894 convention 1): the hub dash's ⌃z (`repo-add`
# in bin/dash-keymap.sh) and the task sidebar's row menu `g` (fleet-sidebar-menu.sh)
# both run it inside bin/dash-popup.sh. It asks ONE thing — the repo as owner/name
# (a GitHub URL or git@ form is normalised) — checks the shape, and hands it to
# `fleet-repo.sh add --session <sess> <owner/name>`: fleet_repo_register (issue
# #1104), the same implementation fleet-up.sh gives the first repo, so the checkout
# is $HOME/projects/<name> (reused when it already is that repo, cloned when
# missing — the clone streams its progress into the popup and can take a while),
# the base branch is resolved, the overlay is written, and the follow-through
# (trust warning, daemon wake, collector kick) runs. Nothing to restart: the dash
# re-reads fleet_repos every frame, so the new repo's heading is on the next one.
#
# The verdict is fleet-repo.sh's stdout token, said in the operator's words and
# held on screen until dismissed — ↵ / esc / a tap on [✕ close] (iPad first,
# issue #346). A wrong shape re-asks instead of failing; esc anywhere cancels.
#
# With <owner/name> on the command line nothing is asked and nothing waits — the
# scriptable form (tests, a one-liner). --session names the fleet; default
# $FLEET_SESSION (both popup openers export it), else the pane's own fleet.
#
# stdout is ONE result token — the set fleet-repo.sh add prints (added:<slug> ·
# refused:hosted · refused:origin-mismatch · refused:not-a-checkout ·
# refused:invalid-repo · failed:clone · failed:write) plus three of its own:
# `cancelled` (the prompt was dismissed), `refused:no-fleet` and `failed:no-result`
# (fleet-repo.sh printed no token). Exit 0 = added, 1 = refused/failed, 2 = usage,
# 130 = cancelled. Every human line is on stderr — inside the popup that IS the
# screen, so the operator sees the clone progress and the verdict either way.
set -uo pipefail
# fzf owns the input line (UTF-8/IME/paste-aware echo, instant esc — issue #429);
# force a UTF-8 locale so the CJK verdict lines are whole characters everywhere.
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-lib.sh"

SESS=""; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session)   [ $# -ge 2 ] || { echo "dash-repo-add: --session needs a value" >&2; exit 2; }
                 SESS="$2"; shift 2 ;;
    --session=*) SESS="${1#--session=}"; shift ;;
    -h|--help)   sed -n '2,3p' "$0" | sed 's/^# //' >&2; exit 2 ;;
    -*)          echo "dash-repo-add: unknown flag $1" >&2; exit 2 ;;
    *)           [ -z "$REPO" ] || { echo "dash-repo-add: extra arg $1" >&2; exit 2; }
                 REPO="$1"; shift ;;
  esac
done
[ -n "$SESS" ] || SESS="${FLEET_SESSION:-}"
[ -n "$SESS" ] || SESS=$(fleet_current_session 2>/dev/null)
if [ -z "$SESS" ] || [ ! -f "$(fleet_conf_file "$SESS")" ]; then
  echo "dash-repo-add: not inside a fleet — pass --session <sess>" >&2
  echo "refused:no-fleet"; exit 1
fi

INTERACTIVE=0
if [ -z "$REPO" ]; then
  if ! [ -t 0 ] && ! [ -t 1 ]; then
    echo "dash-repo-add: no repo given and no terminal to ask on — dash-repo-add.sh <owner/name>" >&2; exit 2
  fi
  command -v fzf >/dev/null 2>&1 \
    || { echo "dash-repo-add: fzf not found — from a shell: bin/fleet-repo.sh add <owner/name>" >&2; exit 2; }
  INTERACTIVE=1
fi

# shape <text> → the normalised owner/name on stdout; rc 1 when it is not one. The
# same rule fleet_repo_register applies, checked here first so a typo re-asks in
# the popup instead of burning a fleet-repo.sh run on it.
shape() {
  local r; r=$(fleet_norm_repo "$1")
  case "$r" in
    *[!A-Za-z0-9_./-]* | */*/* | /* | */) return 1 ;;
    ?*/?*) printf '%s' "$r"; return 0 ;;
  esac
  return 1
}

# `[✕ close]` header token + click-header bind: an iPad/Termius tap-to-dismiss
# where Escape is a reach (issue #346); bracketed as a button (issue #381), so the
# clicked word is `[✕` or `close]` and the case globs fire on either half.
# shellcheck disable=SC2016  # fzf expands $FZF_CLICK_HEADER_WORD itself
CLOSE_BIND='click-header:transform:case "$FZF_CLICK_HEADER_WORD" in *✕*|*close*) echo abort ;; esac'

if [ "$INTERACTIVE" = 1 ]; then
  hosted=$(fleet_repos "$SESS" | paste -sd ' ' - | sed 's/ / · /g')
  # fzf as a pure text input (issue #429): empty candidate list (< /dev/null),
  # --print-query echoes the typed line as the first output line. Exit 130 = Esc /
  # Ctrl-C / the ✕ tap → cancel; 0/1 = accepted (1 = Enter with no match, the
  # normal case here). fzf reads keys from /dev/tty, so it works inside
  # `display-popup -E`.
  note=""
  while :; do
    hdr="加仓库到 ${SESS}  ·  输入 owner/name（GitHub 网址也行）  ·  ↵ 加入 · esc 取消 · [✕ close]"
    hdr="$hdr"$'\n'"已托管：${hosted:-（无）}"
    [ -n "$note" ] && hdr="$hdr"$'\n'"$note"
    raw=$(fzf --print-query --no-multi --layout=reverse --no-info --no-separator \
              --height=100% --border=none --prompt='owner/name ▸ ' --header="$hdr" \
              --bind "$CLOSE_BIND" < /dev/null 2>/dev/null); rc=$?
    [ "$rc" -eq 130 ] && { echo cancelled; exit 130; }
    raw=${raw%%$'\n'*}
    raw=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$raw" ] || { echo cancelled; exit 130; }
    if REPO=$(shape "$raw"); then break; fi
    note="✗ 不是 owner/name 形状：${raw} — 再试一次"
  done
else
  raw="$REPO"
  REPO=$(shape "$raw") || {
    echo "dash-repo-add: '$raw' is not owner/name" >&2; echo "refused:invalid-repo"; exit 1; }
fi

name=$(basename "$REPO"); dir="$HOME/projects/$name"
tokf=$(mktemp "${TMPDIR:-/tmp}/dash-repo-add.XXXXXX") || exit 2
errf=$(mktemp "${TMPDIR:-/tmp}/dash-repo-add.XXXXXX") || { rm -f "$tokf"; exit 2; }
trap 'rm -f "$tokf" "$errf"' EXIT
{
  echo "→ fleet-repo.sh add --session $SESS $REPO"
  echo "  目录 ${dir} —— 已是这个仓库就复用，没有就克隆（可能要几十秒）"
  echo
} >&2
# stdout (the token) to a file; stderr (the clone's progress, the human lines)
# streams to the screen AND to a file, for the verdict screen's tail. A pipeline,
# not a process substitution, so the tee is done before the file is read.
bash "$BIN/fleet-repo.sh" add --session "$SESS" "$REPO" 2>&1 >"$tokf" | tee "$errf" >&2
token=$(grep -E '^(added|refused|failed):' "$tokf" | tail -n 1)

case "$token" in
  added:*)                 v="✓ 已加入 ${REPO} —— 目录 ${dir}；仪表盘下一帧出现「${name}」分组，后台已开始采集它"; rc=0 ;;
  refused:hosted)          v="已在本 fleet：${REPO}（什么都没改）"; rc=1 ;;
  refused:origin-mismatch) v="✗ 目录 ${dir} 已存在，但它的 origin 不是 ${REPO} —— 换个目录要用命令行：bin/fleet-repo.sh add ${REPO} <目录>"; rc=1 ;;
  refused:not-a-checkout)  v="✗ 目录 ${dir} 已存在，但不是 git 仓库 —— 挪开它，或用命令行指定别的目录"; rc=1 ;;
  refused:invalid-repo)    v="✗ 不是 owner/name 形状：${REPO}"; rc=1 ;;
  failed:clone)            v="✗ 克隆失败 —— 看上面 git 的输出（仓库名对吗？gh 登录了吗？有权限吗？）"; rc=1 ;;
  failed:write)            v="✗ 登记文件写不进去 —— 看上面的路径"; rc=1 ;;
  refused:*)               v="✗ 拒绝：${token#refused:}"; rc=1 ;;
  failed:*)                v="✗ 失败：${token#failed:}"; rc=1 ;;
  *)                       v="✗ fleet-repo.sh 没给出结果 —— 看上面的输出"; token="failed:no-result"; rc=1 ;;
esac
printf '\n%s\n' "$v" >&2
printf '%s\n' "$token"

# Hold the verdict on screen until dismissed (the popup closes with us). A list,
# not a `read -rsn1`: ↵ / esc / a double-tap on a row / a tap on [✕ close] all
# close it, which is what an iPad has. The last lines fleet-repo.sh said come
# along (a clone's \r progress unfolded), so a failure's reason is on screen.
if [ "$INTERACTIVE" = 1 ]; then
  rows="$v"$'\n'"$(tr '\r' '\n' < "$errf" | grep -v '^[[:space:]]*$' | tail -n 8 | sed 's/^/    /')"
  printf '%s\n' "$rows" | fzf --no-sort --layout=reverse-list --info=hidden --no-separator \
      --border=none --height=100% --no-input \
      --header="[✕ close]  ·  ↵ / esc 关闭" --bind "$CLOSE_BIND" >/dev/null 2>&1 || :
fi
exit "$rc"
