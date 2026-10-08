#!/bin/bash
# shell-unbreakable-selftest.sh — nothing a person presses in the client takes
# its own list or right pane away, and whatever ends either one is back within
# seconds (issue #1785, EPIC #1776 C9).
#
# Drives: conf/tmux-shell.conf, conf/tmux-shell-stage.conf, bin/fleet-shell.sh
# (the `home` window, its right pane = `viewer`), bin/fleet-sidebar.py (sync's
# heal_frame, the list's steady()), bin/fleet-remote-view.sh (the stage's
# reconnect wait).
#
#   A. lint — no bind in either conf (the client's, the stage's) kills a pane, a
#      window, a session or the server, or respawns one with -k; the rendered
#      servers list no prefix x / & / $ / < / > / w (prefix s is ⌘K's switcher,
#      #2266 — never choose-tree), and no right-click that
#      opens tmux's menus (Kill, Respawn, Rename)
#   B. the real client (bin/fleet, isolated sockets, an ssh shim), a python pty
#      as the person's terminal: prefix x + y, prefix & + y, a right-click + X on
#      the list, on the right pane and on the status line → the window, both
#      panes and the stage's window are all still there
#   C. ⌃c / ⌃\ / ⌃z with the keyboard on the list → the same list process, live
#   D. kill -9 the list → a new list within 5 s; kill -9 the right pane → it is
#      respawned within 5 s, the list beside it
#   E. the right pane's connection drops → 「回车立即重连」, and a ⌃c there
#      leaves the stage's window open
# Prints what the screen showed after prefix x (the issue's 上线证据).
# tmux / python3 absent → SKIP (exit 0). SUB_KEEP=1 keeps the work dir.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { printf 'shell-unbreakable selftest: tmux absent — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'shell-unbreakable selftest: python3 absent — SKIP\n'; exit 0; }

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
eq()   { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1" "$3 (want $2)"; }

# ================================================================================
# A. lint
# ================================================================================
for c in tmux-shell tmux-shell-stage; do
  f="$BIN/../conf/$c.conf"
  CHECKS=$((CHECKS + 1))
  bad=$(grep -nE '^[[:space:]]*bind' "$f" | grep -E 'kill-(pane|window|session|server)|respawn-(pane|window)[^;}]*-k|display-menu|choose-tree|rename-session')
  [ -z "$bad" ] || fail "A: $c.conf binds a key that deletes the client's own frame" "$bad"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sub-st.XXXXXX")" || exit 2
SESS="sub$$"
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

ts()  { "$REAL_TMUX" -L "$SESS" "$@"; }
tsg() { "$REAL_TMUX" -L "$SESS-stage" "$@"; }
cleanup() {
  "$REAL_TMUX" -L "$SESS" kill-server 2>/dev/null
  "$REAL_TMUX" -L "$SESS-stage" kill-server 2>/dev/null
  pkill -f "fleet-shell.sh keeper $SESS" 2>/dev/null
  pkill -f "sub-st.*sleep 600" 2>/dev/null
  [ -n "${SUB_KEEP:-}" ] && { printf "kept %s\n" "$WORK" >&2; return; }; rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# --- a bin/ of our own: every real script, a FAKE fleet-connect.py --------------
SB="$WORK/sbin"; mkdir -p "$SB" "$WORK/conf"
for f in "$BIN"/*; do [ -f "$f" ] && ln -s "$f" "$SB/${f##*/}"; done
for f in "$BIN"/../conf/*; do [ -f "$f" ] && ln -s "$f" "$WORK/conf/${f##*/}"; done
rm -f "$SB/fleet-connect.py"
cat > "$SB/fleet-connect.py" <<'EOF'
#!/usr/bin/env python3
import json, sys
if "--pick" in sys.argv:
    print(json.dumps({"machine": "m5", "hostname": "macmini", "reason": "last", "login": "verk",
                      "machines": [{"alias": "m5", "hostname": "macmini"}]}))
