#!/bin/bash
# fleet-break-it-thin-client-selftest.sh — docs/dev/BREAK-IT.md rows thin-* on the
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
#   thin-home-alone-down    (issue #4829) the home down and no other machine: the
#                           换家 finds none, the loop goes back to the home and is
#                           on it again once it is up — never asking forever
#   thin-first-heals        (issue #4829) no fleet there yet, the hub refuses the
#                           first session «m1: not ready: creds» three times (the
#                           machine coming up): waited out, said, then placed
#   thin-home-login-no-fleet  the person's fleet moved to another login on the
#                           machine (#3049): the hub's home answer names the
#                           login with the live fleet (Go tests by name, run when
#                           a toolchain is here), and the client enters as it
#   route-lan-elsewhere     (issue #3074) away from home with home's LAN line
#                           remembered: the pick never waits on that dark address
#   client-pack-file-missing  (issue #4826) the client package, cut to what a
#                           client uses: every offline word runs with no missing
#                           file, a served script comes on first use, --check
#                           holds the package to what its scripts name
#   client-stays-old        (issue #4916) a new client staged while the 看台 stays
#                           connected for hours: while the person types nothing
#                           moves; once idle the loop drops its line, execs the
#                           new version and is back on the SAME view — and does
#                           it again for the next one (FLEET_CLIENT_UPDATED is
#                           once, not forever)
#   client-update-deletes-foreign  (issue #4827) an upgrade to a manifest that
#                           drops files: the fleet's own unchanged copies go,
#                           a file the person put in or edited stays — in place
#                           and across a whole-version switch
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
  # the network down: ssh hangs in connect a while before it gives up, as a real one
# does — keys typed then land on its pty, which must not echo them (#3061)
cat > "$R/bin/ssh" <<EOF
#!/bin/sh
python3 -c 'import json, sys; print(json.dumps(sys.argv[1:]))' "\$@" >> "$R/ssh.ndjson"
for a; do prev=\$last; last=\$a; done
case \$prev in 127.0.0.1) host=m1 ;; 127.0.0.2) host=m2 ;; *) host=\$prev ;; esac
[ -e "$R/net.down" ] && { sleep 1.5; echo "ssh: connect to host \$prev: Network is unreachable" >&2; exit 255; }
[ -e "$R/down.\$host" ] && { echo "ssh: connect to host \$prev: Connection refused" >&2; exit 255; }
mkdir -p "$R/home/\$host"
cd "$R/home/\$host" || exit 255
[ -e "$R/stall-rig" ] || HOME="$R/home/\$host" HOST_NAME=\$host exec sh -c "\$last"
# thin-stall-drops: the line goes silent for \$(cat stall) seconds — ssh's own rule
# for it, off the argv it was given: ServerAliveCountMax keepalives in a row
# unanswered, one every ServerAliveInterval, and it gives the line up (255). The
# view stays in the foreground (its stdin is the pty); the watcher is the job.
ai=0 am=3
for a; do case \$a in ServerAliveInterval=*) ai=\${a#*=} ;; ServerAliveCountMax=*) am=\${a#*=} ;; esac; done
me=\$\$; rm -f "$R/cut.\$me"
( while kill -0 \$me 2>/dev/null; do
    if [ -e "$R/stall" ]; then
      d=\$(cat "$R/stall"); rm -f "$R/stall"; b=\$((ai * am))
      if [ "\$ai" -gt 0 ] && [ "\$d" -gt "\$b" ]; then
        sleep "\$b"; touch "$R/cut.\$me"; echo "Timeout, server \$prev not responding." >&2
        pkill -P \$me 2>/dev/null; exit 0
      fi
      echo "stalled \$d s, within \$b s" >> "$R/stalls"
    fi
    sleep 0.1
  done ) </dev/null &
HOME="$R/home/\$host" HOST_NAME=\$host sh -c "\$last"
rc=\$?
[ -e "$R/cut.\$me" ] && exit 255
exit \$rc
EOF
  local m
  for m in m1 m2; do
    mkdir -p "$R/home/$m/.claude/fleet/bin"
    ln -s "$BIN/fleet-thin-upload-fixture.py" "$R/home/$m/.claude/fleet/bin/fleet-client-upload.py"
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
# no fleet of yours yet (thin-first-heals): rc 3 until the first session is placed
[ -e "$R/empty.\$HOST_NAME" ] && { echo "fleet-remote-view: no fleet session is live on \$HOST_NAME" >&2; exit 3; }
# the home's tmux restarting (thin-home-restart-new-session): no fleet for N resumes
n=\$(cat "$R/nofleet.\$HOST_NAME" 2>/dev/null || echo 0)
if [ -n "\$resume" ] && [ "\$n" -gt 0 ]; then echo \$((n - 1)) > "$R/nofleet.\$HOST_NAME"
  echo "fleet-remote-view: no fleet session is live on \$HOST_NAME" >&2; exit 3; fi
mkdir -p "$R/views"; st="$R/views/\$HOST_NAME.\$view"
if [ -n "\$want" ]; then w=\$want; elif [ -n "\$resume" ] && [ -f "\$st" ]; then w=\$(cat "\$st"); else w=orch; fi
echo "\$w" > "\$st"
printf '\033]7502;cur;token=%s;m=%s;l=%s;w=u/%s;g=fixture\007' "\$token" "$ME" "\$(id -un)" "\$w"
if [ -e "$R/tmux.attach" ]; then
  # a real session behind it: the home's tmux, allow-passthrough on (as a node)
  exec "$RT" -S "$R/s/home" attach -t w
fi
stty -echo lnext undef 2>/dev/null
[ ! -e "$R/echo-input" ] || stty echo 2>/dev/null
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
env.update(json.loads(os.environ.get("THIN_ENV", "{}")))   # a drill's own knobs / seams
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
  touch "$R/echo-input"  # observe the inserted path before sending a NEW Enter
  # a static net first: the thin road never asks ssh for a master or a persisting one
  bad=$(grep -nE 'ControlMaster=(yes|auto|autoask|ask)|ControlPersist=' "$BIN/fleet-thin.py" "$BIN/fleet-thin-upload.py" 2>/dev/null)
  [ -z "$bad" ] || { WHY="the thin road asks for a master: $bad"; tc_done; return 1; }
  THIN_ARGS='["--home", "m1", "s1"]' tc_drive cs '[
   ["expect", "VIEW s1 ON m1"],
   ["send", "\u001b[200~'"$R"'/drop\\ me.txt\u001b[201~\n"],
   ["expect", "inbox"],
   ["send", "\n"],
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
  until_ok 6 test -e "$R/home/m1/.cache/claude-fleet/inbox/.target" || { WHY="no upload after the spoof (the loop gone? $(tail -n 2 "$R/thin.log" | tr '\t' ' '))"; tc_done; return 1; }
  SECS=$(since "$t0")
  kill -0 "$(cat "$R/thin.pid")" 2>/dev/null || { WHY="a forged quit ended the loop: $(tail -n 3 "$R/thin.log" | tr '\t' ' ')"; tc_done; return 1; }
  grep -aq SPOOFED "$R/term.out" || { WHY="the session's output never reached the person's terminal"; tc_done; return 1; }
  grep -aq ']7502' "$R/term.out" && { WHY="an OSC 7502 reached the person's terminal"; tc_done; return 1; }
  up=$(cat "$R/home/m1/.cache/claude-fleet/inbox/.target")
  case $up in *evil*) WHY="the upload followed a forged target: $up"; tc_done; return 1 ;; esac
  [ -n "$up" ] || { WHY="no committed target"; tc_done; return 1; }
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

