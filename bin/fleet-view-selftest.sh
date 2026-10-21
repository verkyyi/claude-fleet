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
#      fleet-view = root copied (the mouse) + ⌘↓ ⌘↑ ⌘[ ⌘] ⌘P (+ C7's ⌘N ⌘Q ⌘T
#      ⌃\, fleet-view-c7-selftest.sh) off the switch
#      table (dash-keymap.sh); fleet-view-pfx = ⌃] then the 看台's letter (view);
#      sourcing twice leaves the same tables
#   B  ⌘P (`ESC[927~`) in the 看台 opens the list — 等你 first (issue #3179), the
#      question under its row, 排队中 under them (its 收起 line last), 已收起
#      folded (→ ← ↵, #3666), no 「新任务」 / 停放 / 待你动手
#      (issue #3119), no (machine, login) group, no `merged` / `done:2h` /
#      `⇢cla` — `?` shows the legend — and in a session
#      attached directly it does nothing
#      (no popup, no byte reaches the pane)
#   C  ↵ on a row here: the 看台's current window changes (select-window), with no
#      whole-screen clear on the client; one view-switch.ndjson line (method ·
#      ms); the 看台's mouse table equals root's
#   D  go to another machine's / login's session (C4, issue #2751): its link not
#      up → a peer window for that (machine, login) is made in the 看台 (panel
#      role, @peer, @peer_view, @peer_want = the session) and shown, rc 3, logged
#      peer-wait; a second go reuses it; another login here gets its own window
#   E  ⌘↓ / ⌘↑ walk the list's order, ⌘[ / ⌘] the history; a session that is
#      not a 看台 keeps root (its key-table untouched)
#   I  issue #3179 (EPIC #3178 C1; 回收 D, T681): the list grouped by whether it
#      needs you — 置顶 · 等你 · 在干活 · 排队中 (· 已收起, folded); one one-cell glyph a row (! x » ✓ ∙ ?,
#      ASCII under FLEET_GLYPHS=ascii, no colour under NO_COLOR), the state word
#      on the lit row only, the question under an asking row, tags, the repo only
#      with 2+ repos, every query word must hit; `?` on an empty query (in B) is
#      the legend, after text a letter
#   J  issue #3286: 已收起 lists, after the open ended rows, the sessions whose
#      windows were reaped — fleet-history.sh rows (the sidebar's ⌃t ledger),
#      one row a key, one an open row shows left out; its menu is 恢复 alone,
#      which runs fleet-restore-pick.sh --select (a #543 question: exit 4, then
#      --answer); ⌘↓ never walks onto one; the read is cached, single-flight,
#      in the background (view-gone waits for it)
#   K  issue #3731, 回收 D: the producer's 已结束 rows in 排队中 (a window still up,
#      ↵ on the group's last row folds them all through fleet-view-reap-all.sh —
#      dash-reap.sh --yes each, a dirty worktree kept and said) above 已收起 (the
#      last FLEET_VIEW_CLOSED_HOURS, 168,
#      by the close time fleet-history.sh appends; the older ones one line,
#      「更早的 N 个 → /fleet-history」), folded until → / ↵
#   G  a phone (issue #3006, C9): the ⌃] letters (dash-keymap.sh --panel switch
#      view: p list · n / b · c · t · q, one letter each, every one a switch-table
#      action); a 40-column client: ⌃] p opens the list on the whole screen, ⌃] n
#      steps on to another machine's session
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
ROOT="$(cd "$BIN/.." && pwd)"
st_need tmux
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
# Every key a person can add (issue #3185: by default only the panel is bound) —
# the client's extras (carried by the attach) and the phone's ⌃] letters
export FLEET_KEYS_EXTRA='next=cmd+down prev=cmd+up back=cmd+[ fwd=cmd+] new=cmd+n dispatch=cmd+t quit=cmd+q shell=ctrl+\\'
export FLEET_KEYS_PHONE_EXTRA='ctrl+]n=next ctrl+]b=prev ctrl+]h=back ctrl+]l=fwd ctrl+]c=new ctrl+]t=dispatch ctrl+]q=quit ctrl+]\\=shell'
unset TMUX TMUX_PANE
ME=$(id -un)
US=$'\037'
ti() { tmux -S "$IN" "$@"; }
to() { tmux -S "$OUT" "$@"; }

# --- A: the tables ---------------------------------------------------------------
tmux -S "$STOCK" -f /dev/null new-session -d -s k -x 100 -y 30 'sleep 600' || st_fail "A: stock tmux"
tmux -S "$STOCK" list-keys > "$W/stock.keys"
norm() { awk '{ $1 = $1; print }'; }
# The rows the 看台 lists (tmux-dashboard-rows.sh --rows's shape, 19 fields),
# through the producer seam: two here, one on mac-a, one of another login here, one
# ended. Window ids are filled in once the windows exist.
cat > "$W/rows.sh" <<'EOF'
#!/bin/sh
cat "$FLEET_VIEW_ROWS_FILE"
EOF
export FLEET_VIEW_ROWS_CMD="sh '$W/rows.sh'" FLEET_VIEW_ROWS_FILE="$W/rows.txt"
# the 已回收 list's read (issue #3286): an empty ledger unless a leg says otherwise
: > "$W/gone.txt"
export FLEET_VIEW_LANDED_CMD="cat '$W/gone.txt'"
ti -f /dev/null new-session -d -s fl -x 120 -y 30 -n orch "sh -c 'echo ORCH; exec cat > \"$W/pane0.in\"'" || st_fail "A: inner tmux"
ti source-file "$ROOT/conf/tmux-view.conf" 2>"$W/src.err" || st_fail "A: tmux-view.conf did not source: $(cat "$W/src.err")"
for c in 920 921 922 923 924 925 926 927 928 929 930 931 932; do
  ti show-options -s user-keys | grep -Fq "user-keys[$c] \\033[$c~" || st_fail "A: user-keys[$c] not set"
done
ti list-keys -T root | norm > "$W/root.now"; grep -- ' -T root ' "$W/stock.keys" | norm > "$W/root.stock"
diff -q "$W/root.now" "$W/root.stock" >/dev/null || st_fail "A: root differs from tmux's: $(diff "$W/root.stock" "$W/root.now" | head -5)"
ti list-keys -T prefix | norm > "$W/pfx.now"; grep -- ' -T prefix ' "$W/stock.keys" | norm > "$W/pfx.stock"
diff -q "$W/pfx.now" "$W/pfx.stock" >/dev/null || st_fail "A: prefix differs from tmux's"
ti list-keys -T fleet-view | norm > "$W/fv.1"
# MouseDown1Status is the 看台's own (T701: the message row's click opens ⌘P's 消息,
# root's own click carried inside it) — compared apart, like the codes
copy=$(grep -v -E ' User9[0-9][0-9] | C-\] | C-\\\\ | C-Space | F12 | MouseDown1Status ' "$W/fv.1" | sed 's/ -T fleet-view / -T root /')
grep -q ' MouseDown1Status .*mouse_status_range},inbox' "$W/fv.1" || st_fail "A: the message row's click is not fleet-view's"
[ "$copy" = "$(grep -v -E ' C-Space | F12 | MouseDown1Status ' "$W/root.now")" ] || st_fail "A: fleet-view's copy is not root: $(diff <(printf '%s\n' "$copy") "$W/root.now" | head -5)"
table=$(bash "$BIN/dash-keymap.sh" --panel switch list)
vtable=$(bash "$BIN/dash-keymap.sh" --panel switch view)
[ "$(awk '{ print $2 }' <<< "$vtable" | sort | uniq -d)" = '' ] || st_fail "A: two 看台 actions share a ⌃] letter: $vtable"
for a in $(awk '{ print $1 }' <<< "$vtable"); do
  awk -v a="$a" '$1 == a { f = 1 } END { exit !f }' <<< "$table" || st_fail "A: ⌃] letter for $a, which the switch table lacks"
