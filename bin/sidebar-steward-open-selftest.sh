#!/bin/bash
# sidebar-steward-open-selftest.sh — the sidebar's 停放 / 待你动手 rows open
# (issue #2913). Pinned here:
#   A. THE ROAD — fleet_steward.py park_cell / fleet_followup.py todo_cell (the
#      @orch_park_list / @orch_todo_list cells) → fleet-control-read.sh's
#      `orchparkl=` / `orchtodol=` tags, read by fleet_hub_common.py as
#      orch_park_list / orch_todo_list → orch_<sess>'s `parkl=` / `todol=`, which
#      fleet-sidebar-steward.sh reads back. Empty ⇒ "".
#   B. NO ROWS (issue #3119) — the sidebar draws no 停放 / 待你动手 row and no
#      item under one, whatever orch_<sess> carries: no session is special, and
#      the steward's lists are the steward plugin's (C4).
#   C. THE MENU — fleet-sidebar-steward.sh menu --print: a parked item offers
#      立刻唤醒 + its issue, a 待你动手 item 勾掉 + its batch + the desk ticket.
#   D. THE ACTIONS — wake / tick: in the shell they go to the steward as ONE
#      message naming the command (fleet-sidebar-remote.sh message); on the
#      steward's machine they run bin/fleet-park.sh / fleet-steward-tick.sh there;
#      no steward anywhere ⇒ nothing sent.
#   E. TODO-DONE — fleet-steward-tick.sh todo-done --id ticks the item as the
#      person's: done, by person, its write-back queued, the desk body ticked.
set -uo pipefail
export FLEET_SIDEBAR_NODE=1
BIN="$(cd "$(dirname "$0")" && pwd)"
W=$(mktemp -d "${TMPDIR:-/tmp}/sso.XXXXXX")
trap 'rm -rf "$W"' EXIT
FAILS=0
fail() { printf 'selftest FAIL: %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }
G="$W/g"; mkdir -p "$G" "$W/conf/global"

# ── A. the node's half: the two cells → a real fleet-control-read.sh over an
# isolated server (its orchestrator window carries them) → the inventory row ──
FLEET_CONF_DIR="$W/conf" python3 - "$BIN" "$W" <<'PY'
import sys, time
sys.path.insert(0, sys.argv[1])
import fleet_steward as fs
import fleet_followup as fu
now = int(time.time())
park = [{"ref": "o/r#12", "key": "issue-12", "wait": ["reply:o/r#12"], "at": now - 7200},
        {"ref": "o/r#40", "key": "", "wait": ["pr:o/r#41:merged"], "at": now - 600}]
st = type("S", (), {"d": {"todo": {"items": {
    "fu-1": {"id": "fu-1", "kind": "human", "what": "批末在 MacBook 上整套重走一遍", "due": "2026-10-12",
             "sources": [{"epic": "o/r#2756"}], "state": "open"},
    "fu-2": {"id": "fu-2", "kind": "stable", "what": "挪稳定版", "sources": [{"epic": "o/r#2792"}], "state": "done"}},
    "desk_url": "https://github.com/o/r/issues/2863"}}})()
open(sys.argv[2] + "/pc", "w").write(fs.park_cell(park))
open(sys.argv[2] + "/tc", "w").write(fu.todo_cell(fs, fu.todo(st)))
PY
REAL_TMUX=$(command -v tmux 2>/dev/null)
: > "$W/inv"
if [ -n "$REAL_TMUX" ]; then
  jt="$W/jt"; js="sso$$"; mkdir -p "$jt" "$W/jconf/fleets/$js"
  printf 'FLEET_REPO=o/r\n' > "$W/jconf/fleets/$js/conf"
  jq() { TMUX_TMPDIR="$jt" "$REAL_TMUX" -L "$js" "$@"; }
  jq -f /dev/null new-session -d -s "$js" -n home 'sleep 600'
  jq new-window -d -t "=$js:" -n orchestrator 'sleep 600'
  jq set-option -w -t "=$js:orchestrator" @fleet_role orchestrator
  jq set-option -w -t "=$js:orchestrator" @norepo 1
  jinv() { env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$jt" TMPDIR="$W" FLEET_CONF_DIR="$W/jconf" \
             bash "$BIN/fleet-control-read.sh" workers "$js" 2>/dev/null | awk -F'\t' '$10 == "orchestrator"'; }
  jinv > "$W/inv0"
  jq set-option -w -t "=$js:orchestrator" @orch_park 2
  jq set-option -w -t "=$js:orchestrator" @orch_page 'https://p.example/d/'
  jq set-option -w -t "=$js:orchestrator" @orch_park_list "$(cat "$W/pc")"
  jq set-option -w -t "=$js:orchestrator" @orch_todo_list "$(cat "$W/tc")"
  jinv > "$W/inv"
  [ -s "$W/inv" ] || fail "A the inventory has no orchestrator row"
  jq set-option -w -t "=$js:orchestrator" @orch_todo_list 'not/a;cell'
  jinv > "$W/invbad"
  jq kill-server 2>/dev/null
  case "$(cat "$W/inv0")" in *orchparkl=*|*orchtodol=*) fail "A no list, yet a tag: $(cat "$W/inv0")" ;; esac
  [ "$(cat "$W/inv")" = "$(cat "$W/inv0")"$'\t'"orchpark=2"$'\t'"orchpage=https://p.example/d/"$'\t'"orchparkl=$(cat "$W/pc")"$'\t'"orchtodol=$(cat "$W/tc")" ] \
    || fail "A the inventory's tags: $(cat "$W/inv")"
  case "$(cat "$W/invbad")" in *orchtodol=*) fail "A a bad cell rode the inventory" ;; esac
