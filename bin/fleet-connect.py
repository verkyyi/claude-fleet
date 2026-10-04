#!/usr/bin/env python3
"""fleet connect --proxy <machine> — reach a machine's sshd through the hub.

When the direct routes fail (the home LAN is out of reach, the tailnet is down,
the gateway port is closed), the hub is still reachable, and every machine
already holds a link open to it. This is the client half of the relay
(claude-fleet#1413): it opens a WebSocket to the hub's relay endpoint and
copies bytes between it and stdin/stdout, so ssh can use it as a
ProxyCommand:

    ssh -o ProxyCommand='fleet connect --proxy m4' m4
    # or in ~/.ssh/config:
    #   Host m4-relay
    #     HostName m4
    #     ProxyCommand fleet connect --proxy m4

SSH runs end to end inside the stream: the hub only moves ciphertext, and the
machine's sshd still decides who logs in.

The hub admits a relay on one of (first that is present):
  FLEET_HUB_TOKEN / hub.json "token"   a viewer token (the operator) or a
                                       WeCom session token
  ~/.ssh/fleet-cert + -cert.pub        the connection certificate `fleet
                                       login` fetches (proven by signing the
                                       hub's challenge with ssh-keygen -Y sign)

The hub's URL: --hub, else FLEET_HUB_URL, else "url" in
~/.config/claude-fleet/hub.json.

Exit: 0 the stream ended; 1 the hub refused (the reason is on stderr);
2 usage / configuration.

Standard library only: this runs on a colleague's laptop, where nothing of the
fleet is installed but this file.
"""
import base64
import json
import os
import socket
import ssl
import struct
import subprocess
import sys
import threading
import urllib.parse

RELAY_PATH = "/v1/ssh-relay/connect"
SIG_NAMESPACE = "fleet-relay@claude-fleet"
CHUNK = 32 * 1024


def die(msg, code=2):
    sys.stderr.write("fleet connect: " + msg + "\n")
    sys.exit(code)


def config_dir():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "claude-fleet")


def load_hub_conf():
    path = os.path.join(config_dir(), "hub.json")
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as e:
        die("cannot read %s: %s" % (path, e))


def cert_paths():
    key = os.environ.get("FLEET_CERT") or os.path.join(os.path.expanduser("~"), ".ssh", "fleet-cert")
    return key, key + "-cert.pub"


