#!/bin/bash
# fleet-browser-selftest.sh — a remote session's OAuth finishes like a local one
# (issue #3236): bin/fleet-browser.sh, fleet-open.sh --browser, fleet-open-addr.py's
# `cport`, bin/fleet_open_fwd.py, fleet-thin.py's OSC 7502 `open`, the
# fleet-browser plugin and the launchers' BROWSER.
#
#   A  ADDR      `cport` = an authorize URL's loopback redirect_uri port — only with
#                FLEET_OPEN_CALLBACK=1; a non-loopback redirect, no port, no
#                variable → no cport, byte for byte the old payload
#   B  SWITCH    `enabled` reads Claude Code's enabledPlugins (absent / false /
#                true; FLEET_BROWSER overrides); `on` / `off` run `claude plugin
#                install|enable|disable` and say what it does; `hook` writes
#                BROWSER into CLAUDE_ENV_FILE; `<url>` hands fleet-open.sh
#                --browser the URL and logs host + cport, never the URL
#   C  FWD       fleet_open_fwd: free · up · gone (a live server held, a refused
#                port, a far end that accepts and closes at once) · a forward is
#                said + logged on open, closed + said + logged once its server is
#                gone, and at its deadline
#   D  THIN      fleet-thin.py `open` (a fake forward relay, a recording opener):
#                a cport is forwarded AS ITSELF before the page opens, one notice
#                line, forwards.log open → close when the session's callback
#                server stops; a busy port is said and nothing opens; a loopback
#                page gets its forward and opens on it; a plain url just opens;
#                an open with an id answers `fleet-open.sh --ack <id> ok|fail <why>`
#                (issue #3538, FLEET_THIN_ACK_CMD), a bad id none
#   E  ROAD      fleet-open.sh on a thin 看台 (hub active thin): --browser → the
#                7502 `open` with the view's token on its tty and the cport,
#                `unconfirmed` with no receipt; without --browser the 看台 is told
#                too (issue #3538: no longer behind the switch), no cport; a `-via-`
#                看台 is not told directly
#   F  WIRING    the plugin's hook calls fleet-browser.sh hook; both launchers
#                export BROWSER only behind `fleet-browser.sh enabled`
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'selftest: python3 missing — SKIP'; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fbrowser-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'pkill -f "$WORK/bin/relay.py" 2>/dev/null; rm -rf "$WORK"' EXIT
export TMPDIR="$WORK" HOME="$WORK/home"
mkdir -p "$WORK/bin" "$HOME/.claude"
unset FLEET_BROWSER CLAUDE_CONFIG_DIR FLEET_CONF_DIR
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }
TAB=$(printf '\t')
AUTH='https://auth.example.com/authorize?client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A33418%2Fcallback&state=s3cr3t'
cp_of() { python3 -c 'import json,sys; print(json.loads(sys.stdin.read().split("\t")[1]).get("cport","-"))'; }

# ---- A: ADDR -------------------------------------------------------------------
[ "$(FLEET_OPEN_CALLBACK=1 python3 "$BIN/fleet-open-addr.py" "$AUTH" | cp_of)" = 33418 ] \
  && ok 'A cport from a loopback redirect_uri' || bad 'A no cport from a loopback redirect_uri'
[ "$(python3 "$BIN/fleet-open-addr.py" "$AUTH" | cp_of)" = - ] \
  && ok 'A no FLEET_OPEN_CALLBACK → no cport' || bad 'A cport without FLEET_OPEN_CALLBACK'
[ "$(FLEET_OPEN_CALLBACK=1 python3 "$BIN/fleet-open-addr.py" 'https://a.example/x?redirect_uri=https%3A%2F%2Fapp.example%2Fcb' | cp_of)" = - ] \
  && ok 'A a non-loopback redirect → no cport' || bad 'A cport for a non-loopback redirect'
[ "$(FLEET_OPEN_CALLBACK=1 python3 "$BIN/fleet-open-addr.py" 'https://a.example/x?redirect_uri=http%3A%2F%2F127.0.0.1%2Fcb' | cp_of)" = - ] \
  && ok 'A a loopback redirect with no port → no cport' || bad 'A cport for a portless redirect'
[ "$(FLEET_OPEN_CALLBACK=1 python3 "$BIN/fleet-open-addr.py" 'https://a.example/x?redirect_url=http://127.0.0.1:1455/auth/callback' | cp_of)" = 1455 ] \
  && ok 'A redirect_url (127.0.0.1) too' || bad 'A redirect_url not read'

