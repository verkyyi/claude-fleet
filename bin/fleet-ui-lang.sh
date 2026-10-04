#!/bin/sh
# fleet-ui-lang.sh — tiny source-safe translator for tmux-facing UI strings.
#
# FLEET_UI_LANG:
#   auto  follow the login locale (zh* => Chinese, everything else English)
#   en    force English
#   zh    force Chinese

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

fleet_ui_t() {
  _fleet_ui_key=$1
  shift 2>/dev/null || :
  case "$(fleet_ui_lang):$_fleet_ui_key" in
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
    zh:sidebar_on)              printf 'fleet: 任务栏已开启 — worker 空间足够时显示' ;;
    en:sidebar_on)              printf 'fleet: task sidebar on — shown when the worker has room' ;;
    zh:sidebar_hidden)          printf 'fleet: 任务栏已隐藏' ;;
    en:sidebar_hidden)          printf 'fleet: task sidebar hidden' ;;
    zh:sidebar_save_failed)     printf 'fleet: 无法保存任务栏偏好' ;;
    en:sidebar_save_failed)     printf 'fleet: could not save sidebar preference' ;;
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
    zh:pin_heading_fmt)         printf '置顶 (%s)' "${1:-}" ;;
    en:pin_heading_fmt)         printf 'Pinned (%s)' "${1:-}" ;;
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
    *)                          printf '%s' "$_fleet_ui_key" ;;
  esac
}

case "$0" in */fleet-ui-lang.sh|fleet-ui-lang.sh)
  case "${1:-lang}" in
    lang) fleet_ui_lang ;;
    t) shift; fleet_ui_t "$@" ;;
    *) printf 'usage: fleet-ui-lang.sh [lang|t KEY]\n' >&2; exit 2 ;;
  esac ;;
esac
