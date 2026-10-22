#!/bin/bash
# fleet-panel-server-selftest.sh — ⌘P's resident panel (T890,
# bin/fleet-panel-server.py) and the key's direct popup (fleet-popup-lib.sh
# fleet_popup_bind, dash-popup.sh --hold).
#
#   A  the socket: one name per 看台, the Go connector's (sha1(view)[:16], the same
#      constant agent/panel_test.go holds); a directory not 0700 / not ours is
#      refused; `ensure` with no connector starts nothing
#   B  serve + attach: a 看台 on an isolated tmux, the rows through the producer
#      seam; `attach` (the connector in Python) hands its pty to the server, the
#      forked child draws the first frame from the list in hand — the row is on
#      screen, the run's clock says attach · read=0 · frame, ESC ends it with rc 0;
#      the peer is our own uid
#   C  no server: attach execs the fallback with the keypress's --view / --client
#      and FLEET_PANEL_T0
#   D  the stale mark: fresh ⇒ nothing; 130 s ⇒ 「 · 2 分钟前 · 刷新中…」 (en:
#      「 · 2 min ago · refreshing…」); under the 失联 banner the age alone
#   E  the key: fleet_popup_bind sources into tmux and its popup gets
#      FLEET_PANEL_CTX (session · client · window …) and FLEET_PANEL_DIRECT=1
#   F  dash-popup.sh --hold: @popup_open / @popup_pid while the pid lives, the
#      session's FLEET_PANEL_CTX taken off, all cleared when the pid is gone
#   G  the server goes with its 看台: the view session killed ⇒ it exits, its socket
#      removed
#   H  a release switch: the install link the server was started through moves ⇒
#      it starts again on the new code (same pid, «install moved» logged, answering)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need python3
st_real_tmux
W=$(mktemp -d /tmp/fps.XXXXXX) || exit 2     # short: a unix socket path has ~104 bytes
SOCK="$W/t.sock"
SRV=''
cleanup() {
  "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; [ -z "$SRV" ] || kill "$SRV" 2>/dev/null
  if [ -n "${FLEET_PANEL_KEEP:-}" ]; then echo "kept: $W" >&2; else rm -rf "$W"; fi
}
trap cleanup EXIT INT TERM
mkdir -p "$W/conf" "$W/g" "$W/home" "$W/bin" "$W/ps"
chmod 700 "$W/ps"
st_tmux_socket "$W/bin" "$SOCK"
export PATH="$W/bin:$PATH" HOME="$W/home" FLEET_CONF_DIR="$W/conf" FLEET_STATUS_G="$W/g"
export FLEET_PANEL_SOCK_DIR="$W/ps" FLEET_UI_LANG=zh LANG=en_US.UTF-8 FLEET_PANEL_SERVER_REFRESH=1
unset TMUX TMUX_PANE FLEET_VIEW_LANG FLEET_PANEL_SERVER FLEET_PANEL_CTX
FAIL=0
US=$'\037'
ti() { "$REAL_TMUX" -S "$SOCK" "$@"; }

# --- A ----------------------------------------------------------------------------
python3 - "$BIN" "$W" <<'PY' && st_ok "A one socket per 看台 (the connector's name), a foreign directory refused, no connector ⇒ nothing started" || st_miss "A socket"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("ps", os.path.join(sys.argv[1], "fleet-panel-server.py"))
ps = importlib.util.module_from_spec(spec); spec.loader.exec_module(ps)
assert ps.sock_name("Verkys-Mac-93a1de") == "2931611855070aa3.sock", ps.sock_name("Verkys-Mac-93a1de")
assert ps.sock_name("a") != ps.sock_name("b")
bad = os.path.join(sys.argv[2], "open")
os.mkdir(bad, 0o755); os.chmod(bad, 0o755)
os.environ["FLEET_PANEL_SOCK_DIR"] = bad
assert ps.own_dir(make=False) is None, "a 0755 directory was taken"
os.environ["FLEET_PANEL_CONNECTOR"] = os.path.join(sys.argv[2], "none")
assert ps.ensure("v1") == 1 and not os.listdir(bad), "ensure started a server with no connector"
PY

# --- the 看台 ----------------------------------------------------------------------
ti -f /dev/null new-session -d -s fl -x 120 -y 30 -n orch 'sleep 600' || { echo "FAIL: tmux"; exit 1; }
W1=$(ti new-window -d -P -F '#{window_id}' -t fl -n alpha 'sleep 600')
ti set-option -w -t "$W1" @fleet_id f1
ti new-session -d -t fl -s 'fl@view-v1'
ti select-window -t "=fl@view-v1:$W1"
row() { local IFS="$US"; printf '%s\n' "$*"; }
{
  row hdr verkyyi/claude-fleet '' 'claude-fleet (1)' ' '
  row "$W1" working ⠹ 'alpha' ' ' '' 0 '' '' '#11' — 50% ok 'ALPHAROW 在干活' merged '' '' '' ''
} > "$W/rows.txt"
export FLEET_VIEW_ROWS_CMD="cat '$W/rows.txt'" FLEET_VIEW_ROWS_KEEP=0 FLEET_VIEW_LANDED_CMD=true
printf '#!/bin/sh\n' > "$W/bin/ccquota"; chmod +x "$W/bin/ccquota"
export FLEET_PANEL_CONNECTOR="$W/bin/ccquota"
TMUX="$SOCK,0,0" python3 "$BIN/fleet-panel-server.py" serve --view 'fl@view-v1' </dev/null >"$W/serve.out" 2>&1 &
SRV=$!
for _ in $(seq 1 100); do [ -S "$W/ps/$(python3 "$BIN/fleet-panel-server.py" sock --view fl@view-v1 | xargs basename)" ] && break; sleep 0.1; done
sleep 2      # its first read

