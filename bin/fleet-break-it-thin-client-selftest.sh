#!/bin/bash
# fleet-break-it-thin-client-selftest.sh — docs/BREAK-IT.md rows thin-* on the
# CLIENT side (issue #3007, EPIC #2999 C10): the thin loop on the person's own
# computer (bin/fleet-thin.py) against the three kinds of "connection state gone
# bad" (#2987) and the two ways its one line goes away. Its own file, on the cred
# runner (BREAK_CRED_LIB=1); bin/fleet-break-it-selftest.sh's lockstep lint reads
# the drill_* names here too.
#
#   thin-control-socket     a `ControlMaster auto` in the person's ssh config:
#                           every ssh the loop runs still resolves to no master
#                           and no control path (real `ssh -G`), no socket file
#                           anywhere after a session with an upload
#   thin-loop-orphan        the terminal SIGKILLed, then the loop itself
#                           SIGKILLed: nothing of ours left
#   thin-goto-spoof         a program inside a session prints OSC 7502 (bare and
#                           through tmux passthrough, a real isolated tmux with
#                           allow-passthrough on): no quit, the upload still goes
#                           where the home said
#   thin-view-lost-on-drop  the person's own network down long enough for three
#                           failed connections: back on the SAME home, the same
#                           view, the same session — never 换家 to a fresh view
#   thin-home-down          the home machine down, the hub reachable: 换家 to
#                           another machine after three failures
#
# The loop runs for real under a python pty (the terminal), with the real
# bin/fleet-connect.py --argv (a sandbox HOME, its own fleet-ssh-config + routes,
# no hub) and a stand-in `ssh` first on PATH: it logs its argv as JSON and runs
# the remote command in the machine's sandbox HOME (127.0.0.1 = m1, 127.0.0.2 =
# m2). The hub probe is the seam FLEET_THIN_HUB_PROBE_CMD (reachable unless the
# drill took the network down). tmux absent → SKIP (thin-goto-spoof needs one).
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
RT=$(PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v tmux-shim | paste -sd: -) command -v tmux) \
  || { printf 'fleet-break-it-thin-client: tmux absent — SKIP\n'; exit 0; }
SSH_REAL=$(command -v ssh) || { printf 'fleet-break-it-thin-client: ssh absent — SKIP\n'; exit 0; }
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"
unset TMUX TMUX_PANE
ME=$(python3 -c 'import platform; print(platform.node().split(".", 1)[0])')

# tc_rig — a fresh client computer + two home machines under $R
tc_rig() {
  R=$(mktemp -d /tmp/tcr.XXXXXX); R=$(cd "$R" && pwd -P); printf '%s\n' "$R" >> "$WORK/tc-rigs"
  mkdir -p "$R/client/.ssh" "$R/client/.config/claude-fleet" "$R/client/tmp" "$R/bin" "$R/iterm" "$R/s"
  cat > "$R/client/.ssh/fleet-ssh-config" <<'EOF'
Host m1 fleet-m1 fleet-m1-lan
  HostName 127.0.0.1
  User u1
Host m2 fleet-m2 fleet-m2-lan
  HostName 127.0.0.2
  User u2
EOF
  printf 'm1 lan\nm2 lan\n' > "$R/client/.config/claude-fleet/routes"
  echo '{}' > "$R/iterm/fleet.json"
  # the person's own ~/.ssh/config, as #2987 found it: a master for every host
  printf 'Host *\n  ControlMaster auto\n  ControlPath %s/cm-%%C\n  ControlPersist 10m\n' "$R/client/.ssh" > "$R/client/.ssh/config"
  cat > "$R/bin/ssh" <<EOF
#!/bin/sh
python3 -c 'import json, sys; print(json.dumps(sys.argv[1:]))' "\$@" >> "$R/ssh.ndjson"
for a; do prev=\$last; last=\$a; done
case \$prev in 127.0.0.1) host=m1 ;; 127.0.0.2) host=m2 ;; *) host=\$prev ;; esac
[ -e "$R/net.down" ] && { sleep 0.1; echo "ssh: connect to host \$prev: Network is unreachable" >&2; exit 255; }
[ -e "$R/down.\$host" ] && { echo "ssh: connect to host \$prev: Connection refused" >&2; exit 255; }
mkdir -p "$R/home/\$host"
cd "$R/home/\$host" && HOME="$R/home/\$host" HOST_NAME=\$host exec sh -c "\$last"
EOF
  local m
  for m in m1 m2; do
    mkdir -p "$R/home/$m/.claude/fleet/bin"
    ln -s "$BIN/fleet-client-upload.py" "$R/home/$m/.claude/fleet/bin/fleet-client-upload.py"
    cat > "$R/home/$m/.claude/fleet/bin/fleet-remote-view.sh" <<EOF
