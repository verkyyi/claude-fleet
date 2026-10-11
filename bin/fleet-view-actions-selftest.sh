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
#      machine's row only 进入
#   C  view-act, item by item: each calls its script exactly once with the
#      sidebar's arguments; 改名 really renames the window (dash-rename.sh);
#      回收 without a yes does nothing (exit 3); 恢复 presses ↵ on the wrapper's
#      page and goes there; 进入 changes the 看台's window
#   D  the popup on a client: ⌘P's list, Tab opens the row's menu, Esc steps back
#      and Esc again closes with NOTHING run; Tab → 回收 → n does nothing, → y
#      runs dash-reap.sh once; 改名 asks on the bottom line, Esc cancels it
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
unset TMUX TMUX_PANE
ME=$(id -un)
US=$'\037'
ti() { tmux -S "$IN" "$@"; }
to() { tmux -S "$OUT" "$@"; }
LOG="$W/calls.log"; : > "$LOG"

# --- the stubs: one line per call, `name|arg|arg|…` ----------------------------------
for s in dash-open-pr.sh fleet-permission.sh fleet-answer.sh fleet-peer-send.sh dash-pin-toggle.sh \
         fleet-reap-policy.sh fleet-worker-stop.sh fleet-sleep.sh fleet-manual-sub.sh dash-migrate.sh \
         fleet-transfer.sh dash-reap.sh dash-rename.sh; do
  cat > "$W/stub/$s" <<EOF
#!/bin/bash
{ printf '%s' "$s"; for a in "\$@"; do printf '|%s' "\$a"; done; printf '\n'; } >> "$LOG"
case "$s:\$*" in
  dash-open-pr.sh:*--probe*) printf '#41\n' ;;
  fleet-manual-sub.sh:list*) printf 'account\t5h\t7d\tstate\nacct1\t20%%\t40%%\t可迁入\nacct2\t5%%\t9%%\t可迁入\n' ;;
  dash-rename.sh:*) exec bash "$BIN/dash-rename.sh" "\$@" ;;
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
{
  row hdr verkyyi/claude-fleet '' 'claude-fleet (5)' ' '
  row "$W1" 'done' ✓ 'alpha' ' ' '' 0 '' '' '#11' open 50% ok 'Alpha 做完了' merged '' '' '' ''
  row "$W2" needs ! 'beta' ' ' '' 0 'perm' '' '#12' — 50% ok 'Beta 要批准' merged '' '' 'Bash rm' ''
  row "$W4" needs ! 'delta' ' ' '' 0 'question' '' '#14' — 50% ok 'Delta 在问' merged '' '' '选哪个？' ''
  row "$W5" sleeping z 'eps' ' ' '' 0 '' '' '#15' — 50% ok 'Eps 睡着' merged '' '' '' ''
  row "wid:$MU/far1" working ⠹ 'far' ' ' '' 0 '' m4 '#13' — · ok 'Far 在 m4' keep '' '' '' ''
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
[ "$(ids "$MU/far1")" = "enter shell " ] || fail "B: another machine's row: $(ids "$MU/far1")"
pass "B  a row's menu: done · asking · sleeping · ended (恢复) · another machine's (进入 + shell)"

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
if [ -n "${FLEET_VIEW_ACT_EVIDENCE:-}" ]; then
  { echo '--- 改动后：⌘P 选中「Alpha 做完了」· 回收前'; cat "$W/before.txt"; echo '--- Tab → 回收… → y 之后';
    cat "$W/after.txt"; echo '--- Tab 的菜单'; cat "$W/menu.txt"; } > "$FLEET_VIEW_ACT_EVIDENCE"
fi
pass "D  popup: Tab opens the row's menu, Esc steps back and closes with nothing run; 回收 asks y/n (n nothing, y one dash-reap.sh); 改名 asks on the bottom line"
echo "PASS fleet-view-actions-selftest"
