#!/bin/bash
# fleet-fallback-selftest.sh — the shell is the default, the direct way is the
# fallback, and the line is always the fastest one (issue #1628, EPIC #1615 C11):
# bin/fleet's four fallback reasons, fleet-shell.sh's fail_start, fleet-connect.py's
# FLEET_FALLBACK_REASON / FLEET_CONNECT_ROUTE_FILE / FLEET_CONNECT_RETEST /
# --probe-direct, fleet-lib.sh's fleet_fallback_stamp, tmux-status.sh's 直连 line,
# and fleet-remote-view.sh's upgrader (relay → direct on the next quiet moment).
#
# Nothing real is reached: fleet-connect.py is a FAKE in the dispatcher legs (it
# records its argv + FLEET_FALLBACK_REASON), the real one in C runs against a
# loopback SSH-banner server and a fake `ssh` on PATH, tmux is either a fake (B)
# or an isolated socket (`-L <label>`, killed at the end) — never the operator's.
#   A. degenerate — the shell starts (a fake fleet-shell.sh exiting 0): nothing
#                   falls back, no reason set, connect never runs
#   B. fallback   — the shell fails before attaching (a fake tmux whose
#                   new-session fails): bin/fleet says so in one line and runs
#                   `fleet-connect.py --enter` with FLEET_FALLBACK_REASON
#                   「壳起不来：tmux 开不了会话」; FLEET_SHELL=0, tmux 3.1, an iPad
#                   (`uname -m`) and `fleet connect` each carry their own reason;
#                   no terminal (a pipe) carries none
#   C. connect    — the real fleet-connect.py: FLEET_FALLBACK_REASON → the 直连
#                   line on stderr + SendEnv=LC_FLEET_FALLBACK, LC_FLEET_FALLBACK
#                   in ssh's environment; FLEET_CONNECT_ROUTE_FILE gets the route;
#                   the cache keeps the direct routes; --probe-direct answers 0
#                   while the banner server is up, 1 once it is gone;
#                   FLEET_CONNECT_RETEST=1 skips the remembered route
#   D. bar        — fleet_fallback_stamp stamps `<tty>|m5|<reason>` from
#                   LC_FLEET_FALLBACK, a plain attach on that tty clears it, on
#                   another tty leaves it; tmux-status.sh draws
#                   直连 m5（本地壳不可用：…） for THAT tty only, the short form
#                   under 60 columns, nothing with no fb=
#   E. upgrade    — fleet-remote-view.sh `run --shell` in an isolated tmux, a fake
#                   ssh whose first connect says relay: the window gets
#                   @remote_route relay; the direct probe starts answering → within
#                   FLEET_CONNECT_UPGRADE_SECS + FLEET_REMOTE_IDLE_SECS + a reconnect
#                   (scaled clock: 1 s for the 15 s tick) the master is closed, the
#                   reconnect runs with FLEET_CONNECT_RETEST=1 and lands direct
#                   (@remote_route gone)
# tmux / python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { printf 'fleet-fallback selftest: tmux absent — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'fleet-fallback selftest: python3 absent — SKIP\n'; exit 0; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-fallback.XXXXXX")
SOCK="ffb$$"
export HOME="$WORK/home"; mkdir -p "$HOME/.ssh" "$HOME/.config/claude-fleet"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
export FLEET_CONF_DIR="$HOME/.config/claude-fleet"
unset TMUX TMUX_PANE FLEET_SHELL FLEET_HUB_URL FLEET_HUB_TOKEN FLEET_FALLBACK_REASON LC_FLEET_FALLBACK \
      FLEET_CONNECT_RETEST FLEET_CONNECT_ROUTE_FILE FLEET_SHELL_FAIL_FILE FLEET_REMOTE_SSH_CMD

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
    f.write(" ".join(sys.argv[1:]) + "\\treason=" + os.environ.get("FLEET_FALLBACK_REASON", "") + "\\n")
if "--pick" in sys.argv:
    print(json.dumps({"machine": "m5", "hostname": "macmini", "reason": "last", "login": "verk",
                      "machines": [{"alias": "m5", "hostname": "macmini"}]}))
