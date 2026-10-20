#!/bin/sh
# fleet-ui-lang.sh — THE one table of every UI string the fleet draws (issue
# #1535, EPIC #1529 E6). Source-safe; `fleet_ui_t KEY [args…]` is the only way a
# string reaches the bar, the sidebar, a popup, a menu or a toast:
#
#   shell    . fleet-ui-lang.sh; fleet_ui_t KEY [args…]   (printf-style args)
#   tmux     run-shell "sh …/fleet-ui-lang.sh toast '#{client_name}' KEY"
#   python   fleet-ui-lang.sh dump PREFIX… — every KEY starting with a PREFIX as
#            KEY NUL TEXT NUL, each printf argument left as a \001 slot
#            (fleet_view.py reads its strings this way, once, at start)
#
# Today there were four tables (this one, fleet_view.py's TEXT,
# fleet_view.py ACTIONS's MENU_KEYS, fleet-keys.sh's whole zh sheet — gone with
# the sheet, #4902); a string
# added anywhere else is a second source again — fleet-ui-lang-selftest.sh greps
# for one. A key with no entry prints itself, so a typo is visible, never blank.
#
# FLEET_UI_LANG:
#   auto  the person's choice, else the client's locale, else Chinese (below)
#   en    force English
#   zh    force Chinese
#
# auto, in order (issue #3329, EPIC #3178 D5–D7):
#   1. the person's own choice — `ui_lang` (zh | en) in the personal layer this
#      login last read from the hub ($FLEET_CONF_DIR/person-bundle.json), set in a
#      看台's ⌘P (fleet-config.py lang); once set, nothing is detected any more
#   2. a 看台's own connection — FLEET_VIEW_LANG, what its client brought through
#      the door (`@view_lang`, put in the 看台 session's environment by
#      fleet-remote-view.sh attach --thin): zh* => Chinese, none / C / POSIX =>
#      Chinese (D6), anything else English. Set (even empty) = this rule decides.
#   3. the login's own locale, the same way — what a script outside a 看台 reads.
#
# A script that looks up many strings in a row (the key sheet, the row menu)
# calls `fleet_ui_pin` once: the language is resolved one time instead of in a
# subshell per lookup. Not exported — a child resolves its own.

fleet_ui_lang() {
  case "${FLEET_UI_LANG:-auto}" in
    zh|zh_*|zh-*|ZH|ZH_*|ZH-*|cn|CN|chinese|Chinese) printf 'zh\n'; return 0 ;;
    en|en_*|en-*|EN|EN_*|EN-*|english|English)       printf 'en\n'; return 0 ;;
  esac
  fleet_ui_person_lang && return 0
  if [ -n "${FLEET_VIEW_LANG+x}" ]; then
    case "$FLEET_VIEW_LANG" in
      ''|C|C.*|POSIX|POSIX.*|zh*|ZH*) printf 'zh\n' ;;
      *) printf 'en\n' ;;
    esac
    return 0
  fi
  case "${LC_ALL:-${LC_MESSAGES:-${LC_CTYPE:-${LANG:-}}}}" in
    zh*|ZH*) printf 'zh\n' ;;
    en*|EN*) printf 'en\n' ;;
    ''|C|POSIX) printf 'zh\n' ;;
    *)       printf 'en\n' ;;
  esac
}

# fleet_ui_person_lang — the person's own choice (rule 1 above): zh | en, rc 1
# when they never set one. FLEET_UI_PERSON_FILE is the selftest seam.
fleet_ui_person_lang() {
  _fup_f=${FLEET_UI_PERSON_FILE:-${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/person-bundle.json}
  [ -f "$_fup_f" ] || return 1
  _fup_v=$(sed -n 's/.*"ui_lang": *"\([a-z]*\)".*/\1/p' "$_fup_f" 2>/dev/null | head -n 1)
  case "$_fup_v" in zh|en) printf '%s\n' "$_fup_v" ;; *) return 1 ;; esac
}

# fleet_ui_first_hint <device> — the one-time line a 看台's top line wears for 8 s
# (issue #3329, D8, L4): printed — and <device> stamped — only when this
# connection's language was DETECTED (FLEET_UI_LANG auto, no person's choice, a
# FLEET_VIEW_LANG the client said) as something other than the Chinese default,
# the first time <device> (the 看台's view id) comes in. rc 1 = nothing to say. A
# stamp that cannot be written fails open: the line shows again next time.
fleet_ui_first_hint() {
  case "${FLEET_UI_LANG:-auto}" in auto) ;; *) return 1 ;; esac
  fleet_ui_person_lang >/dev/null && return 1
  [ -n "${FLEET_VIEW_LANG:-}" ] || return 1
  [ "$(fleet_ui_lang)" = en ] || return 1
  case "${1:-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  _fuf_d=${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/entry
  [ -e "$_fuf_d/$1.lang-hinted" ] && return 1
  mkdir -p "$_fuf_d" 2>/dev/null
  { true > "$_fuf_d/$1.lang-hinted"; } 2>/dev/null || true
  fleet_ui_t view_lang_auto_fmt "$FLEET_VIEW_LANG"
}

fleet_ui_pin() { _FLEET_UI_L=$(fleet_ui_lang); }

