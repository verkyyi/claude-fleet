#!/bin/bash
# fleet-keys.sh — the fleet keymap cheatsheet (issue #110). One curated source
# of truth for EVERY fleet shortcut, grouped by context:
#   tmux prefix binds · task sidebar · dashboard fzf · backlog fzf · config modal fzf.
#
# Opened by `prefix ?` (display-popup -E; see conf/tmux-attention.conf) and by a
# `?` bind inside the dash/backlog. The popup closes on q/esc.
#
# Context scoping (issue #265): the global `prefix ?` shows the WHOLE sheet, but
# when opened from INSIDE a panel it shows only the shortcuts that apply there —
# that panel's own binds plus the global `tmux prefix` binds (which fire from any
# pane, the dash included), not the other panels' inner binds. Pass the panel via
# `--context dash|backlog` (default `all` = every group). `--context sidebar`
# (issue #948, cut to one screen by #963) is the task sidebar's own `?` sheet:
# the six keys an operator actually uses there, in short Chinese, so the popup
# never needs scrolling. Everything else — the full task sidebar group and the
# `.` row menu's letters — stays in the full sheet, prefix ? away.
#
# Usage:
#   fleet-keys.sh                    # full sheet, wait for q/esc (popup mode)
#   fleet-keys.sh --context dash     # dashboard-scoped sheet (+ tmux prefix)
#   fleet-keys.sh --context backlog  # backlog-scoped sheet (+ tmux prefix)
#   fleet-keys.sh --context sidebar  # the task sidebar's sheet (its `?` / ? row)
#   fleet-keys.sh --plain            # print once and exit (no wait) — pipes/tests
#                                    #   also implied when stdout is not a tty
#
# Drift guard: bin/fleet-keys-selftest.sh cross-checks the keys listed here
# against the binds actually shipped in conf/tmux-attention.conf + the dash/
# backlog fzf --binds, so this sheet can't silently go stale.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh" 2>/dev/null || true
if command -v fleet_load_conf >/dev/null 2>&1; then
  sess="${FLEET_SESSION:-}"
  [ -n "$sess" ] || sess=$(fleet_current_session 2>/dev/null || true)
  [ -n "$sess" ] && fleet_load_conf "$sess" 2>/dev/null || true
fi
. "$BIN/fleet-ui-lang.sh"

PLAIN=""
CONTEXT="all"
while [ $# -gt 0 ]; do
  case "$1" in
    --plain)      PLAIN=1 ;;
    --context)    shift; CONTEXT="${1:-all}" ;;
    --context=*)  CONTEXT="${1#--context=}" ;;
    *)            ;;  # ignore unknown args (forward-compat)
  esac
  shift
done
# Unknown context ⇒ fall back to the full sheet (never render nothing).
case "$CONTEXT" in all|dash|backlog|sidebar) ;; *) CONTEXT="all" ;; esac
# Non-interactive stdout (pipe/redirect/test) ⇒ print-and-exit, never block.
[ -t 1 ] || PLAIN=1

# --- colours (honour NO_COLOR + non-tty) --------------------------------------
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; CYAN=$'\033[36m'; YEL=$'\033[33m'; R=$'\033[0m'
else
  B=""; DIM=""; CYAN=""; YEL=""; R=""
fi

# --- panel keys: resolved tables, never the defaults (#556/#558) ------------
# tmux never delivers its prefix (or prefix2) to a pane, so the dash resolves
# every ⌃-key through bin/dash-keymap.sh at launch — the default, else its ⌥
# fallback. This sheet reads the SAME resolution: `dg <action>` is the glyph
# actually bound, `dn <action>` a trailing note when the default was dodged —
# so the sheet can never name a key the terminal will not deliver.
# Start with the dash table; backlog/config load their own before rendering.
eval "$(bash "$BIN/dash-keymap.sh" env 2>/dev/null)"
dg() {
  local v; v="DASH_GLYPH_$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')"
  printf '%s' "${!v:-⌃?}"
}
dn() {
  local a s r g gl
  a=$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')
  s="DASH_KEYSTATE_$a"; r="DASH_REMAP_$a"; g="DASH_GLYPH_$a"; gl="${!g:-}"
  case "${!s:-ok}" in
    remapped)    printf ' — (⌥ fallback: ⌃%s is your tmux prefix %s)' "${gl#⌥}" "${!r:-}" ;;
    unreachable) printf ' — (UNREACHABLE: %s is your tmux prefix %s and its ⌥ twin is one too)' "$gl" "${!r:-}" ;;
  esac
}

