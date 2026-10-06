#!/bin/sh
# fleet-ui-lang.sh — THE one table of every UI string the fleet draws (issue
# #1535, EPIC #1529 E6). Source-safe; `fleet_ui_t KEY [args…]` is the only way a
# string reaches the bar, the sidebar, a popup, a menu or a toast:
#
#   shell    . fleet-ui-lang.sh; fleet_ui_t KEY [args…]   (printf-style args)
#   tmux     run-shell "sh …/fleet-ui-lang.sh toast '#{client_name}' KEY"
#   python   fleet-ui-lang.sh dump PREFIX… — every KEY starting with a PREFIX as
#            KEY NUL TEXT NUL, each printf argument left as a \001 slot
#            (fleet-sidebar.py reads its strings this way, once, at start)
#
# Today there were four tables (this one, fleet-sidebar.py's TEXT,
# fleet-sidebar-menu.sh's MENU_KEYS, fleet-keys.sh's whole zh sheet); a string
# added anywhere else is a second source again — fleet-ui-lang-selftest.sh greps
# for one. A key with no entry prints itself, so a typo is visible, never blank.
#
# FLEET_UI_LANG:
#   auto  follow the login locale (zh* => Chinese, everything else English)
#   en    force English
#   zh    force Chinese
#
# A script that looks up many strings in a row (the key sheet, the row menu)
# calls `fleet_ui_pin` once: the language is resolved one time instead of in a
# subshell per lookup. Not exported — a child resolves its own.

fleet_ui_lang() {
  case "${FLEET_UI_LANG:-auto}" in
    zh|zh_*|zh-*|ZH|ZH_*|ZH-*|cn|CN|chinese|Chinese) printf 'zh\n'; return 0 ;;
    en|en_*|en-*|EN|EN_*|EN-*|english|English)       printf 'en\n'; return 0 ;;
  esac
  case "${LC_ALL:-${LC_MESSAGES:-${LC_CTYPE:-${LANG:-}}}}" in
    zh*|ZH*) printf 'zh\n' ;;
    en*|EN*) printf 'en\n' ;;
    ''|C|POSIX) printf 'zh\n' ;;
    *)       printf 'en\n' ;;
  esac
}

fleet_ui_pin() { _FLEET_UI_L=$(fleet_ui_lang); }

