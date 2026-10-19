#!/bin/bash
# fleet-view-c7-selftest.sh — ⌘N ⌘T ⌃\ ⌘Q and `fleet ls / open / claude` on the
# thin path (issue #3004, EPIC #2999 C7).
#
# Isolated sockets only, as fleet-view-selftest.sh: an INNER server is the home
# machine (a fleet session `fl` + a 看台 `fl@view-v1` grouped onto it, key-table
# fleet-view), an OUTER server is the person's terminal — its panes `tmux attach`
# to the inner one, so a byte sent into an outer pane is a key typed on the
# client, and capture-pane of the outer pane is what the person sees. A second
# outer pane attaches to `fl` DIRECTLY: every key there must do nothing of ours.
#
#   N  ⌘N (fleet-quickopen.py do new / fleet_view.go_new, issue #3119): a NEW
#      session every press — dash-raw-session.sh --origin hub --no-repo --no-desk
#      --print <fleet> (FLEET_VIEW_NEW_CMD) — once, never `--warm-only` (the warm
#      pool is gone, T495) — the 看台 onto the window it printed
#      (logged how=new) — never the window holding the orchestrator, even with
#      orch_<fleet> naming one, and no orchestrator script run at all
#      (FLEET_VIEW_ORCH_CMD would leave a mark); a direct attach: nothing;
#      each ⌘N one run in timing/session.ndjson (#3551): start · go · total
#   T  ⌘T and ⌘K, keys issue #3328 folded into ⌘P: the panel (its first
#      frame one run in timing/panel.ndjson, #3551) — ⌘T lit on
#      its ⚡ row, no 派一件事 popup — saying 「⌘T 已并进 ⌘P」 the first time only;
#      each press logged how=old:<action>, counted by fleet_keys.old_presses (the
#      doctor's oldkeys row); `send --agent codex` still carries; a direct attach: nothing
#   S  ⌃\: the session's shell — here: a window of the 看台 (@view_shell, panel,
#      @peer_view) whose shell's directory is the session's @worktree; ⌃\ again is
#      back on the session, ⌃\ there selects the same one (one a session); the
#      session's window gone takes its shell along. Another machine's: a channel
#      on C5's link (`ssh -S <link> -l <login> mac-a … shell-here <wid>`), its prompt
#      in the far worktree. A direct attach: no shell window. Issue #3183: in ⌘P,
#      ⌃\ on a lit row opens THAT session's shell though it is not on screen, in
#      the directory its agent is in (@agent_cwd — its last Bash call's cwd — else
#      the agent pane's: cd'd into bin/ → …/bin; both gone → @worktree; `do shell
#      --target <window | fleet_id>`), ⌘P from the
#      shell lights its session (↵ back), a second ⌃\ selects the one open, and
#      `exit` closes the shell window alone — the session's window, its
#      @claude_state and its process unchanged
#   P  ⌘P's one entry (issue #3327, EPIC #3178 ④ — 方案 B; #3180 before it): the
#      search line is the only input; under the sessions ONE ⚡ row (「⚡ 新会话（空白）」
#      on no words, 「⚡ 新任务：<字>」 on words) with its cells 仓库 ‹…› · Agent ‹…›
#      (codex grey with why), then ⏻ 退出 — no other command row; FLEET_PANEL_COMMANDS
#      `none` takes them away, the retired `shell` / `newsess` make none (`view-panel`).
#      Opened: the session in view lit, ↑ 到 ⚡ in the keys. Words that hit light the
#      session (keys 「↵ 切到 #N  ↓ 到 ⚡ 派「…」」), ↓ is ⚡, Tab walks 仓库 → Agent, ←→
#      changes them, ↵ sends to the repo picked. Words that hit nothing light ⚡ with
#      「没有会话叫这句话」; ↵ is ONE `fleet-quick-dispatch.py send`
#      (FLEET_DISPATCH_SEND_CMD) of the words to the last repo, the row its progress
#      (开工中… · 派单中，esc 可以先关) — esc closes the panel and the send still lands.
#      No words: ↑ goes round to ⚡, ↵ = ⌘N's argv, the 看台 on it; words with 不绑仓库
#      = a session here, `--prompt <the words>`; ⏻ = ⌘Q's OSC 7502 + detach
#   I  ⌘P's language row (issue #3329, EPIC #3178 D7): 语言 lights 「◐ 语言 / Language」,
#      ↵ flips to English — kept on the hub (a seam) and re-read here at once, the
#      panel redrawn in it with a 3 s line — Tab's 跟系统走 takes it back; none
#      said ⇒ 中文 and the Termius line (D9). FLEET_VIEW_LANG_EVIDENCE=<prefix>
#      keeps the two screens.
#   Q  ⌘Q: `ESC ] 7502 ; quit ; token=<the row's> BEL` on the client's tty, then
#      the client detached; a direct attach stays
#   L  `fleet ls` with no client tmux: one ssh to the home (fleet-thin.py --run:
#      ControlMaster=no, ControlPath=none, -T) running `fleet-session-cli.py --home
#      ls` — two machines' sessions listed; `--home open` moves the newest live 看台
#   C  `fleet claude` with FLEET_CLIENT=thin: the home's fleet-client-place.sh
#      `- home --agent claude` over --run, then the thin client onto the worker id
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }
command -v tmux >/dev/null 2>&1 || { echo "SKIP: no tmux"; exit 0; }
W=$(mktemp -d "${TMPDIR:-/tmp}/fview7.XXXXXX") || exit 1
IN="$W/in.sock"; OUT="$W/out.sock"
cleanup() {
  [ -n "${FLEET_VIEW_KEEP:-}" ] && { echo "kept: $W" >&2; return; }
  for s in "$IN" "$OUT"; do tmux -S "$s" kill-server 2>/dev/null; done
  rm -rf "$W"
}
trap cleanup EXIT INT TERM
mkdir -p "$W/wt-gamma/bin" "$W/wt-delta/gone" "$W/conf/remote-views/v1.d" "$W/conf/peerlink" "$W/g" "$W/home" "$W/state" "$W/wt-alpha" "$W/farwt" "$W/rbin"
ME=$(id -un)
US=$'\037'
T=$'\t'
UU=11111111-2222-3333-4444-555555555555; MU=22222222-3333-4444-5555-666666666666
ti() { tmux -S "$IN" "$@"; }
to() { tmux -S "$OUT" "$@"; }
cur() { ti display-message -p -t 'fl@view-v1:' '#{window_id}'; }
waitfor() {   # <secs*4> <cmd…> — until the command succeeds
  local n=$1; shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.25; n=$((n - 1)); done
  return 1
}