# group <title>; then key <keys> <desc> rows. Two columns; the key column is
# padded to a fixed DISPLAY width — computed from ${#k} (character count, not
# bytes) so multi-byte glyphs like ⌃ / ⌥ / ● still line up in a UTF-8 locale.
group() { printf '\n%s%s%s %s%s\n' "$B" "$CYAN" "$1" "$R" "${2:+$DIM$2$R}"; }
key() {
  local k="$1" desc="$2" pad n
  n=$((11 - ${#k})); [ "$n" -lt 1 ] && n=1
  printf -v pad '%*s' "$n" ''
  printf '  %s%s%s%s%s\n' "$YEL" "$k" "$R" "$pad" "$desc"
}

# want <group> — is this group in scope for the current $CONTEXT? The global
# `tmux prefix` binds fire from any pane, so they show in every scope; the
# per-panel groups (dashboard/backlog/config modal) show only in the full sheet
# or when that panel is the active context.
want() {
  case "$CONTEXT" in
    all)     return 0 ;;
    dash)    case "$1" in prefix|dashboard) return 0 ;; *) return 1 ;; esac ;;
    backlog) case "$1" in prefix|backlog)   return 0 ;; *) return 1 ;; esac ;;
    sidebar) return 1 ;;   # its own compact sheet: print_sidebar_sheet
    *)       return 0 ;;
  esac
}

