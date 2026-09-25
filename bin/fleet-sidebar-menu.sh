# shellcheck shell=bash
# shellcheck disable=SC2154  # $sess $verb come from fleet-sidebar.sh, which sources this
# fleet-sidebar-menu.sh — sourced by fleet-sidebar.sh for `menu` / `reap`
# (issue #898). The task sidebar's per-row action menu: the six things that used
# to need a trip to the hub list — rename, pin, open PR, answer, flip agent,
# reap — plus a sleeping row's Wake and the Keep awake / Allow sleep toggle
# (issue #1051), plus the row-less "new task (file an issue)", "restore a finished
# task" (#901) and "add a repo" (#1103). Every item calls the SAME
# script the hub binds (EPIC #894 convention 1) with the window's stable `@id`,
# never an index or a name. The view (fleet-sidebar.py) opens it on `.` (empty
# input line) or a second tap on the highlighted row; this file owns the tmux
# syntax so the Python never spells a tmux command string.
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
wake	w	唤醒睡眠中的 z 行（仅睡眠时显示）
awake	k	保持唤醒 ⇄ 允许再次休眠
agent	v	新会话 claude ⇄ codex
reap	x	回收 — 先确认 y/n
new	n	新任务 — 建 issue 并启动 worker
restore	o	恢复已收工任务（hub landed 列表，弹窗）
repo	g	添加仓库到这个 fleet — 询问 owner/name；~/projects/<name>，缺失时 clone（hub ⌃z）'
    m_rename='改名…'; m_unpin='取消置顶'; m_pin='置顶'
    m_open_pr='打开 PR'; m_open_pr_none='打开 PR（没有）'
    m_answer='回答它的提问…'; m_answer_none='回答它的提问（没有）'
    m_wake='唤醒'; m_allow_sleep='允许休眠'; m_keep_awake='保持唤醒'
    m_agent_fmt='新会话改用 %s'; m_reap='回收…'; m_reap_confirm_fmt='回收「%s」？(y/n)'
    m_new='新建任务（建 issue）…'; m_restore='恢复已收工…'; m_repo='＋ 仓库…'
    ;;
  *)
MENU_KEYS='rename	r	rename — edits on the input line (↵ applies, esc / an empty name cancels)
pin	t	pin / unpin the row to the top
pr	p	open its PR (greyed when it has none)
answer	a	answer its question (a red ? row; greyed otherwise)
wake	w	wake a sleeping (z) row now — only listed on one
awake	k	keep it awake ⇄ allow it to sleep again
agent	v	flip new sessions claude ⇄ codex
reap	x	reap it — asks y/n first
new	n	new task — file an issue AND spawn its worker
restore	o	restore a finished task (the hub landed list, in a popup)
repo	g	add a repo to this fleet — asks owner/name; ~/projects/<name>, cloned if missing (the hub ⌃z)'
    m_rename='Rename…'; m_unpin='Unpin'; m_pin='Pin'
    m_open_pr='Open PR'; m_open_pr_none='Open PR (none)'
    m_answer='Answer question…'; m_answer_none='Answer question (none)'
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
case "$wid" in @[0-9]*) ;; *) exit 0 ;; esac
# Never act on another fleet's window, or a stale id tmux recycled elsewhere.
[ "$(tmux display-message -p -t "$wid" '#{session_name}' 2>/dev/null)" = "$sess" ] || exit 0

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
  bash "$BIN/fleet-sidebar-reap.sh" "$sess" "$wid" "$client"
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
