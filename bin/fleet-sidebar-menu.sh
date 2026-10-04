# shellcheck shell=bash
# shellcheck disable=SC2154  # $sess $verb come from fleet-sidebar.sh, which sources this
# fleet-sidebar-menu.sh — sourced by fleet-sidebar.sh for `menu` / `reap`
# (issue #898). The task sidebar's per-row action menu: rename, pin, open PR,
# answer, switch subscription, flip agent, and reap, plus a sleeping row's Wake
# and the Keep awake / Allow sleep toggle
# (issue #1051), plus the row-less "new task (file an issue)", "restore a finished
# task" (#901) and "add a repo" (#1103). Every item calls the SAME
# script the hub binds (EPIC #894 convention 1) with the window's stable `@id`,
# never an index or a name. The view (fleet-sidebar.py) opens it on `.` (empty
# input line) or a second tap on the highlighted row; this file owns the tmux
# syntax so the Python never spells a tmux command string.
#
# A row on ANOTHER machine (`wid:<worker_id>`, issue #1487 / EPIC #1479 C8) gets
# the actions too — message, answer, stop, resume, reap — each a hub WRITE through
# bin/fleet-sidebar-remote.sh → bin/fleet-hub-write.sh (the one write client),
# never a script of this machine aimed at a window it does not have; a local row's
# items are untouched. And with the hub on, both menus list «new task on <m>…» for
# every machine the sidebar's cache says is online (dash-issue-new.sh --node=<m>);
# with the hub off that cache does not exist, so nothing is added.
#
#   menu <session> <@id>          draw it on the session's most-recently-active
#                                 client, anchored on the sidebar pane. tmux
#                                 holds this call until the menu closes, so a
#                                 caller that keeps working must not wait on it
#   menu <session> <@id> --print  print the items (`key<TAB>name<TAB>command`,
#                                 a disabled item's name starts with `-`) — tests
#   reap <session> <@id>          what the menu's reap runs AFTER confirm-before:
#                                 `dash-reap.sh <@id> --yes`, its result token
#                                 read off stdout (never the exit code, #869) and
#                                 toasted — a refusal is never silent
#
#   bash fleet-sidebar-menu.sh --keys
#                                 run directly (not sourced): one `key<TAB>what`
#                                 line per item — the `?` sheet's menu rows
#                                 (fleet-keys.sh --context sidebar, issue #948)
#
# Expects fleet-sidebar.sh's context: $BIN, $sess, $verb, $@, the conf loaded.

[ -n "${BIN:-}" ] || BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-ui-lang.sh"

# The menu's letters: ONE table, read by the menu below (`mk <action>`) and by
# the `?` sheet (--keys), so the sheet can never name a letter the menu lacks.
case "$(fleet_ui_lang)" in
  zh)
MENU_KEYS='rename	r	改名 — 在输入行编辑（↵ 应用，esc / 空名称取消）
pin	t	置顶 / 取消置顶
pr	p	打开 PR（没有时置灰）
answer	a	回答提问（红色 ? 行；否则置灰）
sub	s	切换 sub — 选中运行中的 Claude worker，按 . 后按 s；显示额度并确认
wake	w	唤醒睡眠中的 z 行（仅睡眠时显示）
awake	k	保持唤醒 ⇄ 允许再次休眠
agent	v	新会话 claude ⇄ codex
reap	x	回收 — 先确认 y/n（别机行：经入口让那台机器回收）
new	n	新任务 — 建 issue 并启动 worker
newto	1-9	新建到 <机器>… — 入口在线的别的机器各一项：建 issue，worker 开在那台机器上
restore	o	恢复已收工任务（hub landed 列表，弹窗）
repo	g	添加仓库到这个 fleet — 询问 owner/name；~/projects/<name>，缺失时 clone（hub ⌃z）
open	e	进入 — 打开 ⇄ 代理窗口（只有另一台机器上的行有；菜单标题写着「· 在 m4」）
message	m	发消息… — 只有别机行有：经入口送到那台机器的 issue 桥，作为它的下一轮
stop	q	停 — 只有别机行有：经入口让那台机器上的会话 /exit（可恢复）
resume	c	继续 — 只有别机行有：经入口恢复刚停掉的会话（活着的会被拒绝并告诉你）'
    m_open_remote='进入（⇄ 代理窗口）…'
    m_r_message='发消息…'; m_r_stop='停（/exit）'; m_r_resume='继续（恢复）'
    m_r_answer='答授权 / 回答…'; m_r_answer_none='答授权 / 回答（没有在等）'
    m_r_reap_confirm_fmt='回收「%s」（在 %s）？(y/n)'; m_newto_fmt='新建到 %s…'
    m_rename='改名…'; m_unpin='取消置顶'; m_pin='置顶'
    m_open_pr='打开 PR'; m_open_pr_none='打开 PR（没有）'
    m_answer='回答它的提问…'; m_answer_none='回答它的提问（没有）'
    m_sub='切换 sub（选账号）…'; m_sub_none='切换 sub（先选运行中的 Claude worker）'
    m_wake='唤醒'; m_allow_sleep='允许休眠'; m_keep_awake='保持唤醒'
    m_agent_fmt='新会话改用 %s'; m_reap='回收…'; m_reap_confirm_fmt='回收「%s」？(y/n)'
    m_new='新建任务（建 issue）…'; m_restore='恢复已收工…'; m_repo='＋ 仓库…'
    ;;
  *)