class WS:
    """A minimal RFC 6455 client: one connection, binary + text frames."""

    def __init__(self, url, headers, timeout=20):
        u = urllib.parse.urlsplit(url)
        if u.scheme not in ("http", "https", "ws", "wss"):
            die("the hub URL must be http(s)://…, not %r" % url)
        secure = u.scheme in ("https", "wss")
        port = u.port or (443 if secure else 80)
        raw = socket.create_connection((u.hostname, port), timeout=timeout)
        if secure:
            ctx = ssl.create_default_context()
            raw = ctx.wrap_socket(raw, server_hostname=u.hostname)
        self.sock = raw
        self.wlock = threading.Lock()
        self.buf = b""
        key = base64.b64encode(os.urandom(16)).decode()
        target = (u.path or "/") + ("?" + u.query if u.query else "")
        host = u.hostname + ("" if u.port is None else ":%d" % u.port)
        lines = ["GET %s HTTP/1.1" % target, "Host: " + host, "Upgrade: websocket",
                 "Connection: Upgrade", "Sec-WebSocket-Key: " + key, "Sec-WebSocket-Version: 13"]
        lines += ["%s: %s" % kv for kv in headers.items()]
        self.sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        head = self._read_until(b"\r\n\r\n")
        status = head.split(b"\r\n", 1)[0].decode(errors="replace")
        parts = status.split(" ", 2)
        if len(parts) < 2 or parts[1] != "101":
            body = self.buf[:500].decode(errors="replace").strip()
            try:
                body = json.loads(body).get("error", body)
            except ValueError:
                pass
            die("hub refused the connection: %s%s" % (" ".join(parts[1:]), (" — " + body) if body else ""), 1)
        self.sock.settimeout(None)

    def _read_until(self, marker):
        while marker not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                die("hub closed the connection during the handshake", 1)
            self.buf += chunk
        head, self.buf = self.buf.split(marker, 1)
        return head

    def _read_exact(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(max(65536, n - len(self.buf)))
            if not chunk:
                raise EOFError
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send(self, opcode, payload):
        n = len(payload)
        head = bytes([0x80 | opcode])
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 65536:
            head += bytes([0x80 | 126]) + struct.pack("!H", n)
        else:
            head += bytes([0x80 | 127]) + struct.pack("!Q", n)
        mask = os.urandom(4)
        # XOR the mask in one big-int pass: a per-byte loop costs a core at
        # scp speed.
        reps = (mask * (n // 4 + 1))[:n]
        body = (int.from_bytes(payload, "big") ^ int.from_bytes(reps, "big")).to_bytes(n, "big") if n else b""
        with self.wlock:
            self.sock.sendall(head + mask + body)

    def recv(self):
        """One whole message: (opcode, payload). Answers pings itself."""
        msg, first = b"", None
        while True:
            b0, b1 = self._read_exact(2)
            fin, op, n = b0 & 0x80, b0 & 0x0F, b1 & 0x7F
            if n == 126:
                n = struct.unpack("!H", self._read_exact(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", self._read_exact(8))[0]
            mask = self._read_exact(4) if b1 & 0x80 else None
            data = self._read_exact(n)
            if mask:
                reps = (mask * (n // 4 + 1))[:n]
                data = (int.from_bytes(data, "big") ^ int.from_bytes(reps, "big")).to_bytes(n, "big") if n else b""
            if op == 0x9:
                self.send(0xA, data)
                continue
            if op == 0xA:
                continue
            if op == 0x8:
                return op, data
            if op != 0:
                first = op
            msg += data
            if fin:
                return first, msg

    def close(self, code=1000):
        try:
            self.send(0x8, struct.pack("!H", code))
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


def sign_nonce(nonce):
    key, cert = cert_paths()
    if not (os.path.exists(key) and os.path.exists(cert)):
        die("the hub asked for a connection certificate and there is none at %s — run `fleet login`, "
            "or set FLEET_HUB_TOKEN" % cert, 1)
    try:
        sig = subprocess.run(["ssh-keygen", "-Y", "sign", "-f", key, "-n", SIG_NAMESPACE],
                             input=nonce.encode(), capture_output=True, check=True).stdout.decode()
    except FileNotFoundError:
        die("ssh-keygen is not installed", 1)
    except subprocess.CalledProcessError as e:
        die("ssh-keygen -Y sign failed: %s" % e.stderr.decode(errors="replace").strip(), 1)
    with open(cert) as f:
        return {"type": "auth", "cert": f.read().strip(), "sig": sig}


def proxy(node, hub, token):
    q = urllib.parse.urlencode({"node": node})
    headers = {"Authorization": "Bearer " + token} if token else {}
    ws = WS(hub.rstrip("/") + RELAY_PATH + "?" + q, headers)

    # The handshake: JSON text frames until "ready".
    while True:
        try:
            op, data = ws.recv()
        except EOFError:
            die("hub closed the relay before it was ready", 1)
        if op == 0x8:
            reason = data[2:].decode(errors="replace") if len(data) > 2 else ""
            die("hub closed the relay before it was ready" + (": " + reason if reason else ""), 1)
        if op != 0x1:
            die("hub sent stream bytes before the relay was ready", 1)
        m = json.loads(data)
        t = m.get("type")
        if t == "challenge":
            ws.send(0x1, json.dumps(sign_nonce(m.get("nonce", ""))).encode())
        elif t == "ready":
            break
        elif t == "error":
            die("%s: %s" % (m.get("code", "ERROR"), m.get("message", "")), 1)
        else:
            die("unexpected handshake message %r" % t, 1)

    out = sys.stdout.buffer
    done = threading.Event()

    def down():
        try:
            while True:
                op, data = ws.recv()
                if op == 0x8:
                    break
                if op == 0x2 and data:
                    out.write(data)
                    out.flush()
        except (EOFError, OSError):
            pass
        done.set()

    threading.Thread(target=down, daemon=True).start()
    try:
        while not done.is_set():
            chunk = os.read(0, CHUNK)
            if not chunk:
                break
            ws.send(0x2, chunk)
    except OSError:
        pass
    # stdin ended (ssh is done writing): give the far side's last bytes a
    # moment rather than cutting them off. FLEET_CONNECT_DRAIN_SECS for tests.
    done.wait(timeout=float(os.environ.get("FLEET_CONNECT_DRAIN_SECS") or 10))
    ws.close()
    return 0


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="fleet connect", description=__doc__.split("\n\n")[0])
    ap.add_argument("--proxy", metavar="MACHINE", required=True,
                    help="relay stdin/stdout to MACHINE's sshd through the hub (for ssh's ProxyCommand)")
    ap.add_argument("--hub", help="the hub's URL (default: FLEET_HUB_URL, then hub.json)")
    a = ap.parse_args(argv)
    conf = load_hub_conf()
    hub = a.hub or os.environ.get("FLEET_HUB_URL") or conf.get("url")
    if not hub:
        die("no hub URL: pass --hub, set FLEET_HUB_URL, or put {\"url\": …} in %s"
            % os.path.join(config_dir(), "hub.json"))
    token = os.environ.get("FLEET_HUB_TOKEN") or conf.get("token") or ""
    return proxy(a.proxy, hub, token)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