done
for p in 'quickopen p' 'next n' 'prev b' 'new c' 'dispatch t' 'quit q'; do
  grep -qx "$p" <<< "$vtable" || st_fail "A: the phone's ⌃] $p is not in the 看台's letters: $vtable"
done
for a in next prev back fwd quickopen new quit dispatch; do
  code=$(awk -v a="$a" '$1 == a { print $4 }' <<< "$table"); letter=$(awk -v a="$a" '$1 == a { print $2 }' <<< "$vtable")
  grep -q " -T fleet-view User$code " "$W/fv.1" || st_fail "A: $a (User$code) is not bound in fleet-view"
  ti list-keys -T fleet-view-pfx | norm | grep -q -- "-T fleet-view-pfx \\\\\?$letter " || st_fail "A: ⌃] $letter ($a) is not bound in fleet-view-pfx"
done
for a in zoom fold; do
  code=$(awk -v a="$a" '$1 == a { print $4 }' <<< "$table")
  grep -q " -T fleet-view User$code " "$W/fv.1" && st_fail "A: $a (User$code) is bound — a 看台 has none"
done
grep -q ' -T fleet-view C-\] switch-client -T fleet-view-pfx' "$W/fv.1" || st_fail "A: ⌃] does not enter fleet-view-pfx"
grep -E ' User9[0-9][0-9] | C-\] | C-\\\\ ' "$W/fv.1" | grep -Eq 'kill-|respawn-|rename-session' \
  && st_fail "A: a 看台 key deletes, respawns or renames something"
ti source-file "$ROOT/conf/tmux-view.conf" || st_fail "A: second source"
ti list-keys -T fleet-view | norm > "$W/fv.2"
diff -q "$W/fv.1" "$W/fv.2" >/dev/null || st_fail "A: sourcing twice changed fleet-view"
st_ok_all "A  tables: root/prefix as tmux ships them, fleet-view = root + the 看台's keys, ⌃] prefix, idempotent"

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
  row "$W2" needs ! 'beta' ' ' '' 0 '' '' '#12' — 50% ok 'Beta 要你拍板' 'done:2h' '' question '要不要继续合并？' ''
  row "wid:$MU/far1" working ⠹ 'gamma' ' ' '' 0 '' mac-a '#13' — · ok 'Gamma 在 mac-a' keep '' '' '' ''
  row "wid:$OU/oth1" working ⠹ 'delta' ' ' '' 0 '' nodeA '#14' — · ok 'Delta 另一个登录' merged '' '' '' ''
  row hdr ended '' '▸ Ended (1)' ' '
  row "$W0" 'done' ✓ 'old' ' ' '' 0 '' '' '#9' — · ok 'Old 做完的' merged '' '' '' ''
} > "$W/rows.txt"
pl=$(printf '{"i":[{"r":"o/r#21","k":"epsilon","w":"answer:o/r#21","a":%d}]}' "$(( $(date +%s) - 7200 ))" | base64 | tr '+/' '-_' | tr -d '=\n')
printf '%s\n' "x${US}nodeA${US}online${US}looping${US}${US}${US}0${US}park=1${US}parkl=$pl" > "$W/g/orch_fl"
# one folded-away session (回收 D): fleet-history.sh rows' shape, kept fresh so the
# popup reads it on its first frame; emptied again after B
gone1="landed:issue:21@o/r${US}key${US}✓ #21      $(printf '%-26s' 'Old 收起的') $(printf '   %-8s %-7s %-4s' '5 mins' '#121' '·')${US}$(date +%s)"
printf '%s\n' "$gone1" | tee "$W/gone.txt" > "$W/g/view-gone.fl"
ti new-session -d -t fl -s 'fl@view-v1' || st_fail "B: no 看台 session"
ti set-option -t 'fl@view-v1' key-table fleet-view
ti select-window -t "=fl@view-v1:$W1"
printf '%s\tfl\tthin\t%s\t%s\tcur=%s/f1\troute=lan\tdevice=\ttoken=t\tfuid=%s\tnode=nodeA\n' \
  /dev/null "$(date +%s)" "$$" "$UU" "$UU" > "$W/conf/remote-views/v1"
to -f /dev/null new-session -d -s o -x 120 -y 32 -n view "TMUX= tmux -S '$IN' attach -t 'fl@view-v1'" || st_fail "B: outer tmux"
to new-window -d -t o -n direct "TMUX= tmux -S '$IN' attach -t fl"
sleep 1
[ "$(ti list-clients | wc -l | tr -d ' ')" = 2 ] || st_fail "B: the two clients did not attach: $(ti list-clients)"

# --- B: ⌘P ---------------------------------------------------------------------------
to send-keys -t o:direct -H 1b 5b 39 32 37 7e
sleep 1
to capture-pane -p -t o:direct > "$W/direct.txt"
grep -q '在干活' "$W/direct.txt" && st_fail "B: ⌘P opened a list in a session attached directly"
[ -s "$W/pane0.in" ] && st_fail "B: ⌘P's bytes reached the pane in a session attached directly: $(od -c "$W/pane0.in" | head -2)"
to send-keys -t o:view -H 1b 5b 39 32 37 7e
ok=''; for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 0.5; to capture-pane -p -t o:view > "$W/popup.txt"; grep -q '等你 1' "$W/popup.txt" && { ok=1; break; }
done
[ -n "$ok" ] || st_fail "B: ⌘P in the 看台 opened no list: $(cat "$W/popup.txt")"
for want in '─ 等你 1' '─ 在干活 3' '要不要继续合并？' 'Alpha 的完整标题很长很长' '─ 排队中 1' 'Old 做完的' '⌫ 现在收起已结束的 1 个' '▸ 已收起 1 个'; do
  grep -qF "$want" "$W/popup.txt" || st_fail "B: the list lacks 「${want}」: $(cat "$W/popup.txt")"
done
# no session is special (issue #3119): no orchestrator 「新任务」 row, no 停放 / 待你动手
# section — the panel's own ⚡ row (issue #3327) sits once, under the sessions
# issue #3179: no (machine, login) grouping, a state is a glyph (the word only on the lit row)
# the first row is ✦ 消息 (T701), the sessions' first group 等你 right under it
grep -A1 '│› ' "$W/popup.txt" | tail -1 | grep -q '✦ 消息' || st_fail "B: the first line is not ✦ 消息: $(head -4 "$W/popup.txt")"
grep -A2 '│› ' "$W/popup.txt" | tail -1 | grep -q '─ 等你 1' || st_fail "B: the line under ✦ 消息 is not 等你: $(head -5 "$W/popup.txt")"
[ "$(grep -c '⚡ 新' "$W/popup.txt")" = 1 ] && grep -q '⚡ 新会话' "$W/popup.txt" || st_fail "B: the ⚡ row not once: $(grep -n '⚡' "$W/popup.txt")"
grep -q '新任务[：…]' "$W/popup.txt" && st_fail "B: 「新任务」 on an empty panel: $(grep -n '新任务' "$W/popup.txt")"
for bad in 'merged' 'done:2h' '⇢' '编排' '停放' '待你动手' '（这台）' '─ mac-a' '─ nodeA' '在问你'; do
  grep -qF -- "$bad" "$W/popup.txt" && st_fail "B: the list still says 「${bad}」: $(grep -F -- "$bad" "$W/popup.txt")"