fleet_ui_t() {
  _fleet_ui_key=$1
  shift 2>/dev/null || :
  case "${_FLEET_UI_L:-$(fleet_ui_lang)}:$_fleet_ui_key" in
    zh:dash_ghost_fmt)          printf '↵ 新开 scratch（预填不发送） · 切换 agent: %s' "${1:-}" ;;
    en:dash_ghost_fmt)          printf '↵ new scratch (prefilled, unsent) · switch agent: %s' "${1:-}" ;;
    zh:agent_no_fleet)          printf 'fleet: 不在 fleet 里，无法修改当前 fleet 的 FLEET_AGENT（可改 fleet.conf）' ;;
    en:agent_no_fleet)          printf 'fleet: not inside a fleet — no per-fleet conf to flip FLEET_AGENT in (set it in fleet.conf)' ;;
    zh:agent_not_flipped_fmt)   printf 'fleet: 未切换 FLEET_AGENT — %s' "${1:-}" ;;
    en:agent_not_flipped_fmt)   printf 'fleet: FLEET_AGENT not flipped — %s' "${1:-}" ;;
    zh:agent_write_failed_fmt)  printf 'fleet: 写入 %s 失败（磁盘满或只读？）— FLEET_AGENT 未变' "${1:-}" ;;
    en:agent_write_failed_fmt)  printf 'fleet: write to %s FAILED (full/read-only volume?) — FLEET_AGENT unchanged' "${1:-}" ;;
    zh:agent_flipped_fmt)       printf 'fleet: 新会话 → %s · %s 切回' "${1:-}" "${2:-}" ;;
    en:agent_flipped_fmt)       printf 'fleet: new sessions → %s · %s flips back' "${1:-}" "${2:-}" ;;
    zh:pin_unpinned_fmt)        printf '已取消置顶：%s' "${1:-}" ;;
    en:pin_unpinned_fmt)        printf 'unpinned: %s' "${1:-}" ;;
    zh:pin_pinned_fmt)          printf '已置顶：%s' "${1:-}" ;;
    en:pin_pinned_fmt)          printf 'pinned to the top: %s' "${1:-}" ;;
    # ⌂ / F9 / prefix g landing on the list (issue #1533, fleet-sidebar.sh home)
    # the one failure line (issue #1618, fleet_ui_fail): reason, then the next step
    zh:ui_fail_fmt)             printf '✗ %s' "${1:-}" ;;
    en:ui_fail_fmt)             printf '✗ %s' "${1:-}" ;;
    zh:ui_fail_next_fmt)        printf '✗ %s — %s' "${1:-}" "${2:-}" ;;
    en:ui_fail_next_fmt)        printf '✗ %s — %s' "${1:-}" "${2:-}" ;;
    zh:ui_already_open_fmt)     printf '#%s 已经开着' "${1:-}" ;;
    en:ui_already_open_fmt)     printf '#%s already spawned' "${1:-}" ;;
    zh:ui_already_open_next)    printf '在列表里选它那一行' ;;
    en:ui_already_open_next)    printf 'pick its row in the list' ;;
    zh:ui_filed_no_worker_fmt)  printf '#%s 已建，但没开会话：%s' "${1:-}" "${2:-}" ;;
    en:ui_filed_no_worker_fmt)  printf '#%s filed, but no session started: %s' "${1:-}" "${2:-}" ;;
    zh:ui_filed_no_worker_next) printf '稍后在 backlog 里开' ;;
    en:ui_filed_no_worker_next) printf 'start it from the backlog' ;;
    zh:sidebar_narrow_why)      printf '窗口太窄放不下任务栏' ;;
    en:sidebar_narrow_why)      printf 'too narrow for the list' ;;
    zh:sidebar_narrow_next)     printf '加宽终端或 prefix Space' ;;
    en:sidebar_narrow_next)     printf 'widen it, or prefix Space' ;;
    zh:sidebar_save_next)       printf '配置目录只读？' ;;
    en:sidebar_save_next)       printf 'conf dir read-only?' ;;
    zh:sidebar_save_failed)     printf '任务栏设置没保存' ;;
    en:sidebar_save_failed)     printf 'sidebar setting not saved' ;;
    zh:wait_slot)               printf 'z · 等待空位' ;;
    en:wait_slot)               printf 'z · waiting for a slot' ;;
    # why a ↻ row is waiting (issue #1370, @claude_wait) — the sidebar's selected-row line
    zh:wait_children)           printf '等子任务' ;;
    en:wait_children)           printf 'waiting on sub-tasks' ;;
    zh:wait_bg)                 printf '后台命令在跑' ;;
    en:wait_bg)                 printf 'background command running' ;;
    # the worker pane header's @title_info segments (issue #1377)
    zh:title_kids)              printf '子任务' ;;
    en:title_kids)              printf 'sub-tasks' ;;
    zh:title_loop)              printf 'Loop' ;;
    en:title_loop)              printf 'Loop' ;;
    zh:title_loop_fmt)          printf 'Loop 下次 %s' "${1:-}" ;;
    en:title_loop_fmt)          printf 'Loop next %s' "${1:-}" ;;
    zh:title_needs)             printf '要你处理：' ;;
    en:title_needs)             printf 'needs you: ' ;;
    zh:title_parent)            printf '父' ;;
    en:title_parent)            printf 'parent' ;;
    # which `!` a row is (issue #1328) — ≤ 8 display cells: the hub's act column
    zh:needs_ask)               printf '在问你' ;;
    en:needs_ask)               printf 'asking' ;;
    zh:needs_perm)              printf '等授权' ;;
    en:needs_perm)              printf 'perm' ;;
    zh:needs_blocked)           printf '被卡住' ;;
    en:needs_blocked)           printf 'blocked' ;;
    zh:needs_restore)           printf '恢复失败' ;;
    en:needs_restore)           printf 'restore' ;;
    zh:needs_failed)            printf '运行失败' ;;
    en:needs_failed)            printf 'failed' ;;
    zh:needs_other)             printf '要你处理' ;;
    en:needs_other)             printf 'needs' ;;
    zh:repo_none_tag)           printf '⇢无' ;;
    en:repo_none_tag)           printf '⇢none' ;;
    zh:remote_lost)             printf '失联' ;;
    en:remote_lost)             printf 'lost' ;;
    # the sidebar's machine status line + the lost group (issue #1475)
    zh:node_silent_fmt)         printf '%s 分钟没联系' "${1:-}" ;;
    en:node_silent_fmt)         printf 'silent %s min' "${1:-}" ;;
    zh:node_maint)              printf '维护中' ;;
    en:node_maint)              printf 'maintenance' ;;
    zh:lost_heading_fmt)        printf '─ %s 失联 %s 分钟 ─' "${1:-}" "${2:-}" ;;
    en:lost_heading_fmt)        printf '─ %s lost %s min ─' "${1:-}" "${2:-}" ;;
    zh:lost_heading_short_fmt)  printf '─ %s 失联 ─' "${1:-}" ;;
    en:lost_heading_short_fmt)  printf '─ %s lost ─' "${1:-}" ;;
    # the remote row's actions through the hub (issue #1487, EPIC #1479 C8)
    zh:remote_press_any)        printf '按任意键关闭…' ;;
    en:remote_press_any)        printf 'press any key to close…' ;;
    zh:remote_message_hint)     printf '输入要发给它的话（经入口 → 那台机器的 issue 桥，作为它的下一轮）；空行取消：' ;;
    en:remote_message_hint)     printf 'Type the message (hub → that machine'"'"'s issue bridge, its next turn); empty cancels:' ;;
    zh:remote_perm_prompt)      printf '它在等一个权限确认。  [y] 批准（只按这一次的 Yes）   [n] 拒绝   其它键取消' ;;
    en:remote_perm_prompt)      printf 'It is waiting on a permission prompt.  [y] approve (this one Yes)   [n] refuse   any other key cancels' ;;
    zh:remote_pick_prompt)      printf '回答第几项？（先在代理窗口里看题；1 / 1,3 / 多题用空格分开；权限弹窗答 y 或 n）空行取消：' ;;
    en:remote_pick_prompt)      printf 'Which option? (read the question in the proxy window first; 1 / 1,3 / several questions space-separated; a permission prompt takes y or n) empty cancels:' ;;
    zh:remote_sending)          printf '已交给入口，等那台机器确认…' ;;
    en:remote_sending)          printf 'handed to the hub, waiting for that machine to confirm…' ;;
    # the hub itself silent (issue #1483, EPIC #1479 C4): the menu's word, the action's refusal
    zh:hub_lost_fmt)            printf '入口失联 %s' "${1:-}" ;;
    en:hub_lost_fmt)            printf 'hub lost %s' "${1:-}" ;;
    zh:remote_hub_lost_fmt)     printf '入口失联 %s，稍后再试' "${1:-}" ;;
    en:remote_hub_lost_fmt)     printf 'hub lost %s — try again later' "${1:-}" ;;
    # a cross-machine certificate while the hub is down (issue #1630): refused at once, with the way round
    zh:peer_hub_lost_fmt)       printf '入口失联，机器间访问暂停；你可直接 `fleet %s` 进去' "${1:-}" ;;
    en:peer_hub_lost_fmt)       printf 'hub lost — machine-to-machine access paused; you can still go in directly with `fleet %s`' "${1:-}" ;;
    zh:pin_heading_fmt)         printf '置顶 (%s)' "${1:-}" ;;
    en:pin_heading_fmt)         printf 'Pinned (%s)' "${1:-}" ;;
    zh:attn_summary_fmt)        printf '! %s 个在问你 · 点这里跳过去 ⌃K' "${1:-}" ;;
    en:attn_summary_fmt)        printf '! %s need you · tap here ⌃K' "${1:-}" ;;
    zh:attn_summary_dash_fmt)   printf '! %s 个在问你' "${1:-}" ;;
    en:attn_summary_dash_fmt)   printf '! %s waiting on you' "${1:-}" ;;
    zh:unknown_repo_heading)    printf '? · 未知仓库' ;;
    en:unknown_repo_heading)    printf '? · unknown repo' ;;
    zh:no_repo)                 printf '无仓库' ;;
    en:no_repo)                 printf 'no repo' ;;
    zh:empty_sidebar)           printf '暂无会话 — 输入名称新建' ;;
    en:empty_sidebar)           printf 'No sessions — type a name' ;;
    zh:empty_dash_fmt)          printf '暂无会话 — 输入名称新建 · %s 新任务' "${1:-}" ;;
    en:empty_dash_fmt)          printf 'No sessions — type a name to start one · %s new task' "${1:-}" ;;
    zh:keys_sidebar_title)      printf '任务栏快捷键' ;;
    en:keys_sidebar_title)      printf 'Task Sidebar Keys' ;;
    zh:keys_close)              printf 'q / esc 关闭' ;;
    en:keys_close)              printf 'q / esc close' ;;
    # --- one popup / menu frame (issue #1535): dash-popup.sh's title row + the
    # last row of every menu. A popup title is 「动作 · 对象 · 机器」.
    zh:ui_close)                printf 'Esc 关闭' ;;
    en:ui_close)                printf 'Esc close' ;;
    zh:popup_refused)           printf 'fleet: 弹窗没打开 — 这个终端上已经有一个弹窗或菜单' ;;
    en:popup_refused)           printf 'fleet: popup not opened — this terminal already shows a popup or menu' ;;
    zh:popup_backlog)           printf '议题列表' ;;
    en:popup_backlog)           printf 'Backlog' ;;
    zh:popup_usage)             printf '用量与账号' ;;
    en:popup_usage)             printf 'Usage & accounts' ;;
    zh:popup_alerts)            printf '告警' ;;
    en:popup_alerts)            printf 'Alerts' ;;
    zh:popup_config)            printf '配置' ;;
    en:popup_config)            printf 'Config' ;;
    zh:popup_keys)              printf '快捷键' ;;
    en:popup_keys)              printf 'Keys' ;;
    zh:popup_tasks)             printf '任务' ;;
    en:popup_tasks)             printf 'Tasks' ;;
    zh:popup_new_task)          printf '新建任务' ;;
    en:popup_new_task)          printf 'New task' ;;
    zh:popup_answer)            printf '回答' ;;
    en:popup_answer)            printf 'Answer' ;;
    zh:popup_repo_add)          printf '添加仓库' ;;
    en:popup_repo_add)          printf 'Add repo' ;;
    zh:hint_alerts)             printf '↵ 处理 · 1✖ 2▲ 3● 0全部 · m 静音1h · [✕ 关闭]' ;;
    en:hint_alerts)             printf '↵ act · 1✖ 2▲ 3● 0 all · m mute 1h · [✕ close]' ;;
    zh:hint_usage)              printf '↵ 新会话用它 · Esc 取消 · [✕ 关闭]' ;;
    en:hint_usage)              printf '↵ new sessions use it · esc · [✕ close]' ;;
    zh:hint_backlog)            printf '↵ 开工 · [＋ 新建] · ? 键 · [✕ 关闭]' ;;
    en:hint_backlog)            printf '↵ work · [＋ new] · ? keys · [✕ close]' ;;
    zh:toast_url_copied_fmt)    printf 'fleet: 链接已复制到剪贴板 — %s' "${1:-}" ;;
    en:toast_url_copied_fmt)    printf 'fleet: link copied to your clipboard — %s' "${1:-}" ;;
    # --- toasts a tmux bind shows (issue #1535: no hardcoded English left)
    zh:toast_sidebar_home)      printf '任务栏：输入名称 ↵ 新会话 · ↑↓ 切换 · ↵/Esc 回任务 · 再按 ☰/F9 去 hub' ;;
    en:toast_sidebar_home)      printf 'Tasks: type a name ↵ = new session · ↑↓ switch · ↵/Esc worker · ☰/F9 again → hub' ;;
    zh:toast_sidebar_focus)     printf '任务栏：输入名称 ↵ 新会话 · . 行菜单 · ↑↓ 切换 · 空行 ←→ 折叠 · 有字时移光标 · ↵/Esc 回任务' ;;
    en:toast_sidebar_focus)     printf 'Tasks: type a name ↵ = new session · . = row menu · ↑↓ switch · empty line ←→ fold · with text ←→ move · ↵/Esc worker' ;;
    zh:toast_shell_sidebar)     printf '任务：↑↓ 切换 · ↵ 进入 · . 行菜单 · ? 快捷键 · Esc 返回' ;;
    en:toast_shell_sidebar)     printf 'Tasks: ↑↓ switch · ↵ enter · . row menu · ? keys · Esc back' ;;
    # the row menu's confirmed reap (fleet-sidebar-reap.sh), off dash-reap's token
    zh:reap_done)               printf 'fleet: 已回收' ;;
    en:reap_done)               printf 'fleet: reaped' ;;
    zh:reap_kept)               printf 'fleet: 已回收 — 脏 worktree 已保留在磁盘' ;;
    en:reap_kept)               printf 'fleet: reaped — dirty worktree kept on disk' ;;
    zh:reap_live)               printf 'fleet: 未回收 — agent 仍在运行（或太新）' ;;
    en:reap_live)               printf 'fleet: not reaped — the agent is still live (or too young)' ;;
    zh:reap_skip_fmt)           printf 'fleet: 未回收（%s）' "${1:-}" ;;
    en:reap_skip_fmt)           printf 'fleet: not reaped (%s)' "${1:-}" ;;
    zh:reap_refused_fmt)        printf 'fleet: 未回收 — %s' "${1:-}" ;;
    en:reap_refused_fmt)        printf 'fleet: not reaped — %s' "${1:-}" ;;
    zh:reap_none)               printf 'fleet: 回收没有返回结果 — 请查看 hub' ;;
    en:reap_none)               printf 'fleet: reap gave no result — check the hub' ;;
    # a remote row's action, named for its toast / popup (fleet-sidebar-remote.sh)
    zh:remote_label_stop_fmt)    printf '停 %s（在 %s）' "${1:-}" "${2:-}" ;;
    en:remote_label_stop_fmt)    printf 'stop %s (on %s)' "${1:-}" "${2:-}" ;;
    zh:remote_label_resume_fmt)  printf '继续 %s（在 %s）' "${1:-}" "${2:-}" ;;
    en:remote_label_resume_fmt)  printf 'resume %s (on %s)' "${1:-}" "${2:-}" ;;
    zh:remote_label_reap_fmt)    printf '回收 %s（在 %s）' "${1:-}" "${2:-}" ;;
    en:remote_label_reap_fmt)    printf 'reap %s (on %s)' "${1:-}" "${2:-}" ;;
    zh:remote_label_message_fmt) printf '发给 %s（在 %s）' "${1:-}" "${2:-}" ;;
    en:remote_label_message_fmt) printf 'message %s (on %s)' "${1:-}" "${2:-}" ;;
    zh:remote_label_answer_fmt)  printf '答 %s（在 %s）' "${1:-}" "${2:-}" ;;
    en:remote_label_answer_fmt)  printf 'answer %s (on %s)' "${1:-}" "${2:-}" ;;
    # --- the task sidebar's own strings (fleet-sidebar.py reads `dump sidebar_`)
    zh:sidebar_placeholder)     printf '新会话名…' ;;
    en:sidebar_placeholder)     printf 'New session name…' ;;
    zh:sidebar_help_row)        printf ' ? 快捷键' ;;
    en:sidebar_help_row)        printf ' ? keys' ;;
    zh:sidebar_new_to_fmt)      printf '新会话 → %s…' "${1:-}" ;;
    en:sidebar_new_to_fmt)      printf 'New session → %s…' "${1:-}" ;;
    zh:sidebar_rename)          printf '改名› ' ;;
    zh:sidebar_shell_local_only) printf '这台电脑上没有 fleet：新建 / 恢复请在机器上做' ;;
    en:sidebar_shell_local_only) printf 'no fleet on this computer — new / restore happen on a machine' ;;
    en:sidebar_rename)          printf 'rename› ' ;;
    zh:sidebar_refreshing)      printf '刷新中…' ;;
    en:sidebar_refreshing)      printf 'refreshing…' ;;
    zh:sidebar_landed_heading_fmt) printf '已落地 (%s) · ↵ 恢复' "${1:-}" ;;
    en:sidebar_landed_heading_fmt) printf 'Landed (%s) · ↵ restore' "${1:-}" ;;
    zh:sidebar_landed_empty)    printf '（还没有已落地的会话）' ;;
    en:sidebar_landed_empty)    printf '(no landed sessions yet)' ;;
    zh:sidebar_landed_loading)  printf '已落地 …' ;;
    en:sidebar_landed_loading)  printf 'Landed …' ;;
    zh:sidebar_spawn_failed)    printf '创建失败' ;;
    en:sidebar_spawn_failed)    printf 'spawn failed' ;;
    # the questions asked on the input line instead of a popup (issue #1620)
    zh:sidebar_ask_new)         printf '新任务› ' ;;
    en:sidebar_ask_new)         printf 'task› ' ;;
    zh:sidebar_ask_to_fmt)      printf '→ %s' "${1:-}" ;;
    en:sidebar_ask_to_fmt)      printf '→ %s' "${1:-}" ;;
    zh:sidebar_ask_tab)         printf ' · Tab 换' ;;
    en:sidebar_ask_tab)         printf ' · Tab next' ;;
    zh:sidebar_ask_repo)        printf '仓库› ' ;;
    en:sidebar_ask_repo)        printf 'repo› ' ;;
    zh:sidebar_ask_repo_hint)   printf 'owner/name 或网址 · ↵ 加入' ;;
    en:sidebar_ask_repo_hint)   printf 'owner/name or URL · ↵ adds' ;;
    zh:sidebar_ask_message)     printf '消息› ' ;;
    en:sidebar_ask_message)     printf 'message› ' ;;
    zh:sidebar_ask_answer)      printf '回答› ' ;;
    en:sidebar_ask_answer)      printf 'answer› ' ;;
    zh:sidebar_ask_answer_hint) printf '选项号，或 y / n' ;;
    en:sidebar_ask_answer_hint) printf 'option number(s), or y / n' ;;
    zh:sidebar_ask_perm_hint)   printf '允许？y / n' ;;
    en:sidebar_ask_perm_hint)   printf 'allow? y / n' ;;
    zh:sidebar_ask_sub)         printf '切到› ' ;;
    en:sidebar_ask_sub)         printf 'switch to› ' ;;
    zh:sidebar_ask_sub_loading) printf '读额度…' ;;
    en:sidebar_ask_sub_loading) printf 'reading quota…' ;;
    zh:sidebar_ask_sub_hint)    printf 'Tab 选账号 · ↵ 迁移' ;;
    en:sidebar_ask_sub_hint)    printf 'Tab picks an account · ↵ moves' ;;
    zh:sidebar_ask_restore)     printf 'y 先 reopen · r 直接恢复› ' ;;
    en:sidebar_ask_restore)     printf 'y reopen first · r restore› ' ;;
    # --- the row menu (fleet-sidebar-menu.sh). menu_keys is THE letter table:
    # `action<TAB>letter<TAB>what`, read by the menu (mk) and the ? sheet (--keys).
    zh:menu_keys)               printf '%s' 'rename	r	改名 — 在输入行编辑（↵ 应用，esc / 空名称取消）
