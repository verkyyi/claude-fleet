#!/bin/bash
# client-log-selftest.sh — the client's own record (issue #2896, EPIC #2889 C7;
# docs/CLIENT-LOGS.md): bin/fleet_clientlog.py and its sh twin fleet_clientlog
# (bin/fleet-client-lib.sh), and the four writers — bin/fleet-connect.py
# (relay + ssh), bin/fleet-client-place.sh, the keeper in bin/fleet-shell.sh,
# bin/fleet-login.py — against a sandbox HOME and a fake hub on 127.0.0.1.
#
# Legs:
#   A  conf/secret-shapes.list keeps to the rules both readers share (no
#      backslash, no {m,n}, no (?…), no [[:class:]]), and every shape has a
#      sample below that it redacts
#   B  python and sh, one corpus: the redaction byte for byte, and a whole
#      line (all but its time) byte for byte
#   C  a fake token in a reason is <redacted:…> on disk, from both writers
#   D  600 KB written → the current file + .1, nothing else, each bounded
#   E  a relay the hub closes after 1 s → relay-end · hub · ws close 1011; one
#      the client closes after 11 s → relay-end · client; the ms say so
#   F  ssh as a child: exit 255 → ssh-start + ssh-end `exit 255`; a SIGTERM to
#      fleet-connect reaches ssh; FLEET_CONNECT_SSH_VERBOSE=1 → -v -E ssh-v.log
#   G  place: the hub's REFUSED with every machine's reason → place.log, and
#      the no-hub, no-fleet answer → place.log (the sh writer)
#   H  login: a renew with no device key → login.log `renew scan` + tls sources
#   I  the keeper's output goes to keeper.out, its renewals to keeper.log
#   J  FLEET_CLIENT_LOG=0 writes nothing
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/client-log-selftest.XXXXXX") || exit 2
HUB_PID=""
cleanup() {
  [ -n "$HUB_PID" ] && kill "$HUB_PID" 2>/dev/null
  rm -rf "${WORK:?}"
}
trap cleanup EXIT INT TERM HUP
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" XDG_CACHE_HOME="$WORK/home/.cache"
mkdir -p "$HOME/.ssh"
unset FLEET_HUB_URL FLEET_HUB_TOKEN FLEET_CLIENT_LOG FLEET_CLIENT_LOG_MAX FLEET_CLIENT_LOG_DIR \
      FLEET_SHELL_CACHE FLEET_SECRET_SHAPES FLEET_CONNECT_SSH_VERBOSE
LOGS="$XDG_CACHE_HOME/claude-fleet/shell/logs"
SHAPES="$ROOT/conf/secret-shapes.list"

fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
# shellcheck source=fleet-client-lib.sh
. "$BIN/fleet-client-lib.sh"

# ── A — the table's rules, and a sample per shape ─────────────────────────────
# <name><TAB><a line that must lose its secret>
cat > "$WORK/samples" <<'EOF'
github	clone with ghp_AbCdEf0123456789abcdef0123456789abcd failed
github_pat	push github_pat_11ABCDEFG0_abcdefghijklmnop refused
anthropic	key sk-ant-api03-Zz9_-xYz was rejected
private_key	-----BEGIN OPENSSH PRIVATE KEY----- b3BlbnNzaC1rZXk= AAAA -----END OPENSSH PRIVATE KEY----- after
authorization	header Authorization: Bearer eyJhbGciOi.payload.sig sent
cookie	Cookie: session=abc123; path=/
bearer	got bearer abc.DEF-123_~+/= back
url_query	GET https://hub.example/v1/x?node=m5&token=SEKRIT123&a=1 failed
env_secret	FLEET_HUB_TOKEN=tok-zzz9 in the environment
json_token	{"url": "https://h", "token": "hub-json-token-77"}
EOF
rules=$(grep -v '^#' "$SHAPES" | grep -n . | awk -F '\t' '$2 ~ /\\/ || $2 ~ /[{]/ || $2 ~ /\(\?/ || $2 ~ /\[\[:/ { print $1 }')
[ -z "$rules" ] && ok "A shapes: no backslash, interval, (?…) or [[:class:]]" || bad "A shapes break the shared rules: $rules"
names=$(grep -v '^#' "$SHAPES" | grep . | cut -f1 | sort)
have=$(cut -f1 "$WORK/samples" | sort)
[ "$names" = "$have" ] && ok "A every shape has a sample (and no sample lacks a shape)" \
  || bad "A shapes vs samples differ: $(diff <(printf '%s\n' "$names") <(printf '%s\n' "$have") | tr '\n' ' ')"