MENU_KEYS='rename	r	rename — edits on the input line (↵ applies, esc / an empty name cancels)
pin	t	pin / unpin the row to the top
pr	p	open its PR (greyed when it has none)
answer	a	answer its question (a red ? row; greyed otherwise)
sub	s	switch subscription — select a running Claude worker, press . then s; review quota and confirm
wake	w	wake a sleeping (z) row now — only listed on one
awake	k	keep it awake ⇄ allow it to sleep again
agent	v	flip new sessions claude ⇄ codex
reap	x	reap it — asks y/n first (a row on another machine: through the hub, there)
new	n	new task — file an issue AND spawn its worker
newto	1-9	new task on <machine>… — one per other machine the hub says is online: file the issue, open the worker there
restore	o	restore a finished task (the hub landed list, in a popup)
repo	g	add a repo to this fleet — asks owner/name; ~/projects/<name>, cloned if missing (the hub ⌃z)
open	e	enter — open the ⇄ proxy window (a row on another machine only; the menu title says · on m4)
message	m	message… — a row on another machine only: through the hub to the issue bridge on that machine, as its next turn
stop	q	stop — a row on another machine only: /exit there through the hub (resumable)
resume	c	resume — a row on another machine only: reopen a just-stopped one through the hub (a live one is refused, and says so)'
    m_open_remote='Enter (⇄ proxy window)…'
    m_r_message='Message…'; m_r_stop='Stop (/exit)'; m_r_resume='Resume'
    m_r_answer='Answer prompt…'; m_r_answer_none='Answer prompt (nothing waiting)'
    m_r_reap_confirm_fmt='Reap "%s" (on %s)? (y/n)'; m_newto_fmt='New task on %s…'
    m_rename='Rename…'; m_unpin='Unpin'; m_pin='Pin'
    m_open_pr='Open PR'; m_open_pr_none='Open PR (none)'
    m_answer='Answer question…'; m_answer_none='Answer question (none)'
    m_sub='Switch subscription (choose account)…'; m_sub_none='Switch subscription (select a running Claude worker)'
    m_wake='Wake'; m_allow_sleep='Allow sleep'; m_keep_awake='Keep awake'
    m_agent_fmt='New sessions use %s'; m_reap='Reap…'; m_reap_confirm_fmt='Reap "%s"? (y/n)'
    m_new='New task (file issue)…'; m_restore='Restore finished task…'; m_repo='Add repo…'
    ;;
esac
mk() { printf '%s\n' "$MENU_KEYS" | awk -F '\t' -v a="$1" '$1 == a { print $2; exit }'; }
if [ "${1:-}" = --keys ]; then
  printf '%s\n' "$MENU_KEYS" | awk -F '\t' '{ print $2 "\t" $3 }'
  exit 0
fi

