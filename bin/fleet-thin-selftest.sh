#!/bin/bash
# fleet-thin-selftest.sh — the thin client: one loop, one ssh to the home
# machine (issue #3003, EPIC #2999 C6). Drives bin/fleet-thin.py under a python
# pty, against a stand-in for ssh (runs the remote command in a sandbox HOME
# per machine) and a stand-in for the home's view (`fleet-remote-view.sh attach
# --thin`, EPIC 约定 6: says `cur` in OSC 7502, then reads lines) — never a live
# fleet, never the person's client.
#
#   A  fleet-connect.py --argv: the ssh as JSON, the host's index, -o before it;
#      --avoid takes the next machine; fleet-client-upload.py recv: this machine
#      → the inbox here, another one with no standing connection → rc 1, said
#   B  a connection: --view once, --want the first time, -tt + ControlMaster=no
#      + ControlPath=none + ServerAlive before the host; the OSC 7502s never reach
#      the terminal; the iTerm2 profile goes to fleet; the loop's only child is
#      the ssh (no tmux, no background process); no socket file anywhere
#   C  a drop: one line 「…重连（第 1 次）」, the reconnect is --resume on the
#      SAME view and lands on the same session
#   D  a 7502 with another token does nothing: `quit` ignored, its `cur` never
#      steers an upload
#   E  a drop of a file and ⌃V with a picture: the path ON THE HOME goes in, as
#      a bracketed paste; ⌃V with no picture is the ⌃V itself
#   F  three failed connections → --avoid <home>: a new home, a fresh view there
#   G  a new client between connections is exec'd, view kept (--resume)
#   H  ⌘Q (quit with our token) → exit 0 and the profile back; SIGHUP → the loop
#      and its ssh gone, nothing left; no terminal → exit 2
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/fthin.XXXXXX")"; T="$(cd "$T" && pwd -P)"
FAILS=0
ok()   { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }
cleanup() {
  pkill -f "$T/" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

ME=$(python3 -c 'import platform; print(platform.node().split(".", 1)[0])')

# ---------------------------------------------------------------------------
# A — fleet-connect.py --argv, fleet-client-upload.py recv
# ---------------------------------------------------------------------------
H="$T/a"; mkdir -p "$H/.ssh" "$H/.config/claude-fleet"
cat > "$H/.ssh/fleet-ssh-config" <<'EOF'
Host m1 fleet-m1 fleet-m1-lan
  HostName 127.0.0.1
  Port 2222
  User u1
Host m2 fleet-m2 fleet-m2-lan
  HostName 127.0.0.2
  User u2
EOF
printf 'm1 lan\nm2 lan\n' > "$H/.config/claude-fleet/routes"
argv() { env -i HOME="$H" PATH="$PATH" XDG_CONFIG_HOME="$H/.config" XDG_CACHE_HOME="$H/.cache" \
           FLEET_CLIENT_LOG=0 python3 "$BIN/fleet-connect.py" --argv "$@"; }
j=$(argv m1 -o ControlMaster=no) || fail "A: --argv m1 exit $?"
python3 - "$j" <<'EOF' && ok "A: --argv m1 → the ssh as JSON, host index, -o before the host" || fail "A: --argv m1: $j"
import json, sys
j = json.loads(sys.argv[1])
a, h = j["argv"], j["host"]
assert a[0] == "ssh" and a[h] == "127.0.0.1" and h == len(a) - 1, j
assert a.index("ControlMaster=no") < h and "-l" in a and a[a.index("-l") + 1] == "u1", j
assert j["machine"] == "m1" and j["login"] == "u1" and j["route"] == {"kind": "direct", "name": "lan"}, j
EOF
j=$(argv --avoid m1) || fail "A: --argv --avoid m1 exit $?"
case $j in *'"machine": "m2"'*) ok "A: --avoid m1 → m2" ;; *) fail "A: --avoid m1: $j" ;; esac
UP="$BIN/fleet-client-upload.py"
p=$(printf 'abc' | HOME="$T/recv" FLEET_PASTE_LOG="$T/paste.log" python3 "$UP" recv "$ME" "$(id -un)" "x/fid1" --name n.txt)
if [ "$?" = 0 ] && [ "$(cat "$p" 2>/dev/null)" = abc ] && case $p in "$T/recv/.cache/claude-fleet/inbox/fid1/"*-n.txt) true ;; *) false ;; esac; then
  ok "A: recv for this machine → the inbox here, its path printed"
