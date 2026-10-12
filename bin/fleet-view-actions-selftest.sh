#!/bin/bash
# fleet-view-actions-selftest.sh — Tab on a row of the 看台's list (issue #3181,
# EPIC #3178 C3): bin/fleet_view.py's ACTIONS, the old sidebar row menu's actions
# item for item, each running the SAME script fleet-sidebar-menu.sh ran.
#
# Isolated sockets only: an INNER server is the home machine (a fleet `fl` + its
# 看台 `fl@view-v1`, as fleet-view-selftest.sh builds them), the rows come through
# the producer seam (FLEET_VIEW_ROWS_CMD), and every script an action runs is a
# STUB (FLEET_VIEW_ACT_BIN) that logs its argv — so "it ran that script, once,
# with these arguments" is read off the log.
#
#   A  the table: every letter of the sidebar menu (fleet-ui-lang.sh menu_keys) is
#      an action here (SIDEBAR_ACTIONS) or a row-less one handed to C2 / C7
#      (ROWLESS) — one missing is red; every action fleet-sidebar-menu.sh builds
#      a row item for (`mk <action>`) is in the table
#   B  view-menu: a done row here gets its actions (no 回答 / 唤醒 / 继续), an
#      asking row 回答, a sleeping one 唤醒, an ended exited one 恢复, another
#      machine's row its hub writes (no 置顶 / PR / 唤醒 there)
#   C  view-act, item by item: each calls its script exactly once with the
#      sidebar's arguments; 改名 really renames the window (dash-rename.sh);
#      回收 without a yes does nothing (exit 3); 恢复 presses ↵ on the wrapper's
#      page and goes there; 进入 changes the 看台's window
#   D  the popup on a client: ⌘P's list, Tab opens the row's menu, Esc steps back
#      and Esc again closes with NOTHING run; Tab → 回收 → n does nothing, → y
#      runs dash-reap.sh once; 改名 asks on the bottom line, Esc cancels it
#   E  another machine's row (issue #3182, EPIC #3178 C4): each `far` action runs
#      fleet-sidebar-remote.sh ONCE with (action, fleet, wid:<worker_id>) and makes
#      ONE hub write (FLEET_HUB_WRITE_CMD) naming that worker_id and the answer;
#      the outcome names the machine; the hub's refusal comes back verbatim with a
#      non-zero exit; a lost row (`!`) runs nothing and says 失联，做不了; every
#      write is followed by one hub cache --refresh; in the popup, Tab → 停 on a
#      far row says how it went on the bottom line; a far 改名 shows its new
#      name at once (issue #3317), held until the hub's row says it or
#      FLEET_VIEW_NAME_HOLD_SECS passes
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }
command -v tmux >/dev/null 2>&1 || { echo "SKIP: no tmux"; exit 0; }
W=$(mktemp -d "${TMPDIR:-/tmp}/fvact.XXXXXX") || exit 1
IN="$W/in.sock"; OUT="$W/out.sock"
cleanup() {
  [ -n "${FLEET_VIEW_KEEP:-}" ] && { echo "kept: $W" >&2; return; }
  for s in "$IN" "$OUT"; do tmux -S "$s" kill-server 2>/dev/null; done
  rm -rf "$W"
}
trap cleanup EXIT INT TERM
mkdir -p "$W/conf/remote-views/v1.d" "$W/g" "$W/home" "$W/stub"
export HOME="$W/home" FLEET_CONF_DIR="$W/conf" FLEET_STATUS_G="$W/g" FLEET_UI_LANG=zh LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
unset TMUX TMUX_PANE FLEET_HUB_WRITE_CMD FLEET_REMOTE_SAY FLEET_SIDEBAR_TEXT
ME=$(id -un)
US=$'\037'
ti() { tmux -S "$IN" "$@"; }
to() { tmux -S "$OUT" "$@"; }
LOG="$W/calls.log"; : > "$LOG"

# --- the stubs: one line per call, `name|arg|arg|…` ----------------------------------
for s in dash-open-pr.sh fleet-permission.sh fleet-answer.sh fleet-peer-send.sh dash-pin-toggle.sh \
         fleet-reap-policy.sh fleet-worker-stop.sh fleet-sleep.sh fleet-manual-sub.sh dash-migrate.sh \
         fleet-transfer.sh dash-reap.sh dash-rename.sh fleet-sidebar-remote.sh; do
  cat > "$W/stub/$s" <<EOF