pin	t	置顶 / 取消置顶
pr	p	打开 PR（没有时置灰）
answer	a	回答提问 — 跳到那个会话，在它自己的提问里答（红色 ? 行；否则置灰）
sub	s	切换 sub — 在输入行写账号，Tab 逐个看额度，↵ 迁移
wake	w	唤醒睡眠中的 z 行（仅睡眠时显示）
awake	k	保持唤醒 ⇄ 允许再次休眠
agent	v	新会话 claude ⇄ codex
reap	x	回收 — 先确认 y/n（别机行：经入口让那台机器回收）
new	n	新任务 — 在输入行写标题（多仓库 Tab 换仓库），↵ 建 issue 并启动 worker
newto	1-9	新建到 <机器>… — 入口在线的别的机器各一项：建 issue，worker 开在那台机器上
restore	o	恢复已收工任务 — 任务栏就地换成已落地列表（同 ⌃t）
repo	g	添加仓库到这个 fleet — 在输入行写 owner/name；~/projects/<name>，缺失时 clone（hub ⌃z）
open	e	进入 — 打开代理窗口（只有另一台机器上的行有；菜单标题写着「· m4」）
message	m	发消息… — 只有别机行有：在输入行写，经入口送到那台机器的 issue 桥，作为它的下一轮
stop	q	停 — 只有别机行有：经入口让那台机器上的会话 /exit（可恢复）
resume	c	继续 — 只有别机行有：经入口恢复刚停掉的会话（活着的会被拒绝并告诉你）' ;;
    en:menu_keys)               printf '%s' 'rename	r	rename — edits on the input line (↵ applies, esc / an empty name cancels)
