#!/bin/bash
# shell-switch-repaint-selftest.sh — switching machines in the client repaints
# only the right pane (issue #1759).
#
# What the person's terminal receives is the measure: the real client
# (bin/fleet-shell.sh, started through bin/fleet like the selftest of the shell,
# fleet-shell-selftest.sh) on isolated tmux sockets, a python pty as the outer
# terminal, attached at 160×45. The list is a STAND-IN — a static pane carrying
# the list's own marks (@sidebar, @sidebar_version), so the real move / sync code
# treats it as the list while its content never changes: every byte that lands
# in its column is tmux repainting it, never the list redrawing a row. ssh is a
# shim: an `attach` paints a screen of `<machine>-content` into its pane and
# holds a control socket; a `select` (the same machine, another row) repaints
# that pane the way a far tmux client redraws after a switch.
#
# Steps, each measured until the terminal is quiet: idle (nothing done), SAME
# machine (an m5 row → another m5 row) and OTHER machine (m5 → m4, both
# connections already up) — every one through fleet-sidebar.py's own `jump`, what
# Enter on a row runs. A tiny VT parser maps every printed / erased cell onto the
# screen: the list's column, the status row, the borders, the right pane.
#   · no `\e[2J` in any step
#   · the list's column, the status row and the borders: 0 cells written in
#     either switch (the right pane only)
#   · the other-machine switch: ≤ 1.5 × the same-machine switch's bytes
#   · and it switched: the right pane shows m4-content afterwards
# Prints the two columns (same / other: bytes, list cells, status cells, border
# cells) — the issue's 上线证据. tmux / python3 absent → SKIP (exit 0).
# Debugging: FSR_SHOW=1 prints the right pane and the panes; FSR_KEEP=1 keeps the
# work dir.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { printf 'shell-switch-repaint selftest: tmux absent — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'shell-switch-repaint selftest: python3 absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fsr-st.XXXXXX")" || exit 2
SESS="fsr$$"
export HOME="$WORK/home"; mkdir -p "$HOME/.ssh" "$HOME/.config/claude-fleet"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
export FLEET_CONF_DIR="$HOME/.config/claude-fleet"
export FLEET_SHELL_SESSION="$SESS" FLEET_SHELL_CACHE="$WORK/cache"
export FLEET_REMOTE_BIN="$BIN" FLEET_REMOTE_VIA_HUB=0 FLEET_SHELL_NO_ATTACH=1
export FLEET_HUB_SESSIONS_LOOP_SECS=8 FLEET_HUB_SESSIONS_EVERY=1 FLEET_HUB_SESSIONS_WATCHED_EVERY=1
export FLEET_SHELL_WARM=0 FLEET_CLIENT_ACTIONS=0
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_SESSION FLEET_SHELL FLEET_HUB_SESSIONS_CLIENT FLEET_SIDEBAR_SOURCE
unset FLEET_HUB_URL CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_NODE_ALIASES FLEET_REMOTE_SSH_CMD FLEET_SHELL_STAGE
export FLEET_HUB_URL=https://hub.example

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
ts() { "$REAL_TMUX" -L "$SESS" "$@"; }
waitfor() {  # <secs> <cmd…>
  local n=$(( $1 * 10 )); shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
  return 1
}
cleanup() {
  "$REAL_TMUX" -L "$SESS" kill-server 2>/dev/null
  "$REAL_TMUX" -L "$SESS-stage" kill-server 2>/dev/null
  pkill -f "fleet-shell.sh keeper $SESS" 2>/dev/null
  pkill -f "fsr-st.*sleep 600" 2>/dev/null
  [ -n "${FSR_KEEP:-}" ] && { printf "kept %s\n" "$WORK" >&2; return; }; rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# --- a bin/ of our own: every real script, a FAKE fleet-connect.py --------------
SB="$WORK/sbin"; mkdir -p "$SB" "$WORK/conf"
for f in "$BIN"/*; do [ -f "$f" ] && ln -s "$f" "$SB/${f##*/}"; done
for f in "$BIN"/../conf/*; do [ -f "$f" ] && ln -s "$f" "$WORK/conf/${f##*/}"; done
rm -f "$SB/fleet-connect.py"
cat > "$SB/fleet-connect.py" <<EOF
#!/usr/bin/env python3
import json, sys
if "--pick" in sys.argv:
    print(json.dumps({"machine": "m5", "hostname": "macmini", "reason": "last", "login": "verk",
                      "machines": [{"alias": "m5", "hostname": "macmini"}, {"alias": "m4", "hostname": "mini2"}]}))
sys.exit(0)
EOF
chmod +x "$SB/fleet-connect.py"