#!/bin/bash
{ printf '%s' "$s"; for a in "\$@"; do printf '|%s' "\$a"; done; printf '\n'; } >> "$LOG"
case "$s:\$*" in
  dash-open-pr.sh:*--probe*) printf '#41\n' ;;
  fleet-manual-sub.sh:list*) printf 'account\t5h\t7d\tstate\nacct1\t20%%\t40%%\t可迁入\nacct2\t5%%\t9%%\t可迁入\n' ;;
  dash-rename.sh:*) exec bash "$BIN/dash-rename.sh" "\$@" ;;
  fleet-sidebar-remote.sh:*) exec bash "$BIN/fleet-sidebar-remote.sh" "\$@" ;;
  dash-reap.sh:*) printf 'reaped:clean\n' ;;
esac
exit 0
EOF
done
export FLEET_VIEW_ACT_BIN="$W/stub"
calls() { grep -v -e '--probe' -e '^fleet-manual-sub.sh|list' "$LOG"; }
reset() { : > "$LOG"; }

# --- the fleet, its 看台 and the rows --------------------------------------------------
ti -f /dev/null new-session -d -s fl -x 120 -y 30 -n home "sleep 600" || fail "inner tmux"
W1=$(ti new-window -d -P -F '#{window_id}' -t fl -n alpha "sh -c 'exec cat > \"$W/p1.in\"'")
W2=$(ti new-window -d -P -F '#{window_id}' -t fl -n beta "sh -c 'exec cat > \"$W/p2.in\"'")
W3=$(ti new-window -d -P -F '#{window_id}' -t fl -n gamma "sh -c 'exec cat > \"$W/p3.in\"'")
W4=$(ti new-window -d -P -F '#{window_id}' -t fl -n delta "sh -c 'exec cat > \"$W/p4.in\"'")
W5=$(ti new-window -d -P -F '#{window_id}' -t fl -n eps "sh -c 'exec cat > \"$W/p5.in\"'")
ti set-option -w -t "$W1" @fleet_id f1; ti set-option -w -t "$W2" @fleet_id f2; ti set-option -w -t "$W3" @fleet_id f3
ti set-option -w -t "$W4" @fleet_id f4; ti set-option -w -t "$W5" @fleet_id f5
ti set-option -w -t "$W2" @claude_needs perm; ti set-option -w -t "$W4" @claude_needs ask
ti set-option -w -t "$W3" @wrap_exit_rc 0; ti set-option -w -t "$W5" @worker_lifecycle sleeping
UU=11111111-2222-3333-4444-555555555555; MU=22222222-3333-4444-5555-666666666666
row() { local IFS="$US"; printf '%s\n' "$*"; }
cat > "$W/rows.sh" <<'EOF'
#!/bin/sh
cat "$FLEET_VIEW_ROWS_FILE"
EOF
export FLEET_VIEW_ROWS_CMD="sh '$W/rows.sh'" FLEET_VIEW_ROWS_FILE="$W/rows.txt"
# the 已回收 list's read (issue #3286, fleet-view-selftest.sh J): an empty ledger here
: > "$W/gone.txt"
export FLEET_VIEW_LANDED_CMD="cat '$W/gone.txt'"
{
  row hdr verkyyi/claude-fleet '' 'claude-fleet (5)' ' '
  row "$W1" 'done' ✓ 'alpha' ' ' '' 0 '' '' '#11' open 50% ok 'Alpha 做完了' merged '' '' '' ''
  row "$W2" needs ! 'beta' ' ' '' 0 'perm' '' '#12' — 50% ok 'Beta 要批准' merged '' '' 'Bash rm' ''
  row "$W4" needs ! 'delta' ' ' '' 0 'question' '' '#14' — 50% ok 'Delta 在问' merged '' '' '选哪个？' ''
  row "$W5" sleeping z 'eps' ' ' '' 0 '' '' '#15' — 50% ok 'Eps 睡着' merged '' '' '' ''
  row "wid:$MU/far1" working ⠹ 'far' ' ' '' 0 '' m4 '#13' — · ok 'Far 在 m4' keep '' '' '' ''
  row "wid:$MU/far2" needs ! 'farask' ' ' '' 0 'perm' m4 '#16' — · ok 'Farask 要批准' keep '' '' 'Bash ls' ''
  row "wid:$MU/far3" working ⠹ 'farlost' ' ' '' 0 '' 'm4!' '#17' — · ok 'Farlost 失联' keep '' '' '' ''
  row "wid:$MU/far4" exited x 'fargone' ' ' '' 0 '' m4 '#18' — · ok 'Fargone 停了' keep '' '' '' ''
  row hdr ended '' '▸ Ended (1)' ' '
  row "$W3" exited x 'gamma' ' ' '' 0 '' '' '' — · ok 'Gamma 退出了' merged '' '' '' ''
} > "$W/rows.txt"
ti new-session -d -t fl -s 'fl@view-v1' || fail "no 看台 session"
ti select-window -t "=fl@view-v1:$W1"
printf '%s\tfl\tthin\t%s\t%s\tcur=%s/f1\troute=lan\tdevice=\ttoken=t\tfuid=%s\tnode=nodeA\n' \
  /dev/null "$(date +%s)" "$$" "$UU" "$UU" > "$W/conf/remote-views/v1"
