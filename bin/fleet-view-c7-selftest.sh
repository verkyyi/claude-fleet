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
#   N  ⌘N (fleet-quickopen.py do new / fleet_view.go_orch): the orchestrator's
#      window here; another machine's (orch_<fleet> names it) through its C4
#      window (peer-select, logged how=new); none anywhere → fleet-orchestrator.sh
#      ensure (FLEET_VIEW_ORCH_CMD), then there; a direct attach: nothing
#   T  ⌘T: the 派一件事 popup in the 看台 — 用哪个 Coding Agent, the fleet's default
#      first, an agent this machine lacks grey with why; ↵ sends with no --agent
#      (the default), `send --agent codex` carries it; a direct attach: no popup
#   S  ⌃\: the session's shell — here: a window of the 看台 (@view_shell, panel,
#      @peer_view) whose shell's directory is the session's @worktree; ⌃\ again is
#      back on the session, ⌃\ there selects the same one (one a session); the
#      session's window gone takes its shell along. Another machine's: a channel
#      on C5's link (`ssh -S <link> -l <login> m4 … shell-here <wid>`), its prompt
#      in the far worktree. A direct attach: no shell window
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
mkdir -p "$W/conf/remote-views/v1.d" "$W/conf/peerlink" "$W/g" "$W/home" "$W/state" "$W/wt-alpha" "$W/farwt" "$W/rbin"
ME=$(id -un)
US=$'\037'
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
# ⌘N with no orchestrator anywhere: `ensure` opens one (a window with the role)
cat > "$W/ensure.sh" <<EOF
#!/bin/sh
[ "\$1" = ensure ] || exit 2
w=\$(tmux -S '$IN' new-window -d -P -F '#{window_id}' -t fl -n orch2 'sleep 600') || exit 1
tmux -S '$IN' set-option -w -t "\$w" @fleet_role orchestrator
echo "\$w"
EOF
# ⌘T's send: the payload kept, one filed line back
cat > "$W/send.sh" <<EOF
#!/bin/sh
cp "\$1" '$W/sent.json'
echo 'REMOTE m4 start done $MU/new9	filed: #77'
EOF
# C5's link to m4: a fake ssh — `select` answers at once, anything else is the far
# shell: its argv kept, a shell in the far worktree
cat > "$W/fakessh.sh" <<EOF
#!/bin/sh
for a in "\$@"; do case "\$a" in *'fleet-remote-view.sh select'*) exit 0 ;; esac; done
printf '%s\n' "\$@" > '$W/ssh.argv'
cd '$W/farwt' && exec /bin/sh -i
EOF
chmod +x "$W/ensure.sh" "$W/send.sh" "$W/fakessh.sh"
: > "$W/conf/peerlink/m4.sock"
printf '{"links":[{"machine":"m4","login":"%s","phase":"up","sock":"%s","host":"m4"}]}\n' "$ME" "$W/conf/peerlink/m4.sock" \
  > "$W/conf/peerlink/state.json"
printf 'acme/app\nacme/web\n' > "$W/g/hub_repos"

export HOME="$W/home" FLEET_CONF_DIR="$W/conf" FLEET_STATUS_G="$W/g" FLEET_UI_LANG=zh LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  FLEET_VIEW_ORCH_CMD="sh $W/ensure.sh" FLEET_DISPATCH_SEND_CMD="sh $W/send.sh" FLEET_DISPATCH_AGENTS_HERE=claude \
  FLEET_SWITCH_STATE="$W/state" FLEET_AGENT=claude FLEET_SESSION_SHELL_WATCH=1 FLEET_PEERLINK_SSH="$W/fakessh.sh" \
  SHELL=/bin/sh FLEET_VIEW_ROWS_CMD="true"
unset TMUX TMUX_PANE FLEET_SHELL FLEET_SESSION FLEET_CLIENT