#!/bin/bash
echo "\$HOST_NAME \$*" >> "$R/rv.log"; echo \$\$ > "$R/rv.pid"
view= want= resume= token=
while [ \$# -gt 0 ]; do
  case \$1 in
    --view) view=\$2; shift ;; --want) want=\$2; shift ;; --resume) resume=1 ;;
    --token) token=\$2; shift ;; --device|--route) shift ;;
  esac; shift
done
mkdir -p "$R/views"; st="$R/views/\$HOST_NAME.\$view"
if [ -n "\$want" ]; then w=\$want; elif [ -n "\$resume" ] && [ -f "\$st" ]; then w=\$(cat "\$st"); else w=orch; fi
echo "\$w" > "\$st"
printf '\033]7502;cur;token=%s;m=%s;l=%s;w=u/%s\007' "\$token" "$ME" "\$(id -un)" "\$w"
if [ -e "$R/tmux.attach" ]; then
  # a real session behind it: the home's tmux, allow-passthrough on (as a node)
  exec "$RT" -S "$R/s/home" attach -t w
fi
stty -echo lnext undef 2>/dev/null
printf 'VIEW %s ON %s\r\n' "\$w" "\$HOST_NAME"
while IFS= read -r line; do
  case \$line in
    quit) printf '\033]7502;quit;token=%s\007' "\$token"; exit 0 ;;
    drop) exit 255 ;;
    *)    printf 'GOT[%s]\r\n' "\$(printf '%s' "\$line" | cat -v)" ;;
  esac
done
EOF
    chmod +x "$R/home/$m/.claude/fleet/bin/fleet-remote-view.sh"
  done
  chmod +x "$R/bin/ssh"
  printf 'dropped' > "$R/drop me.txt"
  : > "$R/rv.log"; : > "$R/ssh.ndjson"
  # the terminal: fleet-thin.py under a pty; a script of steps; its pid in drive.pid
  cat > "$R/drive.py" <<'EOF'
import json, os, pty, re, select, signal, sys, time
R, BIN, script = sys.argv[1], sys.argv[2], sys.argv[3]
open(R + "/drive.pid", "w").write(str(os.getpid()))
env = dict(os.environ, HOME=R + "/client", XDG_CACHE_HOME=R + "/client/.cache",
           XDG_CONFIG_HOME=R + "/client/.config", FLEET_CONF_DIR=R + "/client/.config/claude-fleet",
           TMPDIR=R + "/client/tmp", PATH=R + "/bin:" + os.environ["PATH"], FLEET_THIN_LOG=R + "/thin.log",
           FLEET_THIN_BACKOFF="0.3,0.6,1", FLEET_THIN_UP_SECS="1.5", FLEET_THIN_UPDATE_CMD="true",
           FLEET_THIN_HUB_PROBE_CMD="sh -c '[ ! -e %s/net.down ]'" % R, FLEET_CLIENT_LOG="0",
           FLEET_CLIENT_XTVERSION="0", FLEET_UI_LANG="zh", FLEET_CLIENT_CLIP_CMD="false",
           ITERM_PROFILE="Default", TERM_PROGRAM="iTerm.app", FLEET_ITERM_DIR=R + "/iterm", TERM="xterm-256color")
for k in ("TMUX", "TMUX_PANE", "FLEET_CLIENT_UPDATED", "LC_TERMINAL", "FLEET_HUB_URL", "FLEET_HUB_TOKEN", "SSH_CONNECTION"):
    env.pop(k, None)
