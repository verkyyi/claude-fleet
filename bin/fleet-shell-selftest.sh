#!/bin/bash
# fleet-shell-selftest.sh — the fleet SHELL on a person's own computer (issue
# #1484, EPIC #1479 C5): bin/fleet-shell.sh, bin/fleet's dispatch into it,
# fleet-connect.py --pick, fleet-remote-view.sh `select` + the `@remote_ctl`
# retarget, fleet-hub-sessions.sh's client mode, tmux-status.sh's bar in the shell.
#
# Nothing real is reached: the hub is FLEET_HUB_SESSIONS_CMD (a fleet_sessions
# JSON with two machines, m5 and m4), `fleet-connect.py` is a FAKE beside a
# mirrored bin/ (it records its argv and prints a --pick answer), ssh is a shim
# (FLEET_REMOTE_SSH_CMD) that records the remote command instead of running it,
# and the shell's tmux server is its own isolated socket (`-L <session>`), killed
# at the end. The shell starts with FLEET_SHELL_NO_ATTACH=1 (no terminal here).
#   A. degenerate  — FLEET_SHELL=0: bare `fleet` goes to `fleet-connect.py --enter`
#                    exactly as before; no tmux on PATH: the same, plus ONE hint line
#                    on installing tmux; fleet-hub-sessions.sh without
#                    FLEET_HUB_SESSIONS_CLIENT lists the conf dir's fleets, not a
#                    pseudo-fleet
#   B. up          — bare `fleet` (tmux present) starts the shell: the hub's pick
#                    (m5) in the right pane as a `⇄m5` window (`@remote=m5:`), the
#                    LIST pane on its left, the far end asked for `attach --shell -`
#                    through the ssh shim, the environment set on the server, the
#                    conf-free mirror in place
#   C. data        — the client-mode loop writes remote_<sess> with EVERY row remote
#                    (local=0, #me empty, a #node line per machine, m5 included),
#                    hub_ok fresh; the row producer in the shell's environment lists
#                    the hub's rows and none of the shell's own windows
#   D. same machine— `open` on an m5 row with the pane's control socket answering:
#                    `select <wid>` goes over it, the window is retargeted
#                    (`@remote=m5:<wid>`), NO respawn, the list pane's id unchanged
#   E. other machine— `open` on an m4 row: a second window `⇄m4 <name>`, current;
#                    `jump` moves the SAME list pane into it; m5's window stays
#   F. bar         — tmux-status.sh with the shell's env and the m4 window's args
#                    renders hub mode: the m4 chip (online, off the #node line —
#                    no hub_nodes), 入口 ●; the window list is blanked
#   G. lost        — hub_ok aged past FLEET_HUB_SESSIONS_STALE: the rows are still
#                    listed (dimmed, `!`), the bar says 入口 ○ 失联
#   H. ssh mode    — `fleet-shell.sh ssh` turns a ControlMaster call into
#                    `fleet-connect.py --enter <host> -o … -- <cmd>` (ProxyCommand
#                    dropped, -tt → RequestTTY=force); a `-S … -O check` call is
#                    plain ssh; a host that is THIS computer runs the command here
#   I. select      — fleet-remote-view.sh `select` on a node: the worker's window
#                    becomes current in its fleet session; an unknown worker → 3
# tmux / python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { printf 'fleet-shell selftest: tmux absent — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'fleet-shell selftest: python3 absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fsh-st.XXXXXX")" || exit 2
SESS="fsh$$"                          # the shell's session = its socket label
NODE="fshN$$"                         # leg I: a fleet session standing in for a node
export HOME="$WORK/home"; mkdir -p "$HOME/.ssh" "$HOME/.config/claude-fleet"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
export FLEET_CONF_DIR="$HOME/.config/claude-fleet"
export FLEET_SHELL_SESSION="$SESS" FLEET_SHELL_CACHE="$WORK/cache"
export FLEET_REMOTE_BIN="$BIN" FLEET_REMOTE_VIA_HUB=0 FLEET_SHELL_NO_ATTACH=1
export FLEET_HUB_SESSIONS_LOOP_SECS=8 FLEET_HUB_SESSIONS_EVERY=1 FLEET_HUB_SESSIONS_WATCHED_EVERY=1
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_SESSION FLEET_SHELL FLEET_HUB_SESSIONS_CLIENT FLEET_SIDEBAR_SOURCE
unset FLEET_HUB_URL CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_NODE_ALIASES FLEET_REMOTE_SSH_CMD

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 (want '$2')" "$3"; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 (want '$3')" "$2" ;; esac; }
hasnt() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 (must not hold '$3')" "$2" ;; esac; }
ts() { "$REAL_TMUX" -L "$SESS" "$@"; }
tn() { "$REAL_TMUX" -L "$NODE" "$@"; }
waitfor() {  # <secs> <cmd…> — until the command succeeds
  local n=$(( $1 * 10 )); shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
  return 1
}
CLIENT_PID=''
cleanup() {
  exec 7>&- 2>/dev/null
  [ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" 2>/dev/null
  "$REAL_TMUX" -L "$SESS" kill-server 2>/dev/null
  "$REAL_TMUX" -L "$NODE" kill-server 2>/dev/null
  pkill -f "fleet-shell.sh keeper $SESS" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# --- a bin/ of our own: every real script, a FAKE fleet-connect.py --------------
SB="$WORK/sbin"; mkdir -p "$SB" "$WORK/conf"
for f in "$BIN"/*; do [ -f "$f" ] && ln -s "$f" "$SB/${f##*/}"; done
rm -f "$SB/fleet-connect.py"
ln -s "$BIN/../conf/tmux-shell.conf" "$WORK/conf/tmux-shell.conf"
cat > "$SB/fleet-connect.py" <<EOF
#!/usr/bin/env python3
import json, os, sys
open(os.path.join("$WORK", "connect.argv"), "a").write(" ".join(sys.argv[1:]) + "\\n")
if "--pick" in sys.argv:
    if not os.path.exists(os.path.join("$WORK", "hub.ok")):
        sys.stderr.write("fleet connect: no hub URL: run the installer (curl -fsSL <入口>/install | sh)\\n"); sys.exit(2)
    want = [a for a in sys.argv[1:] if not a.startswith("-")]
    m = want[0] if want else "m5"
    print(json.dumps({"machine": m, "hostname": {"m5": "macmini", "m4": "mini2"}.get(m, m), "reason": "last",
                      "login": "verk", "machines": [{"alias": "m5", "hostname": "macmini"}, {"alias": "m4", "hostname": "mini2"}]}))
    sys.exit(0)
if "--enter" in sys.argv:
    sys.stderr.write("fake-connect: enter " + " ".join(sys.argv[1:]) + "\\n")
    sys.exit(0)
sys.exit(0)
EOF
chmod +x "$SB/fleet-connect.py"
: > "$WORK/hub.ok"

# --- the ssh shim: records the remote command; the master's -O answers are yeses ---
SHIM="$WORK/shim"; mkdir -p "$SHIM"
cat > "$SHIM/ssh" <<EOF
#!/bin/bash
op=''; ctl=''
while [ \$# -gt 0 ]; do
  case "\$1" in
    -O) op=\$2; shift 2 ;;
    -S) ctl=\$2; shift 2 ;;
    -o) case "\$2" in ControlPath=*) ctl=\${2#ControlPath=} ;; esac; shift 2 ;;
    -L) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
