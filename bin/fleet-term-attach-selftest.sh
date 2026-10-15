#!/bin/bash
# fleet-term-attach-selftest.sh — bin/fleet-term-attach.sh, a browser terminal's
# one command (claude-fleet#3838, EPIC #3836 C1), on an ISOLATED tmux server and a
# sandbox FLEET_CONF_DIR: it attaches a real terminal (a python pty) to a grouped
# view on the target window, and when the terminal hangs up the view is gone
# within 30 s while the fleet session, its windows and their processes all stay
# (BREAK-IT `term-view-kills-session`). Also: an unknown worker, a bad target, a
# taken view are refused with no view left behind; personal lands on the
# session's current window; nothing new starts.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
fails=0
ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
command -v tmux >/dev/null 2>&1 || { echo "SKIP: no tmux"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 0; }
# the fleet's shim refuses a delete on a fleet's socket — this one is a test's
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v tmux-shim | paste -sd: -)
export PATH
unset TMUX TMUX_PANE

WORK=$(mktemp -d "${TMPDIR:-/tmp}/term-attach.XXXXXX")
RS="ttat$$"
export FLEET_CONF_DIR="$WORK/conf"
mkdir -p "$FLEET_CONF_DIR/fleets/$RS" "$WORK/main"
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s\n' "$WORK/main" > "$FLEET_CONF_DIR/fleets/$RS/conf"
tt() { tmux -L "$RS" "$@"; }
cleanup() { tt kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

tt new-session -d -s "$RS" -n home -x 100 -y 30 'sleep 600'
tt new-window -d -t "=$RS:" -n wk 'sleep 600'
W=$(tt list-windows -t "=$RS" -F '#{window_id} #{window_name}' | awk '$2 == "wk" { print $1 }')
tt set-option -w -t "$W" @fleet_id fid-1
PANEPID=$(tt display-message -p -t "$W" '#{pane_pid}')
NWIN=$(tt list-windows -t "=$RS" | wc -l | tr -d ' ')

# run <view> <target> — the attach on a real pty, in the background; its pid in P.
run() {
  python3 - "$BIN/fleet-term-attach.sh" "$1" "$2" "$WORK/$1.rc" "$WORK/$1.out" >/dev/null 2>&1 <<'PY' &
import os, pty, sys, time, select, signal
script, view, target, rcf, outf = sys.argv[1:6]
out = open(outf, "wb")
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", script, "--view", view, "--target", target])
# keep the terminal drained; stop when told (SIGUSR1) by hanging it up
stop = []
signal.signal(signal.SIGUSR1, lambda *a: stop.append(1))
deadline = time.time() + 60
while time.time() < deadline and not stop:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            b = os.read(fd, 4096)
            if not b:
                break
            out.write(b); out.flush()
        except OSError:
            break
    if os.waitpid(pid, os.WNOHANG)[0]:
        break
if stop:
    os.close(fd)           # the hang-up: the terminal's only end goes away
    try:
        os.killpg(pid, signal.SIGHUP)
    except OSError:
        pass
_, st = os.waitpid(pid, 0)
open(rcf, "w").write(str(os.waitstatus_to_exitcode(st)))
PY
  P=$!
}
waitfor() { local i=0; while [ $i -lt "$2" ]; do eval "$1" && return 0; sleep 0.2; i=$((i + 1)); done; return 1; }

# A: worker — attached on its window; hang up ⇒ the view goes, the fleet stays.
run web-a1 worker:fid-1
if waitfor 'tt has-session -t "=$RS@view-web-a1" 2>/dev/null && [ -n "$(tt list-clients -t "=$RS@view-web-a1" 2>/dev/null)" ]' 50; then
  ok "A an attached view $RS@view-web-a1"
  G=$(tt list-sessions -F '#{session_name} #{session_id}' | awk -v n="$RS@view-web-a1" '$1 == n { print $2 }')
  cur=$(tt display-message -p -t "$G:" '#{window_id}')
  [ "$cur" = "$W" ] && ok "A it shows the worker's window" || bad "A it shows $cur, want $W"
  [ "$(tt show-options -v -t "$G" destroy-unattached 2>/dev/null)" = on ] \
    && ok "A destroy-unattached is on once attached" || bad "A destroy-unattached is not on"
else
  bad "A no attached view appeared: $(tr -d '\033' < "$WORK/web-a1.out" 2>/dev/null | tr '\r\n' '  ' | cut -c1-300) rc=$(cat "$WORK/web-a1.rc" 2>/dev/null) tmux=$(tmux -V)"
fi
t0=$(date +%s)
kill -USR1 "$P" 2>/dev/null
if waitfor '! tt has-session -t "=$RS@view-web-a1" 2>/dev/null' 150; then
  ok "A the hung-up terminal's view is gone in $(( $(date +%s) - t0 ))s (≤30s)"
else
  bad "A the view outlived its terminal by 30s"
fi
wait "$P" 2>/dev/null
tt has-session -t "=$RS" 2>/dev/null && ok "A the fleet session lives" || bad "A the fleet session went"
[ "$(tt list-windows -t "=$RS" | wc -l | tr -d ' ')" = "$NWIN" ] && ok "A every window is still there" || bad "A a window went"
[ "$(tt display-message -p -t "$W" '#{pane_pid}' 2>/dev/null)" = "$PANEPID" ] && kill -0 "$PANEPID" 2>/dev/null \
  && ok "A the worker's process is the same and alive ($PANEPID)" || bad "A the worker's process changed or died"
[ "$(tt list-sessions -F '#{session_name}' | grep -c .)" = 1 ] && ok "A nothing new was started" || bad "A sessions left: $(tt list-sessions -F '#{session_name}' | tr '\n' ' ')"

# B: refusals leave no view.
run web-b1 worker:nope; wait "$P" 2>/dev/null
[ "$(cat "$WORK/web-b1.rc" 2>/dev/null)" = 4 ] && ok "B an unknown worker: exit 4" || bad "B an unknown worker: exit $(cat "$WORK/web-b1.rc" 2>/dev/null)"
run web-b2 'worker:../x'; wait "$P" 2>/dev/null
[ "$(cat "$WORK/web-b2.rc" 2>/dev/null)" = 2 ] && ok "B a path for a target: exit 2" || bad "B a path for a target: exit $(cat "$WORK/web-b2.rc" 2>/dev/null)"
run notweb worker:fid-1; wait "$P" 2>/dev/null
[ "$(cat "$WORK/notweb.rc" 2>/dev/null)" = 2 ] && ok "B a view that is not web-: exit 2" || bad "B a non-web view: exit $(cat "$WORK/notweb.rc" 2>/dev/null)"
tt new-session -d -t "=$RS" -s "$RS@view-web-b3"
run web-b3 worker:fid-1; wait "$P" 2>/dev/null
[ "$(cat "$WORK/web-b3.rc" 2>/dev/null)" = 5 ] && ok "B a taken view: exit 5" || bad "B a taken view: exit $(cat "$WORK/web-b3.rc" 2>/dev/null)"
tt has-session -t "=$RS@view-web-b3" 2>/dev/null && ok "B …and the other's view is untouched" || bad "B the other's view was killed"
tt kill-session -t "=$RS@view-web-b3"
[ "$(tt list-sessions -F '#{session_name}' | grep -c .)" = 1 ] && ok "B no view left behind" || bad "B views left: $(tt list-sessions -F '#{session_name}' | tr '\n' ' ')"

# C: personal — the session's current window, nothing started.
tt select-window -t "=$RS:home"
H=$(tt display-message -p -t "=$RS:" '#{window_id}')
run web-c1 personal
if waitfor 'tt has-session -t "=$RS@view-web-c1" 2>/dev/null' 50; then
  G=$(tt list-sessions -F '#{session_name} #{session_id}' | awk -v n="$RS@view-web-c1" '$1 == n { print $2 }')
  [ "$(tt display-message -p -t "$G:" '#{window_id}')" = "$H" ] && ok "C personal lands on the current window" || bad "C personal landed elsewhere"
else
  bad "C no personal view"
fi
kill -USR1 "$P" 2>/dev/null; wait "$P" 2>/dev/null
waitfor '! tt has-session -t "=$RS@view-web-c1" 2>/dev/null' 150 && ok "C its view goes with it" || bad "C its view stayed"
[ "$(tt list-windows -t "=$RS" | wc -l | tr -d ' ')" = "$NWIN" ] && ok "C no window was made" || bad "C a window was made"

[ "$fails" = 0 ] && { echo "fleet-term-attach-selftest: all passed"; exit 0; }
echo "fleet-term-attach-selftest: $fails failed"; exit 1