pid, fd = pty.fork()
if pid == 0:
    os.execvpe(sys.executable, [sys.executable, BIN + "/fleet-thin.py"] + json.loads(os.environ.get("THIN_ARGS", "[]")), env)
open(R + "/thin.pid", "w").write(str(pid))
buf = b""
def pump(tmo):
    global buf
    r, _, _ = select.select([fd], [], [], tmo)
    if r:
        try:
            d = os.read(fd, 65536)
        except OSError:
            return False
        if not d:
            return False
        buf += d
        open(R + "/term.out", "wb").write(buf)
    return True
def until(pat, tmo):
    end = time.time() + tmo
    while time.time() < end:
        if re.search(pat.encode(), buf):
            return True
        if not pump(0.05):
            time.sleep(0.05)
    return bool(re.search(pat.encode(), buf))
for step in json.load(open(script)):
    kind, arg = step[0], step[1]
    if kind == "send":
        os.write(fd, arg.encode("latin-1"))
    elif kind == "expect":
        print("SAW %r %s" % (arg, until(arg, step[2] if len(step) > 2 else 10)), flush=True)
    elif kind == "await":
        end = time.time() + step[2]
        while time.time() < end and not os.path.exists(arg):
            pump(0.05)
        print("AWAITED %s %s" % (arg, os.path.exists(arg)), flush=True)
    elif kind == "linger":
        end = time.time() + arg
        while time.time() < end:
            pump(0.05)
    elif kind == "wait":
        end, rc = time.time() + arg, None
        while time.time() < end:
            pump(0.05)
            done, st = os.waitpid(pid, os.WNOHANG)
            if done == pid:
                rc = os.WEXITSTATUS(st) if os.WIFEXITED(st) else 128 + os.WTERMSIG(st)
                break
        print("RC %s" % rc, flush=True)
EOF
}
tc_drive() {   # tc_drive <name> <json steps> — foreground; notes in $R/res.<name>
  printf '%s' "$2" > "$R/$1.json"
  python3 "$R/drive.py" "$R" "$BIN" "$R/$1.json" > "$R/res.$1" 2>&1
}
tc_left() {    # what of ours still runs: the loop, its ssh stand-in, the view stand-in
  { tc_alive "$(cat "$R/thin.pid" 2>/dev/null)" && echo loop
    tc_alive "$(cat "$R/rv.pid" 2>/dev/null)" && echo view
    pgrep -f "$R/" 2>/dev/null | while read -r p; do ps -o command= -p "$p" 2>/dev/null; done | grep -v 'drive.py'; } | grep -c .
}
tc_alive() { case $(ps -o stat= -p "${1:-0}" 2>/dev/null) in ""|Z*) return 1 ;; esac; }   # a zombie is gone
tc_none() { [ "$(tc_left)" = 0 ]; }
tc_drop_view() { kill "$(cat "$R/rv.pid")" 2>/dev/null; }   # the line under the view goes
tc_done() {
  pkill -9 -f "$R/" 2>/dev/null
  "$RT" -S "$R/s/home" kill-server 2>/dev/null
  return 0
}