done
ask=$(grep -n '─ 等你' "$W/popup.txt" | head -1 | cut -d: -f1); work=$(grep -n '─ 在干活' "$W/popup.txt" | head -1 | cut -d: -f1)
[ "$ask" -lt "$work" ] || st_fail "B: 等你 is not the first group"
# plan B (T493): glyph · ID · Agent · short name · repo
grep -qE '! +Claude +Beta 要你拍板' "$W/popup.txt" || st_fail "B: the asking row does not lead with its ! glyph: $(grep -F Beta "$W/popup.txt")"
# Highlight changes background only; text and glyph columns stay fixed (#4416).
grep -q '▶' "$W/popup.txt" && st_fail "B: selection inserted a marker"
[ -n "${FLEET_VIEW_EVIDENCE:-}" ] && cp "$W/popup.txt" "$FLEET_VIEW_EVIDENCE"
# `?` on an empty query: the legend line; with text it is a letter of the query
to send-keys -t o:view -l '?'; sleep 0.5; to capture-pane -p -t o:view > "$W/legend.txt"
grep -q '! 等你' "$W/legend.txt" || st_fail "B: ? on an empty query showed no legend: $(cat "$W/legend.txt")"
grep -q '› ?' "$W/legend.txt" && st_fail "B: ? on an empty query went into the query"
to send-keys -t o:view -l '?'; to send-keys -t o:view -l 'z?'; sleep 0.5; to capture-pane -p -t o:view > "$W/legend.txt"
grep -q '› z?' "$W/legend.txt" || st_fail "B: ? after text is not part of the query: $(head -2 "$W/legend.txt")"
to send-keys -t o:view BSpace BSpace; sleep 0.3
# issue #3666: on the 已收起 heading → opens it, ← shuts it, ↵ still toggles. Walk
# down pressing → until its row shows (→ on a session row does nothing).
shot() { sleep 0.4; to capture-pane -p -t o:view > "$W/fold.txt"; }
grep -q 'Old 收起的' "$W/popup.txt" && st_fail "B: 已收起 open before any key"
ok=''; for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  to send-keys -t o:view Down; to send-keys -t o:view Right; shot
  grep -q 'Old 收起的' "$W/fold.txt" && { ok=1; break; }
done
[ -n "$ok" ] || st_fail "B: → on the 已收起 heading did not open it: $(cat "$W/fold.txt")"
grep -q '▾ 已收起' "$W/fold.txt" || st_fail "B: → opened 已收起 but its caret is not ▾: $(grep -F 已收起 "$W/fold.txt")"
to send-keys -t o:view Right; shot
grep -q 'Old 收起的' "$W/fold.txt" || st_fail "B: a second → shut 已收起"
to send-keys -t o:view Left; shot
grep -q 'Old 收起的' "$W/fold.txt" && st_fail "B: ← on the open 已收起 heading did not shut it"
grep -q '▸ 已收起' "$W/fold.txt" || st_fail "B: ← shut 已收起 but its caret is not ▸"
to send-keys -t o:view Left; shot
grep -q 'Old 收起的' "$W/fold.txt" && st_fail "B: a second ← opened 已收起"
to send-keys -t o:view Enter; shot
grep -q 'Old 收起的' "$W/fold.txt" || st_fail "B: ↵ on the 已收起 heading no longer opens it"
to send-keys -t o:view Enter; shot
grep -q 'Old 收起的' "$W/fold.txt" && st_fail "B: ↵ on the open 已收起 heading no longer shuts it"
: > "$W/gone.txt"; : > "$W/g/view-gone.fl"
st_ok_all "B  ⌘P: → opens 已收起, ← shuts it, ↵ toggles it (#3666)"
st_ok_all "B  ⌘P: the list in the 看台 (等你 first, glyphs, the question under its row, 排队中 + its 收起 line, 已收起 folded), nothing in a direct attach"

# --- C: ↵ on beta, here ------------------------------------------------------------------
to pipe-pane -o -t o:view "cat > '$W/client.bytes'"
sleep 0.3
to send-keys -t o:view -l beta; sleep 0.4; to send-keys -t o:view Enter
for _ in 1 2 3 4 5 6 7 8; do sleep 0.3; [ "$(ti display-message -p -t 'fl@view-v1:' '#{window_id}')" = "$W2" ] && break; done
[ "$(ti display-message -p -t 'fl@view-v1:' '#{window_id}')" = "$W2" ] || st_fail "C: ↵ on beta did not switch the 看台 (now $(ti display-message -p -t 'fl@view-v1:' '#{window_id}'))"
[ "$(ti display-message -p -t 'fl:' '#{window_id}')" = "$W0" ] || st_fail "C: the fleet session's own window moved"
sleep 0.5; to pipe-pane -t o:view
python3 - "$W/client.bytes" <<'PY' || st_fail "C: the client got a whole-screen clear on the switch"
import sys
b = open(sys.argv[1], "rb").read()
sys.exit(1 if (b"\x1b[2J" in b or b"\x1b[H\x1b[J" in b or b"\x1bc" in b) else 0)
PY
log="$W/conf/logs/view-switch.ndjson"
python3 - "$log" "$W2" <<'PY' || st_fail "C: view-switch.ndjson: $(cat "$log" 2>/dev/null)"
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1])]
r = recs[-1]
assert r["method"] == "select-window" and r["view"] == "v1" and r["how"] == "popup", r
assert isinstance(r["ms"], (int, float)) and r["ms"] >= 0, r
assert r["to"] == sys.argv[2], r
PY
st_ok_all "C  ↵ here: select-window on the 看台, no whole-screen clear, logged ($(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["ms"])' "$log") ms)"

# --- D: another machine (C4) ---------------------------------------------------------------
before=$(ti display-message -p -t 'fl@view-v1:' '#{window_id}')
TMUX="$IN,0,0" python3 "$BIN/fleet-quickopen.py" go 'fl@view-v1' "$MU/far1"; rc=$?
[ "$rc" = 3 ] || st_fail "D: go to mac-a's session with no link answered $rc, not 3"
PW=$(ti display-message -p -t 'fl@view-v1:' '#{window_id}')
[ "$PW" != "$before" ] || st_fail "D: a far go did not show the machine's window"
[ "$(ti display-message -p -t "$PW" '#{@peer}|#{@peer_view}|#{@fleet_role}|#{@peer_want}')" = "mac-a@$ME|v1|panel|wid:$MU/far1" ] \
  || st_fail "D: the peer window: $(ti display-message -p -t "$PW" '#{@peer}|#{@peer_view}|#{@fleet_role}|#{@peer_want}')"
tail -1 "$log" | grep -q '"method":"peer-wait"' || st_fail "D: not logged peer-wait: $(tail -1 "$log")"
tail -1 "$log" | grep -q '"machine":"mac-a"' || st_fail "D: the far machine is not logged: $(tail -1 "$log")"
TMUX="$IN,0,0" bash "$BIN/fleet-view-go.sh" v1 "$MU/far1"; [ $? = 3 ] || st_fail "D: a second far go is not rc 3"
[ "$(ti list-windows -t fl -F '#{@peer}' | grep -c "^mac-a@$ME\$")" = 1 ] || st_fail "D: a second go made a second mac-a window"
TMUX="$IN,0,0" bash "$BIN/fleet-view-go.sh" v1 "$OU/oth1"; [ $? = 3 ] || st_fail "D: another login's session here is not a peer go (rc 3)"
ti list-windows -t fl -F '#{@peer}' | grep -qx 'nodeA@other' || st_fail "D: another login here got no window of its own: $(ti list-windows -t fl -F '#{@peer}')"
TMUX="$IN,0,0" bash "$BIN/fleet-view-go.sh" v1 "@99999"; [ $? = 4 ] || st_fail "D: a gone window is not rc 4"
TMUX="$IN,0,0" bash "$BIN/fleet-view-go.sh" nosuch "$UU/f1"; [ $? = 2 ] || st_fail "D: no such 看台 is not rc 2"
st_ok_all "D  another machine / login: its peer window, shown waiting (rc 3, peer-wait), one per (machine, login); gone 4; no 看台 2"

