#!/bin/bash
# fleet-webterm-wheel-selftest.sh — the browser terminal's wheel (task C8X3): the
# `fleet-webterm` key table that bin/fleet_view.py's key_lines(browser=True) builds
# (`fleet-quickopen.py view-keys --browser`) must scroll like the iTerm2 看台's root
# copy. On an ISOLATED tmux server with a real (python pty) client sending SGR
# wheel reports, as xterm.js does:
#   A a pane whose program asked for the mouse (Claude Code's fullscreen
#     transcript: alternate screen, no tmux history) gets the wheel itself — it is
#     never pulled into an empty copy-mode;
#   B a plain pane with history scrolls back more than one screen in copy-mode and
#     the wheel back down leaves copy-mode at the bottom.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
command -v tmux >/dev/null 2>&1 || { echo "SKIP: no tmux"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 0; }
# the fleet's shim refuses a delete on a fleet's socket — this one is a test's
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v tmux-shim | paste -sd: -)
export PATH
unset TMUX TMUX_PANE FLEET_SESSION

WORK=$(mktemp -d "${TMPDIR:-/tmp}/wt-wheel.XXXXXX")
RS="wtwh$$"
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" TMPDIR="$WORK/tmp" FLEET_UI_LANG=en
mkdir -p "$HOME" "$TMPDIR" "$FLEET_CONF_DIR"
tt() { tmux -L "$RS" "$@"; }
cleanup() { tt kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# A: the app wants the mouse (1049 alt screen · 1000 buttons · 1006 SGR); it records what it reads
cat > "$WORK/app.sh" <<EOF
printf '\033[?1049h\033[?1000h\033[?1006hAPP'
stty raw -echo
exec cat > '$WORK/app.in'
EOF
tt -f /dev/null new-session -d -s "$RS" -n app -x 80 -y 20 "sh '$WORK/app.sh'"
tt new-window -d -t "=$RS:" -n plain "sh -c 'seq 1 500; exec cat'"
tt set-option -g mouse on
sp=$(tt display-message -p '#{socket_path}')
TMUX="$sp,0,0" python3 "$BIN/fleet-quickopen.py" view-keys --browser || bad "view-keys --browser failed"
G=$(tt display-message -p -t "=$RS:app" '#{session_id}')
tt set-option -t "$G" key-table fleet-webterm || bad "could not wear the fleet-webterm table"
sleep 0.5
[ "$(tt display-message -p -t "=$RS:app" '#{mouse_any_flag}')" = 1 ] || bad "A the app's mouse request did not reach tmux"

python3 - "$RS" "$WORK" <<'PY' > "$WORK/drive.out" 2>&1
import os, pty, select, subprocess, sys, time, fcntl, termios, struct
S, W = sys.argv[1], sys.argv[2]
def tm(*a): return subprocess.run(["tmux", "-L", S, *a], capture_output=True, text=True).stdout.strip()
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execvp("tmux", ["tmux", "-L", S, "attach", "-t", "=" + S + ":app"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 20, 80, 0, 0))
def drain(t):
    end = time.time() + t
    while time.time() < end:
        if select.select([fd], [], [], 0.05)[0]:
            try: os.read(fd, 65536)
            except OSError: return
def wheel(up, n):
    for _ in range(n):
        os.write(fd, b"\x1b[<%d;5;5M" % (64 if up else 65)); drain(0.15)
drain(1.0)
wheel(True, 3); drain(0.3)
print("A mode=%s" % tm("display-message", "-p", "-t", "=%s:app" % S, "#{pane_in_mode}"))
tm("select-window", "-t", "=%s:plain" % S); drain(0.5)
wheel(True, 8)
print("B mode=%s scroll=%s rows=%s" % (tm("display-message", "-p", "-t", "=%s:plain" % S, "#{pane_in_mode}"),
      tm("display-message", "-p", "-t", "=%s:plain" % S, "#{scroll_position}"),
      tm("display-message", "-p", "-t", "=%s:plain" % S, "#{pane_height}")))
wheel(False, 12); drain(0.3)
print("B2 mode=%s" % tm("display-message", "-p", "-t", "=%s:plain" % S, "#{pane_in_mode}"))
os.kill(pid, 9)
PY

grep -q '^A mode=0$' "$WORK/drive.out" && ok "A a mouse-wanting pane stays out of copy-mode" \
  || bad "A pulled into copy-mode: $(tr '\n' ' ' < "$WORK/drive.out")"
grep -qa $'\033\\[<64;' "$WORK/app.in" 2>/dev/null && ok "A the app itself got the wheel-up report" \
  || bad "A the app got no wheel report: $(od -c "$WORK/app.in" 2>/dev/null | head -3 | tr '\n' ' ')"
read -r _ m s r < <(grep '^B ' "$WORK/drive.out" | tr '=' ' ' | awk '{print $1, $3, $5, $7}')
[ "${m:-}" = 1 ] && [ "${s:-0}" -gt "${r:-20}" ] && ok "B a plain pane scrolls back ${s} lines (> one screen of ${r})" \
  || bad "B scrolled ${s:-?} of ${r:-?} (mode ${m:-?})"
grep -q '^B2 mode=0$' "$WORK/drive.out" && ok "B wheel back down leaves copy-mode at the bottom" \
  || bad "B still in copy-mode after the wheel down"

[ "$fails" = 0 ] && echo "PASS fleet-webterm-wheel-selftest" || echo "FAIL fleet-webterm-wheel-selftest ($fails)"
[ "$fails" = 0 ]
