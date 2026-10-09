#!/bin/bash
# fleet-client-where-selftest.sh — where the person is (issue #1716, EPIC #1710
# C6): bin/fleet-client-lease.py's `device` (the where worked out off the ssh
# connection and the terminal), its `where` (the hub read), and the one reader,
# bin/fleet-client-where.sh.
#
# Nothing real is reached: `tailscale` is a fake on PATH answering whois/status
# from files, the terminal is a pty this test answers, the hub is a python HTTP
# server on 127.0.0.1 (killed at the end), and tmux is an isolated socket.
#   A. tailnet    — a tailnet source address → the fake whois' device + system,
#                   via tailnet, caps link, host = this machine
#   B. lan        — a LAN address one tailnet device reports → that device;
#                   one nobody reports → 未知设备 (via lan)
#   C. public     — a public address → 未知设备, via public; no whois asked
#   D. local      — no ssh: via local, caps open_url show_file notify
#   E. terminal   — LC_TERMINAL=iTerm2 (+version) → iTerm2, caps + iterm2;
#                   a terminal answering XTVERSION → its name; nothing → 通用终端
#   F. hub        — fleet-client-where.sh off the hub's lease: the line, --json
#                   fields; a takeover → the next call follows; nobody → exit 3
#   F2. several   — the hub lists two clients (#1932): the line is the primary's
#                   and ends 「也开着：<the other>」; --json carries clients +
#                   primary; the primary moving is followed; one client → the
#                   line byte for byte as before
#   G. node read  — fleet-client-lease.py where asks GET /v1/node/client with
#                   node.env's token (never another credential)
#   G2. refused   — (#2112) the hub answers 401: lease where exits 4 and --json
#                   says hub refused; a hub out of reach stays exit 1, hub down
#   G3. separated — (#2665) node.env unreadable, credsep on: the broker's fcpn1.
#                   token is asked at the BROKER's address, never at the hub
#                   (FLEET_HUB_URL) — the hub has never seen it
#   G4. fallback  — (#2665) the hub refuses the node token: the other credential
#                   (here the hub token) is asked next and answers; --json says
#                   hub up + node_token refused: <the hub's words>, the doctor's
#                   hub_auth_fail gets a client-where line, a clean read drops it
#   G5. both refused — exit 4 only when every credential is refused; --json
#                   carries hub_why (the hub's words)
#   H. local read — no hub: the fleet-shell client attached on this machine
#                   (client.where.json); none attached → exit 3
# python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { printf 'fleet-client-where selftest: python3 absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fcw-st.XXXXXX")" || exit 2
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"   # the doctor's hub_auth_fail lands here, never the live one
export HOME="$WORK/home"; mkdir -p "$HOME/.config/claude-fleet" "$WORK/fakebin"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" FLEET_CONF_DIR="$HOME/.config/claude-fleet"
unset TMUX TMUX_PANE FLEET_HUB_URL CCQUOTA_HUB_URL CCQUOTA_TOKEN FLEET_HUB_TOKEN FLEET_CLIENT_DEVICE SSH_CONNECTION
unset LC_TERMINAL LC_TERMINAL_VERSION TERM_PROGRAM TERM_PROGRAM_VERSION FLEET_NODE_ALIASES FLEET_CLIENT_WHERE_CMD
export FLEET_CLIENT_XTVERSION=0 TERM=xterm-256color
OUT="fcwO$$"; IN="fcwI$$"
HUBPID=''

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 (want '$2')" "$3"; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 (want '$3')" "$2" ;; esac; }
hasnt() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 (must not hold '$3')" "$2" ;; esac; }
cleanup() {
  [ -n "$HUBPID" ] && kill "$HUBPID" 2>/dev/null
  if command -v tmux >/dev/null 2>&1; then
    for s in "$OUT" "$IN"; do tmux -L "$s" kill-server 2>/dev/null; done
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# --- a fake tailscale: whois/status answered from files ------------------------
cat > "$WORK/fakebin/tailscale" <<EOF
#!/bin/bash
echo "\$*" >> "$WORK/ts.log"
case "\$1" in
  whois) f="$WORK/whois-\$3.json"; [ -f "\$f" ] && cat "\$f" || exit 1 ;;
  status) cat "$WORK/status.json" ;;