if [ -n "\$op" ]; then [ "\$op" = check ] && [ -S "\$ctl" ]; exit \$?; fi
host=\$1; shift
printf '%s\\t%s\\n' "\$host" "\$*" >> "$WORK/ssh.log"
case "\$*" in
  *" attach "*) # a master: hold a control socket like ssh would, then stay attached
    python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1)
import time; time.sleep(600)' "\$ctl" & echo \$! > "$WORK/master.pid"; wait ;;
  *" select "*) exit 0 ;;
  *" watch "*) sleep 600 ;;
esac
exit 0
EOF
chmod +x "$SHIM/ssh"
export FLEET_REMOTE_SSH_CMD="$SHIM/ssh"

# --- the hub: fleet_sessions for two machines, this login's rows only --------------
cat > "$WORK/sessions.json" <<'EOF'
{"sessions": [
  {"worker_id": "11111111-1111-4111-8111-111111111111/issue-7", "machine_name": "macmini", "os_user": "verk",
   "availability": "online", "observed_at": "2026-10-04T10:00:00Z",
   "worker": {"issue": 7, "repo": "acme/app", "state": "working", "agent": "claude", "name": "issue-7", "needs": ""}},
  {"worker_id": "11111111-1111-4111-8111-111111111111/scratch-3", "machine_name": "macmini", "os_user": "verk",
   "availability": "online", "observed_at": "2026-10-04T10:00:00Z",
   "worker": {"issue": 0, "repo": "", "state": "idle", "agent": "claude", "name": "notes", "needs": ""}},
  {"worker_id": "22222222-2222-4222-8222-222222222222/issue-9", "machine_name": "mini2", "os_user": "verk",
   "availability": "online", "observed_at": "2026-10-04T10:00:00Z",
   "worker": {"issue": 9, "repo": "acme/app", "state": "needs", "agent": "claude", "name": "issue-9", "needs": "ask"}},
  {"worker_id": "33333333-3333-4333-8333-333333333333/issue-1", "machine_name": "other", "os_user": "someone",
   "availability": "online", "observed_at": "2026-10-04T10:00:00Z",
   "worker": {"issue": 1, "repo": "x/y", "state": "working", "agent": "claude", "name": "issue-1", "needs": ""}}
 ],
 "nodes": [
  {"machine_name": "macmini", "availability": "online", "sessions": 2, "observed_at": "2026-10-04T10:00:00Z"},
  {"machine_name": "mini2", "availability": "online", "sessions": 1, "observed_at": "2026-10-04T10:00:00Z"}
 ]}