sys.exit(0)
EOF
chmod +x "$SB/fleet-connect.py"

# --- the ssh shim: an attach paints a line and holds; `drop` ends it (rc 255) ----
SHIM="$WORK/shim"; mkdir -p "$SHIM"
cat > "$SHIM/ssh" <<EOF
#!/bin/bash
op=''
while [ \$# -gt 0 ]; do
  case "\$1" in -O) op=\$2; shift 2 ;; -S|-o|-L) shift 2 ;; -*) shift ;; *) break ;; esac
done
[ -n "\$op" ] && exit 1
case "\$*" in
  *" attach "*)
    printf 'FAR-END-SESSION\n'
    echo \$\$ > "$WORK/attach.pid"
    sleep 600 & wait \$!
    exit 255 ;;
  *" watch "*|*" serve "*) sleep 600 ;;
esac
exit 0
EOF
chmod +x "$SHIM/ssh"
export FLEET_REMOTE_SSH_CMD="$SHIM/ssh"
printf '{"sessions": [], "nodes": [{"machine_name": "macmini", "availability": "online", "sessions": 0, "observed_at": "2026-10-06T10:00:00Z"}]}\n' > "$WORK/sessions.json"
export FLEET_HUB_SESSIONS_CMD="cat $WORK/sessions.json" FLEET_HUB_SESSIONS_USER=verk

