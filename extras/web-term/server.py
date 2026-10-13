#!/usr/bin/env python3
"""web-term C1 (issue #3837, EPIC #3836): a phone-first web terminal, prototype.

One page (ui/) + one WebSocket bridged to a PTY that runs the command after
`--` (default: `tmux -u -L webterm new-session -A -s main`, its own socket, so a
reconnect lands back where it was and no fleet's server is touched).

  python3 extras/web-term/server.py [--port 8377] [--cwd DIR] [-- cmd ...]

Rails (same as extras/web-chat's local mode, CLAUDE.md «A fleet temp server
binds 127.0.0.1»):
  - listens on 127.0.0.1 ONLY — there is no option that widens it; a phone
    reaches it through the person's own tunnel (README: tailscale serve / ssh -L);
  - a one-time link carries a random token (or $WEBTERM_TOKEN), traded for an
    HttpOnly SameSite=Strict cookie; without it every path is 403;
  - the WebSocket also checks Origin against Host (no cross-site socket);
  - static files only from ui/, never outside it.

Standard library only — macOS's /usr/bin/python3 is 3.9.

Wire: browser → server text frames, JSON: {"t":"in","d":"<text>"} ·
{"t":"resize","cols":N,"rows":N} · {"t":"ping"}; server → browser binary
frames, the PTY's bytes as they come.
"""
import base64
import fcntl
import hashlib
import hmac
import json
import mimetypes
import os
import pty
import secrets
import shutil
import signal
import socket
import struct
import sys
import termios
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
UI = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ui")
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
COOKIE = "webterm"
MAX_FRAME = 1 << 20  # one input frame; a paste bigger than 1 MiB is refused


def default_cmd():
    if shutil.which("tmux"):
        return ["tmux", "-u", "-L", "webterm", "new-session", "-A", "-s", "main",
                ";", "set-option", "-g", "mouse", "on"]
    return [os.environ.get("SHELL") or "/bin/sh", "-l"]


def child_env():
    env = dict(os.environ)
    for k in ("TMUX", "TMUX_PANE", "WEBTERM_TOKEN"):
        env.pop(k, None)
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    # tmux draws CJK as '_' unless the locale says UTF-8.
    loc = env.get("LC_ALL") or env.get("LC_CTYPE") or env.get("LANG") or ""
    if "utf-8" not in loc.lower() and "utf8" not in loc.lower():
        env["LANG"] = "en_US.UTF-8" if sys.platform == "darwin" else "C.UTF-8"
        env.pop("LC_ALL", None)
    return env


def set_winsize(fd, rows, cols):
    rows = max(2, min(int(rows), 500))
    cols = max(2, min(int(cols), 1000))
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


# ---------------------------------------------------------------- WebSocket