EOF
export FLEET_HUB_SESSIONS_CMD="cat $WORK/sessions.json"
export FLEET_HUB_SESSIONS_USER=verk

# ================================================================================
# A. degenerate
# ================================================================================
: > "$WORK/connect.argv"
out=$(FLEET_SHELL=0 "$SB/fleet" 2>&1); rc=$?
eq 'A: FLEET_SHELL=0 bare fleet → connect --enter, exit 0' 0 "$rc"
has 'A: connect saw --enter' "$(cat "$WORK/connect.argv")" '--enter'
hasnt 'A: FLEET_SHELL=0 prints no tmux hint' "$out" 'tmux'
: > "$WORK/connect.argv"
# no tmux on PATH: a PATH with only what the dispatcher needs
NOTMUX="$WORK/notmux"; mkdir -p "$NOTMUX"
for t in sh sed dirname python3 bash env cat; do p=$(command -v "$t") && ln -sf "$p" "$NOTMUX/$t"; done
out=$(PATH="$NOTMUX" "$SB/fleet" 2>&1); rc=$?
eq 'A: no tmux → connect --enter, exit 0' 0 "$rc"
has 'A: no tmux → the hint names tmux' "$out" 'brew install tmux'
eq 'A: the hint is ONE line' 1 "$(printf '%s\n' "$out" | grep -c 'install tmux')"
has 'A: no tmux → connect saw --enter' "$(cat "$WORK/connect.argv")" '--enter'
# fleet-hub-sessions.sh without the client knob: the conf dir's fleets, byte for byte
mkdir -p "$WORK/degen-conf/fleets/plainfleet"; printf 'FLEET_REPO=acme/app\n' > "$WORK/degen-conf/fleets/plainfleet/conf"
( export TMPDIR="$WORK/degen" FLEET_CONF_DIR="$WORK/degen-conf"; mkdir -p "$TMPDIR"; CCQUOTA_FLEET=1 bash "$SB/fleet-hub-sessions.sh" --refresh >/dev/null 2>&1 )
CHECKS=$((CHECKS + 1)); [ -s "$WORK/degen-conf/control/hub-workers.tsv" ] || fail 'A: default mode writes the control locator cache'
CHECKS=$((CHECKS + 1)); [ -s "$WORK/degen/.claude-dash/global/remote_plainfleet" ] || fail 'A: default mode writes the conf dir fleet cache'
CHECKS=$((CHECKS + 1)); [ -e "$WORK/degen/.claude-dash/global/remote_$SESS" ] && fail 'A: default mode wrote a pseudo-fleet cache'
has 'A: default mode: #me is this host' "$(head -2 "$WORK/degen/.claude-dash/global/remote_plainfleet" | tr '\037' ' ')" "#me $(hostname -s | cut -d. -f1)"