# --- E: ⌘↓ ⌘↑ ⌘[ ⌘] ------------------------------------------------------------------------
cur() { ti display-message -p -t 'fl@view-v1:' '#{window_id}'; }
TMUX="$IN,0,0" bash "$BIN/fleet-view-go.sh" v1 "$UU/f1" || st_fail "E: go by worker id"
[ "$(cur)" = "$W1" ] || st_fail "E: go by worker id landed on $(cur)"
to send-keys -t o:view -H 1b 5b 39 32 31 7e   # ⌘↑: alpha → beta (等你 sits above)
for _ in 1 2 3 4 5 6; do sleep 0.3; [ "$(cur)" = "$W2" ] && break; done
[ "$(cur)" = "$W2" ] || st_fail "E: ⌘↑ from alpha did not land on beta ($(cur))"
to send-keys -t o:view -H 1b 5b 39 32 30 7e   # ⌘↓: beta → alpha
for _ in 1 2 3 4 5 6; do sleep 0.3; [ "$(cur)" = "$W1" ] && break; done
[ "$(cur)" = "$W1" ] || st_fail "E: ⌘↓ from beta did not land on alpha ($(cur))"
to send-keys -t o:view -H 1b 5b 39 32 32 7e   # ⌘[: back to beta
for _ in 1 2 3 4 5 6; do sleep 0.3; [ "$(cur)" = "$W2" ] && break; done
[ "$(cur)" = "$W2" ] || st_fail "E: ⌘[ did not go back to beta ($(cur))"
to send-keys -t o:view -H 1b 5b 39 32 33 7e   # ⌘]: forward to alpha
for _ in 1 2 3 4 5 6; do sleep 0.3; [ "$(cur)" = "$W1" ] && break; done
[ "$(cur)" = "$W1" ] || st_fail "E: ⌘] did not go forward to alpha ($(cur))"
to send-keys -t o:view C-] b                 # the phone's ⌃] b = ⌘↑
for _ in 1 2 3 4 5 6; do sleep 0.3; [ "$(cur)" = "$W2" ] && break; done
[ "$(cur)" = "$W2" ] || st_fail "E: ⌃] b did not step to beta ($(cur))"
[ -f "$W/conf/remote-views/v1.d/history.json" ] || st_fail "E: no history beside the registry row"
[ "$(ti show-options -v -t fl key-table 2>/dev/null || echo root)" != fleet-view ] || st_fail "E: the fleet session's key-table changed"
[ -s "$W/pane1.in" ] && st_fail "E: a ⌘ key's bytes reached a pane: $(od -c "$W/pane1.in" | head -2)"
st_ok_all "E  ⌘↓ ⌘↑ walk the list, ⌘[ ⌘] the history, ⌃] b on a phone; the fleet session keeps its keys"

# --- G: a phone (issue #3006, C9; T705): 40 columns, ⌃] p / F12 the whole screen, ⌃] n on to mac-a ----------
to resize-window -t o:view -x 40 -y 20
sleep 0.5
[ "$(ti display-message -p -t 'fl@view-v1:' '#{client_width}')" = 40 ] \
  || st_fail "G: the client is not 40 columns: $(ti list-clients -F '#{client_width}')"
to send-keys -t o:view C-] p
ok=''; for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 0.5; to capture-pane -p -t o:view > "$W/phone.txt"; grep -q '等你' "$W/phone.txt" && { ok=1; break; }
done
[ -n "$ok" ] || st_fail "G: ⌃] p opened no list at 40 columns: $(cat "$W/phone.txt")"
python3 - "$W/phone.txt" <<'PY' || st_fail "G: the list is not the whole screen at 40 columns: $(cat "$W/phone.txt")"
import sys, unicodedata
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
# the popup's border at column 0 on the first row and the 40th column (in display
# cells — a row of CJK is fewer characters) on a body row
cells = lambda t: sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in t)
assert lines[0][:1] in "┌╭", lines[0]
assert any(l.rstrip()[-1:] in "│┃" and cells(l.rstrip()) == 40 for l in lines[1:]), lines
PY
[ -n "${FLEET_VIEW_EVIDENCE_PHONE:-}" ] && cp "$W/phone.txt" "$FLEET_VIEW_EVIDENCE_PHONE"
to send-keys -t o:view Escape
# Escape itself may wait for tmux's default escape-time (500 ms). Do not send
# the next navigation key until the popup has closed and its freeze is undone.
closed=''
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if [ "$(ti show-options -gqv @popup_open)" = 0 ] && \
     [ "$(ti display-message -p -t "$W2" '#{pane_in_mode}')" = 0 ]; then closed=1; break; fi
  sleep 0.2
done
[ -n "$closed" ] || st_fail "G: phone popup did not close and thaw"
# F12 (T705): the phone's one tap — Termius's key row — opens the same list
to send-keys -t o:view F12
ok=''; for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 0.5; to capture-pane -p -t o:view > "$W/phone-f12.txt"; grep -q '等你' "$W/phone-f12.txt" && { ok=1; break; }
done
[ -n "$ok" ] || st_fail "G: F12 opened no list at 40 columns: $(cat "$W/phone-f12.txt")"
[ -n "${FLEET_VIEW_EVIDENCE_PHONE:-}" ] && cp "$W/phone-f12.txt" "$FLEET_VIEW_EVIDENCE_PHONE.f12"
to send-keys -t o:view Escape
closed=''
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if [ "$(ti show-options -gqv @popup_open)" = 0 ] && \
     [ "$(ti display-message -p -t "$W2" '#{pane_in_mode}')" = 0 ]; then closed=1; break; fi
  sleep 0.2
done
[ -n "$closed" ] || st_fail "G: the F12 popup did not close and thaw"
TMUX="$IN,0,0" bash "$BIN/fleet-view-go.sh" v1 "$UU/f1" || st_fail "G: go to alpha"
to send-keys -t o:view C-] n                 # alpha → the next in the list: mac-a's session
for _ in $(seq 1 40); do sleep 0.25;  # a poll, not a budget: the first go opens the peer window (#4443)
   case $(ti display-message -p -t 'fl@view-v1:' '#{@peer}') in mac-a@*) break ;; esac; done
case $(ti display-message -p -t 'fl@view-v1:' '#{@peer}') in
  "mac-a@$ME") ;; *) st_fail "G: ⌃] n from alpha did not step on to mac-a's window ($(cur) @peer=$(ti display-message -p -t 'fl@view-v1:' '#{@peer}'))" ;;
esac
to resize-window -t o:view -x 120 -y 32
st_ok_all "G  a phone: 40 columns, ⌃] p and F12 the list on the whole screen, ⌃] n on to another machine's session"

# --- H: no session is special (issue #3119): the orchestrator gets no line of its own ----------
python3 - "$BIN" <<'EOF' || st_fail "H: the orchestrator still gets a line of its own"
import importlib.util, sys, tempfile
from pathlib import Path
spec = importlib.util.spec_from_file_location("fv", sys.argv[1] + "/fleet_view.py")
fv = importlib.util.module_from_spec(spec); spec.loader.exec_module(fv)
g = Path(tempfile.mkdtemp())
(g / "orch_fl").write_text("\x1f".join(["UU/orchfid", "mac-c", "online", "looping", "", "", "0", "park=1", "todo=2"]) + "\n")
fv.dash_global = lambda: g
fv.view_row = lambda vid: {}
fv.view_fleet = lambda vid, row=None: "fl"
fv.here_label = lambda row: "mac-a"
fv.fleet_logins = lambda: {"UU": "carol"}
fv.windows = lambda fleet: {"@3": ("f3", "orchestrator", 0)}   # the holder here, too
fv.produce = lambda fleet, **kw: ""
assert fv.entries("v1") == [], fv.entries("v1")
# (the orchestrator readers go_orch / orch_target are gone, #3119: conf/gone.list)
EOF
st_ok_all "H  no session is special: orch_<fleet> and a holder window add no line (issue #3119)"

