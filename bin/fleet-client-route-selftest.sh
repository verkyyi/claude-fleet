#!/bin/bash
# fleet-client-route-selftest.sh — the `fleet` client is the ONLY way in, and its
# line is always the fastest one (issue #1628, EPIC #1615 C11, after the
# 2026-10-05 change of course: no fallback to ssh-ing into a machine's own list).
# Covers bin/fleet, fleet-shell.sh's fail_start + client_where, tmux-status.sh's
# `cr=`, fleet-connect.py's FLEET_CONNECT_ROUTE_FILE / FLEET_CONNECT_RETEST /
# --probe-direct, and fleet-remote-view.sh's upgrader (relay → direct).
#
# Nothing real is reached: fleet-connect.py is a FAKE in the dispatcher legs (it
# records its argv), the real one in C runs against a loopback SSH-banner server
# and a fake `ssh` on PATH; tmux is a fake (A) or an isolated socket (`-L
# <label>`, killed at the end) — never the operator's.
#   A. client only — the client starts (a fake fleet-shell.sh): connect never runs;
#                    the client failing before its attach (a fake tmux whose
#                    new-session fails) → ONE line 客户端起不来：…, exit 1, no
#                    `--enter`; tmux 3.1 / no tmux → the install hint, exit 1,
#                    connect never run
#   B. over ssh    — the iPad / iPhone way: the real fleet-shell.sh run with
#                    SSH_CONNECTION set on a tty starts the same client on this
#                    machine (its own -L server) and marks `@fleet_client_remote`
#                    = `<tty>|<machine>`; a local start on another tty leaves it,
#                    on that tty clears it
#   C. connect     — the real fleet-connect.py: FLEET_CONNECT_ROUTE_FILE gets the
#                    route; --probe-direct answers 0 while the banner server is
#                    up, 1 once it is gone or for an unknown machine;
#                    FLEET_CONNECT_RETEST=1 skips the remembered route
#   D. bar         — tmux-status.sh draws 客户端在 m5 上运行 for THAT tty only,
#                    at 54 columns too; no `cr=` → byte for byte
#   E. upgrade     — fleet-remote-view.sh `run --shell` in an isolated tmux, a fake
#                    ssh whose first connect says relay: the window gets
#                    @remote_route relay; the direct probe starts answering →
#                    within FLEET_CONNECT_UPGRADE_SECS + FLEET_REMOTE_IDLE_SECS + a
#                    reconnect (scaled clock: 1 s for the 15 s tick) the master is
#                    closed, the reconnect runs with FLEET_CONNECT_RETEST=1 and
#                    lands direct (@remote_route gone)
# tmux / python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { printf 'fleet-client-route selftest: tmux absent — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'fleet-client-route selftest: python3 absent — SKIP\n'; exit 0; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-client-route.XXXXXX")
SOCK="ffb$$"
export HOME="$WORK/home"; mkdir -p "$HOME/.ssh" "$HOME/.config/claude-fleet"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
export FLEET_CONF_DIR="$HOME/.config/claude-fleet"
unset TMUX TMUX_PANE FLEET_SHELL FLEET_HUB_URL FLEET_HUB_TOKEN SSH_CONNECTION FLEET_NODE_ALIASES \
      FLEET_CONNECT_RETEST FLEET_CONNECT_ROUTE_FILE FLEET_REMOTE_SSH_CMD

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 (want '$2')" "$3"; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 (want '$3')" "$2" ;; esac; }
hasnt() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 (must not hold '$3')" "$2" ;; esac; }
waitfor() {  # <secs> <cmd…> — until the command succeeds
  local n=$(( $1 * 10 )); shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
  return 1
}
SRV_PID=''
cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null
  "$REAL_TMUX" -L "$FLEET_SHELL_SESSION" kill-server 2>/dev/null
  pkill -f "fleet-shell.sh keeper $FLEET_SHELL_SESSION" 2>/dev/null
  [ -f "$WORK/master.pids" ] && while read -r p; do kill "$p" 2>/dev/null; done < "$WORK/master.pids"
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# --- a bin/ of our own: every real script, FAKE fleet-connect.py + fleet-shell.sh ---
SB="$WORK/sbin"; mkdir -p "$SB" "$WORK/conf"
for f in "$BIN"/*; do [ -f "$f" ] && ln -s "$f" "$SB/${f##*/}"; done
for f in "$BIN"/../conf/*; do [ -f "$f" ] && ln -s "$f" "$WORK/conf/${f##*/}"; done
rm -f "$SB/fleet-connect.py"
cat > "$SB/fleet-connect.py" <<EOF
#!/usr/bin/env python3
import json, os, sys
with open(os.path.join("$WORK", "connect.log"), "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\\n")
if "--pick" in sys.argv:
    print(json.dumps({"machine": "m5", "hostname": "macmini", "reason": "last", "login": "verk",
                      "machines": [{"alias": "m5", "hostname": "macmini"}]}))