drill_thin_control_socket() {
  CAP=8   # one session + an upload + ⌘Q, every ssh resolved by the real ssh -G
  local t0 bad n
  tc_rig; t0=$(now)
  # a static net first: the thin road never asks ssh for a master or a persisting one
  bad=$(grep -nE 'ControlMaster=(yes|auto|autoask|ask)|ControlPersist=' "$BIN/fleet-thin.py" "$BIN/fleet-thin-upload.py" 2>/dev/null)
  [ -z "$bad" ] || { WHY="the thin road asks for a master: $bad"; tc_done; return 1; }
  THIN_ARGS='["--home", "m1", "s1"]' tc_drive cs '[
   ["expect", "VIEW s1 ON m1"],
   ["send", "\u001b[200~'"$R"'/drop\\ me.txt\u001b[201~\n"],
   ["expect", "GOT\\[.*inbox"],
   ["send", "quit\n"],
   ["wait", 10]
  ]'
  grep -q 'RC 0' "$R/res.cs" || { WHY="the session did not run to ⌘Q: $(cat "$R/res.cs")"; tc_done; return 1; }
  n=$(grep -c . "$R/ssh.ndjson")
  [ "$n" -ge 2 ] || { WHY="expected the view's ssh and the upload's, saw $n"; tc_done; return 1; }
  # every ssh the loop ran, resolved by the real ssh against the person's config
  bad=$(python3 - "$R" "$SSH_REAL" <<'PY'
import json, subprocess, sys
R, ssh = sys.argv[1], sys.argv[2]
for line in open(R + "/ssh.ndjson"):
    a = json.loads(line)[:-1]            # the remote command off; the host is last now
    a = [x for x in a if x not in ("-tt", "-T", "-t")]
    out = subprocess.run([ssh, "-G", "-F", R + "/client/.ssh/config"] + a,
                         capture_output=True, text=True).stdout.lower().splitlines()
    kv = dict(l.split(" ", 1) for l in out if " " in l)
    if kv.get("controlmaster") != "false" or kv.get("controlpath", "none") != "none":
        print("%s → controlmaster=%s controlpath=%s" % (" ".join(a[-4:]), kv.get("controlmaster"), kv.get("controlpath")))
PY
)
  [ -z "$bad" ] || { WHY="an ssh would open a master under the person's config: $bad"; tc_done; return 1; }
  n=$(find "$R/client" -type s 2>/dev/null | grep -c .)
  [ "$n" = 0 ] || { WHY="$n socket file(s) left under the client's HOME / TMPDIR: $(find "$R/client" -type s)"; tc_done; return 1; }
  SECS=$(since "$t0")
  tc_done
  WHAT="个人配置 ControlMaster auto 下，看台连接和上传的 $(grep -c . "$R/ssh.ndjson") 条 ssh 经真 ssh -G 都是 controlmaster false / controlpath none；结束后客户端 HOME 和 TMPDIR 里没有控制文件"
}

drill_thin_loop_orphan() {
  CAP=3   # the terminal or the loop SIGKILLed → nothing of ours within this
  local t0 a b
  tc_rig
  # 1 — the terminal SIGKILLed (iTerm2's window closed hard): the loop gets its hangup
  ( THIN_ARGS='["--home", "m1", "s1"]' tc_drive t1 '[["expect", "VIEW s1 ON m1"], ["linger", 30]]' & ) 2>/dev/null
  until_ok 10 grep -q 'True' "$R/res.t1" || { WHY="the view never came up: $(cat "$R/res.t1")"; tc_done; return 1; }
  [ "$(tc_left)" -ge 2 ] || { WHY="the loop + its ssh are not both running: $(tc_left)"; tc_done; return 1; }
  t0=$(now); kill -9 "$(cat "$R/drive.pid")"
  until_ok "$CAP" tc_none \
    || { WHY="the terminal SIGKILLed, still running: $(tc_left) — $(pgrep -fl "$R/")"; tc_done; return 1; }
  a=$(since "$t0"); wait 2>/dev/null
  # 2 — the loop itself SIGKILLed (no handler runs): its ssh holds a pty whose master died with it
  ( THIN_ARGS='["--home", "m1", "s1"]' tc_drive t2 '[["expect", "VIEW s1 ON m1"], ["linger", 30]]' & ) 2>/dev/null
  until_ok 10 grep -q 'True' "$R/res.t2" || { WHY="the view never came up (2): $(cat "$R/res.t2")"; tc_done; return 1; }
  t0=$(now); kill -9 "$(cat "$R/thin.pid")"
  until_ok "$CAP" tc_none \
    || { WHY="the loop SIGKILLed, still running: $(tc_left) — $(pgrep -fl "$R/" | grep -v drive.py)"; tc_done; return 1; }
  b=$(since "$t0"); kill -9 "$(cat "$R/drive.pid")" 2>/dev/null; wait 2>/dev/null
  SECS=$(python3 -c 'import sys; print(max(float(sys.argv[1]), float(sys.argv[2])))' "$a" "$b")
  tc_done
  WHAT="终端被 SIGKILL：${a}s 内循环和 ssh 都没了；循环自己被 SIGKILL：${b}s 内它的 ssh 随 pty 收掉；什么都不剩"
}