# --- B ----------------------------------------------------------------------------
CTX="fl@view-v1|/dev/ttys999|$W1|||||120"
python3 - "$BIN" "$SOCK" "$CTX" "$W" <<'PY' && st_ok "B attach: the forked child draws the first frame from the list in hand (attach · read=0 · frame), ESC ⇒ rc 0" || st_miss "B serve + attach: $(tail -3 "$W/conf/logs/panel-server.log" 2>/dev/null)"
import json, os, pty, select, sys, time, collections
BIN, SOCK, CTX, W = sys.argv[1:5]
env = dict(os.environ, TMUX=SOCK + ",0,0", FLEET_PANEL_CTX=CTX, TERM="xterm-256color")
pid, fd = pty.fork()
if pid == 0:
    os.execvpe(sys.executable, [sys.executable, os.path.join(BIN, "fleet-panel-server.py"), "attach", "--", "false"], env)
import fcntl, struct, termios
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
buf, end = b"", time.time() + 15
while time.time() < end and b"ALPHAROW" not in buf:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            buf += os.read(fd, 65536)
        except OSError:
            break
assert b"ALPHAROW" in buf, buf[-400:]
time.sleep(0.5)
os.write(fd, b"\x1b")
done, status, end = 0, 0, time.time() + 10
while time.time() < end:            # read on: the panel's last writes drain before it exits
    done, status = os.waitpid(pid, os.WNOHANG)
    if done:
        break
    r, _, _ = select.select([fd], [], [], 0.1)
    if r:
        try:
            os.read(fd, 65536)
        except OSError:
            pass
assert done, "the connector did not end"
assert os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0, status
runs = collections.OrderedDict()
for line in open(os.path.join(W, "conf", "timing", "panel.ndjson")):
    d = json.loads(line); runs.setdefault(d["ts"], {})[d["seg"]] = d["ms"]
last = list(runs.values())[-1]
assert "attach" in last and last.get("read") == 0.0 and "frame" in last and "boot" not in last, last
PY

# --- C ----------------------------------------------------------------------------
out=$(FLEET_PANEL_CTX="fl@view-nosrv|/dev/ttys9|@1|||||80" python3 "$BIN/fleet-panel-server.py" attach -- sh -c 'echo "$0 $* T0=${FLEET_PANEL_T0:+set}"' x 2>&1)
[ "$out" = "x --view fl@view-nosrv --client /dev/ttys9 T0=set" ] \
  && st_ok "C no server: the fallback runs with the keypress's --view / --client and FLEET_PANEL_T0" \
  || st_miss "C fallback: $out"

# --- D ----------------------------------------------------------------------------
python3 - "$BIN" <<'PY' && st_ok "D the stale mark: fresh nothing, old 「N 前 · 刷新中…」 (zh / en), the age alone under the banner" || st_miss "D stale mark"
import os, sys, time
sys.path.insert(0, sys.argv[1])
import fleet_view as fv
class R: every = 2
now = time.time()
assert fv.age_mark(now - 1, R(), now=now) == "", fv.age_mark(now - 1, R(), now=now)
got = fv.age_mark(now - 130, R(), now=now)
assert got == " · 2 分钟前 · 刷新中…", got
assert fv.age_mark(now - 130, R(), down=True, now=now) == " · 2 分钟前"
os.environ["FLEET_UI_LANG"] = "en"; fv._WORDS.clear()
got = fv.age_mark(now - 130, R(), now=now)
assert got == " · 2 min ago · refreshing…", got
assert fv.age_mark(0, R()) == ""
PY

# --- E ----------------------------------------------------------------------------
cat > "$W/conn.sh" <<EOF
#!/bin/sh
printf '%s|%s\n' "\$FLEET_PANEL_CTX" "\$FLEET_PANEL_DIRECT" > '$W/ctx.out'
EOF
chmod +x "$W/conn.sh"
bind=$(bash -c '. "$1/fleet-popup-lib.sh"; fleet_popup_bind 100 90% 80% "$2" x' _ "$BIN" "$W/conn.sh")
printf 'bind-key -T root F9 %s\n' "$bind" > "$W/bind.conf"
ti source-file "$W/bind.conf" 2>"$W/bind.err" || st_miss "E the bind did not source: $(cat "$W/bind.err")"
python3 - "$SOCK" "$W" <<'PY' && st_ok "E the key: its popup runs the connector with FLEET_PANEL_CTX + FLEET_PANEL_DIRECT, no shell before it" || st_miss "E bind: $(cat "$W/ctx.out" 2>/dev/null)"
import os, pty, select, sys, time
SOCK, W = sys.argv[1:3]
env = dict(os.environ, TERM="xterm-256color"); env.pop("TMUX", None)
pid, fd = pty.fork()
if pid == 0:
    os.execvpe("tmux", ["tmux", "-S", SOCK, "attach", "-t", "fl@view-v1"], env)