sys.exit(0)
EOF
chmod +x "$SB/fleet-connect.py"
SH="$WORK/sh-bin"; mkdir -p "$SH"     # tools for a PATH with a fake tmux / uname
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
# A. degenerate — the shell opens: no fallback, no reason
# ================================================================================
rm -f "$SB/fleet-shell.sh"
printf '#!/bin/sh\necho "shell $*" >> "%s/shell.log"; exit 0\n' "$WORK" > "$SB/fleet-shell.sh"; chmod +x "$SB/fleet-shell.sh"
fake_tmux 3.4 0
: > "$WORK/connect.log"
out=$(PATH="$SH" FLEET_SHELL_NO_ATTACH=1 "$SB/fleet" 2>&1); rc=$?
eq 'A: the shell opens → exit 0' 0 "$rc"
has 'A: the shell ran' "$(cat "$WORK/shell.log" 2>/dev/null)" 'shell'
eq 'A: connect never ran' '' "$(cat "$WORK/connect.log")"
hasnt 'A: no 本地壳 line' "$out" '本地壳'
# the shell exiting non-zero AFTER an attach (nothing written): its own exit, no fallback
printf '#!/bin/sh\nexit 4\n' > "$SB/fleet-shell.sh"
PATH="$SH" FLEET_SHELL_NO_ATTACH=1 "$SB/fleet" >/dev/null 2>&1; rc=$?
eq 'A: a shell exit with no reason is its own (4), no fallback' 4 "$rc"
eq 'A: … and connect never ran' '' "$(cat "$WORK/connect.log")"

# ================================================================================
# B. fallback — each of the four, with its reason
# ================================================================================
rm -f "$SB/fleet-shell.sh"; ln -s "$BIN/fleet-shell.sh" "$SB/fleet-shell.sh"
fake_tmux 3.4 1                                   # new-session fails: the shell cannot start
: > "$WORK/connect.log"
out=$(PATH="$SH" FLEET_SHELL_NO_ATTACH=1 "$SB/fleet" 2>&1); rc=$?
eq 'B: shell fails → connect exit 0' 0 "$rc"
has 'B: one line says the shell could not start' "$out" '本地壳起不来（tmux 开不了会话），改为直连'
has 'B: connect --enter with the reason' "$(cat "$WORK/connect.log")" $'--enter\treason=壳起不来：tmux 开不了会话'
: > "$WORK/connect.log"
PATH="$SH" FLEET_SHELL_NO_ATTACH=1 "$SB/fleet" m5 >/dev/null 2>&1
has 'B: fleet m5 → connect --enter m5 with the reason' "$(cat "$WORK/connect.log")" $'--enter m5\treason=壳起不来：tmux 开不了会话'
: > "$WORK/connect.log"
FLEET_SHELL=0 "$SB/fleet" >/dev/null 2>&1
has 'B: FLEET_SHELL=0 → its reason' "$(cat "$WORK/connect.log")" $'--enter\treason=你设了 FLEET_SHELL=0'
fake_tmux 3.1 0
: > "$WORK/connect.log"
PATH="$SH" FLEET_SHELL_NO_ATTACH=1 "$SB/fleet" >/dev/null 2>&1
has 'B: tmux 3.1 → too old' "$(cat "$WORK/connect.log")" 'reason=tmux 3.1 太旧（要 ≥ 3.2）'
fake_tmux 3.4 0
rm -f "$SH/uname"; printf '#!/bin/sh\necho iPad13,4\n' > "$SH/uname"; chmod +x "$SH/uname"
: > "$WORK/connect.log"
PATH="$SH" FLEET_SHELL_NO_ATTACH=1 "$SB/fleet" >/dev/null 2>&1
has 'B: an iPad → its reason' "$(cat "$WORK/connect.log")" 'reason=iPad 上没有本地壳'
rm -f "$SH/uname"; ln -s "$(command -v uname)" "$SH/uname"
: > "$WORK/connect.log"
"$SB/fleet" connect m5 >/dev/null 2>&1
has 'B: fleet connect → you asked' "$(cat "$WORK/connect.log")" $'m5\treason=你选了直连（fleet connect）'
: > "$WORK/connect.log"
PATH="$SH" "$SB/fleet" </dev/null >/dev/null 2>&1
has 'B: no terminal → the direct way' "$(cat "$WORK/connect.log")" '--enter'
eq 'B: no terminal → no reason' $'--enter\treason=' "$(cat "$WORK/connect.log")"

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
printf '#!/bin/sh\necho "LC=$LC_FLEET_FALLBACK ARGS=$*"\n' > "$FAKESSH/ssh"; chmod +x "$FAKESSH/ssh"
out=$(PATH="$FAKESSH:$PATH" FLEET_FALLBACK_REASON='没有 tmux' FLEET_CONNECT_ROUTE_FILE="$WORK/route.json" \
      python3 "$BIN/fleet-connect.py" m5 2>&1); rc=$?
