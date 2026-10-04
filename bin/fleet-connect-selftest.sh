#!/bin/bash
# fleet-connect-selftest.sh — the client half of the hub relay (issue #1413):
# bin/fleet-connect.py, reached through the bin/fleet dispatcher, against a
# fake hub (a stdlib python3 WebSocket server on 127.0.0.1). No real hub, sshd
# or network beyond loopback.
#
# Legs: a token rides as a bearer and the stream echoes byte for byte (a 1MB
# binary blob, so frame lengths past 64KB and the client's masking are
# exercised); a hub refusal is printed with its code and exits 1; an HTTP 401
# is printed and exits 1; a certificate challenge is answered with an
# `ssh-keygen -Y sign` signature the hub checks with `ssh-keygen -Y
# check-novalidate`; no hub URL is a usage error (exit 2).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-connect-selftest.XXXXXX") || exit 2
HUB_PID=""
cleanup() {
  if [ -n "$HUB_PID" ]; then kill "$HUB_PID" 2>/dev/null; fi
  rm -rf "${WORK:?}"
}
trap cleanup EXIT INT TERM HUP
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config"
mkdir -p "$HOME/.ssh"
unset FLEET_HUB_URL FLEET_HUB_TOKEN FLEET_CERT
# The fake hub never closes first; do not wait the default 10s for it.
export FLEET_CONNECT_DRAIN_SECS=1

fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

cat > "$WORK/hub.py" <<'EOF'
import base64, hashlib, json, os, socket, struct, subprocess, sys, tempfile, threading, urllib.parse
NS = "fleet-relay@claude-fleet"

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
    data = bytes(x ^ mask[i % 4] for i, x in enumerate(read_exact(c, n, buf)))
    return b0 & 0x0F, data

def send(c, op, data):
    n = len(data)
    h = bytes([0x80 | op])
    h += bytes([n]) if n < 126 else (bytes([126]) + struct.pack("!H", n) if n < 65536 else bytes([127]) + struct.pack("!Q", n))
    c.sendall(h + data)