sys.exit(0)
EOF
chmod +x "$SB/fleet-connect.py"
SH="$WORK/sh-bin"; mkdir -p "$SH"     # tools for a PATH with a fake tmux
for t in sh bash sed dirname readlink python3 env cat mktemp rm mkdir ln hostname tr awk head grep date sleep seq uname; do
  p=$(command -v "$t") && ln -sf "$p" "$SH/$t"
done
fake_tmux() {  # <version> <new-session rc> — a tmux on $SH
  cat > "$SH/tmux" <<EOF
#!/bin/sh
for a in "\$@"; do case "\$a" in -V) echo "tmux $1"; exit 0 ;; new-session) exit $2 ;; has-session) exit 1 ;; esac; done
exit 0
EOF
  chmod +x "$SH/tmux"
}
export FLEET_SHELL_CACHE="$WORK/shcache" FLEET_SHELL_SESSION="ffbshell$$"


# ================================================================================
# A. client only — no fallback
# ================================================================================
rm -f "$SB/fleet-shell.sh"
printf '#!/bin/sh\necho "shell $*" >> "%s/shell.log"; exit 0\n' "$WORK" > "$SB/fleet-shell.sh"; chmod +x "$SB/fleet-shell.sh"
fake_tmux 3.4 0
: > "$WORK/connect.log"
PATH="$SH" FLEET_SHELL_NO_ATTACH=1 "$SB/fleet" m5 >/dev/null 2>&1; rc=$?
eq 'A: the client opens → exit 0' 0 "$rc"
has 'A: the client ran for m5' "$(cat "$WORK/shell.log" 2>/dev/null)" 'shell m5'
eq 'A: connect never ran' '' "$(cat "$WORK/connect.log")"
rm -f "$SB/fleet-shell.sh"; ln -s "$BIN/fleet-shell.sh" "$SB/fleet-shell.sh"
fake_tmux 3.4 1                                   # new-session fails: the client cannot start
: > "$WORK/connect.log"
out=$(PATH="$SH" FLEET_SHELL_NO_ATTACH=1 "$SB/fleet" 2>&1); rc=$?
eq 'A: the client cannot start → exit 1' 1 "$rc"
has 'A: one line says why' "$out" '客户端起不来：tmux 开不了会话'
eq 'A: … and only that line' 1 "$(printf '%s\n' "$out" | grep -c .)"
hasnt 'A: no --enter (nothing else opens)' "$(cat "$WORK/connect.log")" '--enter'
fake_tmux 3.1 0
: > "$WORK/connect.log"
out=$(PATH="$SH" FLEET_SHELL_NO_ATTACH=1 "$SB/fleet" 2>&1); rc=$?
eq 'A: tmux 3.1 → exit 1' 1 "$rc"
has 'A: tmux 3.1 → says ≥ 3.2' "$out" 'tmux ≥ 3.2'
eq 'A: tmux 3.1 → connect never ran' '' "$(cat "$WORK/connect.log")"
rm -f "$SH/tmux"
out=$(PATH="$SH" FLEET_SHELL_NO_ATTACH=1 "$SB/fleet" 2>&1); rc=$?
eq 'A: no tmux → exit 1' 1 "$rc"
has 'A: no tmux → the install hint' "$out" 'brew install tmux'
eq 'A: no tmux → connect never ran' '' "$(cat "$WORK/connect.log")"

# ================================================================================
# B. over ssh — the iPad / iPhone way: the same client, on this machine
# ================================================================================
TTYBIN="$WORK/ttybin"; mkdir -p "$TTYBIN"
tty_is() { printf '#!/bin/sh\necho %s\n' "$1" > "$TTYBIN/tty"; chmod +x "$TTYBIN/tty"; }
mark() { "$REAL_TMUX" -L "$FLEET_SHELL_SESSION" show-options -gqv @fleet_client_remote 2>/dev/null; }
tty_is /dev/ttys901
PATH="$TTYBIN:$PATH" SSH_CONNECTION='10.0.0.9 50000 10.0.0.5 22' FLEET_NODE_ALIASES="$(hostname -s | cut -d. -f1)=m5" \
  FLEET_SHELL_NO_ATTACH=1 FLEET_REMOTE_SSH_CMD=/usr/bin/false "$SB/fleet" >/dev/null 2>"$WORK/b.err"; rc=$?
eq 'B: over ssh the client starts here (exit 0)' 0 "$rc"
CHECKS=$((CHECKS + 1)); "$REAL_TMUX" -L "$FLEET_SHELL_SESSION" has-session -t "=$FLEET_SHELL_SESSION" 2>/dev/null \
  || fail 'B: its own -L server is up' "$(cat "$WORK/b.err")"
