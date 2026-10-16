#!/bin/bash
# fleet-term-attach-selftest.sh — bin/fleet-term-attach.sh, a browser terminal's
# one command (claude-fleet#3838, EPIC #3836 C1), on an ISOLATED tmux server and a
# sandbox FLEET_CONF_DIR: it attaches a real terminal (a python pty) to a grouped
# view on the target window, and when the terminal hangs up the view is gone
# within 30 s while the fleet session, its windows and their processes all stay
# (BREAK-IT `term-view-kills-session`). Also: an unknown worker, a bad target, a
# taken view are refused with no view left behind; personal lands on the
# persistent home pane; native menu/select/shell/return work without starting AI.
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
unset TMUX TMUX_PANE FLEET_SESSION FLEET_CLIENT FLEET_SHELL CCQUOTA_FLEET

WORK=$(mktemp -d "${TMPDIR:-/tmp}/term-attach.XXXXXX")
RS="ttat$$"
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_STATUS_G="$WORK/global"
export TMPDIR="$WORK/tmp" SHELL=/bin/sh FLEET_UI_LANG=en
mkdir -p "$HOME" "$TMPDIR" "$FLEET_STATUS_G"
export FLEET_VIEW_ROWS_CMD="cat '$WORK/rows'"
export FLEET_VIEW_FIRST_CMD="echo unexpected >> '$WORK/first'"
: > "$WORK/rows"
mkdir -p "$FLEET_CONF_DIR/fleets/$RS" "$WORK/main"
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s\n' "$WORK/main" > "$FLEET_CONF_DIR/fleets/$RS/conf"
tt() { tmux -L "$RS" "$@"; }
cleanup() { tt kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

tt -f /dev/null new-session -d -s "$RS" -n home -x 120 -y 32 'exec /bin/sh'
tt new-window -d -t "=$RS:" -n wk 'sleep 600'
W=$(tt list-windows -t "=$RS" -F '#{window_id} #{window_name}' | awk '$2 == "wk" { print $1 }')
tt set-option -w -t "$W" @fleet_id fid-1
H=$(tt display-message -p -t "=$RS:home" '#{window_id}')
HPID=$(tt display-message -p -t "$H" '#{pane_pid}')
tt set-option -w -t "$H" @fleet_role home
tt set-option -w -t "$W" @fleet_role worker
US=$'\037'
row() { local IFS="$US"; printf '%s\n' "$*"; }
row "$W" working x wk ' ' '' 0 '' '' '#1' - 50% ok 'Browser worker' merged '' '' '' '' > "$WORK/rows"
PANEPID=$(tt display-message -p -t "$W" '#{pane_pid}')
NWIN=$(tt list-windows -t "=$RS" | wc -l | tr -d ' ')

# run <view> <target> — the attach on a real pty, in the background; its pid in P.
run() {
  python3 - "$BIN/fleet-term-attach.sh" "$1" "$2" "$WORK/$1.rc" "$WORK/$1.out" "$WORK/$1.in" >/dev/null 2>&1 <<'PY' &
import os, pty, sys, time, select, signal, fcntl, termios, struct
script, view, target, rcf, outf, inf = sys.argv[1:7]
out = open(outf, "wb")
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"   # what term-pty gives it
    os.execvp("bash", ["bash", script, "--view", view, "--target", target])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 120, 0, 0))
input_file = open(inf, "w+b", buffering=0)
status = None
# keep the terminal drained; stop when told (SIGUSR1) by hanging it up
stop = []
signal.signal(signal.SIGUSR1, lambda *a: stop.append(1))
deadline = time.time() + 60
while time.time() < deadline and not stop:
    b = input_file.read()
    if b:
        os.write(fd, b)
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            b = os.read(fd, 4096)
            if not b:
                break
            out.write(b); out.flush()
        except OSError:
            break
    done, status = os.waitpid(pid, os.WNOHANG)
    if done:
        break
    status = None