export TMUX="$IN,0,0"
qo() { python3 "$BIN/fleet-quickopen.py" "$@"; }

# --- A: the table against the sidebar menu ---------------------------------------------
letters=$(FLEET_UI_LANG=zh sh "$BIN/fleet-ui-lang.sh" t menu_keys | awk -F '\t' '{ print $1 }')
[ -n "$letters" ] || fail "A: no menu_keys"
built=$(grep -o 'mk [a-z]*' "$BIN/fleet-sidebar-menu.sh" | awk '{ print $2 }' | sort -u)
PYCHK=$(python3 - "$BIN" "$letters" "$built" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fleet_view", sys.argv[1] + "/fleet_view.py")
fv = importlib.util.module_from_spec(spec); spec.loader.exec_module(fv)
bad = []
for a in sys.argv[2].split() + sys.argv[3].split():
    if a in fv.ROWLESS:
        continue
    if a not in fv.SIDEBAR_ACTIONS:
        bad.append("sidebar %s has no action" % a)
    elif fv.SIDEBAR_ACTIONS[a] not in fv.ACTION:
        bad.append("sidebar %s → %s, not in ACTIONS" % (a, fv.SIDEBAR_ACTIONS[a]))
for a in fv.ACTIONS:
    for k in ("id", "label", "when", "local", "far", "ask"):
        if k not in a:
            bad.append("%s lacks %s" % (a.get("id"), k))
print("\n".join(bad))
EOF
)
[ -z "$PYCHK" ] || fail "A: the sidebar menu and ACTIONS differ: $PYCHK"
pass "A  every sidebar menu item is an action here (or row-less, C2 / C7); each action id · label · when · local · far · ask"

# --- B: which actions a row gets -----------------------------------------------------
ids() { qo view-menu --view fl@view-v1 "$1" | awk -F '\t' '{ print $1 }' | tr '\n' ' '; }
m1=$(ids "$W1")
for a in enter shell pr message rename pin reappol stop awake sub agent reap; do
  case " $m1 " in *" $a "*) ;; *) fail "B: done row lacks $a: $m1" ;; esac
done
for a in answer wake resume; do case " $m1 " in *" $a "*) fail "B: done row has $a: $m1" ;; esac; done
qo view-menu --view fl@view-v1 "$W1" | grep -q $'^pr\t打开 PR #41' || fail "B: PR label: $(qo view-menu --view fl@view-v1 "$W1")"
case " $(ids "$W2") " in *" answer "*) ;; *) fail "B: asking row lacks answer" ;; esac
case " $(ids "$W5") " in *" wake "*) ;; *) fail "B: sleeping row lacks wake" ;; esac
case " $(ids "$W5") " in *" stop "*) fail "B: a sleeping row offers stop" ;; esac
m3=$(qo view-menu --view fl@view-v1 "$W3")
grep -q $'^resume\t恢复' <<< "$m3" || fail "B: ended exited row lacks 恢复: $m3"
[ "$(ids "$MU/far1")" = "enter shell message rename pin reappol stop reap " ] || fail "B: another machine's row: $(ids "$MU/far1")"
case " $(ids "$MU/far2") " in *" answer "*) ;; *) fail "B: a far asking row lacks answer: $(ids "$MU/far2")" ;; esac
case " $(ids "$MU/far4") " in *" resume "*) ;; *) fail "B: a far exited row lacks resume: $(ids "$MU/far4")" ;; esac
pass "B  a row's menu: done · asking · sleeping · ended (恢复) · another machine's (its hub writes)"