wid="${3:-}"
# A row on another machine (`wid:<fleet>/<name>`, #1423) gets a menu too (issue
# #1475): titled `<name> · 在 m4` — the ONE place the list names the machine, now
# that the rows look alike — with `enter` (the ⇄ proxy window) and the row-less
# items. Everything a local row's menu does needs a window here; it has none.
remote=''
case "$wid" in @[0-9]*) ;; wid:*/*) remote=1 ;; *) exit 0 ;; esac
# Never act on another fleet's window, or a stale id tmux recycled elsewhere.
[ -n "$remote" ] || [ "$(tmux display-message -p -t "$wid" '#{session_name}' 2>/dev/null)" = "$sess" ] || exit 0

# sq <text> → one word for BOTH /bin/sh and tmux's command parser: single quotes
# (no $ ~ expansion in either), an embedded quote closed, escaped and reopened.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# dq <text> → one double-quoted tmux command string; used when the nested command
# already contains shell single quotes and confirm-before should receive it whole.
dq() { printf '"%s"' "$(printf '%s' "$1" | sed 's/["\\]/\\&/g')"; }
# fe <text> → literal inside a tmux FORMAT (menu names/title, -I input): ## = #.
fe() { printf '%s' "$1" | sed 's/#/##/g'; }

toast() { tmux display-message ${client:+-c "$client"} "$1" 2>/dev/null || :; }
client=$(tmux list-clients -t "$sess" -F '#{client_activity} #{client_name}' 2>/dev/null \
  | sort -rn | head -1 | cut -d' ' -f2-)

if [ "$verb" = reap ]; then
  if [ -n "$remote" ]; then bash "$BIN/fleet-sidebar-remote.sh" reap "$sess" "$wid" "$client"
  else bash "$BIN/fleet-sidebar-reap.sh" "$sess" "$wid" "$client"; fi
  exit 0
fi

# «New task on <m>…» (issue #1487 ④): one item per OTHER machine the sidebar's
# cache (fleet-hub-sessions.sh, `#node` lines) says is online — keys 1…9 in
# cache order. No cache (the hub off) ⇒ no items: the menu is byte for byte the
# one-machine menu. Each files the issue and spawns its worker THERE
# (dash-issue-new.sh --node=<m> → dash-issue-session.sh --node, #1475).
add_newto() {
  local n i=0 m
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    i=$((i + 1)); [ "$i" -le 9 ] || break
    printf -v m "$m_newto_fmt" "$(fe "$n")"
    add "$m" "$i" "$(sh_run "bash $(sq "$BIN/dash-popup.sh") -w 90% -h 12 -- bash $(sq "$BIN/dash-issue-new.sh") confirm --spawn --node=$(sq "$n")")"
  done <<EOF
$(LC_ALL=C awk -F $'\037' '$1 == "#node" && $3 == "online" && $2 != "" { print $2 }' "$FLEET_C/global/remote_$sess" 2>/dev/null)
EOF
}

if [ -n "$remote" ]; then
  # Its machine, name, state and what it needs come from the sidebar's own cache
  # (never the network), as fleet-remote-view.sh reads them.
  row=$(LC_ALL=C awk -F $'\037' -v w="$wid" '$1 == w { print $2 "\037" $8 "\037" $6 "\037" $10; exit }' \
        "$FLEET_C/global/remote_$sess" 2>/dev/null)
  node="${row%%$'\037'*}"; row="${row#*$'\037'}"
  name="${row%%$'\037'*}"; row="${row#*$'\037'}"
  rstate="${row%%$'\037'*}"; rneeds="${row#*$'\037'}"
  [ -n "$node" ] || exit 0
  title=$(fleet_ui_t menu_title_on_node_fmt "${name:-${wid##*/}}" "$node")
  side=$(tmux list-panes -t "$sess:" -F '#{pane_id} #{@sidebar}' 2>/dev/null | awk '$2==1{print $1; exit}')
  ctx="FLEET_SESSION=$(sq "$sess") TMUX_PANE=$(sq "${side:-}")"
  [ -n "${FLEET_CONF_DIR:-}" ] && ctx="$ctx FLEET_CONF_DIR=$(sq "$FLEET_CONF_DIR")"
  [ -n "${FLEET_UI_LANG:-}" ] && ctx="$ctx FLEET_UI_LANG=$(sq "$FLEET_UI_LANG")"
  sh_run() { printf 'run-shell -b %s' "$(sq "$ctx $1 >/dev/null 2>&1 || :")"; }
  items=()
  add() { items+=("$1" "$2" "$3"); }
  add "$m_open_remote" "$(mk open)" "$(sh_run "bash $(sq "$BIN/fleet-remote-view.sh") open $(sq "$wid")")"
  # The actions (issue #1487): every one a hub write through fleet-sidebar-remote.sh.
  # Popups for the two that take input (message text, the answer); the others run
  # detached and toast. Reap confirms first, as a local row's does.
  rmt="bash $(sq "$BIN/fleet-sidebar-remote.sh")"
  rargs="$(sq "$sess") $(sq "$wid")"; [ -n "$client" ] && rargs="$rargs $(sq "$client")"
  add "$m_r_message" "$(mk message)" "$(sh_run "bash $(sq "$BIN/dash-popup.sh") -w 84% -h 12 -- $rmt message $rargs")"
  case "$rneeds:$rstate" in
    ask:*|perm:*|*:needs) add "$m_r_answer" "$(mk answer)" "$(sh_run "bash $(sq "$BIN/dash-popup.sh") -w 84% -h 14 -- $rmt answer $rargs")" ;;
    *) add "-$m_r_answer_none" "$(mk answer)" '' ;;
  esac
  add "$m_r_stop" "$(mk stop)" "$(sh_run "$rmt stop $rargs")"
  add "$m_r_resume" "$(mk resume)" "$(sh_run "$rmt resume $rargs")"
  printf -v m_r_reap_confirm "$m_r_reap_confirm_fmt" "$(fe "${name:-${wid##*/}}")" "$(fe "$node")"
  add "$m_reap" "$(mk reap)" "confirm-before -p $(sq "$m_r_reap_confirm") $(dq "$(sh_run "$rmt reap $rargs")")"
  add "" "" ""
  add "$m_new" "$(mk new)" "$(sh_run "bash $(sq "$BIN/dash-popup.sh") -w 90% -h 12 -- bash $(sq "$BIN/dash-issue-new.sh") confirm --spawn")"
  add_newto
  add "$m_restore" "$(mk restore)" "$(sh_run "bash $(sq "$BIN/fleet-restore-pick.sh") --session $(sq "$sess")")"
  add "$m_repo" "$(mk repo)" "$(sh_run "bash $(sq "$BIN/dash-popup.sh") -w 80% -h 16 -- bash $(sq "$BIN/dash-repo-add.sh")")"
  if [ "${4:-}" = --print ]; then
    printf 'title\t%s\n' "$title"
    i=0
    while [ "$i" -lt "${#items[@]}" ]; do
      printf '%s\t%s\t%s\n' "${items[$((i + 1))]}" "${items[$i]}" "${items[$((i + 2))]}"
      i=$((i + 3))
    done
    exit 0
  fi
  [ -n "$client" ] || exit 0
  tmux display-menu -c "$client" ${side:+-t "$side"} -x P -y P \
    -T "#[align=centre] $(fe "$title") " ${items[@]+"${items[@]}"} 2>/dev/null || :
  exit 0
fi

name=$(tmux display-message -p -t "$wid" '#{window_name}' 2>/dev/null)
state=$(tmux display-message -p -t "$wid" '#{@claude_state}' 2>/dev/null)
life=$(tmux display-message -p -t "$wid" '#{@worker_lifecycle}' 2>/dev/null)
keep=$(tmux show-options -wqv -t "$wid" @sleep_keep_awake 2>/dev/null)
pin=$(tmux show-options -wqv -t "$wid" @pin 2>/dev/null)
pr=$(FLEET_SESSION="$sess" bash "$BIN/dash-open-pr.sh" --wid "$wid" --probe 2>/dev/null </dev/null)
case "${FLEET_AGENT:-claude}" in codex) next=Claude ;; *) next=Codex ;; esac
# The sidebar pane on screen anchors the menu; FLEET_SESSION / TMUX_PANE give the
# popup-opening scripts the context they read inside a pane (dash-popup.sh).
side=$(tmux list-panes -t "$sess:" -F '#{pane_id} #{@sidebar}' 2>/dev/null | awk '$2==1{print $1; exit}')
ctx="FLEET_SESSION=$(sq "$sess") TMUX_PANE=$(sq "${side:-}")"
[ -n "${FLEET_CONF_DIR:-}" ] && ctx="$ctx FLEET_CONF_DIR=$(sq "$FLEET_CONF_DIR")"
[ -n "${FLEET_UI_LANG:-}" ] && ctx="$ctx FLEET_UI_LANG=$(sq "$FLEET_UI_LANG")"
sh_run() { printf 'run-shell -b %s' "$(sq "$ctx $1 >/dev/null 2>&1 || :")"; }