drill_thin_goto_spoof() {
  CAP=4   # the forged escapes printed → the loop still up and an upload landed by the home's cur
  local t0 up
  tc_rig
  cat > "$R/spoof.sh" <<EOF
#!/bin/sh
# a program inside a session: OSC 7502 bare, and wrapped in tmux passthrough
while :; do
  if [ -e "$R/spoof.go" ]; then
    rm -f "$R/spoof.go"
    printf '\033Ptmux;\033\033]7502;quit;token=bad\007\033\\'
    printf '\033]7502;quit;token=bad\007'
    printf '\033Ptmux;\033\033]7502;cur;token=bad;m=evil;l=evil;w=evil\007\033\\'
    printf '\033]7502;cur;m=evil;l=evil;w=evil\007'
    echo SPOOFED; touch "$R/spoofed"
  fi
  sleep 0.1
done
EOF
  chmod +x "$R/spoof.sh"
  "$RT" -S "$R/s/home" -f /dev/null new-session -d -s w -x 100 -y 30 "$R/spoof.sh"
  "$RT" -S "$R/s/home" set -g allow-passthrough on
  "$RT" -S "$R/s/home" set -g status off
  touch "$R/tmux.attach"
  ( THIN_ARGS='["--home", "m1", "s1"]' tc_drive sp '[
   ["await", "'"$R"'/attached", 15],
   ["await", "'"$R"'/spoofed", 10],
   ["linger", 1],
   ["send", "\u001b[200~'"$R"'/drop\\ me.txt\u001b[201~"],
   ["linger", 20]
  ]' & ) 2>/dev/null
  until_ok 10 sh -c '[ "$("$1" -S "$2" list-clients | grep -c .)" -ge 1 ]' _ "$RT" "$R/s/home" \
    || { WHY="the view never attached to the home's session"; tc_done; return 1; }
  sleep 0.5; touch "$R/attached"; t0=$(now); touch "$R/spoof.go"
  until_ok 3 test -e "$R/spoofed" || { WHY="the spoofing program never ran"; tc_done; return 1; }
  until_ok 6 grep -qs '	upload	' "$R/thin.log" || { WHY="no upload after the spoof (the loop gone? $(tail -n 2 "$R/thin.log" | tr '\t' ' '))"; tc_done; return 1; }
  SECS=$(since "$t0")
  kill -0 "$(cat "$R/thin.pid")" 2>/dev/null || { WHY="a forged quit ended the loop: $(tail -n 3 "$R/thin.log" | tr '\t' ' ')"; tc_done; return 1; }
  grep -aq SPOOFED "$R/term.out" || { WHY="the session's output never reached the person's terminal"; tc_done; return 1; }
  grep -aq ']7502' "$R/term.out" && { WHY="an OSC 7502 reached the person's terminal"; tc_done; return 1; }
  up=$(grep '	upload	' "$R/thin.log" | tail -n 1)
  case $up in *"	0	drop_me.txt → "*/inbox/*) ;;
    *) WHY="the upload did not go by the home's cur: $(printf '%s' "$up" | tr '\t' ' ')"; tc_done; return 1 ;; esac
  tc_done; wait 2>/dev/null
  WHAT="会话里的程序（真 tmux，allow-passthrough on）印出伪造的 OSC 7502 quit / cur（直出与 passthrough）：循环照常，终端见不到 7502，随后的拖放仍按家机器的 cur 落到收件箱"
}

drill_thin_view_lost_on_drop() {
  CAP=4   # the network back → the same session, on the same home, the same view
  local t0 v n
  tc_rig
  # one terminal kept open across the drop: drive in the background, lingering
  ( THIN_ARGS='["--home", "m1", "s1"]' tc_drive dr2 '[["expect", "VIEW s1 ON m1"], ["await", "'"$R"'/net.down", 15],
    ["linger", 1.5], ["send", "\u001b[<35;10;5MJUNKTYPED\n"], ["linger", 40]]' & ) 2>/dev/null
  until_ok 10 grep -q 'True' "$R/res.dr2" || { WHY="the view never came up: $(cat "$R/res.dr2")"; tc_done; return 1; }
  v=$(sed -n '1s/.*--view \([^ ]*\).*/\1/p' "$R/rv.log")
  # the lid closed / the Wi-Fi gone: every ssh fails, the hub does not answer either
  touch "$R/net.down"; tc_drop_view
  until_ok 15 sh -c '[ "$(grep -c "	connect	" "$1/thin.log")" -ge 5 ]' _ "$R" \
    || { WHY="the loop did not keep trying while the network was down: $(cat "$R/thin.log")"; tc_done; return 1; }
  rm -f "$R/net.down"; t0=$(now)
  until_ok "$CAP" sh -c 'tail -n 1 "$1/rv.log" | grep -q "^m[12] "' _ "$R" \
    || { WHY="nothing reconnected after the network came back"; tc_done; return 1; }
  until_ok "$CAP" sh -c '[ "$(grep -ac "VIEW s1 ON m1" "$1/term.out")" -ge 2 ]' _ "$R"
  SECS=$(since "$t0")
  n=$(tail -n 1 "$R/rv.log")
  case $n in "m1 attach --thin --view $v --resume "*) ;;
    *) WHY="after the drop the loop went to a fresh view: '$n' (was m1 --view $v); thin.log: $(grep -a rehome "$R/thin.log" | tail -n 2 | tr '\t' ' ')"; tc_done; return 1 ;; esac
  grep -aq 'VIEW orch ON m2\|VIEW s1 ON m2' "$R/term.out" && { WHY="it went to m2 on the way"; tc_done; return 1; }
  # the mouse moved / a key typed while the line was down: no echo, and never sent to the session (#3007)
  grep -aq '35;10;5M\|JUNKTYPED' "$R/term.out" && { WHY="input during the drop reached the screen or the session: $(grep -ao '.\{0,20\}JUNKTYPED.\{0,10\}\|.\{0,10\}35;10;5M' "$R/term.out" | head -2 | cat -v)"; tc_done; return 1; }
  tc_done; wait 2>/dev/null
  WHAT="网断到连续 $(grep -c '	connect	' "$R/thin.log") 次连不上（入口也连不上）：不换家，其间动鼠标、打字不回显也不送进会话；网回来 ${SECS}s 内回到 m1 同一个看台（--resume）的 s1"
}