eq 'B: the mark names this tty and this machine' '/dev/ttys901|m5' "$(mark)"
tty_is /dev/ttys902
PATH="$TTYBIN:$PATH" FLEET_SHELL_NO_ATTACH=1 FLEET_REMOTE_SSH_CMD=/usr/bin/false "$SB/fleet-shell.sh" >/dev/null 2>&1 </dev/null
eq 'B: a local start on ANOTHER tty leaves it' '/dev/ttys901|m5' "$(mark)"
tty_is /dev/ttys901
PATH="$TTYBIN:$PATH" FLEET_SHELL_NO_ATTACH=1 FLEET_REMOTE_SSH_CMD=/usr/bin/false "$SB/fleet-shell.sh" >/dev/null 2>&1 </dev/null
eq 'B: a local start on THAT tty clears it' '' "$(mark)"

# ================================================================================
# C. connect — the real fleet-connect.py
# ================================================================================
python3 - "$WORK/port" <<'EOF' &
import socket, sys, threading
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(16)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
while True:
    c, _ = s.accept()
    try:
        c.sendall(b"SSH-2.0-selftest\r\n")
    finally:
        c.close()
EOF
SRV_PID=$!
waitfor 5 test -s "$WORK/port" || fail 'C: the banner server did not start'
PORT=$(cat "$WORK/port")
mkdir -p "$XDG_CACHE_HOME/claude-fleet"
python3 - "$XDG_CACHE_HOME/claude-fleet/connect.json" "$PORT" <<'EOF'
import json, sys, time
r = {"name": "lan", "kind": "direct", "host": "127.0.0.1", "port": int(sys.argv[2])}
json.dump({"last": "m5", "machines": {"m5": {"at": time.time(), "hub": "", "label": "m5", "login": "verk",
          "machine": {"alias": "m5", "hostname": "macmini"}, "route": r, "routes": [r]}}}, open(sys.argv[1], "w"))
EOF
FAKESSH="$WORK/fakessh"; mkdir -p "$FAKESSH"
printf '#!/bin/sh\necho "SSH-RAN ARGS=$*"\n' > "$FAKESSH/ssh"; chmod +x "$FAKESSH/ssh"
out=$(PATH="$FAKESSH:$PATH" FLEET_CONNECT_ROUTE_FILE="$WORK/route.json" \
      python3 "$BIN/fleet-connect.py" m5 2>&1); rc=$?
eq 'C: connect → ssh ran, exit 0' 0 "$rc"
has 'C: … over the remembered line' "$out" 'SSH-RAN'
hasnt 'C: no fallback words, ever' "$out" '直连'
has 'C: the route file' "$(cat "$WORK/route.json" 2>/dev/null)" '"kind": "direct"'
python3 "$BIN/fleet-connect.py" --probe-direct m5 >/dev/null 2>&1; rc=$?
eq 'C: --probe-direct with the line up → 0' 0 "$rc"
python3 "$BIN/fleet-connect.py" --probe-direct m9 >/dev/null 2>&1; rc=$?
eq 'C: --probe-direct for an unknown machine → 1' 1 "$rc"
out=$(PATH="$FAKESSH:$PATH" FLEET_CONNECT_RETEST=1 python3 "$BIN/fleet-connect.py" m5 2>&1); rc=$?
hasnt 'C: FLEET_CONNECT_RETEST=1 skips the remembered line' "$out" 'SSH-RAN'
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=''
FLEET_CONNECT_PROBE_TIMEOUT=1 python3 "$BIN/fleet-connect.py" --probe-direct m5 >/dev/null 2>&1; rc=$?
eq 'C: --probe-direct with the line down → 1' 1 "$rc"

# ================================================================================
# D. the bar — 客户端在 m5 上运行, for that tty only
# ================================================================================
st() { ( cd "$SB" && TMPDIR="$WORK/st" bash "$SB/tmux-status.sh" sess=x win=@1 remote= acct= wsf= wscf= wsaved= rl5= rl7= "$@" 2>/dev/null ); }
mkdir -p "$WORK/st"
base=$(st cw=120 rr= cr=)
eq 'D: no cr= → the bar byte for byte' "$(st cw=120)" "$base"
has 'D: the line for that tty' "$(st cw=120 rr= 'cr=/dev/ttys901:/dev/ttys901|m5')" '客户端在 m5 上运行'
has 'D: at 54 columns too' "$(st cw=54 rr= 'cr=/dev/ttys901:/dev/ttys901|m5')" '客户端在 m5 上运行'
eq 'D: another client (tty) → nothing' "$base" "$(st cw=120 rr= 'cr=/dev/ttys902:/dev/ttys901|m5')"
"$REAL_TMUX" -L "$SOCK" -f /dev/null new-session -d -s "$SOCK" -x 120 -y 30 'sleep 600' || fail 'E: isolated tmux'