drill_thin_stall_drops() {
  CAP=12   # an 8 s stall of the line → the session still there, no reconnect
  local t0 n bud
  tc_rig; touch "$R/stall-rig"
  ( THIN_ARGS='["--home", "m1", "s1"]' tc_drive st '[["expect", "VIEW s1 ON m1"], ["linger", 40]]' & ) 2>/dev/null
  until_ok 10 grep -q 'True' "$R/res.st" || { WHY="the view never came up: $(cat "$R/res.st")"; tc_done; return 1; }
  # the keepalive the loop gave ssh: never so long a real cut goes unnoticed
  bud=$(python3 -c '
import json, sys
a = json.loads(open(sys.argv[1]).readline()); o = {}
for x in a:
    if "=" in x: k, v = x.split("=", 1); o[k] = v
print(int(o.get("ServerAliveInterval", 0)) * int(o.get("ServerAliveCountMax", 3)))' "$R/ssh.ndjson")
  [ "$bud" -ge 1 ] && [ "$bud" -le 30 ] || { WHY="the view's ssh keepalive gives a dead line up after ${bud}s (want 1..30): $(head -n 1 "$R/ssh.ndjson")"; tc_done; return 1; }
  # the hotspot / the Wi-Fi scan: 8 s of silence, then the line is back
  t0=$(now); echo 8 > "$R/stall"
  until_ok 10 test -s "$R/stalls" || n=dropped
  sleep 1
  if grep -aq '	connect	' "$R/thin.log" || [ -n "${n:-}" ]; then
    WHY="an 8 s stall dropped the live session (keepalive ${bud}s): $(grep -a '	connect	' "$R/thin.log" | tail -n 1 | tr '\t' ' ')"; tc_done; return 1
  fi
  [ "$(grep -c . "$R/rv.log")" = 1 ] || { WHY="the view was attached again: $(cat "$R/rv.log")"; tc_done; return 1; }
  SECS=$(since "$t0")
  tc_done; wait 2>/dev/null
  # a real cut is still given up — and the drop says why (thin.log end=)
  tc_rig; touch "$R/stall-rig"
  ( THIN_ARGS='["--home", "m1", "s1"]' FLEET_THIN_ALIVE_SECS=1 FLEET_THIN_ALIVE_MAX=2 \
      tc_drive sc '[["expect", "VIEW s1 ON m1"], ["linger", 20]]' & ) 2>/dev/null
  until_ok 10 grep -q 'True' "$R/res.sc" || { WHY="the view never came up (2): $(cat "$R/res.sc")"; tc_done; return 1; }
  echo 60 > "$R/stall"
  until_ok 8 sh -c '[ "$(grep -ac "VIEW s1 ON m1" "$1/term.out")" -ge 2 ]' _ "$R" \
    || { WHY="a dead line was never given up and reconnected: $(tail -n 2 "$R/thin.log" | tr '\t' ' ')"; tc_done; return 1; }
  grep -aq '	connect	m1	.*	255	up	.*end=timeout' "$R/thin.log" \
    || { WHY="the drop's connect line does not say end=timeout: $(grep -a '	connect	' "$R/thin.log" | tr '\t' ' ')"; tc_done; return 1; }
  tc_done; wait 2>/dev/null
  WHAT="看台 ssh 的保活 ${bud}s：线路静默 8 s 再恢复，会话不断、不重连；真断（knob 1×2）照样判死、重连回 s1，thin.log 的断线行末尾记 end=timeout"
}

drill_thin_reconnect_slow_pick() {
  CAP=5   # remembered line dark, another LAN line up, a dead public one: not 2 + 3 × 2 s
  local sp D="$WORK/slow-pick" t0 out port
  mkdir -p "$D/home/.ssh" "$D/home/.cache/claude-fleet"
  python3 - "$D" <<'PY' &
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", 0)); s.listen(8)
open(sys.argv[1] + "/port", "w").write(str(s.getsockname()[1]))
s.settimeout(30)
try:
    while True:
        c, _ = s.accept(); c.sendall(b"SSH-2.0-fake\r\n"); c.close()
except Exception:
    pass
PY
  sp=$!   # reaped below: left running it held the next drill's bare `wait` up to 30 s (T532)
  until_ok 5 test -s "$D/port" || { kill "$sp" 2>/dev/null; WHY="the fake sshd never listened"; return 1; }
  port=$(cat "$D/port")
  # m1's lines: lan (answers — loopback stands in for the LAN address), lan-4
  # (remembered, gone dark: a v6 address that changed), public (a TEST-NET address nothing answers)
  printf 'Host m1 fleet-m1 fleet-m1-lan\n  HostName 127.0.0.1\n  Port %s\n  User me\nHost fleet-m1-lan-4\n  HostName 192.0.2.44\n  User me\nHost fleet-m1-public\n  HostName 198.51.100.7\n  User me\n' "$port" > "$D/home/.ssh/fleet-ssh-config"
  python3 - "$D" "$port" <<'PY'
import json, sys, time
d, port = sys.argv[1], int(sys.argv[2])
lan = {"name": "lan", "kind": "direct", "host": "127.0.0.1", "port": port}
lan4 = {"name": "lan-4", "kind": "direct", "host": "192.0.2.44", "port": 22}
pub = {"name": "public", "kind": "direct", "host": "198.51.100.7", "port": 22}
m = {"hostname": "", "alias": "m1", "relay": False, "routes": [lan, lan4, pub], "login": "me"}
now = time.time() - 60
ent = {"at": now, "hub": "", "label": "m1", "machine": m, "login": "me", "route": lan4, "routes": [lan, lan4, pub],
       "by_net": {"192.0.2.1@192.0.2.0/24": {"route": lan4, "at": now}}}
json.dump({"last": "m1", "machines": {"m1": ent}}, open(d + "/home/.cache/claude-fleet/connect.json", "w"))
PY
  t0=$(now)
  out=$(env -u FLEET_HUB_URL -u FLEET_HUB_TOKEN HOME="$D/home" XDG_CACHE_HOME="$D/home/.cache" \
        XDG_CONFIG_HOME="$D/home/.config" FLEET_CONF_DIR="$D/home/.config/claude-fleet" FLEET_CLIENT_LOG=0 \
        FLEET_CONNECT_TIMEOUT=2 FLEET_CONNECT_RETEST=last \
        FLEET_CONNECT_LOCAL_ADDRS="192.0.2.5/24" FLEET_CONNECT_NET_KEY="192.0.2.1@192.0.2.0/24" \
        python3 "$BIN/fleet-connect.py" m1 --print 2>"$D/err")
  SECS=$(since "$t0")
  kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
  case $out in *"-p $port 127.0.0.1"*) ;;
    *) WHY="not the lan line: '$out' $(head -c 300 "$D/err")"; return 1 ;; esac
  le "$SECS" "$CAP" || { WHY="the pick took ${SECS}s: it waited out the dead lines (remembered lan-4 2 s, public 3 × 2 s)"; return 1; }
  WHAT="重连时记住的 lan-4 不通（2 s 超时），另一条 lan 通、public 是死线（3 × 2 s）：${SECS}s 选中 lan，没等 public 测完"
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