# --- I: grouped by what you should do (issue #3179, EPIC #3178 C1) -----------------------------
# 2 machines × 6 kinds of row (asking with its words, failed, broken configuration,
# just merged, pinned, lost): the groups in order, the six glyphs each one cell
# (ASCII under FLEET_GLYPHS=ascii, no colour under NO_COLOR), the state word only
# on the lit row, the question under its row, tags (✗ broken · ∅ · k/N · mac-a 失联,
# the repo only with 2+), no machine group, a child under a parent of another
# group at depth 0, and a two-word query (「修 3164」) hits #3164.
cat > "$W/leg-i.py" <<'PYI'
import importlib.util, os, sys, tempfile, time, unicodedata
from pathlib import Path
B = sys.argv[1]
spec = importlib.util.spec_from_file_location("fv", B + "/fleet_view.py")
fv = importlib.util.module_from_spec(spec); spec.loader.exec_module(fv)
qs = importlib.util.spec_from_file_location("qo", B + "/fleet-quickopen.py")
qo = importlib.util.module_from_spec(qs); qs.loader.exec_module(qo)
US = "\x1f"
now = int(time.time())
def row(*f): return US.join(f)
def body(repos):
    r = []
    r.append(row("hdr", "pin", "", "置顶 (1)", " "))
    r.append(row("@1", "idle", "·", "pinned", " ", "", "0", "", "", "#1", "—", "·", "ok", "置顶的会话", "keep"))
    r.append(row("hdr", "", "", "─" * 40, " "))
    r.append(row("hdr", repos[0], "", "claude-fleet (5)", " "))
    r.append(row("@2", "working", "⠹", "par", " ", "1/2", "0", "", "", "#2", "—", "50%", "ok", "父会话 EPIC", "merged"))
    r.append(row("@3", "needs", "!", "kid", " ", "", "1", "question", "", "#3", "—", "50%", "ok", "子会话在问", "merged", "", "question", "要不要合并这个 PR？   第二行"))
    r.append(row("@4", "failed", "x", "bad", " ", "", "0", "", "", "#4", "—", "·", "broken", "配置坏了的会话", "merged", "failed"))
    r.append(row("@5", "done", "✓", "landed", " ", "", "0", "", "", "#3164", "merged", "·", "ok", "修 列表冻住", "merged"))
    r.append(row("@6", "done", "✓", "oldie", " ", "", "0", "", "", "#6", "merged", "·", "ok", "很早合并的", "merged"))
    r.append(row("hdr", repos[1] if len(repos) > 1 else "none", "", "tokenledger (1)" if len(repos) > 1 else "无仓库 (1)", " "))
    r.append(row("wid:MU/far1", "working", "⠹", "far", " ", "", "0", "", "mac-a!", "#7", "—", "·", "ok", "失联机器上的", "merged"))
    r.append(row("wid:MU/far2", "needs", "!", "far2", " ", "", "0", "", "mac-a", "#8", "—", "·", "ok", "mac-a 在问", "merged", "", "permission", "Bash: rm -rf build"))
    r.append(row("hdr", "ended", "", "▸ 已结束 (1)", " "))
    r.append(row("@9", "done", "✓", "ended", " ", "", "0", "", "", "", "—", "·", "ok", "结束的", "merged"))
    return "\n".join(r) + "\n"
fv.view_row = lambda vid: {}
fv.view_fleet = lambda vid, row=None: "fl"
fv.here_label = lambda row: "nodeA"
fv.fleet_logins = lambda: {"MU": "carol"}
fv.windows = lambda fleet: {"@5": ("", "worker", now - 600), "@6": ("", "worker", now - 3 * 86400), "@9": ("", "worker", now - 60)}
os.environ["FLEET_UI_LANG"] = "zh"
fv.gone_text = lambda fleet: ""
def run(repos):
    fv.produce = lambda fleet, **kw: body(repos)
    return fv.entries("v1")
it = run(["o/claude-fleet"])
heads = [e["group"] for e in it if e["kind"] == "hdr"]
# 回收 D (T681): a done row and the producer's 已结束 are one group, 排队中
assert heads == ["pin", "ask", "work", "queue"], heads
grp = {e["target"]: e["group"] for e in it if e["kind"] == "sess"}
assert grp == {"@1": "pin", "@3": "ask", "@4": "ask", "MU/far2": "ask", "@2": "work", "MU/far1": "work",
               "@5": "queue", "@6": "queue", "@9": "queue"}, grp
assert [e["target"] for e in it if e.get("ended")] == ["@9"], it
sym = {e["target"]: e["sym"] for e in it if e["kind"] == "sess"}
assert sym["@3"] == "needs" and sym["@4"] == "fail" and sym["@2"] == "work" and sym["@5"] == "done" \
    and sym["@1"] == "idle" and sym["MU/far1"] == "lost", sym
ask = [e for e in it if e["kind"] == "ask"]
assert [a["of"] for a in ask] == ["@3", "MU/far2"] and ask[0]["text"] == "要不要合并这个 PR？ 第二行", ask
tags = {e["target"]: e["tags"] for e in it if e["kind"] == "sess"}
assert tags["@4"] == ["✗ 会坏·需重开", "∅"], tags["@4"]
assert tags["MU/far1"] == ["mac-a 失联"] and tags["MU/far2"] == [] and tags["@2"] == ["1/2"], tags
assert not any("o/claude-fleet" in " ".join(t) or "claude-fleet" in " ".join(t) for t in tags.values()), tags
# a child whose parent sits in another group stands at depth 0
dep = {e["target"]: e["depth"] for e in it if e["kind"] == "sess"}
assert dep["@3"] == 0, dep
it2 = run(["o/claude-fleet", "o/tokenledger"])
t2 = {e["target"]: e["tags"] for e in it2 if e["kind"] == "sess"}
assert "claude-fleet" in t2["@2"] and "tokenledger" in t2["MU/far1"], t2
# two-word query
v = fv.visible(it, "修 3164", set())
assert v and v[0]["target"] == "@5", [e.get("target") for e in v]
assert fv.visible(it, "3164 不存在的词", set()) == []
# a match is the title or the issue number, never a machine's name (issue #3327):
# `mac-a` lights no row on mac-a, `#8` its issue
assert [e for e in fv.visible(it, "mac-a", set()) if e["kind"] == "sess" and "mac-a" not in (e.get("text") or "")] == [], \
    [(e.get("target"), e.get("text")) for e in fv.visible(it, "mac-a", set())]