if stop or time.time() >= deadline:
    os.close(fd)           # the hang-up: the terminal's only end goes away
    try:
        os.killpg(pid, signal.SIGHUP)
    except OSError:
        pass
if status is None:
    _, status = os.waitpid(pid, 0)
open(rcf, "w").write(str(os.waitstatus_to_exitcode(status)))
PY
  P=$!
}
waitfor() { local i=0; while [ $i -lt "$2" ]; do eval "$1" && return 0; sleep 0.2; i=$((i + 1)); done; return 1; }

# A nested shell returns; the personal shell itself needs explicit renewal.
if [ "${1:-}" = --renew ]; then
  run web-exit personal
  waitfor 'tt list-clients -t "=$RS@view-wt-web-exit" -F x 2>/dev/null | grep -q x' 75 || bad 'renew: initial attach'
  GEN=$(python3 -c 'import json,os; s=json.load(open(os.environ["FLEET_CONF_DIR"]+"/webterm/terminal.json")); print("%s:%s"%(s["id"],s["generation"]))')
  printf 'sh\rexit\rprintf nested-returned > "$HOME/nested"\r' >> "$WORK/web-exit.in"
  waitfor '[ -f "$HOME/nested" ]' 30 && ok 'nested exit returns to live personal shell' || bad 'nested exit ended personal terminal'
  printf 'exit\r' >> "$WORK/web-exit.in"
  wait "$P"
  run web-no-renew personal; wait "$P"
  [ "$(cat "$WORK/web-no-renew.rc")" = 5 ] && ok 'ordinary reconnect leaves terminal ended' || bad 'ordinary reconnect renewed'
  FLEET_TERM_RENEW=1 FLEET_TERM_RESUME="$GEN" run web-renew personal
  if waitfor 'tt list-clients -t "=$RS@view-wt-web-renew" -F x 2>/dev/null | grep -q x' 30; then
    printf 'printf renewed > "$HOME/renewed"\r' >> "$WORK/web-renew.in"
    waitfor '[ -f "$HOME/renewed" ]' 30 && ok 'explicit renew accepts input' || bad 'renew input failed'
    [ "$(tt display-message -p -t "$W" "#{pane_pid}")" = "$PANEPID" ] && ok 'worker untouched' || bad 'worker changed'
    RENEWPID=$P
    FLEET_TERM_RENEW=1 FLEET_TERM_RESUME="$GEN" run web-stale personal; wait "$P"
    [ "$(cat "$WORK/web-stale.rc")" = 5 ] && ok 'stale renew refused' || bad 'stale renew accepted'
    FLEET_TERM_RESUME="$GEN" run web-stale-connect personal; wait "$P"
    [ "$(cat "$WORK/web-stale-connect.rc")" = 5 ] && ok 'stale connect refused' || bad 'stale connect accepted'
    FLEET_TERM_RENEW=1 FLEET_TERM_RESUME="$GEN" run web-worker-renew worker:fid-1; wait "$P"
    [ "$(cat "$WORK/web-worker-renew.rc")" = 2 ] && ok 'worker renew refused' || bad 'worker renewed'
    CURRENT=$(python3 -c 'import json,os; s=json.load(open(os.environ["FLEET_CONF_DIR"]+"/webterm/terminal.json")); print("%s:%s"%(s["id"],s["generation"]))')
    FLEET_TERM_RENEW=1 FLEET_TERM_RESUME="$CURRENT" run web-occupied personal; wait "$P"
    [ "$(cat "$WORK/web-occupied.rc")" = 4 ] && ok 'renew never steals live control' || bad 'renew stole control'
    P=$RENEWPID

  else
    bad 'explicit renew cannot reopen ended personal terminal'
  fi
  kill -USR1 "$P" 2>/dev/null; wait "$P" 2>/dev/null
  [ "$fails" = 0 ]; exit $?
fi

# Model a close whose view is gone but whose helper has not finished cleanup.
if [ "${1:-}" = --closed-lease ]; then
  python3 - "$BIN" "$RS" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("wt", sys.argv[1] + "/fleet-webterm.py")
wt = importlib.util.module_from_spec(spec); spec.loader.exec_module(wt)
sock = sys.argv[2]
name = sock + "@view-wt-old"
def tm(*a):
    rc, out = wt.tm(sock, *a)
    assert rc == 0, (a, rc, out)
    return out
tm("new-session", "-d", "-t", sock, "-s", name)
gid = tm("display-message", "-p", "-t", "=" + name + ":", "#{session_id}")
path = wt.control_path("personal")
with wt.Lock("control/.lock"):
    old, rc = wt.control_claim(path, "personal", "old", "claim")
    assert rc == 0
    old.update(socket=sock, view=gid, session=name, server_pid=wt.server_pid(sock))
    wt.write_json(path, old)
    assert wt.control_claim(path, "personal", "new", "claim")[1] == 4, "live owner must require Use here"
    tm("kill-session", "-t", gid)
    # Same name, different lifelong session id: old cleanup may not close it.
    tm("new-session", "-d", "-t", sock, "-s", name)
    new, rc = wt.control_claim(path, "personal", "new", "claim")
    assert rc == 0, ("closed view still holds its lease", new)
    assert new["epoch"] == old["epoch"] + 1
    assert wt.close_view(old)
    tm("has-session", "-t", "=" + name)
    assert wt.read_json(path)["conn"] == "new"
print("PASS closed view releases control immediately; live owner and replacement session remain fenced")
PY
  exit $?
fi

# Feed the SAME bytes as the browser through the actual PTY, never call a menu
# action directly. The row producer is a fixture; popup, keys and go are real.
# shellcheck disable=SC2034 # v and before are read by waitfor's eval in this scope
native() {
  local c="$1" v="=$RS@view-wt-$1" before
  before=$(grep -ao 'Browser worker' "$WORK/$c.out" | wc -l | tr -d ' ')
  printf '\033[927~' >> "$WORK/$c.in"
  waitfor '[ "$(grep -ao "Browser worker" "$WORK/$c.out" | wc -l | tr -d " ")" -gt "$before" ]' 75 \
    && ok "$c User927 opens native menu" || bad "$c User927 did not draw native menu"
  printf 'Browser worker\r' >> "$WORK/$c.in"
  waitfor '[ "$(tt display-message -p -t "$v:" "#{window_id}")" = "$W" ]' 50 \
    && ok "$c menu selects worker" || bad "$c menu did not select worker"
  waitfor '[ "$(tt show-options -gqv @popup_open)" = 0 ] && [ "$(tt display-message -p -t "$W" "#{pane_in_mode}")" = 0 ]' 50 \
    || bad "$c menu did not close and thaw"
  printf '\034' >> "$WORK/$c.in"
  waitfor '[ "$(tt display-message -p -t "$v:" "#{window_id}")" = "$H" ]' 50 \
    && ok "$c shell is persistent home" || bad "$c shell did not select home"
  printf 'echo WEB_SHELL_%s\r' "$c" >> "$WORK/$c.in"
  waitfor 'tt capture-pane -p -t "$H" | grep -q "^WEB_SHELL_$c"' 50 \
    && ok "$c real shell accepts input" || bad "$c shell input lost"
  printf '\034' >> "$WORK/$c.in"
  waitfor '[ "$(tt display-message -p -t "$v:" "#{window_id}")" = "$W" ]' 50 \
    && ok "$c shell returns to worker" || bad "$c shell did not return"
  before=$(grep -ao 'Browser worker' "$WORK/$c.out" | wc -l | tr -d ' ')
  printf '\035p' >> "$WORK/$c.in"
  waitfor '[ "$(grep -ao "Browser worker" "$WORK/$c.out" | wc -l | tr -d " ")" -gt "$before" ]' 75 \
    && ok "$c Ctrl+] p opens native menu" || bad "$c prefix menu did not draw"
  printf '\033' >> "$WORK/$c.in"
  waitfor '[ "$(tt show-options -gqv @popup_open)" = 0 ] && [ "$(tt display-message -p -t "$W" "#{pane_in_mode}")" = 0 ]' 50 \
    || bad "$c prefix menu did not close and thaw"
}

# A worker disappearing must not send pending browser input to tmux's next window.
if [ "${1:-}" = --auto-select ]; then
  run web-auto worker:fid-1
  waitfor 'tt list-clients -t "=$RS@view-wt-web-auto" -F x 2>/dev/null | grep -q x' 75 || bad "auto-select no controller"
  sleep 0.4
  tt kill-window -t "$W"
  ! tt has-session -t "=$RS@view-wt-web-auto" 2>/dev/null && ok "auto-select closes view synchronously" || bad "auto-select exposed another window"
  kill -USR1 "$P" 2>/dev/null; wait "$P" 2>/dev/null
  [ "$(tt display-message -p -t "$H" '#{pane_pid}')" = "$HPID" ] && ok "auto-select preserved home" || bad "auto-select replaced home"
  [ "$fails" = 0 ]; exit $?
fi

# A: worker — attached on its window; hang up ⇒ the view goes, the fleet stays.
run web-a1 worker:fid-1
if waitfor 'tt has-session -t "=$RS@view-wt-web-a1" 2>/dev/null && [ -n "$(tt list-clients -t "=$RS@view-wt-web-a1" 2>/dev/null)" ]' 50; then
  AP=$P
  ok "A an attached view $RS@view-wt-web-a1"
  G=$(tt list-sessions -F '#{session_name} #{session_id}' | awk -v n="$RS@view-wt-web-a1" '$1 == n { print $2 }')
  cur=$(tt display-message -p -t "$G:" '#{window_id}')
  [ "$cur" = "$W" ] && ok "A it shows the worker's window" || bad "A it shows $cur, want $W"
  [ "$(tt show-options -v -t "$G" destroy-unattached 2>/dev/null)" = on ] \
    && ok "A destroy-unattached is on once attached" || bad "A destroy-unattached is not on"
  [ "$(tt show-options -v -t "$G" key-table)" = fleet-webterm ] && ok "A fenced native Fleet keys" || bad "A missing native keys"
  [ "$(tt show-options -v -t "$G" prefix)" = None ] && ok "A raw tmux switching disabled" || bad "A raw tmux prefix bypass"
  native web-a1
  bash "$BIN/fleet-term-attach.sh" --view web-a1 --target worker:fid-1 > "$WORK/duplicate.out"
  [ "$?" = 5 ] && ok "A duplicate connection refused" || bad "A duplicate connection accepted"
  run web-denied worker:fid-1; wait "$P" 2>/dev/null
  [ "$(cat "$WORK/web-denied.rc")" = 4 ] && ok "A second controller paused before attach" || bad "A second controller attached"
  tt has-session -t "=$RS@view-wt-web-denied" 2>/dev/null && bad "A refused controller left a view"
  P=$AP
else
  bad "A no attached view appeared: $(tr -d '\033' < "$WORK/web-a1.out" 2>/dev/null | tr '\r\n' '  ' | cut -c1-300) rc=$(cat "$WORK/web-a1.rc" 2>/dev/null) tmux=$(tmux -V)"
fi
t0=$(date +%s)
kill -USR1 "$P" 2>/dev/null
if waitfor '! tt has-session -t "=$RS@view-wt-web-a1" 2>/dev/null' 150; then
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
tt new-session -d -t "=$RS" -s "$RS@view-wt-web-b3"
run web-b3 worker:fid-1; wait "$P" 2>/dev/null
[ "$(cat "$WORK/web-b3.rc" 2>/dev/null)" = 5 ] && ok "B a taken view: exit 5" || bad "B a taken view: exit $(cat "$WORK/web-b3.rc" 2>/dev/null)"
tt has-session -t "=$RS@view-wt-web-b3" 2>/dev/null && ok "B …and the other's view is untouched" || bad "B the other's view was killed"
tt kill-session -t "=$RS@view-wt-web-b3"
[ "$(tt list-sessions -F '#{session_name}' | grep -c .)" = 1 ] && ok "B no view left behind" || bad "B views left: $(tt list-sessions -F '#{session_name}' | tr '\n' ' ')"

# C: personal — the persistent home, even when the fleet selected a worker.
tt select-window -t "=$RS:$W"
run web-c1 personal
if waitfor 'tt list-clients -t "=$RS@view-wt-web-c1" -F x 2>/dev/null | grep -q x' 75; then
  G=$(tt list-sessions -F '#{session_name} #{session_id}' | awk -v n="$RS@view-wt-web-c1" '$1 == n { print $2 }')
  [ "$(tt display-message -p -t "$G:" '#{window_id}')" = "$H" ] && ok "C personal lands on persistent home" || bad "C personal landed elsewhere"
  native web-c1
else
  bad "C no personal view"
fi
kill -USR1 "$P" 2>/dev/null; wait "$P" 2>/dev/null
waitfor '! tt has-session -t "=$RS@view-wt-web-c1" 2>/dev/null' 150 && ok "C its view goes with it" || bad "C its view stayed"
[ "$(tt list-windows -t "=$RS" | wc -l | tr -d ' ')" = "$NWIN" ] && ok "C no window was made" || bad "C a window was made"

# D: takeover fences the old real attachment before returning a new epoch.
run web-d1 personal; DP=$P
waitfor 'tt list-clients -t "=$RS@view-wt-web-d1" -F x 2>/dev/null | grep -q x' 75 || bad "D no first controller"
python3 "$BIN/fleet-webterm.py" control take --target personal --conn web-d2 > "$WORK/take.json"
! tt has-session -t "=$RS@view-wt-web-d1" 2>/dev/null && ok "D take fenced old view" || bad "D old view survived take"
run web-d2 personal
waitfor 'tt list-clients -t "=$RS@view-wt-web-d2" -F x 2>/dev/null | grep -q x' 75 || bad "D no replacement controller"
wait "$DP" 2>/dev/null
python3 "$BIN/fleet-webterm.py" control check --target personal --conn web-d2 --epoch "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["epoch"])' "$WORK/take.json")" >/dev/null \
  && ok "D old cleanup preserves new epoch" || bad "D old cleanup released new epoch"
kill -USR1 "$P" 2>/dev/null; wait "$P" 2>/dev/null
waitfor '! tt has-session -t "=$RS@view-wt-web-d2" 2>/dev/null' 150 || bad "D replacement view stayed"
[ "$(tt display-message -p -t "$H" '#{pane_pid}')" = "$HPID" ] && ok "D persistent shell pid unchanged" || bad "D shell was replaced"
[ "$(tt list-windows -t "=$RS" | wc -l | tr -d ' ')" = "$NWIN" ] && ok "D no extra shell or agent" || bad "D extra window"
[ ! -s "$WORK/first" ] && ok "D never auto-started AI" || bad "D automatic session start"
[ "$(find "$FLEET_CONF_DIR/remote-views" -name 'wt-web-*' | wc -l | tr -d ' ')" = 0 ] && ok "D no connection rows or spools left" || {
  bad "D connection registry leaked"
  find "$FLEET_CONF_DIR/remote-views" -name 'wt-web-*' -print
}
# A changed generation is not first use: never remake the shell automatically.
tt respawn-pane -k -t "$H"
run web-ended personal; wait "$P" 2>/dev/null
[ "$(cat "$WORK/web-ended.rc")" = 5 ] && ok "D lost shell stays ended" || bad "D lost shell silently renewed"

[ "$fails" = 0 ] && { echo "fleet-term-attach-selftest: all passed"; exit 0; }
echo "fleet-term-attach-selftest: $fails failed"; exit 1