fleet_ui_t() {
  _fleet_ui_key=$1
  shift 2>/dev/null || :
  case "${_FLEET_UI_L:-$(fleet_ui_lang)}:$_fleet_ui_key" in
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
    zh:wait_human)              printf '等人扫码 / 点击' ;;
    en:wait_human)              printf 'waiting on a person to scan / click' ;;
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
    zh:needs_auth)              printf '待登录' ;;
    en:needs_auth)              printf 'login' ;;
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
    zh:badge_user_fmt)          printf '%s' "${1:-}" ;;
    en:badge_user_fmt)          printf '%s' "${1:-}" ;;
    zh:badge_hubdown_fmt)       printf '%s · 入口连不上' "${1:-}" ;;
    en:badge_hubdown_fmt)       printf '%s · hub unreachable' "${1:-}" ;;
    zh:badge_hubrefused_fmt)    printf '%s · 入口不认这台电脑 · 请重新扫码（fleet login）' "${1:-}" ;;
    en:badge_hubrefused_fmt)    printf '%s · the hub refused this computer · scan again (fleet login)' "${1:-}" ;;
    zh:badge_rescan_note)       printf '入口不认这台电脑的证书，续期也没用 — 请重新扫码：点左下角，或运行 fleet login' ;;
    en:badge_rescan_note)       printf 'The hub refuses this computer'"'"'s certificate and renewing will not help — scan again: tap the bottom left, or run fleet login' ;;
    zh:client_who_fmt)          printf '登录人 %s（GitHub）· 这台电脑 %s，登录 %s · 证书可进的机器登录：%s' "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
    en:client_who_fmt)          printf 'signed in as %s (GitHub) · this computer %s, login %s · machine logins the certificate opens: %s' "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
    zh:badge_updated_fmt)       printf '✓ 已更新到 %s' "${1:-}" ;;
    en:badge_updated_fmt)       printf '✓ updated to %s' "${1:-}" ;;
    zh:badge_reloaded)          printf '✓ 已重新载入新文件' ;;
    en:badge_reloaded)          printf '✓ reloaded the new files' ;;
    zh:badge_update_failed_fmt) printf '更新没成功：%s' "${1:-}" ;;
    en:badge_update_failed_fmt) printf 'update failed: %s' "${1:-}" ;;
    zh:badge_update_later)      printf '新版已就绪 · 下次打开生效' ;;
    en:badge_update_later)      printf 'new version ready · takes effect next open' ;;
    zh:badge_update_pending_fmt) printf '待换新（%s）' "${1:-}" ;;
    en:badge_update_pending_fmt) printf 'update pending (%s)' "${1:-}" ;;
    zh:peer_hub_lost_fmt)       printf '入口失联，机器间访问暂停；你可直接 `fleet %s` 进去' "${1:-}" ;;
    en:peer_hub_lost_fmt)       printf 'hub lost — machine-to-machine access paused; you can still go in directly with `fleet %s`' "${1:-}" ;;
    zh:pin_heading_fmt)         printf '置顶 (%s)' "${1:-}" ;;
    en:pin_heading_fmt)         printf 'Pinned (%s)' "${1:-}" ;;
    zh:ended_heading_fmt)       printf '已结束 · 还开着 (%s)' "${1:-}" ;;
    en:ended_heading_fmt)       printf 'Ended · still open (%s)' "${1:-}" ;;
    zh:attn_summary_fmt)        printf '! %s 个在问你 · 点这里跳过去 ⌃K' "${1:-}" ;;
    en:attn_summary_fmt)        printf '! %s need you · tap here ⌃K' "${1:-}" ;;
    zh:attn_summary_dash_fmt)   printf '! %s 个在问你' "${1:-}" ;;
    en:attn_summary_dash_fmt)   printf '! %s waiting on you' "${1:-}" ;;
    zh:unknown_repo_heading)    printf '? · 未知仓库' ;;
    en:unknown_repo_heading)    printf '? · unknown repo' ;;
    zh:no_repo)                 printf '无仓库' ;;
    en:no_repo)                 printf 'no repo' ;;
    zh:empty_sidebar)           printf '暂无会话 — ⌘N 新会话' ;;
    en:empty_sidebar)           printf 'No sessions — ⌘N new session' ;;
    zh:empty_dash)              printf '暂无会话 — ⌘P 里新开一个' ;;
    en:empty_dash)              printf 'No sessions — start one from ⌘P' ;;
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
    zh:switch_quit)             printf '退出 fleet' ;;
    en:switch_quit)             printf 'Quit fleet' ;;
    zh:quickopen_cmd_for_fmt)   printf '对 %s' "${1:-}" ;;
    en:quickopen_cmd_for_fmt)   printf 'on %s' "${1:-}" ;;
    zh:quickopen_cmd_none)      printf '这里没有能做的事' ;;
    en:quickopen_cmd_none)      printf 'nothing to do here' ;;
    zh:quickopen_cmd_loading)   printf '读命令…' ;;
    en:quickopen_cmd_loading)   printf 'reading commands…' ;;
    zh:quickopen_keys)          printf '↵ 切过去  ⌃R 改名  ⌃X 回收  ⌃A 回答  ⌃E 回收方式  ⌃O PR  ⌃T 置顶  > 命令  esc 关' ;;
    en:quickopen_keys)          printf '↵ go  ⌃R rename  ⌃X close  ⌃A answer  ⌃E reap  ⌃O PR  ⌃T pin  > commands  esc close' ;;
    # a lost machine's rows (issue #3164)
    zh:quickopen_stale_fmt)     printf '远端列表 %s 没更新 · 标「失联」的行可能已不在' "${1:-}" ;;
    en:quickopen_stale_fmt)     printf "the other machines' list is %s old · rows marked lost may be gone" "${1:-}" ;;
    zh:quickopen_lost)          printf '失联' ;;
    en:quickopen_lost)          printf 'lost' ;;
    zh:quickopen_cmd_keys)      printf '↵ 执行  ↑↓ 选  ⌫ 回到会话  esc 关' ;;
    en:quickopen_cmd_keys)      printf '↵ run  ↑↓ pick  ⌫ back to sessions  esc close' ;;
    # the 看台's switcher (issue #3000, EPIC #2999 C2; #2752: no word to guess)
    zh:view_title) printf '会话' ;;
    en:view_title) printf 'Sessions' ;;
    zh:view_keys) printf '↵ 切过去  Tab 操作  ↑↓ 选  打字筛选  ? 图例  esc 关  ↑ 到 ⚡' ;;
    en:view_keys) printf '↵ go  Tab act  ↑↓ pick  type to filter  ? legend  esc close  ↑ to ⚡' ;;
    zh:view_grp_pin_fmt) printf '置顶 %s' "${1:-}" ;;
    en:view_grp_pin_fmt) printf 'Pinned %s' "${1:-}" ;;
    zh:view_grp_ask_fmt) printf '等你 %s' "${1:-}" ;;
    en:view_grp_ask_fmt) printf 'Waiting on you %s' "${1:-}" ;;
    zh:view_grp_work_fmt) printf '在干活 %s' "${1:-}" ;;
    en:view_grp_work_fmt) printf 'Working %s' "${1:-}" ;;
    zh:view_grp_wait_fmt) printf '等合并 / 等发版 %s' "${1:-}" ;;
    en:view_grp_wait_fmt) printf 'Waiting to merge / ship %s' "${1:-}" ;;
    zh:view_stage_checking) printf '检查中' ;;
    en:view_stage_checking) printf 'checks running' ;;
    zh:view_stage_red) printf '检查红' ;;
    en:view_stage_red) printf 'checks red' ;;
    zh:view_stage_green) printf '可合并' ;;
    en:view_stage_green) printf 'ready to merge' ;;
    zh:view_stage_train) printf '等发布列车' ;;
    en:view_stage_train) printf 'waiting for the release train' ;;
    zh:view_stage_deploying) printf '部署中' ;;
    en:view_stage_deploying) printf 'deploying' ;;
    zh:view_stage_deploy_red) printf '部署红' ;;
    en:view_stage_deploy_red) printf 'deploy red' ;;
    zh:view_ask_open) printf '在问你（见单上的 ⛔）' ;;
    en:view_ask_open) printf 'asking you (see the ⛔ on its issue)' ;;
    zh:view_grp_done_fmt) printf '做完待收 %s' "${1:-}" ;;
    en:view_grp_done_fmt) printf 'Done, to collect %s' "${1:-}" ;;
    zh:view_grp_landed_fmt) printf '刚落地 %s' "${1:-}" ;;
    en:view_grp_landed_fmt) printf 'Just landed %s' "${1:-}" ;;
    zh:view_grp_other_fmt) printf '其他 %s' "${1:-}" ;;
    en:view_grp_other_fmt) printf 'Other %s' "${1:-}" ;;
    zh:view_tag_lost_fmt) printf '%s 失联' "${1:-}" ;;
    en:view_tag_lost_fmt) printf '%s lost' "${1:-}" ;;
    zh:view_tag_lost_min_fmt) printf '失联 %s 分钟' "${1:-}" ;;
    en:view_tag_lost_min_fmt) printf 'lost %s min' "${1:-}" ;;
    zh:view_stale_banner_fmt) printf '%s 的会话 %s 分钟没更新（连不上入口）· 正在重连' "${1:-}" "${2:-}" ;;
    en:view_stale_banner_fmt) printf 'sessions on %s not updated for %s min (hub unreachable) · reconnecting' "${1:-}" "${2:-}" ;;
    zh:view_hub_down_banner_fmt) printf '入口 %s 分钟没响应 · 正在重连' "${1:-}" ;;
    en:view_hub_down_banner_fmt) printf 'hub not answering for %s min · reconnecting' "${1:-}" ;;
    zh:view_lost_go_fmt) printf '%s 失联，进不去 · 正在重连' "${1:-}" ;;
    en:view_lost_go_fmt) printf '%s is lost, cannot go there · reconnecting' "${1:-}" ;;
    zh:view_lost_act_fmt) printf '%s 失联，做不了 · 正在重连' "${1:-}" ;;
    en:view_lost_act_fmt) printf '%s is lost, cannot do that · reconnecting' "${1:-}" ;;
    zh:view_tag_direct_fmt) printf '%s 直连' "${1:-}" ;;
    en:view_tag_direct_fmt) printf '%s direct' "${1:-}" ;;
    zh:view_tag_cfg_broken) printf '会坏·需重开' ;;
    en:view_tag_cfg_broken) printf 'breaks·reopen' ;;
    zh:view_legend_needs) printf '等你' ;;
    en:view_legend_needs) printf 'waiting on you' ;;
    zh:view_legend_fail) printf '失败' ;;
    en:view_legend_fail) printf 'failed' ;;
    zh:view_legend_work) printf '运行中' ;;
    en:view_legend_work) printf 'running' ;;
    zh:view_legend_done) printf '已完成' ;;
    en:view_legend_done) printf 'done' ;;
    zh:view_legend_exited) printf '已退出' ;;
    en:view_legend_exited) printf 'exited' ;;
    zh:view_legend_idle) printf '空闲' ;;
    en:view_legend_idle) printf 'idle' ;;
    zh:view_match_issue_fmt) printf '匹配：关联 issue %s' "${1:-}" ;;
    en:view_match_issue_fmt) printf 'matched: linked issue %s' "${1:-}" ;;
    zh:view_agent_unknown) printf '未知' ;;
    en:view_agent_unknown) printf 'unknown' ;;
    zh:view_id_conflict) printf '同一段对话开在两个窗口' ;;
    en:view_id_conflict) printf 'one conversation open in two windows' ;;
    zh:view_id_conflict_fmt) printf '冲突：与 %s 共用同一段对话（%s）——关掉一个，另一个就恢复' "${1:-}" "${2:-}" ;;
    en:view_id_conflict_fmt) printf 'conflict: shares one conversation with %s (%s) — close one and the other recovers' "${1:-}" "${2:-}" ;;
    zh:view_id_head_fmt) printf '编号 %s  ·  %s' "${1:-}" "${2:-}" ;;
    en:view_id_head_fmt) printf 'ID %s  ·  %s' "${1:-}" "${2:-}" ;;
    zh:view_id_aliases_fmt) printf '别名 %s' "${1:-}" ;;
    en:view_id_aliases_fmt) printf 'aliases %s' "${1:-}" ;;
    zh:view_id_seg_fmt) printf '段 %s  %s  %s  %s' "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
    en:view_id_seg_fmt) printf 'seg %s  %s  %s  %s' "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
    zh:view_id_compact_fmt) printf '压缩×%s' "${1:-}" ;;
    en:view_id_compact_fmt) printf 'compacted×%s' "${1:-}" ;;
    zh:view_id_no_segs) printf '还没有对话段' ;;
    en:view_id_no_segs) printf 'no conversation segment yet' ;;
    zh:view_id_unhubbed) printf '未登记到 hub' ;;
    en:view_id_unhubbed) printf 'not registered with the hub' ;;
    zh:view_id_hub_refused) printf 'hub 拒收：完整 ID 已被另一台机器登记（整机克隆？）' ;;
    en:view_id_hub_refused) printf 'the hub refused it: another machine registered this full ID (a cloned machine?)' ;;
    zh:view_from_fmt) printf '来自 %s：%s' "${1:-}" "${2:-}" ;;
    en:view_from_fmt) printf 'from %s: %s' "${1:-}" "${2:-}" ;;
    zh:view_legend_lost) printf '失联' ;;
    en:view_legend_lost) printf 'lost' ;;
    zh:view_sec_ended_fmt) printf '已结束 · 还开着 %s 个' "${1:-}" ;;
    en:view_sec_ended_fmt) printf 'Ended · still open (%s)' "${1:-}" ;;
    zh:view_sec_gone_fmt) printf '已关闭 %s 个' "${1:-}" ;;
    en:view_sec_gone_fmt) printf 'Closed (%s)' "${1:-}" ;;
    zh:view_cmd_reapall_fmt) printf '⌫ 回收这 %s 个（有未提交改动的 worktree 保留）' "${1:-}" ;;
    en:view_cmd_reapall_fmt) printf '⌫ Reap these %s (a worktree with uncommitted changes is kept)' "${1:-}" ;;
    zh:view_cmd_older_fmt) printf '更早的 %s 个 → /fleet-history' "${1:-}" ;;
    en:view_cmd_older_fmt) printf '%s older → /fleet-history' "${1:-}" ;;
    zh:view_ended_reap_hint) printf 'Tab → 回收' ;;
    en:view_ended_reap_hint) printf 'Tab → reap' ;;
    zh:view_reapall_done_fmt) printf '回收了 %s 个' "${1:-}" ;;
    en:view_reapall_done_fmt) printf 'reaped %s' "${1:-}" ;;
    zh:view_reapall_kept_fmt) printf '%s 个有未提交改动：窗口已关，worktree 保留' "${1:-}" ;;
    en:view_reapall_kept_fmt) printf '%s with uncommitted changes: window closed, worktree kept' "${1:-}" ;;
    zh:view_reapall_left_fmt) printf '%s 个没收（还在忙或要确认）' "${1:-}" ;;
    en:view_reapall_left_fmt) printf '%s left (still busy or needs a confirm)' "${1:-}" ;;
    zh:view_reapall_failed_fmt) printf '%s 个失败' "${1:-}" ;;
    en:view_reapall_failed_fmt) printf '%s failed' "${1:-}" ;;
    zh:view_ago_fmt) printf '%s前' "${1:-}" ;;
    en:view_ago_fmt) printf '%s ago' "${1:-}" ;;
    zh:view_dur_m_fmt) printf '%s 分钟' "${1:-}" ;;
    en:view_dur_m_fmt) printf '%sm' "${1:-}" ;;
    zh:view_dur_h_fmt) printf '%s 小时' "${1:-}" ;;
    en:view_dur_h_fmt) printf '%sh' "${1:-}" ;;
    zh:view_dur_d_fmt) printf '%s 天' "${1:-}" ;;
    en:view_dur_d_fmt) printf '%sd' "${1:-}" ;;
    zh:view_ended_merged) printf '已合并' ;;
    en:view_ended_merged) printf 'merged' ;;
    zh:view_ended_exited) printf '已退出' ;;
    en:view_ended_exited) printf 'exited' ;;
    zh:view_ended_done) printf '本轮结束' ;;
    en:view_ended_done) printf 'turn ended' ;;
    zh:view_ended_gone) printf '窗口已回收' ;;
    en:view_ended_gone) printf 'window reaped' ;;
    zh:view_ended_gone_merged) printf '已合并 · 窗口已回收' ;;
    en:view_ended_gone_merged) printf 'merged · window reaped' ;;
    zh:view_gone_hint) printf '↵ 恢复' ;;
    en:view_gone_hint) printf '↵ restore' ;;
    zh:view_pr_fmt) printf 'PR %s' "${1:-}" ;;
    en:view_pr_fmt) printf 'PR %s' "${1:-}" ;;
    zh:view_today_fmt) printf '今天 %s token' "${1:-}" ;;
    en:view_today_fmt) printf '%s tokens today' "${1:-}" ;;
    zh:view_tok_style) printf 'zh' ;;
    en:view_tok_style) printf 'en' ;;
    zh:view_ask_restore) printf 'y 先 reopen PR 再恢复 · r 直接恢复 · 其它键取消' ;;
    en:view_ask_restore) printf 'y reopen the PR, then restore · r restore anyway · any other key cancels' ;;
    zh:view_state_needs) printf '在问你' ;;
    en:view_state_needs) printf 'asking' ;;
    zh:view_state_blocked) printf '卡住了' ;;
    en:view_state_blocked) printf 'blocked' ;;
    zh:view_state_failed) printf '失败' ;;
    en:view_state_failed) printf 'failed' ;;
    zh:view_state_working) printf '在干活' ;;
    en:view_state_working) printf 'working' ;;
    zh:view_state_looping) printf '循环中' ;;
    en:view_state_looping) printf 'looping' ;;
    zh:view_state_idle) printf '空闲' ;;
    en:view_state_idle) printf 'idle' ;;
    zh:view_state_done) printf '本轮结束' ;;
    en:view_state_done) printf 'turn ended' ;;
    zh:view_state_exited) printf '已退出' ;;
    en:view_state_exited) printf 'exited' ;;
    zh:view_state_landed) printf '已合并' ;;
    en:view_state_landed) printf 'landed' ;;
    zh:view_state_parked) printf '停放' ;;
    en:view_state_parked) printf 'parked' ;;
    zh:view_reap_merged) printf '合并后关' ;;
    en:view_reap_merged) printf 'closes after merge' ;;
    zh:view_reap_merged_for) printf '合并后 %s关' "${1:-}" ;;
    en:view_reap_merged_for) printf 'closes %s after merge' "${1:-}" ;;
    zh:view_reap_done) printf '做完就关' ;;
    en:view_reap_done) printf 'closes when done' ;;
    zh:view_reap_done_for) printf '空闲 %s关' "${1:-}" ;;
    en:view_reap_done_for) printf 'closes after %s idle' "${1:-}" ;;
    zh:view_reap_loop_end) printf '循环停了关' ;;
    en:view_reap_loop_end) printf 'closes when its loop stops' ;;
    zh:view_reap_at) printf '%s 关' "${1:-}" ;;
    en:view_reap_at) printf 'closes at %s' "${1:-}" ;;
    zh:view_reap_keep) printf '不自动关' ;;
    en:view_reap_keep) printf 'never closed by itself' ;;
    zh:view_far_fmt) printf '%s 这台还没接上' "${1:-}" ;;
    en:view_far_fmt) printf '%s is not connected yet' "${1:-}" ;;
    # the keys issue #3328 folded into ⌘P: what a forwarded one says, once
    zh:view_forward_fmt) printf '%s 已并进 ⌘P' "${1:-}" ;;
    en:view_forward_fmt) printf '%s is part of ⌘P now' "${1:-}" ;;
    zh:view_keys_moved) printf '快捷键只剩 ⌘P：翻会话、新任务、shell、退出都在里面（⌘↑↓ ⌘[ ⌘] ⌘T ⌘N 下一版删）' ;;
    en:view_keys_moved) printf 'One key now, ⌘P: switching sessions, a new task, a shell, quit are all in it (⌘↑↓ ⌘[ ⌘] ⌘T ⌘N go next version)' ;;
    zh:view_gone) printf '这个会话已经不在了' ;;
    en:view_gone) printf 'that session is gone' ;;
    zh:view_new_failed) printf '新会话没开起来' ;;
    en:view_new_failed) printf 'the new session did not open' ;;
    # …and why (issue #3458): the spawner's own line, never dropped
    zh:view_new_failed_fmt) printf '新会话没开起来：%s' "${1:-}" ;;
    en:view_new_failed_fmt) printf 'the new session did not open: %s' "${1:-}" ;;
    zh:view_new_timeout_fmt) printf '%s 秒内没开出来' "${1:-}" ;;
    en:view_new_timeout_fmt) printf 'not open within %ss' "${1:-}" ;;
    zh:view_new_exit_fmt) printf '退出码 %s，没说原因' "${1:-}" ;;
    en:view_new_exit_fmt) printf 'exit %s, no reason given' "${1:-}" ;;
    # EPIC #3178 round 2 (issue #3324): the ⌘P panel's next words, for ④ ⑥
    zh:view_count_fmt) printf '会话 %s' "${1:-}" ;;
    en:view_count_fmt) printf 'Sessions %s' "${1:-}" ;;
    zh:view_page_keys_fmt) printf '↵ 执行  ↑↓ 选  %s 直接执行  [ ] 上一个/下一个会话  esc 回列表' "${1:-}" ;;
    en:view_page_keys_fmt) printf '↵ run  ↑↓ pick  %s run it  [ ] previous/next session  esc list' "${1:-}" ;;
    zh:view_choice_keys_fmt) printf '↵ 选定  ↑↓ 选  %s 直接选  esc 返回' "${1:-}" ;;
    en:view_choice_keys_fmt) printf '↵ choose  ↑↓ pick  %s choose it  esc back' "${1:-}" ;;
    zh:view_ask_keys) printf '↵ 确定  ↑↓ 选  esc 回列表' ;;
    en:view_ask_keys) printf '↵ confirm  ↑↓ pick  esc list' ;;
    zh:view_ask_keys_back) printf '↵ 确定  ↑↓ 选  esc 回操作页' ;;
    en:view_ask_keys_back) printf '↵ confirm  ↑↓ pick  esc actions' ;;
    zh:view_compose_keys) printf 'Tab/↑↓ 换项  ←→ 换仓库 / Agent  ↵ 开  esc 回列表' ;;
    en:view_compose_keys) printf 'Tab/↑↓ item  ←→ repo / Agent  ↵ open  esc list' ;;
    zh:view_narrow) printf '窄屏：建议 ≥48 列；Tab/esc 可用' ;;
    en:view_narrow) printf 'Narrow: use ≥48 cols; Tab/esc work' ;;
    zh:view_overlay_gone) printf '来源已失效；请回列表重新选择' ;;
    en:view_overlay_gone) printf 'Source unavailable; select it again in the list' ;;
    zh:view_composer) printf '新会话' ;;
    en:view_composer) printf 'New session' ;;
    zh:view_new_open) printf '开 ↵' ;;
    en:view_new_open) printf 'Open ↵' ;;
    zh:view_cancel) printf '取消' ;;
    en:view_cancel) printf 'Cancel' ;;
    zh:view_confirm) printf '确定' ;;
    en:view_confirm) printf 'Confirm' ;;
    zh:view_draft_save_failed) printf '草稿未能保存到磁盘' ;;
    en:view_draft_save_failed) printf 'Could not save draft to disk' ;;
    zh:view_draft_agent_gone) printf '所选 Agent 已不可用；请重新选择' ;;
    en:view_draft_agent_gone) printf 'Selected agent unavailable; choose again' ;;
    zh:view_draft_repo_gone) printf '所选仓库已不可用；请重新选择' ;;
    en:view_draft_repo_gone) printf 'Selected repository unavailable; choose again' ;;
    zh:view_grid_loading) printf '正在读取仓库和 Agent，请稍候' ;;
    en:view_grid_loading) printf 'Loading repositories and agents; please wait' ;;
    zh:view_search_ph) printf '搜索会话' ;;
    en:view_search_ph) printf 'Search sessions' ;;
    zh:view_cmd_blank) printf '⚡ 新会话' ;;
    en:view_cmd_blank) printf '⚡ New session' ;;
    zh:view_grid_repo) printf '仓库' ;;
    en:view_grid_repo) printf 'Repo' ;;
    zh:view_grid_norepo) printf '不绑仓库' ;;
    en:view_grid_norepo) printf 'No repo' ;;
    zh:view_grid_agent) printf 'Agent' ;;
    en:view_grid_agent) printf 'Agent' ;;
    zh:view_grid_only_fmt) printf '只开放了 %s，就用它' "${1:-}" ;;
    en:view_grid_only_fmt) printf 'only %s is open to you — using it' "${1:-}" ;;
    zh:view_new_agent_fmt) printf '%s — 这次用 %s 开' "${1:-}" "${2:-}" ;;
    en:view_new_agent_fmt) printf '%s — opening %s instead' "${1:-}" "${2:-}" ;;
    zh:view_client_behind_fmt) printf '客户端不是最新（%s，最新 %s）— 在你自己的电脑上运行 fleet update，再重开 fleet' "${1:-}" "${2:-}" ;;
    en:view_client_behind_fmt) printf 'your client is not the latest (%s, latest %s) — run fleet update on your own computer, then reopen fleet' "${1:-}" "${2:-}" ;;
    zh:view_started_fmt) printf '已开工 · T%s' "${1:-}" ;;
    en:view_started_fmt) printf 'started · T%s' "${1:-}" ;;
    zh:view_lang_row) printf '语言 / Language　中文 ✓ · English' ;;
    en:view_lang_row) printf 'Language / 语言　English ✓ · 中文' ;;
    zh:view_lang_saved) printf '界面语言：中文 · 已存到你的账号' ;;
    en:view_lang_saved) printf 'Language: English · saved to your account' ;;
    zh:view_lang_auto_fmt) printf '已按你的系统用中文 · ⌘P → 语言 可改' ;;
    en:view_lang_auto_fmt) printf 'Using English from your system (LANG=%s) · ⌘P → Language to change' "${1:-}" ;;
    # the language row's own lines (issue #3329): ↵ flips, Tab picks, 跟系统走 clears the choice
    # ⌘P's 置顶 line (issue #3517): the session in view; ⌃T does it on any row
    zh:view_pin_current)   printf '置顶当前会话' ;;
    en:view_pin_current)   printf 'Pin the session in view' ;;
    zh:view_unpin_current) printf '取消置顶当前会话' ;;
    en:view_unpin_current) printf 'Unpin the session in view' ;;
    zh:view_pin_foot_fmt)  printf '%s · 任一行上按 ⌃T 也能置顶 / 取消' "${1:-}" ;;
    en:view_pin_foot_fmt)  printf '%s · ⌃T on any row pins / unpins it too' "${1:-}" ;;
    zh:view_lang_foot) printf '↵ 换成 English · 存到你的账号，换设备也跟着 · Tab 跟系统走' ;;
    en:view_lang_foot) printf '↵ switch to 中文 · saved to your account, follows you to every device · Tab follow the system' ;;
    zh:view_lang_nolang_fmt) printf '没收到你的系统语言（Termius → Hosts → %s → Environment 加 LANG=en_US.UTF-8）· ↵ 换成 English' "${1:-}" ;;
    en:view_lang_nolang_fmt) printf 'Your system language did not arrive (Termius → Hosts → %s → Environment: LANG=en_US.UTF-8) · ↵ switch to 中文' "${1:-}" ;;
    zh:view_lang_auto) printf '跟系统走' ;;
    en:view_lang_auto) printf 'Follow the system' ;;
    zh:view_lang_auto_saved) printf '界面语言：跟系统走 · 已存到你的账号' ;;
    en:view_lang_auto_saved) printf 'Language: follow the system · saved to your account' ;;
    zh:view_lang_failed_fmt) printf '语言没换：%s' "${1:-}" ;;
    en:view_lang_failed_fmt) printf 'Language not changed: %s' "${1:-}" ;;
    # the door's one welcome line (issue #3329, L4) — printed only as you come in
    zh:door_welcome) printf '欢迎回来。⌃空格 打开面板。' ;;
    en:door_welcome) printf 'Welcome back. ⌃Space opens the panel.' ;;
    zh:view_door_welcome) printf '欢迎回来。⌃空格 打开面板。' ;;
    en:view_door_welcome) printf 'Welcome back. ⌃Space opens the panel.' ;;
    # the onboarding guide's fixed lines (issue #3332, EPIC #3178 C20): a newcomer
    # who never wrote code — one key, one thing done; only `dev` names code / a PR
    zh:onboard_hello) printf '你好！我是这台电脑上的向导。两三分钟：教你一个键，再帮你把一件事当场做完。' ;;
    en:onboard_hello) printf "Hi! I'm the guide on this computer. Two or three minutes: one key to learn, then one thing done for you, right now." ;;
    zh:onboard_key) printf '只要记住一个键：电脑上 ⌘P，手机上 ⌃空格。它打开一个面板，你所有的会话都在里面；最底下带 ⚡ 的那一行，用来交代一件新的事。' ;;
    en:onboard_key) printf 'There is one key to remember: ⌘P on a computer, ⌃Space on a phone. It opens a panel with all your sessions; the ⚡ row at the bottom is where you hand over something new.' ;;
    zh:onboard_try) printf '现在试一下：按 ⌘P（手机 ⌃空格），直接写一件你想做的事——比如「帮我写一封请假邮件」——然后回车。' ;;
    en:onboard_try) printf 'Try it now: press ⌘P (phone: ⌃Space), write one thing you would like done — say, "draft an email asking for Friday off" — and press Enter.' ;;
    zh:onboard_sent) printf '收到，它已经在一个新会话里开工了。面板里它那一行是 » 就是在干活，变成 ✓ 就是做完了；按 ⌘P，选它，回车，就能过去看。' ;;
    en:onboard_sent) printf 'Got it — a new session has started on it. In the panel, » on its row means working and ✓ means done; press ⌘P, pick it, Enter, to watch.' ;;
    zh:onboard_done) printf '做完了！以后就这样：⌘P，写一句，回车。' ;;
    en:onboard_done) printf "Done! That is all there is from now on: ⌘P, write one line, Enter." ;;
    zh:onboard_more) printf '想再交代一件，随时 ⌘P；想回来找我，在 ⌘P 里选 guide 这一行。' ;;
    en:onboard_more) printf 'Anything else, any time: ⌘P. To come back to me, pick the guide row in ⌘P.' ;;
    zh:view_cmd_quit) printf '⏻ 退出 fleet（会话在后台继续）' ;;
    en:view_cmd_quit) printf '⏻ Quit fleet (sessions keep running)' ;;
    # issue #3327 (EPIC #3178 ④): the ⚡ row's keys line, its no-hit note, its progress
    zh:view_keys_match_fmt) printf '↵ 切到 %s  ↓ 到 ⚡ 预填「%s」  esc 关' "${1:-}" "${2:-}" ;;
    en:view_keys_match_fmt) printf '↵ go to %s  ↓ to ⚡ draft "%s"  esc close' "${1:-}" "${2:-}" ;;
    zh:view_keys_epic) printf '→ 展开 / ← 收起' ;;
    en:view_keys_epic) printf '→ expand / ← collapse' ;;
    zh:view_keys_short) printf '↵ 进入/编辑  Tab 操作  ↑↓ 选  esc 关' ;;
    en:view_keys_short) printf '↵ go/edit  Tab act  ↑↓ pick  esc' ;;
    zh:view_keys_sending) printf '开窗中，esc 可以先关，文字只预填不发送' ;;
    en:view_keys_sending) printf 'opening — esc closes the panel; the draft will not be sent' ;;
    zh:view_nomatch) printf '没有会话叫这句话' ;;
    en:view_nomatch) printf 'no session goes by these words' ;;
    zh:view_task_starting_fmt) printf '⚡ 开窗中… %s' "${1:-}" ;;
    en:view_task_starting_fmt) printf '⚡ starting… %s' "${1:-}" ;;
    zh:view_task_opening) printf '⚡ 开会话中…' ;;
    en:view_task_opening) printf '⚡ opening a session…' ;;
    zh:view_task_step_fmt) printf '… 开会话 · %s' "${1:-}" ;;
    en:view_task_step_fmt) printf '… opening the session · %s' "${1:-}" ;;
    zh:view_sess_issue_fmt) printf '#%s 「%s」' "${1:-}" "${2:-}" ;;
    en:view_sess_issue_fmt) printf '#%s "%s"' "${1:-}" "${2:-}" ;;
    zh:view_sess_fmt) printf '「%s」' "${1:-}" ;;
    en:view_sess_fmt) printf '"%s"' "${1:-}" ;;
    zh:view_peer_wait_fmt) printf '正在连 %s…' "${1:-}" ;;
    en:view_peer_wait_fmt) printf 'connecting to %s…' "${1:-}" ;;
    zh:view_shell_title_fmt) printf 'shell · %s @%s' "${1:-}" "${2:-}" ;;
    en:view_shell_title_fmt) printf 'shell · %s @%s' "${1:-}" "${2:-}" ;;
    zh:view_shell_home_fmt) printf '%s shell' "${1:-}" ;;
    en:view_shell_home_fmt) printf '%s shell' "${1:-}" ;;
    zh:view_shell_failed_fmt) printf '%s 的 shell 开不了' "${1:-}" ;;
    en:view_shell_failed_fmt) printf 'cannot open a shell on %s' "${1:-}" ;;
    zh:view_shell_nolink_fmt) printf '到 %s 的连接还没好，shell 开不了。按任意键关闭。' "${1:-}" ;;
    en:view_shell_nolink_fmt) printf 'the link to %s is not up — no shell. Press a key to close.' "${1:-}" ;;
    zh:view_shell_gone_fmt) printf '这个会话已不在 %s 上（结束或搬走了）。按任意键关闭。' "${1:-}" ;;
    en:view_shell_gone_fmt) printf 'that session is no longer on %s (ended or moved). Press a key to close.' "${1:-}" ;;
    zh:view_dispatch_title) printf '派一件事' ;;
    en:view_dispatch_title) printf 'Dispatch' ;;
    # --- a row's actions: Tab (issue #3181, fleet_view.py ACTIONS) — the old row
    # menu's words (menu_*), one per action
    zh:view_act_enter)          printf '进入' ;;
    en:view_act_enter)          printf 'Enter' ;;
    zh:view_act_shell)          printf '在它的目录开 shell' ;;
    en:view_act_shell)          printf 'Shell in its directory' ;;
    zh:view_act_pr_fmt)         printf '打开 PR %s' "${1:-}" ;;
    en:view_act_pr_fmt)         printf 'Open PR %s' "${1:-}" ;;
    zh:view_act_pr_unknown)     printf 'PR ?（入口没响应）' ;;
    en:view_act_pr_unknown)     printf 'PR ? (hub not answering)' ;;
    zh:view_act_pr_unknown_fmt) printf 'PR ?（入口 %s 分钟没响应）' "${1:-}" ;;
    en:view_act_pr_unknown_fmt) printf 'PR ? (hub not answering for %s min)' "${1:-}" ;;
    zh:view_act_answer)         printf '回答…' ;;
    en:view_act_answer)         printf 'Answer…' ;;
    zh:view_act_message)        printf '发一句话…' ;;
    en:view_act_message)        printf 'Send a message…' ;;
    zh:view_act_rename)         printf '改名…' ;;
    en:view_act_rename)         printf 'Rename…' ;;
    zh:view_act_pin)            printf '置顶' ;;
    en:view_act_pin)            printf 'Pin' ;;
    zh:view_act_unpin)          printf '取消置顶' ;;
    en:view_act_unpin)          printf 'Unpin' ;;
    zh:view_act_reappol)        printf '改回收方式…' ;;
    en:view_act_reappol)        printf 'Reap policy…' ;;
    zh:view_act_stop)           printf '停下（可恢复）' ;;
    en:view_act_stop)           printf 'Stop (resumable)' ;;
    zh:view_act_resume)         printf '继续' ;;
    en:view_act_resume)         printf 'Resume' ;;
    zh:view_act_restore)        printf '恢复' ;;
    en:view_act_restore)        printf 'Restore' ;;
    # another machine's row (issue #4184): its accounts are that login's — the
    # hub's worker_switch picks the active one there
    zh:view_act_agent_fmt)      printf '换成 %s' "${1:-}" ;;
    en:view_act_agent_fmt)      printf 'Switch to %s' "${1:-}" ;;
    zh:view_act_reap)           printf '回收…' ;;
    en:view_act_reap)           printf 'Reap…' ;;
    zh:view_act_reapall)        printf '回收这一组' ;;
    en:view_act_reapall)        printf 'Reap this group' ;;
    zh:view_act_history)        printf '打开历史' ;;
    en:view_act_history)        printf 'Open history' ;;
    zh:view_act_keys)           printf '↑↓ 选 · ↵ 确定 · esc 返回' ;;
    en:view_act_keys)           printf '↑↓ pick · ↵ choose · esc back' ;;
    zh:view_act_done_fmt)       printf '✓ %s' "${1:-}" ;;
    en:view_act_done_fmt)       printf '✓ %s' "${1:-}" ;;
    zh:view_act_failed_fmt)     printf '✗ %s %s' "${1:-}" "${2:-}" ;;
    en:view_act_failed_fmt)     printf '✗ %s %s' "${1:-}" "${2:-}" ;;
    zh:view_act_sent_fmt)       printf '%s：已在后台做' "${1:-}" ;;
    en:view_act_sent_fmt)       printf '%s: under way' "${1:-}" ;;
    zh:view_act_nothing)        printf '没有可选的' ;;
    en:view_act_nothing)        printf 'nothing to pick' ;;
    zh:view_ask_rename)         printf '新名字› ' ;;
    en:view_ask_rename)         printf 'New name› ' ;;
    zh:view_ask_message)        printf '发给它› ' ;;
    en:view_ask_message)        printf 'Message› ' ;;
    zh:view_ask_perm)           printf '批准吗？y 批准 · n 拒绝 ' ;;
    en:view_ask_perm)           printf 'Allow it? y yes · n no ' ;;
    zh:view_ask_pick)           printf '选第几个（几道题用空格隔开）› ' ;;
    en:view_ask_pick)           printf 'Option number(s), one per question› ' ;;
    zh:view_ask_at)             printf '几点回收（HH:MM）› ' ;;
    en:view_ask_at)             printf 'Reap at (HH:MM)› ' ;;
    zh:view_ask_reap_fmt)       printf '回收「%s」？(y/n) ' "${1:-}" ;;
    en:view_ask_reap_fmt)       printf 'Reap "%s"? (y/n) ' "${1:-}" ;;
    zh:view_ask_reapall_fmt)    printf '回收这 %s 个？还在忙的跳过，有未提交改动的 worktree 保留 (y/n) ' "${1:-}" ;;
    en:view_ask_reapall_fmt)    printf 'Reap these %s? Busy ones are skipped, a worktree with uncommitted changes is kept (y/n) ' "${1:-}" ;;
    # ⌘P's 连接路线… (claude-fleet#2886): pin the route to a machine — `fleet route`
    zh:popup_route)             printf '连接路线' ;;
    en:popup_route)             printf 'Connection route' ;;
    zh:popup_new_task)          printf '新建任务' ;;
    en:popup_new_task)          printf 'New task' ;;
    zh:popup_answer)            printf '回答' ;;
    en:popup_answer)            printf 'Answer' ;;
    zh:popup_repo_add)          printf '添加仓库' ;;
    en:popup_repo_add)          printf 'Add repo' ;;
    # ⌘P's 添加仓库… and dash-repo-add.sh's words (issue #3375): a result token
    # (fleet-repo.sh add's) is never shown bare — each has its sentence here
    zh:repo_add_header_fmt)     printf '加仓库到 %s  ·  输入 owner/name，或粘贴 GitHub 链接  ·  ↵ 加入 · esc 取消 · [✕ close]' "${1:-}" ;;
    en:repo_add_header_fmt)     printf 'Add a repo to %s  ·  type owner/name, or paste a GitHub link  ·  ↵ add · esc cancel · [✕ close]' "${1:-}" ;;
    zh:repo_add_hosted_list_fmt) printf '已托管：%s' "${1:-}" ;;
    en:repo_add_hosted_list_fmt) printf 'Already here: %s' "${1:-}" ;;
    zh:repo_add_none)           printf '（无）' ;;
    en:repo_add_none)           printf '(none)' ;;
    zh:repo_add_retry_fmt)      printf '✗ 这不像一个仓库：%s —— 写 owner/name，或粘贴 GitHub 链接，再试一次' "${1:-}" ;;
    en:repo_add_retry_fmt)      printf '✗ That is not a repo: %s — type owner/name or paste a GitHub link, then try again' "${1:-}" ;;
    zh:repo_add_running_fmt)    printf '放到 %s —— 已经是这个仓库就直接用，没有就从 GitHub 拉（可能要几十秒）' "${1:-}" ;;
    en:repo_add_running_fmt)    printf 'Into %s — reused if it already is this repo, else pulled from GitHub (may take a while)' "${1:-}" ;;
    zh:repo_add_close)          printf '[✕ close]  ·  ↵ / esc 关闭' ;;
    en:repo_add_close)          printf '[✕ close]  ·  ↵ / esc to close' ;;
    zh:repo_add_added_fmt)      printf '✓ 已加入 %s —— 代码在 %s，已登记到这个 fleet' "${1:-}" "${2:-}" ;;
    en:repo_add_added_fmt)      printf '✓ Added %s — the code is in %s, and this fleet now hosts it' "${1:-}" "${2:-}" ;;
    zh:repo_add_hosted_fmt)     printf '%s 已在本 fleet 里，代码在 %s —— 不用再加' "${1:-}" "${2:-}" ;;
    en:repo_add_hosted_fmt)     printf '%s is already in this fleet, the code is in %s — nothing to do' "${1:-}" "${2:-}" ;;
    zh:repo_add_mismatch_fmt)   printf '✗ %s 里已经是别的仓库（不是 %s）—— 把那个文件夹挪开再试' "${1:-}" "${2:-}" ;;
    en:repo_add_mismatch_fmt)   printf '✗ %s already holds another repo (not %s) — move that folder away and try again' "${1:-}" "${2:-}" ;;
    zh:repo_add_notcheckout_fmt) printf '✗ %s 已经有个同名文件夹，但不是 git 仓库 —— 把它挪开再试' "${1:-}" ;;
    en:repo_add_notcheckout_fmt) printf '✗ %s already exists and is not a git repo — move it away and try again' "${1:-}" ;;
    zh:repo_add_invalid_fmt)    printf '✗ 这不像一个仓库：%s —— 写 owner/name，或粘贴 GitHub 链接' "${1:-}" ;;
    en:repo_add_invalid_fmt)    printf '✗ That is not a repo: %s — type owner/name or paste a GitHub link' "${1:-}" ;;
    zh:repo_add_net)            printf '✗ 拉不到 GitHub，网络不通 —— 网络好了再试一次' ;;  # no-gh-ok: a hint
    en:repo_add_net)            printf '✗ Cannot reach GitHub — the network is down; try again once it is back' ;;
    zh:repo_add_notfound_fmt)   printf '✗ GitHub 上找不到 %s —— 看看名字拼对没有；私有仓库要你有权限' "${1:-}" ;;
    en:repo_add_notfound_fmt)   printf '✗ GitHub has no %s — check the spelling; a private repo needs your access' "${1:-}" ;;
    zh:repo_add_auth)           printf '✗ GitHub 还没登录（或登录过期了）—— 先在终端运行 gh auth login，再试一次' ;;  # no-gh-ok: a hint
    en:repo_add_auth)           printf '✗ Not signed in to GitHub (or the sign-in expired) — run gh auth login in a terminal, then try again' ;;  # no-gh-ok: a hint
    zh:repo_add_clone)          printf '✗ 没拉下来 —— 原因见上面几行 git 的输出' ;;
    en:repo_add_clone)          printf '✗ The pull failed — the git lines above say why' ;;
    zh:repo_add_write)          printf '✗ 登记没写进去（磁盘满了，或没有写权限）' ;;
    en:repo_add_write)          printf '✗ Could not record it (disk full, or no write permission)' ;;
    zh:repo_add_nofleet)        printf '✗ 这台电脑上没有 fleet —— 要在跑会话的那台电脑上加仓库' ;;
    en:repo_add_nofleet)        printf '✗ There is no fleet on this computer — add the repo on the computer that runs the sessions' ;;
    zh:repo_add_noresult)       printf '✗ 没得到结果 —— 看上面的输出' ;;
    en:repo_add_noresult)       printf '✗ No result came back — see the lines above' ;;
    zh:repo_add_other)          printf '✗ 没加上 —— 看上面的输出' ;;
    en:repo_add_other)          printf '✗ Not added — see the lines above' ;;
    zh:hint_alerts)             printf '↵ 处理 · 1✖ 2▲ 3● 0全部 · m 静音1h · [✕ 关闭]' ;;
    en:hint_alerts)             printf '↵ act · 1✖ 2▲ 3● 0 all · m mute 1h · [✕ close]' ;;
    zh:toast_url_copied_fmt)    printf 'fleet: 链接已复制到剪贴板 — %s' "${1:-}" ;;
    en:toast_url_copied_fmt)    printf 'fleet: link copied to your clipboard — %s' "${1:-}" ;;
    zh:clip_hint)               printf 'fleet: 这个终端可能收不到会话里的复制 — Mac 上按住 ⌥ 拖选、iPad / 手机上长按选字，用终端自己的复制' ;;
    en:clip_hint)               printf 'fleet: this terminal may not receive a copy made in a session — hold ⌥ and drag on a Mac, long-press on an iPad / phone, to use the terminal'"'"'s own copy' ;;
    # --- toasts a tmux bind shows (issue #1535: no hardcoded English left)
    zh:toast_sidebar_home)      printf '任务栏：输入名称 ↵ 新会话 · ↑↓ 切换 · ↵/Esc 回任务 · 再按 ☰/F9 去 hub' ;;
    en:toast_sidebar_home)      printf 'Tasks: type a name ↵ = new session · ↑↓ switch · ↵/Esc worker · ☰/F9 again → hub' ;;
    zh:toast_sidebar_focus)     printf '任务栏：输入名称 ↵ 新会话 · . 行菜单 · ↑↓ 切换 · 空行 ←→ 折叠 · 有字时移光标 · ↵/Esc 回任务' ;;
    en:toast_sidebar_focus)     printf 'Tasks: type a name ↵ = new session · . = row menu · ↑↓ switch · empty line ←→ fold · with text ←→ move · ↵/Esc worker' ;;
    zh:toast_shell_sidebar)     printf '任务：↑↓ 切换 · ↵ 进入 · . 行菜单 · ? 快捷键 · Esc 返回' ;;
    en:toast_shell_sidebar)     printf 'Tasks: ↑↓ switch · ↵ enter · . row menu · ? keys · Esc back' ;;
    # the row menu's confirmed reap (fleet_view.py reap action), off dash-reap's token
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
    # a remote row's action, named for its toast / popup (fleet-row-remote.sh)
    zh:remote_label_stop_fmt)    printf '停 %s（在 %s）' "${1:-}" "${2:-}" ;;
    en:remote_label_stop_fmt)    printf 'stop %s (on %s)' "${1:-}" "${2:-}" ;;
    zh:remote_label_resume_fmt)  printf '继续 %s（在 %s）' "${1:-}" "${2:-}" ;;
    en:remote_label_resume_fmt)  printf 'resume %s (on %s)' "${1:-}" "${2:-}" ;;
    zh:remote_label_reap_fmt)    printf '回收 %s（在 %s）' "${1:-}" "${2:-}" ;;
    en:remote_label_reap_fmt)    printf 'reap %s (on %s)' "${1:-}" "${2:-}" ;;
    zh:remote_label_rename_fmt)  printf '%s 改名（在 %s）' "${1:-}" "${2:-}" ;;
    en:remote_label_rename_fmt)  printf 'rename %s (on %s)' "${1:-}" "${2:-}" ;;
    zh:remote_label_reappol_fmt) printf '%s 改回收方式（在 %s）' "${1:-}" "${2:-}" ;;
    en:remote_label_reappol_fmt) printf 'reap policy of %s (on %s)' "${1:-}" "${2:-}" ;;
    zh:remote_label_agent_fmt)   printf '%s 换成 %s（在 %s）' "${1:-}" "${2:-}" "${3:-}" ;;
    en:remote_label_agent_fmt)   printf 'switch %s to %s (on %s)' "${1:-}" "${2:-}" "${3:-}" ;;
    zh:remote_label_pin_on_fmt)  printf '置顶 %s（在 %s）' "${1:-}" "${2:-}" ;;
    en:remote_label_pin_on_fmt)  printf 'pin %s (on %s)' "${1:-}" "${2:-}" ;;
    zh:remote_label_pin_off_fmt) printf '取消置顶 %s（在 %s）' "${1:-}" "${2:-}" ;;
    en:remote_label_pin_off_fmt) printf 'unpin %s (on %s)' "${1:-}" "${2:-}" ;;
    zh:remote_reappol_hint)      printf '%s' 'merged[:时长] · done[:时长] · loop-end · at:<时间> · keep' ;;
    en:remote_reappol_hint)      printf '%s' 'merged[:dur] · done[:dur] · loop-end · at:<time> · keep' ;;
    zh:remote_reappol_bad_fmt)   printf '%s：「%s」不是回收方式' "${1:-}" "${2:-}" ;;
    en:remote_reappol_bad_fmt)   printf '%s: "%s" is not a reap policy' "${1:-}" "${2:-}" ;;
    zh:remote_label_message_fmt) printf '发给 %s（在 %s）' "${1:-}" "${2:-}" ;;
    en:remote_label_message_fmt) printf 'message %s (on %s)' "${1:-}" "${2:-}" ;;
    zh:remote_label_answer_fmt)  printf '答 %s（在 %s）' "${1:-}" "${2:-}" ;;
    en:remote_label_answer_fmt)  printf 'answer %s (on %s)' "${1:-}" "${2:-}" ;;
    # --- the task sidebar's own strings (fleet_view.py reads `dump sidebar_`)
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
    # what a needs row asks (issue #2538): its kind's word, and the bar's line
    zh:sidebar_ask_permission)  printf '权限' ;;
    en:sidebar_ask_permission)  printf 'permission' ;;
    zh:sidebar_ask_question)    printf '问题' ;;
    en:sidebar_ask_question)    printf 'question' ;;
    zh:sidebar_ask_auth)        printf '登录' ;;
    en:sidebar_ask_auth)        printf 'login' ;;
    zh:sidebar_ask_fmt)         printf '在问你（%s）：%s' "${1:-}" "${2:-}" ;;
    en:sidebar_ask_fmt)         printf 'asking (%s): %s' "${1:-}" "${2:-}" ;;
    zh:sidebar_backfill_failed) printf '单子没建上' ;;
    en:sidebar_backfill_failed) printf 'issue not filed' ;;
    zh:sidebar_solo_fmt)        printf '单独的活 · %s' "${1:-}" ;;
    en:sidebar_solo_fmt)        printf 'on their own · %s' "${1:-}" ;;
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
    zh:sidebar_orphan_rep)      printf '结果给你' ;;
    en:sidebar_orphan_rep)      printf 'yours now' ;;
    zh:sidebar_ask_orphan_fmt)  printf '%s 的结果 — 派它的会话已不在' "${1:-}" ;;
    en:sidebar_ask_orphan_fmt)  printf 'the result of %s — its spawner is gone' "${1:-}" ;;
    zh:sidebar_orphan_read)     printf '知道了，不再显示' ;;
    en:sidebar_orphan_read)     printf 'Got it, hide it' ;;
    zh:sidebar_orphan_keys)     printf '↵ 已读 · esc 留着' ;;
    en:sidebar_orphan_keys)     printf '↵ read · esc keep' ;;
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
    zh:home_resumed_fmt)        printf '回到你上一次的会话（%s）' "${1:-}" ;;
    en:home_resumed_fmt)        printf 'back to your last session (%s)' "${1:-}" ;;
    zh:home_also_open_fmt)      printf '另一台也开着：%s' "${1:-}" ;;
    en:home_also_open_fmt)      printf 'also open on: %s' "${1:-}" ;;
    zh:home_failed_fmt)         printf '开不了会话：%s' "${1:-}" ;;
    en:home_failed_fmt)         printf 'could not open a session: %s' "${1:-}" ;;
    zh:home_first_failed)       printf '你的第一个会话没开出来' ;;
    en:home_first_failed)       printf 'your first session did not open' ;;
    zh:home_first_why_fmt)      printf '原因：%s' "${1:-}" ;;
    en:home_first_why_fmt)      printf 'why: %s' "${1:-}" ;;
    zh:home_first_next_fmt)     printf '下一步：%s' "${1:-}" ;;
    en:home_first_next_fmt)     printf 'next: %s' "${1:-}" ;;
    zh:home_first_retry_fmt)    printf '%s 秒后自动再试一次，也可以现在敲 fleet claude' "${1:-60}" ;;
    en:home_first_retry_fmt)    printf 'trying again in %s s — or type fleet claude now' "${1:-60}" ;;
    zh:home_first_next)         printf '敲 fleet claude 再开一次；还不行就 fleet doctor 看哪里断了' ;;
    en:home_first_next)         printf 'type fleet claude to try again; if it still fails, fleet doctor says what is down' ;;
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
    # `fleet claude` / `fleet codex`'s own one-session view (issue #2349): its bar and its last words
    zh:solo_view_bar)           printf '⌃\\ 会话 shell · ⌃D 放到后台 · /exit 结束会话' ;;
    en:solo_view_bar)           printf '⌃\\ session shell · ⌃D to the background · /exit ends the session' ;;
    zh:solo_view_bar_shell)     printf '⌃\\ 回到会话 · ⌃D 放到后台' ;;
    en:solo_view_bar_shell)     printf '⌃\\ back to the session · ⌃D to the background' ;;
    zh:solo_view_left_fmt)      printf '会话在后台继续（%s）。`fleet` 可以找回。' "${1:-}" ;;
    en:solo_view_left_fmt)      printf 'The session keeps running in the background (%s). `fleet` finds it again.' "${1:-}" ;;
    zh:solo_view_ended_fmt)     printf '会话已结束（%s）。' "${1:-}" ;;
    en:solo_view_ended_fmt)     printf 'The session has ended (%s).' "${1:-}" ;;
    # 退出 fleet (issue #2349): `fleet quit`, ⌘Q, ⌘K's / the menu's last line — the
    # client's processes here go, the sessions on the machines do not
    zh:retire_done)             printf '旧客户端（#3008 已删除）在这台电脑上留下的进程已停下；`fleet` 打开客户端。' ;;
    en:retire_done)             printf 'What the old client (deleted in #3008) left running on this computer has stopped; `fleet` opens the client.' ;;
    zh:retire_none)             printf 'fleet 没有在后台运行：客户端只在打开它的终端里，⌘Q 或关掉终端就退出。' ;;
    en:retire_none)             printf 'Nothing of fleet runs in the background: the client lives in the terminal that opened it — ⌘Q or close that terminal.' ;;
    zh:retire_left)             printf '旧客户端（#3008 已删除）还在这台电脑后台运行：`fleet quit` 停掉它。' ;;
    en:retire_left)             printf 'The old client (deleted in #3008) still runs in the background here: `fleet quit` stops it.' ;;
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
    zh:compose_attach_big)      printf '（超过 10 MB，带不过去）' ;;
    en:compose_attach_big)      printf ' (over 10 MB, will not go)' ;;
    # ⌃V a picture / a dropped file into a session on another machine (issue #2757,
    # fleet-client-upload.py)
    zh:paste_too_big)           printf '没传：%s 超过 %s MB' "${1:-}" "${2:-}" ;;
    en:paste_too_big)           printf 'not sent: %s is over %s MB' "${1:-}" "${2:-}" ;;
    zh:paste_failed)            printf '没传：%s' "${1:-}" ;;
    en:paste_failed)            printf 'not sent: %s' "${1:-}" ;;
    zh:paste_no_line)           printf '连不上 %s' "${1:-}" ;;
    en:paste_no_line)           printf 'no connection to %s' "${1:-}" ;;
    zh:paste_sending)           printf '正在传 %s …' "${1:-}" ;;
    en:paste_sending)           printf 'sending %s …' "${1:-}" ;;
    zh:thin_reconnect)          printf '和 %s 的连接断了，%s 秒后重连（第 %s 次）' "${1:-}" "${2:-}" "${3:-}" ;;
    en:thin_reconnect)          printf 'lost the connection to %s, reconnecting in %ss (attempt %s)' "${1:-}" "${2:-}" "${3:-}" ;;
    zh:thin_update_switch)      printf '客户端有新版（stable 挪了），换到新版后回到这个会话…' ;;
    en:thin_update_switch)      printf 'a new client is out (stable moved): switching to it, then back to this session…' ;;
    zh:thin_debug_hint)         printf '一直连不上？跑 fleet debug report，把这台电脑的情况交给入口看' ;;
    en:thin_debug_hint)         printf 'still failing? run fleet debug report to hand this computer'"'"'s state to the hub' ;;
    zh:thin_no_tty)             printf 'fleet --thin 要在终端里运行（这里是管道或脚本）' ;;
    en:thin_no_tty)             printf 'fleet --thin needs a terminal (this is a pipe or a script)' ;;
    zh:thin_no_home_fmt)        printf '连不上家机器：%s' "${1:-}" ;;
    en:thin_no_home_fmt)        printf 'cannot reach the home machine: %s' "${1:-}" ;;
    zh:thin_no_fleet_fmt)       printf '%s 这台机器的登录 %s 下没有 fleet' "${1:-}" "${2:-}" ;;
    en:thin_no_fleet_fmt)       printf 'no fleet on %s under login %s' "${1:-}" "${2:-}" ;;
    zh:thin_home_restart_fmt)   printf '家机器 %s 在重启，稍等 — 回来就接回刚才的会话（最多再等 %s 秒）' "${1:-}" "${2:-}" ;;
    en:thin_home_restart_fmt)   printf 'home %s is restarting — waiting to reconnect to the same session (up to %ss more)' "${1:-}" "${2:-}" ;;
    zh:thin_first_start)        printf '你还没有 fleet 会话：正在为你开第一个…' ;;
    en:thin_first_start)        printf 'no fleet session of yours yet: opening your first one…' ;;
    zh:thin_first_opening_fmt)  printf '正在为你开机器（%s），约 %s 秒 — 开好后自动接着开你的第一个会话' "${1:-}" "${2:-}" ;;
    en:thin_first_opening_fmt)  printf 'opening a machine for you (%s), about %ss — your first session opens once it is ready' "${1:-}" "${2:-}" ;;
    zh:thin_first_retry_fmt)    printf '第一个会话没开出来，%s 秒后再试一次' "${1:-}" ;;
    en:thin_first_retry_fmt)    printf 'your first session did not open, trying again in %ss' "${1:-}" ;;
    zh:thin_first_placed_fmt)   printf '第一个会话开在 %s，连过去' "${1:-}" ;;
    en:thin_first_placed_fmt)   printf 'your first session opened on %s, connecting' "${1:-}" ;;
    zh:thin_first_failed)       printf '你的第一个会话没开出来' ;;
    en:thin_first_failed)       printf 'your first session did not open' ;;
    zh:thin_first_why_fmt)      printf '原因：%s' "${1:-}" ;;
    en:thin_first_why_fmt)      printf 'why: %s' "${1:-}" ;;
    zh:thin_first_next_fmt)     printf '下一步：%s' "${1:-}" ;;
    en:thin_first_next_fmt)     printf 'next: %s' "${1:-}" ;;
    zh:thin_first_ask_fmt)      printf '找入口管理员 %s' "${1:-}" ;;
    en:thin_first_ask_fmt)      printf 'ask the hub admin (%s)' "${1:-}" ;;
    zh:thin_first_next)         printf '稍后再敲 %s；还不行就 %s debug report，把这台电脑的情况交给入口看' "${1:-fleet}" "${1:-fleet}" ;;
    en:thin_first_next)         printf 'type %s again later; if it still fails, run %s debug report to hand this computer'"'"'s state to the hub' "${1:-fleet}" "${1:-fleet}" ;;
    zh:thin_first_settle_fmt)   printf '机器 %s 上的登录开好了，等它的 fleet 报上来（最多再等 %s 秒）' "${1:-}" "${2:-}" ;;
    en:thin_first_settle_fmt)   printf 'your login on %s is ready, waiting for its fleet to report (up to %ss more)' "${1:-}" "${2:-}" ;;
    zh:thin_first_settle_timeout_fmt) printf '%s 上的登录开好后等了 %s 分钟，它的 fleet 还没报上来（%s）' "${1:-}" "${2:-}" "${3:-}" ;;
    en:thin_first_settle_timeout_fmt) printf 'the login on %s was opened, but its fleet did not report within %s minutes (%s)' "${1:-}" "${2:-}" "${3:-}" ;;
    zh:thin_path_hint_fmt)      printf '这个终端还找不到 fleet 命令：先敲 exec %s（或开一个新终端），或直接敲 %s' "${1:-zsh}" "${2:-fleet}" ;;
    en:thin_path_hint_fmt)      printf 'this terminal cannot find fleet yet: type exec %s (or open a new terminal), or type %s' "${1:-zsh}" "${2:-fleet}" ;;
    zh:thin_first_wait_fmt)     printf '第一个会话还开不了（%s）——这会自己好，接着等（最多再等 %s 秒）' "${1:-}" "${2:-}" ;;
    en:thin_first_wait_fmt)     printf 'your first session cannot open yet (%s) — this heals by itself, waiting (up to %ss more)' "${1:-}" "${2:-}" ;;
    zh:thin_rehome_back_fmt)    printf '除了 %s 没有别的在线机器，回到它接着重连' "${1:-}" ;;
    en:thin_rehome_back_fmt)    printf 'no other machine is online: back to %s, reconnecting' "${1:-}" ;;
    # the 看台 keeps breaking: the home's command line instead (EPIC T651 C4)
    zh:thin_view_never_fmt)     printf '看台连续 %s 次没起来' "${1:-}" ;;
    en:thin_view_never_fmt)     printf 'the 看台 did not come up %s times in a row' "${1:-}" ;;
    zh:thin_view_crash_fmt)     printf '看台连续 %s 次起来就退出（代码 %s）' "${1:-}" "${2:-}" ;;
    en:thin_view_crash_fmt)     printf 'the 看台 quit right after it came up %s times in a row (code %s)' "${1:-}" "${2:-}" ;;
    zh:thin_shell_fmt)          printf '%s — 已把你放在 %s 的命令行' "${1:-}" "${2:-}" ;;
    en:thin_shell_fmt)          printf '%s — you are at the command line on %s' "${1:-}" "${2:-}" ;;
    zh:thin_shell_back)         printf '输入 exit 回看台（在这台机器上输入 fleet 也行）；排查看 ~/.config/claude-fleet/logs/' ;;
    en:thin_shell_back)         printf 'type exit to go back to the 看台 (or fleet on that machine); logs in ~/.config/claude-fleet/logs/' ;;
    zh:thin_shell_done_fmt)     printf '离开了 %s 的命令行，再试看台…' "${1:-}" ;;
    en:thin_shell_done_fmt)     printf 'left the command line on %s: trying the 看台 again…' "${1:-}" ;;
    zh:entry_view_none_fmt)     printf '看台没起来（%s）— 已把你放在 %s 的命令行。输入 fleet 回看台' "${1:-}" "${2:-}" ;;
    en:entry_view_none_fmt)     printf 'the 看台 did not come up (%s): you are at the command line on %s. Type fleet to go back' "${1:-}" "${2:-}" ;;
    zh:entry_view_crash_fmt)    printf '看台意外退出（代码 %s）— 已把你放在 %s 的命令行。输入 fleet 回看台' "${1:-}" "${2:-}" ;;
    en:entry_view_crash_fmt)    printf 'the 看台 quit unexpectedly (code %s): you are at the command line on %s. Type fleet to go back' "${1:-}" "${2:-}" ;;
    zh:thin_first_no_lease_fmt) printf '入口没给这台电脑客户端租约（%s）' "${1:-}" ;;
    en:thin_first_no_lease_fmt) printf 'the hub gave this computer no client lease (%s)' "${1:-}" ;;
    zh:thin_first_timeout_fmt)  printf '等了 %s 分钟，机器还没开好' "${1:-}" ;;
    en:thin_first_timeout_fmt)  printf 'waited %s minutes and the machine is still not ready' "${1:-}" ;;
    zh:thin_first_rounds_fmt)   printf '开好的会话所在的机器 %s 仍然没有 fleet 会话（已经开过 %s 次）' "${1:-}" "${2:-}" ;;
    en:thin_first_rounds_fmt)   printf 'the machine the session opened on (%s) still has no fleet session (opened %s times)' "${1:-}" "${2:-}" ;;
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
    # the desk ticket of a no-code session (issue #2676, dash-raw-session.sh)
    zh:compose_sent_fmt)        printf '已发出：%s · 开工中…' "${1:-}" ;;
    en:compose_sent_fmt)        printf 'sent: %s · starting…' "${1:-}" ;;
    zh:compose_empty)           printf '先写一行再 ↵' ;;
    en:compose_empty)           printf 'write a line first' ;;
    zh:compose_failed_fmt)      printf '✗ 没发出去：%s · 字还在，改好再 ↵' "${1:-}" ;;
    en:compose_failed_fmt)      printf '✗ not sent: %s · your text is kept — fix it and ↵ again' "${1:-}" ;;
    zh:compose_failed_unknown)  printf '原因没说出来，看 fleet doctor' ;;
    en:compose_failed_unknown)  printf 'no reason given — see fleet doctor' ;;
    zh:compose_failed_silent)   printf '等了 4 分钟没有回音，看侧栏有没有开出来' ;;
    en:compose_failed_silent)   printf 'no answer after 4 minutes — check the list for the session' ;;
    zh:compose_nolist)          printf '没找到任务列表：直接发给入口' ;;
    en:compose_nolist)          printf 'no task list found: sending straight to the hub' ;;
    zh:compose_result_fmt)      printf '入口回话：%s' "${1:-}" ;;
    en:compose_result_fmt)      printf 'the hub says: %s' "${1:-}" ;;
    # ⌘T 派一件事 (issue #2753, bin/fleet-quick-dispatch.py)
    zh:dispatch_field_title)    printf '派一件事' ;;
    en:dispatch_field_title)    printf 'Dispatch' ;;
    zh:dispatch_field_repo)     printf '仓库' ;;
    en:dispatch_field_repo)     printf 'repo' ;;
    zh:dispatch_field_agent)    printf '用哪个 Coding Agent' ;;
    en:dispatch_field_agent)    printf 'Coding Agent' ;;
    zh:dispatch_agent_default)  printf '（默认）' ;;
    en:dispatch_agent_default)  printf '(default)' ;;
    zh:dispatch_agent_missing_fmt) printf '%s 这台没装 %s' "${1:-}" "${2:-}" ;;
    en:dispatch_agent_missing_fmt) printf '%s has no %s installed' "${1:-}" "${2:-}" ;;
    zh:dispatch_agent_blocked_fmt) printf '%s：管理员暂未开放' "${1:-}" ;;
    en:dispatch_agent_blocked_fmt) printf '%s: not opened to you by the admin yet' "${1:-}" ;;
    zh:dispatch_keys)           printf '↵ 建单并开工 · Tab 下一项 · ←→ 换仓库 / Agent · esc 关' ;;
    en:dispatch_keys)           printf '↵ file + start · Tab next · ←→ repo / agent · esc close' ;;
    zh:dispatch_norepo)         printf '还没有可派的仓库（入口还没说这台电脑的机器托管哪些仓库）' ;;
    en:dispatch_norepo)         printf 'no repo to dispatch to yet (the hub has not said which repos your machines host)' ;;
    # hub authority: a repo's start is a hub task first (issue #4965)
    zh:dispatch_new_title)      printf '新会话' ;;
    en:dispatch_new_title)      printf 'New session' ;;
    zh:dispatch_task_done_fmt)  printf '已建 %s 并开工：%s' "${1:-}" "${2:-}" ;;
    en:dispatch_task_done_fmt)  printf 'recorded %s and started it: %s' "${1:-}" "${2:-}" ;;
    zh:dispatch_task_made_fmt)  printf '已建 %s' "${1:-}" ;;
    en:dispatch_task_made_fmt)  printf 'recorded %s' "${1:-}" ;;
    zh:dispatch_hub_elsewhere_fmt) printf '%s 不在 %s 这台上：任务由入口管时，⌘P 只在本机开带仓库的任务——到托管它的那台开，或让编排会话派' "${1:-}" "${2:-}" ;;
    en:dispatch_hub_elsewhere_fmt) printf '%s is not on %s: with the hub owning tasks, ⌘P opens a repo task on this machine only — open it on the machine that hosts it, or have an orchestrator dispatch it' "${1:-}" "${2:-}" ;;
    zh:dispatch_sending)        printf '发出中…' ;;
    en:dispatch_sending)        printf 'sending…' ;;
    zh:popup_dispatch)          printf '派一件事' ;;
    en:popup_dispatch)          printf 'Dispatch' ;;
    zh:sidebar_dispatch_done_fmt) printf '已建 #%s 并开工' "${1:-}" ;;
    en:sidebar_dispatch_done_fmt) printf 'filed #%s and started its worker' "${1:-}" ;;
    zh:sidebar_dispatch_started_fmt) printf '已开工：%s' "${1:-}" ;;
    en:sidebar_dispatch_started_fmt) printf 'started: %s' "${1:-}" ;;
    zh:keys_switch_dispatch)    printf %s '派一件事：一行标题 + 仓库（默认上次用的）+ 可选交给 Codex，↵ 建单并开工；任何窗口都能按，不经过模型' ;;
    en:keys_switch_dispatch)    printf %s 'dispatch: a title + a repo (the last one used) + optionally Codex, ↵ files it and starts its worker; from any window, no model on the way' ;;
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
    zh:sidebar_ask_restore)     printf 'y 先 reopen · r 直接恢复› ' ;;
    en:sidebar_ask_restore)     printf 'y reopen first · r restore› ' ;;
    zh:sidebar_ask_keys)        printf '↵ 确定 · esc 取消' ;;
    en:sidebar_ask_keys)        printf '↵ ok · esc cancel' ;;
    # --- the row menu (fleet_view.py ACTIONS). menu_keys is THE letter table:
    # `action<TAB>letter<TAB>what`, read by the menu (mk) and the ? sheet (--keys).
    zh:menu_keys)               printf '%s' 'rename	r	改名 — 在输入行编辑（↵ 应用，esc / 空名称取消）