# ---- B: SWITCH -----------------------------------------------------------------
FB="$BIN/fleet-browser.sh"
SET="$HOME/.claude/settings.json"
bash "$FB" enabled && bad 'B no settings.json reads on' || ok 'B no settings.json → off'
echo '{"enabledPlugins":{"fleet-browser@claude-fleet":false}}' > "$SET"
bash "$FB" enabled && bad 'B disabled reads on' || ok 'B enabledPlugins false → off'
echo '{"enabledPlugins":{"fleet-browser@claude-fleet":true}}' > "$SET"
bash "$FB" enabled && ok 'B enabledPlugins true → on' || bad 'B enabled plugin reads off'
FLEET_BROWSER=0 bash "$FB" enabled && bad 'B FLEET_BROWSER=0 ignored' || ok 'B FLEET_BROWSER=0 → off'
rm -f "$SET"

cat > "$WORK/bin/fakeclaude" <<EOF
#!/bin/bash
echo "\$*" >> "$WORK/claude.calls"
S="$SET"
case "\$1 \$2" in
  "plugin install"|"plugin enable") echo '{"enabledPlugins":{"fleet-browser@claude-fleet":true}}' > "\$S" ;;
  "plugin disable") echo '{"enabledPlugins":{"fleet-browser@claude-fleet":false}}' > "\$S" ;;
esac
EOF
chmod +x "$WORK/bin/fakeclaude"
out=$(FLEET_BROWSER_CLAUDE="$WORK/bin/fakeclaude" bash "$FB" on 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'plugin install fleet-browser@claude-fleet' "$WORK/claude.calls" && bash "$FB" enabled \
  && ok 'B on → claude plugin install/enable, enabled' || bad "B on (rc=$rc): $out"
case "$out" in *'在你的电脑上打开'*'用完即关'*) ok 'B on says what it does' ;; *) bad "B on says nothing: $out" ;; esac
out=$(FLEET_BROWSER_CLAUDE="$WORK/bin/fakeclaude" bash "$FB" off 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'plugin disable fleet-browser@claude-fleet' "$WORK/claude.calls" && ! bash "$FB" enabled \
  && ok 'B off → claude plugin disable, off' || bad "B off (rc=$rc): $out"
: > "$WORK/env.file"
CLAUDE_ENV_FILE="$WORK/env.file" bash "$FB" hook
grep -q "^export BROWSER=.*fleet-browser.sh" "$WORK/env.file" && ok 'B hook → BROWSER in CLAUDE_ENV_FILE' \
  || bad "B hook wrote: $(cat "$WORK/env.file")"
(unset CLAUDE_ENV_FILE; bash "$FB" hook) && ok 'B hook without CLAUDE_ENV_FILE exits 0' || bad 'B hook failed with no env file'

cat > "$WORK/bin/fakeopen" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$WORK/open.argv"
echo sent:client
EOF
chmod +x "$WORK/bin/fakeopen"
FLEET_BROWSER_OPEN="$WORK/bin/fakeopen" bash "$FB" "$AUTH"; rc=$?
[ "$rc" = 0 ] && [ "$(sed -n 1p "$WORK/open.argv")" = --browser ] && [ "$(sed -n 3p "$WORK/open.argv")" = "$AUTH" ] \
  && ok 'B <url> → fleet-open.sh --browser -- <url>' || bad "B <url> rc=$rc argv: $(tr '\n' ' ' < "$WORK/open.argv")"
BL="$HOME/.config/claude-fleet/logs/browser.log"
if grep -q "sent:client${TAB}auth.example.com${TAB}33418" "$BL" 2>/dev/null && ! grep -q 's3cr3t' "$BL"; then
  ok 'B browser.log: result · host · cport, never the URL'
else bad "B browser.log: $(cat "$BL" 2>/dev/null)"; fi

# ---- C: FWD --------------------------------------------------------------------
out=$(python3 - "$BIN" "$WORK" <<'PY' 2>&1
import importlib.util, os, socket, sys, threading, time
spec = importlib.util.spec_from_file_location("f", os.path.join(sys.argv[1], "fleet_open_fwd.py"))
f = importlib.util.module_from_spec(spec); spec.loader.exec_module(f)
bad = []
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0)); srv.listen(8); port = srv.getsockname()[1]
held = []
def serve():
    while True:
        try:
            c, _ = srv.accept()
        except OSError:
            return
        held.append(c)          # a live server: holds the idle connection
threading.Thread(target=serve, daemon=True).start()
if f.free(port): bad.append("free: a listened port reads free")
if not f.up(port, 2): bad.append("up: a listening port not up")
if f.gone(port): bad.append("gone: a live server reads gone")
q = f.any_port()
if not f.gone(q): bad.append("gone: a refused port reads alive")
# a far end that is no more: accepted, closed at once (what ssh does)
k = socket.socket(); k.bind(("127.0.0.1", 0)); k.listen(4); kp = k.getsockname()[1]
def closer():
    while True:
        try:
            c, _ = k.accept(); c.close()
        except OSError:
            return
