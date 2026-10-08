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
    zh:sidebar_narrow_next)     printf '加宽终端，或 ⌘P 跳转' ;;
    en:sidebar_narrow_next)     printf 'widen it, or ⌘P to jump' ;;
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
    zh:wait_tool)               printf '等 fleet 工具返回' ;;
    en:wait_tool)               printf 'waiting on a fleet tool call' ;;
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
    zh:needs_exited)            printf '已退出' ;;
    en:needs_exited)            printf 'exited' ;;
    zh:needs_other)             printf '要你处理' ;;
    en:needs_other)             printf 'needs' ;;
    zh:repo_none_tag)           printf '⇢无' ;;
    en:repo_none_tag)           printf '⇢none' ;;
    zh:remote_lost)             printf '失联' ;;
    en:remote_lost)             printf 'lost' ;;
    # the machine words (issue #1475)
    zh:node_silent_fmt)         printf '%s 分钟没联系' "${1:-}" ;;
    en:node_silent_fmt)         printf 'silent %s min' "${1:-}" ;;
    zh:node_maint)              printf '维护中' ;;
    en:node_maint)              printf 'maintenance' ;;
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
    # the bar's left end (issue #1779, fleet-client-badge.sh): ⌂ = where the CLIENT runs,
    # and nowhere else — local: machine · terminal; over ssh: machine ← the device in your hand
    zh:badge_local_fmt)         printf '⌂ %s · %s' "${1:-}" "${2:-}" ;;
    en:badge_local_fmt)         printf '⌂ %s · %s' "${1:-}" "${2:-}" ;;
    zh:badge_ssh_fmt)           printf '⌂ %s ← %s' "${1:-}" "${2:-}" ;;
    en:badge_ssh_fmt)           printf '⌂ %s ← %s' "${1:-}" "${2:-}" ;;
    zh:badge_bare_fmt)          printf '⌂ %s' "${1:-}" ;;
    en:badge_bare_fmt)          printf '⌂ %s' "${1:-}" ;;
    zh:badge_hubdown_fmt)       printf '⌂ %s · 入口连不上' "${1:-}" ;;
    en:badge_hubdown_fmt)       printf '⌂ %s · hub unreachable' "${1:-}" ;;
    zh:badge_hubrefused_fmt)    printf '⌂ %s · 入口不认这台电脑 · 请重新扫码（fleet login）' "${1:-}" ;;
    en:badge_hubrefused_fmt)    printf '⌂ %s · the hub refused this computer · scan again (fleet login)' "${1:-}" ;;
    zh:badge_rescan_note)       printf '入口不认这台电脑的证书，续期也没用 — 请重新扫码：点左下角，或运行 fleet login' ;;
    en:badge_rescan_note)       printf 'The hub refuses this computer'"'"'s certificate and renewing will not help — scan again: tap the bottom left, or run fleet login' ;;
    zh:badge_updated_fmt)       printf '✓ 已更新到 %s' "${1:-}" ;;
    en:badge_updated_fmt)       printf '✓ updated to %s' "${1:-}" ;;
    zh:badge_reloaded)          printf '✓ 已重新载入新文件' ;;
    en:badge_reloaded)          printf '✓ reloaded the new files' ;;
    zh:badge_update_failed_fmt) printf '更新没成功：%s' "${1:-}" ;;
    en:badge_update_failed_fmt) printf 'update failed: %s' "${1:-}" ;;
    zh:badge_update_later)      printf '新版已就绪 · 下次打开生效' ;;
    en:badge_update_later)      printf 'new version ready · takes effect next open' ;;
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
    zh:empty_sidebar)           printf '暂无会话 — ⌘N 新任务' ;;
    en:empty_sidebar)           printf 'No sessions — ⌘N new task' ;;
    zh:empty_dash_fmt)          printf '暂无会话 — 输入名称新建 · %s 新任务' "${1:-}" ;;
    en:empty_dash_fmt)          printf 'No sessions — type a name to start one · %s new task' "${1:-}" ;;
    zh:keys_sidebar_title)      printf '任务栏：只点' ;;
    en:keys_sidebar_title)      printf 'Task list: taps only' ;;
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
    zh:popup_rescan)            printf '重新扫码' ;;
    en:popup_rescan)            printf 'Scan again' ;;
    zh:popup_quickopen)         printf '跳到会话' ;;
    en:popup_quickopen)         printf 'Go to session' ;;
    # ⌘P's commands (issue #1952): `>` lists the row menu's items
    zh:quickopen_cmd_hint)      printf '输入 > 是命令' ;;
    en:quickopen_cmd_hint)      printf 'type > for commands' ;;
    zh:switch_new)              printf '+ 新会话' ;;
    en:switch_new)              printf '+ New session' ;;
    zh:switch_multi)            printf '打开多会话视图' ;;
    en:switch_multi)            printf 'Open the multi-session view' ;;
    zh:switch_solo)             printf '收起侧栏' ;;
    en:switch_solo)             printf 'Hide the list' ;;
    zh:quickopen_cmd_for_fmt)   printf '对 %s' "${1:-}" ;;
    en:quickopen_cmd_for_fmt)   printf 'on %s' "${1:-}" ;;
    zh:quickopen_cmd_none)      printf '这里没有能做的事' ;;
    en:quickopen_cmd_none)      printf 'nothing to do here' ;;
    zh:quickopen_cmd_loading)   printf '读命令…' ;;
    en:quickopen_cmd_loading)   printf 'reading commands…' ;;
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
    zh:remote_label_switch_fmt)  printf '%s 换订阅（在 %s）' "${1:-}" "${2:-}" ;;
    en:remote_label_switch_fmt)  printf 'switch %s to an available subscription (on %s)' "${1:-}" "${2:-}" ;;
    zh:remote_label_resume_fmt)  printf '继续 %s（在 %s）' "${1:-}" "${2:-}" ;;
    en:remote_label_resume_fmt)  printf 'resume %s (on %s)' "${1:-}" "${2:-}" ;;
    zh:remote_label_reap_fmt)    printf '回收 %s（在 %s）' "${1:-}" "${2:-}" ;;
    en:remote_label_reap_fmt)    printf 'reap %s (on %s)' "${1:-}" "${2:-}" ;;
    zh:remote_label_message_fmt) printf '发给 %s（在 %s）' "${1:-}" "${2:-}" ;;
    en:remote_label_message_fmt) printf 'message %s (on %s)' "${1:-}" "${2:-}" ;;
    zh:remote_label_answer_fmt)  printf '答 %s（在 %s）' "${1:-}" "${2:-}" ;;
    en:remote_label_answer_fmt)  printf 'answer %s (on %s)' "${1:-}" "${2:-}" ;;
    # --- the task sidebar's own strings (fleet-sidebar.py reads `dump sidebar_`)
    zh:sidebar_new_to_fmt)      printf '新会话 → %s…' "${1:-}" ;;
    en:sidebar_new_to_fmt)      printf 'New session → %s…' "${1:-}" ;;
    zh:sidebar_rename)          printf '改名› ' ;;
    en:sidebar_rename)          printf 'rename› ' ;;
    zh:sidebar_here)            printf '本机' ;;
    en:sidebar_here)            printf 'here' ;;
    zh:sidebar_cfg_stale)       printf '配置旧' ;;
    en:sidebar_cfg_stale)       printf 'old cfg' ;;
    zh:sidebar_cfg_renew)       printf '待换新' ;;
    en:sidebar_cfg_renew)       printf 'renew' ;;
    zh:sidebar_cfg_broken)      printf '会坏·需重开' ;;
    en:sidebar_cfg_broken)      printf 'breaks·reopen' ;;
    zh:sidebar_epic_stale)      printf '没人在跑' ;;
    en:sidebar_epic_stale)      printf 'not driven' ;;
    zh:sidebar_epic_stale_detail_fmt) printf '心跳 %s 分钟前停了 · 再点一下重开驱动会话' "${1:-}" ;;
    en:sidebar_epic_stale_detail_fmt) printf 'heartbeat stopped %s min ago · tap again to reopen its driver' "${1:-}" ;;
    zh:sidebar_ask_epic_fmt)    printf '#%s 没人在跑 — 重开驱动会话？' "${1:-}" ;;
    en:sidebar_ask_epic_fmt)    printf '#%s is not driven — reopen its driver?' "${1:-}" ;;
    zh:sidebar_epic_reopen)     printf '重开驱动会话 /fleet-epic-run' ;;
    en:sidebar_epic_reopen)     printf 'Reopen the driver /fleet-epic-run' ;;
    zh:sidebar_epic_reopen_keys) printf '↵ 开 · esc 取消' ;;
    en:sidebar_epic_reopen_keys) printf '↵ open · esc cancel' ;;
    zh:sidebar_epic_reopening_fmt) printf '在开 #%s 的驱动会话…' "${1:-}" ;;
    en:sidebar_epic_reopening_fmt) printf 'opening the driver for #%s…' "${1:-}" ;;
    zh:sidebar_landed_heading_fmt) printf '已落地 (%s) · ↵ 恢复' "${1:-}" ;;
    en:sidebar_landed_heading_fmt) printf 'Landed (%s) · ↵ restore' "${1:-}" ;;
    zh:sidebar_landed_empty)    printf '（还没有已落地的会话）' ;;
    en:sidebar_landed_empty)    printf '(no landed sessions yet)' ;;
    zh:sidebar_landed_loading)  printf '已落地 …' ;;
    en:sidebar_landed_loading)  printf 'Landed …' ;;
    zh:sidebar_spawn_failed)    printf '创建失败' ;;
    en:sidebar_spawn_failed)    printf 'spawn failed' ;;
    # the shell's new / restore / scratch: repo, then where (issue #1778)
    zh:sidebar_place_repo)      printf '新会话 → 选仓库' ;;
    en:sidebar_place_repo)      printf 'New session → repo' ;;
    zh:sidebar_place_where_fmt) printf '%s → 开在哪' "${1:-}" ;;
    en:sidebar_place_where_fmt) printf '%s → where' "${1:-}" ;;
    zh:sidebar_place_keys)      printf '↑↓ 选 · ↵ 确认 · esc 取消' ;;
    en:sidebar_place_keys)      printf '↑↓ pick · ↵ ok · esc cancel' ;;
    zh:sidebar_place_auto)      printf '自动（入口挑最闲的）' ;;
    en:sidebar_place_auto)      printf 'auto (the hub picks the idlest)' ;;
    zh:sidebar_place_rec)       printf '推荐' ;;
    en:sidebar_place_rec)       printf 'default' ;;
    zh:sidebar_place_running_fmt) printf '%s 个在跑' "${1:-}" ;;
    en:sidebar_place_running_fmt) printf '%s running' "${1:-}" ;;
    zh:sidebar_place_coord)     printf '只协调' ;;
    en:sidebar_place_coord)     printf 'coordinates only' ;;
    zh:sidebar_place_maint)     printf '维护中' ;;
    en:sidebar_place_maint)     printf 'maintenance' ;;
    zh:sidebar_place_lost)      printf '失联' ;;
    en:sidebar_place_lost)      printf 'lost' ;;
    zh:sidebar_place_cant_fmt)  printf '%s：%s，不能开' "${1:-}" "${2:-}" ;;
    en:sidebar_place_cant_fmt)  printf '%s: %s — cannot open there' "${1:-}" "${2:-}" ;;
    zh:sidebar_place_issue)     printf 'issue #› ' ;;
    en:sidebar_place_issue)     printf 'issue #› ' ;;
    zh:sidebar_place_issue_hint_fmt) printf '→ %s · 输 issue 号；写字 = 草稿名' "${1:-}" ;;
    en:sidebar_place_issue_hint_fmt) printf '→ %s · an issue number; words = a scratch name' "${1:-}" ;;
    zh:sidebar_place_restore)   printf '恢复› ' ;;
    en:sidebar_place_restore)   printf 'restore› ' ;;
    zh:sidebar_place_restore_hint_fmt) printf '→ %s · issue-N 或 scratch-N' "${1:-}" ;;
    en:sidebar_place_restore_hint_fmt) printf '→ %s · issue-N or scratch-N' "${1:-}" ;;
    zh:sidebar_place_draft_fmt) printf '草稿 %s' "${1:-}" ;;
    en:sidebar_place_draft_fmt) printf 'scratch %s' "${1:-}" ;;
    zh:sidebar_place_norepo)    printf '还没有仓库：侧栏里先要有一个仓库的会话' ;;
    en:sidebar_place_norepo)    printf 'no repo yet: the list shows none to open in' ;;
    zh:sidebar_place_nohost)    printf '你还没有能开会话的机器：请入口管理员给你分一台' ;;
    en:sidebar_place_nohost)    printf 'no machine of yours hosts a repo yet: ask the hub admin for one' ;;
    zh:sidebar_place_nohost_ask_fmt) printf '你还没有能开会话的机器：请找入口管理员 %s 给你分一台' "${1:-}" ;;
    en:sidebar_place_nohost_ask_fmt) printf 'no machine of yours hosts a repo yet: ask the hub admin (%s) for one' "${1:-}" ;;
    zh:sidebar_place_account_opening_fmt) printf '正在为你开机器（%s），约 %s 秒 — 开好后自动接着开' "${1:-}" "${2:-}" ;;
    en:sidebar_place_account_opening_fmt) printf 'opening a machine for you (%s), about %ss — your session opens once it is ready' "${1:-}" "${2:-}" ;;
    zh:sidebar_place_account_failed_fmt) printf '给你开机器没成功：请找入口管理员 %s' "${1:-}" ;;
    en:sidebar_place_account_failed_fmt) printf 'opening a machine for you failed: ask the hub admin (%s)' "${1:-}" ;;
    # the stage's first window while no machine is up (fleet-shell.sh wait,
    # issue #2220): the hub's word on the person's login, never a bare
    # 「没有在线的机器」 while one is being opened for them
    zh:shell_wait_nohost)       printf '入口没有在线的机器，或者连不上入口。\n  左边是入口给的列表（缓存也算）：点一行就进那台机器；底下一栏说入口通不通。' ;;
    en:shell_wait_nohost)       printf 'no machine of yours is online, or the hub is out of reach.\n  The list on the left is the hub'"'"'s (cached counts): tap a row to enter that machine; the bottom line says whether the hub answers.' ;;
    zh:shell_wait_opening_fmt)  printf '正在为你开机器（%s），约 %s 秒。\n  开好后左边会出现它；那时 ⌘N 新任务（或 prefix c）开第一个会话。' "${1:-}" "${2:-}" ;;
    en:shell_wait_opening_fmt)  printf 'opening a machine for you (%s), about %ss.\n  It shows on the left once it is ready; then ⌘N new task (or prefix c) opens your first session.' "${1:-}" "${2:-}" ;;
    zh:shell_wait_failed_fmt)   printf '给你开机器没成功：请找入口管理员 %s。' "${1:-}" ;;
    en:shell_wait_failed_fmt)   printf 'opening a machine for you failed: ask the hub admin (%s).' "${1:-}" ;;
    zh:shell_wait_none_fmt)     printf '你还没有能开会话的机器：请找入口管理员 %s 给你分一台。' "${1:-}" ;;
    en:shell_wait_none_fmt)     printf 'no machine of yours hosts a session yet: ask the hub admin (%s) for one.' "${1:-}" ;;
    zh:shell_wait_home_fmt)     printf '这台电脑（%s）上没有你的 fleet 会话——这个客户端只看、只派，正常。\n  开第一个会话：⌘N 新任务（或 prefix c），写下要做的事，入口交给有空的机器去做。\n  左边是你在各台机器上的会话：点一行就进去。' "${1:-}" ;;
    en:shell_wait_home_fmt)     printf 'this computer (%s) holds no fleet session of yours — normal for a client that only looks and hands out work.\n  Your first session: ⌘N new task (or prefix c), write what to do, and the hub hands it to a free machine.\n  The list on the left is your sessions on every machine: tap a row to enter.' "${1:-}" ;;
    zh:shell_wait_leave)        printf 'prefix d 离开；再敲 fleet 回来。' ;;
    en:shell_wait_leave)        printf 'prefix d to leave; type fleet to come back.' ;;
    zh:sidebar_place_account_slow_fmt) printf '机器还没开好：稍后再回车一次，或找入口管理员 %s' "${1:-}" ;;
    en:sidebar_place_account_slow_fmt) printf 'your machine is not ready yet: press enter again later, or ask the hub admin (%s)' "${1:-}" ;;
    zh:sidebar_place_hubdown)   printf '入口连不上，暂时不能新建' ;;
    en:sidebar_place_hubdown)   printf 'the hub is unreachable — nothing can be opened now' ;;
    zh:sidebar_place_opening_fmt) printf '正在 %s 上开…' "${1:-}" ;;
    en:sidebar_place_opening_fmt) printf 'opening on %s…' "${1:-}" ;;
    zh:sidebar_place_opening_auto) printf '正在开（入口挑机器）…' ;;
    en:sidebar_place_opening_auto) printf 'opening (the hub picks a machine)…' ;;
    zh:sidebar_place_opened_fmt) printf '已在 %s 上开好，已切过去' "${1:-}" ;;
    en:sidebar_place_opened_fmt) printf 'opened on %s — switched to it' "${1:-}" ;;
    zh:sidebar_place_notyet_fmt) printf '已在 %s 上开好；侧栏还没出现，稍后再看' "${1:-}" ;;
    en:sidebar_place_notyet_fmt) printf 'opened on %s; not in the list yet — look again soon' "${1:-}" ;;
    zh:sidebar_place_held_fmt)  printf '已在 %s 上跑 · y 切过去› ' "${1:-}" ;;
    en:sidebar_place_held_fmt)  printf 'running on %s · y switches› ' "${1:-}" ;;
    zh:sidebar_place_refused_fmt) printf '开不了：%s' "${1:-}" ;;
    en:sidebar_place_refused_fmt) printf 'cannot open: %s' "${1:-}" ;;
    zh:sidebar_place_declined_fmt) printf '%s 没开成：%s' "${1:-}" "${2:-}" ;;
    en:sidebar_place_declined_fmt) printf '%s did not open it: %s' "${1:-}" "${2:-}" ;;
    zh:sidebar_place_unknown_fmt) printf '%s 还没回话：稍后看侧栏' "${1:-}" ;;
    en:sidebar_place_unknown_fmt) printf '%s has not answered yet — watch the list' "${1:-}" ;;
    # the writing area's row and its in-flight row (issue #1953)
    zh:sidebar_portal)          printf '新任务' ;;
    en:sidebar_portal)          printf 'New task' ;;
    zh:sidebar_portal_placing_fmt) printf '开工中… %s' "${1:-}" ;;
    en:sidebar_portal_placing_fmt) printf 'starting… %s' "${1:-}" ;;
    # a HOME session (issue #2264): `fleet claude` / `fleet codex`, a newcomer's first one
    zh:home_opening_fmt)        printf '正在开 %s 会话（主目录，开在入口挑的有空机器上）…' "${1:-}" ;;
    en:home_opening_fmt)        printf 'opening a %s session (home directory, on the machine the hub picks)…' "${1:-}" ;;
    # the newcomer's one-session view (issue #2347): no fleet word before the first key
    zh:home_opening_solo_fmt)   printf '正在开 %s 会话（主目录，开在一台有空的机器上）…' "${1:-}" ;;
    en:home_opening_solo_fmt)   printf 'opening a %s session (home directory, on a free machine)…' "${1:-}" ;;
    zh:home_placed_fmt)         printf '会话开在 %s' "${1:-}" ;;
    en:home_placed_fmt)         printf 'the session is on %s' "${1:-}" ;;
    zh:home_failed_fmt)         printf '开不了会话：%s' "${1:-}" ;;
    en:home_failed_fmt)         printf 'could not open a session: %s' "${1:-}" ;;
    zh:home_first_hint)         printf '这里和本地运行 claude 一样；要在某个仓库里做，直接告诉我仓库名' ;;
    en:home_first_hint)         printf 'Just like running claude locally; to work in a repo, tell me its name' ;;
    # leaving the one-session view (issue #2265): ⌃D / prefix d / the agent's /exit
    zh:solo_left_fmt)           printf '会话在后台继续（%s）。' "${1:-}" ;;
    en:solo_left_fmt)           printf 'The session keeps running in the background (%s).' "${1:-}" ;;
    zh:solo_back)               printf '下次输入 fleet 回来。' ;;
    en:solo_back)               printf 'Type fleet to come back.' ;;
    zh:solo_ended_fmt)          printf '会话已结束（%s）。' "${1:-}" ;;
    en:solo_ended_fmt)          printf 'The session has ended (%s).' "${1:-}" ;;
    zh:solo_resume)             printf 'fleet 可以恢复。' ;;
    en:solo_resume)             printf 'Type fleet to resume it.' ;;
    # the writing area itself (issue #1953, bin/fleet-compose.py)
    zh:compose_title)           printf '新任务' ;;
    en:compose_title)           printf 'New task' ;;
    zh:compose_head)            printf '写下要做的事' ;;
    en:compose_head)            printf 'What needs doing' ;;
    zh:compose_saved_fmt)       printf '草稿已保存 %s' "${1:-}" ;;
    en:compose_saved_fmt)       printf 'draft saved %s' "${1:-}" ;;
    zh:compose_placeholder)     printf '一行就够，多写几行也行。文件拖进来就是附件。' ;;
    en:compose_placeholder)     printf 'One line is enough; more is fine. Drop a file in to attach it.' ;;
    zh:compose_repo)            printf '仓库' ;;
    en:compose_repo)            printf 'repo' ;;
    zh:compose_repo_auto)       printf '自动' ;;
    en:compose_repo_auto)       printf 'auto' ;;
    zh:compose_repo_here)       printf '你刚才在这' ;;
    en:compose_repo_here)       printf 'where you just were' ;;
    zh:compose_menu_keys)       printf '↑↓ 选 · ↵ 确定 · esc 关' ;;
    en:compose_menu_keys)       printf '↑↓ pick · ↵ choose · esc close' ;;
    zh:compose_attach)          printf '附件' ;;
    en:compose_attach)          printf 'attached' ;;
    zh:compose_go_issue)        printf '↵ 开工' ;;
    en:compose_go_issue)        printf '↵ start' ;;
    zh:compose_keys)            printf '⇧↵ 换行 · Tab 改选项 · esc 返回' ;;
    en:compose_keys)            printf '⇧↵ new line · Tab options · esc back' ;;
    zh:compose_repo_home)       printf '无仓库 · HOME' ;;
    en:compose_repo_home)       printf 'no repo · HOME' ;;
    zh:compose_repo_home_note)  printf '在主目录开会话' ;;
    en:compose_repo_home_note)  printf 'a session in your home directory' ;;
    zh:compose_repo_last)       printf '上次用的' ;;
    en:compose_repo_last)       printf 'used last' ;;
    zh:compose_node)            printf '节点' ;;
    en:compose_node)            printf 'machine' ;;
    zh:compose_node_auto)       printf '自动' ;;
    en:compose_node_auto)       printf 'auto' ;;
    zh:compose_node_rec_fmt)    printf '推荐 · %s 个在跑' "${1:-}" ;;
    en:compose_node_rec_fmt)    printf 'default · %s running' "${1:-}" ;;
    zh:compose_node_running_fmt) printf '%s 个在跑' "${1:-}" ;;
    en:compose_node_running_fmt) printf '%s running' "${1:-}" ;;
    zh:compose_node_coord)      printf '只协调' ;;
    en:compose_node_coord)      printf 'coordinates only' ;;
    zh:compose_node_maint)      printf '维护中' ;;
    en:compose_node_maint)      printf 'maintenance' ;;
    zh:compose_node_lost)       printf '失联' ;;
    en:compose_node_lost)       printf 'lost' ;;
    zh:compose_agent)           printf 'Agent' ;;
    en:compose_agent)           printf 'Agent' ;;
    zh:compose_agent_default)   printf '默认' ;;
    en:compose_agent_default)   printf 'default' ;;
    zh:compose_orch_nolist)     printf '没找到任务列表，切不到编排' ;;
    en:compose_orch_nolist)     printf 'no task list found: cannot switch to the orchestrator' ;;
    zh:compose_orch_none)       printf '这台机器没有编排会话' ;;
    en:compose_orch_none)       printf 'no orchestrating session on this machine' ;;
    zh:orch_window)             printf '编排' ;;
    en:orch_window)             printf 'orchestrator' ;;
    zh:compose_sent_fmt)        printf '已发出：%s · 开工中…' "${1:-}" ;;
    en:compose_sent_fmt)        printf 'sent: %s · starting…' "${1:-}" ;;
    zh:compose_empty)           printf '先写一行再 ↵' ;;
    en:compose_empty)           printf 'write a line first' ;;
    zh:compose_nolist)          printf '没找到任务列表：直接发给入口' ;;
    en:compose_nolist)          printf 'no task list found: sending straight to the hub' ;;
    zh:compose_result_fmt)      printf '入口回话：%s' "${1:-}" ;;
    en:compose_result_fmt)      printf 'the hub says: %s' "${1:-}" ;;
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
    zh:sidebar_ask_keys)        printf '↵ 确定 · esc 取消' ;;
    en:sidebar_ask_keys)        printf '↵ ok · esc cancel' ;;
    # --- the row menu (fleet-sidebar-menu.sh). menu_keys is THE letter table:
    # `action<TAB>letter<TAB>what`, read by the menu (mk) and the ? sheet (--keys).
    zh:menu_keys)               printf '%s' 'rename	r	改名 — 在输入行编辑（↵ 应用，esc / 空名称取消）