# --- C: each action, its script, once ---------------------------------------------------
one() {   # <id> <expected line> [view-act args…]
  local id=$1 want=$2; shift 2
  reset
  qo view-act --view fl@view-v1 "$@" >/dev/null 2>"$W/err" || fail "C: $id failed: $(cat "$W/err")"
  got=$(calls)
  [ "$got" = "$want" ] || fail "C: $id ran «${got}», want «${want}»"
}
one pr "dash-open-pr.sh|--wid|$W1" "$W1" pr
one answer "fleet-permission.sh|--allow|$W2|--session|fl|--by|$ME" "$W2" answer --text y
one answer-n "fleet-permission.sh|--deny|$W2|--session|fl|--by|$ME" "$W2" answer --text n
one answer-pick "fleet-answer.sh|--answer|$W4|--session|fl|2" "$W4" answer --text 2
one message "fleet-peer-send.sh|$W1|合并了吗 hello" "$W1" message --text '合并了吗 hello'
one pin "dash-pin-toggle.sh|$W1" "$W1" pin
one reappol "fleet-reap-policy.sh|set|done:2h|--win|$W1|--session|fl" "$W1" reappol --text done:2h
one stop "fleet-worker-stop.sh|fl|fid:f1" "$W1" stop
one wake "fleet-sleep.sh|wake|fl|$W5|--over-cap" "$W5" wake
one awake "fleet-sleep.sh|keep-awake|fl|$W1" "$W1" awake
one sub "dash-migrate.sh|$W1|to|acct2" "$W1" sub --text acct2
one agent "fleet-transfer.sh|--session|fl|--window|$W1|--to|codex" "$W1" agent
one rename "dash-rename.sh|--wid|$W1|新名字" "$W1" rename --text '新名字'
[ "$(ti display-message -p -t "$W1" '#{window_name}')" = '新名字' ] || fail "C: rename did not rename the window"
reset
qo view-act --view fl@view-v1 "$W1" reap >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ -z "$(calls)" ] || fail "C: reap without a yes: rc=$rc ran «$(calls)»"
one reap "dash-reap.sh|$W1|--yes" "$W1" reap --yes
reset
qo view-act --view fl@view-v1 "$W1" wake >/dev/null 2>&1 && fail "C: wake on an awake row ran"
[ -z "$(calls)" ] || fail "C: a refused action ran «$(calls)»"
one resume "" "$W3" resume
sleep 0.3
[ "$(wc -c < "$W/p3.in" | tr -d ' ')" = 1 ] || fail "C: 恢复 did not press ↵ on the page ($(od -c "$W/p3.in" | head -2))"
[ "$(ti display-message -p -t '=fl@view-v1:' '#{window_id}')" = "$W3" ] || fail "C: 恢复 did not go there"
one enter "" "$W2" enter
[ "$(ti display-message -p -t '=fl@view-v1:' '#{window_id}')" = "$W2" ] || fail "C: 进入 did not go there"
one shell "" "$W1" shell
ti list-windows -t fl -F '#{@view_shell}|#{@peer_view}' | grep -q "@$ME:$W1|v1" \
  || fail "C: 在它的目录开 shell made no shell window: $(ti list-windows -t fl -F '#{window_id} #{@view_shell}')"
pass "C  every action runs its script exactly once with the sidebar's arguments; rename renames; reap needs y; 恢复 / 进入 / shell go"

# --- D: the popup on a client -------------------------------------------------------------
ti select-window -t "=fl@view-v1:$W1"
reset
to -f /dev/null new-session -d -s o -x 120 -y 30 \
  "env TMUX='$IN,0,0' ESCDELAY=25 python3 '$BIN/fleet-quickopen.py' --view fl@view-v1; echo POPUP-CLOSED; sleep 600" \
  || fail "D: outer tmux"