# --- the seams the home machine's keys run through ------------------------------
# ⌘N: dash-raw-session.sh's stand-in — its argv kept, a window opened, the
# --print receipt (`<window_id>\t<name>\t<worktree>\t<fleet_id>`) back
cat > "$W/newsess.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> '$W/new.argv'
n=\$(wc -l < '$W/new.argv' | tr -d ' ')
w=\$(tmux -S '$IN' new-window -d -P -F '#{window_id}' -t fl -n "new\$n" 'sleep 600') || exit 1
printf '%s\tnew%s\t\tfid%s\n' "\$w" "\$n" "\$n"
EOF
# an orchestrator script, should anything still call one: it leaves a mark
cat > "$W/ensure.sh" <<EOF
#!/bin/sh
: > '$W/orch.called'
exit 1
EOF
# ⌘T's send: the payload kept, one filed line back
cat > "$W/send.sh" <<EOF
#!/bin/sh
[ -e '$W/slow' ] && sleep 3
cp "\$1" '$W/sent.json'
echo x >> '$W/send.calls'
echo 'REMOTE mac-a start done $MU/new9	filed: #77'
EOF
# C5's link to mac-a: a fake ssh — `select` answers at once, anything else is the far
# shell: its argv kept, a shell in the far worktree
cat > "$W/fakessh.sh" <<EOF
#!/bin/sh
for a in "\$@"; do case "\$a" in *'fleet-remote-view.sh select'*) exit 0 ;; esac; done
printf '%s\n' "\$@" > '$W/ssh.argv'
cd '$W/farwt' && exec /bin/sh -i
EOF
chmod +x "$W/ensure.sh" "$W/newsess.sh" "$W/send.sh" "$W/fakessh.sh"
: > "$W/conf/peerlink/mac-a.sock"
printf '{"links":[{"machine":"mac-a","login":"%s","phase":"up","sock":"%s","host":"mac-a"}]}\n' "$ME" "$W/conf/peerlink/mac-a.sock" \
  > "$W/conf/peerlink/state.json"
printf 'acme/app\nacme/web\n' > "$W/g/hub_repos"
: > "$W/rows.txt"

export HOME="$W/home" FLEET_CONF_DIR="$W/conf" FLEET_STATUS_G="$W/g" FLEET_UI_LANG=zh LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  FLEET_VIEW_ORCH_CMD="sh $W/ensure.sh" FLEET_VIEW_NEW_CMD="sh $W/newsess.sh" FLEET_DISPATCH_SEND_CMD="sh $W/send.sh" FLEET_DISPATCH_AGENTS_HERE=claude \
  FLEET_SWITCH_STATE="$W/state" FLEET_AGENT=claude FLEET_SESSION_SHELL_WATCH=1 FLEET_PEERLINK_SSH="$W/fakessh.sh" \
  SHELL=/bin/sh FLEET_VIEW_ROWS_CMD="cat '$W/rows.txt'"
unset TMUX TMUX_PANE FLEET_SHELL FLEET_SESSION FLEET_CLIENT
# C7's keys are a person's to add since issue #3185 (by default only the panel)
export FLEET_KEYS_EXTRA='next=cmd+down prev=cmd+up back=cmd+[ fwd=cmd+] new=cmd+n dispatch=cmd+t quit=cmd+q shell=ctrl+\\'
export FLEET_KEYS_PHONE_EXTRA='ctrl+]n=next ctrl+]b=prev ctrl+]c=new ctrl+]t=dispatch ctrl+]q=quit ctrl+]\\=shell'

# --- the home: a fleet, a 看台, two clients ------------------------------------------------
# panes ignore ⌃\ (stty -isig) so a key that reaches one shows instead of killing it
pane() { printf "sh -c 'echo %s; stty -isig 2>/dev/null; exec cat > \"%s\"'" "$1" "$2"; }
ti -f /dev/null new-session -d -s fl -x 120 -y 30 -n orch "$(pane ORCH "$W/pane0.in")" || fail "inner tmux"
ti source-file "$ROOT/conf/tmux-view.conf" 2>"$W/src.err" || fail "tmux-view.conf did not source: $(cat "$W/src.err")"
W0=$(ti display-message -p -t 'fl:orch' '#{window_id}')
W1=$(ti new-window -d -P -F '#{window_id}' -t fl -n alpha -c "$W/wt-alpha" "$(pane ALPHA "$W/pane1.in")")
W2=$(ti new-window -d -P -F '#{window_id}' -t fl -n beta "$(pane BETA "$W/pane2.in")")
ti set-option -w -t "$W0" @fleet_role orchestrator
ti set-option -w -t "$W1" @fleet_id f1; ti set-option -w -t "$W1" @worktree "$W/wt-alpha"
ti set-option -w -t "$W2" @fleet_id f2
ti new-session -d -t fl -s 'fl@view-v1' || fail "no 看台 session"
ti set-option -t 'fl@view-v1' key-table fleet-view
ti select-window -t "=fl@view-v1:$W2"
printf '%s\tfl\tthin\t%s\t%s\tcur=%s/f2\troute=lan\tdevice=\ttoken=tok7\tfuid=%s\tnode=nodeA\n' \
  /dev/null "$(date +%s)" "$$" "$UU" "$UU" > "$W/conf/remote-views/v1"
to -f /dev/null new-session -d -s o -x 120 -y 32 -n view "TMUX= tmux -S '$IN' attach -t 'fl@view-v1'" || fail "outer tmux"
to new-window -d -t o -n direct "TMUX= tmux -S '$IN' attach -t fl"
sleep 1
[ "$(ti list-clients | wc -l | tr -d ' ')" = 2 ] || fail "the two clients did not attach: $(ti list-clients)"
nwin() { ti list-windows -t fl | wc -l | tr -d ' '; }

# --- N: ⌘N ----------------------------------------------------------------------------------
before=$(nwin); fcur=$(ti display-message -p -t 'fl:' '#{window_id}')
to send-keys -t o:direct -H 1b 5b 39 32 38 7e
sleep 1
[ "$(nwin)" = "$before" ] && [ "$(ti display-message -p -t 'fl:' '#{window_id}')" = "$fcur" ] \
  || fail "N: ⌘N did something in a session attached directly"