drill_thin_home_alone_down() {
  CAP=10   # the home back up → on it again within a few backoffs
  local t0
  tc_rig
  # one machine only: a 换家 has nowhere to go
  printf 'Host m1 fleet-m1 fleet-m1-lan\n  HostName 127.0.0.1\n  User u1\n' > "$R/client/.ssh/fleet-ssh-config"
  printf 'm1 lan\n' > "$R/client/.config/claude-fleet/routes"
  ( THIN_ARGS='["--home", "m1", "s1"]' tc_drive ha '[["expect", "VIEW s1 ON m1"], ["linger", 40]]' & ) 2>/dev/null
  until_ok 10 grep -q 'True' "$R/res.ha" || { WHY="the view never came up: $(cat "$R/res.ha")"; tc_done; return 1; }
  touch "$R/down.m1"; tc_drop_view
  until_ok 10 grep -aq 'asking for a home other than m1' "$R/thin.log" \
    || { WHY="no 换家 asked: $(tail -n 4 "$R/thin.log" | tr '\t' ' ')"; tc_done; return 1; }
  sleep 2   # the 换家 finds nothing a few times while m1 is still down
  rm -f "$R/down.m1"; t0=$(now)
  until_ok "$CAP" sh -c '[ "$(grep -ac "VIEW s1 ON m1" "$1/term.out")" -ge 2 ]' _ "$R" \
    || { WHY="never back on m1 once it was up: $(tail -n 4 "$R/thin.log" | tr '\t' ' ')"; tc_done; return 1; }
  SECS=$(since "$t0")
  grep -aq 'no other home: back to m1' "$R/thin.log" || { WHY="thin.log has no back-to-the-home line"; tc_done; return 1; }
  grep -aq '除了 m1 没有别的在线机器' "$R/term.out" || { WHY="the screen never said there is no other machine"; tc_done; return 1; }
  tc_done; wait 2>/dev/null
  WHAT="家机器 m1 停了、也没有别的机器：换家找不到就回到 m1（屏幕说「除了 m1 没有别的在线机器，回到它接着重连」），m1 起来后 ${SECS}s 回到 s1"
}

