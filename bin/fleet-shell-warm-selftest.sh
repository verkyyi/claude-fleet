#!/bin/bash
# fleet-shell-warm-selftest.sh — the shell's lines are open before you need them
# (issue #1631, EPIC #1615 C14): bin/fleet-shell.sh `warm`, the proxy pane of
# bin/fleet-remote-view.sh `run --shell` riding a warm master, the warm masters
# as node sources in bin/fleet-hub-sessions.sh, and its end-to-end log (--e2e).
#
# Nothing real is reached: `fleet connect` is a FAKE (FLEET_SHELL_WARM_CONNECT for
# the warm loop, a fake fleet-connect.py in a mirrored bin/ for the proxy pane)
# that records its argv and binds a unix socket where ssh would put its master;
# ssh is a PATH shim (`-O check` = the socket is there and not marked dead,
# `-O exit` = logged + removed, anything else logged); tmux runs on an isolated
# socket of its own (`-L fwarm<pid>`), killed at the end.
#   A. degenerate — FLEET_SHELL_WARM=0: no master, no log; no sidebar cache: no
#                   master either
#   B. warm       — one tick off a cache listing mac-b (online, 2 sessions), mac-a
#                   (online, 1), m3 (online, 0), m2 (lost, 3) and this computer:
#                   a master for mac-b and mac-a only, each `fleet connect <m> -o
#                   ControlMaster=yes -o ControlPath=$TMPDIR/warm/<m>.sock -o
#                   ControlPersist=10m -o SessionType=none … -o
#                   ServerAliveInterval=2 -o ServerAliveCountMax=3 -o IPQoS=… -o
#                   Compression=no`; a second tick starts nothing; the cap
#                   (FLEET_SHELL_WARM_MAX=1) keeps the busiest
#   C. down       — mac-a goes lost: the next tick closes its master (`-O exit`, the
#                   socket gone), mac-b's stands; a master a window rides
#                   (`@remote_ctl`) is kept even once its machine drops out; a
#                   dead master (check fails) is started again; the loop proper
#                   closes every master once the shell's server is gone
#   D. ride       — `run --shell mac-b <wid>` with mac-b's master warm: the session goes
#                   over it (`-S …/warm/mac-b.sock`, ControlMaster=no), fleet connect
#                   is never run, the warm master is NOT closed when the pane ends;
#                   cold (no warm master): fleet connect --enter with
#                   ServerAliveInterval=2 / ServerAliveCountMax=3 / IPQoS / Compression=no
#   L. login      — (issue #2987) a machine whose sessions are in another login's
#                   fleet (`fleet_logins`) gets `<m>@<login>.sock`, opened as that
#                   login; `run` for such a session rides it; gone when no session
#                   of that login is left
#   E. sources    — a warm master is a node source for the hub-lost refresh
#   F. e2e        — the client-mode loop logs one line per row whose state moved
#                   (lag = received − observed_at), none for an unchanged row or
#                   the first cache; `--e2e` prints n · median · max
# tmux / python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { printf 'fleet-shell-warm selftest: tmux absent — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'fleet-shell-warm selftest: python3 absent — SKIP\n'; exit 0; }

# short: a unix socket path is capped near 104 bytes
WORK="$(mktemp -d /tmp/fwarm.XXXXXX)" || exit 2
S="fwarm$$"
export HOME="$WORK/home"; mkdir -p "$HOME" "$WORK/t"
export TMPDIR="$WORK/t" FLEET_CONF_DIR="$WORK/conf" XDG_CONFIG_HOME="$WORK/home/.config"
mkdir -p "$FLEET_CONF_DIR"
unset TMUX TMUX_PANE FLEET_SHELL FLEET_SHELL_WARM FLEET_SHELL_WARM_MAX FLEET_NODE_ALIASES FLEET_REMOTE_SSH \
      FLEET_HUB_URL CCQUOTA_HUB_URL FLEET_SESSION
FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 (want '$2')" "$3"; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 (want '$3')" "$2" ;; esac; }
hasnt() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 (must not hold '$3')" "$2" ;; esac; }
ts() { "$REAL_TMUX" -L "$S" "$@"; }
cleanup() {
  ts kill-server 2>/dev/null
  pkill -f "$WORK/" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- fakes ------------------------------------------------------------------------
# fake `fleet connect`: argv → connect.log; bind the ControlPath socket (a master)
cat > "$WORK/connect" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/connect.log"
for a in "\$@"; do case "\$a" in ControlPath=*) ctl=\${a#ControlPath=} ;; esac; done
[ -n "\${ctl:-}" ] && python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "\$ctl"
exit 0
EOF
chmod +x "$WORK/connect"
SHIM="$WORK/shim"; mkdir -p "$SHIM"
cat > "$SHIM/ssh" <<EOF
#!/bin/bash
op=''; ctl=''; all="\$*"
while [ \$# -gt 0 ]; do
  case "\$1" in
    -O) op=\$2; shift 2 ;;
    -S) ctl=\$2; shift 2 ;;
    -o) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
case "\$op" in
  check) [ -S "\$ctl" ] && ! grep -qxF "\$ctl" "$WORK/dead" 2>/dev/null; exit \$? ;;
  exit)  printf 'EXIT %s\n' "\$ctl" >> "$WORK/ssh.log"; rm -f "\$ctl"; exit 0 ;;
  ?*)    exit 0 ;;
esac
printf 'RUN %s\n' "\$all" >> "$WORK/ssh.log"
case "\$all" in *" watch "*) sleep 30 ;; esac
exit 0
EOF
chmod +x "$SHIM/ssh"
export PATH="$SHIM:$PATH" FLEET_REMOTE_SSH_CMD="$SHIM/ssh" FLEET_SHELL_WARM_CONNECT="$WORK/connect"

G="$TMPDIR/.claude-dash/global"; mkdir -p "$G"
WD="$TMPDIR/warm"
me=$(hostname -s 2>/dev/null); me=${me%%.*}
cache() {   # <label:av:n>… → the sidebar cache's #node lines
  local x
  { printf '#ts\037%s\n#me\037\n' "$(date +%s)"
    for x in "$@"; do IFS=: read -r l a n <<EOF2
$x
EOF2
      printf '#node\037%s\037%s\037%s\037%s\037hub\n' "$l" "$a" "$n" "$(date +%s)"; done; } > "$G/remote_$S"
}
tick() { bash "$BIN/fleet-shell.sh" warm "$S" --once; }

# ================================================================================
# A. degenerate
cache mac-b:online:2
FLEET_SHELL_WARM=0 bash "$BIN/fleet-shell.sh" warm "$S"; rc=$?
eq 'A: FLEET_SHELL_WARM=0 exits 0' 0 "$rc"
eq 'A: FLEET_SHELL_WARM=0 started nothing' '' "$(cat "$WORK/connect.log" 2>/dev/null)"
[ -d "$WD" ] && fail 'A: FLEET_SHELL_WARM=0 made the warm dir'
rm -f "$G/remote_$S"
tick
eq 'A: no sidebar cache → no master' '' "$(cat "$WORK/connect.log" 2>/dev/null)"

# ================================================================================
# B. warm
cache mac-b:online:2 mac-a:online:1 m3:online:0 m2:lost:3 "$me:online:4"
tick; sleep 0.5
log=$(cat "$WORK/connect.log" 2>/dev/null)
eq 'B: two masters started' 2 "$(printf '%s\n' "$log" | grep -c .)"
mac_b=$(printf '%s\n' "$log" | grep '^mac-b ')
has 'B: mac-b started' "$mac_b" "mac-b -o ControlMaster=yes -o ControlPath=$WD/mac-b.sock -o ControlPersist=10m"
for o in SessionType=none ForkAfterAuthentication=yes BatchMode=yes ServerAliveInterval=2 ServerAliveCountMax=3 \
         'IPQoS=lowdelay throughput' Compression=no; do has "B: mac-b's master carries $o" "$mac_b" "-o $o"; done
has 'B: mac-a started' "$log" "mac-a -o ControlMaster=yes -o ControlPath=$WD/mac-a.sock"
hasnt 'B: m3 (no session) not started' "$log" 'm3 '
hasnt 'B: m2 (lost) not started' "$log" 'm2 '
hasnt 'B: this computer never warmed' "$log" "$me "
[ -S "$WD/mac-b.sock" ] && [ -S "$WD/mac-a.sock" ] || fail 'B: the masters hold their sockets'
: > "$WORK/connect.log"; tick; sleep 0.3
eq 'B: a second tick starts nothing (both alive)' '' "$(cat "$WORK/connect.log")"
# the cap keeps the busiest
mv "$WD" "$WD.keep"
FLEET_SHELL_WARM_MAX=1 tick; sleep 0.3
eq 'B: FLEET_SHELL_WARM_MAX=1 → only the busiest (mac-b)' 'mac-b' "$(cut -d' ' -f1 "$WORK/connect.log" | tr '\n' ' ' | sed 's/ $//')"
rm -rf "$WD"; mv "$WD.keep" "$WD"; : > "$WORK/connect.log"