miss=''
while IFS=$'\t' read -r n line; do
  py=$(printf '%s\n' "$line" | python3 "$BIN/fleet_clientlog.py" redact)
  case "$py" in *"<redacted:$n>"*) ;; *) miss="$miss $n(py:$py)" ;; esac
done < "$WORK/samples"
[ -z "$miss" ] && ok "A each sample is redacted by its own shape" || bad "A not redacted by its shape:$miss"

# ── B — python and sh agree, byte for byte ────────────────────────────────────
{
  cut -f2 "$WORK/samples"
  printf '%s\n' 'plain words, 中文原因：连接被中转关闭 (1011)' '' 'a	tab inside' \
    'Authorization: token gho_abc ; and ?sig=x&signature=y' 'PASSWORD=p ; secret=s ; my_passwd=q' \
    '"refresh_token" : "r1" and "password":"p2"' 'nothing here at all'
  python3 -c 'print("长" * 700 + "ghp_" + "x" * 50)'        # past 2000 bytes, a cut mid-character
  python3 -c 'print("a" * 1999 + "中文")'
} > "$WORK/corpus"
python3 "$BIN/fleet_clientlog.py" redact < "$WORK/corpus" > "$WORK/py.out"
: > "$WORK/sh.out"
while IFS= read -r l; do printf '%s' "$l" | fleet_clientlog_redact >> "$WORK/sh.out"; done < "$WORK/corpus"
if cmp -s "$WORK/py.out" "$WORK/sh.out"; then ok "B redaction: python = sh on $(wc -l < "$WORK/corpus" | tr -d ' ') lines"
else bad "B redaction differs:"; diff "$WORK/py.out" "$WORK/sh.out" | head -6; fi
R=$'relay closed\tby hub\nnext line ghp_SECRETSECRET 中文'
python3 "$BIN/fleet_clientlog.py" write connect relay-end m5 relay 1023 hub "$R"
fleet_clientlog connect relay-end m5 relay 1023 hub "$R"
n=$(cut -f2- "$LOGS/connect.log" | sort -u | wc -l | tr -d ' ')
cols=$(awk -F '\t' '{ print NF }' "$LOGS/connect.log" | sort -u | tr '\n' ' ')
ts=$(cut -f1 "$LOGS/connect.log" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')
[ "$n" = 1 ] && [ "$cols" = "7 " ] && [ "$ts" = 2 ] && ok "B a whole line: python = sh (7 fields, UTC time)" \
  || bad "B lines differ: n=$n cols=$cols ts=$ts: $(cat "$LOGS/connect.log")"

# ── C — a fake token never reaches the disk ───────────────────────────────────
grep -q 'ghp_SECRET' "$LOGS/connect.log" && bad "C the token reached connect.log" \
  || { grep -q '<redacted:github>' "$LOGS/connect.log" && ok "C a token in a reason is <redacted:github> on disk (both writers)" \
       || bad "C no redaction mark in connect.log"; }
[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$LOGS/connect.log")" = 600 ] \
  && ok "C the log is 0600" || bad "C connect.log is not 0600"

# ── D — rotation ──────────────────────────────────────────────────────────────
pad=$(python3 -c 'print("x" * 1000)')
for i in $(seq 1 330); do fleet_clientlog keeper renew - - "" ok "$pad"; done
FLEET_CLIENT_LOG_MAX=524288 python3 - "$BIN" "$pad" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cl", sys.argv[1] + "/fleet_clientlog.py")
cl = importlib.util.module_from_spec(spec); spec.loader.exec_module(cl)
for _ in range(330):
    cl.write("keeper", "renew", "-", "-", "", "ok", sys.argv[2])
EOF
files=$(cd "$LOGS" && ls keeper.log* | tr '\n' ' ')
big=$(wc -c < "$LOGS/keeper.log" | tr -d ' '); old=$(wc -c < "$LOGS/keeper.log.1" 2>/dev/null | tr -d ' ')
if [ "$files" = "keeper.log keeper.log.1 " ] && [ "$big" -le 530000 ] && [ "${old:-0}" -le 530000 ]; then
  ok "D 660 KB written → keeper.log ($big B) + keeper.log.1 ($old B), nothing else"
else bad "D rotation: files=$files current=$big old=${old:-none}"; fi

# ── E — a relay's end, and who ended it ───────────────────────────────────────
cat > "$WORK/hub.py" <<'EOF'
import base64, hashlib, json, socket, struct, sys, threading, time, urllib.parse

def read_exact(c, n, buf):
    while len(buf[0]) < n:
        d = c.recv(65536)
        if not d:
            raise EOFError
        buf[0] += d
    out, buf[0] = buf[0][:n], buf[0][n:]
    return out

def recv(c, buf):
    b0, b1 = read_exact(c, 2, buf)
    n = b1 & 0x7F
    if n == 126: n = struct.unpack("!H", read_exact(c, 2, buf))[0]
    elif n == 127: n = struct.unpack("!Q", read_exact(c, 8, buf))[0]
    mask = read_exact(c, 4, buf) if b1 & 0x80 else b"\0\0\0\0"
    return b0 & 0x0F, bytes(x ^ mask[i % 4] for i, x in enumerate(read_exact(c, n, buf)))

def send(c, op, data):
    c.sendall(bytes([0x80 | op, len(data)]) + data)

def place(c, body):
    out = {"state": "failed", "exit": 4,
           "line": "REFUSED NO_CAPACITY\tNo machine can take it: m4: CPU busy 93% over 80%; m5: offline"}
    raw = json.dumps(out).encode()
    c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % len(raw) + raw)
    c.close()