pin	t	pin / unpin the row to the top
pr	p	open its PR (greyed when it has none)
answer	a	answer its question — jumps to that session, to answer in its own picker (a red ? row; greyed otherwise)
sub	s	switch subscription — the account on the input line, Tab through them with their quota, ↵ moves
wake	w	wake a sleeping (z) row now — only listed on one
awake	k	keep it awake ⇄ allow it to sleep again
agent	v	flip new sessions claude ⇄ codex
reap	x	reap it — asks y/n first (a row on another machine: through the hub, there)
new	n	new task — its title on the input line (Tab picks the repo in a 2+ repo fleet), ↵ files the issue AND spawns its worker
newto	1-9	new task on <machine>… — one per other machine the hub says is online: file the issue, open the worker there
restore	o	restore a finished task — the sidebar shows the landed list in place (as ⌃t)
repo	g	add a repo to this fleet — owner/name on the input line; ~/projects/<name>, cloned if missing (the hub ⌃z)
open	e	enter — open the proxy window (a row on another machine only; the menu title says · m4)
message	m	message… — a row on another machine only: typed on the input line, through the hub to the issue bridge on that machine, as its next turn
stop	q	stop — a row on another machine only: /exit there through the hub (resumable)
resume	c	resume — a row on another machine only: reopen a just-stopped one through the hub (a live one is refused, and says so)' ;;
    zh:menu_open_remote)        printf '进入（代理窗口）…' ;;
    en:menu_open_remote)        printf 'Enter (proxy window)…' ;;
    zh:menu_r_message)          printf '发消息…' ;;
    en:menu_r_message)          printf 'Message…' ;;
    zh:menu_r_stop)             printf '停（/exit）' ;;
    en:menu_r_stop)             printf 'Stop (/exit)' ;;
    zh:menu_r_resume)           printf '继续（恢复）' ;;
    en:menu_r_resume)           printf 'Resume' ;;
    zh:menu_r_answer)           printf '答授权 / 回答…' ;;
    en:menu_r_answer)           printf 'Answer prompt…' ;;
    zh:menu_r_answer_none)      printf '答授权 / 回答（没有在等）' ;;
    en:menu_r_answer_none)      printf 'Answer prompt (nothing waiting)' ;;
    zh:menu_r_reap_confirm_fmt) printf '回收「%s」（在 %s）？(y/n)' "${1:-}" "${2:-}" ;;
    en:menu_r_reap_confirm_fmt) printf 'Reap "%s" (on %s)? (y/n)' "${1:-}" "${2:-}" ;;
    zh:menu_newto_fmt)          printf '新建到 %s…' "${1:-}" ;;
    en:menu_newto_fmt)          printf 'New task on %s…' "${1:-}" ;;
    zh:menu_rename)             printf '改名…' ;;
    en:menu_rename)             printf 'Rename…' ;;
    zh:menu_unpin)              printf '取消置顶' ;;
    en:menu_unpin)              printf 'Unpin' ;;
    zh:menu_pin)                printf '置顶' ;;
    en:menu_pin)                printf 'Pin' ;;
    zh:menu_open_pr)            printf '打开 PR' ;;
    en:menu_open_pr)            printf 'Open PR' ;;
    zh:menu_open_pr_none)       printf '打开 PR（没有）' ;;
    en:menu_open_pr_none)       printf 'Open PR (none)' ;;
    zh:menu_answer)             printf '回答它的提问…' ;;
    en:menu_answer)             printf 'Answer question…' ;;
    zh:menu_answer_none)        printf '回答它的提问（没有）' ;;
    en:menu_answer_none)        printf 'Answer question (none)' ;;
    zh:menu_sub)                printf '切换 sub（选账号）…' ;;
    en:menu_sub)                printf 'Switch subscription (choose account)…' ;;
    zh:menu_sub_none)           printf '切换 sub（先选运行中的 Claude worker）' ;;
    en:menu_sub_none)           printf 'Switch subscription (select a running Claude worker)' ;;
    zh:menu_wake)               printf '唤醒' ;;
    en:menu_wake)               printf 'Wake' ;;
    zh:menu_allow_sleep)        printf '允许休眠' ;;
    en:menu_allow_sleep)        printf 'Allow sleep' ;;
    zh:menu_keep_awake)         printf '保持唤醒' ;;
    en:menu_keep_awake)         printf 'Keep awake' ;;
    zh:menu_agent_fmt)          printf '新会话改用 %s' "${1:-}" ;;
    en:menu_agent_fmt)          printf 'New sessions use %s' "${1:-}" ;;
    zh:menu_reap)               printf '回收…' ;;
    en:menu_reap)               printf 'Reap…' ;;
    zh:menu_reap_confirm_fmt)   printf '回收「%s」？(y/n)' "${1:-}" ;;
    en:menu_reap_confirm_fmt)   printf 'Reap "%s"? (y/n)' "${1:-}" ;;
    zh:menu_new)                printf '新建任务（建 issue）…' ;;
    en:menu_new)                printf 'New task (file issue)…' ;;
    zh:menu_restore)            printf '恢复已收工…' ;;
    en:menu_restore)            printf 'Restore finished task…' ;;
    zh:menu_repo)               printf '＋ 仓库…' ;;
    en:menu_repo)               printf 'Add repo…' ;;
    # --- the key sheet (fleet-keys.sh): its frame, then one entry per row
    zh:keys_title)              printf 'fleet 快捷键' ;;
    en:keys_title)              printf 'fleet keymap' ;;
    zh:keys_sub_dash)           printf '（仪表盘面板 · tmux 前缀键也可用 · q/esc 关闭）' ;;
    en:keys_sub_dash)           printf '(dashboard panel · prefix binds work here too · q/esc to close)' ;;
    zh:keys_sub_backlog)        printf '（议题列表面板 · tmux 前缀键也可用 · q/esc 关闭）' ;;
    en:keys_sub_backlog)        printf '(backlog panel · prefix binds work here too · q/esc to close)' ;;
    zh:keys_sub_all_fmt)        printf '（prefix = tmux 前缀键，本机为 %s · q/esc 关闭）' "${1:-}" ;;
    en:keys_sub_all_fmt)        printf '(prefix = your tmux prefix, %s here · q/esc to close)' "${1:-}" ;;
    zh:keys_dn_remapped_fmt)    printf ' — （⌥ 替代：⌃%s 是你的 tmux 前缀 %s）' "${1:-}" "${2:-}" ;;
    en:keys_dn_remapped_fmt)    printf ' — (⌥ fallback: ⌃%s is your tmux prefix %s)' "${1:-}" "${2:-}" ;;
    zh:keys_dn_unreachable_fmt) printf ' — （按不到：%s 是你的 tmux 前缀 %s，它的 ⌥ 也是）' "${1:-}" "${2:-}" ;;
    en:keys_dn_unreachable_fmt) printf ' — (UNREACHABLE: %s is your tmux prefix %s and its ⌥ twin is one too)' "${1:-}" "${2:-}" ;;
    # the task sidebar's one-screen sheet (`--context sidebar`, issue #963)
    zh:keys_sb_type_k)          printf '打字 ↵' ;;
    en:keys_sb_type_k)          printf 'type ↵' ;;
    zh:keys_sb_type)            printf '起新会话' ;;
    en:keys_sb_type)            printf 'new session' ;;
    zh:keys_sb_switch)          printf '切换任务' ;;
    en:keys_sb_switch)          printf 'switch task' ;;
    zh:keys_sb_edit_k)          printf '编辑' ;;
    en:keys_sb_edit_k)          printf 'edit' ;;
    zh:keys_sb_menu_k_fmt)      printf '%s / 再点一次' "${1:-}" ;;
    en:keys_sb_menu_k_fmt)      printf '%s / tap again' "${1:-}" ;;
    zh:keys_sb_menu)            printf '任务菜单' ;;
    en:keys_sb_menu)            printf 'task menu' ;;
    zh:keys_sb_esc)             printf '键盘还给任务' ;;
    en:keys_sb_esc)             printf 'return keys to task' ;;
    zh:keys_sb_more)            printf '临时会话 · 已落地 · 刷新 · 详情' ;;
    en:keys_sb_more)            printf 'scratch · landed · reload · info' ;;
    zh:keys_sb_home)            printf '进任务栏；F9 再按隐藏' ;;
    en:keys_sb_home)            printf 'enter sidebar; F9 again hides' ;;
    zh:keys_sb_all_fmt)         printf '全部按键（prefix = %s）' "${1:-}" ;;
    en:keys_sb_all_fmt)         printf 'all keys (prefix = %s)' "${1:-}" ;;
    # the full sheet, one row each (fleet-keys.sh print_sheet; generated from
    # the two sheets it replaced, row for row)
    zh:keys_g_prefix)          printf %s 'tmux 前缀' ;;
    en:keys_g_prefix)          printf %s 'tmux prefix' ;;
    zh:keys_g_prefix_sub)      printf %s '— 客户端（fleet）里任意窗口可用' ;;
    en:keys_g_prefix_sub)      printf %s '— in the client (fleet), from any window' ;;
    zh:keys_prefix_02)         printf %s '同 prefix E：聚焦任务列表' ;;
    en:keys_prefix_02)         printf %s 'the task list, focused — as prefix E' ;;
    zh:keys_prefix_04)         printf %s '聚焦任务列表：↑↓ 切换 · ↵ 进入 · . 行菜单 · Esc 交还键盘' ;;
    en:keys_prefix_04)         printf %s 'focus the task list — ↑↓ switch · ↵ enter · . row menu · esc hands the keyboard back; then type: see the '"'"'task sidebar'"'"' group' ;;
    zh:keys_prefix_05)         printf %s '回到上一台机器（上一个窗口）' ;;
    en:keys_prefix_05)         printf %s 'back to the machine you were on (the previous window)' ;;
    zh:keys_prefix_06)         printf %s '同 prefix E：聚焦任务列表' ;;
    en:keys_prefix_06)         printf %s 'the task list, focused — as prefix E' ;;
    zh:keys_prefix_09)         printf %s '缩放会话窗格；键盘在任务列表上时也是缩放会话并交还键盘' ;;
    en:keys_prefix_09)         printf %s 'zoom the session pane — from the task list too: it zooms the SESSION and hands the keyboard back, never the list' ;;
    zh:keys_prefix_10)         printf %s '查看会话滚屏（tmux copy-mode）；键盘在任务列表上时同样作用于会话' ;;
    en:keys_prefix_10)         printf %s 'scroll back the session (tmux copy-mode) — from the task list too: it opens on the SESSION and hands the keyboard back' ;;
    zh:keys_prefix_16)         printf %s '跳到下一个在问你的任务并切过去（键盘不用在任务列表上；点列表顶部「! N 个在问你」那一行也一样）' ;;
    en:keys_prefix_16)         printf %s 'jump to the next task waiting on you and switch to it — the keyboard need not be on the task list; a tap on the list'"'"'s top line「! N need you」does the same' ;;
    zh:keys_prefix_13)         printf %s '打开这份快捷键' ;;
    en:keys_prefix_13)         printf %s 'this cheatsheet' ;;
    zh:keys_prefix_14)         printf %s '无前缀：缩放右侧会话窗格（本机窗格，按键不会传到远端）' ;;
    en:keys_prefix_14)         printf %s '(no prefix) zoom the session pane on the right — this computer'"'"'s pane; the key never reaches the far end' ;;
    zh:keys_prefix_15)         printf %s '在 shell 叫回上手向导，从上次进度继续' ;;
    en:keys_prefix_15)         printf %s 'from a shell, reopen the onboarding guide at its saved progress' ;;
    zh:keys_g_sidebar)         printf %s '任务栏' ;;
    en:keys_g_sidebar)         printf %s 'task sidebar' ;;
    zh:keys_g_sidebar_sub)     printf %s '— prefix E 或点击任务栏后可用' ;;
    en:keys_g_sidebar_sub)     printf %s '— once prefix E or a tap puts the keyboard on it' ;;
    zh:keys_sidebar_01k)       printf %s '输入名称' ;;
    en:keys_sidebar_01k)       printf %s 'type a name' ;;
    zh:keys_sidebar_01)        printf %s '在底部输入行编辑；支持中文、空格、粘贴；回车新建 scratch 并切过去' ;;
    en:keys_sidebar_01)        printf %s 'fills the ONE input line at the bottom at its cursor ▏ — every letter types (q n j k too), CJK fine; backspace deletes before the cursor, delete after it, ⌃u clears. Rename edits the same way' ;;
    zh:keys_sidebar_02k)       printf %s '粘贴' ;;
    en:keys_sidebar_02k)       printf %s 'paste' ;;
    zh:keys_sidebar_02)        printf %s '终端粘贴（⌘v）也落在输入行，作为一个名称——换行变空格、不会提交；键盘在任务栏时 worker 收不到' ;;
    en:keys_sidebar_02)        printf %s 'a terminal paste (⌘v) lands on the input line too, as ONE name — newlines become spaces, nothing is submitted; the worker sees none of it while the keyboard is here' ;;
    zh:keys_sidebar_03)        printf %s '有名称：新建 scratch；空行：把键盘还给 worker' ;;
    en:keys_sidebar_03)        printf %s 'with a name: start a scratch session named after it (the hub'"'"'s ⌃s) and switch to it — no popup, no hub. A refusal (cap, worktree) shows on the line and keeps the name. Empty line: give input back to the worker' ;;
    zh:keys_sidebar_04)        printf %s '清空输入；空行时把键盘还给 worker' ;;
    en:keys_sidebar_04)        printf %s 'clear the typed name; on an empty line give input back to the worker' ;;
    zh:keys_sidebar_05)        printf %s '选择任务；停顿后切换到选中任务' ;;
    en:keys_sidebar_05)        printf %s 'switch to the highlighted task (follows once you pause, ~¼s; a held key is one switch, a row passed over is never selected); on an EMPTY line home/end the ends' ;;
    zh:keys_sidebar_06)        printf %s '有文字时移动光标；空行时折叠/展开选中行或仓库组' ;;
    en:keys_sidebar_06)        printf %s 'with text: move the cursor (home/end: to the line'"'"'s start/end). On an EMPTY line: fold / unfold the highlighted row'"'"'s subtree — or, on a repo heading, that repo'"'"'s whole group (`▸ tokenledger (2)` is a folded one) — the hub'"'"'s rule' ;;
    zh:keys_sidebar_07)        printf %s '按词移动光标' ;;
    en:keys_sidebar_07)        printf %s 'move the cursor a word left / right (the terminal'"'"'s ESC b / ESC f or ⌥-arrow)' ;;
    zh:keys_sidebar_08)        printf %s '光标到行首' ;;
    en:keys_sidebar_08)        printf %s 'cursor to the start of the line' ;;
    zh:keys_sidebar_09)        printf %s '光标到行尾' ;;
    en:keys_sidebar_09)        printf %s 'cursor to the end of the line' ;;
    zh:keys_sidebar_10)        printf %s '删除光标前一个词' ;;
    en:keys_sidebar_10)        printf %s 'delete the word before the cursor' ;;
    zh:keys_sidebar_11)        printf %s '有文字时删除光标到行尾；空行时跳到下一个在问你的任务（同点顶部汇总行、prefix k）' ;;
    en:keys_sidebar_11)        printf %s 'with text: delete from the cursor to the end of the line. On an EMPTY line: jump to the next task waiting on you (red !), in list order — as a tap on the top summary line, or prefix k' ;;
    zh:keys_sidebar_12k)       printf %s '点仓库标题' ;;
    en:keys_sidebar_12k)       printf %s 'tap a heading' ;;
    zh:keys_sidebar_12)        printf %s '2+ 仓库、看全部时：点一下仓库标题只选中它（不切换），输入行写着它——这时输入名称或新任务都建在那个仓库；再点一次在输入行写钉在该仓库的新任务标题。「无仓库」= $HOME；esc 或点任务行清除' ;;
    en:keys_sidebar_12)        printf %s '2+ repos, viewing all: a tap on a repo heading selects it (no switch) and the input line names it — a typed name or new task starts THERE; tap it again for a new task'"'"'s title on the input line, pinned to that repo. '"'"'no repo'"'"' = $HOME; esc or a tap on a task clears it' ;;
    zh:keys_sidebar_13)        printf %s '新任务：在输入行写标题，↵ 创建 issue 并启动 worker' ;;
    en:keys_sidebar_13)        printf %s 'new task — its title on the input line (Tab picks the repo in a 2+ repo fleet, ⌃s makes it a scratch instead); ↵ files an issue AND spawns its worker' ;;
    zh:keys_sidebar_14)        printf %s '空行时打开选中任务菜单；输入名称时就是普通点号' ;;
    en:keys_sidebar_14)        printf %s 'on an EMPTY line: the highlighted task'"'"'s menu — rename (edits on this line: ↵ applies, esc/empty cancels) · pin · open PR · answer its question · flip new sessions claude⇄codex · reap (asks y/n first) · new task. Inside a name it types a dot. Touch: tap the highlighted row again' ;;
    zh:keys_sidebar_15)        printf %s '恢复已收工任务 — 就地换成已落地列表（同 ⌃t）' ;;
    en:keys_sidebar_15)        printf %s 'restore a finished task — the landed list, in place (as ⌃t); ↵ brings it back as the current window (a closed-unmerged PR asks y / r on the input line first). Touch: the row menu'"'"'s last item' ;;
    zh:keys_sidebar_16)        printf %s '空行时打开任务栏快捷键；输入名称时就是普通问号' ;;
    en:keys_sidebar_16)        printf %s 'on an EMPTY line, or a tap on the '"'"'? 快捷键'"'"' row above it: this sidebar'"'"'s key sheet. Inside a name it types a ?' ;;
    zh:keys_sidebar_18)         printf %s '立即开一个临时会话 — 同 hub 的 ⌃s：不命名（输入行有字就用它命名），开在选中行的仓库，并切过去。被拒（上限、worktree）写在输入行' ;;
    en:keys_sidebar_18)         printf %s 'a scratch session NOW — the hub'"'"'s ⌃s: unnamed (a typed name, if any, names it), in the highlighted row'"'"'s repo, and it becomes the current window. A refusal (cap, worktree) shows on the input line' ;;
    zh:keys_sidebar_19)         printf %s '运行中 ⇄ 已落地，就地切换 — 同 hub 的 ⌃t：已落地列表（fleet-history.sh rows）占用任务栏的行；在一行上 ↵（或再点一次）把它恢复为当前窗口，列表回到运行中。⌃o 同此' ;;
    en:keys_sidebar_19)         printf %s 'running ⇄ landed, in place — the hub'"'"'s ⌃t: the landed list (fleet-history.sh rows) takes the sidebar'"'"'s rows; ↵ (or a second tap) on one restores it as the current window and the list goes back to running. ⌃o does the same' ;;
    zh:keys_sidebar_20)         printf %s '立即重读当前列表（已落地列表也算）— 同 hub 的 ⌃r' ;;
    en:keys_sidebar_20)         printf %s 're-read the shown list now (the landed one included) — the hub'"'"'s ⌃r' ;;
    zh:keys_sidebar_21)         printf %s 'Tab 键：展开 / 收起信息列 — 每行的单号 · PR · 上下文%，右对齐，同 hub 的三格。默认收起（名称优先占宽）；展开时任务栏最宽到 FLEET_SIDEBAR_WIDTH_MAX，再宽就让名称让位' ;;
    en:keys_sidebar_21)         printf %s 'the Tab key: open / fold the info column — each row'"'"'s issue · PR · ctx%, right-aligned, the hub'"'"'s three cells. Folded by default (the names get the width); open, the sidebar widens up to FLEET_SIDEBAR_WIDTH_MAX and the names give way past that' ;;
    zh:keys_g_menu)            printf %s '行菜单' ;;
    en:keys_g_menu)            printf %s 'row menu' ;;
    zh:keys_g_menu_sub)        printf %s '— 在任务栏按 . 或再次点击选中行' ;;
    en:keys_g_menu_sub)        printf %s '— after . or a second tap on the highlighted row: press its letter' ;;
    zh:keys_g_dashboard)       printf %s '仪表盘' ;;
    en:keys_g_dashboard)       printf %s 'dashboard' ;;
    zh:keys_g_dashboard_sub)   printf %s '— hub 的 dash 面板内（prefix g）' ;;
    en:keys_g_dashboard_sub)   printf %s '— inside the hub dash pane (prefix g)' ;;
    zh:keys_dashboard_01)      printf %s '跳到高亮窗口' ;;
    en:keys_dashboard_01)      printf %s 'jump to the highlighted window' ;;
    zh:keys_dashboard_02)      printf %s '展开/折叠高亮行的子树；在仓库标题上折叠/展开整个仓库组' ;;
    en:keys_dashboard_02)      printf %s 'unfold / fold the highlighted row'"'"'s subtree. A session spawned from another one nests under it (└ indent, one level per generation), and those children are COLLAPSED BY DEFAULT, every level on its own — the parent row'"'"'s `3/5` badge is what the folded block says, so the list stays one line per parent. → opens the block you are on, ← shuts the block you are IN (from the parent row or from any child in it, which puts the cursor back on the parent). A child in `needs` NEVER folds away — the red `!` (its act cell says which: 在问你 question · 等授权 permission · 被卡住 worker-declared blocker, read the issue · 恢复失败 · 运行失败) — because the quiet layer folds and the loud one does not. ▸ / ▾ on a row marks a folded / open block. On a REPO HEADING (a 2+ repo fleet'"'"'s `tokenledger (2)`) the same keys fold and unfold that repo'"'"'s whole group — ← leaves the heading alone as `▸ tokenledger (2)`, its count still the rows it hides, → brings them back; a `needs` row shows through here too. The closed view (⌃t) nests and folds the same way, off the ledger'"'"'s own record of what spawned what. With text typed on the prompt line, ←/→ are that line'"'"'s cursor keys as always' ;;
    zh:keys_dashboard_03)      printf %s '左侧 id 是窗口句柄，可给 fleet-migrate.sh / dash-reap.sh 等命令使用' ;;
    en:keys_dashboard_03)      printf %s 'the leftmost id column is that WINDOW'"'"'s handle (a1…z9) — unique in this fleet, it survives a migrate/handoff, and it is accepted wherever a window target is: `fleet-migrate.sh b3`, `dash-reap.sh a1`. Freed for reuse once the window is gone; the landed view has none (⌃t shows `·`)' ;;
    zh:keys_dashboard_04k)     printf %s '输入名称, enter' ;;
    en:keys_dashboard_04k)     printf %s 'type a name, enter' ;;
    zh:keys_dashboard_04)      printf %s '按输入文本新建 scratch，文本会预填为未发送草稿；中文和空格都支持' ;;
    en:keys_dashboard_04)      printf %s 'scratch named after the text, full text prefilled as an UNSENT draft; CJK + spaces fine, title capped at 24 cols (esc clears the dash input)' ;;
    zh:keys_dashboard_05)      printf %s '新 issue：创建 issue 并启动 worker' ;;
    en:keys_dashboard_05)      printf %s 'new issue — file one AND spawn its worker (quick-dispatch)' ;;
    zh:keys_dashboard_06)      printf %s '立即新建 raw scratch 会话' ;;
    en:keys_dashboard_06)      printf %s 'raw scratch session — spawns instantly (the fleet'"'"'s default agent in its own scratch-N worktree, no issue, no prompt)' ;;
    zh:keys_dashboard_07)      printf %s '切换新会话默认 agent（claude ⇄ codex），写入当前 fleet 配置' ;;
    en:keys_dashboard_07)      printf %s 'flip this fleet'"'"'s default agent for NEW sessions (claude ⇄ codex) — the prompt line shows it (claude ▸ / codex ▸); written to the fleet'"'"'s conf, so every spawn path follows — this key, prefix+c or FLEET_AGENT in the conf are the ways to pick it (no prompt-line prefix)' ;;
    zh:keys_dashboard_08)      printf %s '重命名高亮窗口；在查询行内编辑' ;;
    en:keys_dashboard_08)      printf %s 'rename the highlighted window — edit inline on the query line (↵ commits · esc cancels)' ;;
    zh:keys_dashboard_09)      printf %s '处理红色 needs 行：回答问题或查看权限阻塞详情' ;;
    en:keys_dashboard_09)      printf %s 'deal with the highlighted red row. A question row (act cell 在问你) is an AskUserQuestion: a tappable list per question, one tap each (issue #605) — and the ONLY way to answer one, since a SendMessage is delivered between turns and a pending question IS the turn, so the message waits for the answer that waits for the message. A permission row (等授权) is a PERMISSION prompt: this SHOWS you the blocked command and the reason it was stopped, without attaching to the pane (issue #640) — approving one is a human decision and nothing here will press Yes. Either way nothing is typed unless the chosen option is visibly on the worker'"'"'s screen' ;;
    zh:keys_dashboard_10)      printf %s '回收完成的 worker；必要时确认，脏 worktree 会保留' ;;
    en:keys_dashboard_10)      printf %s 'reap a finished worker (window + worktree + issue) — confirms when the row isn'"'"'t merged+clean. Targets: @window-id, %pane-id, registered handle, issue-N or scratch-N; indexes/names are refused. From a SCRIPT: `dash-reap.sh <handle> --yes` takes that confirm branch unasked (a dirty worktree is still KEPT) and prints a result token (`reaped:full`/`reaped:keep`/`skip:needs-confirm`/`refused:<slug>`); with no client attached it never pops a box at you' ;;
    zh:keys_dashboard_11)      printf %s '把高亮会话迁移到另一个有余量的账号' ;;
    en:keys_dashboard_11)      printf %s 'move the highlighted session onto another subscription account NOW — the unstick for a `⚠ stuck` row (issue #873). It asks y/n on the status line, then fleet-migrate'"'"'s own dry-run decides; y closes it (/exit), stops those commands, and resumes the same transcript in a new window on the account with headroom, the stopped commands named in its first prompt. Refuses when no account has room (every one benched) — it never bounces a session onto another wall. Same as `fleet-account.sh migrate --force-bg <window>`; `migrate --stuck` moves every stuck row' ;;
    zh:keys_dashboard_12)      printf %s '置顶/取消置顶高亮窗口；置顶行显示在最上方' ;;
    en:keys_dashboard_12)      printf %s 'pin/unpin the highlighted window to the TOP of the list — a pin beats the status sort (a pinned idle row sits above a red one), so the session you are deliberately watching stays where you left it. Pinned rows move to the 置顶 group at the very top (a thin line closes it; ←/→ on its heading folds it); pinning a PARENT floats its children with it, still nested. The pin lives on the tmux window, so it vanishes with the window — nothing to clean up' ;;
    zh:keys_dashboard_13)      printf %s '给当前 fleet 添加仓库' ;;
    en:keys_dashboard_13)      printf %s 'add a repo to this fleet (issue #1103) — a popup asks just owner/name (a GitHub URL is fine) and runs `fleet-repo.sh add`: the checkout is ~/projects/<name>, reused when it already is that repo, cloned when missing (the clone'"'"'s progress shows in the popup); the verdict stays up until you dismiss it (↵ / esc / [✕ close]) — added · already hosted · the dir is another repo · clone failed. No restart: the repo'"'"'s heading is on the dash'"'"'s next frame and the background daemons pick it up within a tick. Also the task sidebar'"'"'s row menu `g`. A different checkout dir still needs the shell form, `bin/fleet-repo.sh add <owner/name> <dir>`' ;;
    zh:keys_dashboard_14)      printf %s '切换 live / closed 视图' ;;
    en:keys_dashboard_14)      printf %s 'toggle live ⇄ closed (finished sessions + scratch)' ;;
    zh:keys_dashboard_15)      printf %s '恢复高亮的已收工会话' ;;
    en:keys_dashboard_15)      printf %s 'restore the highlighted landed session into a new window (claude --resume)' ;;
    zh:keys_dashboard_16)      printf '恢复高亮 landed 会话' ;;
    en:keys_dashboard_16)      printf 'resume the highlighted landed session — same as %s' "${1:-}" ;;
    zh:keys_dashboard_17)      printf %s '在浏览器打开 landed 行的 PR' ;;
    en:keys_dashboard_17)      printf %s 'open the highlighted landed row'"'"'s PR in the browser' ;;
    zh:keys_dashboard_18)      printf %s '立即刷新' ;;
    en:keys_dashboard_18)      printf %s 'refresh now' ;;
    zh:keys_dashboard_19)      printf %s '空查询行时打开这份快捷键' ;;
    en:keys_dashboard_19)      printf %s 'this cheatsheet — on an EMPTY prompt line (with text typed, ? is just a character)' ;;
    zh:keys_dashboard_20)      printf %s '重启 dash（hub 面板常驻）' ;;
    en:keys_dashboard_20)      printf %s 'relaunch the dash (it'"'"'s the always-on hub pane)' ;;
    zh:keys_g_backlog)         printf %s '议题列表' ;;
    en:keys_g_backlog)         printf %s 'backlog' ;;
    zh:keys_g_backlog_sub)     printf %s '— 议题列表弹窗内' ;;
    en:keys_g_backlog_sub)     printf %s '— inside the backlog popup' ;;
    zh:keys_backlog_01)        printf %s '显示/隐藏预览窗（正文、标签、评论）' ;;
    en:keys_backlog_01)        printf %s 'toggle the preview pane (body/labels/comments) — off by default' ;;
    zh:keys_backlog_02)        printf %s '筛选 issues' ;;
    en:keys_backlog_02)        printf %s 'filter issues (type to narrow; off by default)' ;;
    zh:keys_backlog_03)        printf %s '启动高亮 issue 的 worker' ;;
    en:keys_backlog_03)        printf %s 'work the issue — spawn its session' ;;
    zh:keys_backlog_04)        printf %s '创建新 issue' ;;
    en:keys_backlog_04)        printf %s 'file a new issue' ;;
    zh:keys_backlog_05)        printf %s '关闭高亮 issue（y/n 确认）' ;;
    en:keys_backlog_05)        printf %s 'close the highlighted issue (y/n confirm)' ;;
    zh:keys_backlog_06)        printf %s '循环优先级标签（无→p2→p1→p0→无）' ;;
    en:keys_backlog_06)        printf %s 'cycle the issue'"'"'s priority label (none→p2→p1→p0→none)' ;;
    zh:keys_backlog_07)        printf %s '在网页打开 issue' ;;
    en:keys_backlog_07)        printf %s 'open the issue on the web' ;;
    zh:keys_backlog_08)        printf %s '立即刷新' ;;
    en:keys_backlog_08)        printf %s 'refresh now' ;;
    zh:keys_backlog_09)        printf %s '打开这份快捷键' ;;
    en:keys_backlog_09)        printf %s 'this cheatsheet' ;;
    zh:keys_backlog_10)        printf %s '关闭' ;;
    en:keys_backlog_10)        printf %s 'close' ;;
    zh:keys_g_config)          printf %s '配置弹窗' ;;
    en:keys_g_config)          printf %s 'config modal' ;;
    zh:keys_g_config_sub)      printf %s '— 配置弹窗内' ;;
    en:keys_g_config_sub)      printf %s '— inside the config popup' ;;
    zh:keys_config_01)         printf %s '编辑高亮配置项 / 展开分组' ;;
    en:keys_config_01)         printf %s 'edit the highlighted key / expand the section' ;;
    zh:keys_config_02)         printf %s '展开/折叠分组' ;;
    en:keys_config_02)         printf %s 'expand/collapse a section' ;;
    zh:keys_config_03)         printf %s '切换写入范围（当前 fleet ⇄ repo）' ;;
    en:keys_config_03)         printf %s 'toggle the write scope (this fleet ⇄ repo)' ;;
    zh:keys_config_04)         printf %s '显示/隐藏详情预览' ;;
    en:keys_config_04)         printf %s 'toggle the detail preview' ;;
    zh:keys_config_05)         printf %s '显示原始 FLEET_* 键名' ;;
    en:keys_config_05)         printf %s 'reveal the raw FLEET_* keys inline' ;;
    zh:keys_config_06)         printf %s '立即刷新' ;;
    en:keys_config_06)         printf %s 'refresh now' ;;
    zh:keys_config_07)         printf %s '关闭' ;;
    en:keys_config_07)         printf %s 'close' ;;
    *)                          printf '%s' "$_fleet_ui_key" ;;
  esac
}