else
  printf 'selftest: tmux not installed — the inventory leg of A skipped\n' >&2
fi

# ── A + B (python) ───────────────────────────────────────────────────────────
FLEET_STATUS_G="$G" FLEET_CONF_DIR="$W/conf" FLEET_UI_LANG=zh python3 - "$BIN" "$G" "$W" <<'PY' || FAILS=$((FAILS + 1))
import importlib.util, sys, time
from pathlib import Path
real_bin, G, W = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
sys.path.insert(0, str(real_bin))
import fleet_steward as fs
import fleet_hub_common as hc
spec = importlib.util.spec_from_file_location('sidebar', real_bin / 'fleet-sidebar.py')
sb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sb)
N = [0]


def check(what, ok, got=None):
    N[0] += 1
    if not ok:
        print('selftest FAIL: %s%s' % (what, '' if got is None else ' — got %r' % (got,)), file=sys.stderr)
        sys.exit(1)


now = int(time.time())
pc, tc = open(W + '/pc').read(), open(W + '/tc').read()
check('A each cell is one token', pc and tc and all(c.isalnum() or c in '-_' for c in pc + tc), (pc, tc))
check('A empty ⇒ ""', fs.park_cell([]) == '' and fs.list_cell({"i": []}) == '')
inv = open(W + '/inv').read().rstrip('\n')
if inv:
    r = hc.inventory_row(inv.split('\t'))
    extra = r[1] if r else {}
    check('A the hub parser keeps both cells', extra.get('orch_park_list') == pc and
          extra.get('orch_todo_list') == tc and extra.get('orch_page') == 'https://p.example/d/' and
          extra.get('orch_park') == 2, extra)
bad = open(W + '/invbad').read().rstrip('\n') if Path(W + '/invbad').exists() else ''
if bad:
    check('A …and drops nothing else when a cell is bad', 'orch_todo_list' not in hc.inventory_row(bad.split('\t'))[1])
line = ['fleet/abc', 'm5', 'online', 'working', '', '', '', 'park=2', 'todo=1', 'page=https://p.example/d/',
        'parkl=' + pc, 'todol=' + tc]

# ── B ──
_st = sb.STAGE
sb.STAGE = '1'
with open(G + '/orch_fleet', 'w', encoding='utf-8') as f:
    f.write('\x1f'.join(line) + '\n')
r1 = ['@1', 'working', '*', 'one', ' ', '', '0'] + [''] * (sb.ROW_FIELDS - 7)
check('B no 停放 / 待你动手 row, no item (issue #3119)', sb.with_portal([r1], None, 'fleet') == [r1],
      sb.with_portal([r1], None, 'fleet'))