# The task sidebar's `?` sheet (issue #963): the seven keys an operator uses on
# the sidebar (the input line's editing keys share one row, #1097), one short
# Chinese line each, so the whole sheet fits its popup
# (fleet-sidebar.py's open_help sizes it to this) — the popup cannot scroll.
# `skey <key> <extra> <desc>`: the key column is 14 CELLS; <extra> is how many
# of the key's characters are double-width (CJK), which ${#k} counts once.
# Keymap-resolved keys still come from `--panel sidebar` (dg), never hardcoded.
skey() {
  local k="$1" pad n
  n=$((14 - ${#k} - $2)); [ "$n" -lt 1 ] && n=1
  printf -v pad '%*s' "$n" ''
  printf '  %s%s%s%s%s\n' "$YEL" "$k" "$R" "$pad" "$3"
}
print_sidebar_sheet() {
  eval "$(bash "$BIN/dash-keymap.sh" --panel sidebar env 2>/dev/null)"
  printf '%s%s %s %s  %s%s%s\n\n' "$B" "$CYAN" "$(fleet_ui_t keys_sidebar_title)" "$R" "$DIM" "$(fleet_ui_t keys_close)" "$R"
  if [ "$(fleet_ui_lang)" = zh ]; then
    skey "打字 ↵" 2 "起新会话"
    skey "↑ ↓" 0 "切换任务"
    skey "编辑" 2 "←→ Home End ⌥←→ $(dg bol) $(dg eol) $(dg kill_word) $(dg kill_eol) ⌃u"
    skey "$(dg menu) / 再点一次" 4 "任务菜单$(dn menu)"
    skey "esc" 0 "键盘还给任务"
    skey "⌂ / F9" 0 "进任务栏，再按去 hub"
    skey "prefix ?" 0 "全部按键（prefix = ${DASH_KEYMAP_PREFIX:-C-b}）"
  else
    skey "type ↵" 0 "new session"
    skey "↑ ↓" 0 "switch task"
    skey "edit" 0 "←→ Home End ⌥←→ $(dg bol) $(dg eol) $(dg kill_word) $(dg kill_eol) ⌃u"
    skey "$(dg menu) / tap again" 0 "task menu$(dn menu)"
    skey "esc" 0 "return keys to task"
    skey "⌂ / F9" 0 "enter sidebar, then hub"
    skey "prefix ?" 0 "all keys (prefix = ${DASH_KEYMAP_PREFIX:-C-b})"
  fi
}

print_sheet_zh() {
  local sub
  if [ "$CONTEXT" = sidebar ]; then print_sidebar_sheet; return; fi
  case "$CONTEXT" in
    dash)    sub="（仪表盘面板 · tmux 前缀键也可用 · q/esc 关闭）" ;;
    backlog) sub="（议题列表面板 · tmux 前缀键也可用 · q/esc 关闭）" ;;
    *)       sub="（prefix = tmux 前缀键，本机为 ${DASH_KEYMAP_PREFIX:-C-b} · q/esc 关闭）" ;;
  esac
  printf '%s%s fleet 快捷键 %s  %s%s%s\n' "$B" "$CYAN" "$R" "$DIM" "$sub" "$R"

  if want prefix; then
  group "tmux 前缀" "— 任意窗口可用"
  key "prefix a" "跳到下一个需要你处理的窗口（红色优先，其次绿色）"
  key "prefix g" "聚焦 hub 的仪表盘；再按一次放大"
  key "prefix e" "显示/隐藏 worker 任务栏（保存到当前 fleet；窄屏自动隐藏）"
  key "prefix E" "聚焦任务栏；没有任务栏时打开任务选择器"
  key "prefix Space" "任务选择器：切换任务，或输入名称新建 scratch；F9 / ⌂ 回 hub"
  key "prefix b" "议题列表：GitHub issues，回车启动该 issue 的 worker"
  key "prefix c" "配置弹窗：查看/编辑 FLEET_* 设置"
  key "prefix z" "缩放当前 worker（tmux 原生 zoom）"
  key "prefix [" "查看 worker 滚屏（tmux copy-mode）"
  key "prefix u" "用量 + 账号弹窗：查看 5h/7d 用量，选择新会话账号"
  key "prefix !" "告警弹窗：✖ 告警 / ▲ 提醒 / ● 等你 一张表，↵ 执行动作 · 1/2/3 按级别过滤 · m 静音 1 小时（✖ 不可静音）"
  key "prefix ?" "打开这份快捷键"
  key "F9" "无前缀：回到本 fleet 的 hub；在带任务栏的任务里先聚焦任务栏，再按回 hub"
  key "cf --guide" "在 shell 叫回上手向导，从上次进度继续"
  key "click ● N" "点击左下角 needs 数字：跳到下一个需要处理的窗口"
  key "click ✖ / ▲" "点击右下角告警计数：打开告警弹窗，只看该级别"
  fi

  if want sidebar; then
  eval "$(bash "$BIN/dash-keymap.sh" --panel sidebar env 2>/dev/null)"
  group "任务栏" "— prefix E 或点击任务栏后可用"
  key "输入名称" "在底部输入行编辑；支持中文、空格、粘贴；回车新建 scratch 并切过去"
  key "enter" "有名称：新建 scratch；空行：把键盘还给 worker"
  key "esc" "清空输入；空行时把键盘还给 worker"
  key "↑ / ↓" "选择任务；停顿后切换到选中任务"
  key "← / →" "有文字时移动光标；空行时折叠/展开选中行或仓库组"
  key "⌥← / ⌥→" "按词移动光标"
  key "$(dg bol)" "光标到行首$(dn bol)"
  key "$(dg eol)" "光标到行尾$(dn eol)"
  key "$(dg kill_word)" "删除光标前一个词$(dn kill_word)"
  key "$(dg kill_eol)" "删除光标到行尾$(dn kill_eol)"
  key "$(dg new)" "新任务：创建 issue 并启动 worker$(dn new)"
  key "$(dg menu)" "空行时打开选中任务菜单；输入名称时就是普通点号$(dn menu)"
  key "$(dg restore)" "恢复已收工任务$(dn restore)"
  key "$(dg help)" "空行时打开任务栏快捷键；输入名称时就是普通问号$(dn help)"
  key "prefix e" "隐藏任务栏"
  fi

  if want menu; then
  group "行菜单" "— 在任务栏按 . 或再次点击选中行"
  local mk what
  while IFS='	' read -r mk what; do
    [ -n "$mk" ] && key "$mk" "$what"
  done <<EOF
$(FLEET_UI_LANG=zh bash "$BIN/fleet-sidebar-menu.sh" --keys 2>/dev/null)
EOF
  fi

  if want dashboard; then
  group "仪表盘" "— hub 的 dash 面板内（prefix g）"
  key "enter" "跳到高亮窗口"
  key "→ / ←" "展开/折叠高亮行的子树；在仓库标题上折叠/展开整个仓库组"
  key "id a1 b7" "左侧 id 是窗口句柄，可给 fleet-migrate.sh / dash-reap.sh 等命令使用"
  key "输入名称, enter" "按输入文本新建 scratch，文本会预填为未发送草稿；中文和空格都支持"
  key "$(dg new)" "新 issue：创建 issue 并启动 worker$(dn new)"
  key "$(dg scratch)" "立即新建 raw scratch 会话$(dn scratch)"
  key "$(dg agent)" "切换新会话默认 agent（claude ⇄ codex），写入当前 fleet 配置$(dn agent)"
  key "$(dg rename)" "重命名高亮窗口；在查询行内编辑$(dn rename)"
  key "$(dg answer)" "处理红色 needs 行：回答问题或查看权限阻塞详情$(dn answer)"
  key "$(dg reap)" "回收完成的 worker；必要时确认，脏 worktree 会保留$(dn reap)"
  key "$(dg migrate)" "把高亮会话迁移到另一个有余量的账号$(dn migrate)"
  key "$(dg pin)" "置顶/取消置顶高亮窗口；置顶行显示在最上方$(dn pin)"
  key "$(dg repo-add)" "给当前 fleet 添加仓库$(dn repo-add)"
  key "$(dg view)" "切换 live / closed 视图$(dn view)"
  key "$(dg restore)" "恢复高亮的已收工会话$(dn restore)"
  key "enter (landed)" "恢复高亮 landed 会话"
  key "$(dg pr) (landed)" "在浏览器打开 landed 行的 PR$(dn pr)"
  key "$(dg reload)" "立即刷新$(dn reload)"
  key "?" "空查询行时打开这份快捷键"
  key "esc" "重启 dash（hub 面板常驻）"
  fi

  if want backlog; then
  eval "$(bash "$BIN/dash-keymap.sh" --panel backlog env 2>/dev/null)"
  group "议题列表" "— prefix b 内"
  key "space" "显示/隐藏预览窗（正文、标签、评论）"
  key "/" "筛选 issues"
  key "enter" "启动高亮 issue 的 worker"
  key "$(dg new)" "创建新 issue$(dn new)"
  key "$(dg close)" "关闭高亮 issue（y/n 确认）$(dn close)"
  key "$(dg priority)" "循环优先级标签（无→p2→p1→p0→无）$(dn priority)"
  key "$(dg open)" "在网页打开 issue$(dn open)"
  key "$(dg reload)" "立即刷新$(dn reload)"
  key "?" "打开这份快捷键"
  key "esc" "关闭"
  fi

  if want config; then
  eval "$(bash "$BIN/dash-keymap.sh" --panel config env 2>/dev/null)"
  group "配置弹窗" "— prefix c 内"
  key "enter" "编辑高亮配置项 / 展开分组"
  key "tab" "展开/折叠分组"
  key "$(dg scope)" "切换写入范围（当前 fleet ⇄ repo）$(dn scope)"
  key "space / $(dg preview)" "显示/隐藏详情预览$(dn preview)"
  key "?" "显示原始 FLEET_* 键名"
  key "$(dg reload)" "立即刷新$(dn reload)"
  key "esc" "关闭"
  fi
}