# fleet_ui_fail REASON [NEXT] — THE one way an operation the operator asked for
# says it did NOT happen (issue #1618, EPIC #1615 C3): one red line, the reason
# and the next step, held FLEET_REFUSE_MS (default 4000) so it is read, not
# glimpsed. A SUCCESS says nothing — the window appearing, going, the sidebar row
# changing is the feedback; never add a "done ✓" toast beside this. The caller
# keeps its own stderr line (the record a headless caller reads).
#   FLEET_UI_SOCK   tmux -L label to draw on (a headless caller naming its fleet)
#   FLEET_UI_CLIENT the one client to draw on (a bind's #{client_name})
#   FLEET_UI_QUIET  1 = draw nothing (the caller says it in its own line)
fleet_ui_fail() {
  # FLEET_UI_QUIET=1: a caller that re-says the failure in its own one line
  [ "${FLEET_UI_QUIET:-0}" = 1 ] && return 0
  if [ -n "${2:-}" ]; then _fuf_m=$(fleet_ui_t ui_fail_next_fmt "$1" "$2")
  else _fuf_m=$(fleet_ui_t ui_fail_fmt "${1:-}"); fi
  _fuf_d=${FLEET_REFUSE_MS:-4000}; case $_fuf_d in ''|*[!0-9]*) _fuf_d=4000 ;; esac
  # the colour is the palette's (conf/fleet-palette.conf), never one of our own
  _fuf_c=${PAL_RED:-}
  if [ -z "$_fuf_c" ] && [ -n "${BIN:-}" ] && [ -f "$BIN/../conf/fleet-palette.conf" ]; then
    _fuf_c=$(sed -n "s/^%hidden PAL_RED='\(#[0-9A-Fa-f]*\)'.*/\1/p" "$BIN/../conf/fleet-palette.conf" 2>/dev/null)
  fi
  tmux ${FLEET_UI_SOCK:+-L "$FLEET_UI_SOCK"} display-message ${FLEET_UI_CLIENT:+-c "$FLEET_UI_CLIENT"} \
    -d "$_fuf_d" "#[${_fuf_c:+fg=$_fuf_c,}bold] $_fuf_m " 2>/dev/null || :
}