screen() { to capture-pane -p -t o; }
waitfor() { local _i; for _i in $(seq 1 40); do screen | grep -qF -- "$1" && return 0; sleep 0.1; done; return 1; }
waitfor 'Tab 操作' || fail "D: the list did not open: $(screen)"
to send-keys -t o Tab
waitfor '回收…' || fail "D: Tab opened no menu: $(screen)"
screen > "$W/menu.txt"
grep -q '─ Alpha 做完了' "$W/menu.txt" || fail "D: the menu's title is not the row: $(cat "$W/menu.txt")"
to send-keys -t o Escape
waitfor 'Tab 操作' || fail "D: Esc did not step back to the list: $(screen)"
to send-keys -t o Escape
waitfor 'POPUP-CLOSED' || fail "D: Esc did not close the list"
[ -z "$(calls)" ] || fail "D: Esc ran «$(calls)»"
to respawn-pane -k -t o "env TMUX='$IN,0,0' ESCDELAY=25 python3 '$BIN/fleet-quickopen.py' --view fl@view-v1; echo POPUP-CLOSED; sleep 600"
waitfor 'Tab 操作' || fail "D: the list did not reopen"
screen > "$W/before.txt"
to send-keys -t o Tab; waitfor '回收…' || fail "D: no menu"
for _ in $(seq 1 20); do to send-keys -t o Down; done
waitfor '▶ 回收…' || fail "D: ↓ did not reach 回收: $(screen)"
to send-keys -t o Enter
waitfor '回收「Alpha 做完了」？(y/n)' || fail "D: 回收 did not ask y/n: $(screen)"
to send-keys -t o n
waitfor 'Tab 操作' || fail "D: n did not return to the list"
[ -z "$(calls)" ] || fail "D: 回收 → n ran «$(calls)»"
to send-keys -t o Tab; waitfor '回收…' || fail "D: no menu (2)"
for _ in $(seq 1 20); do to send-keys -t o Down; done
to send-keys -t o Enter; waitfor '(y/n)' || fail "D: no y/n (2)"
to send-keys -t o y
for _ in $(seq 1 40); do [ -n "$(calls)" ] && break; sleep 0.1; done
[ "$(calls)" = "dash-reap.sh|$W1|--yes" ] || fail "D: 回收 → y ran «$(calls)»"
waitfor '回收：已在后台做' || fail "D: the list does not say the reap is under way: $(screen)"
screen > "$W/after.txt"
reset
to send-keys -t o Tab; waitfor '改名…' || fail "D: no menu (3)"
for _ in $(seq 1 4); do to send-keys -t o Down; done
waitfor '▶ 改名…' || fail "D: ↓4 is not 改名: $(screen)"
to send-keys -t o Enter
waitfor '新名字› 新名字' || fail "D: 改名 did not ask on the bottom line, pre-filled: $(screen)"
to send-keys -t o Escape
waitfor 'Tab 操作' || fail "D: Esc did not cancel the rename"
[ -z "$(calls)" ] || fail "D: a cancelled rename ran «$(calls)»"
# ⌘P's 置顶 (issue #3517): the session in view has its own line, and ⌃T on the lit
# row runs the row's own 置顶 — dash-pin-toggle.sh once, the list stays open
screen | grep -q '📌 置顶当前会话' || fail "D: no 「📌 置顶当前会话」 line: $(screen)"
reset
to send-keys -t o C-t
for _ in $(seq 1 40); do [ -n "$(calls)" ] && break; sleep 0.1; done
[ "$(calls)" = "dash-pin-toggle.sh|$W1" ] || fail "D: ⌃T ran «$(calls)»"
waitfor 'Tab 操作' || fail "D: ⌃T closed the list: $(screen)"
if [ -n "${FLEET_VIEW_ACT_EVIDENCE:-}" ]; then
  { echo '--- 改动后：⌘P 选中「Alpha 做完了」· 回收前'; cat "$W/before.txt"; echo '--- Tab → 回收… → y 之后';
    cat "$W/after.txt"; echo '--- Tab 的菜单'; cat "$W/menu.txt"; } > "$FLEET_VIEW_ACT_EVIDENCE"