def serve(c):
    buf = [b""]
    while b"\r\n\r\n" not in buf[0]:
        buf[0] += c.recv(4096)
    head, buf[0] = buf[0].split(b"\r\n\r\n", 1)
    lines = head.decode().split("\r\n")
    path = lines[0].split(" ")[1]
    hdr = {k.lower(): v for k, v in (l.split(": ", 1) for l in lines[1:])}
    if path.startswith("/v1/fleet/client/place"):
        return place(c, buf[0])
    node = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query).get("node", [""])[0]
    acc = base64.b64encode(hashlib.sha1((hdr["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    c.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % acc).encode())
    send(c, 1, json.dumps({"type": "ready"}).encode())
    if node == "close1":
        time.sleep(1)
        send(c, 8, struct.pack("!H", 1011) + b"node link lost")
        time.sleep(0.5)
        return c.close()
    try:
        while True:
            op, data = recv(c, buf)
            if op == 8:
                send(c, 8, data)
                break
    except (EOFError, OSError):
        pass
    c.close()

s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(8)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
while True:
    c, _ = s.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
EOF
python3 "$WORK/hub.py" "$WORK/port" &
HUB_PID=$!
for _ in $(seq 1 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
PORT=$(cat "$WORK/port" 2>/dev/null)
[ -n "$PORT" ] || { echo "FAIL fake hub did not start"; exit 1; }
HUB="http://127.0.0.1:$PORT"
rm -f "$LOGS/connect.log"
# the hub closes after 1 s; ssh (stdin) stays open longer
sleep 4 | FLEET_HUB_TOKEN=tok-1 FLEET_CONNECT_DRAIN_SECS=1 python3 "$BIN/fleet-connect.py" --hub "$HUB" --proxy close1 >/dev/null 2>&1
# ssh closes its side after 11 s; the hub never closes first
sleep 11 | FLEET_HUB_TOKEN=tok-1 FLEET_CONNECT_DRAIN_SECS=1 python3 "$BIN/fleet-connect.py" --hub "$HUB" --proxy hold >/dev/null 2>&1
e1=$(awk -F '\t' '$2 == "relay-end" && $3 == "close1"' "$LOGS/connect.log")
e2=$(awk -F '\t' '$2 == "relay-end" && $3 == "hold"' "$LOGS/connect.log")
o=$(awk -F '\t' '$2 == "relay-open" && $6 == "ok"' "$LOGS/connect.log" | wc -l | tr -d ' ')
ms1=$(printf '%s' "$e1" | cut -f5); ms2=$(printf '%s' "$e2" | cut -f5)
case "$e1" in *$'\t'relay$'\t'*$'\t'hub$'\t''ws close 1011: node link lost') r1=1 ;; *) r1='' ;; esac
case "$e2" in *$'\t'relay$'\t'*$'\t'client$'\t''ssh closed the stream (stdin EOF)') r2=1 ;; *) r2='' ;; esac
if [ -n "$r1" ] && [ "${ms1:-0}" -ge 900 ] && [ "${ms1:-0}" -lt 3000 ]; then
  ok "E hub closes at 1 s → relay-end · hub · ws close 1011 · ${ms1} ms"
else bad "E hub-closed relay line wrong: $e1"; fi
if [ -n "$r2" ] && [ "${ms2:-0}" -ge 10500 ] && [ "${ms2:-0}" -lt 14000 ]; then
  ok "E client closes at 11 s → relay-end · client · ${ms2} ms"
else bad "E client-closed relay line wrong: $e2"; fi
[ "$o" = 2 ] && ok "E each relay's handshake → relay-open ok" || bad "E relay-open lines: $o"
FLEET_HUB_TOKEN=tok-1 python3 "$BIN/fleet-connect.py" --hub "http://127.0.0.1:1" --proxy m9 </dev/null >/dev/null 2>&1
awk -F '\t' '$2 == "relay-open" && $3 == "m9" && $6 == "fail" && $7 != ""' "$LOGS/connect.log" | grep -q . \
  && ok "E a relay that cannot open → relay-open fail + why" || bad "E no relay-open fail line: $(tail -n 1 "$LOGS/connect.log")"

# ── F — ssh as a child, its end written down ──────────────────────────────────
cat > "$WORK/runssh.py" <<'EOF'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fc", sys.argv[1] + "/fleet-connect.py")
fc = importlib.util.module_from_spec(spec); spec.loader.exec_module(fc)
route = {"kind": "direct", "name": "lan", "host": "10.0.0.9", "port": 22}
if sys.argv[2] == "cmd":
    print(" ".join(fc.ssh_command({"alias": "m5"}, route, "u1", "")))
    sys.exit(0)
sys.exit(fc.run_logged(sys.argv[3:], "m5", route, "u1"))
EOF
python3 "$WORK/runssh.py" "$BIN" run sh -c 'exit 255'; rc=$?
st=$(awk -F '\t' '$2 == "ssh-start" && $3 == "m5" && $4 == "direct"' "$LOGS/connect.log" | tail -n 1)
en=$(awk -F '\t' '$2 == "ssh-end" && $3 == "m5"' "$LOGS/connect.log" | tail -n 1)
if [ "$rc" = 255 ] && [ -n "$st" ] && [ "$(printf '%s' "$en" | cut -f6)" = "exit 255" ]; then
  ok "F ssh exit 255 → ssh-start + ssh-end · exit 255, and fleet-connect exits 255"
else bad "F ssh lines/rc: rc=$rc start=[$st] end=[$en]"; fi
python3 "$WORK/runssh.py" "$BIN" run sh -c 'trap "exit 7" TERM; sleep 30 & wait' &
p=$!; sleep 1; kill -TERM "$p"; wait "$p"; rc=$?
en=$(awk -F '\t' '$2 == "ssh-end"' "$LOGS/connect.log" | tail -n 1)
case "$en" in *$'\t''exit 7'$'\t'*'this side got signal 15') r=1 ;; *) r='' ;; esac
[ "$rc" = 7 ] && [ -n "$r" ] && ok "F a SIGTERM to fleet-connect reaches ssh; the line says both" \
  || bad "F SIGTERM forwarding: rc=$rc end=[$en]"