drill_thin_first_heals() {
  CAP=12   # three «not ready» refusals 0.3 s apart, then placed and drawn (3 s warm, 8 s cold)
  local t0
  tc_rig
  touch "$R/empty.m1"
  cat > "$R/place.sh" <<PLACE
#!/bin/sh
n=\$(cat "$R/place.n" 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > "$R/place.n"
if [ \$n -le 3 ]; then
  printf 'DECLINED -\tNo machine can take a new session now — m1: not ready: creds; m2: 没有你的登录；正在更新（switched）\n'; exit 5
fi
rm -f "$R/empty.m1"; printf 'REMOTE m1 x y s1\n'
PLACE
  printf '#!/bin/sh\nprintf "active\\tL1\\n"\n' > "$R/lease.sh"
  chmod +x "$R/place.sh" "$R/lease.sh"; t0=$(now)
  ( THIN_ARGS='["--home", "m1", "s1"]' FLEET_THIN_FIRST_RETRY=0.3 FLEET_THIN_PLACE_CMD="$R/place.sh" \
      FLEET_CLIENT_LEASE_CMD="$R/lease.sh" FLEET_THIN_ACCOUNT_CMD="echo {}" \
      tc_drive fh '[["expect", "VIEW s1 ON m1", 20], ["linger", 2]]' & ) 2>/dev/null
  until_ok "$CAP" grep -aq 'VIEW s1 ON m1' "$R/term.out" \
    || { WHY="never placed and drawn: $(tail -n 4 "$R/thin.log" | tr '\t' ' ') / $(tr -d '\r' < "$R/term.out" | tail -n 3)"; tc_done; return 1; }
  SECS=$(since "$t0")
  grep -aq '没开出来' "$R/term.out" && { WHY="it told the person the first session did not open"; tc_done; return 1; }
  grep -aq '这会自己好' "$R/term.out" || { WHY="the screen never said it is waiting for the machine"; tc_done; return 1; }
  [ "$(cat "$R/place.n")" = 4 ] || { WHY="asked the hub $(cat "$R/place.n") times, not 4"; tc_done; return 1; }
  tc_done; wait 2>/dev/null
  WHAT="新人的第一个会话：入口三次说「m1: not ready: creds」（机器在起），客户端说「这会自己好，接着等」，第四次放下去，${SECS}s 画出 s1——不再两次就说没开出来"
}

drill_thin_home_restart_new_session() {
  CAP=8   # the home's tmux back → the same session, never a new one asked for
  local t0
  tc_rig
  ( THIN_ARGS='["--home", "m1", "s1"]' FLEET_THIN_HOME_RESTART_POLL=0.3 FLEET_THIN_PLACE_CMD="sh -c 'echo asked >> $R/place.log; exit 4'" \
      tc_drive hr '[["expect", "VIEW s1 ON m1"], ["linger", 40]]' & ) 2>/dev/null
  until_ok 10 grep -q 'True' "$R/res.hr" || { WHY="the view never came up: $(cat "$R/res.hr")"; tc_done; return 1; }
  # save · kill-server: the next three attaches find no fleet (rc 3), then restore
  echo 3 > "$R/nofleet.m1"; t0=$(now); tc_drop_view
  until_ok "$CAP" sh -c '[ "$(grep -ac "VIEW s1 ON m1" "$1/term.out")" -ge 2 ]' _ "$R" \
    || { WHY="not back on s1: $(tail -n 4 "$R/thin.log" | tr '\t' ' ')"; tc_done; return 1; }
  SECS=$(since "$t0")
  grep -aq '家机器 m1 在重启' "$R/term.out" || { WHY="the screen never said the home is restarting"; tc_done; return 1; }
  [ -s "$R/place.log" ] && { WHY="the loop asked the hub for a NEW session while the home restarted"; tc_done; return 1; }
  grep -aq '下没有 fleet\|没开出来' "$R/term.out" && { WHY="it told the person there is no fleet"; tc_done; return 1; }
  [ "$(grep -c '^m1 attach --thin .*--resume' "$R/rv.log")" -ge 4 ] || { WHY="an attach after the drop was not --resume: $(cat "$R/rv.log")"; tc_done; return 1; }
  tc_done; wait 2>/dev/null
  WHAT="家机器的 tmux 重启（save · kill-server · restore）：连着的看台连续 3 次 rc 3，屏幕说「家机器 m1 在重启，稍等」，${SECS}s 后 --resume 回到同一个 s1，没向入口要新会话"
}

drill_thin_home_login_no_fleet() {
  CAP=120; local t0 out rc tests f
  tests='TestHomeLoginIsTheOneWithALiveFleet TestHomeLoginNeverAnotherPersonsLogin'
  f="$ROOT/tokenledger/hub/api/fleet_home_login_test.go"
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  # the client half: a machine's own login wins, a no_fleet machine is no 换家
  # target, and rc 3 names the machine and the login
  grep -q 'hm\["login"\] != ent.get("login")' "$BIN/fleet-connect.py" && grep -q 'c.get("no_fleet")' "$BIN/fleet-connect.py" \
    || { WHY="fleet-connect.py no longer takes the home answer's per-machine login / skips no_fleet"; return 1; }
  grep -q 'thin_no_fleet_fmt' "$BIN/fleet-thin.py" || { WHY="the thin loop no longer says which login had no fleet"; return 1; }
  t0=$(now)
  WHAT='人的 fleet 搬到同机另一个登录（dave → carol）：入口的家答案每台机器带上有活 fleet 的那个登录（不是人的默认登录、不是别人的登录），别处有 fleet 时没有 fleet 的机器不当家、换家也不去；fleet-connect 照它进（FLEET_CONNECT_LOGIN 仍优先），看台遇到 rc 3 说「<机器> 这台机器的登录 <登录> 下没有 fleet」'
  go_half "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./hub/api; case $? in
    0) WHAT="${WHAT}（go test 两条）" ;;
    1) return 1 ;;
    2) WHAT="${WHAT}；Go 测试这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们" ;;
    3) WHAT="${WHAT}；没有 go：两条测试按名核对在，Go 门（tokenledger.yml）跑它们" ;;
  esac
  SECS=$(since "$t0")
}