pin	t	置顶 / 取消置顶
pr	p	打开 PR（没有时置灰）
answer	a	回答提问 — 跳到那个会话，在它自己的提问里答（红色 ? 行；否则置灰）
reappol	l	改回收方式 — 合并后 / 做完就收 / 循环停了 / 到点 / 常驻
agent	v	新会话 claude ⇄ codex
reap	x	回收 — 先确认 y/n（别机行：经入口让那台机器回收）
new	n	新任务 — 在输入行写标题（多仓库 Tab 换仓库），↵ 建 issue 并启动 worker
newto	1-9	新建到 <机器>… — 入口在线的别的机器各一项：建 issue，worker 开在那台机器上
restore	o	已落地 — 任务栏就地换成已落地列表，点一行恢复（再选一次回到运行中）
repo	g	添加仓库到这个 fleet — 在输入行写 owner/name；~/projects/<name>，缺失时 clone（hub ⌃z）
open	e	进入 — 打开代理窗口（只有另一台机器上的行有；菜单标题写着「· mac-a」）
message	m	发消息… — 只有别机行有：在输入行写，经入口送到那台机器的 issue 桥，作为它的下一轮
stop	q	停 — 只有别机行有：经入口让那台机器上的会话 /exit（可恢复）
resume	c	继续 — 只有别机行有：经入口恢复刚停掉的会话（活着的会被拒绝并告诉你）
clients	d	我的客户端 — 只在客户端：同时开着的每台设备、终端、最后使用时间，可断开某一台
quit	z	退出 fleet — 只在客户端：关掉这台电脑上客户端的全部进程，远端会话照常在机器上跑（⌘Q · fleet quit）' ;;
    en:menu_keys)               printf '%s' 'rename	r	rename — edits on the input line (↵ applies, esc / an empty name cancels)