[ -s "$W/pane0.in" ] && fail "N: ⌘N's bytes reached a pane in a direct attach: $(od -c "$W/pane0.in" | head -2)"
# the orchestrator's holder here and orch_<fleet> naming another machine's: ⌘N
# goes to neither — a new session, every press
printf '%s\n' "$MU/orch4${US}mac-a${US}online${US}working${US}${US}" > "$W/g/orch_fl"
to send-keys -t o:view -H 1b 5b 39 32 38 7e
waitfor 20 sh -c "tmux -S '$IN' list-windows -t fl -F '#{window_name}' | grep -qx new1" || fail "N: ⌘N in the 看台 opened no new session"
N1=$(ti list-windows -t fl -F '#{window_id} #{window_name}' | awk '$2 == "new1" { print $1 }')
waitfor 16 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$N1' ]" \
  || fail "N: ⌘N did not land the 看台 on the new session (now $(cur), it is $N1)"
[ "$(cur)" != "$W0" ] || fail "N: ⌘N landed on the orchestrator's holder"
[ "$(head -1 "$W/new.argv")" = "--origin hub --no-repo --no-desk --print fl" ] \
  || fail "N: the new session was not asked as a no-repo one of this fleet: $(head -1 "$W/new.argv")"
grep -q -- '--warm-only' "$W/new.argv" && fail "N: ⌘N still asked for a warm window: $(cat "$W/new.argv")"
log="$W/conf/logs/view-switch.ndjson"
tail -1 "$log" | grep -q '"how":"new"' || fail "N: the switch is not logged how=new: $(tail -1 "$log")"
to send-keys -t o:view -H 1b 5b 39 32 38 7e
waitfor 20 sh -c "tmux -S '$IN' list-windows -t fl -F '#{window_name}' | grep -qx new2" || fail "N: a second ⌘N opened no second session"
N2=$(ti list-windows -t fl -F '#{window_id} #{window_name}' | awk '$2 == "new2" { print $1 }')
waitfor 16 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$N2' ]" \
  || fail "N: the second ⌘N did not land on its new session (now $(cur), it is $N2)"
[ -e "$W/orch.called" ] && fail "N: ⌘N ran an orchestrator script"
# the session clock (issue #3551): every ⌘N a run in timing/session.ndjson —
# start · go · total (a session starts cold since the warm pool left, T495)
waitfor 10 sh -c "python3 '$BIN/fleet_timing.py' check | grep -q '^session n=2 .* cold=0\$'" \
  || fail "N: the two ⌘N are not two session runs: $(python3 "$BIN/fleet_timing.py" check)"
python3 - "$FLEET_CONF_DIR/timing/session.ndjson" <<'PY' || fail "N: a ⌘N's run is not start · go · total"
import json, sys
runs = {}
for line in open(sys.argv[1]):
    r = json.loads(line)
    assert set(r) == {"ts", "what", "seg", "ms"} and r["what"] == "session", r
    runs.setdefault(r["ts"], []).append(r["seg"])
sys.exit(0 if all(v == ["start", "go", "total"] for v in runs.values()) else 1)
PY
rm -f "$W/g/orch_fl"
# another machine's C4 window (made here, link up) — the S and Q legs use it
PW=$(ti new-window -d -P -F '#{window_id}' -t fl -n @mac-a 'sleep 600')
for o in "@fleet_role panel" "@peer mac-a@$ME" "@peer_view v1" "@peer_node mac-a" "@peer_login $ME" "@peer_cur wid:$MU/far1"; do
  ti set-option -w -t "$PW" ${o%% *} "${o#* }"
done
pass "N  ⌘N: a new no-repo session every press, the 看台 on it — never the orchestrator's holder, no orchestrator script; a direct attach: nothing"

# --- T: ⌘T and the other keys issue #3328 took away ------------------------------------------
# ⌘T's 派一件事 popup has no entry any more: ⌘T (even as the person's own extra,
# dispatch=cmd+t) opens the panel lit on its ⚡ row; a key that went (⌘K here — no
# extra names it, so it is the default forward) opens the panel too. Each says
# 「<key> 已并进 ⌘P」 the first time only, and every press is a line how=old:<action>
# that fleet_keys.old_presses — the doctor's `oldkeys` row — counts.
to send-keys -t o:direct -H 1b 5b 39 33 32 7e
sleep 1.5
to capture-pane -p -t o:direct | grep -q '⚡' && fail "T: ⌘T opened the panel in a direct attach"
log="$W/conf/logs/view-switch.ndjson"
to send-keys -t o:view -H 1b 5b 39 33 32 7e
ok=''; for _ in $(seq 1 20); do
  sleep 0.4; to capture-pane -p -t o:view > "$W/dispatch.txt"; grep -q '已并进 ⌘P' "$W/dispatch.txt" && { ok=1; break; }
done
[ -n "$ok" ] || fail "T: ⌘T in the 看台 did not open the panel saying 「⌘T 已并进 ⌘P」: $(cat "$W/dispatch.txt")"
grep -q '  ⚡ 新会话（空白）' "$W/dispatch.txt" || fail "T: ⌘T's panel is not lit on ⚡: $(grep -v '^$' "$W/dispatch.txt")"
grep -qF '⌘T 已并进 ⌘P' "$W/dispatch.txt" || fail "T: the hint does not name ⌘T: $(grep '已并进' "$W/dispatch.txt")"
grep -q '用哪个 Coding Agent' "$W/dispatch.txt" && fail "T: ⌘T still opened the 派一件事 popup"
# the panel clock (issue #3551): the frame drawn ⇒ one run boot · read · frame · total
waitfor 10 sh -c "python3 '$BIN/fleet_timing.py' check | grep -q '^panel n=1 '" \
  || fail "T: the panel's first frame left no run in timing/panel.ndjson: $(python3 "$BIN/fleet_timing.py" check)"
