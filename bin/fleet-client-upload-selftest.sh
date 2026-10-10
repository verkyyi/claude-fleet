#!/bin/bash
# fleet-client-upload-selftest.sh — a picture pasted, a file dropped: the session
# on another machine reads it (issue #2757, EPIC #2756 C1). Drives
# bin/fleet-client-upload.py (put · paste · filter · sweep), the ⌃V bind in
# conf/tmux-shell.conf and fleet-shell.sh's paste_sed, all against a fake ssh
# whose remote commands run in a sandbox HOME (the node), on isolated tmux
# sockets — never a live fleet.
#
#   A  put: the file lands in the node's inbox/<fleet_id>/ (0700) and its path
#      there is printed; the same bytes twice land once; over the bound → rc 3
#      and one line, nothing sent; the login's cap drops the oldest first
#   B  filter (the bytes toward ssh): a drop of existing paths is swapped for
#      the node's; any other paste, a path that does not exist, a lone Escape
#      pass byte for byte; a pty child sees the pane's size
#   C  paste (⌃V): a picture on the clipboard → put + bracket-paste of the
#      node's path into the stage's window; no picture / FLEET_CLIENT_PASTE=0 /
#      a session on this computer → ⌃V on to the pane as it is
#   D  sweep: a gone session's inbox goes, a live one stays, a key-named one and
#      `machine` wait out the days, a file past them goes
#   F  the writing area's draft handed to an open session: its files go first
#   E  the conf: ⌃V bound behind @fleet_paste; paste_sed fills 1 on a Mac only,
#      0 off / elsewhere / on a managed machine
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
UP="$BIN/fleet-client-upload.py"
W="$(mktemp -d "${TMPDIR:-/tmp}/fcu.XXXXXX")"; W="$(cd "$W" && pwd -P)"
FAILS=0
ok()   { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }
cleanup() {
  tmux -S "$W/shell.sock" kill-server 2>/dev/null
  tmux -S "$W/stage.sock" kill-server 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT

mkdir -p "$W/node" "$W/cli" "$W/mac"
cat > "$W/ssh" <<EOF_SSH
#!/bin/bash
for a in "\$@"; do [ "\$a" = -O ] && exit 0; done
last="\${@: -1}"
printf '%s\n' "\$last" >> "$W/ssh.calls"
case "\$last" in
  *fleet-inbox*) HOME="$W/node" exec sh -c "\$last" ;;
  *) cat > "$W/session.in"; exit 0 ;;
esac
EOF_SSH
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in ControlPath=*) : > "${a#ControlPath=}" ;; esac; done\n' > "$W/connect"
chmod +x "$W/ssh" "$W/connect"
export TMPDIR="$W/cli" FLEET_CLIENT_DIR="$W/cli" FLEET_REMOTE_SSH_CMD="$W/ssh" FLEET_CLIENT_ACTIONS_CONNECT="$W/connect" \
       FLEET_PASTE_LOG="$W/paste.log" FLEET_UI_LANG=zh
unset TMUX TMUX_PANE FLEET_SHELL_SESSION FLEET_SHELL_STAGE FLEET_CLIENT_PASTE
FID=11111111-2222-3333-4444-555555555555
WID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/$FID"
INBOX="$W/node/.cache/claude-fleet/inbox"

# ---------------------------------------------------------------- A put
printf 'shot' > "$W/mac/a shot.png"
p=$(python3 "$UP" put "m9:$WID" "$W/mac/a shot.png"); rc=$?
case "$p" in "$INBOX/$FID/"*-a_shot.png) ok "A put prints the node's path" ;; *) fail "A put printed [$p] rc $rc" ;; esac
[ "$(cat "$p" 2>/dev/null)" = shot ] && ok "A the bytes are there" || fail "A the file in the inbox is not the bytes sent"
[ "$(stat -f %Lp "$INBOX/$FID" 2>/dev/null || stat -c %a "$INBOX/$FID")" = 700 ] && ok "A the inbox is 0700" \
  || fail "A the inbox mode is $(ls -ld "$INBOX/$FID")"
p2=$(python3 "$UP" put "m9:$WID" "$W/mac/a shot.png")
[ "$p2" = "$p" ] && [ "$(ls "$INBOX/$FID" | wc -l | tr -d ' ')" = 1 ] && ok "A the same bytes land once" \
  || fail "A a second put of the same bytes made [$p2] ($(ls "$INBOX/$FID" | tr '\n' ' '))"