# ================================================================================
# C. down
: > "$WORK/ssh.log"
cache mac-b:online:2 mac-a:lost:1
tick
has 'C: mac-a lost → its master closed' "$(cat "$WORK/ssh.log")" "EXIT $WD/mac-a.sock"
[ -e "$WD/mac-a.sock" ] && fail 'C: mac-a.sock still there'
hasnt "C: mac-b's master stands" "$(cat "$WORK/ssh.log")" "EXIT $WD/mac-b.sock"
# a window rides mac-b's master: kept even when mac-b drops out
ts -f /dev/null new-session -d -s "$S" -x 80 -y 20 'sleep 300'
ts set-window-option -t "=$S:" @remote_ctl "$WD/mac-b.sock"
cache mac-a:lost:1
: > "$WORK/ssh.log"; tick
hasnt 'C: a master a window rides is kept' "$(cat "$WORK/ssh.log")" "EXIT $WD/mac-b.sock"
ts set-window-option -u -t "=$S:" @remote_ctl
# a dead master comes back
cache mac-b:online:2
printf '%s\n' "$WD/mac-b.sock" > "$WORK/dead"
: > "$WORK/connect.log"; tick; sleep 0.3
has 'C: a dead master is started again' "$(cat "$WORK/connect.log")" 'mac-b -o ControlMaster=yes'
rm -f "$WORK/dead"
# the loop proper: one at a time; the server gone → every master closed, loop ends
FLEET_SHELL_WARM_EVERY=1 bash "$BIN/fleet-shell.sh" warm "$S" & lp=$!
sleep 1
FLEET_SHELL_WARM_EVERY=1 bash "$BIN/fleet-shell.sh" warm "$S"; rc=$?
eq 'C: a second loop exits at once (one at a time)' 0 "$rc"
: > "$WORK/ssh.log"
ts kill-server 2>/dev/null
for _ in 1 2 3 4 5 6; do kill -0 "$lp" 2>/dev/null || break; sleep 0.5; done
kill -0 "$lp" 2>/dev/null && { fail 'C: the loop outlived the server'; kill "$lp"; }
has 'C: the server gone → mac-b closed' "$(cat "$WORK/ssh.log")" "EXIT $WD/mac-b.sock"
[ -e "$WD/loop.pid" ] && fail 'C: loop.pid left behind'

# ================================================================================
# D. ride — the proxy pane, through the shell's own ssh mode (fake fleet-connect.py)
SB="$WORK/sbin"; mkdir -p "$SB"
for f in "$BIN"/*; do [ -f "$f" ] && ln -s "$f" "$SB/${f##*/}"; done
rm -f "$SB/fleet-connect.py"
cat > "$SB/fleet-connect.py" <<EOF
#!/usr/bin/env python3
import sys
open("$WORK/fc.log", "a").write(" ".join(sys.argv[1:]) + "\n")
EOF
WID="11111111-1111-4111-8111-111111111111/issue-7"
cache mac-b:online:2
: > "$WORK/connect.log"; tick; sleep 0.3
[ -S "$WD/mac-b.sock" ] || fail 'D: no warm master to ride'
: > "$WORK/ssh.log"; rm -f "$WORK/fc.log"
FLEET_REMOTE_SSH_CMD="$SB/fleet-shell.sh ssh" FLEET_REMOTE_BIN=rb bash "$SB/fleet-remote-view.sh" run --shell mac-b "$WID" >/dev/null 2>&1; rc=$?
eq 'D: the pane ended cleanly' 0 "$rc"
sl=$(cat "$WORK/ssh.log")
has 'D: the session rode the warm master' "$sl" "RUN -tt -o ClearAllForwardings=yes -o ControlMaster=no -S $WD/mac-b.sock mac-b bash rb/fleet-remote-view.sh attach --shell"
hasnt 'D: fleet connect never ran' "$(cat "$WORK/fc.log" 2>/dev/null)" 'mac-b'
hasnt 'D: the warm master was not closed by the pane' "$sl" "EXIT $WD/mac-b.sock"
[ -S "$WD/mac-b.sock" ] || fail 'D: the warm master is gone after the pane'
# cold: no warm master → fleet connect, with the new keepalive
FLEET_SHELL_WARM=0 FLEET_REMOTE_SSH_CMD="$SB/fleet-shell.sh ssh" FLEET_REMOTE_BIN=rb bash "$SB/fleet-remote-view.sh" run --shell mac-b "$WID" >/dev/null 2>&1
fc=$(cat "$WORK/fc.log" 2>/dev/null)
has 'D: cold → fleet connect --enter' "$fc" '--enter mac-b'
for o in ServerAliveInterval=2 ServerAliveCountMax=3 'IPQoS=lowdelay throughput' Compression=no ControlMaster=yes; do
  has "D: cold master carries $o" "$fc" "-o $o"