esac
EOF
chmod +x "$WORK/fakebin/tailscale"
export PATH="$WORK/fakebin:$PATH"
cat > "$WORK/whois-100.101.2.3.json" <<'EOF'
{"Node":{"Name":"verkyyi-iphone.tail435588.ts.net.","ComputedName":"verkyyi-iphone","Hostinfo":{"OS":"iOS","Hostname":"localhost"}}}
EOF
cat > "$WORK/status.json" <<'EOF'
{"Self":{"HostName":"macmini","DNSName":"macmini.tail.ts.net.","OS":"macOS","Addrs":["192.168.1.10:41641"]},
 "Peer":{"k1":{"HostName":"MacBook","DNSName":"macbook.tail.ts.net.","OS":"macOS","Addrs":["192.168.1.20:41641","203.0.113.7:41641"],"CurAddr":""},
         "k2":{"HostName":"ipad","DNSName":"ipad.tail.ts.net.","OS":"iOS","Addrs":["[fe80::5]:41641"]}}}
EOF

dev() { python3 "$BIN/fleet-client-lease.py" device --save "$WORK/w.json" >/dev/null 2>&1; cat "$WORK/w.json" 2>/dev/null; }
field() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print(" ".join(v) if isinstance(v,list) else (v or ""))' "$WORK/w.json" "$1"; }
ME=$(python3 -c 'import platform; print(platform.node().split(".",1)[0])')

# --- A. tailnet --------------------------------------------------------------------
SSH_CONNECTION="100.101.2.3 50000 100.64.0.9 22" dev >/dev/null
eq "A tailnet device" "verkyyi-iphone" "$(field device)"
eq "A tailnet os" "iOS" "$(field os)"
eq "A via" "tailnet" "$(field via)"
eq "A caps" "link" "$(field caps)"
eq "A host = this machine" "$ME" "$(field host)"
SSH_CONNECTION="100.101.2.3 50000 100.64.0.9 22" FLEET_NODE_ALIASES="$ME=m5" dev >/dev/null
eq "A host through FLEET_NODE_ALIASES" "m5" "$(field host)"

# --- B. lan --------------------------------------------------------------------------
SSH_CONNECTION="192.168.1.20 50000 192.168.1.10 22" dev >/dev/null
eq "B lan hit device" "MacBook" "$(field device)"
eq "B lan hit os" "macOS" "$(field os)"
eq "B lan via" "lan" "$(field via)"
SSH_CONNECTION="fe80::5 50000 fe80::1 22" dev >/dev/null
eq "B lan v6 hit" "ipad" "$(field device)"
SSH_CONNECTION="192.168.1.99 50000 192.168.1.10 22" dev >/dev/null
eq "B lan miss → 未知设备" "未知设备" "$(field device)"
eq "B lan miss via" "lan" "$(field via)"

# --- C. public -----------------------------------------------------------------------
: > "$WORK/ts.log"
SSH_CONNECTION="198.51.100.4 50000 192.168.1.10 22022" dev >/dev/null
eq "C public → 未知设备" "未知设备" "$(field device)"
eq "C via public" "public" "$(field via)"
eq "C no tailscale asked" "" "$(cat "$WORK/ts.log")"

# --- D. local ------------------------------------------------------------------------
FLEET_CLIENT_DEVICE=TheMac dev >/dev/null
eq "D local via" "local" "$(field via)"
eq "D local caps" "open_url show_file notify" "$(field caps)"
eq "D FLEET_CLIENT_DEVICE names it" "TheMac" "$(field device)"
hasnt "D local os" "$(field os)" "未知"