printf 'x' | python3 "$UP" put "m9:$WID" - --name 'clip.png' >/dev/null && ls "$INBOX/$FID" | grep -q -- '-clip.png$' \
  && ok "A put - takes stdin" || fail "A put - did not land"
python3 -c 'import sys; open(sys.argv[1], "wb").write(b"\0" * (10 * 1048576 + 1))' "$W/mac/big.png"
n0=$(wc -l < "$W/ssh.calls")
err=$(python3 "$UP" put "m9:$WID" "$W/mac/big.png" 2>&1 >/dev/null); rc=$?
[ "$rc" = 3 ] && case "$err" in *没传*big.png*10\ MB*) true ;; *) false ;; esac && [ "$(wc -l < "$W/ssh.calls")" = "$n0" ] \
  && ok "A over 10 MB: rc 3, one line, nothing sent ($err)" || fail "A over the bound: rc $rc [$err]"
cp "$W/mac/big.png" "$W/mac/big.log"
python3 "$UP" put "m9:$WID" "$W/mac/big.log" >/dev/null && ok "A a 10 MB non-image goes (100 MB bound)" \
  || fail "A a 10 MB log was refused"
# the login's cap: 1 MB ⇒ the 10 MB log just sent is the oldest, and goes first
FLEET_INBOX_CAP_MB=1 python3 "$UP" put "m9:$WID" "$W/mac/a shot.png" --name other.png >/dev/null
sleep 1; printf 'y' > "$W/mac/y.txt"
FLEET_INBOX_CAP_MB=1 python3 "$UP" put "m9:$WID" "$W/mac/y.txt" >/dev/null
ls "$INBOX/$FID" | grep -q 'big.log' && fail "A the cap did not drop the oldest" || ok "A past the cap the oldest goes"
ls "$INBOX/$FID" | grep -q 'y.txt' && ok "A the new file stays under the cap" || fail "A the cap dropped the new file"

# ---------------------------------------------------------------- B filter
rw() {   # python: feed chunks to a Rewriter, print what goes on
  python3 - "$UP" "$@" <<'EOF'
import importlib.util, sys
s = importlib.util.spec_from_file_location("u", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
r = m.Rewriter("m9", sys.argv[2], "")
out = b""
for c in sys.argv[3:]:
    o, waiting = r.feed(c.replace("\\x1b", "\x1b").encode())
    out += o
sys.stdout.buffer.write(out + r.flush())
EOF
}
same() { [ "$(rw "$WID" "$1" | od -An -tx1)" = "$(printf '%b' "$1" | od -An -tx1)" ]; }
same 'hello \x1b[200~some text\x1b[201~ bye' && ok "B a text paste passes byte for byte" || fail "B a text paste changed"
same "\x1b[200~$W/mac/nope.png\x1b[201~" && ok "B a path that does not exist passes" || fail "B a missing path was touched"
same "\x1b[200~see $W/mac/y.txt\x1b[201~" && ok "B prose with a path in it passes" || fail "B prose with a path was touched"
same '\x1b' && ok "B a lone Escape is not held" || fail "B a lone Escape was held"
[ -z "$(python3 - "$UP" <<'EOF'
import importlib.util, sys
s = importlib.util.spec_from_file_location("u", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
o, _ = m.Rewriter("m9", "x/y", "").feed(b"\x1b")
sys.stdout.write(repr(o) if o != b"\x1b" else "")
EOF
)" ] && ok "B a lone Escape goes at once" || fail "B a lone Escape waited for the next read"
got=$(rw "$WID" '\x1b[2' "00~$W/mac/a\\ shot.png $W/mac/y.txt \x1b[201~")
case "$got" in *"$INBOX/$FID/"*a_shot.png\ "$INBOX/$FID/"*y.txt\ $'\033[201~') ok "B a drop split across reads: both paths swapped" ;;
  *) fail "B a drop became [$(printf '%s' "$got" | tr '\033' '^')]" ;; esac