# ================================================================================
# B. up — bare `fleet` with tmux: the shell
# ================================================================================
: > "$WORK/connect.argv"
out=$("$SB/fleet" 2>"$WORK/up.err"); rc=$?
eq 'B: bare fleet → the shell started (exit 0)' 0 "$rc"
eq 'B: it printed its session' "$SESS" "$out"
has 'B: connect was asked for --pick' "$(cat "$WORK/connect.argv")" '--pick'
hasnt 'B: connect was NOT asked to --enter (no ssh of its own)' "$(cat "$WORK/connect.argv")" '--enter'
CHECKS=$((CHECKS + 1)); ts has-session -t "=$SESS" 2>/dev/null || fail 'B: the shell server is up'
# A client (what the person's terminal is): control mode needs no tty, and the
# list is drawn only for an attached session (as in a fleet). Its stdin is a fifo
# this test holds open; closing it (the exit) ends the client.
mkfifo "$WORK/client.fifo"
"$REAL_TMUX" -L "$SESS" -C attach-session -t "=$SESS" < "$WORK/client.fifo" >/dev/null 2>&1 &
CLIENT_PID=$!
exec 7> "$WORK/client.fifo"
CHECKS=$((CHECKS + 1)); waitfor 5 test "$(ts display-message -p -t "=$SESS:" '#{session_attached}')" != 0 || fail 'B: a control client attached'
w1=$(ts list-windows -t "=$SESS" -F '#{window_id}' | head -1)
eq 'B: the first window is m5 (the pick)' '⇄m5' "$(ts display-message -p -t "$w1" '#{window_name}')"
eq 'B: @remote = m5: (the machine, no worker)' 'm5:' "$(ts show-options -wqv -t "$w1" @remote)"
CHECKS=$((CHECKS + 1)); waitfor 10 grep -q "attach --shell '-'" "$WORK/ssh.log" || fail 'B: the far end was asked for attach --shell -' "$(cat "$WORK/ssh.log" 2>/dev/null)"
has 'B: the ssh went to m5' "$(head -1 "$WORK/ssh.log")" 'm5	'
env_g=$(ts show-environment -g)
has 'B: server env FLEET_SHELL=1' "$env_g" 'FLEET_SHELL=1'
has 'B: server env client mode' "$env_g" "FLEET_HUB_SESSIONS_CLIENT=$SESS"
has 'B: server env hub source' "$env_g" 'FLEET_SIDEBAR_SOURCE=hub'
has 'B: server env TMPDIR under the cache' "$env_g" "TMPDIR=$WORK/cache/tmp"
has 'B: server env aliases from the pick' "$env_g" 'FLEET_NODE_ALIASES=macmini=m5 mini2=m4'
CHECKS=$((CHECKS + 1)); [ -L "$WORK/cache/bin/fleet-sidebar.py" ] || fail 'B: the conf-free mirror has the scripts'
CHECKS=$((CHECKS + 1)); [ -e "$WORK/cache/fleet.conf" ] && fail 'B: the mirror must have no sibling fleet.conf'
has 'B: tmux.conf names the mirror' "$(cat "$WORK/cache/tmux.conf")" "$WORK/cache/bin/tmux-status.sh"
# the list pane: sync (the hooks' call) puts the view left of the ssh pane
ts set-option -g @popup_open 0 2>/dev/null
ts resize-window -t "$w1" -x 200 -y 50 2>/dev/null
view_of() { ts list-panes -t "$1" -F '#{pane_id} #{@sidebar}' 2>/dev/null | awk '$2 == 1 { print $1; exit }'; }
sock=$(ts display-message -p '#{socket_path}')
( export TMUX="$sock,0,0" FLEET_SHELL=1 FLEET_SIDEBAR_SOURCE=hub CCQUOTA_FLEET=1 TMPDIR="$WORK/cache/tmp" FLEET_HUB_SESSIONS_CLIENT="$SESS"
  bash "$WORK/cache/bin/fleet-sidebar.sh" sync "$w1" >/dev/null 2>&1 )
