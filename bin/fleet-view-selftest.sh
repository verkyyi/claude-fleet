#!/bin/bash
# fleet-view-selftest.sh — the 看台's keys and switcher (issue #3000, EPIC #2999 C2).
#
# Isolated sockets only: an INNER server stands for the home machine (a fleet
# session `fl` + a 看台 `fl@view-v1` grouped onto it, key-table fleet-view, as
# fleet-remote-view.sh attach --thin makes one), an OUTER server stands for the
# person's terminal — its panes run `tmux attach` to the inner one, so a byte sent
# into an outer pane is a key typed on the client, and capture-pane of the outer
# pane is what the person sees (the popup included).
#
#   A  conf/tmux-view.conf: user-keys 920..932; root and prefix exactly tmux's;
#      fleet-view = root copied (the mouse) + ⌘↓ ⌘↑ ⌘[ ⌘] ⌘P ⌘K off the switch
#      table (dash-keymap.sh); fleet-view-pfx = ⌃] then the table's prefix letter;
#      sourcing twice leaves the same tables
#   B  ⌘P (`ESC[927~`) in the 看台 opens the list — grouped by (machine, login),
#      this one first, 停放 · 待你动手 · 已结束 under them, no `merged` / `done:2h` /
#      `⇢cla` / bare `!` — and in a session attached directly it does nothing
#      (no popup, no byte reaches the pane)
#   C  ↵ on a row here: the 看台's current window changes (select-window), with no
#      whole-screen clear on the client; one view-switch.ndjson line (method ·
#      ms); the 看台's mouse table equals root's
#   D  go to another machine's / login's session: rc 3, 「这台还没接上」, nothing
#      changed, logged far-none
#   E  ⌘↓ / ⌘↑ walk the list's order, ⌘[ / ⌘] the history; a session that is
#      not a 看台 keeps root (its key-table untouched)
#   F  the old client's quickopen is untouched by --view (do <verb> alone still
#      hands the verb to the list)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }
command -v tmux >/dev/null 2>&1 || { echo "SKIP: no tmux"; exit 0; }
W=$(mktemp -d "${TMPDIR:-/tmp}/fview.XXXXXX") || exit 1
IN="$W/in.sock"; OUT="$W/out.sock"; STOCK="$W/stock.sock"
cleanup() {
  [ -n "${FLEET_VIEW_KEEP:-}" ] && { echo "kept: $W" >&2; return; }
  for s in "$IN" "$OUT" "$STOCK"; do tmux -S "$s" kill-server 2>/dev/null; done
  rm -rf "$W"
}
trap cleanup EXIT INT TERM
mkdir -p "$W/conf/remote-views/v1.d" "$W/g" "$W/home"
export HOME="$W/home" FLEET_CONF_DIR="$W/conf" FLEET_STATUS_G="$W/g" FLEET_UI_LANG=zh LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
unset TMUX TMUX_PANE
ME=$(id -un)
US=$'\037'
ti() { tmux -S "$IN" "$@"; }
to() { tmux -S "$OUT" "$@"; }

# --- A: the tables ---------------------------------------------------------------
tmux -S "$STOCK" -f /dev/null new-session -d -s k -x 100 -y 30 'sleep 600' || fail "A: stock tmux"
tmux -S "$STOCK" list-keys > "$W/stock.keys"
norm() { awk '{ $1 = $1; print }'; }
# The rows the 看台 lists (tmux-dashboard-rows.sh --sidebar's shape, 19 fields),
# through the producer seam: two here, one on m4, one of another login here, one
# ended. Window ids are filled in once the windows exist.
cat > "$W/rows.sh" <<'EOF'
#!/bin/sh
cat "$FLEET_VIEW_ROWS_FILE"
EOF
export FLEET_VIEW_ROWS_CMD="sh '$W/rows.sh'" FLEET_VIEW_ROWS_FILE="$W/rows.txt"
ti -f /dev/null new-session -d -s fl -x 120 -y 30 -n orch "sh -c 'echo ORCH; exec cat > \"$W/pane0.in\"'" || fail "A: inner tmux"
ti source-file "$ROOT/conf/tmux-view.conf" 2>"$W/src.err" || fail "A: tmux-view.conf did not source: $(cat "$W/src.err")"
for c in 920 921 922 923 924 925 926 927 928 929 930 931 932; do
  ti show-options -s user-keys | grep -Fq "user-keys[$c] \\033[$c~" || fail "A: user-keys[$c] not set"