fi
pass "D  popup: Tab opens the row's menu, Esc steps back and closes with nothing run; 回收 asks y/n (n nothing, y one dash-reap.sh); 改名 asks on the bottom line; 📌 置顶当前会话 and ⌃T (#3517)"
# --- E: another machine's row --------------------------------------------------------------
# the sidebar's own cache (fleet-sidebar-remote.sh reads $FLEET_C/global, FLEET_C
# under $TMPDIR): the same dir the list reads (FLEET_STATUS_G)
export TMPDIR="$W/t"; G="$TMPDIR/.claude-dash/global"; mkdir -p "$G"
export FLEET_STATUS_G="$G" CCQUOTA_FLEET=1
{ printf '#ts\037%s\n' "$(date +%s)"
  for k in far1:far: far2:farask:perm far3:farlost: far4:fargone:; do
    IFS=: read -r id nm nd <<< "$k"
    printf 'wid:%s/%s\037m4\037\037\037\037\037\037%s\037\037%s\n' "$MU" "$id" "$nm" "$nd"
  done; } > "$G/remote_fl"
date +%s > "$G/hub_ok"
WRITES="$W/writes"; : > "$WRITES"
cat > "$W/hubw.sh" <<'EOF'
printf '%s\t%s\n' "$1" "$2" >> "$WRITES"
if [ -s "$FLEET_CONF_DIR/hub.answer" ]; then cat "$FLEET_CONF_DIR/hub.answer"; exit 0; fi
case "$1" in
  worker_reap) printf '{"operation_id":"op1","status":"succeeded","result":{"token":"reaped:full","exit":0}}\n' ;;
  *) printf '{"operation_id":"op1","status":"succeeded","result":{}}\n' ;;
esac
EOF
export WRITES FLEET_HUB_WRITE_CMD="bash '$W/hubw.sh' \"\$@\""
HS="$W/hubsess.log"; : > "$HS"
printf 'printf "%%s\\n" "$*" >> %q\n' "$HS" > "$W/hubsess.sh"
export FLEET_VIEW_HUBSESS="$W/hubsess.sh"
far() {   # <id> <action> <tool> <json fragment> [view-act args…]
  local id=$1 act=$2 tool=$3 frag=$4; shift 4
  reset; : > "$WRITES"; : > "$HS"
  out=$(qo view-act --view fl@view-v1 "$MU/$id" "$act" "$@" 2>"$W/err") || fail "E: $act failed: $out $(cat "$W/err")"
  [ "$(calls)" = "fleet-sidebar-remote.sh|$act|fl|wid:$MU/$id" ] || fail "E: $act ran «$(calls)»"
  [ "$(grep -c . "$WRITES")" = 1 ] && [ "$(cut -f1 "$WRITES")" = "$tool" ] || fail "E: $act wrote «$(cat "$WRITES")»"
  body=$(cut -f2 "$WRITES")
  case "$body" in *"\"worker_id\":\"$MU/$id\""*) ;; *) fail "E: $act's write names no worker_id: $body" ;; esac
  case "$body" in *"$frag"*) ;; *) fail "E: $act's write lacks $frag: $body" ;; esac
  case "$out" in *m4*) ;; *) fail "E: $act's outcome does not name the machine: $out" ;; esac
  grep -qx -- --refresh "$HS" || fail "E: $act was not followed by a hub --refresh: $(cat "$HS")"
}
far far1 message worker_message '"text":"你好 hi"' --text '你好 hi'
far far1 rename worker_rename '"name":"新名"' --text '新名'
# the new name shows at once (issue #3317), before far1's machine has sent its
# next inventory round the hub — and the hold goes once the hub's row says it
vtext() { qo view-rows --view fl@view-v1 | awk -F '\t' -v t="$1" '$1 == "sess" && $2 == t { print $4 }'; }
[ "$(vtext "$MU/far1")" = '新名' ] || fail "E: a far rename does not show at once: $(vtext "$MU/far1")"
[ -s "$G/view-names.fl" ] || fail "E: no hold written for the far rename"
FLEET_VIEW_NAME_HOLD_SECS=0 qo view-rows --view fl@view-v1 >/dev/null
[ ! -s "$G/view-names.fl" ] || fail "E: a hold past FLEET_VIEW_NAME_HOLD_SECS was kept: $(cat "$G/view-names.fl")"
[ "$(vtext "$MU/far1")" = 'Far 在 m4' ] || fail "E: an expired hold still names the row: $(vtext "$MU/far1")"
qo view-act --view fl@view-v1 "$MU/far1" rename --text '新名' >/dev/null 2>&1 || fail "E: the second far rename failed"
cp "$W/rows.txt" "$W/rows.bak"
sed "s/Far 在 m4/新名/" "$W/rows.bak" > "$W/rows.txt"
[ "$(vtext "$MU/far1")" = '新名' ] || fail "E: the hub's own new name is not shown"
[ ! -s "$G/view-names.fl" ] || fail "E: the hold outlived the hub saying the name: $(cat "$G/view-names.fl")"
mv "$W/rows.bak" "$W/rows.txt"
far far1 reappol worker_reap_policy '"policy":"done:2h"' --text done:2h
# 置顶 (issue #3517): a set on the wire — the opposite of what the cache's field 30 says
far far1 pin worker_pin '"pin":"on"'
awk -F '\037' -v OFS='\037' -v w="wid:$MU/far1" '$1 == w { $30 = 1 } { print }' "$G/remote_fl" > "$G/remote_fl.new" \
  && mv "$G/remote_fl.new" "$G/remote_fl"