# --- the ssh shim: an attach paints its machine's screen; a select repaints it ----
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
# a far tmux client's whole-screen redraw: cursor home, every row rewritten
paint() {  # <host> <tag>
  local r=1
  while [ "\$r" -le 40 ]; do
    printf '\033[%d;1H%s-content %s row %02d · lorem ipsum dolor sit amet\033[K' "\$r" "\$1" "\$2" "\$r"
    r=\$((r + 1))
  done
}
case "\$*" in
  *" attach "*)
    tty > "$WORK/tty.\$host"
    paint "\$host" attach
    python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); time.sleep(600)' "\$ctl" &
    wait ;;
  *" select "*)
    t=\$(cat "$WORK/tty.\$host" 2>/dev/null) && [ -w "\$t" ] && paint "\$host" "select \$RANDOM" > "\$t"
    exit 0 ;;
  *" watch "*|*" serve "*) sleep 600 ;;
esac
exit 0
EOF
chmod +x "$SHIM/ssh"
export FLEET_REMOTE_SSH_CMD="$SHIM/ssh"

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
   "worker": {"issue": 9, "repo": "acme/app", "state": "working", "agent": "claude", "name": "issue-9", "needs": ""}}
 ],
 "nodes": [
  {"machine_name": "macmini", "availability": "online", "sessions": 2, "observed_at": "2026-10-04T10:00:00Z"},
  {"machine_name": "mini2", "availability": "online", "sessions": 1, "observed_at": "2026-10-04T10:00:00Z"}
 ]}
EOF
export FLEET_HUB_SESSIONS_CMD="cat $WORK/sessions.json" FLEET_HUB_SESSIONS_USER=verk