done
ti list-keys -T root | norm > "$W/root.now"; grep -- ' -T root ' "$W/stock.keys" | norm > "$W/root.stock"
diff -q "$W/root.now" "$W/root.stock" >/dev/null || fail "A: root differs from tmux's: $(diff "$W/root.stock" "$W/root.now" | head -5)"
ti list-keys -T prefix | norm > "$W/pfx.now"; grep -- ' -T prefix ' "$W/stock.keys" | norm > "$W/pfx.stock"
diff -q "$W/pfx.now" "$W/pfx.stock" >/dev/null || fail "A: prefix differs from tmux's"
ti list-keys -T fleet-view | norm > "$W/fv.1"
copy=$(grep -v -E ' User9[0-9][0-9] | C-\] ' "$W/fv.1" | sed 's/ -T fleet-view / -T root /')
[ "$copy" = "$(cat "$W/root.now")" ] || fail "A: fleet-view's copy is not root: $(diff <(printf '%s\n' "$copy") "$W/root.now" | head -5)"
table=$(bash "$BIN/dash-keymap.sh" --panel switch list)
for a in next prev back fwd quickopen switcher; do
  code=$(awk -v a="$a" '$1 == a { print $4 }' <<< "$table"); letter=$(awk -v a="$a" '$1 == a { print $5 }' <<< "$table")
  grep -q " -T fleet-view User$code " "$W/fv.1" || fail "A: $a (User$code) is not bound in fleet-view"
  ti list-keys -T fleet-view-pfx | norm | grep -q -- "-T fleet-view-pfx \\\\\?$letter " || fail "A: ⌃] $letter ($a) is not bound in fleet-view-pfx"
done
for a in zoom new fold quit dispatch; do
  code=$(awk -v a="$a" '$1 == a { print $4 }' <<< "$table")
  grep -q " -T fleet-view User$code " "$W/fv.1" && fail "A: $a (User$code) is bound — it is C7's"
done
grep -q ' -T fleet-view C-\] switch-client -T fleet-view-pfx' "$W/fv.1" || fail "A: ⌃] does not enter fleet-view-pfx"
grep -E ' User9[0-9][0-9] | C-\] ' "$W/fv.1" | grep -Eq 'kill-|respawn-|rename-session' \
  && fail "A: a 看台 key deletes, respawns or renames something"
ti source-file "$ROOT/conf/tmux-view.conf" || fail "A: second source"
ti list-keys -T fleet-view | norm > "$W/fv.2"
diff -q "$W/fv.1" "$W/fv.2" >/dev/null || fail "A: sourcing twice changed fleet-view"
pass "A  tables: root/prefix as tmux ships them, fleet-view = root + the 看台's keys, ⌃] prefix, idempotent"

# --- the fleet, the 看台, the client ---------------------------------------------------
W1=$(ti new-window -d -P -F '#{window_id}' -t fl -n alpha "sh -c 'echo ALPHA; exec cat > \"$W/pane1.in\"'")
W2=$(ti new-window -d -P -F '#{window_id}' -t fl -n beta "sh -c 'echo BETA; exec cat > \"$W/pane2.in\"'")
W0=$(ti display-message -p -t 'fl:orch' '#{window_id}')
ti set-option -w -t "$W0" @fleet_role orchestrator; ti set-option -w -t "$W1" @fleet_id f1; ti set-option -w -t "$W2" @fleet_id f2
UU=11111111-2222-3333-4444-555555555555; MU=22222222-3333-4444-5555-666666666666; OU=99999999-8888-7777-6666-555555555555
printf '%s\t%s\n' "$OU" other > "$W/g/fleet_logins"
row() { local IFS="$US"; printf '%s\n' "$*"; }
{
  row hdr verkyyi/claude-fleet '' 'claude-fleet (4)' ' '
  row "$W1" working ⠹ 'alpha短名 ⇢cla' ' ' '' 0 '' '' '#11' — 50% ok 'Alpha 的完整标题很长很长' merged '' '' '' ''
  row "$W2" needs ! 'beta' ' ' '' 0 '' '' '#12' — 50% ok 'Beta 在问你' 'done:2h' '' '' '' ''
  row "wid:$MU/far1" idle · 'gamma' ' ' '' 0 '' m4 '#13' — · ok 'Gamma 在 m4' keep '' '' '' ''
  row "wid:$OU/oth1" working ⠹ 'delta' ' ' '' 0 '' nodeA '#14' — · ok 'Delta 另一个登录' merged '' '' '' ''
  row hdr ended '' '▸ Ended (1)' ' '
  row "$W0" 'done' ✓ 'old' ' ' '' 0 '' '' '#9' merged · ok 'Old 做完的' merged '' '' '' ''
} > "$W/rows.txt"
pl=$(printf '{"i":[{"r":"o/r#21","k":"epsilon","w":"answer:o/r#21","a":%d}]}' "$(( $(date +%s) - 7200 ))" | base64 | tr '+/' '-_' | tr -d '=\n')
printf '%s\n' "x${US}nodeA${US}online${US}looping${US}${US}${US}0${US}park=1${US}parkl=$pl" > "$W/g/orch_fl"
ti new-session -d -t fl -s 'fl@view-v1' || fail "B: no 看台 session"
ti set-option -t 'fl@view-v1' key-table fleet-view
ti select-window -t "=fl@view-v1:$W1"
printf '%s\tfl\tthin\t%s\t%s\tcur=%s/f1\troute=lan\tdevice=\ttoken=t\tfuid=%s\tnode=nodeA\n' \
  /dev/null "$(date +%s)" "$$" "$UU" "$UU" > "$W/conf/remote-views/v1"