# --- the home: a fleet, a 看台, two clients ------------------------------------------------
# panes ignore ⌃\ (stty -isig) so a key that reaches one shows instead of killing it
pane() { printf "sh -c 'echo %s; stty -isig 2>/dev/null; exec cat > \"%s\"'" "$1" "$2"; }
ti -f /dev/null new-session -d -s fl -x 120 -y 30 -n orch "$(pane ORCH "$W/pane0.in")" || fail "inner tmux"
ti source-file "$ROOT/conf/tmux-view.conf" 2>"$W/src.err" || fail "tmux-view.conf did not source: $(cat "$W/src.err")"
W0=$(ti display-message -p -t 'fl:orch' '#{window_id}')
W1=$(ti new-window -d -P -F '#{window_id}' -t fl -n alpha "$(pane ALPHA "$W/pane1.in")")
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
to send-keys -t o:view -H 1b 5b 39 32 38 7e
waitfor 16 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$W0' ]" \
  || fail "N: ⌘N in the 看台 did not land on the orchestrator here (now $(cur))"
log="$W/conf/logs/view-switch.ndjson"
tail -1 "$log" | grep -q '"how":"new"' || fail "N: the switch is not logged how=new: $(tail -1 "$log")"
# another machine holds it: orch_<fleet> names it; its C4 window (made here, link up)
PW=$(ti new-window -d -P -F '#{window_id}' -t fl -n @m4 'sleep 600')
for o in "@fleet_role panel" "@peer m4@$ME" "@peer_view v1" "@peer_node m4" "@peer_login $ME" "@peer_cur wid:$MU/far1"; do
  ti set-option -w -t "$PW" ${o%% *} "${o#* }"
done
ti set-option -w -u -t "$W0" @fleet_role
printf '%s\n' "$MU/orch4${US}m4${US}online${US}working${US}${US}" > "$W/g/orch_fl"
to send-keys -t o:view -H 1b 5b 39 32 38 7e
waitfor 16 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$PW' ]" \
  || fail "N: ⌘N with the orchestrator on m4 did not show m4's window (now $(cur))"
[ "$(ti display-message -p -t "$PW" '#{@peer_cur}')" = "wid:$MU/orch4" ] || fail "N: m4's window is not on its orchestrator: $(ti display-message -p -t "$PW" '#{@peer_cur}')"
tail -1 "$log" | grep -q '"method":"peer-select"' || fail "N: not one peer-select: $(tail -1 "$log")"
# none anywhere: ensure, then there
rm -f "$W/g/orch_fl"
to send-keys -t o:view -H 1b 5b 39 32 38 7e
waitfor 20 sh -c "tmux -S '$IN' list-windows -t fl -F '#{window_name}' | grep -qx orch2" || fail "N: no orchestrator anywhere → ensure was not run"
O2=$(ti list-windows -t fl -F '#{window_id} #{window_name}' | awk '$2 == "orch2" { print $1 }')
waitfor 16 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$O2' ]" \
  || fail "N: after ensure the 看台 is not on the new orchestrator (now $(cur), it is $O2)"
pass "N  ⌘N: the orchestrator here · on m4 through its window (peer-select) · none → ensure, then there; a direct attach: nothing"

# --- T: ⌘T ----------------------------------------------------------------------------------
to send-keys -t o:direct -H 1b 5b 39 33 32 7e
sleep 1.5
to capture-pane -p -t o:direct | grep -q '用哪个 Coding Agent' && fail "T: ⌘T opened the popup in a direct attach"
to send-keys -t o:view -H 1b 5b 39 33 32 7e
ok=''; for _ in $(seq 1 20); do
  sleep 0.4; to capture-pane -p -t o:view > "$W/dispatch.txt"; grep -q '用哪个 Coding Agent' "$W/dispatch.txt" && { ok=1; break; }
done
[ -n "$ok" ] || fail "T: ⌘T in the 看台 opened no 派一件事 popup: $(cat "$W/dispatch.txt")"
for want in '派一件事' '仓库' 'claude（默认）' "这台没装 codex"; do
  grep -qF "$want" "$W/dispatch.txt" || fail "T: the popup lacks 「${want}」: $(cat "$W/dispatch.txt")"
