# shellcheck shell=bash
# shellcheck disable=SC2154  # $sess $verb come from fleet-sidebar.sh, which sources this
# fleet-sidebar-menu.sh — sourced by fleet-sidebar.sh for `menu` / `reap`
# (issue #898). The task sidebar's per-row action menu: the six things that used
# to need a trip to the hub list — rename, pin, open PR, answer, flip agent,
# reap — plus a sleeping row's Wake and the Keep awake / Allow sleep toggle
# (issue #1051), plus the row-less "new task (file an issue)" and "restore a finished
# task" (#901). Every item calls the SAME
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

# The menu's letters: ONE table, read by the menu below (`mk <action>`) and by
# the `?` sheet (--keys), so the sheet can never name a letter the menu lacks.
MENU_KEYS='rename	r	rename — edits on the input line (↵ applies, esc / an empty name cancels)
pin	t	pin / unpin the row to the top
pr	p	open its PR (greyed when it has none)
answer	a	answer its question (a red ? row; greyed otherwise)
wake	w	wake a sleeping (z) row now — only listed on one
awake	k	keep it awake ⇄ allow it to sleep again
agent	v	flip new sessions claude ⇄ codex
reap	x	reap it — asks y/n first
new	n	new task — file an issue AND spawn its worker
restore	o	restore a finished task (the hub landed list, in a popup)'
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
# fe <text> → literal inside a tmux FORMAT (menu names/title, -I input): ## = #.
fe() { printf '%s' "$1" | sed 's/#/##/g'; }

toast() { tmux display-message ${client:+-c "$client"} "$1" 2>/dev/null || :; }
client=$(tmux list-clients -t "$sess" -F '#{client_activity} #{client_name}' 2>/dev/null \
  | sort -rn | head -1 | cut -d' ' -f2-)

if [ "$verb" = reap ]; then
  # --yes: the confirm-before that led here IS the confirm (EPIC decision 5).
  # dash-reap.sh still never removes a dirty worktree, and still refuses a live
  # agent (skip:live) whatever --yes says.
  out=$(bash "$BIN/dash-reap.sh" "$wid" --yes 2>/dev/null </dev/null)
  token=$(printf '%s\n' "$out" | grep -E '^(reaped|skip|refused):' | tail -1)
  case "$token" in
    reaped:full) toast "fleet: reaped" ;;
    reaped:keep) toast "fleet: reaped — dirty worktree kept on disk" ;;
    skip:live)   toast "fleet: not reaped — the agent is still live (or too young)" ;;
    skip:*)      toast "fleet: not reaped (${token#skip:})" ;;
    refused:*)   toast "fleet: not reaped — ${token#refused:}" ;;
    *)           toast "fleet: reap gave no result — check the hub" ;;
  esac
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
sh_run() { printf 'run-shell -b %s' "$(sq "$ctx $1 >/dev/null 2>&1 || :")"; }

items=()
add() { items+=("$1" "$2" "$3"); }   # name key command
# Rename edits in the view's own input line (fleet-sidebar.py `renaming`): park
# the row's id on the view, keep the keyboard there, and wake it with F12.
if [ -n "$side" ]; then
  add "改名…" "$(mk rename)" "set-option -p -t $side @sidebar_rename $wid ; switch-client -T fleet-sidebar ; send-keys -t $side F12"
else add "-改名…" "$(mk rename)" ''; fi
if [ "$pin" = 1 ]; then add "取消置顶" "$(mk pin)" "$(sh_run "bash $(sq "$BIN/dash-pin-toggle.sh") $wid")"
else add "置顶" "$(mk pin)" "$(sh_run "bash $(sq "$BIN/dash-pin-toggle.sh") $wid")"; fi
if [ -n "$pr" ]; then add "打开 PR $(fe "$pr")" "$(mk pr)" "$(sh_run "bash $(sq "$BIN/dash-open-pr.sh") --wid $wid")"
else add "-打开 PR（没有）" "$(mk pr)" ''; fi
if [ "$state" = needs ]; then
  add "回答它的提问…" "$(mk answer)" "$(sh_run "bash $(sq "$BIN/dash-popup.sh") -w 84% -h 70% -- bash $(sq "$BIN/dash-answer.sh") $(sq "$sess:$wid")")"
else add "-回答它的提问（没有）" "$(mk answer)" ''; fi
# Wake (issue #1051): only a sleeping row gets it, and it wakes at once — opening
# the menu and picking it is already the second deliberate step (EPIC #1048
# decision 4). Detached, because the wake respawns the pane. Keep awake flips the
# sleep controller's own @sleep_keep_awake hold; the label says what a pick does.
# --over-cap (issue #1058): the operator's own wake goes even at the session limit.
slp="bash $(sq "$BIN/fleet-sleep.sh")"
[ "$life" = sleeping ] && add "唤醒" "$(mk wake)" "$(sh_run "$slp wake $(sq "$sess") $wid --over-cap")"
if [ "$keep" = 1 ]; then add "允许休眠" "$(mk awake)" "$(sh_run "$slp allow-sleep $(sq "$sess") $wid")"
else add "保持唤醒" "$(mk awake)" "$(sh_run "$slp keep-awake $(sq "$sess") $wid")"; fi
add "新会话改用 $next" "$(mk agent)" "$(sh_run "bash $(sq "$BIN/dash-agent-toggle.sh")")"
add "回收…" "$(mk reap)" "confirm-before -p $(sq "回收「$(fe "$name")」？(y/n)") $(sq "$(sh_run "bash $(sq "$BIN/fleet-sidebar.sh") reap $(sq "$sess") $wid")")"
add "" "" ""
add "新建任务（建 issue）…" "$(mk new)" "$(sh_run "bash $(sq "$BIN/dash-popup.sh") -w 90% -h 12 -- bash $(sq "$BIN/dash-issue-new.sh") confirm --spawn")"
# Row-less too (issue #901): the hub's ⌃t landed list + ⌃o, as one popup.
add "恢复已收工…" "$(mk restore)" "$(sh_run "bash $(sq "$BIN/fleet-restore-pick.sh") --session $(sq "$sess")")"

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