print_sheet() {
  local sub
  if [ "$CONTEXT" = sidebar ]; then print_sidebar_sheet; return; fi
  if [ "$(fleet_ui_lang)" = zh ]; then print_sheet_zh; return; fi
  case "$CONTEXT" in
    dash)    sub="(dashboard panel · prefix binds work here too · q/esc to close)" ;;
    backlog) sub="(backlog panel · prefix binds work here too · q/esc to close)" ;;
    *)       sub="(prefix = your tmux prefix, ${DASH_KEYMAP_PREFIX:-C-b} here · q/esc to close)" ;;
  esac
  printf '%s%s fleet keymap %s  %s%s%s\n' "$B" "$CYAN" "$R" "$DIM" "$sub" "$R"

  if want prefix; then
  group "tmux prefix" "— global, from any window"
  key "prefix a" "jump to the next window that needs you (red first, then green)"
  key "prefix g" "focus the dash — jump to the hub's dash pane; press again to zoom it"
  key "prefix e" "show/hide the worker task sidebar (saved for this fleet; narrow screens hide it automatically)"
  key "prefix E" "focus the task sidebar (or click/tap it) — then type: see the 'task sidebar' group. No sidebar on screen: opens the task picker (prefix Space)"
  key "prefix Space" "task picker — the task sidebar's list as a popup, for when the sidebar is hidden (narrow screen) or off: ↵ switch · type a name + $(dg scratch) (or ↵ on no match) = new scratch session · F9 / [⌂ hub] = the hub · esc / [✕ close]$(dn scratch)"
  key "prefix b" "backlog modal — GitHub issues; enter spawns the issue's session"
  key "prefix c" "config modal — view/edit FLEET_* across layers"
  key "prefix z" "zoom the worker (tmux's own zoom) — from the task sidebar too: it zooms the WORKER and hands the keyboard back, never the sidebar"
  key "prefix [" "scroll back the worker (tmux copy-mode) — from the task sidebar too: it opens on the WORKER and hands the keyboard back"
  key "prefix u" "usage + account modal — 5h/7d usage and limit detail, and (with an account pool) pick the account new sessions use"
  key "prefix !" "alerts popup — every ✖ alarm / ▲ warning / ● needs the status bar counts, one row each with its action: ↵ act (go to window / restart daemon / see accounts / see disk) · 1/2/3 filter by level, 0 all · m mute 1h (never an alarm) · esc close"
  key "prefix ?" "this cheatsheet"
  key "F9" "(no prefix) jump back to this session's hub — from a task showing the task bar, the first press focuses the bar (like prefix E) and a second press goes to the hub; the ⌂ tap does the same. A task with NO sidebar on screen opens the task picker instead (prefix Space), F9 in it goes on to the hub (FLEET_HOME_SIDEBAR_FIRST=0 turns both off)"
  key "cf --guide" "from a shell, reopen the onboarding guide at its saved progress"
  key "click ● N" "the needs badge (bottom-left) cycles to the next 'needs' window"
  key "click ✖ / ▲" "the alert counts (bottom-right) — open the alerts popup filtered to that level"
  fi

  if want sidebar; then
  eval "$(bash "$BIN/dash-keymap.sh" --panel sidebar env 2>/dev/null)"
  group "task sidebar" "— once prefix E or a tap puts the keyboard on it"
  key "type a name" "fills the ONE input line at the bottom at its cursor ▏ — every letter types (q n j k too), CJK fine; backspace deletes before the cursor, delete after it, ⌃u clears. Rename edits the same way"
  key "paste" "a terminal paste (⌘v) lands on the input line too, as ONE name — newlines become spaces, nothing is submitted; the worker sees none of it while the keyboard is here"
  key "enter" "with a name: start a scratch session named after it (the hub's ⌃s) and switch to it — no popup, no hub. A refusal (cap, worktree) shows on the line and keeps the name. Empty line: give input back to the worker"
  key "esc" "clear the typed name; on an empty line give input back to the worker"
  key "↑ / ↓" "switch to the highlighted task (follows once you pause, ~¼s; a held key is one switch, a row passed over is never selected); on an EMPTY line home/end the ends"
  key "← / →" "with text: move the cursor (home/end: to the line's start/end). On an EMPTY line: fold / unfold the highlighted row's subtree — or, on a repo heading, that repo's whole group (\`▸ tokenledger (2)\` is a folded one) — the hub's rule"
  key "⌥← / ⌥→" "move the cursor a word left / right (the terminal's ESC b / ESC f or ⌥-arrow)"
  key "$(dg bol)" "cursor to the start of the line$(dn bol)"
  key "$(dg eol)" "cursor to the end of the line$(dn eol)"
  key "$(dg kill_word)" "delete the word before the cursor$(dn kill_word)"
  key "$(dg kill_eol)" "delete from the cursor to the end of the line$(dn kill_eol)"
  key "tap a heading" "2+ repos, viewing all: a tap on a repo heading selects it (no switch) and the input line names it — a typed name or new task starts THERE; tap it again for the new-task popup pinned to that repo. 'no repo' = \$HOME; esc or a tap on a task clears it"
  key "$(dg new)" "new task — file an issue AND spawn its worker (the hub's ⌃n popup)$(dn new)"
  key "$(dg menu)" "on an EMPTY line: the highlighted task's menu — rename (edits on this line: ↵ applies, esc/empty cancels) · pin · open PR · answer its question · flip new sessions claude⇄codex · reap (asks y/n first) · new task. Inside a name it types a dot. Touch: tap the highlighted row again$(dn menu)"
  key "$(dg restore)" "restore a finished task — the hub's ⌃t landed list in a popup; ↵ brings it back as the current window (a closed-unmerged PR asks to reopen first). Touch: the row menu's last item$(dn restore)"
  key "$(dg help)" "on an EMPTY line, or a tap on the '? 快捷键' row above it: this sidebar's key sheet. Inside a name it types a ?$(dn help)"
  key "prefix e" "hide the sidebar (q types now; no tap hides it)"
  fi

  if want menu; then
  group "row menu" "— after . or a second tap on the highlighted row: press its letter"
  local mk what
  while IFS='	' read -r mk what; do
    [ -n "$mk" ] && key "$mk" "$what"
  done <<EOF