python3 "$BIN/fleet_timing.py" table panel | grep -q '^| frame | ' || fail "T: the panel run has no frame segment: $(python3 "$BIN/fleet_timing.py" table panel)"
[ -n "${FLEET_VIEW_EVIDENCE:-}" ] && cp "$W/dispatch.txt" "$FLEET_VIEW_EVIDENCE"
to send-keys -t o:view Escape; sleep 0.8
to send-keys -t o:view -H 1b 5b 39 33 32 7e
waitfor 20 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q '  ⚡'" || fail "T: a second ⌘T opened no panel"
sleep 0.4; to capture-pane -p -t o:view | grep -q '已并进' && fail "T: the second ⌘T said 「已并进 ⌘P」 again"
to send-keys -t o:view Escape; sleep 0.8
to send-keys -t o:view -H 1b 5b 39 33 30 7e
waitfor 20 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -qF '⌘K 已并进 ⌘P'" || fail "T: ⌘K (code 930) did not open the panel saying 「⌘K 已并进 ⌘P」: $(to capture-pane -p -t o:view)"
to send-keys -t o:view Escape; sleep 0.8
[ "$(grep -c '"how":"old:dispatch"' "$log")" = 2 ] || fail "T: two ⌘T are not two how=old:dispatch lines: $(grep old: "$log")"
grep -q '"how":"old:switcher","key":"⌘K"' "$log" || fail "T: ⌘K is not logged how=old:switcher: $(grep old: "$log")"
[ "$(PYTHONPATH="$BIN" python3 -c 'import fleet_keys,sys; print(fleet_keys.old_presses(sys.argv[1]))' "$log")" = "3 ⌘T 2 · ⌘K 1" ] \
  || fail "T: old_presses does not count them: $(PYTHONPATH="$BIN" python3 -c 'import fleet_keys,sys; print(fleet_keys.old_presses(sys.argv[1]))' "$log")"
grep -q 'fleet_keys.old_presses' "$BIN/fleet-doctor.sh" || fail "T: the doctor's oldkeys row does not read fleet_keys.old_presses"
# the one message after the update (fleet-remote-view.sh attach --thin runs view-notice):
# on the 看台's client once, then never again on this login
TMUX="$IN,0,0" python3 "$BIN/fleet-quickopen.py" view-notice --view fl@view-v1 || fail "T: view-notice exited non-zero"
[ -s "$W/conf/keys-notice-3328" ] || fail "T: view-notice left no mark — it would say it at every attach"
grep -q 'view-notice --view' "$BIN/fleet-remote-view.sh" || fail "T: attach --thin does not run view-notice"
# ⌘T's send itself is ⌘P's ⚡ (leg P); `send` keeps its --agent
python3 "$BIN/fleet-quick-dispatch.py" send --title '看日志' --repo acme/web --agent codex --view fl@view-v1 >/dev/null \
  || fail "T: send --agent codex --view exited non-zero"
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("agent"))' "$W/sent.json")" = codex ] \
  || fail "T: --agent codex did not ride the payload: $(cat "$W/sent.json")"
rm -f "$W/sent.json"
pass "T  ⌘T / ⌘K (#3328): the panel — ⌘T lit on ⚡ — 「已并进 ⌘P」 once, each press how=old:<action> for the doctor; no 派一件事 popup; nothing in a direct attach"

# --- S: ⌃\ -----------------------------------------------------------------------------------
ti select-window -t "=fl@view-v1:$W1"; sleep 0.3
before=$(nwin)
to send-keys -t o:direct 'C-\'
sleep 1
[ "$(nwin)" = "$before" ] || fail "S: ⌃\\ opened a window from a direct attach"
to send-keys -t o:view 'C-\'
waitfor 20 sh -c "tmux -S '$IN' list-windows -t fl -F '#{@view_shell}' | grep -qx 'nodeA@$ME:$W1'" \
  || fail "S: ⌃\\ on alpha made no shell window: $(ti list-windows -t fl -F '#{window_id} #{@view_shell}')"
SW=$(ti list-windows -t fl -F "#{window_id} #{@view_shell}" | awk -v k="nodeA@$ME:$W1" '$2 == k { print $1 }')
[ "$(cur)" = "$SW" ] || fail "S: the 看台 is not on the shell window ($(cur))"
[ "$(ti display-message -p -t "$SW" '#{@fleet_role}|#{@peer_view}')" = "panel|v1" ] || fail "S: the shell window's marks: $(ti display-message -p -t "$SW" '#{@fleet_role}|#{@peer_view}')"
sleep 1; to send-keys -t o:view -l 'echo "AT=$(pwd)"'; to send-keys -t o:view Enter
waitfor 20 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q 'AT=.*wt-alpha'" \
  || fail "S: the shell is not in the session's worktree: $(to capture-pane -p -t o:view | tail -5)"
to send-keys -t o:view 'C-\'
waitfor 12 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$W1' ]" || fail "S: ⌃\\ in the shell is not back on alpha ($(cur))"
to send-keys -t o:view 'C-\'
waitfor 12 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$SW' ]" || fail "S: ⌃\\ on alpha again did not select its shell ($(cur))"
[ "$(ti list-windows -t fl -F '#{@view_shell}' | grep -c .)" = 1 ] || fail "S: a second shell window for one session"
[ -s "$W/pane1.in" ] && fail "S: ⌃\\ reached alpha's pane"
ti kill-window -t "$W1"
waitfor 24 sh -c "! tmux -S '$IN' list-windows -t fl -F '#{window_id}' | grep -qx '$SW'" || fail "S: alpha gone, its shell stayed"
# another machine's: the mac-a window, on far1
ti select-window -t "=fl@view-v1:$PW"; ti set-option -w -t "$PW" @peer_cur "wid:$MU/far1"; sleep 0.3
to send-keys -t o:view 'C-\'
waitfor 20 sh -c "tmux -S '$IN' list-windows -t fl -F '#{@view_shell}' | grep -qx 'mac-a@$ME:$MU/far1'" \
  || fail "S: ⌃\\ on mac-a's session made no shell window: $(ti list-windows -t fl -F '#{window_id} #{@view_shell}')"
waitfor 20 test -s "$W/ssh.argv" || fail "S: no ssh on the link for mac-a's shell"
argv=$(tr '\n' ' ' < "$W/ssh.argv")
for want in "-S $W/conf/peerlink/mac-a.sock" "ControlMaster=no" "-tt" "-l $ME" " mac-a " "fleet-remote-view.sh shell-here $MU/far1"; do
  case " $argv " in *"$want"*) ;; *) fail "S: mac-a's shell ssh lacks 「${want}」: $argv" ;; esac