done
[ -n "${FLEET_VIEW_EVIDENCE:-}" ] && cp "$W/dispatch.txt" "$FLEET_VIEW_EVIDENCE"
to send-keys -t o:view -l '修登录页'; sleep 0.3
to send-keys -t o:view Tab; to send-keys -t o:view Tab; to send-keys -t o:view Right; sleep 0.3   # codex is grey: still claude
to send-keys -t o:view Enter
waitfor 20 test -s "$W/sent.json" || fail "T: ↵ sent nothing: $(to capture-pane -p -t o:view)"
python3 - "$W/sent.json" <<'PY' || fail "T: the payload: $(cat "$W/sent.json")"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["title"] == "修登录页" and d["via"] == "dispatch" and d["repo"] == "acme/app", d
assert d.get("agent") is None, d   # the default rides no --agent
PY
rm -f "$W/sent.json"
python3 "$BIN/fleet-quick-dispatch.py" send --title '看日志' --repo acme/web --agent codex --view fl@view-v1 >/dev/null \
  || fail "T: send --agent codex --view exited non-zero"
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("agent"))' "$W/sent.json")" = codex ] \
  || fail "T: --agent codex did not ride the payload: $(cat "$W/sent.json")"
pass "T  ⌘T: 派一件事 in the 看台 — the agent step (default claude, codex grey: not installed), ↵ sends, --agent carries; nothing in a direct attach"

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
# another machine's: the m4 window, on far1
ti select-window -t "=fl@view-v1:$PW"; ti set-option -w -t "$PW" @peer_cur "wid:$MU/far1"; sleep 0.3
to send-keys -t o:view 'C-\'
waitfor 20 sh -c "tmux -S '$IN' list-windows -t fl -F '#{@view_shell}' | grep -qx 'm4@$ME:$MU/far1'" \
  || fail "S: ⌃\\ on m4's session made no shell window: $(ti list-windows -t fl -F '#{window_id} #{@view_shell}')"
waitfor 20 test -s "$W/ssh.argv" || fail "S: no ssh on the link for m4's shell"
argv=$(tr '\n' ' ' < "$W/ssh.argv")
for want in "-S $W/conf/peerlink/m4.sock" "ControlMaster=no" "-tt" "-l $ME" " m4 " "fleet-remote-view.sh shell-here $MU/far1"; do
  case " $argv " in *"$want"*) ;; *) fail "S: m4's shell ssh lacks 「${want}」: $argv" ;; esac
done
sleep 0.5; to send-keys -t o:view -l 'echo "AT=$(pwd)"'; to send-keys -t o:view Enter
waitfor 20 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q 'AT=.*farwt'" \
  || fail "S: m4's shell is not in its worktree: $(to capture-pane -p -t o:view | tail -5)"
pass "S  ⌃\\: the session's shell in its worktree (here; m4 over the link's shell-here), ⌃\\ back and forth, one a session, gone with the session; nothing in a direct attach"

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
  printf '%s\n' "wid:$MU/issue-12${T}needs${T}!${T}登录页重做${T}m4${T}acme/web (2)${T}${T}#12${T}—${T}merged${T}登录页重做${T}acme/web"
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
for want in 登录页重做 样式 m4 nodeA; do
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
TMUX="$IN,0,0" FLEET_SESSION_CLI_ROWS="$W/rows.tsv" FLEET_SESSION_CLI_CACHE= \
  python3 "$BIN/fleet-session-cli.py" --home open 样式 >/dev/null 2>&1 || fail "L: --home open exited non-zero"
[ "$(cur)" = "$W2" ] || fail "L: --home open did not move the 看台 to beta ($(cur))"
pass "L  fleet ls with no client tmux: one ssh to the home (no master), two machines' sessions; --home open moves the 看台"

# --- C: fleet claude, thin -------------------------------------------------------------------
cat > "$W/rbin/fleet-client-place.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$@" > '$W/place.argv'
printf 'REMOTE m4 start done %s\tok\n' '$MU/home1'
EOF
cat > "$W/claude.sh" <<EOF
#!/bin/sh
cd '$BIN' && FLEET_CLIENT=thin FLEET_THIN_ARGV_CMD="sh $W/argv.sh" FLEET_REMOTE_BIN='$W/rbin' FLEET_THIN_LOG='$W/thin.log' \
  FLEET_DEBUG_PROMPT=0 FLEET_HOME_THIN_CMD='printf "%s\n" "\$@" > $W/thin.want' bash '$BIN/fleet-home-session.sh' claude
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