check('B …and no reader left for them', not any(hasattr(sb, n) for n in ('steward_rows', 'steward_items', 'orch_list',
                                                                        'orch_counts', 'open_steward_menu')))
sb.STAGE = _st
print('selftest OK: A+B %d checks' % N[0])
PY

# the orch line C and D read (fleet-hub-sessions.sh's shape)
FLEET_CONF_DIR="$W/conf" python3 - "$BIN" "$G" <<'PY'
import sys, time
sys.path.insert(0, sys.argv[1])
import fleet_steward as fs
now = int(time.time())
pc = fs.park_cell([{"ref": "o/r#12", "key": "issue-12", "wait": ["reply:o/r#12"], "at": now - 60}])
tc = fs.list_cell({"u": "https://github.com/o/r/issues/2863",
                   "i": [{"id": "fu-1", "w": "人做：重走一遍", "s": "o/r#2756", "d": "2026-10-12"}]})
open(sys.argv[2] + "/orch_fleet", "w").write("\x1f".join(
    ["fleet/abc", "m5", "online", "working", "", "", "", "park=1", "todo=3", "page=https://p.example/d/",
     "parkl=" + pc, "todol=" + tc]) + "\n")
PY

# ── C. the menu ──────────────────────────────────────────────────────────────
SB() { FLEET_STATUS_G="$G" FLEET_UI_LANG=zh FLEET_CONF_DIR="$W/conf" bash "$1/fleet-sidebar-steward.sh" "${@:2}" 2>&1; }
m=$(SB "$BIN" menu fleet 'stewitem:park:o/r#12' --print)
case "$m" in *"title	o/r#12 · issue-12"*) ;; *) fail "C park menu title: $m" ;; esac
case "$m" in *"w	立刻唤醒	run-shell -b"*"fleet-sidebar-steward.sh"*"wake "*"fleet"*"o/r#12"*) ;; *) fail "C park menu wake: $m" ;; esac
case "$m" in *"o	打开 #12	"*"https://github.com/o/r/issues/12"*) ;; *) fail "C park menu issue: $m" ;; esac
m=$(SB "$BIN" menu fleet 'stewitem:todo:fu-1' --print)
case "$m" in *"x	勾掉"*"fleet-sidebar-steward.sh"*"tick "*"fleet"*"fu-1"*) ;; *) fail "C todo menu tick: $m" ;; esac
case "$m" in *"o	打开 #2756	"*"/o/r/issues/2756"*) ;; *) fail "C todo menu source: $m" ;; esac
case "$m" in *"d	打开待办单	"*"/o/r/issues/2863"*) ;; *) fail "C todo menu desk: $m" ;; esac
[ -z "$(SB "$BIN" menu fleet 'stewitem:todo:fu-9' --print)" ] || fail "C an item not on the list opens no menu"
m=$(SB "$BIN" menu fleet 'stewitem:more:todo' --print)
case "$m" in *"p.example/d/"*) ;; *) fail "C 还有 N 个 opens the steward page: $m" ;; esac

# ── D. the actions, on a sandbox bin with stub scripts ──────────────────────
SBX="$W/bin"; mkdir -p "$SBX"
for f in fleet-sidebar-steward.sh fleet-lib.sh fleet-ui-lang.sh fleet-lang.sh fleet-status-lib.sh fleet-trace-lib.sh; do
  [ -e "$BIN/$f" ] && ln -s "$BIN/$f" "$SBX/$f"