class WS:
    """The server half of RFC 6455 on a raw socket: unmasked sends, masked reads."""

    def __init__(self, sock):
        self.sock = sock
        self.lock = threading.Lock()
        self.closed = False

    def _recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise EOFError
            buf += chunk
        return buf

    def send(self, payload, opcode=0x2):
        n = len(payload)
        if n < 126:
            head = struct.pack("!BB", 0x80 | opcode, n)
        elif n < 1 << 16:
            head = struct.pack("!BBH", 0x80 | opcode, 126, n)
        else:
            head = struct.pack("!BBQ", 0x80 | opcode, 127, n)
        with self.lock:
            if self.closed:
                return
            self.sock.sendall(head + payload)

    def close(self, code=1000):
        try:
            self.send(struct.pack("!H", code), opcode=0x8)
        except OSError:
            pass
        self.closed = True

    def recv(self):
        """One message: (opcode, bytes). Continuation frames are joined."""
        data, first_op = b"", None
        while True:
            b1, b2 = self._recv_exact(2)
            fin, op = b1 & 0x80, b1 & 0x0F
            n = b2 & 0x7F
            if n == 126:
                n = struct.unpack("!H", self._recv_exact(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", self._recv_exact(8))[0]
            if n > MAX_FRAME or len(data) + n > MAX_FRAME:
                raise ValueError("frame too large")
            mask = self._recv_exact(4) if b2 & 0x80 else None
            body = self._recv_exact(n)
            if mask:
                body = bytes(c ^ mask[i % 4] for i, c in enumerate(body))
            if op >= 0x8:  # control frames may interleave
                if op == 0x9:
                    self.send(body, opcode=0xA)
                    continue
                if op == 0xA:
                    continue
                return op, body
            if first_op is None:
                first_op = op
            data += body
            if fin:
                return first_op, data


# ---------------------------------------------------------------- the bridge


def bridge(ws, cmd, cwd, cols, rows):
    pid, fd = pty.fork()
    if pid == 0:  # child
        try:
            os.chdir(cwd)
            os.execvpe(cmd[0], cmd, child_env())
        except Exception as e:  # noqa: BLE001 — the child has nowhere else to say it
            os.write(2, ("web-term: cannot run %s: %s\r\n" % (cmd[0], e)).encode())
        os._exit(127)
    set_winsize(fd, rows, cols)

    def pump():
        try:
            while True:
                out = os.read(fd, 65536)
                if not out:
                    break
                ws.send(out)
        except OSError:
            pass
        ws.close()
        try:
            ws.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    t = threading.Thread(target=pump, daemon=True)
    t.start()
    try:
        while not ws.closed:
            op, body = ws.recv()
            if op == 0x8:
                break
            if op != 0x1:
                continue
            try:
                msg = json.loads(body.decode("utf-8"))
            except ValueError:
                continue
            kind = msg.get("t")
            if kind == "in" and isinstance(msg.get("d"), str):
                data = msg["d"].encode("utf-8")
                while data:
                    data = data[os.write(fd, data):]
            elif kind == "resize":
                try:
                    set_winsize(fd, msg.get("rows", 24), msg.get("cols", 80))
                except (TypeError, ValueError, OSError):
                    pass
    except (EOFError, OSError, ValueError):
        pass
    finally:
        ws.close()
        # SIGHUP: a tmux client detaches (the session stays for the next connect).
        try:
            os.kill(pid, signal.SIGHUP)
        except OSError:
            pass
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except OSError:
            pass


# ---------------------------------------------------------------- HTTP


class Handler(BaseHTTPRequestHandler):
    server_version = "web-term/0"
    protocol_version = "HTTP/1.1"  # a 101 must say 1.1; every reply sends Content-Length
    token = ""
    cmd = []
    cwd = "."

    def log_message(self, fmt, *args):  # one line per request, never the token
        line = fmt % args
        if "t=" in line:
            line = line.split("?", 1)[0] + "?…"
        sys.stderr.write("web-term: %s %s\n" % (self.address_string(), line))

    def _authed(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        got = (q.get("t") or [""])[0]
        if got and hmac.compare_digest(got, self.token):
            return "query"
        for part in (self.headers.get("Cookie") or "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == COOKIE and v and hmac.compare_digest(v, self.token):
                return "cookie"
        return ""

    def _deny(self, code=403, why="需要启动时打印的链接 / open the link the server printed"):
        body = (why + "\n").encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _origin_ok(self):
        origin = self.headers.get("Origin")
        if not origin:
            return False
        o = urllib.parse.urlparse(origin).netloc.lower()
        hosts = {(self.headers.get("Host") or "").lower(),
                 (self.headers.get("X-Forwarded-Host") or "").lower()}
        return o in hosts - {""}

    def do_GET(self):  # noqa: N802
        how = self._authed()
        path = urllib.parse.urlparse(self.path).path
        if not how:
            return self._deny()
        if how == "query":  # trade the link for a cookie, then drop it from the URL
            self.send_response(302)
            self.send_header("Set-Cookie", "%s=%s; HttpOnly; SameSite=Strict; Path=/" % (COOKIE, self.token))
            self.send_header("Location", path if path != "/ws" else "/")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path == "/ws":
            return self._ws()
        return self._static(path)

    def _static(self, path):
        rel = "index.html" if path in ("", "/") else path.lstrip("/")
        full = os.path.realpath(os.path.join(UI, rel))
        if not full.startswith(os.path.realpath(UI) + os.sep) or not os.path.isfile(full):
            return self._deny(404, "not found")
        with open(full, "rb") as f:
            body = f.read()
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        if ctype.startswith("text/") or ctype.endswith("javascript"):
            ctype += "; charset=utf-8"
        hosts = " ".join("ws://%s wss://%s" % (h, h) for h in
                         {self.headers.get("Host") or HOST, self.headers.get("X-Forwarded-Host") or ""} if h)
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        # xterm.js writes <style> into the page, hence 'unsafe-inline' for styles only.
        self.send_header("Content-Security-Policy",
                         "default-src 'self'; style-src 'self' 'unsafe-inline'; "
                         "connect-src 'self' %s; frame-ancestors 'none'" % hosts)
        self.end_headers()
        self.wfile.write(body)

    def _ws(self):
        if not self._origin_ok():
            return self._deny(403, "origin")
        key = self.headers.get("Sec-WebSocket-Key")
        if (self.headers.get("Upgrade") or "").lower() != "websocket" or not key:
            return self._deny(400, "websocket only")
        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.wfile.flush()
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)

        def num(k, d):
            try:
                return int((q.get(k) or [d])[0])
            except ValueError:
                return d
        self.close_connection = True
        bridge(WS(self.connection), self.cmd, self.cwd, num("cols", 80), num("rows", 24))


def main(argv):
    port, cwd, cmd = 8377, os.getcwd(), None
    if "--" in argv:
        i = argv.index("--")
        argv, cmd = argv[:i], argv[i + 1:] or None
    it = iter(argv)
    for a in it:
        if a == "--port":
            port = int(next(it))
        elif a == "--cwd":
            cwd = next(it)
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            sys.stderr.write("web-term: unknown option %s (it listens on %s only; no --bind)\n" % (a, HOST))
            return 2
    Handler.token = os.environ.get("WEBTERM_TOKEN") or secrets.token_urlsafe(18)
    Handler.cmd = cmd or default_cmd()
    Handler.cwd = cwd
    ThreadingHTTPServer.daemon_threads = True
    srv = ThreadingHTTPServer((HOST, port), Handler)
    print("web-term: http://%s:%d/?t=%s" % (HOST, srv.server_address[1], Handler.token), flush=True)
    print("web-term: runs %s" % " ".join(Handler.cmd), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