c0=$(python3 "$WORK/runssh.py" "$BIN" cmd); c1=$(FLEET_CONNECT_SSH_VERBOSE=1 python3 "$WORK/runssh.py" "$BIN" cmd)
case "$c0" in *' -v '*) bad "F -v without FLEET_CONNECT_SSH_VERBOSE" ;; *)
  case "$c1" in *" -v -E $LOGS/ssh-v.log "*) ok "F FLEET_CONNECT_SSH_VERBOSE=1 → ssh -v -E <logs>/ssh-v.log (off by default)" ;;
               *) bad "F verbose ssh command: $c1" ;; esac ;; esac

# ── G — place ─────────────────────────────────────────────────────────────────
CD="$WORK/client"; mkdir -p "$CD"; printf 'lease-1\n' > "$CD/client.lease"; printf 'k\n' > "$CD/client.key"
FLEET_HUB_URL="$HUB" FLEET_HUB_TOKEN=tok-1 FLEET_CLIENT_DIR="$CD" FLEET_CLIENT_PLACE_WAIT=5 \
  bash "$BIN/fleet-client-place.sh" o/r 42 >/dev/null 2>&1; rc=$?
pl=$(tail -n 1 "$LOGS/place.log" 2>/dev/null)
case "$pl" in *$'\t'issue-42$'\t'auto$'\t'-$'\t'*$'\t''REFUSED 4'$'\t''repo=o/r | No machine can take it: m4: CPU busy 93% over 80%; m5: offline'*) r=1 ;; *) r='' ;; esac
[ "$rc" = 4 ] && [ -n "$r" ] && ok "G the hub's REFUSED, every machine's reason → place.log" \
  || bad "G place.log: rc=$rc line=[$pl]"