# --- E. terminal ---------------------------------------------------------------------
LC_TERMINAL=iTerm2 LC_TERMINAL_VERSION=3.6.1 SSH_CONNECTION="100.101.2.3 1 2 3" dev >/dev/null
eq "E LC_TERMINAL" "iTerm2 3.6.1" "$(field terminal)"
eq "E iterm2 cap" "link iterm2" "$(field caps)"
TERM_PROGRAM=tmux dev >/dev/null
eq "E TERM_PROGRAM=tmux is not a terminal" "通用终端（xterm-256color）" "$(field terminal)"
eq "E nothing → 通用终端" "通用终端（xterm-256color）" "$(dev >/dev/null; field terminal)"
# a pty whose far end answers XTVERSION (and the DA1 after it), as a terminal would
xt=$(FLEET_CLIENT_XTVERSION=1 python3 - "$BIN/fleet-client-lease.py" <<'PY'
import os, pty, subprocess, sys, threading
m, s = pty.openpty()
name = os.ttyname(s)
def answer():
    buf = b""
    while b"\033[c" not in buf:
        buf += os.read(m, 64)
    os.write(m, b"\033P>|WezTerm 20240203\033\\\033[?62;22c")
threading.Thread(target=answer, daemon=True).start()
env = dict(os.environ, FLEET_CLIENT_TTY=name)
print(subprocess.run([sys.executable, sys.argv[1], "device"], env=env, capture_output=True, timeout=10).stdout.decode().strip())
PY
)
eq "E XTVERSION answer → its name" "WezTerm 20240203" "$(printf '%s' "$xt" | cut -f2)"
# a pty nobody answers: the 200 ms bound, then TERM
t0=$(python3 -c 'import time; print(time.time())')
xt=$(FLEET_CLIENT_XTVERSION=1 python3 - "$BIN/fleet-client-lease.py" <<'PY'
import os, pty, subprocess, sys
m, s = pty.openpty()
env = dict(os.environ, FLEET_CLIENT_TTY=os.ttyname(s))
print(subprocess.run([sys.executable, sys.argv[1], "device"], env=env, capture_output=True, timeout=10).stdout.decode().strip())
PY
)
eq "E no XTVERSION answer → 通用终端" "通用终端（xterm-256color）" "$(printf '%s' "$xt" | cut -f2)"
el=$(python3 -c "import time; print(int((time.time()-$t0)*1000))")
CHECKS=$((CHECKS + 1)); [ "$el" -lt 3000 ] || fail "E the silent terminal held the start ${el}ms"