items=()
add() { items+=("$1" "$2" "$3"); }   # name key command
# Rename edits in the view's own input line (fleet-sidebar.py `renaming`): park
# the row's id on the view, keep the keyboard there, and wake it with F12. The
# view pins the client to itself on its next poll (#1105), so a paste of the new
# name lands on the input line.
if [ -n "$side" ]; then
  add "$m_rename" "$(mk rename)" "set-option -p -t $side @sidebar_rename $wid ; switch-client -T fleet-sidebar ; send-keys -t $side F12"
else add "-$m_rename" "$(mk rename)" ''; fi
if [ "$pin" = 1 ]; then add "$m_unpin" "$(mk pin)" "$(sh_run "bash $(sq "$BIN/dash-pin-toggle.sh") $wid")"
else add "$m_pin" "$(mk pin)" "$(sh_run "bash $(sq "$BIN/dash-pin-toggle.sh") $wid")"; fi
if [ -n "$pr" ]; then add "$m_open_pr $(fe "$pr")" "$(mk pr)" "$(sh_run "bash $(sq "$BIN/dash-open-pr.sh") --wid $wid")"
else add "-$m_open_pr_none" "$(mk pr)" ''; fi
if [ "$state" = needs ]; then
  add "$m_answer" "$(mk answer)" "$(sh_run "bash $(sq "$BIN/dash-popup.sh") -w 84% -h 70% -- bash $(sq "$BIN/dash-answer.sh") $(sq "$sess:$wid")")"