done
hasnt 'D: the old 5 s keepalive is gone' "$fc" 'ServerAliveInterval=5'

# ================================================================================
# L. login (issue #2987) — the sessions on mac-b are in the fleet of login `carol`
#    (`fleet_logins`), the person's default login is another: the warm master is
#    `mac-b@carol.sock`, opened as carol (FLEET_CONNECT_LOGIN), and `run` for a
#    session of that fleet rides it. Before: one `mac-b.sock` as the default login,
#    which `run` refused to ride for carol — every switch a private master.
rm -rf "$WD"; : > "$WORK/connect.log"; : > "$WORK/ssh.log"
LU=22222222-2222-4222-8222-222222222222
printf '%s\tcarol\n' "$LU" > "$G/fleet_logins"
cat > "$WORK/connect" <<EOF
#!/bin/bash
printf '%s login=%s\n' "\$*" "\${FLEET_CONNECT_LOGIN:-}" >> "$WORK/connect.log"
for a in "\$@"; do case "\$a" in ControlPath=*) ctl=\${a#ControlPath=} ;; esac; done
[ -n "\${ctl:-}" ] && python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "\$ctl"
[ -n "\${FLEET_CONNECT_ROUTE_FILE:-}" ] && printf '{"machine": "mac-b", "kind": "direct", "name": "tailnet", "login": "%s"}\n' "\${FLEET_CONNECT_LOGIN:-dave}" > "\$FLEET_CONNECT_ROUTE_FILE"
exit 0
EOF
cache mac-b:online:2
printf 'wid:%s/issue-3\037mac-b\037online\n' "$LU" >> "$G/remote_$S"
tick; sleep 0.5
log=$(cat "$WORK/connect.log")
has 'L: the master is the login'"'"'s own: mac-b@carol.sock' "$log" "ControlPath=$WD/mac-b@carol.sock"
has 'L: …opened as that login' "$log" 'login=carol'
eq 'L: one master, not one per login it does not need' 1 "$(grep -c . "$WORK/connect.log")"
[ -S "$WD/mac-b@carol.sock" ] || fail 'L: mac-b@carol.sock is up'
: > "$WORK/ssh.log"
FLEET_CONF_DIR="$WORK/conf" FLEET_REMOTE_SSH_CMD="$SB/fleet-shell.sh ssh" FLEET_REMOTE_BIN=rb \
  bash "$SB/fleet-remote-view.sh" run --shell mac-b "$LU/issue-3" >/dev/null 2>&1
sl=$(cat "$WORK/ssh.log")
has 'L: run rides the login'"'"'s warm master' "$sl" "-S $WD/mac-b@carol.sock"
has 'L: …as that login' "$sl" '-l carol'
hasnt 'L: …no private master' "$(cat "$WORK/fc.log" 2>/dev/null)" "$LU"
# a tick with the login's sessions gone closes its master
cache mac-b:online:2
: > "$WORK/ssh.log"; tick
has 'L: no session of that login left → its master closed' "$(cat "$WORK/ssh.log")" "EXIT $WD/mac-b@carol.sock"
rm -f "$G/fleet_logins"
cat > "$WORK/connect" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/connect.log"
for a in "\$@"; do case "\$a" in ControlPath=*) ctl=\${a#ControlPath=} ;; esac; done
[ -n "\${ctl:-}" ] && python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "\$ctl"
exit 0
EOF
rm -rf "$WD"; : > "$WORK/connect.log"; tick; sleep 0.3

# ================================================================================
# E. sources — a warm master answers when the hub is lost
awk '/^node_ssh_host\(\) \{/ || /^node_sources\(\) \{/ { on = 1 } on { print } on && /^}/ { on = 0 }' \
  "$BIN/fleet-hub-sessions.sh" > "$WORK/ns.sh"
out=$( CLIENT="$S" bash -c '. "$1"; node_sources' _ "$WORK/ns.sh" 2>/dev/null)
eq 'E: the warm master is a node source' "$(printf 'mac-b\tmac-b\t%s' "$WD/mac-b.sock")" "$out"

# ================================================================================
# F. e2e — the client-mode loop's log
now=$(date +%s)
iso() { python3 -c 'import datetime,sys; print(datetime.datetime.utcfromtimestamp(float(sys.argv[1])).strftime("%Y-%m-%dT%H:%M:%S.%f000Z"))' "$1" 2>/dev/null; }
sj() {   # <state-7> <observed-7> <state-9>
  cat > "$WORK/sess.json" <<EOF
{"sessions": [
 {"worker_id": "$WID", "machine_name": "mac-b", "os_user": "bob", "availability": "online", "observed_at": "$2",
  "worker": {"issue": 7, "repo": "a/b", "state": "$1", "agent": "claude", "name": "issue-7", "needs": ""}},
 {"worker_id": "11111111-1111-4111-8111-111111111111/issue-9", "machine_name": "mac-b", "os_user": "bob", "availability": "online", "observed_at": "$2",
  "worker": {"issue": 9, "repo": "a/b", "state": "$3", "agent": "claude", "name": "issue-9", "needs": ""}}],
 "nodes": [{"machine_name": "mac-b", "availability": "online", "sessions": 2, "observed_at": "$2"}]}
EOF
}
ref() { FLEET_HUB_SESSIONS_CLIENT="$S" CCQUOTA_FLEET=1 FLEET_HUB_SESSIONS_CMD="cat $WORK/sess.json" FLEET_HUB_SESSIONS_USER=bob \
        bash "$BIN/fleet-hub-sessions.sh" --refresh >/dev/null 2>&1; }
rm -f "$G/remote_$S" "$G/hub_e2e.log"
sj working "$(iso "$now")" idle; ref
[ -s "$G/remote_$S" ] || fail 'F: the client-mode refresh wrote no cache'
[ -e "$G/hub_e2e.log" ] && fail 'F: the first cache logged a change'
sj needs "$(iso "$(python3 -c "import time; print(time.time() - 0.25)")")" idle; ref
lines=$(cat "$G/hub_e2e.log" 2>/dev/null)
eq 'F: one line for the one row that moved' 1 "$(printf '%s\n' "$lines" | grep -c .)"
has 'F: the line names the row and its new state' "$lines" "$WID needs|-"
lag=$(printf '%s\n' "$lines" | awk '{ print $3 }')
case "$lag" in ''|*[!0-9]*) fail 'F: lag not a number' "$lag" ;; *) [ "$lag" -ge 200 ] && [ "$lag" -lt 5000 ] || fail 'F: lag ≈ 250 ms' "$lag" ;; esac
out=$(bash "$BIN/fleet-hub-sessions.sh" --e2e 2>&1); rc=$?
eq 'F: --e2e exit 0' 0 "$rc"
has 'F: --e2e reads n · median · max' "$out" "n 1 · median ${lag}ms · max ${lag}ms"
ref
eq 'F: an unchanged answer logs nothing' 1 "$(grep -c . "$G/hub_e2e.log")"
# not the shell (a node's fleet): never logged
rm -f "$G/hub_e2e.log"
FLEET_SESSION_FAKE=1 CCQUOTA_FLEET=1 FLEET_HUB_SESSIONS_CMD="cat $WORK/sess.json" bash "$BIN/fleet-hub-sessions.sh" --refresh >/dev/null 2>&1
[ -e "$G/hub_e2e.log" ] && fail 'F: a node (no client knob) wrote the e2e log'

printf 'fleet-shell-warm selftest: %s (%d checks, %d failed)\n' "$([ "$FAIL" = 0 ] && echo OK || echo FAIL)" "$CHECKS" "$FAIL"
[ "$FAIL" = 0 ]