done
for f in "$BIN"/*lib*.sh; do [ -e "$SBX/${f##*/}" ] || ln -s "$f" "$SBX/${f##*/}"; done
cat > "$SBX/fleet-sidebar-remote.sh" <<EOF
#!/bin/bash
printf '%s|%s|%s\n' "\$1" "\$3" "\${FLEET_SIDEBAR_TEXT:-}" >> "$W/sent"
EOF
cat > "$SBX/fleet-park.sh" <<EOF
#!/bin/bash
printf 'park %s\n' "\$*" >> "$W/ran"
EOF
cat > "$SBX/fleet-steward-tick.sh" <<EOF
#!/bin/bash
printf 'tick %s\n' "\$*" >> "$W/ran"
EOF
: > "$SBX/fleet_steward.py"
FLEET_SHELL=1 SB "$SBX" wake fleet 'o/r#12' >/dev/null
[ ! -s "$W/sent" ] || fail "D no steward session: something was sent ($(cat "$W/sent"))"
printf 'fleet/stew-1\n' > "$G/steward_all_fleet"
FLEET_SHELL=1 SB "$SBX" wake fleet 'o/r#12' >/dev/null
FLEET_SHELL=1 SB "$SBX" tick fleet fu-1 >/dev/null
s=$(cat "$W/sent" 2>/dev/null)
case "$s" in *"message|wid:fleet/stew-1|[sidebar] 立刻唤醒 o/r#12 — please run: ~/.claude/fleet/bin/fleet-park.sh 'wake' 'o/r#12'"*) ;;
  *) fail "D shell wake → one message to the steward: $s" ;; esac
case "$s" in *"[sidebar] 勾掉"*"fu-1 — please run: ~/.claude/fleet/bin/fleet-steward-tick.sh 'todo-done' '--id' 'fu-1'"*) ;;
  *) fail "D shell tick → one message to the steward: $s" ;; esac
[ "$(wc -l < "$W/sent" | tr -d ' ')" = 2 ] || fail "D one message each: $s"
[ ! -s "$W/ran" ] || fail "D the shell ran a node script: $(cat "$W/ran")"
FLEET_SIDEBAR_STEWARD_LOCAL=1 SB "$SBX" wake fleet 'o/r#12' >/dev/null
FLEET_SIDEBAR_STEWARD_LOCAL=1 SB "$SBX" tick fleet fu-1 >/dev/null
r=$(cat "$W/ran" 2>/dev/null)
[ "$r" = "park wake o/r#12
tick todo-done --id fu-1" ] || fail "D the steward's machine runs them here: $r"
[ "$(wc -l < "$W/sent" | tr -d ' ')" = 2 ] || fail "D …and sends nothing"
SB "$SBX" tick fleet 'fu;1' >/dev/null; [ "$(wc -l < "$W/ran" | tr -d ' ')" = 2 ] || fail "D a bad id runs nothing"

# ── E. todo-done ─────────────────────────────────────────────────────────────
cat > "$W/conf/global/steward.state.json" <<'EOF'
{"v": 1, "todo": {"items": {"fu-1": {"id": "fu-1", "kind": "human", "what": "重走一遍", "due": "2026-10-12",
  "key": "k1", "sources": [{"epic": "o/r#2756"}], "state": "open"}}, "open": {"k1": "fu-1"},
  "desk": "gh:o/r#2863", "desk_url": "https://github.com/o/r/issues/2863"}}
EOF
E() { FLEET_CONF_DIR="$W/conf" FLEET_STEWARD_STAMP_TODO_CMD=true FLEET_STEWARD_WINDOWS_CMD=true FLEET_UI_LANG=zh \
      python3 "$BIN/fleet_steward.py" todo-done --session fleet "$@" 2>&1; }
o=$(E --id fu-1); [ "$o" = "ticked fu-1" ] || fail "E todo-done: $o"
FLEET_CONF_DIR="$W/conf" FLEET_UI_LANG=zh python3 - "$BIN" "$W/conf/global/steward.state.json" <<'PY' || FAILS=$((FAILS + 1))
import json, sys
sys.path.insert(0, sys.argv[1])
import fleet_steward as fs
import fleet_followup as fu
d = json.load(open(sys.argv[2]))
i = d["todo"]["items"]["fu-1"]
ok = i["state"] == "done" and i["by"] == "person" and i["writeback"] == ["o/r#2756"] and "k1" not in d["todo"]["open"]
body = fu.render(fs, d["todo"])
if not ok or "- [x]" not in body:
    print("selftest FAIL: E the item is not the person's done: %r\n%s" % (i, body), file=sys.stderr)
    sys.exit(1)
PY
o=$(E --id fu-1); [ "$o" = "already done" ] || fail "E a second tick: $o"
E --id fu-9 >/dev/null; [ $? = 1 ] || fail "E an unknown id is rc 1"

[ "$FAILS" = 0 ] || exit 1
echo "selftest OK: sidebar-steward-open"