else add "-$m_answer_none" "$(mk answer)" ''; fi
if fleet_pane_claude_pid "$wid" >/dev/null 2>&1; then
  add "$m_sub" "$(mk sub)" "$(sh_run "bash $(sq "$BIN/dash-migrate.sh") $wid choose")"
else add "-$m_sub_none" "$(mk sub)" ''; fi
# Wake (issue #1051): only a sleeping row gets it, and it wakes at once — opening
# the menu and picking it is already the second deliberate step (EPIC #1048
# decision 4). Detached, because the wake respawns the pane. Keep awake flips the
# sleep controller's own @sleep_keep_awake hold; the label says what a pick does.
# --over-cap (issue #1058): the operator's own wake goes even at the session limit.
slp="bash $(sq "$BIN/fleet-sleep.sh")"
[ "$life" = sleeping ] && add "$m_wake" "$(mk wake)" "$(sh_run "$slp wake $(sq "$sess") $wid --over-cap")"
if [ "$keep" = 1 ]; then add "$m_allow_sleep" "$(mk awake)" "$(sh_run "$slp allow-sleep $(sq "$sess") $wid")"
else add "$m_keep_awake" "$(mk awake)" "$(sh_run "$slp keep-awake $(sq "$sess") $wid")"; fi
printf -v m_agent "$m_agent_fmt" "$next"
add "$m_agent" "$(mk agent)" "$(sh_run "bash $(sq "$BIN/dash-agent-toggle.sh")")"
printf -v m_reap_confirm "$m_reap_confirm_fmt" "$(fe "$name")"
reap_args="$(sq "$sess") $wid"; [ -n "$client" ] && reap_args="$reap_args $(sq "$client")"
add "$m_reap" "$(mk reap)" "confirm-before -p $(sq "$m_reap_confirm") $(dq "$(sh_run "bash $(sq "$BIN/fleet-sidebar-reap.sh") $reap_args")")"
add "" "" ""
add "$m_new" "$(mk new)" "$(sh_run "bash $(sq "$BIN/dash-popup.sh") -w 90% -h 12 -- bash $(sq "$BIN/dash-issue-new.sh") confirm --spawn")"
add_newto
# Row-less too (issue #901): the hub's ⌃t landed list + ⌃o, as one popup.
add "$m_restore" "$(mk restore)" "$(sh_run "bash $(sq "$BIN/fleet-restore-pick.sh") --session $(sq "$sess")")"
# Row-less (issue #1103): the hub's ⌃z — the same popup, the same script. Listed
# in a one-repo fleet too: it is how the second repo gets in.
add "$m_repo" "$(mk repo)" "$(sh_run "bash $(sq "$BIN/dash-popup.sh") -w 80% -h 16 -- bash $(sq "$BIN/dash-repo-add.sh")")"

if [ "${4:-}" = --print ]; then
  i=0
  while [ "$i" -lt "${#items[@]}" ]; do
    printf '%s\t%s\t%s\n' "${items[$((i + 1))]}" "${items[$i]}" "${items[$((i + 2))]}"
    i=$((i + 3))
  done
  exit 0
fi
[ -n "$client" ] || exit 0
tmux display-menu -c "$client" ${side:+-t "$side"} -x P -y P \
  -T "#[align=centre] $(fe "$name") " ${items[@]+"${items[@]}"} 2>/dev/null || :
exit 0