FLEET_CONF_DIR="$WORK/noconf" FLEET_CLIENT_DIR="$WORK/none" bash "$BIN/fleet-client-place.sh" o/r scratch >/dev/null 2>&1; rc=$?
pl=$(tail -n 1 "$LOGS/place.log" 2>/dev/null)
case "$pl" in *$'\t'scratch$'\t'auto$'\t'-$'\t'*$'\t''NOHUB 1'$'\t''repo=o/r | 这台电脑没有 fleet，也连不上入口') r=1 ;; *) r='' ;; esac
[ "$rc" = 1 ] && [ -n "$r" ] && ok "G no hub, no fleet → place.log NOHUB (the sh writer)" || bad "G no-hub place line: rc=$rc [$pl]"

# ── H — login ─────────────────────────────────────────────────────────────────
python3 - "$BIN" <<'EOF'
import importlib.util, sys
sys.path.insert(0, sys.argv[1])
spec = importlib.util.spec_from_file_location("fl", sys.argv[1] + "/fleet-login.py")
fl = importlib.util.module_from_spec(spec); spec.loader.exec_module(fl)
sys.exit(0 if fl.renew("https://hub.invalid", quiet=True) == fl.NEEDS_SCAN else 1)
EOF
rc=$?
ll=$(tail -n 1 "$LOGS/login.log" 2>/dev/null)
case "$ll" in *$'\t'renew$'\t''https://hub.invalid'$'\t'-$'\t'*$'\t'scan$'\t''no device key yet'*'tls: '*) r=1 ;; *) r='' ;; esac
[ "$rc" = 0 ] && [ -n "$r" ] && ok "H a renew with no device key → login.log renew · scan · its words · tls sources" \
  || bad "H login.log: rc=$rc [$ll]"

# ── I — the keeper ────────────────────────────────────────────────────────────
n=$(grep -c '>>"$(keeper_out)" 2>&1' "$BIN/fleet-shell.sh")
grep -q 'keeper "$SESS" </dev/null >/dev/null' "$BIN/fleet-shell.sh" && bad "I a keeper still starts into /dev/null" \
  || { [ "$n" -ge 3 ] && ok "I every keeper start writes to keeper.out ($n places)" || bad "I keeper_out used $n times"; }
for w in 'klog start' 'kseen "$what" "$L_STATE"' 'kseen "$what" fail' 'klog stop'; do
  grep -qF "$w" "$BIN/fleet-shell.sh" || bad "I keeper.log writer missing: $w"
done
ok "I keeper.log: start · each changed renewal outcome · stop"

# ── J — off ───────────────────────────────────────────────────────────────────
rm -rf "$LOGS"
FLEET_CLIENT_LOG=0 python3 "$BIN/fleet_clientlog.py" write connect x
FLEET_CLIENT_LOG=0 fleet_clientlog place x
[ ! -e "$LOGS" ] && ok "J FLEET_CLIENT_LOG=0 writes nothing (both writers)" || bad "J something was written: $(ls "$LOGS")"

[ "$fail" = 0 ] && echo "PASS client-log-selftest" || echo "FAIL client-log-selftest"
exit "$fail"