done
sleep 0.5; to send-keys -t o:view -l 'echo "AT=$(pwd)"'; to send-keys -t o:view Enter
waitfor 20 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q 'AT=.*farwt'" \
  || fail "S: mac-a's shell is not in its worktree: $(to capture-pane -p -t o:view | tail -5)"
# issue #3183: ⌃\ on a lit row of ⌘P — gamma, not on screen, its agent in bin/
# (the cd runs in the pane's own process: tmux reads the cwd of the pane's
# foreground process group LEADER, and dash keeps a `sh -c` wrapper as that)
W3=$(ti new-window -d -P -F '#{window_id}' -t fl -n gamma "cd '$W/wt-gamma/bin' && stty -isig 2>/dev/null; exec cat > '$W/pane3.in'")
ti set-option -w -t "$W3" @fleet_id f3; ti set-option -w -t "$W3" @worktree "$W/wt-gamma"; ti set-option -w -t "$W3" @claude_state working
row() { local IFS="$US"; printf '%s\n' "$*"; }
row "$W3" working x gamma ' ' '' 0 '' '' '#33' - 50% ok 'Gamma task' merged '' '' '' '' > "$W/rows.txt"
P3=$(ti display-message -p -t "$W3" '#{pane_pid}')
ti select-window -t "=fl@view-v1:$W2"; sleep 0.3
listed() { tmux -S "$OUT" capture-pane -p -t o:view | grep -q 'Gamma task'; }
to send-keys -t o:view -H 1b 5b 39 32 37 7e
waitfor 20 listed || fail "S: ⌘P listed no gamma: $(to capture-pane -p -t o:view)"
to send-keys -t o:view -l gamma; sleep 0.4; to send-keys -t o:view 'C-\'
waitfor 20 sh -c "tmux -S '$IN' list-windows -t fl -F '#{@view_shell}' | grep -qx 'nodeA@$ME:$W3'" \
  || fail "S: ⌃\\ on gamma's row made no shell for it: $(ti list-windows -t fl -F '#{window_id} #{@view_shell}') $(to capture-pane -p -t o:view | tail -3)"
SG=$(ti list-windows -t fl -F "#{window_id} #{@view_shell}" | awk -v k="nodeA@$ME:$W3" '$2 == k { print $1 }')
waitfor 12 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$SG' ]" || fail "S: the 看台 is not on gamma's shell ($(cur))"
sleep 1; to send-keys -t o:view -l 'echo "AT=$(pwd)"'; to send-keys -t o:view Enter
waitfor 20 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q 'AT=.*wt-gamma/bin'" \
  || fail "S: gamma's shell is not where its agent is (…/wt-gamma/bin): $(to capture-pane -p -t o:view | grep -v '^$'; ti display-message -p -t "$SG" 'mode=#{pane_in_mode} dead=#{pane_dead} cmd=#{pane_current_command} pid=#{pane_pid}'; ti capture-pane -p -t "$SG" | grep -v '^$')"
# ⌘P from the shell: its session lit — ↵ is back on gamma
to send-keys -t o:view -H 1b 5b 39 32 37 7e
waitfor 20 listed || fail "S: ⌘P from the shell listed nothing"
sleep 0.3
to capture-pane -p -t o:view | grep -q '  .*Gamma task' || fail "S: ⌘P in gamma's shell does not light gamma: $(to capture-pane -p -t o:view | grep -n 'Gamma task')"
to send-keys -t o:view Enter
waitfor 12 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$W3' ]" || fail "S: ↵ from the shell's ⌘P is not back on gamma ($(cur))"
# again from the panel: the one open, selected
to send-keys -t o:view -H 1b 5b 39 32 37 7e
waitfor 20 listed || fail "S: ⌘P (again) listed no gamma"
to send-keys -t o:view -l gamma; sleep 0.4; to send-keys -t o:view 'C-\'
waitfor 12 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$SG' ]" || fail "S: a second ⌃\\ on gamma did not select its shell ($(cur))"
[ "$(ti list-windows -t fl -F '#{@view_shell}' | grep -cx "nodeA@$ME:$W3")" = 1 ] || fail "S: a second shell window for gamma"
# exit: the shell window alone goes
to send-keys -t o:view -l 'exit'; to send-keys -t o:view Enter
waitfor 20 sh -c "! tmux -S '$IN' list-windows -t fl -F '#{window_id}' | grep -qx '$SG'" || fail "S: exit left gamma's shell window"
ti list-windows -t fl -F '#{window_id}' | grep -qx "$W3" || fail "S: exit in the shell took gamma's window"
[ "$(ti display-message -p -t "$W3" '#{@claude_state}|#{pane_pid}|#{pane_dead}')" = "working|$P3|0" ] \
  || fail "S: gamma changed under its shell's exit: $(ti display-message -p -t "$W3" '#{@claude_state}|#{pane_pid}|#{pane_dead}') (was working|$P3|0)"
[ -s "$W/pane3.in" ] && fail "S: the shell sent keys to gamma's pane: $(od -c "$W/pane3.in" | head -2)"
# the cwd its last Bash call left (@agent_cwd) outranks the pane's; `do shell --target`
mkdir -p "$W/wt-gamma/lib"; ti set-option -w -t "$W3" @agent_cwd "$W/wt-gamma/lib"
TMUX="$IN,0,0" python3 "$BIN/fleet-quickopen.py" 'do' shell --view fl@view-v1 --target "$W3" || fail "S: do shell --target $W3 exited non-zero"
waitfor 20 sh -c "tmux -S '$IN' list-windows -t fl -F '#{@view_shell}' | grep -qx 'nodeA@$ME:$W3'" || fail "S: --target $W3 made no shell for gamma"
sleep 1; to send-keys -t o:view -l 'echo "AT=$(pwd)=="'; to send-keys -t o:view Enter
waitfor 20 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q 'AT=.*wt-gamma/lib=='" \
  || fail "S: gamma's @agent_cwd is not where its shell opened: $(to capture-pane -p -t o:view | grep -v '^$')"