pin	t	pin / unpin the row to the top
pr	p	open its PR (greyed when it has none)
answer	a	answer its question — jumps to that session, to answer in its own picker (a red ? row; greyed otherwise)
reappol	l	reap policy — after merge / when done / after the loop / at a time / keep
agent	v	flip new sessions claude ⇄ codex
reap	x	reap it — asks y/n first (a row on another machine: through the hub, there)
new	n	new task — its title on the input line (Tab picks the repo in a 2+ repo fleet), ↵ files the issue AND spawns its worker
newto	1-9	new task on <machine>… — one per other machine the hub says is online: file the issue, open the worker there
restore	o	landed — the sidebar shows the landed list in place; tap a row to restore it (again: back to the running list)
repo	g	add a repo to this fleet — owner/name on the input line; ~/projects/<name>, cloned if missing (the hub ⌃z)
open	e	enter — open the proxy window (a row on another machine only; the menu title says · mac-a)
message	m	message… — a row on another machine only: typed on the input line, through the hub to the issue bridge on that machine, as its next turn
stop	q	stop — a row on another machine only: /exit there through the hub (resumable)
resume	c	resume — a row on another machine only: reopen a just-stopped one through the hub (a live one is refused, and says so)
clients	d	my clients — in the client only: every device you have open, its terminal and when last used; disconnect one
quit	z	quit fleet — in the client only: every process of the client on this computer goes, the sessions keep running on their machines (⌘Q · fleet quit)' ;;
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
    # --- the reap policy (issue #1902): the row menu's submenu and the shell's
    # new-session question 「什么时候回收？」 — the prototype's words.
    # --- 我的客户端 (issue #1932): the clients open at once, fleet-client-menu.sh
    zh:menu_clients)            printf '我的客户端…' ;;
    en:menu_clients)            printf 'My clients…' ;;
    zh:menu_quit)               printf '退出 fleet' ;;
    en:menu_quit)               printf 'Quit fleet' ;;
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
    zh:topbar_no_record)        printf '顶行无记录' ;;
    en:topbar_no_record)        printf 'no top-line record' ;;
    # the top line's own words (fleet-topbar.py reads `dump topbar_`, issue #3324)
    zh:topbar_left_fmt)         printf '剩余 %s' "${1:-}" ;;
    en:topbar_left_fmt)         printf '%s left' "${1:-}" ;;
    zh:topbar_ago_fmt)          printf '%s 分钟前' "${1:-}" ;;
    en:topbar_ago_fmt)          printf '%s min ago' "${1:-}" ;;
    zh:topbar_today_fmt)        printf '今天 %s' "${1:-}" ;;
    en:topbar_today_fmt)        printf '%s today' "${1:-}" ;;
    zh:topbar_pr_merged)        printf 'PR 已合并' ;;
    en:topbar_pr_merged)        printf 'PR merged' ;;
    zh:topbar_pr_closed)        printf 'PR 已关闭' ;;
    en:topbar_pr_closed)        printf 'PR closed' ;;
    zh:topbar_down_fmt)         printf '%s 连不上' "${1:-}" ;;
    en:topbar_down_fmt)         printf '%s unreachable' "${1:-}" ;;
    zh:topbar_retry_fmt)        printf '第 %s 次重连' "${1:-}" ;;
    en:topbar_retry_fmt)        printf 'retry %s' "${1:-}" ;;
    zh:topbar_relay_fmt)        printf '%s 经中转' "${1:-}" ;;
    en:topbar_relay_fmt)        printf '%s via relay' "${1:-}" ;;
    zh:topbar_direct_quiet)     printf '直连（入口没声音）' ;;
    en:topbar_direct_quiet)     printf 'direct (the entry is silent)' ;;
    # the machine's credential proxy failing upstream (T657, fleet_upstream_stats.py banner)
    zh:topbar_upstream_fmt)     printf '上游连不上：%s（%s 次）' "${1:-}" "${2:-}" ;;
    en:topbar_upstream_fmt)     printf 'upstream unreachable: %s (%s)' "${1:-}" "${2:-}" ;;
    zh:topbar_up_refused)       printf '连接被拒' ;;
    en:topbar_up_refused)       printf 'connection refused' ;;
    zh:topbar_up_reset)         printf '连接被重置' ;;
    en:topbar_up_reset)         printf 'connection reset' ;;
    zh:topbar_up_timeout)       printf '连接超时' ;;
    en:topbar_up_timeout)       printf 'timed out' ;;
    zh:topbar_up_tls)           printf 'TLS 失败' ;;
    en:topbar_up_tls)           printf 'TLS failed' ;;
    zh:topbar_up_dns)           printf 'DNS 失败' ;;
    en:topbar_up_dns)           printf 'DNS failed' ;;
    zh:topbar_up_neterr)        printf '网络错误' ;;
    en:topbar_up_neterr)        printf 'network error' ;;
    zh:topbar_up_429)           printf '429 限流' ;;
    en:topbar_up_429)           printf '429 rate limited' ;;
    zh:topbar_up_5xx)           printf '5xx 出错' ;;
    en:topbar_up_5xx)           printf '5xx error' ;;
    zh:topbar_up_529)           printf '529 过载' ;;
    en:topbar_up_529)           printf '529 overloaded' ;;
    zh:notify_ask)              printf '%s 在问你' "${1:-}" ;;
    en:notify_ask)              printf '%s is asking you' "${1:-}" ;;
    zh:notify_perm)             printf '%s 要你批准' "${1:-}" ;;
    en:notify_perm)             printf '%s needs your approval' "${1:-}" ;;
    zh:notify_auth)             printf '%s 要你登录' "${1:-}" ;;
    en:notify_auth)             printf '%s needs you to sign in' "${1:-}" ;;
    zh:notify_stuck)            printf '%s 被卡住了' "${1:-}" ;;
    en:notify_stuck)            printf '%s is stuck' "${1:-}" ;;
    zh:notify_failed)           printf '%s 失败了' "${1:-}" ;;
    en:notify_failed)           printf '%s failed' "${1:-}" ;;
    zh:notify_done)             printf '%s 做完了' "${1:-}" ;;
    en:notify_done)             printf '%s is done' "${1:-}" ;;
    zh:notify_done_batch)       printf '%s 做完了 %s 个' "${1:-}" "${2:-}" ;;
    en:notify_done_batch)       printf '%s: %s done' "${1:-}" "${2:-}" ;;
    zh:notify_done_last)        printf '最新：%s' "${1:-}" ;;
    en:notify_done_last)        printf 'latest: %s' "${1:-}" ;;
    zh:notify_doctor_tn)        printf '通知点一下直接切到会话（terminal-notifier）' ;;
    en:notify_doctor_tn)        printf 'a click on a notification goes to its session (terminal-notifier)' ;;
    zh:notify_doctor_no_tn)     printf '没装 terminal-notifier：通知照弹，点了只把终端叫到前面（brew install terminal-notifier 可直接切到会话）' ;;
    en:notify_doctor_no_tn)     printf 'terminal-notifier is not installed: notifications still come, a click only brings the terminal forward (brew install terminal-notifier to land on the session)' ;;
    zh:notify_doctor_off)       printf '通知已关（FLEET_NOTIFY=0）' ;;
    en:notify_doctor_off)       printf 'notifications off (FLEET_NOTIFY=0)' ;;
    zh:menu_reap_policy)        printf '改回收方式…' ;;
    en:menu_reap_policy)        printf 'Reap policy…' ;;
    zh:reap_menu_title)         printf '什么时候回收' ;;
    en:reap_menu_title)         printf 'When to reap' ;;
    zh:reap_menu_merged)        printf '合并后回收 — PR 合并 10 分钟后' ;;
    en:reap_menu_merged)        printf 'After merge — 10 min after the PR merges' ;;
    zh:reap_menu_done_15m)      printf '做完就回收 — 闲满 15 分钟' ;;
    en:reap_menu_done_15m)      printf 'When done — idle 15 minutes' ;;
    zh:reap_menu_loop_end)      printf '循环停了回收 — /loop 停了以后' ;;
    en:reap_menu_loop_end)      printf 'After the loop — once /loop stops' ;;
    zh:reap_menu_at)            printf '到点回收…' ;;
    en:reap_menu_at)            printf 'At a time…' ;;
    zh:reap_menu_keep)          printf '常驻 — 永不自动回收' ;;
    en:reap_menu_keep)          printf 'Keep — never reaped' ;;
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
    zh:sidebar_place_reap_done) printf '做完就回收\t闲满 15 分钟' ;;
    en:sidebar_place_reap_done) printf 'When done\tidle 15 minutes' ;;
    zh:sidebar_place_reap_loop_end) printf '循环停了回收\t/loop 停了以后' ;;
    en:sidebar_place_reap_loop_end) printf 'After the loop\tonce /loop stops' ;;
    zh:sidebar_place_reap_at)   printf '到点回收\t下一步写时间' ;;
    en:sidebar_place_reap_at)   printf 'At a time\tthe time comes next' ;;
    zh:sidebar_place_reap_keep) printf '常驻\t永不自动回收' ;;
    en:sidebar_place_reap_keep) printf 'Keep\tnever reaped' ;;
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
    # the 看台's switch keys, one per dash-keymap.sh --panel switch row (docs-build.sh's key table)
    zh:keys_switch_next)       printf %s '下一个会话，右侧立刻跟过去' ;;
    en:keys_switch_next)       printf %s 'the next session; the right pane follows at once' ;;
    zh:keys_switch_prev)       printf %s '上一个会话' ;;
    en:keys_switch_prev)       printf %s 'the previous session' ;;
    zh:keys_switch_back)       printf %s '后退：回到刚才看的会话（没有任务列表时：上一台机器）' ;;
    en:keys_switch_back)       printf %s 'back through the sessions you were on (no task list: the machine before)' ;;
    zh:keys_switch_fwd)        printf %s '前进' ;;
    en:keys_switch_fwd)        printf %s 'forward again' ;;
    zh:keys_switch_zoom)       printf %s '放大右侧会话，再按复原' ;;
    en:keys_switch_zoom)       printf %s 'zoom the session on the right; again to restore' ;;
    zh:keys_switch_quickopen)  printf %s '快速跳转：打几个字（名字、机器、状态都算），↵ 切过去；不打字 ↵ = 上一个看的' ;;
    en:keys_switch_quickopen)  printf %s 'quick open: type a few letters (name, machine, state), ↵ switches; ↵ on nothing = the one you saw before' ;;
    zh:keys_switch_new)        printf %s '新会话：在家里的机器开一个不绑仓库的会话，光标就在它的输入框' ;;
    en:keys_switch_new)        printf %s 'new session: a no-repo session on your home machine, the cursor in its input' ;;
    zh:keys_switch_fold)       printf %s '展开/收起当前会话的子任务；在子任务上按：收起它的父任务' ;;
    en:keys_switch_fold)       printf %s 'open / shut the sub-tasks of the session in view; on a sub-task: shut its parent' ;;
    zh:keys_switch_switcher)   printf %s '切换会话：全部会话按最近使用排，可搜索；最下面「+ 新会话」和「打开多会话视图」（多会话视图里是「收起侧栏」）' ;;
    en:keys_switch_switcher)   printf %s 'switch session: every session, most recent first, searchable; at the bottom + New session and Open the multi-session view (Hide the list in it)' ;;
    zh:keys_switch_quit)       printf %s '退出当前客户端连接，会话照常在机器上运行；fleet 重新进入' ;;
    en:keys_switch_quit)       printf %s 'quit this client connection; sessions keep running on their machines; fleet opens it again' ;;
    # an ask's hints under its question (issue #4337, bin/fleet-mcp.py ask): nothing acts on them
    zh:ask_hint_suggest)        printf '建议：%s' "${1:-}" ;;
    en:ask_hint_suggest)        printf 'suggested: %s' "${1:-}" ;;
    zh:ask_hint_default)        printf '没人答时：%s（仅提示，不会自动执行）' "${1:-}" ;;
    en:ask_hint_default)        printf 'if nobody answers: %s (a hint — nothing goes ahead by itself)' "${1:-}" ;;
    zh:ask_hint_due)            printf '希望在此前答复：%s' "${1:-}" ;;
    en:ask_hint_due)            printf 'wanted by: %s' "${1:-}" ;;
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
  _fuh_d="${FLEET_C:-${TMPDIR:-/tmp/claude-fleet-$(id -u)}/.claude-dash}/global"
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
    # first-hint DEVICE — the 看台's one-time language line, or nothing (issue #3329)
    first-hint) fleet_ui_first_hint "${2:-}" ;;
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
              case "$_k" in "$_p"*) printf '%s\0%s\0' "$_k" "$(fleet_ui_t "$_k" "$_s" "$_s" "$_s" "$_s")"; break ;; esac
            done
          done ;;
    *) printf 'usage: fleet-ui-lang.sh [lang|first-hint DEVICE|t KEY|toast CLIENT KEY|hint CLIENT KEY|dump PREFIX…]\n' >&2; exit 2 ;;
  esac ;;
esac