out=$("$SB/fleet" 2>"$WORK/up.err"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$SESS" ] || { printf 'FAIL: the client did not start (rc %s): %s\n' "$rc" "$(cat "$WORK/up.err")" >&2; exit 1; }

# A, on the servers as rendered: the keys are gone, not just absent from the file
for k in x '&' '$' '<' '>' w; do
  CHECKS=$((CHECKS + 1))
  [ -z "$(ts list-keys -T prefix 2>/dev/null | awk -v k="$k" '$4 == k || $4 == "\\" k')" ] || fail "A: the client still binds prefix $k"
done
# prefix s is the switcher now (issue #2266, ⌘K's key elsewhere) — never choose-tree
CHECKS=$((CHECKS + 1))
ts list-keys -T prefix 2>/dev/null | awk '$4 == "s"' | grep -q 'fleet-quickopen.py --switch' \
  && ! ts list-keys -T prefix 2>/dev/null | awk '$4 == "s"' | grep -qE 'choose-tree|kill' \
  || fail "A: prefix s is not the switcher (or still choose-tree)"
for m in MouseDown3Pane M-MouseDown3Pane MouseDown3Status M-MouseDown3Status MouseDown3StatusLeft M-MouseDown3StatusLeft; do
  CHECKS=$((CHECKS + 1))
  ts list-keys -T root 2>/dev/null | awk -v k="$m" '$4 == k' | grep -qE 'display-menu|kill' && fail "A: the client's $m opens a menu"
  CHECKS=$((CHECKS + 1))
  tsg list-keys -T root 2>/dev/null | awk -v k="$m" '$4 == k' | grep -qE 'display-menu|kill' && fail "A: the stage's $m opens a menu"
done
eq 'A: the right pane is kept when it ends (remain-on-exit)' on \
  "$(ts show-options -pv -t "=$SESS:home.0" remain-on-exit 2>/dev/null)"

# ================================================================================
# B–E, through a terminal
# ================================================================================
python3 - "$REAL_TMUX" "$SESS" "$WORK" > "$WORK/result" 2>"$WORK/drive.err" <<'PY'
import fcntl, os, pty, select, signal, struct, subprocess, sys, termios, time
tmux, sess, work = sys.argv[1:4]
W, H = 200, 50

def t(*a, sock=sess):
    return subprocess.run([tmux, "-L", sock, *a], capture_output=True, text=True).stdout.strip()

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(TERM="xterm-256color", LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")
    os.environ.pop("TMUX", None)
    os.execvp(tmux, [tmux, "-L", sess, "attach-session", "-t", "=" + sess])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", H, W, 0, 0))

def pump(secs):
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                os.read(fd, 65536)
            except OSError:
                return

def key(data, wait=0.6):
    os.write(fd, data)
    pump(wait)

def until(secs, test):
    end = time.time() + secs
    while time.time() < end:
        if test():
            return True
        pump(0.1)
    return test()

def frame():
    """(list pane, its pid, right pane, its pid, its dead flag, pane count)"""
    rows = [l.split() for l in t("list-panes", "-t", "=" + sess + ":home", "-F",
            "#{pane_id} #{pane_pid} #{?@sidebar,1,0} #{pane_dead} #{pane_left}").splitlines()]
    lst = next((r for r in rows if r[2] == "1"), None)
    right = next((r for r in rows if r[2] != "1"), None)
    return (lst[0] if lst else "", lst[1] if lst else "", right[0] if right else "",
            right[1] if right else "", right[3] if right else "", len(rows))

def say(k, v):
    print("%s=%s" % (k, v)); sys.stdout.flush()

def kill_tree(p):
    subprocess.run(["pkill", "-9", "-P", p], capture_output=True)
    try:
        os.kill(int(p), signal.SIGKILL)
    except (OSError, ValueError):
        pass

def alive():
    f = frame()
    return f[0] != "" and f[2] != "" and f[4] == "0" and t("has-session", "-t", "=" + sess) == ""

def ok_frame(tag):
    say(tag + "_session", "1" if subprocess.run([tmux, "-L", sess, "has-session", "-t", "=" + sess],
                                                capture_output=True).returncode == 0 else "0")
    f = frame()
    say(tag + "_list", "1" if f[0] else "0")
    say(tag + "_right", "1" if f[2] and f[4] == "0" else "0")
    say(tag + "_stage", t("list-windows", "-t", "=" + sess + "-stage", "-F", "x", sock=sess + "-stage").count("x"))

try:
    say("up", "1" if until(15, lambda: frame()[0] != "") else "0")
    pump(1.0)
    stage0 = t("list-windows", "-t", "=" + sess + "-stage", "-F", "x", sock=sess + "-stage").count("x")
    say("stage0", stage0)
    # B. prefix x + y, prefix & + y
    key(b"\x02x"); key(b"y", 1.0)
    shot = t("capture-pane", "-p", "-t", "=" + sess + ":home.{right}")
    open(os.path.join(work, "after-x.txt"), "w").write(shot)
    say("x_prompt", "1" if "kill-pane" in shot else "0")
    ok_frame("x")
    key(b"\x02&"); key(b"y", 1.0)
    ok_frame("amp")
    # a right-click + X: on the list (col 5), on the right pane (col 120), on the
    # status line (the last row) — SGR mouse, button 2 = right
    for tag, col, row in (("rc_list", 5, 10), ("rc_right", 120, 10), ("rc_status", 3, H)):
        key(b"\x1b[<2;%d;%dM" % (col, row), 0.2)
        key(b"\x1b[<2;%d;%dm" % (col, row), 0.4)
        key(b"X", 1.0)
        key(b"\x1b", 0.3)
        ok_frame(tag)
    # C. ⌃c / ⌃\ / ⌃z reaching the list — no key does since
    # issue #1950 (it takes none), so the bytes go to its pane directly, as a
    # client a running server still holds in its old key table would send them
    pump(0.8)   # the right-clicks above settled (the old prefix E's pause)
    lst, lpid = frame()[:2]
    for b in ("C-c", "C-\\", "C-z"):
        t("send-keys", "-t", lst, b)
        time.sleep(0.8)
    pump(1.0)
    f = frame()
    say("cc_same", "1" if f[0] == lst and f[1] == lpid else "0")
    say("cc_why", "%s/%s -> %s/%s" % (lst, lpid, f[0], f[1]))
    say("cc_state", subprocess.run(["ps", "-o", "stat=", "-p", lpid], capture_output=True, text=True).stdout.strip())
    # D. kill -9 the list; kill -9 the right pane
    kill_tree(lpid)
    t0 = time.time()
    back = until(5, lambda: frame()[0] != "" and frame()[1] != lpid)
    say("list_back", "1" if back else "0"); say("list_secs", "%.1f" % (time.time() - t0))
    rpid = frame()[3]
    kill_tree(rpid)
    t0 = time.time()
    back = until(5, lambda: alive() and frame()[3] != rpid)
    say("right_back", "1" if back else "0"); say("right_secs", "%.1f" % (time.time() - t0))
    until(5, lambda: frame()[0] != "")
    ok_frame("killed")
    # E. the connection drops (the shim's attach ends 255): the reconnect wait
    try:
        apid = open(os.path.join(work, "attach.pid")).read().strip()
        subprocess.run(["pkill", "-9", "-P", apid], capture_output=True)
    except OSError:
        apid = ""
    seen = until(5, lambda: "回车立即重连" in t("capture-pane", "-p", "-t", "=" + sess + "-stage:", sock=sess + "-stage"))
    say("drop_note", "1" if seen else "0")
    tsw = t("list-panes", "-t", "=" + sess + "-stage:", "-F", "#{pane_id}", sock=sess + "-stage")
    t("send-keys", "-t", tsw, "C-c", sock=sess + "-stage")
    pump(1.0)
    say("drop_cc_stage", t("list-windows", "-t", "=" + sess + "-stage", "-F", "x", sock=sess + "-stage").count("x"))
finally:
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass
PY
r() { sed -n "s/^$1=//p" "$WORK/result" | tail -n 1; }
[ -s "$WORK/result" ] || { printf 'FAIL: the drive printed nothing: %s\n' "$(cat "$WORK/drive.err")" >&2; exit 1; }
eq 'B: the client drew its list' 1 "$(r up)"
s0=$(r stage0)
eq 'B: prefix x asks nothing' 0 "$(r x_prompt)"
for tag in x amp rc_list rc_right rc_status; do
  eq "B: $tag — the session lives" 1 "$(r ${tag}_session)"
  eq "B: $tag — the list is there" 1 "$(r ${tag}_list)"
  eq "B: $tag — the right pane is there" 1 "$(r ${tag}_right)"
  eq "B: $tag — the stage keeps its window" "$s0" "$(r ${tag}_stage)"
done
eq "C: ⌃c / ⌃\\ / ⌃z leave the same list process ($(r cc_why))" 1 "$(r cc_same)"
[ "$(r cc_same)" = 1 ] || find "$WORK" -name 'sidebar-*.log' -exec sh -c 'echo "--- $1"; tail -40 "$1"' _ {} \; >&2
CHECKS=$((CHECKS + 1)); case "$(r cc_state)" in T*) fail 'C: ⌃z stopped the list' "$(r cc_state)" ;; esac
eq 'D: kill -9 the list → a new one within 5 s' 1 "$(r list_back)"
eq 'D: kill -9 the right pane → respawned within 5 s' 1 "$(r right_back)"
eq 'D: … the session lives' 1 "$(r killed_session)"
eq 'D: … the list is beside it' 1 "$(r killed_list)"
eq 'E: a dropped line says 回车立即重连' 1 "$(r drop_note)"
eq 'E: ⌃c in the wait leaves the stage its window' "$s0" "$(r drop_cc_stage)"

printf '\n--- after prefix x + y (上线证据) ---\n'
cat "$WORK/after-x.txt" 2>/dev/null | sed -n '1,6p'
printf -- '--- list back in %ss · right pane back in %ss ---\n' "$(r list_secs)" "$(r right_secs)"
if [ "$FAIL" -gt 0 ]; then
  printf 'shell-unbreakable selftest: %d/%d FAILED\n' "$FAIL" "$CHECKS" >&2
  [ -s "$WORK/drive.err" ] && sed -n '1,20p' "$WORK/drive.err" >&2
  exit 1
fi
printf 'shell-unbreakable selftest: %d checks OK\n' "$CHECKS"