# --- the client, up -------------------------------------------------------------
out=$("$SB/fleet" 2>"$WORK/up.err"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$SESS" ] || { printf 'FAIL: the client did not start (rc %s): %s\n' "$rc" "$(cat "$WORK/up.err")" >&2; exit 1; }
G="$WORK/cache/tmp/.claude-dash/global"
waitfor 15 test -s "$G/remote_$SESS" || { printf 'FAIL: no row cache\n' >&2; exit 1; }
SOCK=$(ts display-message -p '#{socket_path}')
w=$(ts display-message -p -t "=$SESS:" '#{window_id}')
right=$(ts list-panes -t "$w" -F '#{pane_id}' | head -1)
VER=$(sed -n 's/^VIEW_VERSION = "\([^"]*\)".*/\1/p' "$BIN/fleet-sidebar.py")
# The stand-in list, where sync would draw the real one, with the real one's marks.
ts resize-window -t "$w" -x 160 -y 44 2>/dev/null
standin=$(ts split-window -d -h -b -f -l 30 -t "$right" -P -F '#{pane_id}' \
  "sh -c 'i=1; while [ \$i -le 50 ]; do printf \"LISTROW %02d\\n\" \$i; i=\$((i+1)); done; exec sleep 600'")
ts set-option -p -t "$standin" @sidebar 1 \; set-option -p -t "$standin" @sidebar_version "$VER" \; \
   set-option -w -t "$w" @sidebar_worker "$right" \; set-option -p -t "$standin" remain-on-exit off

cat > "$WORK/jump.sh" <<EOF
#!/bin/bash
# what Enter on a row runs: fleet-sidebar.py jump, in the client's environment
cd "$WORK/cache/bin" && env TMUX="$SOCK,0,0" TMUX_PANE="$standin" FLEET_SHELL=1 FLEET_SESSION="$SESS" CCQUOTA_FLEET=1 \\
  FLEET_SIDEBAR_SOURCE=hub TMPDIR="$WORK/cache/tmp" FLEET_HUB_SESSIONS_CLIENT="$SESS" \\
  \$(tmux -L "$SESS" show-environment -g FLEET_SHELL_STAGE 2>/dev/null | grep -v "^-") \\
  python3 - "$SESS" "\$1" "$standin" "$WORK/cache/lock" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sb", "fleet-sidebar.py"); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.jump(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
PY
EOF
chmod +x "$WORK/jump.sh"

M5A='wid:11111111-1111-4111-8111-111111111111/issue-7'
M5B='wid:11111111-1111-4111-8111-111111111111/scratch-3'
M4='wid:22222222-2222-4222-8222-222222222222/issue-9'

python3 - "$REAL_TMUX" "$SESS" "$standin" "$WORK" "$M5A" "$M5B" "$M4" > "$WORK/result" 2>"$WORK/measure.err" <<'PY'
import fcntl, os, pty, select, struct, subprocess, sys, termios, time, unicodedata
tmux, sess, standin, work, m5a, m5b, m4 = sys.argv[1:8]
W, H = 160, 45

def t(*a):
    return subprocess.run([tmux, "-L", sess, *a], capture_output=True, text=True).stdout.strip()

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(TERM="xterm-256color", LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")
    os.environ.pop("TMUX", None)
    os.execvp(tmux, [tmux, "-L", sess, "attach-session", "-t", "=" + sess])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", H, W, 0, 0))

def drain(quiet=0.6, most=6.0):
    """Every byte until the terminal has been quiet for `quiet` seconds."""
    buf, end, last = b"", time.time() + most, time.time()
    while time.time() < end and time.time() - last < quiet:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            buf, last = buf + chunk, time.time()
    return buf

def jump(wid):
    subprocess.run(["bash", os.path.join(work, "jump.sh"), wid], capture_output=True)

def cells(data):
    """The set of (row, col) the stream prints or erases, and its 2J count."""
    hit, row, col, top, bot, i, n = set(), 0, 0, 0, H - 1, 0, len(data)
    clears = 0
    text = data.decode("utf-8", "replace")
    n = len(text)
    def mark(r, c0, c1):
        for c in range(max(c0, 0), min(c1, W)):
            hit.add((r, c))
    saved = (0, 0)
    while i < n:
        ch = text[i]
        if ch == "\x1b":
            if i + 1 >= n:
                break
            nx = text[i + 1]
            if nx == "[":
                j = i + 2
                while j < n and not ("\x40" <= text[j] <= "\x7e"):
                    j += 1
                if j >= n:
                    break
                raw, final = text[i + 2:j], text[j]
                i = j + 1
                if raw.startswith("?") or raw.startswith(">") or raw.startswith("="):
                    continue
                ps = [int(p) if p.isdigit() else 0 for p in raw.split(";")] if raw else []
                p1 = ps[0] if ps else 0
                if final in "Hf":
                    row = (ps[0] if ps and ps[0] else 1) - 1
                    col = (ps[1] if len(ps) > 1 and ps[1] else 1) - 1
                elif final == "A": row = max(0, row - (p1 or 1))
                elif final == "B": row = min(H - 1, row + (p1 or 1))
                elif final == "C": col = min(W - 1, col + (p1 or 1))
                elif final == "D": col = max(0, col - (p1 or 1))
                elif final == "G": col = (p1 or 1) - 1
                elif final == "d": row = (p1 or 1) - 1
                elif final == "K":
                    if p1 == 0: mark(row, col, W)
                    elif p1 == 1: mark(row, 0, col + 1)
                    else: mark(row, 0, W)
                elif final == "X": mark(row, col, col + (p1 or 1))
                elif final in "@P": mark(row, col, W)
                elif final in "LM":
                    for r in range(row, bot + 1): mark(r, 0, W)
                elif final in "ST":
                    for r in range(top, bot + 1): mark(r, 0, W)
                elif final == "J":
                    if p1 == 2 or p1 == 3:
                        clears += 1
                        for r in range(H): mark(r, 0, W)
                    elif p1 == 0:
                        mark(row, col, W)
                        for r in range(row + 1, H): mark(r, 0, W)
                    else:
                        for r in range(row): mark(r, 0, W)
                        mark(row, 0, col + 1)
                elif final == "r":
                    top = (ps[0] if ps and ps[0] else 1) - 1
                    bot = (ps[1] if len(ps) > 1 and ps[1] else H) - 1
                    row, col = 0, 0
                continue
            if nx in "]P_^":   # OSC / DCS / APC / PM: to BEL or ST
                j = i + 2
                while j < n and text[j] != "\x07" and text[j:j + 2] != "\x1b\\":
                    j += 1
                i = j + (1 if j < n and text[j] == "\x07" else 2)
                continue
            if nx in "()*+":
                i += 3
                continue
            if nx == "7": saved = (row, col)
            elif nx == "8": row, col = saved
            elif nx == "M": row = max(0, row - 1)
            elif nx == "D" or nx == "E": row = min(H - 1, row + 1)
            i += 2
            continue
        i += 1
        if ch == "\r": col = 0
        elif ch == "\n": row = min(H - 1, row + 1)
        elif ch == "\b": col = max(0, col - 1)
        elif ch == "\t": col = min(W - 1, (col // 8 + 1) * 8)
        elif ch < " " or ch == "\x7f": pass
        else:
            wide = 2 if unicodedata.east_asian_width(ch) in "WF" else (0 if unicodedata.combining(ch) else 1)
            mark(row, col, col + max(wide, 1))
            col = min(W - 1, col + wide) if col + wide >= W else col + wide
    return hit, clears

def regions():
    """The list's column, the right pane's rectangle — read after the step."""
    win = t("display-message", "-p", "-t", "=" + sess + ":", "#{window_id}")
    out = {}
    for line in t("list-panes", "-t", win, "-F", "#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height}").splitlines():
        p, l, tp, w, h = line.split()
        out["list" if p == standin else "right"] = (int(l), int(tp), int(w), int(h))
    return out

def classify(hit, reg):
    lst, right = reg.get("list"), reg.get("right")
    n = {"list": 0, "status": 0, "border": 0, "right": 0}
    for r, c in hit:
        if r == H - 1:
            n["status"] += 1
        elif lst and lst[0] <= c < lst[0] + lst[2] and lst[1] <= r < lst[1] + lst[3]:
            n["list"] += 1
        elif right and right[0] <= c < right[0] + right[2] and right[1] <= r < right[1] + right[3]:
            n["right"] += 1
        else:
            n["border"] += 1
    return n

drain(1.5, 8)
time.sleep(0.5)
# both connections up, settled: m4 opened once, then back on m5
jump(m4); drain(1.0, 8)
jump(m5a); drain(1.0, 8)
time.sleep(1.0); drain(0.5, 3)
rows = {}
for name, act in (("idle", None), ("same", m5b), ("other", m4)):
    drain(0.5, 3)
    if act:
        jump(act)
    data = drain(0.8, 6)
    hit, clears = cells(data)
    n = classify(hit, regions())
    rows[name] = (len(data), n, clears)
right = regions().get("right")
shown = ""
if right:
    win = t("display-message", "-p", "-t", "=" + sess + ":", "#{window_id}")
    for line in t("list-panes", "-t", win, "-F", "#{pane_id} #{pane_left}").splitlines():
        p, l = line.split()
        if p != standin:
            shown = t("capture-pane", "-p", "-t", p)
for name in ("idle", "same", "other"):
    b, n, c = rows[name]
    print("%s %d %d %d %d %d %d" % (name, b, n["list"], n["status"], n["border"], n["right"], c))
print("shows_m4 %d" % (1 if "m4-content" in shown else 0))
os.kill(pid, 9)
PY
[ -s "$WORK/result" ] || { printf 'FAIL: the measurement did not run: %s\n' "$(tail -5 "$WORK/measure.err")" >&2; exit 1; }

[ -n "${FSR_SHOW:-}" ] && { ts capture-pane -p -e -t "$right" | head -4; ts list-panes -a -F '#{window_name} #{pane_id} #{pane_width}x#{pane_height} @sidebar=#{@sidebar}'; } >&2
val() { awk -v k="$1" -v f="$2" '$1 == k { print $f; exit }' "$WORK/result"; }
printf '%-22s %10s %10s\n' '' '同机器' '跨机器'
printf '%-22s %10s %10s\n' 'bytes 总字节数' "$(val same 2)" "$(val other 2)"
printf '%-22s %10s %10s\n' 'list cells 侧栏区写入' "$(val same 3)" "$(val other 3)"
printf '%-22s %10s %10s\n' 'status cells 状态栏写入' "$(val same 4)" "$(val other 4)"
printf '%-22s %10s %10s\n' 'border cells 边框写入' "$(val same 5)" "$(val other 5)"
printf '%-22s %10s %10s\n' 'right cells 右侧写入' "$(val same 6)" "$(val other 6)"
printf '%-22s %10s %10s\n' '\e[2J' "$(val same 7)" "$(val other 7)"
printf 'idle: %s bytes, list %s, status %s, border %s\n' "$(val idle 2)" "$(val idle 3)" "$(val idle 4)" "$(val idle 5)"

for k in same other; do
  for f in 3:list 4:status 5:border 7:2J; do
    CHECKS=$((CHECKS + 1))
    [ "$(val "$k" "${f%%:*}")" = 0 ] || fail "$k-machine switch wrote ${f#*:} (want 0)" "$(val "$k" "${f%%:*}")"
  done
done
CHECKS=$((CHECKS + 1))
s=$(val same 2); o=$(val other 2)
[ -n "$s" ] && [ -n "$o" ] && [ $(( o * 2 )) -le $(( s * 3 )) ] || fail 'the other-machine switch costs ≤ 1.5× the same-machine one' "other $o vs same $s bytes"
CHECKS=$((CHECKS + 1)); [ "$(val shows_m4 2)" = 1 ] || fail 'after the other-machine switch the right pane shows m4'

if [ "$FAIL" -gt 0 ]; then
  printf 'shell-switch-repaint selftest: %d/%d checks FAILED\n' "$FAIL" "$CHECKS" >&2
  exit 1
fi
printf 'shell-switch-repaint selftest: %d checks passed\n' "$CHECKS"
exit 0