case "$got" in *"$W/mac"*) fail "B the Mac path went on" ;; esac
python3 -c 'import sys; open(sys.argv[1], "wb").write(b"\0" * (10 * 1048576 + 1))' "$W/mac/big2.png"
got=$(rw "$WID" "\x1b[200~$W/mac/big2.png\x1b[201~")
[ -z "$got" ] && ok "B a drop with nothing sendable sends nothing (no Mac path)" || fail "B an over-bound drop sent [$got]"
# the whole program, around a pty child that reports its size and what it read
python3 - "$UP" "$W" <<'EOF' && ok "B under a pty: bytes and size reach the child" || fail "B the pty leg"
import os, pty, sys, time, fcntl, termios, struct
up, w = sys.argv[1], sys.argv[2]
child = "import fcntl,termios,struct,sys,os,tty; tty.setraw(0); r,c,_,_=struct.unpack('HHHH',fcntl.ioctl(0,termios.TIOCGWINSZ,b'\\0'*8)); open(sys.argv[1],'w').write('%dx%d %s' % (c, r, os.read(0, 64)))"
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 33, 101, 0, 0))
    os.execvp("python3", ["python3", up, "filter", "--node", "m9", "--", "python3", "-c", child, w + "/pty.out"])
time.sleep(1.0)
os.write(fd, b"\x1b[200~hi\x1b[201~")
deadline = time.time() + 10
while time.time() < deadline:
    if os.waitpid(pid, os.WNOHANG)[0] == pid:
        break
    try:
        os.read(fd, 1024)
    except OSError:
        pass
    time.sleep(0.05)
out = open(w + "/pty.out").read()
sys.exit(0 if out.startswith("101x33 ") and "hi" in out else (print(out) or 1))
EOF
printf 'abc' | FLEET_CLIENT_PASTE=0 python3 "$UP" filter --node m9 -- sh -c "cat > '$W/off.out'"
[ "$(cat "$W/off.out")" = abc ] && ok "B FLEET_CLIENT_PASTE=0 runs the command bare" || fail "B off: [$(cat "$W/off.out")]"
printf 'abc' | python3 "$UP" filter --node m9 -- sh -c "exit 7"; [ $? = 7 ] && ok "B the child's exit code is the filter's" \
  || fail "B the filter lost the child's exit code"

# ---------------------------------------------------------------- C paste
tmux -S "$W/stage.sock" -f /dev/null new-session -d -s fcs -x 80 -y 20 "stty raw -echo; cat > '$W/stage.in'"
tmux -S "$W/stage.sock" set-window-option -t fcs: @remote "m9:$WID"
tmux -S "$W/shell.sock" -f /dev/null new-session -d -s fc -x 80 -y 20 "stty raw -echo; cat > '$W/shell.in'"
SPANE=$(tmux -S "$W/shell.sock" display -p -t fc: '#{pane_id}')
printf '#!/bin/sh\nprintf PNG > "$1"\n' > "$W/clip-yes"; printf '#!/bin/sh\nexit 1\n' > "$W/clip-no"; chmod +x "$W/clip-yes" "$W/clip-no"
pst() { FLEET_SHELL_STAGE=fcs FLEET_CLIENT_STAGE_CMD="tmux -S $W/stage.sock" FLEET_CLIENT_SHELL_CMD="tmux -S $W/shell.sock" \
        "$@" python3 "$UP" paste --pane "$SPANE"; }
pst env FLEET_CLIENT_CLIP_CMD="$W/clip-yes"
sleep 0.5
case "$(cat "$W/stage.in")" in "$INBOX/$FID/"*-clip.png) ok "C a picture: its node path is pasted into the stage's window" ;;
  *) fail "C the stage window got [$(cat "$W/stage.in")]" ;; esac
pst env FLEET_CLIENT_CLIP_CMD="$W/clip-no"
pst env FLEET_CLIENT_CLIP_CMD="$W/clip-yes" FLEET_CLIENT_PASTE=0
tmux -S "$W/stage.sock" set-window-option -t fcs: @remote "$(hostname -s):$WID"
pst env FLEET_CLIENT_CLIP_CMD="$W/clip-yes"
sleep 0.5
[ "$(od -An -c "$W/shell.in" | tr -d ' ')" = '026026026' ] && ok "C no picture / off / a session here: ⌃V goes on as it is" \
  || fail "C the shell pane got [$(od -An -c "$W/shell.in")], want three ^V"
[ "$(wc -l < "$W/stage.in" | tr -d ' ')" -le 1 ] && ! grep -q 'clip.png.*clip.png' "$W/stage.in" \
  && ok "C nothing else reached the session" || fail "C the stage got more: [$(cat "$W/stage.in")]"

# ---------------------------------------------------------------- D sweep
G=99999999-2222-3333-4444-555555555555
mkdir -p "$W/home/.cache/claude-fleet/inbox/$G" "$W/home/.cache/claude-fleet/inbox/$FID" \
         "$W/home/.cache/claude-fleet/inbox/issue-7" "$W/home/.cache/claude-fleet/inbox/machine"