CHECKS=$((CHECKS + 1)); waitfor 5 test -n "$(view_of "$w1")" || fail 'B: sync put a list pane in the m5 window' "$(ts list-panes -t "$w1" -F '#{pane_id} #{@sidebar} #{pane_current_command}')"
view=$(view_of "$w1")
eq 'B: the list pane is on the left' "$view" "$(ts list-panes -t "$w1" -F '#{pane_id} #{pane_left}' | awk '$2 == 0 { print $1; exit }')"
eq 'B: two panes: list + ssh' 2 "$(ts list-panes -t "$w1" -F x | grep -c x)"

# ================================================================================
# C. data — the client-mode loop and the row producer
# ================================================================================
G="$WORK/cache/tmp/.claude-dash/global"
CHECKS=$((CHECKS + 1)); waitfor 15 test -s "$G/remote_$SESS" || fail 'C: the keeper/loop wrote the pseudo-fleet cache' "$(ls "$G" 2>/dev/null)"
cache=$(tr '\037' '|' < "$G/remote_$SESS" 2>/dev/null)
has 'C: #me is empty in client mode' "$cache" '#me|'
hasnt 'C: #me names no host' "$cache" "#me|$(hostname -s | cut -d. -f1)"
has 'C: a #node line for m5' "$cache" '#node|m5|online|2|'
has 'C: a #node line for m4' "$cache" '#node|m4|online|1|'
has 'C: the m5 worker row is REMOTE (local=0)' "$cache" 'wid:11111111-1111-4111-8111-111111111111/issue-7|m5|online|7|acme/app|working|claude|issue-7|||0|'
has 'C: the m4 row with its need' "$cache" 'wid:22222222-2222-4222-8222-222222222222/issue-9|m4|online|9|acme/app|needs|claude|issue-9||ask|0|'
hasnt 'C: another login is not a row' "$cache" 'someone'
hasnt 'C: another login is not a row (wid)' "$cache" '33333333'
CHECKS=$((CHECKS + 1)); [ -s "$G/hub_ok" ] || fail 'C: hub_ok written'
CHECKS=$((CHECKS + 1)); [ -e "$FLEET_CONF_DIR/control/hub-workers.tsv" ] && fail 'C: client mode must not write the control locator cache'
rows=$( cd "$WORK/cache/bin" && TMUX="$(ts display-message -p '#{socket_path}'),0,0" FLEET_SHELL=1 FLEET_SESSION="$SESS" FLEET_SIDEBAR_CURRENT="$w1" \
        FLEET_SIDEBAR_SOURCE=hub CCQUOTA_FLEET=1 TMPDIR="$WORK/cache/tmp" FLEET_HUB_SESSIONS_CLIENT="$SESS" \
        bash "$WORK/cache/bin/tmux-dashboard-rows.sh" --sidebar 2>/dev/null | tr '\037' '|' )
has 'C: the producer lists the m5 worker' "$rows" 'issue-7'
has 'C: the producer lists the m4 worker' "$rows" 'issue-9'
has 'C: the producer lists the scratch row' "$rows" 'notes'
hasnt 'C: the shell window itself is not a row' "$rows" '⇄m5'
hasnt 'C: no row is tagged lost while the hub answers' "$rows" 'm5!'

# ================================================================================
# D. same machine — open an m5 row: select over the control socket, no respawn
# ================================================================================
CHECKS=$((CHECKS + 1)); waitfor 5 test -S "$(ts show-options -wqv -t "$w1" @remote_ctl)" || fail 'D: run stashed a live @remote_ctl on its window' "$(ts show-options -wqv -t "$w1" @remote_ctl)"
pane_pid=$(ts list-panes -t "$w1" -F '#{pane_id} #{pane_pid} #{@sidebar}' | awk '$3 != 1 { print $2; exit }')
: > "$WORK/ssh.log"
out=$( TMUX="$(ts display-message -p '#{socket_path}'),0,0" FLEET_SHELL=1 FLEET_SESSION="$SESS" CCQUOTA_FLEET=1 TMPDIR="$WORK/cache/tmp" FLEET_CONF_DIR="$FLEET_CONF_DIR" \
       bash "$WORK/cache/bin/fleet-remote-view.sh" open 'wid:11111111-1111-4111-8111-111111111111/issue-7' 2>&1 )