def serve(c):
    buf = [b""]
    while b"\r\n\r\n" not in buf[0]:
        buf[0] += c.recv(4096)
    head, buf[0] = buf[0].split(b"\r\n\r\n", 1)
    lines = head.decode().split("\r\n")
    path = lines[0].split(" ")[1]
    hdr = {k.lower(): v for k, v in (l.split(": ", 1) for l in lines[1:])}
    node = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query).get("node", [""])[0]
    if node == "deny401":
        c.sendall(b'HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n\r\n{"error":"a session, a viewer token or a connection certificate is required"}')
        return c.close()
    acc = base64.b64encode(hashlib.sha1((hdr["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    c.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % acc).encode())
    auth = hdr.get("authorization", "")
    if node == "refuse":
        send(c, 1, json.dumps({"type": "error", "code": "NOT_FOUND", "message": "no machine \"refuse\" among yours"}).encode())
        return c.close()
    if auth != "Bearer tok-1":
        # No token: prove a certificate.
        send(c, 1, json.dumps({"type": "challenge", "nonce": "nonce-42"}).encode())
        op, data = recv(c, buf)
        m = json.loads(data)
        with tempfile.TemporaryDirectory() as d:
            open(d + "/sig", "w").write(m["sig"])
            r = subprocess.run(["ssh-keygen", "-Y", "check-novalidate", "-n", NS, "-s", d + "/sig"],
                               input=b"nonce-42", capture_output=True)
        if r.returncode != 0 or "-cert-v01@openssh.com" not in m.get("cert", ""):
            send(c, 1, json.dumps({"type": "error", "code": "UNAUTHORIZED", "message": "bad cert"}).encode())
            return c.close()
        open(sys.argv[2], "w").write("cert-ok\n")
    send(c, 1, json.dumps({"type": "ready"}).encode())
    try:
        while True:
            op, data = recv(c, buf)
            if op == 8:
                send(c, 8, data)
                break
            if op == 2:
                send(c, 2, data)
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

python3 "$WORK/hub.py" "$WORK/port" "$WORK/certok" &
HUB_PID=$!
for _ in $(seq 1 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
PORT=$(cat "$WORK/port" 2>/dev/null)
[ -n "$PORT" ] || { echo "FAIL fake hub did not start"; exit 1; }
HUB="http://127.0.0.1:$PORT"

# 1 — token + byte-exact echo of 1MB of binary.
head -c 1048576 /dev/urandom > "$WORK/blob"
FLEET_HUB_TOKEN=tok-1 "$BIN/fleet" connect --hub "$HUB" --proxy echo < "$WORK/blob" > "$WORK/echo" 2>"$WORK/err1"
rc=$?
if [ "$rc" = 0 ] && cmp -s "$WORK/blob" "$WORK/echo"; then ok "token: 1MB echoed byte for byte"
else bad "token leg: rc=$rc, $(wc -c < "$WORK/echo") of 1048576 bytes back; $(cat "$WORK/err1")"; fi

# 2 — a hub refusal is printed with its code and exits 1.
out=$(FLEET_HUB_TOKEN=tok-1 "$BIN/fleet" connect --hub "$HUB" --proxy refuse < /dev/null 2>&1); rc=$?
case "$rc:$out" in
  1:*NOT_FOUND*) ok "refusal: exit 1 with the hub's code" ;;
  *) bad "refusal: rc=$rc out=$out" ;;
esac

# 3 — HTTP 401 before the upgrade.
out=$(FLEET_HUB_TOKEN=tok-1 "$BIN/fleet" connect --hub "$HUB" --proxy deny401 < /dev/null 2>&1); rc=$?
case "$rc:$out" in
  1:*401*certificate*) ok "401: exit 1 with the hub's reason" ;;
  *) bad "401: rc=$rc out=$out" ;;
esac

# 4 — certificate challenge answered with ssh-keygen -Y sign; the hub hands
#     the hub URL over through hub.json this time.
if command -v ssh-keygen >/dev/null 2>&1; then
  ssh-keygen -q -t ed25519 -N '' -f "$WORK/ca" >/dev/null
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/fleet-cert" >/dev/null
  ssh-keygen -q -s "$WORK/ca" -I wx-alice -n alice -V +1h "$HOME/.ssh/fleet-cert.pub" >/dev/null 2>&1
  mkdir -p "$XDG_CONFIG_HOME/claude-fleet"
  printf '{"url": "%s"}\n' "$HUB" > "$XDG_CONFIG_HOME/claude-fleet/hub.json"
  printf 'abc' | "$BIN/fleet" connect --proxy echo > "$WORK/echo4" 2>"$WORK/err4"; rc=$?
  if [ "$rc" = 0 ] && [ "$(cat "$WORK/echo4")" = abc ] && [ -s "$WORK/certok" ]; then ok "certificate: challenge signed and checked, stream up"
  else bad "certificate leg: rc=$rc echo=$(cat "$WORK/echo4") $(cat "$WORK/err4")"; fi
  rm -f "$XDG_CONFIG_HOME/claude-fleet/hub.json"
else
  echo "skip certificate leg: no ssh-keygen"
fi

# 5 — no hub URL anywhere: usage error.
out=$("$BIN/fleet" connect --proxy m4 < /dev/null 2>&1); rc=$?
case "$rc:$out" in
  2:*"no hub URL"*) ok "no hub URL: exit 2" ;;
  *) bad "no hub URL: rc=$rc out=$out" ;;
esac

# 6 — the dispatcher refuses an unknown command.
"$BIN/fleet" nosuch >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "dispatcher: unknown command exits 2" || bad "dispatcher: rc=$rc"

[ "$fail" = 0 ] && echo "PASS fleet-connect-selftest" || echo "FAIL fleet-connect-selftest"
exit "$fail"