I2="$W/home/.cache/claude-fleet/inbox"
for d in "$G" "$FID" issue-7 machine; do printf x > "$I2/$d/f"; done
printf x > "$I2/$FID/old"; touch -t 202001010000 "$I2/$FID/old"
printf '#!/bin/sh\necho %s\necho other\n' "$FID" > "$W/live"; chmod +x "$W/live"
HOME="$W/home" FLEET_INBOX_LIVE_CMD="$W/live" python3 "$UP" sweep --dry > "$W/dry.out"
[ -d "$I2/$G" ] && grep -q "$G" "$W/dry.out" && ok "D --dry names, removes nothing" || fail "D --dry: $(cat "$W/dry.out")"
HOME="$W/home" FLEET_INBOX_LIVE_CMD="$W/live" python3 "$UP" sweep >/dev/null
[ ! -e "$I2/$G" ] && ok "D a gone session's inbox goes" || fail "D the gone session's inbox stayed"
[ -f "$I2/$FID/f" ] && [ ! -e "$I2/$FID/old" ] && ok "D a live one stays; a file past 7 days goes" || fail "D live: $(ls "$I2/$FID")"
[ -f "$I2/issue-7/f" ] && [ -f "$I2/machine/f" ] && ok "D key-named and machine wait out the days" || fail "D a key-named dir went"
printf '#!/bin/sh\nexit 1\n' > "$W/live"
HOME="$W/home" FLEET_INBOX_LIVE_CMD="$W/live" python3 "$UP" sweep >/dev/null
[ -f "$I2/$FID/f" ] && ok "D no read of the live windows removes no session's inbox" || fail "D an unknown read removed a live inbox"

# ---------------------------------------------------------------- F the draft
# ⇧⇥ hands the writing area's draft to the open orchestrator (fleet-compose.py
# carry): its dropped files go first, the text names them there
got=$(python3 - "$BIN/fleet-compose.py" "$W/mac/a\\ shot.png" "$WID" <<'EOF'
import importlib.util, sys
s = importlib.util.spec_from_file_location("c", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.carried_files("look at %s please" % sys.argv[2], {"node": "m9", "wid": sys.argv[3]}))
EOF
)
case "$got" in "look at $INBOX/$FID/"*a_shot.png" please") ok "F the draft's file goes first, the text names it there" ;;
  *) fail "F carried_files gave [$got]" ;; esac

# ---------------------------------------------------------------- E conf
CONF="$BIN/../conf/tmux-shell.conf"
grep -q '^set -g @fleet_paste __PASTE__$' "$CONF" && grep -q "^bind -n C-v if -F '#{&&:#{==:#{@fleet_paste},1}," "$CONF" \
  && grep -q 'fleet-client-upload.py paste' "$CONF" && ok "E ⌃V is bound behind @fleet_paste" || fail "E the conf's ⌃V bind"
ps_() { bash -c 'eval "$(sed -n "/^paste_sed()/,/^}/p" "$1")"; paste_sed' - "$BIN/fleet-shell.sh"; }
[ "$(FLEET_CLIENT_PASTE_OS=Darwin ps_)" = 's|__PASTE__|1|g' ] \
  && [ "$(FLEET_CLIENT_PASTE_OS=Darwin FLEET_CLIENT_PASTE=0 ps_)" = 's|__PASTE__|0|g' ] \
  && [ "$(FLEET_CLIENT_PASTE_OS=Linux ps_)" = 's|__PASTE__|0|g' ] \
  && [ "$(FLEET_CLIENT_PASTE_OS=Darwin FLEET_NODE_HOSTED=1 ps_)" = 's|__PASTE__|0|g' ] \
  && ok "E @fleet_paste is 1 on a Mac's own client only" || fail "E paste_sed"
grep -q 'FLEET_CLIENT_PASTE; do' "$BIN/fleet-shell.sh" && ok "E FLEET_CLIENT_PASTE reaches the shell's servers" \
  || fail "E FLEET_CLIENT_PASTE is not passed to the shell's environment"
grep -q 'fleet-client-upload.py" filter' "$BIN/fleet-remote-view.sh" && ok "E the proxy's ssh runs behind the filter" \
  || fail "E fleet-remote-view.sh does not wrap its ssh"

if [ "$FAILS" -gt 0 ]; then
  printf 'fleet-client-upload selftest: %d FAILED\n' "$FAILS" >&2
  exit 1
fi
printf 'fleet-client-upload selftest: OK\n'