def drain(t):
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try: os.read(fd, 65536)
            except OSError: return
drain(1.0)
os.write(fd, b"\x1b[20~")          # F9
out = os.path.join(W, "ctx.out")
end = time.time() + 5
while time.time() < end and not os.path.exists(out):
    drain(0.1)
got = open(out).read().strip()
f = got.split("|")
assert f[0] == "fl@view-v1" and f[1].startswith("/dev/") and f[2].startswith("@") and f[-1] == "1", got
os.kill(pid, 9)
PY

# --- F ----------------------------------------------------------------------------
ti set-environment -t 'fl@view-v1' FLEET_PANEL_CTX x
sleep 30 & HP=$!
TMUX="$SOCK,0,0" bash "$BIN/dash-popup.sh" --hold "$HP" --session 'fl@view-v1' --title view_title </dev/null >/dev/null 2>&1 &
HOLDER=$!
for _ in $(seq 1 50); do [ "$(ti show -gqv @popup_open)" != "" ] && [ "$(ti show -gqv @popup_open)" != 0 ] && break; sleep 0.1; done
f0=$FAIL
[ "$(ti show -gqv @popup_pid)" = "$(ti show -gqv @popup_open):$HP" ] || st_miss "F @popup_pid is not the panel's: $(ti show -gqv @popup_pid)"
ti show-environment -t 'fl@view-v1' FLEET_PANEL_CTX 2>/dev/null | grep -q '^FLEET_PANEL_CTX=' && st_miss "F the keypress context stayed in the session"
kill "$HP"; wait "$HP" 2>/dev/null
for _ in $(seq 1 50); do kill -0 "$HOLDER" 2>/dev/null || break; sleep 0.1; done
[ "$(ti show -gqv @popup_open)" = 0 ] && [ -z "$(ti show -gqv @popup_pid)" ] || st_miss "F the book outlived the panel: open=$(ti show -gqv @popup_open)"
[ "$FAIL" = "$f0" ] && st_ok "F --hold: @popup_open/@popup_pid while the panel lives, the context taken off, cleared after"

# --- H ----------------------------------------------------------------------------
mkdir -p "$W/rel1" "$W/rel2"
for f in "$BIN"/*; do ln -s "$f" "$W/rel1/"; ln -s "$f" "$W/rel2/"; done
ln -s "$W/rel1" "$W/cur"
ti new-session -d -t fl -s 'fl@view-v2'
FLEET_PANEL_SOCK_DIR="$W/ps" TMUX="$SOCK,0,0" python3 "$W/cur/fleet-panel-server.py" serve --view 'fl@view-v2' </dev/null >/dev/null 2>&1 &
SRV2=$!
sp2="$W/ps/$(python3 "$BIN/fleet-panel-server.py" sock --view fl@view-v2 | xargs basename)"
for _ in $(seq 1 100); do [ -S "$sp2" ] && break; sleep 0.1; done
rm "$W/cur" && ln -s "$W/rel2" "$W/cur"
for _ in $(seq 1 60); do grep -q 'install moved' "$W/conf/logs/panel-server.log" 2>/dev/null && [ -S "$sp2" ] && break; sleep 0.2; done
sleep 1
if grep -Eq "install moved \(.*/rel1 → .*/rel2\)" "$W/conf/logs/panel-server.log" 2>/dev/null && kill -0 "$SRV2" 2>/dev/null \
   && FLEET_PANEL_SOCK_DIR="$W/ps" python3 "$BIN/fleet-panel-server.py" status --view fl@view-v2 >/dev/null; then
  st_ok "H a release switch: the server starts again on the new code (same pid, answering)"
else
  st_miss "H release switch: $(tail -2 "$W/conf/logs/panel-server.log")"
fi
kill "$SRV2" 2>/dev/null; ti kill-session -t 'fl@view-v2' 2>/dev/null

# --- G ----------------------------------------------------------------------------
sp="$W/ps/$(python3 "$BIN/fleet-panel-server.py" sock --view fl@view-v1 | xargs basename)"
ti kill-session -t 'fl@view-v1'
for _ in $(seq 1 80); do [ -e "$sp" ] || break; sleep 0.1; done
for _ in $(seq 1 30); do kill -0 "$SRV" 2>/dev/null || break; sleep 0.1; done
[ ! -e "$sp" ] && ! kill -0 "$SRV" 2>/dev/null \
  && st_ok "G its 看台 gone ⇒ the server exits, its socket removed" || st_miss "G the server outlived its 看台"

[ "$FAIL" = 0 ] && echo "fleet-panel-server-selftest: ALL PASS" || echo "fleet-panel-server-selftest: FAILED"
exit "$FAIL"