threading.Thread(target=closer, daemon=True).start()
if not f.gone(kp): bad.append("gone: accept-and-close reads alive")
said, closed = [], []
fw = f.Forwards(os.path.join(sys.argv[2], "fwd.log"), say=said.append)
f.GRACE, f.EVERY = 0, 0
fw.add(port, "macmini", "issue-1", lambda: closed.append(port), callback=True)
if not said or "localhost:%d" % port not in said[0] or "issue-1" not in said[0] or "10 分钟" not in said[0]:
    bad.append("notice: %r" % said)
fw.tick()
if closed: bad.append("tick closed a live forward")
try:
    srv.shutdown(socket.SHUT_RDWR)
except OSError:
    pass
srv.close()
for c in held: c.close()
time.sleep(0.2)
fw.tick()
if closed != [port]: bad.append("tick did not close a forward whose server is gone: %r" % closed)
if not said or "已关闭" not in said[-1] or "回调完成" not in said[-1]: bad.append("close line: %r" % said)
fw.add(kp, "macmini", "issue-2", lambda: closed.append(kp), callback=True, ttl=0.01)
time.sleep(0.05); fw.tick()
if closed[-1] != kp or "到时" not in said[-1]: bad.append("deadline: %r %r" % (closed, said[-1]))
log = open(os.path.join(sys.argv[2], "fwd.log")).read().splitlines()
ev = [l.split("\t")[1] for l in log]
if ev != ["open", "close", "open", "close"]: bad.append("log events %r" % ev)
print("\n".join(bad) if bad else "ok")
PY
)
[ "$out" = ok ] && ok 'C free · up · gone · notice · close on gone · close at deadline · log' || bad "C $out"

# ---- D: THIN -------------------------------------------------------------------
cat > "$WORK/bin/relay.py" <<'PY'
# a fake `ssh -N -L lport:127.0.0.1:rport`: relay 127.0.0.1:lport → 127.0.0.1:rport;
# a refused far end closes the accepted connection at once (ssh's behaviour)
import socket, sys, threading
lp, rp = int(sys.argv[1]), int(sys.argv[2])
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", lp)); s.listen(8)
def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d: break
            b.sendall(d)
    except OSError:
        pass
    for x in (a, b):
        try: x.close()
        except OSError: pass
while True:
    c, _ = s.accept()
    try:
        r = socket.create_connection(("127.0.0.1", rp), timeout=2)
    except OSError:
        c.close(); continue
    threading.Thread(target=pipe, args=(c, r), daemon=True).start()
    threading.Thread(target=pipe, args=(r, c), daemon=True).start()