# --- F. the reader, off the hub ------------------------------------------------------
cat > "$WORK/hubread" <<EOF
#!/bin/bash
cat "$WORK/lease.json"
EOF
chmod +x "$WORK/hubread"
export FLEET_CLIENT_WHERE_CMD="$WORK/hubread" FLEET_SHELL_SESSION="$IN" FLEET_SHELL_CACHE="$WORK/shellcache"
cat > "$WORK/lease.json" <<'EOF'
{"state":"active","lease":{"id":"L1","device":"MacBook","os":"macOS","terminal":"iTerm2 3.6","via":"local","host":"MacBook","caps":["open_url","show_file","notify","iterm2"],"since":"2026-10-05T12:00:00Z"}}
EOF
line=$(bash "$BIN/fleet-client-where.sh"); rc=$?
eq "F rc" "0" "$rc"
eq "F line" "MacBook · macOS · iTerm2 3.6 · 能：打开网页、收文件、系统通知、iTerm2" "$line"
j=$(bash "$BIN/fleet-client-where.sh" --json)
jf() { printf '%s' "$j" | python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print(" ".join(v) if isinstance(v,list) else v)' "$1"; }
eq "F json device" "MacBook" "$(jf device)"
eq "F json caps" "open_url show_file notify iterm2" "$(jf caps)"
eq "F json since" "2026-10-05T12:00:00Z" "$(jf since)"
eq "F json via" "local" "$(jf via)"
eq "F json source" "hub" "$(jf source)"
eq "F json hub up" "up" "$(jf hub)"
for k in device os terminal caps since via host; do has "F json has $k" "$j" "\"$k\""; done
# the phone takes over: the very next call follows (nothing cached)
cat > "$WORK/lease.json" <<'EOF'
{"state":"active","lease":{"id":"L2","device":"verkyyi-iphone","os":"iOS","terminal":"Termius","via":"tailnet","host":"m5","caps":["link"],"since":"2026-10-05T12:05:00Z"}}
EOF
eq "F takeover followed" "verkyyi-iphone · iOS · Termius（客户端在 m5 上运行）· 能：给链接" "$(bash "$BIN/fleet-client-where.sh")"
# F2. several clients (#1932): the primary is the lease, the others named
mac='{"id":"L1","device":"MacBook","os":"macOS","terminal":"iTerm2 3.6","via":"local","host":"MacBook","caps":["open_url"]}'
ph='{"id":"L2","device":"verkyyi-iphone","os":"iOS","terminal":"Termius","via":"tailnet","host":"m5","caps":["link"]}'
printf '{"state":"active","lease":%s,"clients":[%s,%s],"primary":"L2"}\n' "$ph" "$ph" "$mac" > "$WORK/lease.json"
eq "F2 iPhone typed last" "verkyyi-iphone · iOS · Termius（客户端在 m5 上运行）· 能：给链接 · 也开着：MacBook" "$(bash "$BIN/fleet-client-where.sh")"
j=$(bash "$BIN/fleet-client-where.sh" --json)
eq "F2 json primary" "L2" "$(jf primary)"
eq "F2 json two clients" "2" "$(printf '%s' "$j" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["clients"]))')"
printf '{"state":"active","lease":%s,"clients":[%s,%s],"primary":"L1"}\n' "$mac" "$mac" "$ph" > "$WORK/lease.json"
eq "F2 MacBook typed last" "MacBook · macOS · iTerm2 3.6 · 能：打开网页 · 也开着：verkyyi-iphone" "$(bash "$BIN/fleet-client-where.sh")"
printf '{"state":"active","lease":%s,"clients":[%s],"primary":"L1"}\n' "$mac" "$mac" > "$WORK/lease.json"
eq "F2 one client: as before" "MacBook · macOS · iTerm2 3.6 · 能：打开网页" "$(bash "$BIN/fleet-client-where.sh")"
printf '{"state":"none","lease":null}\n' > "$WORK/lease.json"
line=$(bash "$BIN/fleet-client-where.sh"); rc=$?
eq "F nobody → exit 3" "3" "$rc"
eq "F nobody line" "此刻没有客户端连着" "$line"

# --- G. the node's read: GET /v1/node/client with node.env's token -----------------
cat > "$WORK/hub.py" <<'PY'
import http.server, json, sys
work = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        open(work + "/hub.log", "a").write("%s %s %s\n" % (self.command, self.path, self.headers.get("Authorization")))
        ok = (self.path, self.headers.get("Authorization")) in (("/v1/node/client", "Bearer NODETOK"),
                                                                 ("/hub/v1/node/client", "Bearer fcpn1.BROKER"))
        self.answer(ok)
    def do_POST(self):
        open(work + "/hub.log", "a").write("%s %s %s\n" % (self.command, self.path, self.headers.get("Authorization")))
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.answer(self.path == "/v1/fleet/client" and self.headers.get("Authorization") == "Bearer CLIENTTOK")
    def answer(self, ok):
        if not ok:
            b = json.dumps({"error": "unrecognised enrollment token"}).encode()
            self.send_response(401); self.send_header("Content-Type", "application/json"); self.end_headers()
            self.wfile.write(b); return
        b = json.dumps({"state": "active", "lease": {"id": "L9", "device": "MacBook", "terminal": "iTerm2", "caps": ["open_url"]}}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(work + "/hub.port.tmp", "w") as f:
    f.write(str(s.server_address[1]))
import os
os.replace(work + "/hub.port.tmp", work + "/hub.port")
s.serve_forever()
PY
python3 "$WORK/hub.py" "$WORK" & HUBPID=$!
n=300; while [ ! -s "$WORK/hub.port" ] && [ "$n" -gt 0 ]; do sleep 0.1; n=$((n - 1)); done
port=$(cat "$WORK/hub.port" 2>/dev/null)
[ -n "$port" ] || fail "G the fake hub never listened"
export NO_PROXY='*' no_proxy='*'   # a runner's proxy must not stand between us and 127.0.0.1
printf 'CCQUOTA_HUB_URL=http://127.0.0.1:%s\nCCQUOTA_TOKEN=NODETOK\n' "$port" > "$FLEET_CONF_DIR/node.env"
w=$(python3 "$BIN/fleet-client-lease.py" where 2>"$WORK/g.err"); rc=$?
eq "G rc" "0" "$rc"
[ "$rc" = 0 ] || printf '      stderr: %s\n' "$(cat "$WORK/g.err")" >&2
has "G the owner's lease" "$w" '"device": "MacBook"'
has "G asked with the node token" "$(cat "$WORK/hub.log" 2>/dev/null)" "GET /v1/node/client Bearer NODETOK"
eq "G through the reader" "MacBook · iTerm2 · 能：打开网页" "$(env -u FLEET_CLIENT_WHERE_CMD bash "$BIN/fleet-client-where.sh")"
# G2 (#2112): the hub is UP and refuses the credential (401) — exit 4, hub
# refused; out of reach (a dead port) stays exit 1, hub down
printf 'CCQUOTA_HUB_URL=http://127.0.0.1:%s\nCCQUOTA_TOKEN=WRONGTOK\n' "$port" > "$FLEET_CONF_DIR/node.env"
python3 "$BIN/fleet-client-lease.py" where >/dev/null 2>&1; rc=$?
eq "G2 401 → exit 4 (refused, not unreachable)" "4" "$rc"
has "G2 --json hub refused" "$(env -u FLEET_CLIENT_WHERE_CMD bash "$BIN/fleet-client-where.sh" --json)" '"hub": "refused"'
printf 'CCQUOTA_HUB_URL=http://127.0.0.1:1\nCCQUOTA_TOKEN=NODETOK\n' > "$FLEET_CONF_DIR/node.env"
python3 "$BIN/fleet-client-lease.py" where >/dev/null 2>&1; rc=$?
eq "G2 out of reach → exit 1" "1" "$rc"
has "G2 --json hub down" "$(env -u FLEET_CLIENT_WHERE_CMD bash "$BIN/fleet-client-where.sh" --json)" '"hub": "down"'
# G3 (#2665): separated — node.env is the role account's (unreadable here), the
# credential proxy hands out a broker URL + fcpn1. token. The pair goes together:
# the broker's token to the broker, never to FLEET_HUB_URL.
SB="$WORK/sbin"; mkdir -p "$SB"
cp "$BIN/fleet-client-lease.py" "$BIN/fleet-connect.py" "$BIN/fleet-client-where.sh" "$SB/"
[ -f "$BIN/fleet-lib.sh" ] && cp "$BIN/fleet-lib.sh" "$SB/"
printf '#!/bin/bash\n[ "$1" = node-token ] && printf "http://127.0.0.1:%s/hub\\tfcpn1.BROKER\\n"\n' "$port" > "$SB/fleet-cred-proxy.sh"
ln -sf "$WORK/nowhere/node.env" "$FLEET_CONF_DIR/node.env"
printf 'CCQUOTA_HUB_URL=http://127.0.0.1:%s\n' "$port" > "$FLEET_CONF_DIR/node.pub.env"
printf '{}\n' > "$FLEET_CONF_DIR/credsep.json"
: > "$WORK/hub.log"
w=$(FLEET_HUB_URL="http://127.0.0.1:$port" python3 "$SB/fleet-client-lease.py" where 2>"$WORK/g3.err"); rc=$?
eq "G3 separated rc" "0" "$rc"
has "G3 separated: the owner's lease" "$w" '"device": "MacBook"'
has "G3 asked the broker with its token" "$(cat "$WORK/hub.log")" "GET /hub/v1/node/client Bearer fcpn1.BROKER"
hasnt "G3 never sent the broker token to the hub" "$(cat "$WORK/hub.log")" "GET /v1/node/client Bearer fcpn1.BROKER"
hasnt "G3 no node_token refusal" "$w" "node_token"
rm -f "$FLEET_CONF_DIR/node.env" "$FLEET_CONF_DIR/node.pub.env" "$FLEET_CONF_DIR/credsep.json"

# G4 (#2665): the hub refuses the node token — the read does not stop there: the
# other credential (the hub token; on a real node the certificate) answers.
HAF="$TMPDIR/.claude-dash/global/hub_auth_fail"
printf 'CCQUOTA_HUB_URL=http://127.0.0.1:%s\nCCQUOTA_TOKEN=WRONGTOK\n' "$port" > "$FLEET_CONF_DIR/node.env"
: > "$WORK/hub.log"
w=$(FLEET_HUB_TOKEN=CLIENTTOK python3 "$BIN/fleet-client-lease.py" where 2>"$WORK/g4.err"); rc=$?
eq "G4 node token refused, the other credential answers → rc 0" "0" "$rc"
has "G4 the owner's lease" "$w" '"device": "MacBook"'
has "G4 says the node token was refused" "$w" '"node_token": "refused: unrecognised enrollment token"'
has "G4 asked with the node token first" "$(cat "$WORK/hub.log")" "GET /v1/node/client Bearer WRONGTOK"
has "G4 then with the hub token" "$(cat "$WORK/hub.log")" "POST /v1/fleet/client Bearer CLIENTTOK"
j=$(FLEET_HUB_TOKEN=CLIENTTOK env -u FLEET_CLIENT_WHERE_CMD bash "$BIN/fleet-client-where.sh" --json)
has "G4 --json hub up" "$j" '"hub": "up"'
has "G4 --json carries the node token's refusal" "$j" '"node_token": "refused: unrecognised enrollment token"'
has "G4 --json the client" "$j" '"device": "MacBook"'
if [ -f "$BIN/fleet-lib.sh" ]; then
  has "G4 the doctor's hubauth file names client-where" "$(cat "$HAF" 2>/dev/null)" "client-where	"
  has "G4 … with the hub's words" "$(cat "$HAF" 2>/dev/null)" "node token: unrecognised enrollment token"
  printf 'CCQUOTA_HUB_URL=http://127.0.0.1:%s\nCCQUOTA_TOKEN=NODETOK\n' "$port" > "$FLEET_CONF_DIR/node.env"
  env -u FLEET_CLIENT_WHERE_CMD bash "$BIN/fleet-client-where.sh" >/dev/null
  hasnt "G4 a clean read drops the line" "$(cat "$HAF" 2>/dev/null)" "client-where"
fi

# G5: every credential refused → exit 4, the hub's words carried
printf 'CCQUOTA_HUB_URL=http://127.0.0.1:%s\nCCQUOTA_TOKEN=WRONGTOK\n' "$port" > "$FLEET_CONF_DIR/node.env"
w=$(FLEET_HUB_TOKEN=BADCLIENT python3 "$BIN/fleet-client-lease.py" where 2>/dev/null); rc=$?
eq "G5 both refused → exit 4" "4" "$rc"
has "G5 the hub's words" "$w" '"why": "unrecognised enrollment token"'
j=$(FLEET_HUB_TOKEN=BADCLIENT env -u FLEET_CLIENT_WHERE_CMD bash "$BIN/fleet-client-where.sh" --json)
has "G5 --json hub refused" "$j" '"hub": "refused"'
has "G5 --json hub_why" "$j" '"hub_why": "unrecognised enrollment token"'

rm -f "$FLEET_CONF_DIR/node.env"
w=$(python3 "$BIN/fleet-client-lease.py" where); rc=$?
eq "G no hub anywhere → nohub" '{"state": "nohub"}' "$w"

# --- H. no hub: the fleet-shell client attached here --------------------------------
printf '{"state":"nohub"}\n' > "$WORK/lease.json"
line=$(bash "$BIN/fleet-client-where.sh"); rc=$?
eq "H no server → exit 3" "3" "$rc"
if command -v tmux >/dev/null 2>&1; then
  mkdir -p "$WORK/shellcache/tmp"
  printf '{"device": "LocalMac", "os": "macOS", "terminal": "iTerm2 3.6", "via": "local", "host": "LocalMac", "caps": ["open_url", "show_file", "notify", "iterm2"]}\n' \
    > "$WORK/shellcache/tmp/client.where.json"
  tmux -L "$IN" -f /dev/null new-session -d -s "$IN" 'sleep 600'
  line=$(bash "$BIN/fleet-client-where.sh"); rc=$?
  eq "H server, no client attached → exit 3" "3" "$rc"
  # a real attached client: a pane of an outer isolated server attached to it
  tmux -L "$OUT" -f /dev/null new-session -d -x 120 -y 30 "env -u TMUX tmux -L $IN attach -t $IN"
  n=50; while [ -z "$(tmux -L "$IN" list-clients 2>/dev/null)" ] && [ "$n" -gt 0 ]; do sleep 0.1; n=$((n - 1)); done
  line=$(bash "$BIN/fleet-client-where.sh"); rc=$?
  eq "H attached → exit 0" "0" "$rc"
  eq "H local line" "LocalMac · macOS · iTerm2 3.6 · 能：打开网页、收文件、系统通知、iTerm2" "$line"
  j=$(bash "$BIN/fleet-client-where.sh" --json)
  eq "H source local" "local" "$(jf source)"
  eq "H no hub → hub nohub" "nohub" "$(jf hub)"
  [ -n "$(jf since)" ] || fail "H since from the file's mtime"
  # a client from before #1716: no where saved — its device + tmux's terminal word
  rm -f "$WORK/shellcache/tmp/client.where.json"
  c=$(tmux -L "$IN" list-clients -F '#{client_name}' | head -n 1)
  mkdir -p "$WORK/shellcache/tmp/client.dev"
  printf 'OldMac\n' > "$WORK/shellcache/tmp/client.dev/$(printf '%s' "$c" | tr -c 'A-Za-z0-9._-' '_')"
  has "H older client: its device" "$(bash "$BIN/fleet-client-where.sh")" "OldMac"
  # the hub out of reach: the same local answer
  printf '#!/bin/bash\nexit 1\n' > "$WORK/hubread"
  has "H hub out of reach → local" "$(bash "$BIN/fleet-client-where.sh")" "OldMac"
  j=$(bash "$BIN/fleet-client-where.sh" --json)
  eq "H hub out of reach → hub down (issue #1779)" "down" "$(jf hub)"
else
  printf 'skip H attached legs: no tmux\n'
fi

if [ "$FAIL" -gt 0 ]; then
  printf 'fleet-client-where selftest: %d of %d checks FAILED\n' "$FAIL" "$CHECKS" >&2
  exit 1
fi
printf 'fleet-client-where selftest: PASS (%d checks)\n' "$CHECKS"