to send-keys -t o:view -l 'exit'; to send-keys -t o:view Enter
# the agent's directory gone (and a stale @agent_cwd) → @worktree; `--target <bare fleet_id>`
W4=$(ti new-window -d -P -F '#{window_id}' -t fl -n delta "cd '$W/wt-delta/gone' && exec cat > /dev/null")
ti set-option -w -t "$W4" @fleet_id f4; ti set-option -w -t "$W4" @worktree "$W/wt-delta"; ti set-option -w -t "$W4" @agent_cwd "$W/nope"
sleep 0.3; rmdir "$W/wt-delta/gone"
TMUX="$IN,0,0" python3 "$BIN/fleet-quickopen.py" 'do' shell --view fl@view-v1 --target f4 || fail "S: do shell --target f4 exited non-zero"
waitfor 20 sh -c "tmux -S '$IN' list-windows -t fl -F '#{@view_shell}' | grep -qx 'nodeA@$ME:$W4'" || fail "S: --target f4 made no shell for delta"
sleep 1; to send-keys -t o:view -l 'echo "AT=$(pwd)=="'; to send-keys -t o:view Enter
waitfor 20 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q 'AT=.*wt-delta=='" \
  || fail "S: delta's agent directory gone, the shell is not in its @worktree: $(to capture-pane -p -t o:view | grep -v '^$'; ti list-windows -t fl -F '#{window_id} #{@view_shell} mode=#{pane_in_mode} cmd=#{pane_current_command}')"
pass "S  ⌃\\: the session's shell in its worktree (here; mac-a over the link's shell-here), ⌃\\ back and forth, one a session, gone with the session; nothing in a direct attach; ⌘P's ⌃\\ on a session off screen — where its agent is (@agent_cwd, else its pane's bin/, else @worktree), ↵ back from its shell, exit closes the shell alone (#3183)"

# --- P: anchored composer; existing placement routes (#4416) -------------------
vp() { TMUX="$IN,0,0" python3 "$BIN/fleet-quickopen.py" view-panel --view fl@view-v1 "$@"; }
ti select-window -t "=fl@view-v1:$W3"; sleep 0.3
vp > "$W/panel.txt" || fail "P: view-panel"
grep -qx "cmd${T}pin${T}置顶当前会话" "$W/panel.txt" || fail "P: plain pin row missing"
[ "$(tail -3 "$W/panel.txt" | cut -f1,2 | tr '\t\n' ': ')" = "cmd:new cmd:lang cmd:quit " ] || fail "P: command order"
grep -q '^grid' "$W/panel.txt" && fail "P: composer controls still inserted in list"
for word in 置顶 pin; do vp "$word" | grep -q "^cmd${T}pin" || fail "P: pin search"; done
for word in 语言 lang english 中文; do vp "$word" | grep -q "^cmd${T}lang" || fail "P: language search"; done
vp Gamma | grep -q "^cmd${T}lang" && fail "P: unrelated language row in search"
FLEET_PANEL_COMMANDS=none vp | grep -q '^cmd' && fail "P: none still has commands"
[ "$(FLEET_PANEL_COMMANDS='new shell newsess' vp | grep '^cmd' | cut -f2 | tr '\n' ' ')" = "pin new lang quit " ] || fail "P: retired commands"
# Each route case starts an independent draft; retention is covered in the native
# overlay selftest. Only this test's private conf is touched.
popen() {
  rm -rf "$W/conf/panel-drafts"
  to send-keys -t o:view -H 1b 5b 39 32 37 7e
  waitfor 20 listed || fail "P: panel did not open"
}
pcompose() {
  popen
  to send-keys -t o:view -l "$1"; sleep 0.3
  to send-keys -t o:view Enter
  waitfor 12 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q '开窗预填'" || fail "P: composer did not open"
  waitfor 48 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q '仓库 ‹acme/'" || fail "P: repositories did not load"
}
pclosed() { waitfor 20 sh -c "! tmux -S '$OUT' capture-pane -p -t o:view | grep -q '⚡'" || fail "P: panel stayed open"; }
: > "$W/send.calls"; rm -f "$W/sent.json"; : > "$W/slow"
pcompose '修 3164 的列表'
[ ! -s "$W/send.calls" ] || fail "P: opening composer dispatched"
to send-keys -t o:view Tab Tab Tab Enter
waitfor 12 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q '开窗中… 修 3164 的列表'" || fail "P: no progress"
to send-keys -t o:view Escape; sleep 0.2; to send-keys -t o:view Escape
pclosed
rm -f "$W/slow"
waitfor 40 test -s "$W/sent.json" || fail "P: send closed with panel"
sleep 0.5
[ "$(grep -c . "$W/send.calls")" = 1 ] || fail "P: duplicate send"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["title"]=="修 3164 的列表" and d["via"]=="dispatch" and d["repo"]=="acme/web" and d["draft"]==d["title"] and not d["body"] and not d["issue"], d' "$W/sent.json" || fail "P: payload"
# Search hit still enters the session; Down selects New, Tab explicitly opens it.
: > "$W/send.calls"; rm -f "$W/sent.json"
ti select-window -t "=fl@view-v1:$W3"; sleep 0.3
popen
to send-keys -t o:view -l Gamma; sleep 0.3
to send-keys -t o:view Down Tab; sleep 0.3
waitfor 48 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q '仓库 ‹acme/web›'" || fail "P: hit composer repo read"
to send-keys -t o:view Tab Left Tab Right; sleep 0.3
to capture-pane -p -t o:view > "$W/panel-grid.txt"
grep -q '仓库 ‹acme/app›' "$W/panel-grid.txt" && grep -q 'Agent ‹Claude›' "$W/panel-grid.txt" || fail "P: repo/agent selection: $(cat "$W/panel-grid.txt")"
to send-keys -t o:view Tab Enter
waitfor 20 test -s "$W/sent.json" || fail "P: explicit draft button sent nothing"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["title"]=="Gamma" and d["repo"]=="acme/app" and d["agent"]=="claude" and d["draft"]=="Gamma" and not d["body"], d' "$W/sent.json" || fail "P: picked repo"
pclosed
# Blank button keeps the draft, and uses the selected no-repo/agent route.
pcompose 'keep this draft'
to send-keys -t o:view Tab Left Tab Tab Tab Enter
waitfor 20 sh -c "tmux -S '$IN' list-windows -t fl -F '#{window_name}' | grep -qx new3" || fail "P: blank opened no session: $(to capture-pane -p -t o:view) $(cat "$W/new.argv")"
[ "$(sed -n 3p "$W/new.argv")" = "--origin hub --no-repo --agent claude --no-desk --print fl" ] || fail "P: blank argv: $(sed -n 3p "$W/new.argv")"
N3=$(ti list-windows -t fl -F '#{window_id} #{window_name}' | awk '$2 == "new3" { print $1 }')
waitfor 16 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$N3' ]" || fail "P: not on new3"
pclosed
python3 -c 'import json,pathlib,sys; ds=list(pathlib.Path(sys.argv[1]).glob("*.json")); assert len(ds)==1 and json.loads(ds[0].read_text())["text"]=="keep this draft"' "$W/conf/panel-drafts" || fail "P: blank consumed draft"
pcompose '看看日志'
to send-keys -t o:view Tab Left Tab Tab Enter
waitfor 20 sh -c "tmux -S '$IN' list-windows -t fl -F '#{window_name}' | grep -qx new4" || fail "P: no-repo draft opened no session"
[ "$(sed -n 4p "$W/new.argv")" = "--origin hub --no-repo --agent claude --draft 看看日志 --no-desk --print fl" ] || fail "P: no-repo argv: $(sed -n 4p "$W/new.argv")"
pclosed
# Quit still goes through OSC 7502 + detach.
to pipe-pane -o -t o:view "cat > '$W/client-p.bytes'"; sleep 0.3
popen
to send-keys -t o:view -l 'zzz'; sleep 0.3; to send-keys -t o:view Down Enter
waitfor 20 sh -c "! tmux -S '$IN' list-clients -F '#{session_name}' | grep -q 'view-v1'" || fail "P: quit did not detach"
sleep 0.3
python3 -c 'import sys; sys.exit(0 if b"\x1b]7502;quit;token=tok7\x07" in open(sys.argv[1],"rb").read() else 1)' "$W/client-p.bytes" || fail "P: quit OSC missing"
to new-window -d -t o -n view "TMUX= tmux -S '$IN' attach -t 'fl@view-v1'"; sleep 1
pass "P  composer opens without dispatch; explicit draft/blank buttons preserve the existing routes, agent, progress and quit"