eq 'D: open printed the SAME window' "$w1" "$out"
eq 'D: @remote retargeted to the worker' 'm5:11111111-1111-4111-8111-111111111111/issue-7' "$(ts show-options -wqv -t "$w1" @remote)"
eq 'D: the window is renamed after the row' '⇄m5 issue-7' "$(ts display-message -p -t "$w1" '#{window_name}')"
has 'D: select went over the connection' "$(cat "$WORK/ssh.log")" "fleet-remote-view.sh select '11111111-1111-4111-8111-111111111111/issue-7'"
hasnt 'D: no second attach (no respawn)' "$(cat "$WORK/ssh.log")" 'attach'
eq 'D: the ssh pane was NOT respawned (same pid)' "$pane_pid" "$(ts list-panes -t "$w1" -F '#{pane_id} #{pane_pid} #{@sidebar}' | awk '$3 != 1 { print $2; exit }')"
eq 'D: the list pane is the same pane' "$view" "$(view_of "$w1")"
eq 'D: still one window' 1 "$(ts list-windows -t "=$SESS" -F x | grep -c x)"

# ================================================================================
# E. other machine — open an m4 row: a second window, the list pane follows
# ================================================================================
: > "$WORK/ssh.log"
out=$( TMUX="$(ts display-message -p '#{socket_path}'),0,0" FLEET_SHELL=1 FLEET_SESSION="$SESS" CCQUOTA_FLEET=1 TMPDIR="$WORK/cache/tmp" FLEET_CONF_DIR="$FLEET_CONF_DIR" \
       bash "$WORK/cache/bin/fleet-remote-view.sh" open 'wid:22222222-2222-4222-8222-222222222222/issue-9' 2>&1 )
w2=$out
CHECKS=$((CHECKS + 1)); case "$w2" in @*) [ "$w2" != "$w1" ] || fail 'E: a NEW window for m4' "$w2" ;; *) fail 'E: open printed a window id' "$w2" ;; esac
eq 'E: two windows now' 2 "$(ts list-windows -t "=$SESS" -F x | grep -c x)"
eq 'E: the m4 window is current' "$w2" "$(ts display-message -p -t "=$SESS:" '#{window_id}')"
eq 'E: named ⇄m4 <name>' '⇄m4 issue-9' "$(ts display-message -p -t "$w2" '#{window_name}')"
eq 'E: @remote = m4:<wid>' 'm4:22222222-2222-4222-8222-222222222222/issue-9' "$(ts show-options -wqv -t "$w2" @remote)"
CHECKS=$((CHECKS + 1)); waitfor 10 grep -q "^m4	.*run\|^m4	" "$WORK/ssh.log" || fail 'E: the far end m4 was asked to attach' "$(cat "$WORK/ssh.log")"
has 'E: run --shell → attach --shell on m4' "$(cat "$WORK/ssh.log")" "attach --shell '22222222-2222-4222-8222-222222222222/issue-9'"
# the list pane follows: fleet-sidebar.py jump (what Enter does) moves the SAME pane
ts resize-window -t "$w2" -x 200 -y 50 2>/dev/null
( cd "$WORK/cache/bin" && TMUX="$(ts display-message -p '#{socket_path}'),0,0" FLEET_SHELL=1 FLEET_SESSION="$SESS" CCQUOTA_FLEET=1 TMPDIR="$WORK/cache/tmp" \
  python3 - "$SESS" "$w2" "$view" "$WORK/cache/lock" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sb", "fleet-sidebar.py"); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.jump(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
PY
)
eq 'E: the SAME list pane now sits in the m4 window' "$view" "$(view_of "$w2")"
eq 'E: the list pane is on the left of m4' "$view" "$(ts list-panes -t "$w2" -F '#{pane_id} #{pane_left}' | awk '$2 == 0 { print $1; exit }')"
eq 'E: the m5 window is still there' '⇄m5 issue-7' "$(ts display-message -p -t "$w1" '#{window_name}')"
eq 'E: m5 window keeps its ssh pane' 1 "$(ts list-panes -t "$w1" -F x | grep -c x)"