else fail "A: recv here: '$p'"; fi
e=$(printf 'abc' | HOME="$T/recv" FLEET_CONF_DIR="$T/recv/conf" FLEET_PASTE_LOG="$T/paste.log" FLEET_UI_LANG=en \
      python3 "$UP" recv elsewhere u9 "x/fid1" --name n.txt 2>&1 >/dev/null); rc=$?
[ "$rc" = 1 ] && case $e in *'no connection to elsewhere'*) true ;; *) false ;; esac \
  && ok "A: recv for another machine with no standing connection → rc 1, said" || fail "A: recv elsewhere rc=$rc '$e'"

# ---------------------------------------------------------------------------
# the stand-ins
# ---------------------------------------------------------------------------
# argv: the --argv seam — a home named, else m1 (m2 when --avoid m1)
cat > "$T/argv.sh" <<EOF
#!/bin/sh
echo "\$*" >> "$T/argv.log"
home=m1
case " \$* " in *" --avoid m1 "*) home=m2 ;; esac
case "\${1:-}" in m*) home=\$1 ;; esac
printf '{"argv": ["sh", "$T/ssh.sh", "-o", "X=1", "%s"], "host": 4, "machine": "%s", "login": "u1", "route": {"kind": "direct", "name": "lan"}}\n' "\$home" "\$home"
EOF
# ssh: the remote command in the machine's sandbox HOME; a machine marked down → 255
cat > "$T/ssh.sh" <<EOF
#!/bin/sh
echo "\$*" >> "$T/ssh.log"
for a; do prev=\$last; last=\$a; done
host=\$prev; remote=\$last
[ -e "$T/down.\$host" ] && { echo "ssh: connect to host \$host: Connection refused" >&2; exit 255; }
mkdir -p "$T/home/\$host"
cd "$T/home/\$host" && HOME="$T/home/\$host" HOST_NAME=\$host exec sh -c "\$remote"
EOF
for m in m1 m2; do
  mkdir -p "$T/home/$m/.claude/fleet/bin"
  ln -s "$BIN/fleet-client-upload.py" "$T/home/$m/.claude/fleet/bin/fleet-client-upload.py"
  cat > "$T/home/$m/.claude/fleet/bin/fleet-remote-view.sh" <<EOF
#!/bin/bash
echo "\$HOST_NAME \$*" >> "$T/rv.log"
view= want= resume= token=
while [ \$# -gt 0 ]; do
  case \$1 in
    --view) view=\$2; shift ;; --want) want=\$2; shift ;; --resume) resume=1 ;;
    --token) token=\$2; shift ;; --device|--route) shift ;;
  esac; shift
done
mkdir -p "$T/views"; st="$T/views/\$HOST_NAME.\$view"
if [ -n "\$want" ]; then w=\$want; elif [ -n "\$resume" ] && [ -f "\$st" ]; then w=\$(cat "\$st"); else w=orch; fi
echo "\$w" > "\$st"
stty -echo lnext undef 2>/dev/null
printf '\033]7502;cur;token=bad;m=evil;l=evil;w=evil\007'
printf '\033]7502;cur;token=%s;m=%s;l=%s;w=u/%s\007' "\$token" "$ME" "\$(id -un)" "\$w"
printf 'VIEW %s ON %s\r\n' "\$w" "\$HOST_NAME"
while IFS= read -r line; do
  case \$line in
    quit)     printf '\033]7502;quit;token=%s\007' "\$token"; exit 0 ;;
    fakequit) printf '\033]7502;quit;token=bad\007'; printf 'FAKE SENT\r\n' ;;
    drop)     exit 255 ;;
    *)        printf 'GOT[%s]\r\n' "\$(printf '%s' "\$line" | cat -v)" ;;
  esac
done
EOF
done
chmod +x "$T/argv.sh" "$T/ssh.sh"
mkdir -p "$T/iterm"; echo '{}' > "$T/iterm/fleet.json"
printf 'PNGDATA' > "$T/pic.png"
cat > "$T/clip.sh" <<EOF
#!/bin/sh
[ -e "$T/clip.on" ] || exit 1
cp "$T/pic.png" "\$1"
EOF
chmod +x "$T/clip.sh"
printf 'dropped' > "$T/drop me.txt"
echo v1 > "$T/version"