drill_route_lan_elsewhere() {
  CAP=2   # away from home: no handshake to home's dark LAN address (FLEET_CONNECT_TIMEOUT=4)
  local sp D="$WORK/lan-elsewhere" t0 out port
  mkdir -p "$D/home/.ssh" "$D/home/.cache/claude-fleet"
  # a fake sshd for the tailnet line (loopback — always measured)
  python3 - "$D" <<'PY' &
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", 0)); s.listen(8)
open(sys.argv[1] + "/port", "w").write(str(s.getsockname()[1]))
s.settimeout(30)
try:
    while True:
        c, _ = s.accept(); c.sendall(b"SSH-2.0-fake\r\n"); c.close()
except Exception:
    pass
PY
  sp=$!   # reaped below: left running it held the next drill's bare `wait` up to 30 s (T532)
  until_ok 5 test -s "$D/port" || { kill "$sp" 2>/dev/null; WHY="the fake sshd never listened"; return 1; }
  port=$(cat "$D/port")
  # home's LAN line is a TEST-NET address nothing answers (as 192.168.1.249 is from a hotspot)
  printf 'Host m1 fleet-m1 fleet-m1-lan\n  HostName 192.0.2.10\n  User me\nHost fleet-m1-tailnet\n  HostName 127.0.0.1\n  Port %s\n  User me\n' "$port" > "$D/home/.ssh/fleet-ssh-config"
  # …and it is what was picked at home a minute ago
  python3 - "$D" "$port" <<'PY'
import json, sys, time
d, port = sys.argv[1], int(sys.argv[2])
lan = {"name": "lan", "kind": "direct", "host": "192.0.2.10", "port": 22}
tl = {"name": "tailnet", "kind": "direct", "host": "127.0.0.1", "port": port}
m = {"hostname": "", "alias": "m1", "relay": False, "routes": [lan, tl], "login": "me"}
now = time.time() - 60
ent = {"at": now, "hub": "", "label": "m1", "machine": m, "login": "me", "route": lan, "routes": [lan, tl],
       "by_net": {"192.0.2.1@192.0.2.0/24": {"route": lan, "at": now}}}
json.dump({"last": "m1", "machines": {"m1": ent}}, open(d + "/home/.cache/claude-fleet/connect.json", "w"))
PY
  t0=$(now)
  out=$(env -u FLEET_HUB_URL -u FLEET_HUB_TOKEN HOME="$D/home" XDG_CACHE_HOME="$D/home/.cache" \
        XDG_CONFIG_HOME="$D/home/.config" FLEET_CONF_DIR="$D/home/.config/claude-fleet" FLEET_CLIENT_LOG=0 \
        FLEET_CONNECT_TIMEOUT=4 FLEET_CONNECT_PROBES=1 \
        FLEET_CONNECT_LOCAL_ADDRS="172.20.10.3/28,100.101.2.3/32" FLEET_CONNECT_NET_KEY="172.20.10.1@172.20.10.0/28" \
        python3 "$BIN/fleet-connect.py" m1 --print 2>"$D/err")
  SECS=$(since "$t0")
  kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
  case $out in *"-p $port 127.0.0.1"*) ;;
    *) WHY="not the tailnet line: '$out' $(head -c 300 "$D/err")"; return 1 ;; esac
  WHAT="离开家里的局域网（热点 172.20.10.0/28），记住的是家里的 lan 192.0.2.10：没对它握手，${SECS}s 选中 Tailscale"
}