to -f /dev/null new-session -d -s o -x 120 -y 32 -n view "TMUX= tmux -S '$IN' attach -t 'fl@view-v1'" || fail "B: outer tmux"
to new-window -d -t o -n direct "TMUX= tmux -S '$IN' attach -t fl"
sleep 1
[ "$(ti list-clients | wc -l | tr -d ' ')" = 2 ] || fail "B: the two clients did not attach: $(ti list-clients)"

# --- B: ⌘P ---------------------------------------------------------------------------
to send-keys -t o:direct -H 1b 5b 39 32 37 7e
sleep 1
to capture-pane -p -t o:direct > "$W/direct.txt"
grep -q '这台' "$W/direct.txt" && fail "B: ⌘P opened a list in a session attached directly"
[ -s "$W/pane0.in" ] && fail "B: ⌘P's bytes reached the pane in a session attached directly: $(od -c "$W/pane0.in" | head -2)"
to send-keys -t o:view -H 1b 5b 39 32 37 7e
ok=''; for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 0.5; to capture-pane -p -t o:view > "$W/popup.txt"; grep -q "nodeA · ${ME}（这台）" "$W/popup.txt" && { ok=1; break; }
done
[ -n "$ok" ] || fail "B: ⌘P in the 看台 opened no list: $(cat "$W/popup.txt")"
for want in '新任务（编排）' "nodeA · ${ME}（这台）" '─ m4 ' "nodeA · other" 'Alpha 的完整标题很长很长' '在问你' '在干活' '停放 1 个' '已结束 1 个'; do
  grep -qF "$want" "$W/popup.txt" || fail "B: the list lacks 「${want}」: $(cat "$W/popup.txt")"
done
for bad in 'merged' 'done:2h' '⇢' ' ! '; do
  grep -qF -- "$bad" "$W/popup.txt" && fail "B: the list still says 「${bad}」: $(grep -F -- "$bad" "$W/popup.txt")"
done
here=$(grep -n "（这台）" "$W/popup.txt" | head -1 | cut -d: -f1); far=$(grep -n '─ m4 ' "$W/popup.txt" | head -1 | cut -d: -f1)
[ "$here" -lt "$far" ] || fail "B: this machine's group is not first"
[ -n "${FLEET_VIEW_EVIDENCE:-}" ] && cp "$W/popup.txt" "$FLEET_VIEW_EVIDENCE"
pass "B  ⌘P: the list in the 看台 (grouped, words, sections), nothing in a direct attach"

# --- C: ↵ on beta, here ------------------------------------------------------------------
to pipe-pane -o -t o:view "cat > '$W/client.bytes'"
sleep 0.3
to send-keys -t o:view -l beta; sleep 0.4; to send-keys -t o:view Enter
for _ in 1 2 3 4 5 6 7 8; do sleep 0.3; [ "$(ti display-message -p -t 'fl@view-v1:' '#{window_id}')" = "$W2" ] && break; done
[ "$(ti display-message -p -t 'fl@view-v1:' '#{window_id}')" = "$W2" ] || fail "C: ↵ on beta did not switch the 看台 (now $(ti display-message -p -t 'fl@view-v1:' '#{window_id}'))"
[ "$(ti display-message -p -t 'fl:' '#{window_id}')" = "$W0" ] || fail "C: the fleet session's own window moved"
sleep 0.5; to pipe-pane -t o:view
python3 - "$W/client.bytes" <<'PY' || fail "C: the client got a whole-screen clear on the switch"
import sys
b = open(sys.argv[1], "rb").read()
sys.exit(1 if (b"\x1b[2J" in b or b"\x1b[H\x1b[J" in b or b"\x1bc" in b) else 0)
PY
log="$W/conf/logs/view-switch.ndjson"
python3 - "$log" "$W2" <<'PY' || fail "C: view-switch.ndjson: $(cat "$log" 2>/dev/null)"
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1])]
r = recs[-1]
assert r["method"] == "select-window" and r["view"] == "v1" and r["how"] == "popup", r
assert isinstance(r["ms"], (int, float)) and r["ms"] >= 0, r
assert r["to"] == sys.argv[2], r
PY
pass "C  ↵ here: select-window on the 看台, no whole-screen clear, logged ($(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["ms"])' "$log") ms)"