PY
cat > "$WORK/bin/opener" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$WORK/opened"
EOF
chmod +x "$WORK/bin/opener"
out=$(FLEET_THIN_FWD_CMD="python3 $WORK/bin/relay.py" FLEET_THIN_OPEN_CMD="$WORK/bin/opener" \
      FLEET_THIN_LOG="$WORK/thinlog/thin.log" python3 - "$BIN" "$WORK" <<'PY' 2>&1
import base64, importlib.util, json, os, socket, sys, threading, time
spec = importlib.util.spec_from_file_location("thin", os.path.join(sys.argv[1], "fleet-thin.py"))
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
work = sys.argv[2]
bad = []
th = t.Thin.__new__(t.Thin)
th.home, th.base, th.fwd, th.said = "macmini", {"argv": ["ssh", "macmini"], "host": 1}, None, []
th.said_lock = threading.Lock()
fw = th.forwards()
fw.mod.GRACE, fw.mod.EVERY = 0, 0
def j(d):
    return {"j": base64.b64encode(json.dumps(d).encode()).decode(), "token": "x"}
def opened():
    try:
        return open(os.path.join(work, "opened")).read().splitlines()
    except OSError:
        return []
# the session's callback server, on the "home" (here)
far = socket.socket(); far.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
far.bind(("127.0.0.1", 0)); far.listen(8); rport = far.getsockname()[1]
# cport == the far port: in a real setup they are two machines; here the relay
# listens on cport and the far server on rport — so forward(cport, cport) must be
# told where the far end is: the seam maps cport to rport through a fixed table
cport = fw.mod.any_port()
os.environ["FLEET_THIN_FWD_CMD"] = "python3 %s/bin/relay.py" % work
orig = th.forward
th.forward = lambda lp, rp: orig(lp, rport if rp == cport else rp)
held = []
def keep():
    while True:
        try:
            held.append(far.accept()[0])
        except OSError:
            return
threading.Thread(target=keep, daemon=True).start()
url = "https://auth.example.com/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A" + str(cport) + "%2Fcallback"
th.open_req(j({"v": 1, "kind": "url", "url": url, "cport": cport, "who": "issue-3236", "ttl": 600}))
if opened() != [url]: bad.append("cport: page not opened: %r" % opened())
if not fw.held(cport): bad.append("cport: no forward held")
try:
    socket.create_connection(("127.0.0.1", cport), timeout=2).close()
except OSError as e:
    bad.append("cport: localhost:%d does not reach the session (%s)" % (cport, e))
if not th.said or "localhost:%d" % cport not in th.said[0] or "issue-3236" not in th.said[0]:
    bad.append("cport: notice %r" % th.said)
try:
    far.shutdown(socket.SHUT_RDWR)
except OSError:
    pass
far.close()
for c in held: c.close()
time.sleep(0.3)
fw.tick()
if fw.held(cport): bad.append("cport: forward still held after the callback server stopped")
time.sleep(0.3)
if not fw.mod.free(cport): bad.append("cport: port %d still bound after close" % cport)
log = open(os.path.join(work, "thinlog", "forwards.log")).read()
if "\topen\t%d\tmacmini\tissue-3236\t" % cport not in log or "\tclose\t%d\t" % cport not in log:
    bad.append("cport: forwards.log %r" % log)
# busy here → said, nothing opened
busy = socket.socket(); busy.bind(("127.0.0.1", 0)); busy.listen(1); bp = busy.getsockname()[1]
n = len(opened())
th.said = []
th.open_req(j({"v": 1, "kind": "url", "url": url, "cport": bp, "who": "w"}))
if len(opened()) != n: bad.append("busy: page opened anyway")
if not th.said or "被占用" not in th.said[-1]: bad.append("busy: not said %r" % th.said)
busy.close()
# a loopback page (rport): forwarded, opened on the local port
pg = socket.socket(); pg.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
pg.bind(("127.0.0.1", 0)); pg.listen(4); pp = pg.getsockname()[1]
th.forward = orig
th.open_req(j({"v": 1, "kind": "forward", "rport": pp, "path": "/d/x/", "scheme": "http", "who": "w"}))
last = opened()[-1] if opened() else ""
if not last.startswith("http://127.0.0.1:") or not last.endswith("/d/x/"): bad.append("page: opened %r" % last)
pg.close()
# a plain url: just opened, no forward
th.open_req(j({"v": 1, "kind": "url", "url": "https://example.com/", "who": "w"}))
if opened()[-1] != "https://example.com/": bad.append("url: %r" % opened()[-1])
# the receipt (issue #3538): an open with an id answers `--ack <id> ok|fail <why>`
acks = os.path.join(work, "acks")
os.environ["FLEET_THIN_ACK_CMD"] = "sh -c 'printf \"%%s|\" \"$@\" >> %s; echo >> %s' ack" % (acks, acks)
th.open_req(j({"v": 1, "kind": "url", "url": "https://example.com/r", "who": "w", "id": "abc123"}))
busy = socket.socket(); busy.bind(("127.0.0.1", 0)); busy.listen(1); bp = busy.getsockname()[1]
th.open_req(j({"v": 1, "kind": "url", "url": url, "cport": bp, "who": "w", "id": "def456"}))
busy.close()
th.open_req(j({"v": 1, "kind": "url", "url": "https://example.com/n", "who": "w", "id": "not hex"}))
got = open(acks).read().splitlines() if os.path.exists(acks) else []
if got[:1] != ["--ack|abc123|ok||"]: bad.append("ack ok: %r" % got)
if len(got) < 2 or not got[1].startswith("--ack|def456|fail|local port %d is busy" % bp): bad.append("ack fail: %r" % got)
if len(got) != 2: bad.append("ack: a bad id was answered: %r" % got)
th.fwd.close_all()
print("\n".join(bad) if bad else "ok")
PY
)
[ "$out" = ok ] && ok 'D thin open: cport forwarded as itself, said, logged, closed when the server stops · busy said · page · url · receipt ok/fail' \
  || bad "D $out"
pkill -f "$WORK/bin/relay.py" 2>/dev/null

# ---- E: ROAD -------------------------------------------------------------------
STATE="$WORK/state"; mkdir -p "$STATE"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/bash
case "\$1" in
  display-message) echo fleet-x ;;
  list-clients) cat "$STATE/clients" ;;