drill_thin_home_down() {
  CAP=6   # the home down, the hub there: three failures, then another home
  local t0 n
  tc_rig
  ( THIN_ARGS='["--home", "m1", "s1"]' tc_drive hd '[["expect", "VIEW s1 ON m1"], ["linger", 40]]' & ) 2>/dev/null
  until_ok 10 grep -q 'True' "$R/res.hd" || { WHY="the view never came up: $(cat "$R/res.hd")"; tc_done; return 1; }
  touch "$R/down.m1"; t0=$(now); tc_drop_view
  until_ok "$CAP" grep -aq 'VIEW s1 ON m2' "$R/term.out" \
    || { WHY="no 换家 to m2: $(tail -n 4 "$R/thin.log" | tr '\t' ' ')"; tc_done; return 1; }
  SECS=$(since "$t0")
  n=$(grep '^m2 ' "$R/rv.log" | head -n 1)
  case $n in *--resume*) WHY="--resume on a home that has no view of ours: $n"; tc_done; return 1 ;; esac
  grep -aq 'rehome' "$R/thin.log" || { WHY="thin.log has no rehome line"; tc_done; return 1; }
  tc_done; wait 2>/dev/null
  WHAT="家机器 m1 停了、入口在：连续 3 次连不上后 ${SECS}s 换到 m2，新的看台（没有 --resume，仍按 --want 打开 s1），thin.log 记了 rehome"
}

tc_cleanup() {
  local r
  if [ -f "$WORK/tc-rigs" ]; then
    while read -r r; do pkill -9 -f "$r/" 2>/dev/null; "$RT" -S "$r/s/home" kill-server 2>/dev/null
      [ -n "${BREAK_KEEP:-}" ] || rm -rf "$r"; done < "$WORK/tc-rigs"
  fi
  cleanup
}
trap tc_cleanup EXIT
cred_run_drills "$0"