# the harness: fleet-thin.py under a pty, a script of (send, expect) steps
cat > "$T/drive.py" <<'EOF'
import os, pty, re, select, signal, subprocess, sys, time, json
T, BIN, script = sys.argv[1], sys.argv[2], sys.argv[3]
env = dict(os.environ, HOME=T + "/client", XDG_CACHE_HOME=T + "/client/.cache", FLEET_THIN_LOG=T + "/thin.log",
           FLEET_THIN_ARGV_CMD=T + "/argv.sh", FLEET_THIN_BACKOFF="0.2", FLEET_THIN_UP_SECS="1.5",
           FLEET_THIN_UPDATE_CMD=T + "/update.sh", FLEET_CLIENT_XTVERSION="0", FLEET_UI_LANG="zh",
           FLEET_CLIENT_CLIP_CMD=T + "/clip.sh", FLEET_PASTE_LOG=T + "/paste.log",
           ITERM_PROFILE="Default", TERM_PROGRAM="iTerm.app", FLEET_ITERM_DIR=T + "/iterm")
for k in ("TMUX", "TMUX_PANE", "FLEET_CLIENT_UPDATED", "LC_TERMINAL"):
    env.pop(k, None)
args = json.loads(os.environ.get("THIN_ARGS", "[]"))
pid, fd = pty.fork()
if pid == 0:
    os.execvpe(sys.executable, [sys.executable, BIN + "/fleet-thin.py"] + args, env)
buf = b""
def read_until(pat, tmo=10):
    global buf
    end = time.time() + tmo
    while time.time() < end:
        if re.search(pat.encode(), buf):
            return True
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                d = os.read(fd, 65536)
            except OSError:
                return bool(re.search(pat.encode(), buf))
            if not d:
                break
            buf += d
    return bool(re.search(pat.encode(), buf))
rc = None
for step in json.load(open(script)):
    kind, arg = step[0], step[1]
    if kind == "send":
        os.write(fd, arg.encode("latin-1"))
    elif kind == "expect":
        if not read_until(arg, step[2] if len(step) > 2 else 10):
            print("TIMEOUT waiting for %r" % arg)
    elif kind == "sleep":
        time.sleep(arg)
    elif kind == "children":
        kids = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout.split()
        cmds = [subprocess.run(["ps", "-o", "command=", "-p", k], capture_output=True, text=True).stdout.strip() for k in kids]
        print("CHILDREN %d %s" % (len(kids), " | ".join(cmds)))
    elif kind == "hup":
        os.kill(pid, signal.SIGHUP)
    elif kind == "wait":
        end = time.time() + arg
        while time.time() < end:
            read_until("$^", 0.1)
            done, st = os.waitpid(pid, os.WNOHANG)
            if done == pid:
                rc = os.WEXITSTATUS(st) if os.WIFEXITED(st) else 128 + os.WTERMSIG(st)
                break
        print("RC %s" % rc)
        print("THINPID %d" % pid)
open(T + "/out." + os.path.basename(script), "wb").write(buf)
EOF
drive() {   # drive <name> <json steps>  → $T/res.<name> (harness notes), $T/out.<name> (the terminal)
  printf '%s' "$2" > "$T/$1"
  python3 "$T/drive.py" "$T" "$BIN" "$T/$1" > "$T/res.$1" 2>&1
}
printf '#!/bin/sh\nexit 0\n' > "$T/update.sh"; chmod +x "$T/update.sh"

# ---------------------------------------------------------------------------
# B C D E — one session: connect, drop, a fake quit, uploads, quit
# ---------------------------------------------------------------------------
: > "$T/rv.log"; : > "$T/ssh.log"
THIN_ARGS='["s1"]' drive main '[
 ["expect", "VIEW s1 ON m1"],
 ["children", ""],
 ["send", "drop\n"],
 ["expect", "VIEW s1 ON m1[\\s\\S]*VIEW s1 ON m1"],
 ["send", "fakequit\n"],
 ["expect", "FAKE SENT"],
 ["sleep", 0.5],
 ["send", "\u001b[200~'"$T"'/drop\\ me.txt\u001b[201~\n"],
 ["expect", "GOT\\[.*inbox"],
 ["send", "\u0016"],
 ["sleep", 0.4],
 ["send", "x\n"],
 ["expect", "GOT\\[\\^Vx\\]"],
 ["sleep", 0.2]
]' # (the session goes on in the next step through quit; this one ends on SIGHUP below)
out=$(cat "$T/out.main" 2>/dev/null); res=$(cat "$T/res.main")
case $res in *TIMEOUT*) fail "B-E: the harness timed out: $res" ;; esac
l1=$(sed -n 1p "$T/rv.log"); l2=$(sed -n 2p "$T/rv.log")
view=$(printf '%s\n' "$l1" | sed -n 's/.*--view \([^ ]*\).*/\1/p')
case $l1 in "m1 attach --thin --view $view --want s1 --device "*" --route lan --token "*) ok "B: first attach — --view, --want s1, --device, --route, --token" ;;
  *) fail "B: first attach: $l1" ;; esac