# --- D: another machine --------------------------------------------------------------------
before=$(ti display-message -p -t 'fl@view-v1:' '#{window_id}')
TMUX="$IN,0,0" python3 "$BIN/fleet-quickopen.py" go 'fl@view-v1' "$MU/far1"; rc=$?
[ "$rc" = 3 ] || fail "D: go to m4's session answered $rc, not 3"
[ "$(ti display-message -p -t 'fl@view-v1:' '#{window_id}')" = "$before" ] || fail "D: a far go changed the 看台"
tail -1 "$log" | grep -q '"method":"far-none"' || fail "D: not logged far-none: $(tail -1 "$log")"
TMUX="$IN,0,0" bash "$BIN/fleet-view-go.sh" v1 "$OU/oth1"; [ $? = 3 ] || fail "D: another login's session here is not C4's (rc 3)"
TMUX="$IN,0,0" bash "$BIN/fleet-view-go.sh" v1 "@99999"; [ $? = 4 ] || fail "D: a gone window is not rc 4"
TMUX="$IN,0,0" bash "$BIN/fleet-view-go.sh" nosuch "$UU/f1"; [ $? = 2 ] || fail "D: no such 看台 is not rc 2"
pass "D  another machine / login: 这台还没接上 (rc 3), nothing moved; gone 4; no 看台 2"

# --- E: ⌘↓ ⌘↑ ⌘[ ⌘] ------------------------------------------------------------------------
cur() { ti display-message -p -t 'fl@view-v1:' '#{window_id}'; }
TMUX="$IN,0,0" bash "$BIN/fleet-view-go.sh" v1 "$UU/f1" || fail "E: go by worker id"
[ "$(cur)" = "$W1" ] || fail "E: go by worker id landed on $(cur)"
to send-keys -t o:view -H 1b 5b 39 32 30 7e   # ⌘↓: alpha → beta
for _ in 1 2 3 4 5 6; do sleep 0.3; [ "$(cur)" = "$W2" ] && break; done
[ "$(cur)" = "$W2" ] || fail "E: ⌘↓ from alpha did not land on beta ($(cur))"
to send-keys -t o:view -H 1b 5b 39 32 31 7e   # ⌘↑: beta → alpha
for _ in 1 2 3 4 5 6; do sleep 0.3; [ "$(cur)" = "$W1" ] && break; done
[ "$(cur)" = "$W1" ] || fail "E: ⌘↑ from beta did not land on alpha ($(cur))"
to send-keys -t o:view -H 1b 5b 39 32 32 7e   # ⌘[: back to beta
for _ in 1 2 3 4 5 6; do sleep 0.3; [ "$(cur)" = "$W2" ] && break; done
[ "$(cur)" = "$W2" ] || fail "E: ⌘[ did not go back to beta ($(cur))"
to send-keys -t o:view -H 1b 5b 39 32 33 7e   # ⌘]: forward to alpha
for _ in 1 2 3 4 5 6; do sleep 0.3; [ "$(cur)" = "$W1" ] && break; done
[ "$(cur)" = "$W1" ] || fail "E: ⌘] did not go forward to alpha ($(cur))"
to send-keys -t o:view C-] n                 # the phone's ⌃] n = ⌘↓
for _ in 1 2 3 4 5 6; do sleep 0.3; [ "$(cur)" = "$W2" ] && break; done
[ "$(cur)" = "$W2" ] || fail "E: ⌃] n did not step to beta ($(cur))"
[ -f "$W/conf/remote-views/v1.d/history.json" ] || fail "E: no history beside the registry row"
[ "$(ti show-options -v -t fl key-table 2>/dev/null || echo root)" != fleet-view ] || fail "E: the fleet session's key-table changed"
[ -s "$W/pane1.in" ] && fail "E: a ⌘ key's bytes reached a pane: $(od -c "$W/pane1.in" | head -2)"
pass "E  ⌘↓ ⌘↑ walk the list, ⌘[ ⌘] the history, ⌃] n on a phone; the fleet session keeps its keys"

# --- F: the old client's road ----------------------------------------------------------------
grep -q 'if argv\[:1\] == \["do"\] and len(argv) == 2:' "$BIN/fleet-quickopen.py" || fail "F: the old do <verb> road changed"
pass "F  the old client's quickopen keeps its own road"
echo "fleet-view-selftest: all passed"