eq 'C: connect → ssh ran, exit 0' 0 "$rc"
has 'C: the 直连 line on stderr' "$out" 'fleet · 直连 m5（本地壳不可用：没有 tmux）'
has 'C: LC_FLEET_FALLBACK in ssh env' "$out" 'LC=m5|没有 tmux'
has 'C: ssh sends it' "$out" 'SendEnv=LC_FLEET_FALLBACK'
has 'C: the route file' "$(cat "$WORK/route.json" 2>/dev/null)" '"kind": "direct"'
out=$(PATH="$FAKESSH:$PATH" python3 "$BIN/fleet-connect.py" m5 2>&1)
hasnt 'C: no reason → no 直连 line' "$out" '直连'
hasnt 'C: no reason → no SendEnv' "$out" 'SendEnv'
python3 "$BIN/fleet-connect.py" --probe-direct m5 >/dev/null 2>&1; rc=$?
eq 'C: --probe-direct with the line up → 0' 0 "$rc"
python3 "$BIN/fleet-connect.py" --probe-direct m9 >/dev/null 2>&1; rc=$?
eq 'C: --probe-direct for an unknown machine → 1' 1 "$rc"
out=$(PATH="$FAKESSH:$PATH" FLEET_CONNECT_RETEST=1 python3 "$BIN/fleet-connect.py" m5 2>&1); rc=$?
hasnt 'C: FLEET_CONNECT_RETEST=1 skips the remembered line' "$out" 'LC='
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=''
FLEET_CONNECT_PROBE_TIMEOUT=1 python3 "$BIN/fleet-connect.py" --probe-direct m5 >/dev/null 2>&1; rc=$?
eq 'C: --probe-direct with the line down → 1' 1 "$rc"

# ================================================================================
# D. the bar — the stamp and the 直连 line
# ================================================================================
"$REAL_TMUX" -L "$SOCK" -f /dev/null new-session -d -s "$SOCK" -x 120 -y 30 'sleep 600' || fail 'D: isolated tmux'
TTYBIN="$WORK/ttybin"; mkdir -p "$TTYBIN"
tty_is() { printf '#!/bin/sh\necho %s\n' "$1" > "$TTYBIN/tty"; chmod +x "$TTYBIN/tty"; }
stamp() { ( PATH="$TTYBIN:$PATH"; export PATH; . "$BIN/fleet-lib.sh"; tmux() { "$REAL_TMUX" "$@"; }; fleet_fallback_stamp "$SOCK" ); }
opt() { "$REAL_TMUX" -L "$SOCK" show -gv @fleet_fallback_reason 2>/dev/null; }
tty_is /dev/ttys901
LC_FLEET_FALLBACK='m5|没有 tmux' stamp
eq 'D: stamped <tty>|<machine>|<reason>' '/dev/ttys901|m5|没有 tmux' "$(opt)"
tty_is /dev/ttys902
stamp
eq 'D: a plain attach on ANOTHER tty leaves it' '/dev/ttys901|m5|没有 tmux' "$(opt)"
tty_is /dev/ttys901
stamp
eq 'D: a plain attach on THAT tty clears it' '' "$(opt)"
st() { ( cd "$SB" && TMPDIR="$WORK/st" bash "$SB/tmux-status.sh" sess=x win=@1 remote= acct= wsf= wscf= wsaved= rl5= rl7= "$@" 2>/dev/null ); }
mkdir -p "$WORK/st"
base=$(st cw=120 rr= fb=)
eq 'D: no fb= → the bar byte for byte' "$(st cw=120)" "$base"
b=$(st cw=120 rr= 'fb=/dev/ttys901:/dev/ttys901|m5|没有 tmux')
has 'D: the 直连 line for that tty' "$b" '直连 m5（本地壳不可用：没有 tmux）'
b=$(st cw=54 rr= 'fb=/dev/ttys901:/dev/ttys901|m5|没有 tmux')
has 'D: narrow → the short form' "$b" '直连 m5（没有 tmux）'
hasnt 'D: narrow → no 本地壳不可用' "$b" '本地壳不可用'
b=$(st cw=120 rr= 'fb=/dev/ttys902:/dev/ttys901|m5|没有 tmux')
eq 'D: another client (tty) → nothing' "$base" "$b"

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

printf 'fleet-fallback selftest: %d checks, %d failed\n' "$CHECKS" "$FAIL"
[ "$FAIL" -eq 0 ]