s1=$(sed -n 1p "$T/ssh.log")
case $s1 in *"-o X=1 -tt -o ControlMaster=no -o ControlPath=none -o ServerAliveInterval=2 -o ServerAliveCountMax=3 m1 bash .claude/fleet/bin/fleet-remote-view.sh attach --thin"*)
  ok "B: -tt, ControlMaster=no, ControlPath=none, ServerAlive before the host; the view's command after" ;;
  *) fail "B: ssh argv: $s1" ;; esac
case $out in *7502*) fail "B: an OSC 7502 reached the terminal" ;; *) ok "B: no OSC 7502 reaches the terminal (ours and the bad-token one)" ;; esac
case $out in $'\e]1337;SetProfile=fleet\a'*) ok "B: the iTerm2 profile goes to fleet first" ;; *) fail "B: no SetProfile=fleet first" ;; esac
case $res in *"CHILDREN 1 bash .claude/fleet/bin/fleet-remote-view.sh attach --thin "*) ok "B: the loop's only child is the ssh" ;; *) fail "B: children: $(grep CHILDREN "$T/res.main")" ;; esac
socks=$(find "$T/client" -type s 2>/dev/null | wc -l | tr -d ' ')
[ "$socks" = 0 ] && ok "B: no socket file under the client's HOME / cache" || fail "B: $socks socket file(s)"
case $out in *'和 m1 的连接断了，0.2 秒后重连（第 1 次）'*) ok "C: a drop → one line 「和 m1 的连接断了…（第 1 次）」" ;; *) fail "C: no reconnect line" ;; esac
case $l2 in "m1 attach --thin --view $view --resume --device "*) ok "C: the reconnect is --resume on the same view, back on s1" ;; *) fail "C: reconnect: $l2" ;; esac
[ "$(grep -c 'VIEW s1 ON m1' "$T/out.main")" -ge 2 ] || fail "C: not back on s1"
case $out in *'FAKE SENT'*'GOT['*) ok "D: a quit with another token does nothing" ;; *) fail "D: the loop ended on a bad token" ;; esac
got=$(grep -ao 'GOT\[[^]]*\]' "$T/out.main" | head -1)
case $got in *"^[[200~$T/home/m1/.cache/claude-fleet/inbox/s1/"*"-drop_me.txt^[[201~]") ok "E: a drop → the path on the home, bracket-pasted" ;;
  *) fail "E: drop: $got" ;; esac
[ "$(cat "$T"/home/m1/.cache/claude-fleet/inbox/*/*drop_me.txt 2>/dev/null)" = dropped ] \
  && ok "E: the dropped file's bytes are in the home's inbox" || fail "E: the file is not in the home's inbox"
grep -q 'evil' "$T/paste.log" 2>/dev/null && fail "D: an upload went by the bad-token cur" || ok "D: the bad-token cur never steered an upload"
case $out in *'GOT[^Vx]'*) ok "E: ⌃V with no picture is the ⌃V itself" ;; *) fail "E: ⌃V with no picture" ;; esac

# ⌃V with a picture, then quit
touch "$T/clip.on"; : > "$T/rv.log"
THIN_ARGS='[]' drive pic '[
 ["expect", "VIEW orch ON m1"],
 ["send", "\u0016"],
 ["sleep", 0.8],
 ["send", "\n"],
 ["expect", "GOT\\[.*clip.png"],
 ["send", "quit\n"],
 ["wait", 10]
]'
out=$(cat "$T/out.pic"); res=$(cat "$T/res.pic")
case $(grep -ao 'GOT\[[^]]*\]' "$T/out.pic") in *"^[[200~$T/home/m1/.cache/claude-fleet/inbox/orch/"*"-clip.png^[[201~]") ok "E: ⌃V with a picture → its path on the home, bracket-pasted" ;;
  *) fail "E: ⌃V picture: $(grep -ao 'GOT\[[^]]*\]' "$T/out.pic")" ;; esac
case $res in *'RC 0'*) ok "H: ⌘Q (quit, our token) → exit 0" ;; *) fail "H: quit: $res" ;; esac
case $out in *$'\e]1337;SetProfile=Default\a') ok "H: the iTerm2 profile back last" ;; *) fail "H: profile not restored at the end" ;; esac
rm -f "$T/clip.on"

