# shellcheck shell=bash
# shellcheck disable=SC2154  # $sess $verb come from fleet-sidebar.sh, which sources this
# fleet-sidebar-menu.sh — sourced by fleet-sidebar.sh for `menu` / `reap`
# (issue #898). The task sidebar's per-row action menu: rename, pin, open PR,
# answer, switch subscription, flip agent, and reap, plus a sleeping row's Wake
# and the Keep awake / Allow sleep toggle
# (issue #1051), plus the row-less "new task (file an issue)", "restore a finished
# task" (#901) and "add a repo" (#1103). Every item calls the SAME
# script the hub binds (EPIC #894 convention 1) with the window's stable `@id`,
# never an index or a name. The view (fleet-sidebar.py) opens it on a second tap
# on the highlighted row or a right-click (issue #1950); this file owns the tmux
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

# Every string — the letter table (`menu_keys`: action<TAB>letter<TAB>what, read
# by the menu below via `mk <action>` and by the `?` sheet via --keys) and every
# item's label — comes from THE table, fleet-ui-lang.sh (issue #1535). The
# language is resolved once (fleet_ui_pin); `t` is the lookup.
fleet_ui_pin
t() { fleet_ui_t "$@"; }
MENU_KEYS=$(t menu_keys)
mk() { printf '%s\n' "$MENU_KEYS" | awk -F '\t' -v a="$1" '$1 == a { print $2; exit }'; }
if [ "${1:-}" = --keys ]; then
  # the shell's menu has no row-less items (issue #1518), so its sheet lists none
  printf '%s\n' "$MENU_KEYS" | awk -F '\t' -v sh="${FLEET_SHELL:-0}" \
    'sh == 1 && ($1 == "new" || $1 == "newto" || $1 == "restore" || $1 == "repo") { next }
     sh != 1 && $1 == "clients" { next } { print $2 "\t" $3 }'
  exit 0
fi