drill_thin_upload_blocks_input() {
  CAP=12
  local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-thin-upload-selftest.py" Pump 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT="慢剪贴板期间 PTY 输出和 resize 继续，Ctrl+C 只取消上传并及时恢复输入，暂停期文字回车不执行"
}


# client-pack-file-missing (issue #4826, EPIC #4823 C3): the client package
# leaves out a file a client road still runs. This tree's client, installed from
# a file:// copy of it (no hub) into a sandbox HOME: every word a client types
# offline runs with no missing-file error, the words whose scripts the package
# only serves fetch them on first use, and --check holds the package to what its
# scripts name. FLEET_CPM_SRC (another tree) is the seam that shows it red — a
# bin/fleet that knows no served file, against this manifest.
drill_client_pack_file_missing() {
  CAP=120
  local t0 src S H R M w out miss bad='' p
  t0=$(now)
  src=$(cd "${FLEET_CPM_SRC:-$BIN/..}" && pwd -P)
  S=$(mktemp -d /tmp/cpm.XXXXXX); S=$(cd "$S" && pwd -P); printf '%s\n' "$S" >> "$WORK/tc-rigs"
  M=tokenledger/hub/api/fleetclient/manifest
  mkdir -p "$S/src/$(dirname "$M")"; cp "$src/$M" "$S/src/$M"
  awk '!/^[[:space:]]*#/ && NF { print $1 }' "$S/src/$M" | while IFS= read -r p; do
    mkdir -p "$S/src/$(dirname "$p")"; cp -p "$src/$p" "$S/src/$p"
  done
  H="$S/home"; R="$H/.claude/fleet"; mkdir -p "$H"
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$H" LANG=C.UTF-8 TMPDIR="$S" FLEET_INSTALL_SRC="file://$S/src" \
    FLEET_INSTALL_NO_RUN=1 FLEET_INSTALL_NO_DEPS=1 FLEET_INSTALL_NO_HUB=1 FLEET_INSTALL_NO_NODE=1 FLEET_INSTALL_STATIC_TMUX=0 \
    sh "$S/src/bin/fleet-install.sh" >"$S/install.out" 2>&1 || { WHY="install: $(tail -n 2 "$S/install.out")"; return 1; }
  # the words, offline (test identity, no hub, no GitHub); a served file comes from the tree
  while IFS= read -r w; do
    # shellcheck disable=SC2086  # the word's arguments
    out=$(cd "$H" && env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$H" LANG=C.UTF-8 TERM=dumb TMPDIR="$S" \
      FLEET_CLIENT_IDENTITY=test FLEET_SERVED_FROM="file://$S/src" FLEET_STABLE_API="file://$S/no-api" \
      FLEET_CLIENT_CHECK_SECS=999999 FLEET_NOTIFY=0 "$R/bin/fleet" $w </dev/null 2>&1)
    miss=$(printf '%s\n' "$out" | grep -E "No such file|not found|can.t open|command not found|ModuleNotFoundError|unbound variable" | head -n 1)
    [ -z "$miss" ] || bad="$bad | fleet $w: $miss"
  done <<'EOF'
--help
status
update
doctor
host status
route
logout
ls --services
users --help
release stats --help
node status
config
claude --here
EOF
  for p in bin/fleet-users.py bin/fleet-hub-admin.py bin/fleet-release-stats.py; do
    [ -f "$R/$p" ] || bad="$bad | $p not fetched on first use"
  done
  [ -z "$bad" ] || { WHY="${bad# | }"; return 1; }
  # the package, held to what its scripts name (both ways)
  out=$(bash "$src/bin/fleet-client-runtime.sh" --check "$src/conf/client-runtime.list" "$src/$M" 2>&1) \
    || { WHY="fleet-client-runtime.sh --check: $(printf '%s' "$out" | head -n 3 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="纯客户端：13 个词离线跑通、没有一处缺文件；fleet users / release stats 用到时才把 served 的脚本取来；--check 两个方向都对得上"
}

# client-update-deletes-foreign (issue #4827, EPIC #4823 C4): an installed
# client upgraded to a manifest that no longer lists two of its files. This
# tree's client from a file:// copy with two extra fleet files on its manifest
# (v1), then the tree's own manifest (v2, v3): the fleet's unchanged copy goes,
# the one the person edited and the ones they put in stay — in place (no
# version) and across whole-version switches (only the current + the one before
# kept). FLEET_CUF_SRC (another tree) is the seam that shows it red.
drill_client_update_deletes_foreign() {
  CAP=150
  local t0 src S M p v H R bad=''
  t0=$(now)
  src=$(cd "${FLEET_CUF_SRC:-$BIN/..}" && pwd -P)
  S=$(mktemp -d /tmp/cuf.XXXXXX); S=$(cd "$S" && pwd -P); printf '%s\n' "$S" >> "$WORK/tc-rigs"
  M=tokenledger/hub/api/fleetclient/manifest
  for v in v1 v2; do
    mkdir -p "$S/$v/$(dirname "$M")"; cp "$src/$M" "$S/$v/$M"
    awk '!/^[[:space:]]*#/ && NF && $2 != "served" { print $1 }' "$S/$v/$M" | while IFS= read -r p; do
      mkdir -p "$S/$v/$(dirname "$p")"; cp -p "$src/$p" "$S/$v/$p"
    done
  done
  printf '#!/bin/sh\n# fleet-gone-a.sh\n' > "$S/v1/bin/fleet-gone-a.sh"
  printf '#!/bin/sh\n# fleet-gone-b.sh\n' > "$S/v1/bin/fleet-gone-b.sh"
  printf 'bin/fleet-gone-a.sh\nbin/fleet-gone-b.sh\n' >> "$S/v1/$M"
  # cuf_install <home> <src> [version] — the install line, offline
  cuf_install() {
    env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$1" LANG=C.UTF-8 TMPDIR="$S" FLEET_INSTALL_SRC="file://$S/$2" \
      ${3:+FLEET_INSTALL_VERSION="$3"} FLEET_INSTALL_NO_RUN=1 FLEET_INSTALL_NO_DEPS=1 FLEET_INSTALL_NO_HUB=1 \
      FLEET_INSTALL_NO_NODE=1 FLEET_INSTALL_STATIC_TMUX=0 \
      sh "$S/$2/bin/fleet-install.sh" >>"$S/install.out" 2>&1
  }
  # cuf_person <root> — what a person does to an installed client
  cuf_person() {
    printf '#!/bin/sh\necho mine\n' > "$1/bin/my-tool.sh"
    printf 'MINE=1\n' > "$1/conf/my.conf"
    printf '# edited by hand\n' >> "$1/bin/fleet-gone-b.sh"
  }
  # cuf_check <root> <leg>
  cuf_check() {
    [ -f "$1/bin/fleet" ] || bad="$bad | $2: bin/fleet missing"
    [ ! -e "$1/bin/fleet-gone-a.sh" ] || bad="$bad | $2: the fleet's unchanged bin/fleet-gone-a.sh left behind"
    for p in bin/my-tool.sh conf/my.conf; do [ -f "$1/$p" ] || bad="$bad | $2: the person's $p deleted"; done
    grep -q 'edited by hand' "$1/bin/fleet-gone-b.sh" 2>/dev/null || bad="$bad | $2: the person's edit of bin/fleet-gone-b.sh deleted"
  }
  # in place: no version named → file by file in the one directory
  H="$S/h1"; R="$H/.claude/fleet"; mkdir -p "$H"
  cuf_install "$H" v1 || { WHY="install v1: $(tail -n 2 "$S/install.out")"; return 1; }
  cuf_person "$R"
  cuf_install "$H" v2 || { WHY="install v2: $(tail -n 2 "$S/install.out")"; return 1; }
  cuf_check "$R" 'in place'
  # whole versions: v1 → v2 → v3, the person's files carried each time
  H="$S/h2"; R="$H/.claude/fleet"; mkdir -p "$H"
  cuf_install "$H" v1 1111111111111111111111111111111111111111 || { WHY="install v1 (versioned): $(tail -n 2 "$S/install.out")"; return 1; }
  cuf_person "$R"
  cuf_install "$H" v2 2222222222222222222222222222222222222222 || { WHY="install v2 (versioned): $(tail -n 2 "$S/install.out")"; return 1; }
  [ -L "$R" ] || bad="$bad | versioned: $R is not a link after the switch"
  cuf_check "$R" 'versioned v2'
  cuf_install "$H" v2 3333333333333333333333333333333333333333 || { WHY="install v3 (versioned): $(tail -n 2 "$S/install.out")"; return 1; }
  cuf_check "$R" 'versioned v3'
  v=$(find "$R.versions" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l | tr -d ' ')
  [ "$v" -le 2 ] || bad="$bad | versioned: $v version dirs kept (the current + the one before = 2)"
  [ -z "$bad" ] || { WHY="${bad# | }"; return 1; }
  SECS=$(since "$t0")
  WHAT="升级到少了两个文件的清单：fleet 原样的那个删了，人改过的、自己放的留着；整版切换两次也带着，版本目录只留当前 + 上一版"
}

drill_client_stays_old() {
  CAP=6   # staged, the person idle 1 s → the new version on the same view
  local t0 v steps i n
  tc_rig
  # the update's two halves (seams): poll says a new client is staged while
  # $R/new.ready is there; start switches to it (rc 3) and takes the mark away
  printf '#!/bin/sh\n[ -e "%s/new.ready" ] && exit 10\nexit 0\n' "$R" > "$R/poll.sh"
  printf '#!/bin/sh\nif [ -e "%s/new.ready" ]; then rm -f "%s/new.ready"; echo x >> "%s/switched"; exit 3; fi\nexit 0\n' "$R" "$R" "$R" > "$R/update.sh"
  chmod +x "$R/poll.sh" "$R/update.sh"
  # the person typing for 4 s (a key every 0.25 s), then idle for a long while
  steps='[["expect", "VIEW s1 ON m1"], ["await", "'"$R"'/new.ready", 15]'
  for i in $(seq 1 16); do steps="$steps"', ["send", "k"], ["linger", 0.25]'; done
  steps="$steps"', ["send", "\n"], ["linger", 40]]'
  ( THIN_ARGS='["--home", "m1", "s1"]' \
    THIN_ENV='{"FLEET_THIN_UPDATE_CMD": "'"$R"'/update.sh", "FLEET_THIN_POLL_CMD": "'"$R"'/poll.sh", "FLEET_THIN_POLL_SECS": "0.5", "FLEET_THIN_UPDATE_IDLE": "1"}' \
    tc_drive so "$steps" & ) 2>/dev/null
  until_ok 10 grep -q 'True' "$R/res.so" || { WHY="the view never came up: $(cat "$R/res.so")"; tc_done; return 1; }
  v=$(sed -n '1s/.*--view \([^ ]*\).*/\1/p' "$R/rv.log")
  # a release lands while the 看台 is up and the person is typing
  touch "$R/new.ready"; sleep 3.5
  [ ! -e "$R/switched" ] || { WHY="the client switched while the person was typing: $(tr '\t' ' ' < "$R/thin.log")"; tc_done; return 1; }
  t0=$(now)
  until_ok "$CAP" test -e "$R/switched" \
    || { WHY="a client staged while connected never took over (the 看台 stays on the old version until it is closed): $(tr '\t' ' ' < "$R/thin.log")"; tc_done; return 1; }
  until_ok "$CAP" sh -c '[ "$(grep -ac "VIEW s1 ON m1" "$1/term.out")" -ge 2 ]' _ "$R" \
    || { WHY="switched, but the view did not come back: $(tail -n 2 "$R/rv.log")"; tc_done; return 1; }
  SECS=$(since "$t0")
  n=$(sed -n 2p "$R/rv.log")
  case $n in "m1 attach --thin --view $v --resume "*) ;;
    *) WHY="after the switch the loop went to another view: '$n' (was m1 --view $v)"; tc_done; return 1 ;; esac
  grep -aq '	exec	' "$R/thin.log" || { WHY="no exec in thin.log: $(tr '\t' ' ' < "$R/thin.log")"; tc_done; return 1; }
  # the next release: the new process takes it too (not once per terminal)
  touch "$R/new.ready"
  until_ok "$CAP" sh -c '[ "$(grep -c . "$1/switched")" -ge 2 ] && [ "$(grep -ac "VIEW s1 ON m1" "$1/term.out")" -ge 3 ]' _ "$R" \
    || { WHY="the second release never took over (switched $(grep -c . "$R/switched")×): $(tr '\t' ' ' < "$R/thin.log")"; tc_done; return 1; }
  tc_done; wait 2>/dev/null
  WHAT="看台连着时取好了新版：人在打字不动；空闲 1 s 后 ${SECS}s 内断线、exec 新版、回到 m1 同一个看台（--resume）的 s1；下一版同样接上"
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