# ================================================================================
# F. the bar — tmux-status.sh in the shell's environment, for the m4 window
# ================================================================================
bar() {  # <window> — the bar as the conf's status-right runs it
  ( cd "$WORK/cache/bin" && FLEET_SHELL=1 FLEET_SIDEBAR_SOURCE=hub CCQUOTA_FLEET=1 TMPDIR="$WORK/cache/tmp" FLEET_CONF_DIR="$FLEET_CONF_DIR" FLEET_NODE_ALIASES='macmini=m5 mini2=m4' \
    TMUX="$(ts display-message -p '#{socket_path}'),0,0" HOSTNAME=laptop \
    bash "$WORK/cache/bin/tmux-status.sh" "sess=$SESS" "win=$1" "remote=$(ts show-options -wqv -t "$1" @remote)" acct= wsf=x wscf=y wsaved= 2>/dev/null )
}
b=$(bar "$w2")
has 'F: the bar names m4 (the right pane machine)' "$b" 'm4 '
has 'F: m4 is online off the #node line (no hub_nodes)' "$b" "m4 #[fg=#9ece6a]● "
hasnt 'F: no `?` for a machine the hub lists' "$b" 'm4 #[fg=#565f89]? '
has 'F: 入口 ●' "$b" '入口 #[fg=#9ece6a]● '
hasnt 'F: no local CPU chip for a remote window' "$b" 'CPU'
b5=$(bar "$w1")
has 'F: the m5 window says m5' "$b5" 'm5 '
eq 'F: the window list was blanked (hub mode)' '1' "$(ts show-options -gqv @status_wlist_saved)"

# ================================================================================
# G. lost — the hub silent: rows stay (dimmed), the bar says 失联
# ================================================================================
pkill -f "fleet-shell.sh keeper $SESS" 2>/dev/null
pkill -f "fleet-hub-sessions.sh --loop" 2>/dev/null; sleep 0.3
old=$(( $(date +%s) - 400 )); printf '%s\n' "$old" > "$G/hub_ok"
rows=$( cd "$WORK/cache/bin" && TMUX="$(ts display-message -p '#{socket_path}'),0,0" FLEET_SHELL=1 FLEET_SESSION="$SESS" FLEET_SIDEBAR_CURRENT="$w2" \
        FLEET_SIDEBAR_SOURCE=hub CCQUOTA_FLEET=1 TMPDIR="$WORK/cache/tmp" FLEET_HUB_SESSIONS_CLIENT="$SESS" \
        bash "$WORK/cache/bin/tmux-dashboard-rows.sh" --sidebar 2>/dev/null | tr '\037' '|' )
has 'G: the m4 row is still listed' "$rows" 'issue-9'
has 'G: the m5 row is still listed' "$rows" 'issue-7'
has 'G: rows are marked lost' "$rows" 'm4!'
b=$(bar "$w2")
has 'G: the bar says 入口 失联' "$b" '入口 #[fg=#f7768e]○ 失联'
printf '%s\n' "$(date +%s)" > "$G/hub_ok"

# ================================================================================
# H. ssh mode
# ================================================================================
: > "$WORK/connect.argv"
out=$( PATH="$SHIM:$PATH" bash "$SB/fleet-shell.sh" ssh -tt -o ServerAliveInterval=5 -o ControlMaster=yes -o "ControlPath=$WORK/x.ctl" -o ControlPersist=no \
       -o "ProxyCommand=fleet connect --proxy m4" m4 "bash .claude/fleet/bin/fleet-remote-view.sh attach --shell 'w' 'v'" 2>&1 )