assert [e["target"] for e in fv.visible(it, "#8", set()) if e["kind"] == "sess"] == ["MU/far2"], fv.visible(it, "#8", set())
# paint
def w1(c): return 0 if unicodedata.category(c) in ("Mn", "Me", "Cf") else (2 if unicodedata.east_asian_width(c) in "WF" else 1)
for mode in ("", "ascii"):
    os.environ["FLEET_GLYPHS"] = mode
    shown = fv.visible(run(["o/r"]), "", set())
    at = next(i for i, e in enumerate(shown) if e.get("target") == "@2")
    lines = fv.paint(shown, at, 100, qo.cells, qo.clip)
    gl = fv.glyphs()
    for e, segs in zip(shown, lines):
        if e["kind"] != "sess": continue
        g = segs[1][0]
        assert g == gl[e["sym"]] and len(g) == 1 and w1(g) == 1, (g, e)
        if mode == "ascii": assert g.isascii(), g
        text = "".join(s[0] for s in segs)
        assert e["word"] not in text.split(e["text"])[0], text
        assert text.startswith("  " + gl[e["sym"]] + " "), text
    assert len({e["sym"] for e in shown if e["kind"] == "sess"}) == 6
    assert any(any(st.startswith("c") for _, st in segs for st in st) for segs in lines)
    # only ! and ✗ are coloured (red, bold); the tags no longer ride the row
    for e, segs in zip(shown, lines):
        if e["kind"] != "sess": continue
        colored = any(st.startswith("c") for st in segs[1][1])
        assert colored == (e["sym"] in ("needs", "fail") and not e.get("lost")), (e["sym"], segs[1])
        assert "会坏" not in "".join(t for t, _ in segs), segs
os.environ["NO_COLOR"] = "1"
lines = fv.paint(shown, at, 100, qo.cells, qo.clip)
assert not any(st.startswith("c") for segs in lines for _, sty in segs for st in sty), "NO_COLOR left a colour"
PYI
( unset NO_COLOR FLEET_COLOR FLEET_GLYPHS; python3 "$W/leg-i.py" "$BIN" ) || st_fail "I: the grouped list"
st_ok_all "I  ⌘P grouped: 置顶 · 等你 · 在干活 · 排队中 (· 已收起); six one-cell glyphs (ascii, NO_COLOR); the question under its row; tags; 「修 3164」"

# --- J: the reaped sessions (issue #3286) -------------------------------------------------------
mkdir -p "$W/jstub"
cat > "$W/jstub/fleet-restore-pick.sh" <<'EOF'
#!/bin/bash
printf 'fleet-restore-pick.sh|%s\n' "$*" >> "$JLOG"
case "$*" in *landed:issue:7*--ask*) echo '#7 的 PR #70 已关闭（未合并），静默 15 分钟会被回收'; exit 4 ;; esac
exit 0
EOF
cat > "$W/leg-j.py" <<'PYJ'
import importlib.util, os, sys, time
from pathlib import Path
B, W = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("fv", B + "/fleet_view.py")
fv = importlib.util.module_from_spec(spec); spec.loader.exec_module(fv)
US, E = "\x1f", "\x1b["
TX, GY, R = E + "38;2;169;177;214m", E + "38;2;86;95;137m", E + "0m"
def led(target, glyph, iss, win, title, act, pr):
    # fleet-history.sh cmd_rows' shape: glyph · issue (5) · tree · window (26) · title · act (8) · PR (7) · dep (4)
    return target + US + "key" + US + glyph + " " + iss.ljust(5) + " " + GY + "  " + R + " " + TX + win.ljust(26) + R + " " + \
        TX + title + R + "   " + GY + act.ljust(8) + R + " " + pr.ljust(7) + " " + "·".ljust(4)
gone = "\n".join([
    "hdr" + US + "hdr" + US + "  issue    window   title",
    led("landed:3278@o/claude-fleet", "✓", "#3276", "mac-新登录", "Mac 新登录租凭据 + 演练认看台", "32 mins", "#3278"),
    led("landed:3278@o/claude-fleet", "✓", "#3276", "mac-新登录", "（同一个键，旧一行）", "3 days", "#3278"),
    led("landed:scratch:scratch-23@o/claude-fleet", "✗", "~23", "写设计页", "写设计页（个人 MCP 统一", "47 mins", "—"),
    led("landed:issue:7@o/claude-fleet", "✗", "#7", "seven", "PR 关了没合的", "2 hours", "—"),
    led("landed:5011@o/claude-fleet", "✓", "#11", "alpha", "已经又开着的 #11", "1 day", "#5011"),
]) + "\n"
US_ = US
def row(*f): return US_.join(f)
open_rows = "\n".join([
    row("hdr", "o/claude-fleet", "", "claude-fleet (1)", " "),
    row("@1", "working", "⠹", "alpha", " ", "", "0", "", "", "#11", "—", "50%", "ok", "Alpha", "merged"),
    row("hdr", "ended", "", "▸ 已结束 (1)", " "),
    row("@9", "done", "✓", "ended", " ", "", "0", "", "", "#9", "merged", "·", "ok", "结束的", "merged"),
]) + "\n"
fv.view_row = lambda vid: {}
fv.view_fleet = lambda vid, row=None: "fl"
fv.here_label = lambda row: "nodeA"
fv.fleet_logins = lambda: {}
fv.windows = lambda fleet: {"@9": ("", "worker", int(time.time()) - 3 * 86400)}   # merged days ago: 已结束
fv.produce = lambda fleet, **kw: open_rows
fv.gone_text = lambda fleet: gone
it = fv.entries("v1")
sec = [e for e in it if e["kind"] == "sec"]
# issue #3731, 回收 D: the open one in 排队中 (marked ended), the reaped ones under 已收起
assert [(e["sec"], e["n"]) for e in sec] == [("gone", 3)], sec
ended = [e for e in it if (e.get("ended") or e.get("sec") == "gone") and e["kind"] == "sess"]
assert [e["target"] for e in ended] == ["@9", "landed:3278@o/claude-fleet", "landed:scratch:scratch-23@o/claude-fleet",
                                        "landed:issue:7@o/claude-fleet"], [e["target"] for e in ended]
assert [e.get("sec") or e["group"] for e in ended] == ["queue", "gone", "gone", "gone"], ended
g = ended[1]
assert g["gone"] and g["text"] == "Mac 新登录租凭据 + 演练认看台" and g["issue"] == "#3276" and g["right"] == "32 mins", g
assert g["sym"] == "done" and ended[2]["sym"] == "fail" and g["word"] == "已合并 · 窗口已回收", g
assert "PR #3278" in g["foot"] and "↵ 恢复" in g["foot"], g["foot"]
# folded: none of them shows; opened: all four, after the open one
v = fv.visible(it, "", set())
assert not any(e.get("gone") for e in v), v
v = fv.visible(it, "", {"ended"})
assert not any(e.get("gone") for e in v), v
v = fv.visible(it, "", {"gone"})
assert [e["target"] for e in v if e.get("sec") == "gone" and e["kind"] == "sess"] == [e["target"] for e in ended[1:]]
# a query finds one
assert [e["target"] for e in fv.visible(it, "演练认看台", set())] == ["landed:3278@o/claude-fleet"]
# ⌘↓ ⌘↑ never walk onto a reaped one
assert fv.session_order(it) == ["@1", "@9"], fv.session_order(it)
# Tab: 恢复, alone
r = fv.act_row("fl", g)
m = [(a["id"], label) for a, label in fv.menu_of(r)]
assert m == [("resume", "恢复")], m
# 恢复 runs the sidebar's ⌃t script, the same argv
log = Path(os.environ["JLOG"])
rc, said, went = fv.act_run(None, "v1", "fl", fv.ACTION["resume"], r, "", wait=True)
calls = log.read_text().splitlines()
assert rc == 0 and calls == ["fleet-restore-pick.sh|--select landed:3278@o/claude-fleet --session fl --ask"], (rc, said, calls)
# a #543 row: the question (exit 4), then the answer
r7 = fv.act_row("fl", ended[3])
rc, said, _ = fv.act_run(None, "v1", "fl", fv.ACTION["resume"], r7, "", wait=False)
assert rc == 4 and "已关闭" in said, (rc, said)
rc, said, _ = fv.act_run(None, "v1", "fl", fv.ACTION["resume"], r7, "R", wait=False)
assert rc == 0 and log.read_text().splitlines()[-1] == \
    "fleet-restore-pick.sh|--select landed:issue:7@o/claude-fleet --session fl --answer r", log.read_text()