pin	t	置顶 / 取消置顶
pr	p	打开 PR（没有时置灰）
answer	a	回答提问 — 跳到那个会话，在它自己的提问里答（红色 ? 行；否则置灰）
sub	s	切换 sub — 在输入行写账号，Tab 逐个看额度，↵ 迁移
wake	w	唤醒睡眠中的 z 行（仅睡眠时显示）
awake	k	保持唤醒 ⇄ 允许再次休眠
reappol	l	改回收方式 — 合并后 / 做完就收 / 循环停了 / 到点 / 常驻
agent	v	新会话 claude ⇄ codex
reap	x	回收 — 先确认 y/n（别机行：经入口让那台机器回收）
new	n	新任务 — 在输入行写标题（多仓库 Tab 换仓库），↵ 建 issue 并启动 worker
newto	1-9	新建到 <机器>… — 入口在线的别的机器各一项：建 issue，worker 开在那台机器上
restore	o	已落地 — 任务栏就地换成已落地列表，点一行恢复（再选一次回到运行中）
repo	g	添加仓库到这个 fleet — 在输入行写 owner/name；~/projects/<name>，缺失时 clone（hub ⌃z）
open	e	进入 — 打开代理窗口（只有另一台机器上的行有；菜单标题写着「· m4」）
message	m	发消息… — 只有别机行有：在输入行写，经入口送到那台机器的 issue 桥，作为它的下一轮
stop	q	停 — 只有别机行有：经入口让那台机器上的会话 /exit（可恢复）
resume	c	继续 — 只有别机行有：经入口恢复刚停掉的会话（活着的会被拒绝并告诉你）
clients	d	我的客户端 — 只在客户端：同时开着的每台设备、终端、最后使用时间，可断开某一台
orch	b	进编排会话 — 直接切到固定的编排会话（写作区里再按 ⌘N 也是；「新任务」行的右键菜单，⌘P 的 > 也有）' ;;
    en:menu_keys)               printf '%s' 'rename	r	rename — edits on the input line (↵ applies, esc / an empty name cancels)