esac
EOF
cat > "$WORK/bin/where" <<'EOF'
#!/bin/sh
echo '{"source":"hub","state":"active","via":"thin"}'
EOF
cat > "$WORK/bin/open-url" <<EOF
#!/bin/sh
echo fallback:copied
EOF
chmod +x "$WORK/bin/tmux" "$WORK/bin/where" "$WORK/bin/open-url"
RV="$HOME/.config/claude-fleet/remote-views"; mkdir -p "$RV"
dev=$(printf '{"device":"MacBook"}' | base64 | tr -d '\n')
printf '/dev/ttys901\tfleet-x\tthin\t1\t1\tcur=x\troute=lan\tdevice=%s\ttoken=tok123\tfuid=u\tnode=macmini\n' "$dev" > "$RV/v1"
printf '/dev/ttys902\tfleet-x\tthin\t1\t1\tcur=x\troute=lan\tdevice=%s\ttoken=tokvia\tfuid=u\tnode=m4\n' "$dev" > "$RV/v2-via-m4"
printf '100\t/dev/ttys901\n' > "$STATE/clients"
road() {  # [--browser] — fleet-open.sh on the thin road
  PATH="$WORK/bin:$PATH" TMUX="/x/sock,1,0" TMUX_PANE="%1" FLEET_OPEN_WHERE_CMD="$WORK/bin/where" \
    FLEET_OPEN_URL_BIN="$WORK/bin/open-url" FLEET_THIN_OPEN_OUT="$WORK/thin.out" FLEET_SHOW_OUT="$WORK/show.out" \
    FLEET_OPEN_SECRET_FILE="$WORK/open.secret" FLEET_OPEN_DOCPREV_ROOT="$WORK/none" FLEET_OPEN_ACK_WAIT=1 \
    bash "$BIN/fleet-open.sh" "$@" 2>"$WORK/road.err"
}
rm -f "$WORK/thin.out"
res=$(FLEET_BROWSER=0 road --browser "$AUTH")
v=$(python3 - "$WORK/thin.out" <<'PY'
import base64, json, re, sys
b = open(sys.argv[1], "rb").read().decode()
m = re.fullmatch(r"\x1b\]7502;open;token=([^;]+);j=([A-Za-z0-9+/=]+)\x07", b)
if not m:
    print("bytes %r" % b[:80]); sys.exit()
d = json.loads(base64.b64decode(m.group(2)))
print("ok" if m.group(1) == "tok123" and d.get("cport") == 33418 and d.get("who") == "fleet-x" and d.get("ttl") == 600 else "payload %r" % d)
PY
)
[ "$res" = unconfirmed ] && [ "$v" = ok ] && ok 'E --browser on a thin 看台 → 7502 open with its token, unconfirmed without a receipt' \
  || bad "E browser road: $res / $v / $(cat "$WORK/road.err")"
grep -q 'MacBook' "$WORK/road.err" && ok 'E the device is named' || bad "E device: $(cat "$WORK/road.err")"
rm -f "$WORK/thin.out"
res=$(FLEET_BROWSER=0 road "$AUTH")
python3 - "$WORK/thin.out" <<'PY' && ok 'E off → the 看台 is told too (#3538), no cport' || bad "E off ($res)"
import base64, json, re, sys
m = re.fullmatch(r"\x1b\]7502;open;token=tok123;j=([A-Za-z0-9+/=]+)\x07", open(sys.argv[1], "rb").read().decode())
sys.exit(0 if m and "cport" not in json.loads(base64.b64decode(m.group(1))) else 1)
PY
printf '100\t/dev/ttys902\n' > "$STATE/clients"
rm -f "$WORK/thin.out"
res=$(FLEET_BROWSER=0 road --browser "$AUTH")
[ ! -e "$WORK/thin.out" ] && ok 'E a -via- 看台 is not told directly' || bad "E -via- got the 7502 ($res)"

# ---- F: WIRING -----------------------------------------------------------------
grep -q 'fleet-browser.sh\\" hook' "$ROOT/plugins/fleet-browser/hooks/hooks.json" \
  && ok 'F the plugin SessionStart hook runs fleet-browser.sh hook' || bad 'F plugin hook'
for l in fleet-claude.sh fleet-codex.sh; do
  grep -q 'if bash "$BIN/fleet-browser.sh" enabled 2>/dev/null; then export BROWSER="$BIN/fleet-browser.sh"; fi' "$BIN/$l" \
    && ok "F $l exports BROWSER only when enabled" || bad "F $l BROWSER wiring"
done

[ "$fail" = 0 ] && echo 'fleet-browser-selftest: all green' || echo 'fleet-browser-selftest: FAILED'
exit "$fail"