# not in the background for a plain row when the popup does not wait: one call, started
n = len(log.read_text().splitlines())
rc, said, _ = fv.act_run(None, "v1", "fl", fv.ACTION["resume"], fv.act_row("fl", ended[2]), "", wait=False)
for _ in range(50):
    if len(log.read_text().splitlines()) > n: break
    time.sleep(0.1)
assert rc == 0 and log.read_text().splitlines()[-1].endswith("--select landed:scratch:scratch-23@o/claude-fleet --session fl"), \
    log.read_text()
PYJ
( JLOG="$W/j.log" FLEET_VIEW_ACT_BIN="$W/jstub" python3 "$W/leg-j.py" "$BIN" "$W" ) || st_fail "J: the reaped sessions in 已结束"
# the read: cached, single-flight, in the background; view-gone waits for it
printf 'landed:1@o/r\037k\037x\n' > "$W/gone.txt"
G="$W/g/view-gone.fl"; rm -f "$G"
python3 - "$BIN" <<'PYK' || st_fail "J: the 已回收 read"
import importlib.util, os, sys, time
spec = importlib.util.spec_from_file_location("fv", sys.argv[1] + "/fleet_view.py")
fv = importlib.util.module_from_spec(spec); spec.loader.exec_module(fv)
p = fv.gone_file("fl")
assert fv.gone_text("fl") == ""                      # no copy yet: nothing, a read started
for _ in range(50):
    if p.exists(): break
    time.sleep(0.1)
assert p.read_text().startswith("landed:1@o/r"), "the background read wrote nothing"
lock = p.parent / (p.name + ".lock")
for _ in range(50):
    if not lock.exists(): break
    time.sleep(0.1)
lock.mkdir()
assert fv.gone_read("fl") is False                   # one read at a time
lock.rmdir()
os.utime(str(p), (time.time() - 3600,) * 2)
mt = p.stat().st_mtime
assert fv.gone_text("fl").startswith("landed:1@o/r")  # the old copy shows; a new read starts
for _ in range(50):
    if p.stat().st_mtime > mt: break
    time.sleep(0.1)
assert p.stat().st_mtime > mt, "a stale copy was not read again"
PYK
rm -f "$G"
printf 'landed:2@o/r\037k\037y\n' > "$W/gone.txt"
python3 "$BIN/fleet-quickopen.py" view-gone --view v1 || st_fail "J: view-gone"
grep -q '^landed:2@o/r' "$G" || st_fail "J: view-gone did not read: $(cat "$G" 2>&1)"
: > "$W/gone.txt"
st_ok_all "J  已收起 lists the reaped sessions (fleet-history.sh rows) below 排队中; Tab/↵ → 恢复 = fleet-restore-pick.sh --select; read cached in the background"

# --- K: 已结束 · 还开着 and 已关闭 (issue #3731) ----------------------------------------
mkdir -p "$W/kstub"
cat > "$W/kstub/fleet-view-reap-all.sh" <<'EOF'
printf 'reap-all|%s\n' "$*" >> "$KLOG"
echo '回收了 2 个'
EOF
cat > "$W/leg-k.py" <<'PYK'
import importlib.util, os, sys, time
from pathlib import Path
B = sys.argv[1]
spec = importlib.util.spec_from_file_location("fv", B + "/fleet_view.py")
fv = importlib.util.module_from_spec(spec); spec.loader.exec_module(fv)
US, E = "\x1f", "\x1b["
TX, GY, R = E + "38;2;169;177;214m", E + "38;2;86;95;137m", E + "0m"
now = int(time.time())
def led(n, hours, act):
    # fleet-history.sh cmd_rows' shape, and the close time FLEET_HISTORY_EPOCH appends
    return "landed:%d@o/r" % (900 + n) + US + "key" + US + "✓ " + ("#%d" % n).ljust(5) + " " + GY + "  " + R + " " + \
        TX + ("w%d" % n).ljust(26) + R + " " + TX + "关了的 %d" % n + R + "   " + GY + act.ljust(8) + R + " " + \
        ("#%d" % (900 + n)).ljust(7) + " " + "·".ljust(4) + US + str(now - int(hours * 3600))
# 3 closed in the last 48 h, 5 before — the words lie on purpose: the epoch decides
gone = "\n".join([led(1, 1, "9 yrs"), led(2, 10, "9 yrs"), led(3, 47, "9 yrs"),
                  led(4, 49, "now"), led(5, 72, "now"), led(6, 200, "now"), led(7, 2000, "now"), led(8, 9000, "now")]) + "\n"
def row(*f): return US.join(f)
open_rows = "\n".join([
    row("hdr", "o/r", "", "r (1)", " "),
    row("@1", "working", "⠹", "alpha", " ", "", "0", "", "", "#11", "—", "50%", "ok", "Alpha", "merged"),
    row("@11", "idle", "·", "eleven", " ", "", "0", "", "", "#21", "—", "·", "ok", "闲着的十一", "merged"),
    row("hdr", "ended", "", "▸ 已结束 · 还开着 (3)", " "),
    row("@8", "done", "✓", "eight", " ", "", "0", "", "", "", "—", "·", "ok", "做完的八", "merged"),
    row("@9", "done", "✓", "nine", " ", "", "0", "", "", "", "—", "·", "ok", "做完的九", "merged"),
    row("@10", "exited", "x", "ten", " ", "", "0", "", "", "", "—", "·", "ok", "退出的十", "merged"),
]) + "\n"
fv.view_row = lambda vid: {}
fv.view_fleet = lambda vid, row=None: "fl"
fv.here_label = lambda row: "nodeA"
fv.fleet_logins = lambda: {}
fv.windows = lambda fleet: {}
fv.produce = lambda fleet, **kw: open_rows
fv.gone_text = lambda fleet: gone
os.environ.pop("FLEET_VIEW_CLOSED_HOURS", None)
os.environ["FLEET_CONF_DIR"] = sys.argv[2]          # no fleet.conf there: the default, 168 (7 days)
it = fv.entries("v1")
sec = [e for e in it if e["kind"] == "sec"]
assert [(e["sec"], e["n"]) for e in sec] == [("gone", 6)], sec
assert sec[0]["text"] == "已收起 6 个" and sec[0]["older"] == 3, sec
# 回收 D: the producer's 已结束 rows sit in 排队中, its 收起 line last; 已收起 (heading
# · newest first · 更早的 3 个) under it
q = next(e for e in it if e["kind"] == "hdr" and e["group"] == "queue")
tail = [(e["kind"], e.get("target") or e.get("cmd") or e.get("sec") or e.get("group")) for e in it[it.index(q):]]
# T688: an idle session waits in 排队中 (tagged 空闲), never 等你; an exited agent
# whose window is up is folded straight into 已收起, a live row there (↵ its window)
assert tail == [("hdr", "queue"), ("sess", "@11"), ("sess", "@8"), ("sess", "@9"), ("cmd", "reapall"),
                ("sec", "gone"), ("sess", "@10"), ("sess", "landed:901@o/r"), ("sess", "landed:902@o/r"), ("sess", "landed:903@o/r"),
                ("sess", "landed:904@o/r"), ("sess", "landed:905@o/r"), ("cmd", "history")], tail