argv=$(cat "$WORK/connect.argv")
has 'H: a master goes to fleet-connect.py --enter m4' "$argv" '--enter m4'
has 'H: control options kept' "$argv" "-o ControlPath=$WORK/x.ctl"
has 'H: keepalive kept' "$argv" '-o ServerAliveInterval=5'
has 'H: -tt → RequestTTY=force' "$argv" '-o RequestTTY=force'
hasnt 'H: ProxyCommand dropped (fleet connect decides the route)' "$argv" 'ProxyCommand'
has 'H: the remote command after --' "$argv" "-- bash .claude/fleet/bin/fleet-remote-view.sh attach --shell 'w' 'v'"
: > "$WORK/ssh.log"
PATH="$SHIM:$PATH" bash "$SB/fleet-shell.sh" ssh -S "$WORK/x.ctl" m4 "bash .claude/fleet/bin/fleet-remote-view.sh select 'w'" >/dev/null 2>&1
has 'H: a slave (-S) is plain ssh over the socket' "$(cat "$WORK/ssh.log")" "m4	bash .claude/fleet/bin/fleet-remote-view.sh select 'w'"
eq 'H: a slave never asks fleet connect' 0 "$(grep -c select "$WORK/connect.argv")"
me=$(hostname -s | cut -d. -f1)
out=$( FLEET_NODE_ALIASES="$me=here" bash "$SB/fleet-shell.sh" ssh -tt -o ControlMaster=yes -o "ControlPath=$WORK/y.ctl" here "printf 'local:%s' \"\${TMUX:-unset}\"" 2>&1 )
eq 'H: a host that is this computer runs the command here, TMUX unset' 'local:unset' "$out"
out=$( FLEET_NODE_ALIASES="$me=here" bash "$SB/fleet-shell.sh" ssh -S "$WORK/y.ctl" -O check here 2>&1 ); rc=$?
eq 'H: its -O check is a yes' 0 "$rc"

# ================================================================================
# I. select — on a node: the worker's window becomes current
# ================================================================================
# A node: a fleet conf + a machine id ⇒ a fleet UUID, the first half of every
# worker_id the hub hands the shell (fleet_wid_home finds the fleet by it — there
# is no caller session over ssh).
mkdir -p "$FLEET_CONF_DIR/fleets/$NODE" "$FLEET_CONF_DIR/control" "$WORK/node-tmp"
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s\n' "$WORK/main" > "$FLEET_CONF_DIR/fleets/$NODE/conf"
python3 - "$FLEET_CONF_DIR/control/state.sqlite3" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT)")
c.execute("INSERT OR REPLACE INTO metadata VALUES ('machine_id', '0b8e2f3a-7c1d-4e5f-9a6b-1c2d3e4f5a6b')"); c.commit()
PY
U=$(. "$SB/fleet-lib.sh"; fleet_uuid "$NODE")
CHECKS=$((CHECKS + 1)); [ -n "$U" ] || fail 'I: rig: no fleet UUID for the node'
tn new-session -d -s "$NODE" -n hub -x 120 -y 30 "sleep 600" || fail 'I: node server'
tn new-window -d -t "=$NODE:" -n issue-7 "sleep 600"; tn set-window-option -t "=$NODE:issue-7" @issue 7
tn new-window -d -t "=$NODE:" -n issue-8 "sleep 600"; tn set-window-option -t "=$NODE:issue-8" @issue 8
tn select-window -t "=$NODE:hub"
( export TMPDIR="$WORK/node-tmp"; unset TMUX TMUX_PANE
  CCQUOTA_FLEET=1 bash "$SB/fleet-remote-view.sh" select "wid:$U/issue-8" >/dev/null 2>&1 ); rc=$?
eq 'I: select exits 0 for a live worker' 0 "$rc"
eq 'I: the worker window is now current on the node' 'issue-8' "$(tn display-message -p -t "=$NODE:" '#{window_name}')"
( export TMPDIR="$WORK/node-tmp"; unset TMUX TMUX_PANE
  CCQUOTA_FLEET=1 bash "$SB/fleet-remote-view.sh" select "wid:$U/issue-99" >/dev/null 2>&1 ); rc=$?
eq 'I: an unknown worker → 3' 3 "$rc"
eq 'I: the current window is unchanged' 'issue-8' "$(tn display-message -p -t "=$NODE:" '#{window_name}')"
# attach -: the login's fleet session, no window selected (what the shell's first window asks)
out=$( export TMPDIR="$WORK/node-tmp"; unset TMUX TMUX_PANE; CCQUOTA_FLEET=1 FLEET_REMOTE_TEST_NOATTACH=1 bash -c '
  . "$1/fleet-lib.sh"; fleet_sockets | head -1' _ "$SB" )
eq 'I: fleet_sockets names the node session (what attach - picks)' "$NODE" "$out"

printf 'fleet-shell selftest: %d checks, %d failures\n' "$CHECKS" "$FAIL"
[ "$FAIL" = 0 ] && echo "PASS fleet-shell-selftest" || echo "FAIL fleet-shell-selftest"
[ "$FAIL" = 0 ]