far far1 pin worker_pin '"pin":"off"'
far far1 stop worker_stop ''
far far4 resume worker_resume ''
far far2 answer worker_answer '"answer":"yes"' --text y
far far1 reap worker_reap '' --yes
# the hub says no: its words, verbatim, and a non-zero exit
printf '{"error":{"code":"FORBIDDEN","message":"no grant for this login"}}\n' > "$FLEET_CONF_DIR/hub.answer"
reset
out=$(qo view-act --view fl@view-v1 "$MU/far1" stop 2>&1) && fail "E: a refused stop exited 0: $out"
case "$out" in *"FORBIDDEN"*"no grant for this login"*) ;; *) fail "E: the refusal is not shown verbatim: $out" ;; esac
rm -f "$FLEET_CONF_DIR/hub.answer"
# a lost row: nothing goes out, and it says so
reset; : > "$WRITES"
out=$(qo view-act --view fl@view-v1 "$MU/far3" reap --yes 2>&1) && fail "E: a lost row's reap exited 0"
[ -z "$(calls)" ] && [ ! -s "$WRITES" ] || fail "E: a lost row sent «$(calls) $(cat "$WRITES")»"
case "$out" in *"m4 失联，做不了"*) ;; *) fail "E: a lost row does not say why: $out" ;; esac
# the popup: Tab → 停 on the far row, off the screen's thread, the outcome on the bottom line
reset; : > "$WRITES"
# the pane is the outer server's: hand it E's environment (the hub seams, the cache)
penv=$(printf ' %q' "TMPDIR=$TMPDIR" "FLEET_STATUS_G=$G" "CCQUOTA_FLEET=1" "WRITES=$WRITES" \
       "FLEET_HUB_WRITE_CMD=$FLEET_HUB_WRITE_CMD" "FLEET_VIEW_HUBSESS=$FLEET_VIEW_HUBSESS")
to respawn-pane -k -t o "env TMUX='$IN,0,0' ESCDELAY=25$penv python3 '$BIN/fleet-quickopen.py' --view fl@view-v1; echo POPUP-CLOSED; sleep 600"
waitfor 'Tab 操作' || fail "E: the list did not reopen: $(screen)"
to send-keys -t o -l 'Far 在'
waitfor '› Far 在' || fail "E: typing did not filter: $(screen)"
to send-keys -t o Tab; waitfor '─ Far 在 m4' || fail "E: Tab on the far row: $(screen)"
for _ in $(seq 1 6); do to send-keys -t o Down; done
waitfor '▶ 停下' || fail "E: ↓6 is not 停下 (置顶 sits above it, #3517): $(screen)"
to send-keys -t o Enter
waitfor '（在 m4）：已完成' || fail "E: the popup does not say the stop landed: $(screen)"
[ "$(calls)" = "fleet-sidebar-remote.sh|stop|fl|wid:$MU/far1" ] || fail "E: the popup's stop ran «$(calls)»"
pass "E  another machine's row: each far action one sidebar-remote call + one hub write (worker_id, answer, pin on/off), the machine named, a refusal verbatim, a lost row nothing, a --refresh after; the popup's 停 lands off-thread"
echo "PASS fleet-view-actions-selftest"