assert q["text"] == "排队中 3", q
assert not any(e["kind"] == "hdr" and e["group"] == "ask" for e in it), it
idle = next(e for e in it if e.get("target") == "@11")
assert idle["group"] == "queue" and idle["tags"] == ["空闲"] and not idle.get("ended"), idle
ten = next(e for e in it if e.get("target") == "@10")
assert ten["sec"] == "gone" and ten["shut"] and not ten.get("gone") and ten["word"] == "已退出", ten
assert ten["foot"].endswith("已退出 · ↵ 恢复") and fv.live(ten) is False, ten
assert "enter" in [a["id"] for a in fv.ACTIONS if a["when"](ten)], ten
more = it[-1]
assert more["text"] == "更早的 3 个 → /fleet-history" and more["sec"] == "gone", more
ra = next(e for e in it if e.get("cmd") == "reapall")
assert ra["row"]["targets"] == ["@8", "@9"] and "收起已结束的 2 个" in ra["text"] and "sec" not in ra, ra
assert "Tab → 回收" in next(e for e in it if e.get("target") == "@8")["foot"]
# 已收起 folded by default: its heading, none of its rows; → opens it, ← shuts it
v = fv.visible(it, "", set())
assert [(e["kind"], e.get("sec")) for e in v if e.get("sec")] == [("sec", "gone")], v
assert all(e.get("closed") for e in v if e["kind"] == "sec")
assert [e.get("target") for e in v if e.get("ended")] == ["@8", "@9"], v
opened = fv.sec_fold(set(), "gone", True)
v = fv.visible(it, "", opened)
assert [e.get("target") or e.get("cmd") for e in v if e.get("sec") == "gone" and e["kind"] != "sec"] == \
    ["@10", "landed:901@o/r", "landed:902@o/r", "landed:903@o/r", "landed:904@o/r", "landed:905@o/r", "history"], v
assert fv.visible(it, "", fv.sec_fold(opened, "gone", False)) == fv.visible(it, "", set())
# the panel (view-panel's rows): the same lines, ⚡ and ⏻ after them
p = fv.panel_rows(it, "", {"ended", "gone"}, cmds=["new", "quit"])
kinds = [e.get("cmd") or e.get("target") for e in p if e["kind"] in ("cmd", "sess")]
h = kinds.index("history")
assert kinds[h - 1:h + 2] == ["landed:905@o/r", "history", "new"] and kinds[-1] == "quit", kinds
# the window is a setting: 1.5 h ⇒ one listed, seven older; fleet.conf's line when no env
Path(sys.argv[2], "fleet.conf").write_text("FLEET_VIEW_CLOSED_HOURS=1.5\n")
it2 = fv.entries("v1")
s2 = [e for e in it2 if e["kind"] == "sec" and e["sec"] == "gone"][0]
assert (s2["n"], s2["older"]) == (2, 7) and it2[-1]["text"] == "更早的 7 个 → /fleet-history", s2
os.environ["FLEET_VIEW_CLOSED_HOURS"] = "100"
s3 = [e for e in fv.entries("v1") if e["kind"] == "sec" and e["sec"] == "gone"][0]
assert (s3["n"], s3["older"]) == (6, 3), s3
os.environ.pop("FLEET_VIEW_CLOSED_HOURS")
Path(sys.argv[2], "fleet.conf").unlink()
# nothing older ⇒ no 更早 line; nothing closed ⇒ no 已收起 heading
fv.gone_text = lambda fleet: "\n".join(gone.split("\n")[:3]) + "\n"
it3 = fv.entries("v1")
assert not any(e.get("cmd") == "history" for e in it3) and it3[-1]["target"] == "landed:903@o/r", it3[-1]
fv.gone_text = lambda fleet: ""
assert [(e["sec"], e["n"]) for e in fv.entries("v1") if e["kind"] == "sec"] == [("gone", 1)]     # @10 alone
fv.produce = lambda fleet, **kw: "\n".join(l for l in open_rows.split("\n") if not l.startswith("@10" + US)) + "\n"
assert [e["sec"] for e in fv.entries("v1") if e["kind"] == "sec"] == []
fv.produce = lambda fleet, **kw: open_rows
# a copy written before the epoch rode along: the words, read as the least they mean
assert fv.gone_age(None, "47 mins", now) == 47 * 60 and fv.gone_age(None, "1 day", now) == 86400
assert fv.gone_age(None, "2 days", now) == 172800 and fv.gone_age(None, "now", now) == 0
assert fv.gone_age(None, "-", now) is None and fv.gone_age(now - 5, "9 yrs", now) == 5
t = fv.gone_rows(led(1, 1, "3 hours") + "\n" + led(2, 1, "3 hours").rpartition(US)[0] + "\n")
assert t[0][7] == now - 3600 and t[1][7] is None and t[1][5] == "3 hours", t
# ↵ on the 回收 row: y/N first (one key), then fleet-view-reap-all.sh <fleet> <every target>
a = fv.ACTION["reapall"]
assert fv.act_ask(a, ra["row"]) == "key" and a.get("yes") and "回收这 2 个" in a["prompt"](ra["row"]), a
rc, said, went = fv.act_run(None, "v1", "fl", a, ra["row"], "y")
assert rc == 0 and not went and "回收了 2 个" in said, (rc, said)
assert Path(os.environ["KLOG"]).read_text().splitlines() == ["reap-all|fl @8 @9"], Path(os.environ["KLOG"]).read_text()
assert fv.ACTION["history"]["local"]({}, "", "fl") == "history"
assert "reapall" in fv.ROWLESS and "history" in fv.ROWLESS
PYK
mkdir -p "$W/kconf"
( KLOG="$W/k.log" FLEET_VIEW_ACT_BIN="$W/kstub" FLEET_UI_LANG=zh python3 "$W/leg-k.py" "$BIN" "$W/kconf" ) \
  || st_fail "K: 排队中's 收起 line / 已收起"
# the helper itself: each target through dash-reap.sh --yes, one line for the person
mkdir -p "$W/kreap"
cp "$BIN/fleet-view-reap-all.sh" "$BIN/fleet-ui-lang.sh" "$W/kreap/"
cat > "$W/kreap/dash-reap.sh" <<'EOF'
printf 'dash-reap|%s\n' "$*" >> "$KLOG2"
case "$1" in
  @8) echo reaped:full ;;
  @9) echo reaped:keep ;;
  @7) echo 'agent still working' >&2; echo skip:live; exit 3 ;;
esac
EOF
cat > "$W/kreap/fleet-row-remote.sh" <<'EOF'
printf 'remote|%s\n' "$*" >> "$KLOG2"
echo '✓ reaped'
EOF
out=$(KLOG2="$W/k2.log" FLEET_UI_LANG=zh bash "$W/kreap/fleet-view-reap-all.sh" fl @8 @9 @7 wid:u/f1); rc=$?
[ "$rc" = 0 ] || st_fail "K: reap-all rc $rc: $out"
[ "$out" = "回收了 2 个 · 1 个有未提交改动：窗口已关，worktree 保留 · 1 个没收（还在忙或要确认） — agent still working" ] \
  || st_fail "K: reap-all said: $out"
[ "$(cat "$W/k2.log")" = "$(printf 'dash-reap|@8 --yes\ndash-reap|@9 --yes\ndash-reap|@7 --yes\nremote|reap fl wid:u/f1')" ] \
  || st_fail "K: reap-all calls: $(cat "$W/k2.log")"
# the history rows carry the close time only when asked (every other reader byte for byte)
grep -qF '[ "${FLEET_HISTORY_EPOCH:-0}" = 1 ] && lbuf+="${US}${ep:-}"' "$BIN/fleet-history.sh" \
  || st_fail "K: fleet-history.sh rows no longer appends the close time under FLEET_HISTORY_EPOCH"
grep -qF 'FLEET_HISTORY_EPOCH="1"' "$BIN/fleet_view.py" || st_fail "K: the 已回收 read does not ask for the close time"
st_ok_all "K  排队中's 已结束 rows (收起这 N 个 → fleet-view-reap-all.sh) above 已收起 (last 7 days, 更早的 N 个 → /fleet-history), folded (#3731)"

echo "fleet-view-selftest: all passed"