# ---------------------------------------------------------------------------
# F — three failures → another home
# ---------------------------------------------------------------------------
: > "$T/rv.log"; : > "$T/argv.log"
THIN_ARGS='[]' drive rehome '[
 ["expect", "VIEW orch ON m1"],
 ["sleep", 1.7],
 ["send", "drop\n"],
 ["expect", "VIEW orch ON m2", 15],
 ["send", "quit\n"],
 ["wait", 10]
]' &
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$T/rv.log" ] && break; sleep 0.2
done
touch "$T/down.m1"; wait
grep -q -- '--avoid m1' "$T/argv.log" && ok "F: three failed connections → --avoid m1" || fail "F: argv: $(cat "$T/argv.log")"
[ "$(grep -c '^m1 ' "$T/rv.log")" = 1 ] && [ "$(grep -c '^m1' "$T/ssh.log")" -ge 1 ] || :
l=$(grep '^m2 ' "$T/rv.log" | head -1)
case $l in "m2 attach --thin --view "*" --device "*) case $l in *--resume*) fail "F: --resume on a new home" ;; *) ok "F: on m2 with a fresh view (no --resume)" ;; esac ;;
  *) fail "F: never reached m2: $(cat "$T/rv.log")" ;; esac
grep -q 'rehome' "$T/thin.log" && ok "F: thin.log says rehome" || fail "F: no rehome line"
rm -f "$T/down.m1"

# ---------------------------------------------------------------------------
# G — a new version between connections
# ---------------------------------------------------------------------------
: > "$T/rv.log"
printf '#!/bin/sh\n[ -e "%s/updated" ] && exit 0\ntouch "%s/updated"; exit 3\n' "$T" "$T" > "$T/update.sh"
THIN_ARGS='[]' drive upd '[
 ["expect", "VIEW orch ON m1"],
 ["sleep", 1.7],
 ["send", "drop\n"],
 ["expect", "VIEW orch ON m1[\\s\\S]*VIEW orch ON m1", 15],
 ["send", "quit\n"],
 ["wait", 10]
]'
v1=$(sed -n '1s/.*--view \([^ ]*\).*/\1/p' "$T/rv.log"); l2=$(sed -n 2p "$T/rv.log")
grep -q "	exec	" "$T/thin.log" && ok "G: a new client between connections → exec (thin.log)" || fail "G: no exec line"
case $l2 in "m1 attach --thin --view $v1 --resume "*) ok "G: the new version resumes the same view" ;; *) fail "G: after exec: $l2" ;; esac
printf '#!/bin/sh\nexit 0\n' > "$T/update.sh"

# ---------------------------------------------------------------------------
# H — SIGHUP: nothing left; thin.log; no terminal
# ---------------------------------------------------------------------------
THIN_ARGS='[]' drive hup '[
 ["expect", "VIEW orch ON m1"],
 ["hup", ""],
 ["wait", 5]
]'
sleep 0.3
left=$(pgrep -f "$T/" | while read -r p; do ps -o command= -p "$p"; done | grep -v 'drive.py' | grep -c .)
[ "$left" = 0 ] && ok "H: SIGHUP → the loop and its ssh gone, nothing left" || fail "H: left after SIGHUP: $(pgrep -fl "$T/")"
case $(cat "$T/res.hup") in *'RC 129'*) ok "H: SIGHUP → exit 129" ;; *) fail "H: hup: $(cat "$T/res.hup")" ;; esac
awk -F '\t' '$2 == "connect" && NF >= 9 && $3 == "m1" && $4 == "lan" && $5 ~ /^[0-9]+$/ && $6 ~ /^[0-9]+$/ && $7 ~ /^[0-9]+$/ { n++ } END { exit !(n > 0) }' "$T/thin.log" \
  && ok "H: thin.log connect lines carry home · route · pick_ms · ssh_ms · first_ms" || fail "H: thin.log: $(head -3 "$T/thin.log")"
e=$(python3 "$BIN/fleet-thin.py" </dev/null 2>&1); rc=$?
[ "$rc" = 2 ] && ok "H: no terminal → exit 2, one line" || fail "H: no tty rc=$rc $e"

echo
[ "$FAILS" = 0 ] && { echo "fleet-thin-selftest: PASS"; exit 0; }
echo "fleet-thin-selftest: $FAILS FAIL"; exit 1