wid="${3:-}"
# A row on another machine (`wid:<fleet>/<name>`, #1423) gets a menu too (issue
# #1475): titled `<name> · 在 m4` — the ONE place the list names the machine, now
# that the rows look alike — with `enter` (the proxy window) and the row-less
# items. Everything a local row's menu does needs a window here; it has none.
remote=''
case "$wid" in @[0-9]*) ;; wid:*/*) remote=1 ;; *) exit 0 ;; esac
# Never act on another fleet's window, or a stale id tmux recycled elsewhere.
[ -n "$remote" ] || [ "$(tmux display-message -p -t "$wid" '#{?#{session_group},#{session_group},#{session_name}}' 2>/dev/null)" = "$sess" ] || exit 0

# sq <text> → one word for BOTH /bin/sh and tmux's command parser: single quotes
# (no $ ~ expansion in either), an embedded quote closed, escaped and reopened.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# dq <text> → one double-quoted tmux command string; used when the nested command
# already contains shell single quotes and confirm-before should receive it whole.
dq() { printf '"%s"' "$(printf '%s' "$1" | sed 's/["\\]/\\&/g')"; }
# fe <text> → literal inside a tmux FORMAT (menu names/title, -I input): ## = #.
fe() { printf '%s' "$1" | sed 's/#/##/g'; }
# ask <kind> [arg…] → the tmux command that asks on one line under the session
# instead of a popup (issues #1620, #1950): park `<kind> <arg>…` on the view
# (@sidebar_ask) and wake it with F12 — the path rename took since #898
# (fleet-sidebar.py `Ask`, bin/fleet-ask.py); the question's line takes the
# keyboard. Every arg is a token (@id, wid:…, a machine, a needs word), so a
# space separates them. Empty when no view is on screen; the caller greys the
# item then.
ask() {
  [ -n "${side:-}" ] || return 0
  printf 'set-option -p -t %s @sidebar_ask %s ; send-keys -t %s F12' \
    "$side" "$(sq "$*")" "$side"
}

toast() { tmux display-message ${client:+-c "$client"} "$1" 2>/dev/null || :; }
client=$(tmux list-clients -t "$sess" -F '#{client_activity} #{client_name}' 2>/dev/null \
  | sort -rn | head -1 | cut -d' ' -f2-)

if [ "$verb" = reap ]; then
  if [ -n "$remote" ]; then bash "$BIN/fleet-sidebar-remote.sh" reap "$sess" "$wid" "$client"
  else bash "$BIN/fleet-sidebar-reap.sh" "$sess" "$wid" "$client"; fi
  exit 0
fi

# 入口通不通 (issue #1483, EPIC #1479 C4): global/hub_ok through the one rule in
# fleet-status-lib.sh — the sidebar's rows and the bar read the same file. Lost ⇒
# a remote row's title carries 「入口失联 3m」 and «新建到 m4…» is greyed (a spawn
# there is a hub placement); the row's actions stay listed — each refuses with a
# toast of its own (fleet-sidebar-remote.sh), so a tap is never silent. No cache
# (the hub off): no word, nothing here runs.
HUB_LOST=''; ME=''
if [ -s "$FLEET_C/global/remote_$sess" ]; then
  # shellcheck disable=SC2034  # FLEET_STATUS_G is read by the lib sourced on the same line
  FLEET_STATUS_G="$FLEET_C/global"; . "$BIN/fleet-status-lib.sh"
  fleet_status_remote_head "$sess"; ME=$FSR_ME; fleet_status_hub_ok "$FSR_TS"
  if fleet_status_hub_lost "$(date +%s)"; then fleet_status_age "$FSH_AGE"; HUB_LOST=$(fleet_ui_t hub_lost_fmt "$FSA"); fi
fi

# «New task on <m>…» (issue #1487 ④): one item per OTHER machine the sidebar's
# cache (fleet-hub-sessions.sh, `#node` lines) says is online — keys 1…9 in
# cache order. No cache (the hub off) ⇒ no items: the menu is byte for byte the
# one-machine menu. Each files the issue and spawns its worker THERE
# (dash-issue-new.sh --node=<m> → dash-issue-session.sh --node, #1475); greyed,
# with the reason, while the hub is silent (#1483).
add_newto() {
  local n i=0 m
  while IFS= read -r n; do
    # a machine name is a token (dash-issue-new.sh --node= checks it again), so it
    # travels unquoted
    case "$n" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    i=$((i + 1)); [ "$i" -le 9 ] || break
    m=$(t menu_newto_fmt "$n")
    if [ -n "$HUB_LOST" ]; then add "-$m · $HUB_LOST" "$i" ''
    else adda "$m" "$i" "$(ask new "$n")"; fi
  done <<EOF
$(LC_ALL=C awk -F $'\037' '$1 == "#node" && $3 == "online" && $2 != "" { print $2 }' "$FLEET_C/global/remote_$sess" 2>/dev/null)
EOF
}

# One menu frame (issue #1535, EPIC #1529 E6) — the same for a local row and a
# row on another machine:
#
#   title    「名称 · 机器 · 状态」: the machine only when the hub is on (a
#            one-machine login has nothing to tell apart), the state only when
#            the row wants you (its needs word, the act cell's), then the hub's
#            silence if any
#   groups   进入 / 消息 / 控制 / 其它, in that order, a rule between two that
#            both have items; a group with nothing in it is not drawn
#   last     「Esc 关闭」, greyed — the menu always says how it closes
#
# Each item's LETTER is fixed by menu_keys whatever group it lands in.
items=()
add() { items+=("$1" "$2" "$3"); }   # name key command
adda() {   # an item that asks on the view's line: greyed when no view is up
  if [ -n "$3" ]; then add "$1" "$2" "$3"; else add "-$1" "$2" ''; fi
}
group() {   # a rule before the next group, never two in a row, never first
  local n=${#items[@]}
  [ "$n" -gt 0 ] && [ -n "${items[$((n - 3))]}" ] && add "" "" ""
  return 0
}
state_word() {   # <state> <needs kind> → the act cell's word, or nothing
  case "$1" in
    needs)  case "$2" in ask|perm|blocked|restore) t "needs_$2" ;; *) t needs_other ;; esac ;;
    failed) t needs_failed ;;
  esac
}
# show <title> — print (--print, the tests) or draw the menu
show() {
  local i=0 margs=()
  add "" "" ""
  add "-$(t ui_close)" "" ""
  if [ "$PRINT" = 1 ]; then
    printf 'title\t%s\n' "$1"
    while [ "$i" -lt "${#items[@]}" ]; do
      printf '%s\t%s\t%s\n' "${items[$((i + 1))]}" "${items[$i]}" "${items[$((i + 2))]}"
      i=$((i + 3))
    done
    exit 0
  fi
  [ -n "$client" ] || exit 0
  # a rule is ONE argument to display-menu (an empty name), an item three
  while [ "$i" -lt "${#items[@]}" ]; do
    if [ -z "${items[$i]}" ]; then margs+=("")
    else margs+=("${items[$i]}" "${items[$((i + 1))]}" "${items[$((i + 2))]}"); fi
    i=$((i + 3))
  done
  # the popup frame's border, title and colours (issue #1619)
  . "$BIN/fleet-popup-lib.sh"; fleet_menu_style
  tmux display-menu -c "$client" ${side:+-t "$side"} -x P -y P ${FMENU_STYLE[@]+"${FMENU_STYLE[@]}"} \
    -T "#[align=centre] $(fe "$1") " -- ${margs[@]+"${margs[@]}"} 2>/dev/null || :
  exit 0
}
PRINT=''; [ "${4:-}" = --print ] && PRINT=1

# The row-less items, the same at the bottom of both menus.
add_other() {
  # Each asks on the view's input line (issue #1620), not in a popup: a new
  # task's title (Tab picks the repo in a 2+ repo fleet) …
  adda "$(t menu_new)" "$(mk new)" "$(ask new)"
  add_newto
  # Row-less too (issue #901): the landed list — the view's own ⌃t list, in
  # place (the restore popup was that list a second time) …
  adda "$(t menu_restore)" "$(mk restore)" "$(ask landed)"
  # Row-less (issue #1103): the hub's ⌃z, as an owner/name on the line.
  # Listed in a one-repo fleet too: it is how the second repo gets in.
  adda "$(t menu_repo)" "$(mk repo)" "$(ask repo)"
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
  # 「名称 · m4 · 在问你」 — the ONE place the list names the machine (#1475)
  title="${name:-${wid##*/}} · $node"
  # a prompt the hub saw is a needs row whatever its state field says (as the
  # answer item below reads it)
  case "$rneeds" in ask|perm) word=$(state_word needs "$rneeds") ;; *) word=$(state_word "$rstate" "$rneeds") ;; esac
  [ -z "$word" ] || title="$title · $word"
  [ -z "$HUB_LOST" ] || title="$title · $HUB_LOST"          # the hub silent (#1483)
  side=$(tmux list-panes -t "$sess:" -F '#{pane_id} #{@sidebar}' 2>/dev/null | awk '$2==1{print $1; exit}')
  ctx="FLEET_SESSION=$(sq "$sess") TMUX_PANE=$(sq "${side:-}")"
  [ -n "${FLEET_CONF_DIR:-}" ] && ctx="$ctx FLEET_CONF_DIR=$(sq "$FLEET_CONF_DIR")"
  [ -n "${FLEET_UI_LANG:-}" ] && ctx="$ctx FLEET_UI_LANG=$(sq "$FLEET_UI_LANG")"
  sh_run() { printf 'run-shell -b %s' "$(sq "$ctx $1 >/dev/null 2>&1 || :")"; }
  # The actions (issue #1487): every one a hub write through fleet-sidebar-remote.sh.
  # The two that take input (message text, the answer) ask on the view's input
  # line (issue #1620); the others run detached and toast. Reap confirms first,
  # as a local row's does.
  rmt="bash $(sq "$BIN/fleet-sidebar-remote.sh")"
  rargs="$(sq "$sess") $(sq "$wid")"; [ -n "$client" ] && rargs="$rargs $(sq "$client")"
  # 进入
  add "$(t menu_open_remote)" "$(mk open)" "$(sh_run "bash $(sq "$BIN/fleet-remote-view.sh") open $(sq "$wid")")"
  # 消息
  group
  adda "$(t menu_r_message)" "$(mk message)" "$(ask message "$wid")"
  case "$rneeds:$rstate" in
    ask:*|perm:*|*:needs) adda "$(t menu_r_answer)" "$(mk answer)" "$(ask answer "$wid" "$rneeds")" ;;
    *) add "-$(t menu_r_answer_none)" "$(mk answer)" '' ;;
  esac
  # 控制
  group
  add "$(t menu_r_stop)" "$(mk stop)" "$(sh_run "$rmt stop $rargs")"
  add "$(t menu_r_resume)" "$(mk resume)" "$(sh_run "$rmt resume $rargs")"
  m_r_reap_confirm=$(t menu_r_reap_confirm_fmt "$(fe "${name:-${wid##*/}}")" "$(fe "$node")")
  add "$(t menu_reap)" "$(mk reap)" "confirm-before -p $(sq "$m_r_reap_confirm") $(dq "$(sh_run "$rmt reap $rargs")")"
  # 其它 — not in the SHELL (issue #1518): its computer has no fleet conf, gh or
  # worktree, and its install (fleetclient/manifest) ships none of the scripts
  # these four run, so each was a silent no-op there. The shell's every row is
  # remote, so this is the only branch it reaches.
  if [ "${FLEET_SHELL:-0}" != 1 ]; then
    group
    add_other
  else
    # 我的客户端 (issue #1932): the clients open at once, one to disconnect —
    # a second menu, drawn by fleet-client-menu.sh on the same client
    group
    add "$(t menu_clients)" "$(mk clients)" "$(sh_run "bash $(sq "$BIN/fleet-client-menu.sh") menu $(sq "$sess")${client:+ $(sq "$client")}")"
  fi
  show "$title"
fi

name=$(tmux display-message -p -t "$wid" '#{window_name}' 2>/dev/null)
state=$(tmux display-message -p -t "$wid" '#{@claude_state}' 2>/dev/null)
needs=$(tmux display-message -p -t "$wid" '#{@claude_needs}' 2>/dev/null)
life=$(tmux display-message -p -t "$wid" '#{@worker_lifecycle}' 2>/dev/null)
keep=$(tmux show-options -wqv -t "$wid" @sleep_keep_awake 2>/dev/null)
pin=$(tmux show-options -wqv -t "$wid" @pin 2>/dev/null)
pr=$(FLEET_SESSION="$sess" bash "$BIN/dash-open-pr.sh" --wid "$wid" --probe 2>/dev/null </dev/null)
case "${FLEET_AGENT:-claude}" in codex) next=Claude ;; *) next=Codex ;; esac
# The sidebar pane on screen anchors the menu; FLEET_SESSION / TMUX_PANE give the
# scripts the items run the context they read inside a pane.
side=$(tmux list-panes -t "$sess:" -F '#{pane_id} #{@sidebar}' 2>/dev/null | awk '$2==1{print $1; exit}')
ctx="FLEET_SESSION=$(sq "$sess") TMUX_PANE=$(sq "${side:-}")"
[ -n "${FLEET_CONF_DIR:-}" ] && ctx="$ctx FLEET_CONF_DIR=$(sq "$FLEET_CONF_DIR")"
[ -n "${FLEET_UI_LANG:-}" ] && ctx="$ctx FLEET_UI_LANG=$(sq "$FLEET_UI_LANG")"
# Once the action is done, F11 wakes the view to read the rows at once (issue
# #1530) — a pin, a wake, a reap shows in the next frame, not after the 1 s tick.
wake=''; [ -n "$side" ] && wake="; tmux send-keys -t $side F11 >/dev/null 2>&1"
sh_run() { printf 'run-shell -b %s' "$(sq "$ctx $1 >/dev/null 2>&1$wake || :")"; }

title=$name
[ -z "$ME" ] || title="$title · $ME"
word=$(state_word "$state" "$needs"); [ -z "$word" ] || title="$title · $word"
# 进入
if [ -n "$pr" ]; then add "$(t menu_open_pr) $(fe "$pr")" "$(mk pr)" "$(sh_run "bash $(sq "$BIN/dash-open-pr.sh") --wid $wid")"
else add "-$(t menu_open_pr_none)" "$(mk pr)" ''; fi
# 消息
group
# 回答 goes to the row's own pane (issue #1620): the question is there, in the
# agent's own picker — the answer popup only copied it.
if [ "$state" = needs ]; then
  adda "$(t menu_answer)" "$(mk answer)" "$(ask jump "$wid")"
else add "-$(t menu_answer_none)" "$(mk answer)" ''; fi
# 控制
group
# Rename edits in the view's own input line (fleet-sidebar.py `Ask`): park
# the row's id on the view, keep the keyboard there, and wake it with F12. The
# view pins the client to itself on its next poll (#1105), so a paste of the new
# name lands on the input line.
if [ -n "$side" ]; then add "$(t menu_rename)" "$(mk rename)" "$(ask rename "$wid")"
else add "-$(t menu_rename)" "$(mk rename)" ''; fi
if [ "$pin" = 1 ]; then add "$(t menu_unpin)" "$(mk pin)" "$(sh_run "bash $(sq "$BIN/dash-pin-toggle.sh") $wid")"
else add "$(t menu_pin)" "$(mk pin)" "$(sh_run "bash $(sq "$BIN/dash-pin-toggle.sh") $wid")"; fi
# 切换 sub: the account on the input line, Tab through them with their quota
# (issue #1620) — dash-migrate.sh <@id> to <account> does the move.
if fleet_pane_claude_pid "$wid" >/dev/null 2>&1 && [ -n "$side" ]; then
  add "$(t menu_sub)" "$(mk sub)" "$(ask sub "$wid")"
else add "-$(t menu_sub_none)" "$(mk sub)" ''; fi
# Wake (issue #1051): only a sleeping row gets it, and it wakes at once — opening
# the menu and picking it is already the second deliberate step (EPIC #1048
# decision 4). Detached, because the wake respawns the pane. Keep awake flips the
# sleep controller's own @sleep_keep_awake hold; the label says what a pick does.
# --over-cap (issue #1058): the operator's own wake goes even at the session limit.
slp="bash $(sq "$BIN/fleet-sleep.sh")"
[ "$life" = sleeping ] && add "$(t menu_wake)" "$(mk wake)" "$(sh_run "$slp wake $(sq "$sess") $wid --over-cap")"
if [ "$keep" = 1 ]; then add "$(t menu_allow_sleep)" "$(mk awake)" "$(sh_run "$slp allow-sleep $(sq "$sess") $wid")"
else add "$(t menu_keep_awake)" "$(mk awake)" "$(sh_run "$slp keep-awake $(sq "$sess") $wid")"; fi
# 改回收方式 (issue #1902): a second menu of the five policies, the current one
# marked; it writes @reap_policy through the one setter the session's own
# `set_reap` tool runs too.
add "$(t menu_reap_policy)" "$(mk reappol)" "$(sh_run "bash $(sq "$BIN/fleet-reap-policy.sh") menu $(sq "$sess") $wid${client:+ $(sq "$client")}")"
m_reap_confirm=$(t menu_reap_confirm_fmt "$(fe "$name")")
reap_args="$(sq "$sess") $wid"; [ -n "$client" ] && reap_args="$reap_args $(sq "$client")"
add "$(t menu_reap)" "$(mk reap)" "confirm-before -p $(sq "$m_reap_confirm") $(dq "$(sh_run "bash $(sq "$BIN/fleet-sidebar-reap.sh") $reap_args")")"
# 其它
group
add "$(t menu_agent_fmt "$next")" "$(mk agent)" "$(sh_run "bash $(sq "$BIN/dash-agent-toggle.sh")")"
add_other
show "$title"