# --- I: the language row (issue #3329, EPIC #3178 D7, L1–L3) --------------------------------
# The person's choice is kept on the hub (a seam: GET/PUT the state file) and read back
# at once into person-bundle.json; the 看台 said no language (FLEET_VIEW_LANG empty) ⇒
# Chinese, and the row's footer says how to bring one (D9). FLEET_UI_LANG auto here.
# The footer names this machine; a GitHub macOS runner's 60-odd-char hostname pushed
# the LANG= half past the popup's width (issue #3545), so the name is pinned short.
printf '{"version":1,"bundle":{}}' > "$W/person.json"
cat > "$W/person-hub.sh" <<EOF
#!/bin/sh
st='$W/person.json'; body=\$(cat)
[ "\$1" = GET ] && { cat "\$st"; exit 0; }
python3 -c '
import json, sys
b, st = json.loads(sys.argv[1]), sys.argv[2]
cur = json.load(open(st))
if b.get("base") != cur["version"]:
    print(json.dumps({"status": 409, "error": "stale"})); sys.exit()
new = {"version": cur["version"] + 1, "prev": cur["version"], "bundle": b["bundle"]}
json.dump(new, open(st, "w")); print(json.dumps(new))' "\$body" "\$st"
EOF
for k in FLEET_UI_LANG=auto FLEET_VIEW_LANG= FLEET_SIDEBAR_HOST=c7host "FLEET_PERSON_HUB_CMD=sh $W/person-hub.sh \"\$@\"" "FLEET_PERSON_BUNDLE_CMD=cat $W/person.json"; do
  ti set-environment -t 'fl@view-v1' "${k%%=*}" "${k#*=}"
done
lshot() { to capture-pane -p -t o:view | grep -v '^$'; }
to send-keys -t o:view -H 1b 5b 39 32 37 7e
waitfor 20 listed || fail "I: ⌘P listed nothing"
to send-keys -t o:view -l '语言'; sleep 0.5
waitfor 10 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q '  ◐ 语言 / Language　中文 ✓ · English'" \
  || fail "I: typing 语言 did not light the language row: $(lshot)"
lshot | grep -q 'Termius → Hosts' && fail "I: footer repeats selected row detail"
[ -n "${FLEET_VIEW_LANG_EVIDENCE:-}" ] && lshot > "$FLEET_VIEW_LANG_EVIDENCE.zh.txt"
to send-keys -t o:view Enter
waitfor 20 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q 'Language: English · saved to your account'" \
  || fail "I: ↵ did not switch to English and say so: $(lshot)"
lshot | grep -q '◐ Language / 语言　English ✓ · 中文' || fail "I: the panel did not redraw in English: $(lshot)"
[ -n "${FLEET_VIEW_LANG_EVIDENCE:-}" ] && lshot > "$FLEET_VIEW_LANG_EVIDENCE.en.txt"
grep -q '"ui_lang": *"en"' "$W/person.json" || fail "I: the hub was not told: $(cat "$W/person.json")"
grep -q '"ui_lang": *"en"' "$W/conf/person-bundle.json" || fail "I: this computer's copy was not re-read: $(cat "$W/conf/person-bundle.json" 2>&1)"
[ "$(FLEET_VIEW_LANG=en_US.UTF-8 FLEET_UI_LANG=auto sh "$BIN/fleet-ui-lang.sh" first-hint devX)" = "" ] \
  || fail "I: a person who chose is still told about detection (D8)"
waitfor 24 sh -c "! tmux -S '$OUT' capture-pane -p -t o:view | grep -q 'Language: English · saved'" || fail "I: the confirmation did not go by itself (3 s): $(lshot)"
# Tab: 中文 · English · Follow the system — the last takes the choice away
to send-keys -t o:view Tab; sleep 0.4
lshot | grep -q 'Follow the system' || fail "I: Tab on the row offers no 跟系统走: $(lshot)"
to send-keys -t o:view Down; sleep 0.1; to send-keys -t o:view Down; sleep 0.1; to send-keys -t o:view Enter
waitfor 20 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q '界面语言：跟系统走 · 已存到你的账号'" \
  || fail "I: 跟系统走 did not go back to the detected language (中文, none said): $(lshot)"
