#!/usr/bin/env bash
# topbar-switch-selftest.sh — a 看台's top line follows a window close / switch at
# once (issue #3532).
#
# The 看台's status line is ONE `#()` job per client (fleet-topbar.py render --node,
# fleet-remote-view.sh rv_thin_dress), and tmux draws a job's LAST output until a
# new run finishes. Before #3532 a close or a switch first redrew the window just
# left, for as long as python took. Now the line says which window it was made for
# (own_window) and tmux itself draws the stand-in (quick_fmt) at the first redraw.
# The line's left is the brand alone (task ZDYN), so what tells one window's line
# from another's is its right: each window here wears its own context reading
# (「剩余 11%」, 「剩余 22%」 …), waited for by its % alone.
#
# A real client in a pty on an isolated socket, a 看台-like session wearing the
# line exactly as rv_thin_dress spells it (status top, every 2 s):
#   A. kill the current window → the stand-in (the brand) is redrawn ≤ 300 ms with
#      nothing of the window just left, and the new window's reading follows.
#   B. select another window → the same.
#   C. the job slowed by 1 s (`sleep 1;` in front): the stand-in still ≤ 300 ms —
#      it is tmux's, no process in between; the new reading only after the second.
#   D. the stale line yields only to its own window: rendered for window X, the
#      line expands to itself in X and to the stand-in anywhere else.
#   E. idle adds nothing: no new hook on the server, the status-interval as dressed.
#
# TOPBAR_SWITCH_BIN=<dir> runs the same legs against another bin/ (a before/after
# measurement: `git archive HEAD~ bin | tar -x -C /tmp/old`); TOPBAR_SWITCH_MEASURE=1
# prints the times and does not fail.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
TB_BIN=${TOPBAR_SWITCH_BIN:-$BIN}
MEASURE=${TOPBAR_SWITCH_MEASURE:-}
TMUX_BIN=$(command -v tmux) || { echo "SKIP: no tmux"; exit 0; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/topbar-switch.XXXXXX")
SOCK="$WORK/sock"
cleanup() { "$TMUX_BIN" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
unset TMUX TMUX_PANE
FAILS=0
fail() { echo "FAIL: $1${2:+ — $2}"; FAILS=$((FAILS + 1)); }

mkdir -p "$WORK/reg" "$WORK/g"
T() { "$TMUX_BIN" -S "$SOCK" "$@"; }

# the line exactly as rv_thin_bar spells it (no registry row, no cache: the
# window's own stamps draw it); $1 = what runs before the python (C's `sleep 1;`)
dress() {
  local pre="$1" bar
  bar="#(${pre}python3 '$TB_BIN/fleet-topbar.py' render --node view=t1 s=fleet reg='$WORK/reg' g='$WORK/g'"
  bar="$bar sock=#{q:socket_path} cw=#{client_width} w=#{window_id} pc=#{q:@peer_cur} pd=#{pane_dead}"
  bar="$bar vl=#{q:@view_lang_set}:#{q:@view_lang} nt=#{@view_notice}"
  bar="$bar ack=#{?#{e|>=:#{client_activity},#{@view_notice_hold}},1,0} up=#{q:@view_upload})"
  T set-option -t fleet status on \; set-option -t fleet status-position top \; \
    set-option -t fleet status-interval 2 \; set-option -t fleet status-format[0] "$bar"
}

T -f /dev/null new-session -d -s fleet -x 160 -y 20 -n alpha-left 'exec sleep 3600' || { echo "FAIL: no tmux server"; exit 1; }
T set-option -g exit-empty off
for n in beta-next gamma-third delta-fourth; do
  T new-window -d -t fleet: -n "$n" 'exec sleep 3600'
done
NOW=$(date +%s)
for wv in alpha-left:11 beta-next:22 gamma-third:33 delta-fourth:44; do
  T set-window-option -t "fleet:${wv%%:*}" @ctx_left "${wv##*:}" \; set-window-option -t "fleet:${wv%%:*}" @ctx_band ok \
    \; set-window-option -t "fleet:${wv%%:*}" @ctx_ts "$NOW"
done
T set-window-option -t fleet:beta-next @claude_state working
T select-window -t fleet:alpha-left
H0=$(T show-hooks -g 2>/dev/null)
dress ""

# The pty: one client attached to the 看台, 160 × 20. Commands on stdin, one per
# line: `wait <text> <secs>` (until <text> is on the screen stream since the last
# mark; `cur` = the session's current window's reading, asked then), `seen <text>`
# (whether it has been on the stream since the last mark), `mark` (forget what came
# before), `run <tmux args…>` (the clock starts as it is sent).
cat > "$WORK/term.py" <<'PY'
import fcntl, os, pty, select, struct, subprocess, sys, termios, time
tmux, sock = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execvp(tmux, [tmux, "-S", sock, "attach", "-t", "fleet"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 20, 160, 0, 0))
buf = b""
def pump(secs):
    global buf
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.005)
        if r:
            try:
                d = os.read(fd, 65536)
            except OSError:
                return
            if not d:
                return
            buf += d
def wait_for(text, secs):
    t0 = time.time()
    while time.time() - t0 < secs:
        if text.encode() in buf:
            return True
        pump(0.005)
    return text.encode() in buf
t_mark = time.time()
for line in sys.stdin:
    cmd = line.rstrip("\n").split("\t")
    if cmd[0] == "mark":
        pump(0.2); buf = b""; t_mark = time.time()
    elif cmd[0] == "run":
        buf = b""; t_mark = time.time()
        subprocess.run([tmux, "-S", sock] + cmd[1:], capture_output=True)
    elif cmd[0] == "wait":
        text = cmd[1]
        if text == "cur":   # whichever window is the session's current one now
            text = subprocess.run([tmux, "-S", sock, "display-message", "-p", "-t", "fleet:",
                                   "#{@ctx_left}"], capture_output=True, text=True).stdout.strip() + "%"
        hit = wait_for(text, float(cmd[2]))
        print("%s %s %d" % (cmd[1], "hit" if hit else "miss", int((time.time() - t_mark) * 1000)), flush=True)
    elif cmd[0] == "seen":
        pump(0.005)
        print("%s %s 0" % (cmd[1], "seen" if cmd[1].encode() in buf else "unseen"), flush=True)
os.kill(pid, 9)
PY

# ms_of <output> <text> — the ms of a hit, else 99999
ms_of() { printf '%s\n' "$1" | awk -v t="$2" '$1 == t && $2 == "hit" { print $3; f = 1 } END { if (!f) print 99999 }'; }
# unseen <label> <output> <text> — <text> never came on the stream (a `seen` line)
unseen() {
  [ -n "$MEASURE" ] && return
  if printf '%s\n' "$2" | grep -qF "$3 unseen"; then st_ok "$1"; else fail "$1" "$2"; fi
}
check() {  # <label> <ms> <limit ms>
  if [ -n "$MEASURE" ]; then echo "measure: $1 ${2}ms"; return; fi
  if [ "$2" -le "$3" ]; then st_ok "$1 (${2}ms ≤ ${3}ms)"; else fail "$1" "${2}ms > ${3}ms"; fi
}

# ---- A + B: the real line ----------------------------------------------------------
# the stand-in's mark: the brand's name, drawn at every redraw
BR=Tokenman
OUT=$(printf '%s\n' \
  "wait	11%	5" "wait	⌘P	5" "mark" \
  "run	kill-window	-t	fleet:alpha-left" "wait	$BR	3" "seen	11%" "wait	cur	3" \
  "mark" "run	select-window	-t	fleet:gamma-third" "wait	$BR	3" "seen	22%" "wait	33%	3" \
  | python3 "$WORK/term.py" "$TMUX_BIN" "$SOCK")
[ "$(ms_of "$OUT" "11%")" -lt 99999 ] || fail "the client draws the top line at all" "$OUT"
A=$(printf '%s\n' "$OUT" | sed -n '3,5p'); B=$(printf '%s\n' "$OUT" | sed -n '6,8p')
check "A: a closed window — the stand-in on the line" "$(ms_of "$A" "$BR")" 300
unseen "A: …nothing of the window just left" "$A" "11%"
check "A: …the next one's full line follows" "$(ms_of "$A" cur)" 3000
check "B: a switch — the stand-in on the line" "$(ms_of "$B" "$BR")" 300
unseen "B: …nothing of the window just left" "$B" "22%"
check "B: …the new one's full line follows" "$(ms_of "$B" "33%")" 3000

# ---- C: the job slowed by a second ---------------------------------------------------
dress "sleep 1; "
OUT=$(printf '%s\n' \
  "wait	33%	5" "wait	⌘P	5" "mark" \
  "run	kill-window	-t	fleet:gamma-third" "wait	$BR	3" "seen	33%" "wait	cur	4" \
  | python3 "$WORK/term.py" "$TMUX_BIN" "$SOCK")
C=$(printf '%s\n' "$OUT" | sed -n '3,5p')
check "C: a 1 s job — the stand-in still on the line" "$(ms_of "$C" "$BR")" 300
unseen "C: …nothing of the window just left" "$C" "33%"
CF=$(ms_of "$C" cur)
if [ -z "$MEASURE" ]; then
  if [ "$CF" -ge 900 ] && [ "$CF" -lt 99999 ]; then st_ok "C: …the full line only once the job ran (${CF}ms)"
  else fail "C: the full line came from the job" "${CF}ms"; fi
fi

# ---- D: the line yields only to its own window -----------------------------------------
if [ -z "$MEASURE" ]; then
  WB=$(T display-message -p -t fleet:beta-next '#{window_id}')
  L=$(python3 "$TB_BIN/fleet-topbar.py" render --node view=t1 s=fleet "reg=$WORK/reg" "g=$WORK/g" \
    "sock=$SOCK" cw=160 "w=$WB" pd=0)
  INB=$(T display-message -p -t fleet:beta-next "$L" | sed 's/#\[[^]]*\]//g')
  IND=$(T display-message -p -t fleet:delta-fourth "$L" | sed 's/#\[[^]]*\]//g')
  case "$INB" in *"›› Tokenman"*" 22"*"⌘P"*) st_ok "D: in its own window the full line" ;; *) fail "D: in its own window the full line" "$INB" ;; esac
  case "$IND" in *"›› Tokenman"*) st_ok "D: elsewhere the stand-in, the brand" ;; *) fail "D: elsewhere the stand-in" "$IND" ;; esac
  case "$IND" in *"22"*|*"⌘P"*) fail "D: …nothing of the window it was made for" "$IND" ;; *) st_ok "D: …nothing of the window it was made for" ;; esac
  # a line with the format's own characters survives the branch: , } # { (no stamp
  # reaches it free-form today — stamp_ctx keeps the model to a safe set — but a
  # word of the line may carry them)
  L=$(python3 - "$TB_BIN" "$WB" <<'TBPY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("tb", sys.argv[1] + "/fleet-topbar.py")
tb = importlib.util.module_from_spec(spec); spec.loader.exec_module(tb)
print(tb.own_window(sys.argv[2], "#[fg=#565f89]" + tb.tmux_text("a,b}c#d{e") + " ⌘P#[default]"))
TBPY
)
  INB=$(T display-message -p -t "$WB" "$L" | sed 's/#\[[^]]*\]//g')
  case "$INB" in *'a,b}c#d{e'*"⌘P"*) st_ok "D: a line with , } # { comes through whole" ;; *) fail "D: a line with , } # {" "$INB" ;; esac

  # ---- E: idle adds nothing ---------------------------------------------------------------
  if [ "$(T show-hooks -g 2>/dev/null)" = "$H0" ]; then st_ok "E: no hook added"; else fail "E: no hook added"; fi
  if [ "$(T show-options -qv -t fleet status-interval)" = 2 ]; then st_ok "E: the status-interval as dressed"; else fail "E: status-interval"; fi
fi

[ "$FAILS" -eq 0 ] && { echo "topbar-switch-selftest: PASS"; exit 0; }
echo "topbar-switch-selftest: $FAILS FAIL"; exit 1