# fleet_ui_hint_once KEY — rc 0 the first time KEY's how-to line is asked for
# today on this login (and stamps it), rc 1 after: a sidebar's key help flashes
# once a day, not on every visit (issue #1618). The stamp is
# $FLEET_C/global/hint.<KEY>.<YYYYMMDD> — $FLEET_C is per login ($TMPDIR); an
# older day's stamp for the KEY is swept as today's is written. A stamp that
# cannot be written fails OPEN (the hint shows), never silent forever.
fleet_ui_hint_once() {
  case "${1:-}" in ''|*[!A-Za-z0-9_]*) return 0 ;; esac
  _fuh_d="${FLEET_C:-${TMPDIR:-/tmp}/.claude-dash}/global"
  _fuh_s="$_fuh_d/hint.$1.$(date +%Y%m%d)"
  [ -e "$_fuh_s" ] && return 1
  mkdir -p "$_fuh_d" 2>/dev/null
  for _fuh_o in "$_fuh_d/hint.$1".*; do [ -e "$_fuh_o" ] && rm -f "$_fuh_o"; done
  { true > "$_fuh_s"; } 2>/dev/null || true   # `true`, not `:` — a failed redirect on a SPECIAL builtin exits dash
  return 0
}

case "$0" in */fleet-ui-lang.sh|fleet-ui-lang.sh)
  case "${1:-lang}" in
    lang) fleet_ui_lang ;;
    t) shift; fleet_ui_t "$@" ;;
    # toast CLIENT KEY [args…] — a tmux bind's message, in the login's language
    toast) _c=${2:-}; shift 2 2>/dev/null || shift $#
           tmux display-message ${_c:+-c "$_c"} "$(fleet_ui_t "$@")" 2>/dev/null || : ;;
    # hint CLIENT KEY — KEY's toast, but only the first time today (issue #1618)
    hint) _c=${2:-}; shift 2 2>/dev/null || shift $#
          fleet_ui_hint_once "${1:-}" && tmux display-message ${_c:+-c "$_c"} "$(fleet_ui_t "$@")" 2>/dev/null || : ;;
    # dump PREFIX… — every key starting with a PREFIX, KEY NUL TEXT NUL; a printf
    # argument stays a \001 slot the caller fills
    dump) fleet_ui_pin; _s=$(printf '\001')
          for _k in $(sed -n 's/^ *zh:\([A-Za-z0-9_]*\)).*/\1/p' "$0"); do
            for _p in "$@"; do
              [ "$_p" = dump ] && continue
              case "$_k" in "$_p"*) printf '%s\0%s\0' "$_k" "$(fleet_ui_t "$_k" "$_s" "$_s" "$_s")"; break ;; esac
            done
          done ;;
    *) printf 'usage: fleet-ui-lang.sh [lang|t KEY|toast CLIENT KEY|hint CLIENT KEY|dump PREFIX…]\n' >&2; exit 2 ;;
  esac ;;
esac