grep -q 'ui_lang' "$W/person.json" && fail "I: 跟系统走 left ui_lang on the hub: $(cat "$W/person.json")"
to send-keys -t o:view Escape
for k in FLEET_UI_LANG FLEET_VIEW_LANG FLEET_PERSON_HUB_CMD FLEET_PERSON_BUNDLE_CMD; do ti set-environment -t 'fl@view-v1' -u "$k"; done
rm -f "$W/conf/person-bundle.json" "$W/conf/person-bundle.good.json"
pass "I  ⌘P's language row: 语言 finds it, ↵ flips to English on the hub and here at once (the panel redraws, 3 s line), Tab 跟系统走 takes it back; no language said ⇒ 中文 + the Termius line (#3329)"

# --- Q: ⌘Q -----------------------------------------------------------------------------------
to pipe-pane -o -t o:view "cat > '$W/client.bytes'"; sleep 0.3
to send-keys -t o:direct -H 1b 5b 39 33 31 7e
sleep 1
ti list-clients -F '#{session_name}' | grep -qx fl || fail "Q: ⌘Q detached a direct attach"
to send-keys -t o:view -H 1b 5b 39 33 31 7e
waitfor 20 sh -c "! tmux -S '$IN' list-clients -F '#{session_name}' | grep -q 'view-v1'" || fail "Q: ⌘Q did not detach the 看台's client"
sleep 0.3
grep -q $'\033\\]7502;quit;token=tok7\a' "$W/client.bytes" 2>/dev/null \
  || python3 -c 'import sys; sys.exit(0 if b"\x1b]7502;quit;token=tok7\x07" in open(sys.argv[1],"rb").read() else 1)' "$W/client.bytes" \
  || fail "Q: no OSC 7502 quit with the row's token reached the client: $(od -c "$W/client.bytes" | tail -5)"
pass "Q  ⌘Q: OSC 7502 quit (the row's token) on the client's tty, then detached; a direct attach stays"

# --- L: fleet ls / open with no client tmux --------------------------------------------------
T=$'\t'
{
  printf '%s\n' "wid:$MU/issue-12${T}needs${T}!${T}登录页重做${T}mac-a${T}acme/web (2)${T}${T}#12${T}—${T}merged${T}登录页重做${T}acme/web"
  printf '%s\n' "$W2${T}working${T}●${T}样式${T}nodeA${T}acme/web (2)${T}${T}#13${T}—${T}done:2h${T}${T}acme/web"
} > "$W/rows.tsv"
cat > "$W/argv.sh" <<EOF
#!/bin/sh
printf '{"argv": ["sh", "$W/homessh.sh", "homebox"], "host": 2, "route": "lan"}\n'
EOF
# the home: one ssh — its options kept, the command run here with the home's rows
cat > "$W/homessh.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$@" > '$W/home.argv'
for last; do :; done
FLEET_SESSION_CLI_ROWS='$W/rows.tsv' FLEET_SESSION_CLI_CACHE= exec sh -c "\$last"
EOF
out=$(FLEET_SESSION_CLI_ROAD=home FLEET_THIN_ARGV_CMD="sh $W/argv.sh" FLEET_REMOTE_BIN="$BIN" FLEET_THIN_LOG="$W/thin.log" \
  python3 "$BIN/fleet-session-cli.py" ls </dev/null 2>&1) || fail "L: fleet ls over the home exited non-zero: $out"
for want in 登录页重做 样式 mac-a nodeA; do
  case "$out" in *"$want"*) ;; *) fail "L: fleet ls lacks 「${want}」: $out" ;; esac
done
hargv=$(tr '\n' ' ' < "$W/home.argv")
for want in "ControlMaster=no" "ControlPath=none" "-T" "homebox" "fleet-session-cli.py --home ls"; do
  case " $hargv " in *"$want"*) ;; *) fail "L: the one-shot ssh lacks 「${want}」: $hargv" ;; esac
done
grep -q "${T}run${T}" "$W/thin.log" || fail "L: thin.log has no run line: $(cat "$W/thin.log")"
[ -n "${FLEET_VIEW_LS_EVIDENCE:-}" ] && printf '%s\n' "$out" > "$FLEET_VIEW_LS_EVIDENCE"
# --home open: the newest live 看台 here goes there (its client gone after ⌘Q: re-attach)
to new-window -d -t o -n view2 "TMUX= tmux -S '$IN' attach -t 'fl@view-v1'"; sleep 1
ti select-window -t "=fl@view-v1:$PW"
TMUX="$IN,0,0" FLEET_SESSION_CLI_ROWS="$W/rows.tsv" FLEET_SESSION_CLI_CACHE='' \
  python3 "$BIN/fleet-session-cli.py" --home open 样式 >/dev/null 2>&1 || fail "L: --home open exited non-zero"
[ "$(cur)" = "$W2" ] || fail "L: --home open did not move the 看台 to beta ($(cur))"
pass "L  fleet ls with no client tmux: one ssh to the home (no master), two machines' sessions; --home open moves the 看台"

# --- C: fleet claude, thin -------------------------------------------------------------------
cat > "$W/rbin/fleet-client-place.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$@" > '$W/place.argv'
printf 'REMOTE mac-a start done %s\tok\n' '$MU/home1'
EOF
cat > "$W/claude.sh" <<EOF
#!/bin/sh
cd '$BIN' && FLEET_CLIENT=thin FLEET_THIN_ARGV_CMD="sh $W/argv.sh" FLEET_REMOTE_BIN='$W/rbin' FLEET_THIN_LOG='$W/thin.log' \
  FLEET_HOME_THIN_CMD='printf "%s\n" "\$@" > $W/thin.want' bash '$BIN/fleet-home-session.sh' claude
echo "rc=\$?" > '$W/claude.rc'
EOF
to new-window -d -t o -n claude "sh '$W/claude.sh'"
waitfor 40 test -s "$W/claude.rc" || fail "C: fleet claude did not finish"
[ "$(cat "$W/claude.rc")" = rc=0 ] || fail "C: fleet claude: $(cat "$W/claude.rc")"
[ "$(cat "$W/thin.want" 2>/dev/null)" = "$MU/home1" ] || fail "C: the thin client was not pointed at the new session: $(cat "$W/thin.want" 2>/dev/null)"
pargs=$(tr '\n' ' ' < "$W/place.argv")
case "$pargs" in "- home --agent claude "*) ;; *) fail "C: the home's place: $pargs" ;; esac
pass "C  fleet claude (thin): the home places it (- home --agent claude), then fleet --thin <its worker id>"
echo "fleet-view-c7-selftest: all passed"