# ================================================================================
# E. upgrade — relay → direct on the next quiet moment
# ================================================================================
ESSH="$WORK/essh"; mkdir -p "$ESSH"
cat > "$ESSH/ssh" <<EOF
#!/bin/bash
op=''; ctl=''
while [ \$# -gt 0 ]; do
  case "\$1" in
    -O) op=\$2; shift 2 ;;
    -S) ctl=\$2; shift 2 ;;
    -o) case "\$2" in ControlPath=*) ctl=\${2#ControlPath=} ;; esac; shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
if [ -n "\$op" ]; then
  [ -S "\$ctl" ] || exit 255
  case "\$op" in
    check) exit 0 ;;
    exit) kill "\$(cat "\$ctl.mpid" 2>/dev/null)" 2>/dev/null; rm -f "\$ctl"; exit 0 ;;
  esac
  exit 0
fi
case "\$*" in
  *" attach "*)
    n=\$(( \$(cat "$WORK/connects" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$WORK/connects"
    echo "\$n retest=\${FLEET_CONNECT_RETEST:-} \$(date +%s)" >> "$WORK/connect-e.log"
    # as fleet-connect.py would: the first connect is over the relay, later ones direct
    if [ "\$n" = 1 ]; then k=relay; else k=direct; fi
    [ -n "\${FLEET_CONNECT_ROUTE_FILE:-}" ] && printf '{"machine": "m5", "kind": "%s", "name": "x"}\n' "\$k" > "\$FLEET_CONNECT_ROUTE_FILE"
    python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); time.sleep(600)' "\$ctl" &
    echo \$! > "\$ctl.mpid"; echo \$! >> "$WORK/master.pids"
    wait; exit 255 ;;
  *" watch "*) exit 0 ;;
esac
exit 0
EOF
chmod +x "$ESSH/ssh"
printf '#!/bin/sh\n[ -f "%s/direct.up" ]\n' "$WORK" > "$WORK/probe"; chmod +x "$WORK/probe"
"$REAL_TMUX" -L "$SOCK" new-window -d -n E -P -F '#{window_id}' \
  "env FLEET_REMOTE_SSH_CMD=$ESSH/ssh FLEET_CONNECT_PROBE_CMD=$WORK/probe FLEET_CONNECT_UPGRADE_SECS=1 FLEET_REMOTE_IDLE_SECS=0 FLEET_REMOTE_BIN=$BIN FLEET_REMOTE_VIA_HUB=0 TMPDIR=$WORK bash $BIN/fleet-remote-view.sh run --shell m5 -" \
  > "$WORK/ewin"
EW=$(cat "$WORK/ewin")
route_opt() { "$REAL_TMUX" -L "$SOCK" show-options -wqv -t "$EW" @remote_route 2>/dev/null; }
is_relay() { [ "$(route_opt)" = relay ]; }
waitfor 10 is_relay || fail 'E: the relay connection marks @remote_route relay' "$(route_opt)"
sleep 2                                            # a few failed probes: nothing moves
eq 'E: the probe failing → still one connection' 1 "$(cat "$WORK/connects" 2>/dev/null)"
t0=$(date +%s); : > "$WORK/direct.up"
two() { [ "$(cat "$WORK/connects" 2>/dev/null)" = 2 ]; }
waitfor 10 two || fail 'E: the direct line answered → a second connection' "$(cat "$WORK/connect-e.log" 2>/dev/null)"
t1=$(tail -n 1 "$WORK/connect-e.log" | awk '{ print $3 }')
CHECKS=$((CHECKS + 1)); [ $(( ${t1:-99999} - t0 )) -le 4 ] || fail "E: switched within tick + idle + reconnect (scaled ≤ 4s)" "$(( ${t1:-0} - t0 ))s"
has 'E: the reconnect re-measures (FLEET_CONNECT_RETEST=1)' "$(tail -n 1 "$WORK/connect-e.log")" 'retest=1'
has 'E: the first connect was not a retest' "$(head -n 1 "$WORK/connect-e.log")" '1 retest= '
not_relay() { [ -z "$(route_opt)" ]; }
waitfor 5 not_relay || fail 'E: on the direct line @remote_route is gone' "$(route_opt)"
sleep 2
eq 'E: on the direct line no further switch' 2 "$(cat "$WORK/connects")"

printf 'fleet-client-route selftest: %d checks, %d failed\n' "$CHECKS" "$FAIL"
[ "$FAIL" -eq 0 ]