$(bash "$BIN/fleet-sidebar-menu.sh" --keys 2>/dev/null)
EOF
  fi

  if want dashboard; then
  group "dashboard" "— inside the hub dash pane (prefix g)"
  key "enter" "jump to the highlighted window"
  key "→ / ←" "unfold / fold the highlighted row's subtree. A session spawned from another one nests under it (└ indent), and those children are COLLAPSED BY DEFAULT — the parent row's \`3/5 ✓ · 1!\` badge is what the folded block says, so the list stays one line per parent. → opens the block you are on, ← shuts the block you are IN (from the parent row or from any child in it, which puts the cursor back on the parent). A child in \`needs\` NEVER folds away — any red glyph (\`?\` question · \`⊘\` permission · \`⊠\` worker-declared blocker: read the issue · \`!\`) — because the quiet layer folds and the loud one does not. ▸ / ▾ on a row marks a folded / open block. On a REPO HEADING (a 2+ repo fleet's \`tokenledger (2)\`) the same keys fold and unfold that repo's whole group — ← leaves the heading alone as \`▸ tokenledger (2)\`, its count still the rows it hides, → brings them back; a \`needs\` row shows through here too. The closed view (⌃t) nests and folds the same way, off the ledger's own record of what spawned what. With text typed on the prompt line, ←/→ are that line's cursor keys as always"
  key "id a1 b7" "the leftmost id column is that WINDOW's handle (a1…z9) — unique in this fleet, it survives a migrate/handoff, and it is accepted wherever a window target is: \`fleet-migrate.sh b3\`, \`dash-reap.sh a1\`. Freed for reuse once the window is gone; the landed view has none (⌃t shows \`·\`)"
  key "type a name, enter" "scratch named after the text, full text prefilled as an UNSENT draft; CJK + spaces fine, title capped at 24 cols (esc clears the dash input)"
  key "$(dg new)" "new issue — file one AND spawn its worker (quick-dispatch)$(dn new)"
  key "$(dg scratch)" "raw scratch session — spawns instantly (the fleet's default agent in its own scratch-N worktree, no issue, no prompt)$(dn scratch)"
  key "$(dg agent)" "flip this fleet's default agent for NEW sessions (claude ⇄ codex) — the prompt line shows it (claude ▸ / codex ▸); written to the fleet's conf, so every spawn path follows — this key, prefix+c or FLEET_AGENT in the conf are the ways to pick it (no prompt-line prefix)$(dn agent)"
  key "$(dg rename)" "rename the highlighted window — edit inline on the query line (↵ commits · esc cancels)$(dn rename)"
  key "$(dg answer)" "deal with the highlighted red row. A \`?\` row is an AskUserQuestion: a tappable list per question, one tap each (issue #605) — and the ONLY way to answer one, since a SendMessage is delivered between turns and a pending question IS the turn, so the message waits for the answer that waits for the message. A \`⊘\` row is a PERMISSION prompt: this SHOWS you the blocked command and the reason it was stopped, without attaching to the pane (issue #640) — approving one is a human decision and nothing here will press Yes. Either way nothing is typed unless the chosen option is visibly on the worker's screen$(dn answer)"
  key "$(dg reap)" "reap a finished worker (window + worktree + issue) — confirms when the row isn't merged+clean. Targets: @window-id, %pane-id, registered handle, issue-N or scratch-N; indexes/names are refused. From a SCRIPT: \`dash-reap.sh <handle> --yes\` takes that confirm branch unasked (a dirty worktree is still KEPT) and prints a result token (\`reaped:full\`/\`reaped:keep\`/\`skip:needs-confirm\`/\`refused:<slug>\`); with no client attached it never pops a box at you$(dn reap)"
  key "$(dg migrate)" "move the highlighted session onto another subscription account NOW — the unstick for a \`⚠ stuck\` row (issue #873). A confirm popup shows the target account and every background command the move will stop; y closes it (/exit), stops those commands, and resumes the same transcript in a new window on the account with headroom, the stopped commands named in its first prompt. Refuses when no account has room (every one benched) — it never bounces a session onto another wall. Same as \`fleet-account.sh migrate --force-bg <window>\`; \`migrate --stuck\` moves every stuck row$(dn migrate)"
  key "$(dg pin)" "pin/unpin the highlighted window to the TOP of the list — a pin beats the status sort (a pinned idle row sits above a red one), so the session you are deliberately watching stays where you left it. Pinned rows move to the 置顶 group at the very top (a thin line closes it; ←/→ on its heading folds it); pinning a PARENT floats its children with it, still nested. The pin lives on the tmux window, so it vanishes with the window — nothing to clean up$(dn pin)"
  key "$(dg repo-add)" "add a repo to this fleet (issue #1103) — a popup asks just owner/name (a GitHub URL is fine) and runs \`fleet-repo.sh add\`: the checkout is ~/projects/<name>, reused when it already is that repo, cloned when missing (the clone's progress shows in the popup); the verdict stays up until you dismiss it (↵ / esc / [✕ close]) — added · already hosted · the dir is another repo · clone failed. No restart: the repo's heading is on the dash's next frame and the background daemons pick it up within a tick. Also the task sidebar's row menu \`g\`. A different checkout dir still needs the shell form, \`bin/fleet-repo.sh add <owner/name> <dir>\`$(dn repo-add)"
  key "$(dg view)" "toggle live ⇄ closed (finished sessions + scratch)$(dn view)"
  key "$(dg restore)" "restore the highlighted landed session into a new window (claude --resume)$(dn restore)"
  key "enter (landed)" "resume the highlighted landed session — same as $(dg restore)"
  key "$(dg pr) (landed)" "open the highlighted landed row's PR in the browser$(dn pr)"
  key "$(dg reload)" "refresh now$(dn reload)"
  key "?" "this cheatsheet — on an EMPTY prompt line (with text typed, ? is just a character)"
  key "esc" "relaunch the dash (it's the always-on hub pane)"
  fi

  if want backlog; then
  eval "$(bash "$BIN/dash-keymap.sh" --panel backlog env 2>/dev/null)"
  group "backlog" "— inside prefix b"
  key "space" "toggle the preview pane (body/labels/comments) — off by default"
  key "/" "filter issues (type to narrow; off by default)"
  key "enter" "work the issue — spawn its session"
  key "$(dg new)" "file a new issue$(dn new)"
  key "$(dg close)" "close the highlighted issue (y/n confirm)$(dn close)"
  key "$(dg priority)" "cycle the issue's priority label (none→p2→p1→p0→none)$(dn priority)"
  key "$(dg open)" "open the issue on the web$(dn open)"
  key "$(dg reload)" "refresh now$(dn reload)"
  key "?" "this cheatsheet"
  key "esc" "close"
  fi

  if want config; then
  eval "$(bash "$BIN/dash-keymap.sh" --panel config env 2>/dev/null)"
  group "config modal" "— inside prefix c"
  key "enter" "edit the highlighted key / expand the section"
  key "tab" "expand/collapse a section"
  key "$(dg scope)" "toggle the write scope (this fleet ⇄ repo)$(dn scope)"
  key "space / $(dg preview)" "toggle the detail preview$(dn preview)"
  key "?" "reveal the raw FLEET_* keys inline"
  key "$(dg reload)" "refresh now$(dn reload)"
  key "esc" "close"
  fi
}

print_sheet

[ -n "$PLAIN" ] && exit 0

# Interactive popup: hold open until q or esc. read -rsn1 grabs one keypress;
# $'\e' is the esc byte. Anything else just redraws nothing and waits again.
while :; do
  IFS= read -rsn1 k || break
  case "$k" in
    q|Q|$'\e') break ;;
  esac
done