pin	t	pin / unpin the row to the top
pr	p	open its PR (greyed when it has none)
answer	a	answer its question — jumps to that session, to answer in its own picker (a red ? row; greyed otherwise)
sub	s	switch subscription — the account on the input line, Tab through them with their quota, ↵ moves
wake	w	wake a sleeping (z) row now — only listed on one
awake	k	keep it awake ⇄ allow it to sleep again
reappol	l	reap policy — after merge / when done / after the loop / at a time / keep
agent	v	flip new sessions claude ⇄ codex
reap	x	reap it — asks y/n first (a row on another machine: through the hub, there)
new	n	new task — its title on the input line (Tab picks the repo in a 2+ repo fleet), ↵ files the issue AND spawns its worker
newto	1-9	new task on <machine>… — one per other machine the hub says is online: file the issue, open the worker there
restore	o	landed — the sidebar shows the landed list in place; tap a row to restore it (again: back to the running list)
repo	g	add a repo to this fleet — owner/name on the input line; ~/projects/<name>, cloned if missing (the hub ⌃z)
open	e	enter — open the proxy window (a row on another machine only; the menu title says · m4)
message	m	message… — a row on another machine only: typed on the input line, through the hub to the issue bridge on that machine, as its next turn
stop	q	stop — a row on another machine only: /exit there through the hub (resumable)
resume	c	resume — a row on another machine only: reopen a just-stopped one through the hub (a live one is refused, and says so)
clients	d	my clients — in the client only: every device you have open, its terminal and when last used; disconnect one
orch	b	go to the orchestrator — straight to the orchestrating session of the fleet (⌘N again in the writing area too; also on the right-click menu of the 「New task」 row, and in ⌘P >)' ;;
    zh:menu_open_remote)        printf '进入（代理窗口）…' ;;
    en:menu_open_remote)        printf 'Enter (proxy window)…' ;;
    zh:menu_r_message)          printf '发消息…' ;;
    en:menu_r_message)          printf 'Message…' ;;
    zh:menu_r_stop)             printf '停（/exit）' ;;
    en:menu_r_stop)             printf 'Stop (/exit)' ;;
    zh:menu_r_resume)           printf '继续（恢复）' ;;
    en:menu_r_resume)           printf 'Resume' ;;
    zh:menu_r_switch)           printf '换到可用订阅（同一对话）' ;;
    en:menu_r_switch)           printf 'Move to an available subscription' ;;
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
    # --- the reap policy (issue #1902): the row menu's submenu and the shell's
    # new-session question 「什么时候回收？」 — the prototype's words.
    # --- 我的客户端 (issue #1932): the clients open at once, fleet-client-menu.sh
    zh:menu_clients)            printf '我的客户端…' ;;
    en:menu_clients)            printf 'My clients…' ;;
    zh:clients_title)           printf '我的客户端' ;;
    en:clients_title)           printf 'My clients' ;;
    zh:clients_stale)           printf '入口连不上，上次的' ;;
    en:clients_stale)           printf 'hub unreachable, last known' ;;
    zh:clients_this)            printf '（这台）' ;;
    en:clients_this)            printf '(this one)' ;;
    zh:clients_now)             printf '刚刚用过' ;;
    en:clients_now)             printf 'in use now' ;;
    zh:clients_ago_m)           printf '%s 分钟前用过' "${1:-}" ;;
    en:clients_ago_m)           printf 'used %sm ago' "${1:-}" ;;
    zh:clients_ago_h)           printf '%s 小时前用过' "${1:-}" ;;
    en:clients_ago_h)           printf 'used %sh ago' "${1:-}" ;;
    zh:clients_ago_d)           printf '%s 天前用过' "${1:-}" ;;
    en:clients_ago_d)           printf 'used %sd ago' "${1:-}" ;;
    zh:clients_none)            printf '没有客户端连着' ;;
    en:clients_none)            printf 'no client connected' ;;
    zh:clients_hint)            printf '● = 网页、文件、通知送到这台（最后打字的）· 选一台断开' ;;
    en:clients_hint)            printf '● = pages, files, notes go here (typed last) · pick one to disconnect' ;;
    zh:clients_confirm_fmt)     printf '断开「%s」？(y/n)' "${1:-}" ;;
    en:clients_confirm_fmt)     printf 'Disconnect "%s"? (y/n)' "${1:-}" ;;
    zh:clients_revoked)         printf '已断开' ;;
    en:clients_revoked)         printf 'Disconnected' ;;
    zh:clients_revoke_failed)   printf '断开没成功：' ;;
    en:clients_revoke_failed)   printf 'Could not disconnect:' ;;
    zh:topbar_also_fmt)         printf '也在 %s 上打开' "${1:-}" ;;
    en:topbar_also_fmt)         printf 'also open on %s' "${1:-}" ;;
    zh:menu_reap_policy)        printf '改回收方式…' ;;
    en:menu_reap_policy)        printf 'Reap policy…' ;;
    zh:reap_menu_title)         printf '什么时候回收' ;;
    en:reap_menu_title)         printf 'When to reap' ;;
    zh:reap_menu_merged)        printf '合并后回收 — PR 合并 10 分钟后' ;;
    en:reap_menu_merged)        printf 'After merge — 10 min after the PR merges' ;;
    zh:reap_menu_done_2h)       printf '做完就回收 — 闲满 2 小时' ;;
    en:reap_menu_done_2h)       printf 'When done — idle 2 hours' ;;
    zh:reap_menu_loop_end)      printf '循环停了回收 — /loop 停了以后' ;;
    en:reap_menu_loop_end)      printf 'After the loop — once /loop stops' ;;
    zh:reap_menu_at)            printf '到点回收…' ;;
    en:reap_menu_at)            printf 'At a time…' ;;
    zh:reap_menu_keep)          printf '常驻 — 永不自动回收，只睡眠' ;;
    en:reap_menu_keep)          printf 'Keep — never reaped, only sleeps' ;;
    zh:reap_menu_at_prompt)     printf '几点回收（HH:MM 或 2026-10-06T18:00Z）:' ;;
    en:reap_menu_at_prompt)     printf 'Reap at (HH:MM or 2026-10-06T18:00Z):' ;;
    # the row's reap-policy word (issue #1902), left of the @ mark; _narrow when tight
    zh:sidebar_reap_merged)     printf '合并后回收' ;;
    en:sidebar_reap_merged)     printf 'after merge' ;;
    zh:sidebar_reap_merged_for) printf '合并后留 %s' "${1:-}" ;;
    en:sidebar_reap_merged_for) printf 'merge+%s' "${1:-}" ;;
    zh:sidebar_reap_done)       printf '做完就回收' ;;
    en:sidebar_reap_done)       printf 'when done' ;;
    zh:sidebar_reap_done_for)   printf '做完闲 %s' "${1:-}" ;;
    en:sidebar_reap_done_for)   printf 'done+%s' "${1:-}" ;;
    zh:sidebar_reap_loop_end)   printf '循环停了回收' ;;
    en:sidebar_reap_loop_end)   printf 'after loop' ;;
    zh:sidebar_reap_at)         printf '到点 %s' "${1:-}" ;;
    en:sidebar_reap_at)         printf 'at %s' "${1:-}" ;;
    zh:sidebar_reap_keep)       printf '常驻' ;;
    en:sidebar_reap_keep)       printf 'keep' ;;
    # the five choices of 「什么时候回收？」 (issue #1902): `label<TAB>note`
    zh:sidebar_place_reap_merged) printf '合并后回收\tPR 合并 10 分钟后' ;;
    en:sidebar_place_reap_merged) printf 'After merge\t10 min after the PR merges' ;;
    zh:sidebar_place_reap_done) printf '做完就回收\t闲满 2 小时' ;;
    en:sidebar_place_reap_done) printf 'When done\tidle 2 hours' ;;
    zh:sidebar_place_reap_loop_end) printf '循环停了回收\t/loop 停了以后' ;;
    en:sidebar_place_reap_loop_end) printf 'After the loop\tonce /loop stops' ;;
    zh:sidebar_place_reap_at)   printf '到点回收\t下一步写时间' ;;
    en:sidebar_place_reap_at)   printf 'At a time\tthe time comes next' ;;
    zh:sidebar_place_reap_keep) printf '常驻\t永不自动回收，只睡眠' ;;
    en:sidebar_place_reap_keep) printf 'Keep\tnever reaped, only sleeps' ;;
    zh:sidebar_place_reap_fmt)  printf '%s → 什么时候回收？' "${1:-}" ;;
    en:sidebar_place_reap_fmt)  printf '%s → when to reap?' "${1:-}" ;;
    zh:sidebar_place_reap_keys) printf '↑↓ 选 · ↵ 确认（默认：%s）· esc 取消' "${1:-}" ;;
    en:sidebar_place_reap_keys) printf '↑↓ pick · ↵ ok (default: %s) · esc cancel' "${1:-}" ;;
    zh:sidebar_place_reap_default) printf '默认' ;;
    en:sidebar_place_reap_default) printf 'default' ;;
    zh:sidebar_place_reap_at_ask) printf '几点回收？HH:MM 或 2026-10-06T18:00Z› ' ;;
    en:sidebar_place_reap_at_ask) printf 'Reap at? HH:MM or 2026-10-06T18:00Z› ' ;;
    zh:sidebar_place_reap_bad)  printf '不是一个时间：HH:MM 或 2026-10-06T18:00Z' ;;
    en:sidebar_place_reap_bad)  printf 'not a time: HH:MM or 2026-10-06T18:00Z' ;;
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
    zh:menu_sub)                printf '迁移到…（换账号）' ;;
    en:menu_sub)                printf 'Move to… (another account)' ;;
    zh:menu_sub_none)           printf '迁移到…（只有运行中的 Claude 会话能迁）' ;;
    en:menu_sub_none)           printf 'Move to… (a running Claude session only)' ;;
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
    zh:menu_orch)               printf '进编排会话' ;;
    en:menu_orch)               printf 'Go to the orchestrator' ;;
    zh:menu_orch_none)          printf '进编排会话 · 这台机器没有编排会话' ;;
    en:menu_orch_none)          printf 'Go to the orchestrator · none on this machine' ;;
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
    # the full sheet, one row each (fleet-keys.sh print_sheet; generated from
    # the two sheets it replaced, row for row)
    zh:keys_g_prefix)          printf %s 'tmux 前缀' ;;
    en:keys_g_prefix)          printf %s 'tmux prefix' ;;
    zh:keys_g_prefix_sub)      printf %s '— 客户端（fleet）里任意窗口可用' ;;
    en:keys_g_prefix_sub)      printf %s '— in the client (fleet), from any window' ;;
    zh:keys_prefix_05)         printf %s '回到上一台机器（上一个窗口）' ;;
    en:keys_prefix_05)         printf %s 'back to the machine you were on (the previous window)' ;;
    zh:keys_prefix_09)         printf %s '缩放会话窗格（从不缩放任务列表）' ;;
    en:keys_prefix_09)         printf %s 'zoom the session pane — the SESSION, never the list' ;;
    zh:keys_prefix_10)         printf %s '查看会话滚屏（tmux copy-mode）' ;;
    en:keys_prefix_10)         printf %s 'scroll back the session (tmux copy-mode)' ;;
    zh:keys_prefix_16)         printf %s '跳到下一个在问你的任务并切过去（列表里它是红色 !）' ;;
    en:keys_prefix_16)         printf %s 'jump to the next task waiting on you and switch to it (its row in the list is a red !)' ;;
    zh:keys_prefix_13)         printf %s '打开这份快捷键' ;;
    en:keys_prefix_13)         printf %s 'this cheatsheet' ;;
    zh:keys_prefix_14)         printf %s '无前缀：缩放右侧会话窗格（本机窗格，按键不会传到远端）' ;;
    en:keys_prefix_14)         printf %s '(no prefix) zoom the session pane on the right — this computer'"'"'s pane; the key never reaches the far end' ;;
    zh:keys_prefix_15)         printf %s '在 shell 叫回上手向导，从上次进度继续' ;;
    en:keys_prefix_15)         printf %s 'from a shell, reopen the onboarding guide at its saved progress' ;;
    zh:keys_g_switch)          printf %s '切会话' ;;
    en:keys_g_switch)          printf %s 'switch sessions' ;;
    zh:keys_g_switch_sub)      printf %s '— 任意窗口可用；Mac 的 iTerm2 里按 ⌘ 键（fleet 配置文件），其它终端按前缀键' ;;
    en:keys_g_switch_sub)      printf %s '— from any window; the ⌘ chord in iTerm2 on a Mac (the fleet profile), the prefix key anywhere else' ;;
    zh:keys_switch_next)       printf %s '下一个会话，右侧立刻跟过去' ;;
    en:keys_switch_next)       printf %s 'the next session; the right pane follows at once' ;;
    zh:keys_switch_prev)       printf %s '上一个会话' ;;
    en:keys_switch_prev)       printf %s 'the previous session' ;;
    zh:keys_switch_back)       printf %s '后退：回到刚才看的会话（没有任务列表时：上一台机器）' ;;
    en:keys_switch_back)       printf %s 'back through the sessions you were on (no task list: the machine before)' ;;
    zh:keys_switch_fwd)        printf %s '前进' ;;
    en:keys_switch_fwd)        printf %s 'forward again' ;;
    zh:keys_switch_needs)      printf %s '下一个在等你的会话' ;;
    en:keys_switch_needs)      printf %s 'the next session waiting on you' ;;
    zh:keys_switch_zoom)       printf %s '放大右侧会话，再按复原' ;;
    en:keys_switch_zoom)       printf %s 'zoom the session on the right; again to restore' ;;
    zh:keys_switch_help)       printf %s '全部按键' ;;
    en:keys_switch_help)       printf %s 'every key' ;;
    zh:keys_switch_quickopen)  printf %s '快速跳转：打几个字（名字、机器、状态都算），↵ 切过去；不打字 ↵ = 上一个看的' ;;
    en:keys_switch_quickopen)  printf %s 'quick open: type a few letters (name, machine, state), ↵ switches; ↵ on nothing = the one you saw before' ;;
    zh:keys_switch_new)        printf %s '新任务：右边打开写作区，多行、附件，↵ 开 issue 和会话；在写作区再按一次：去编排会话，再按回来' ;;
    en:keys_switch_new)        printf %s 'new task: the writing area on the right — several lines, attachments; ↵ files the issue and opens its session; again in it: the orchestrating session, and back' ;;
    zh:keys_switch_fold)       printf %s '展开/收起当前会话的子任务；在子任务上按：收起它的父任务' ;;
    en:keys_switch_fold)       printf %s 'open / shut the sub-tasks of the session in view; on a sub-task: shut its parent' ;;
    zh:keys_switch_switcher)   printf %s '切换会话：全部会话按最近使用排，可搜索；最下面「+ 新会话」和「打开多会话视图」（多会话视图里是「收起侧栏」）' ;;
    en:keys_switch_switcher)   printf %s 'switch session: every session, most recent first, searchable; at the bottom + New session and Open the multi-session view (Hide the list in it)' ;;
    zh:keys_single_f1)         printf %s '窄屏（手机）：全屏切换器 —— 在等你的 · 最近 1–9 · 全部，点一行切过去；顶栏点名字同此' ;;
    en:keys_single_f1)         printf %s 'narrow (a phone): the full-screen switcher — waiting on you · recent 1–9 · all, tap a row; tapping the name on the top line too' ;;
    zh:keys_single_f23)        printf %s '窄屏：上一个 / 下一个会话（顶栏 ‹ › 同此）' ;;
    en:keys_single_f23)        printf %s 'narrow: the session above / below (the top line ‹ › too)' ;;
    zh:keys_single_f4)         printf %s '窄屏：下一个在等你的会话' ;;
    en:keys_single_f4)         printf %s 'narrow: the next session waiting on you' ;;
    # --- ⌘/ — the one page of keys (issue #1952, fleet-keys.sh --page): three
    # groups, the ⌘ chord on the left and the other terminals' key on the right
    zh:keys_page_title)        printf %s '按键' ;;
    en:keys_page_title)        printf %s 'Keys' ;;
    zh:keys_page_sub)          printf %s 'Mac · iTerm2 按 ⌘ 键；别的终端用右边那一列' ;;
    en:keys_page_sub)          printf %s 'the ⌘ chord in iTerm2 on a Mac; any other terminal: the right column' ;;
    zh:keys_page_cmd)          printf %s '⌘ 键' ;;
    en:keys_page_cmd)          printf %s '⌘ keys' ;;
    zh:keys_page_new)          printf %s '新任务；再按一次：去编排，再按回来' ;;
    en:keys_page_new)          printf %s 'new task; again: orchestrator, and back' ;;
    zh:keys_page_quickopen)    printf %s '跳到任意会话；输入 > 是命令' ;;
    en:keys_page_quickopen)    printf %s 'go to any session; type > for commands' ;;
    zh:keys_page_fold)         printf %s '展开/收起子任务（子任务上：收起父任务）' ;;
    en:keys_page_fold)         printf %s 'open / shut sub-tasks (on one: its parent)' ;;
    zh:keys_page_switcher)     printf %s '切换会话 · 新会话 · 打开/收起多会话视图' ;;
    en:keys_page_switcher)     printf %s 'switch session · new · multi-session view on/off' ;;
    zh:keys_page_prevnext)     printf %s '上一个 / 下一个会话' ;;
    en:keys_page_prevnext)     printf %s 'previous / next session' ;;
    zh:keys_page_backfwd)      printf %s '后退 / 前进' ;;
    en:keys_page_backfwd)      printf %s 'back / forward' ;;
    zh:keys_page_needs)        printf %s '去在问你的' ;;
    en:keys_page_needs)        printf %s 'to the one asking you' ;;
    zh:keys_page_zoom)         printf %s '放大右边，再按复原' ;;
    en:keys_page_zoom)         printf %s 'zoom the right side; again to restore' ;;
    zh:keys_page_help)         printf %s '这一页' ;;
    en:keys_page_help)         printf %s 'this page' ;;
    zh:keys_page_compose)      printf %s '写作区' ;;
    en:keys_page_compose)      printf %s 'writing area' ;;
    zh:keys_page_c_send)       printf %s '发出' ;;
    en:keys_page_c_send)       printf %s 'send' ;;
    zh:keys_page_c_nl)         printf %s '换行' ;;
    en:keys_page_c_nl)         printf %s 'new line' ;;
    zh:keys_page_c_tab)        printf %s '下一项（记成 issue · 仓库）' ;;
    en:keys_page_c_tab)        printf %s 'next option (file an issue · repo)' ;;
    zh:keys_page_c_btab)       printf %s '交给编排，草稿一起带过去' ;;
    en:keys_page_c_btab)       printf %s 'hand it to the orchestrator, the draft along' ;;
    zh:keys_page_c_space)      printf %s '切换选中的那一项' ;;
    en:keys_page_c_space)      printf %s 'flip the option it is on' ;;
    zh:keys_page_c_esc)        printf %s '回去，草稿留着' ;;
    en:keys_page_c_esc)        printf %s 'back; the draft is kept' ;;
    zh:keys_page_mouse)        printf %s '鼠标' ;;
    en:keys_page_mouse)        printf %s 'mouse' ;;
    zh:keys_page_m_menu)       printf %s '这一行的菜单，和 ⌘P 的 > 命令是同一张表' ;;
    en:keys_page_m_menu)       printf %s 'the row'"'"'s menu — the same list as ⌘P'"'"'s > commands' ;;
    zh:keys_page_more)         printf %s '面板里的按键：在那个面板里按 ?' ;;
    en:keys_page_more)         printf %s 'a panel'"'"'s own keys: press ? inside it' ;;
    zh:keys_g_sidebar)         printf %s '任务栏' ;;
    en:keys_g_sidebar)         printf %s 'task sidebar' ;;
    zh:keys_g_sidebar_sub)     printf %s '— 只点，不收键盘；按键都在上面一组' ;;
    en:keys_g_sidebar_sub)     printf %s '— taps only, it takes no keys; the keys are the group above' ;;
    zh:keys_sidebar_m1k)       printf %s '点一行' ;;
    en:keys_sidebar_m1k)       printf %s 'tap a row' ;;
    zh:keys_sidebar_m1)        printf %s '切过去' ;;
    en:keys_sidebar_m1)        printf %s 'switch to it' ;;
    zh:keys_sidebar_m2k)       printf %s '再点一次 / 右键' ;;
    en:keys_sidebar_m2k)       printf %s 'tap again / right-click' ;;
    zh:keys_sidebar_m2)        printf %s '这一行的菜单：改名 · 置顶 · 回答 · 回收 …' ;;
    en:keys_sidebar_m2)        printf %s 'the row'"'"'s menu — rename · pin · answer · reap …' ;;
    zh:keys_sidebar_m3k)       printf %s '点 ▸ ▾' ;;
    en:keys_sidebar_m3k)       printf %s 'tap ▸ ▾' ;;
    zh:keys_sidebar_m3)        printf %s '折叠 / 展开这一组' ;;
    en:keys_sidebar_m3)        printf %s 'fold / unfold its block' ;;
    zh:keys_sidebar_m4k)       printf %s '改名 · 回答' ;;
    en:keys_sidebar_m4k)       printf %s 'rename · answer' ;;
    zh:keys_sidebar_m4)        printf %s '在会话下面临时出一行问：↵ 确定 · esc 取消' ;;
    en:keys_sidebar_m4)        printf %s 'asked on one line under the session — ↵ ok · esc cancel' ;;
    zh:keys_sidebar_12k)       printf %s '点仓库标题' ;;
    en:keys_sidebar_12k)       printf %s 'tap a heading' ;;
    zh:keys_sidebar_12)        printf %s '点一下选中它（不切换），再点一次在这个仓库开新任务；「无仓库」= $HOME' ;;
    en:keys_sidebar_12)        printf %s 'a tap selects it (no switch), a second one opens a new task in that repo; '"'"'no repo'"'"' = $HOME' ;;
    zh:keys_g_menu)            printf %s '行菜单' ;;
    en:keys_g_menu)            printf %s 'row menu' ;;
    zh:keys_g_menu_sub)        printf %s '— 再次点击选中行，或右键一行' ;;
    en:keys_g_menu_sub)        printf %s '— a second tap on the highlighted row, or a right-click: press its letter' ;;
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
