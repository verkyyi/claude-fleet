#!/usr/bin/env python3
"""fleet-webterm-selftest.py — web-term C1 (issue #3837): extras/web-term/server.py
for real on a free 127.0.0.1 port, a PTY running a small sh loop.

  A  no token ⇒ 403 on the page, a file and the socket
  B  the one-time link ⇒ 302 + HttpOnly SameSite=Strict cookie, token gone from the URL
  C  nothing outside ui/ is served
  D  the socket refuses a missing / foreign Origin
  E  the PTY: the asked size, CJK text arrives whole, a resize reaches the program
  F  127.0.0.1 only — no option widens it
  G  the browser goes ⇒ the PTY's program is gone (no orphan)
  H  extras/web-term/ui/keys.js (under node, when there is one): the compose box's
     bracketed paste, ESC dropped, the key bar's sequences
"""
import base64
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER = os.path.join(ROOT, "extras", "web-term", "server.py")
KEYS = os.path.join(ROOT, "extras", "web-term", "ui", "keys.js")
TOKEN = "selftest-token-3837"
fails = []


def check(name, ok, detail=""):
    print("%s %s%s" % ("PASS" if ok else "FAIL", name, (" — " + detail) if detail and not ok else ""))
    if not ok:
        fails.append(name)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


opener = urllib.request.build_opener(NoRedirect)


def get(url, cookie=None):
    req = urllib.request.Request(url)
    if cookie:
        req.add_header("Cookie", cookie)
    try:
        r = opener.open(req, timeout=5)
        return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def ws_open(port, origin, cookie, cols=90, rows=20):
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    head = ("GET /ws?cols=%d&rows=%d HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n"
            % (cols, rows, port, key))
    if origin:
        head += "Origin: %s\r\n" % origin
    if cookie:
        head += "Cookie: %s\r\n" % cookie
    s.sendall((head + "\r\n").encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = s.recv(4096)
        if not chunk:
            break
        resp += chunk
    status = int(resp.split(b" ", 2)[1]) if resp else 0
    rest = resp.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in resp else b""
    return s, status, rest


def ws_send(s, obj):
    data = json.dumps(obj).encode("utf-8")
    mask = os.urandom(4)
    n = len(data)
    head = struct.pack("!BB", 0x81, 0x80 | n) if n < 126 else struct.pack("!BBH", 0x81, 0x80 | 126, n)
    s.sendall(head + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(data)))


class Reader:
    def __init__(self, s, buf):
        self.s, self.buf, self.out = s, buf, b""

    def _frames(self):
        while len(self.buf) >= 2:
            n = self.buf[1] & 0x7F
            off = 2
            if n == 126:
                if len(self.buf) < 4:
                    return
                n, off = struct.unpack("!H", self.buf[2:4])[0], 4
            elif n == 127:
                if len(self.buf) < 10:
                    return
                n, off = struct.unpack("!Q", self.buf[2:10])[0], 10
            if len(self.buf) < off + n:
                return
            if self.buf[0] & 0x0F == 0x2:
                self.out += self.buf[off:off + n]
            self.buf = self.buf[off + n:]

    def until(self, needle, secs=5):
        end = time.time() + secs
        self._frames()
        while needle not in self.out and time.time() < end:
            self.s.settimeout(max(0.05, end - time.time()))
            try:
                chunk = self.s.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            self.buf += chunk
            self._frames()
        return needle in self.out


def main():
    env = dict(os.environ, WEBTERM_TOKEN=TOKEN)
    prog = ("echo pid:$$; stty size; stty -echo; "
            "while IFS= read -r l; do printf 'got:%s\\n' \"$l\"; stty size; done")
    srv = subprocess.Popen([sys.executable, SERVER, "--port", "0", "--", "sh", "-c", prog],
                           env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        line = srv.stdout.readline().strip()
        check("F printed address is 127.0.0.1", line.startswith("web-term: http://127.0.0.1:"), line)
        port = int(line.split(":")[3].split("/")[0])
        base = "http://127.0.0.1:%d" % port
        lsn = subprocess.run([sys.executable, "-c",
                              "import socket;s=socket.socket();s.settimeout(1);"
                              "import sys;h=[a for a in sys.argv[1:]];"
                              "print(s.connect_ex((h[0],int(h[1]))))", "127.0.0.1", str(port)],
                             capture_output=True, text=True)
        check("F reachable on loopback", lsn.stdout.strip() == "0", lsn.stdout)

        code, _, _ = get(base + "/")
        check("A page without token is 403", code == 403, str(code))
        code, _, _ = get(base + "/app.js")
        check("A file without token is 403", code == 403, str(code))
        code, _, _ = get(base + "/?t=wrong")
        check("A wrong token is 403", code == 403, str(code))
        s, st, _ = ws_open(port, base, None)
        s.close()
        check("A socket without cookie is 403", st == 403, str(st))

        code, hdr, _ = get(base + "/?t=" + TOKEN)
        ck = hdr.get("Set-Cookie", "")
        check("B link gives 302", code == 302, str(code))
        check("B cookie is HttpOnly + SameSite=Strict", "HttpOnly" in ck and "SameSite=Strict" in ck, ck)
        check("B token dropped from Location", TOKEN not in hdr.get("Location", "?"), hdr.get("Location", ""))
        cookie = ck.split(";", 1)[0]
        code, hdr, body = get(base + "/", cookie)
        check("B page with cookie is 200", code == 200 and b"keys.js" in body, str(code))
        check("B page has a CSP", "default-src 'self'" in hdr.get("Content-Security-Policy", ""))

        for bad in ("/../server.py", "/%2e%2e/server.py", "/vendor/../../server.py"):
            req = urllib.request.Request(base + bad)
            req.add_header("Cookie", cookie)
            try:
                c = opener.open(req, timeout=5).status
            except urllib.error.HTTPError as e:
                c = e.code
            check("C %s not served" % bad, c == 404, str(c))

        s, st, _ = ws_open(port, None, cookie)
        s.close()
        check("D socket without Origin is 403", st == 403, str(st))
        s, st, _ = ws_open(port, "http://evil.example", cookie)
        s.close()
        check("D socket from a foreign Origin is 403", st == 403, str(st))

        s, st, rest = ws_open(port, base, cookie, cols=90, rows=20)
        check("E socket upgrades", st == 101, str(st))
        r = Reader(s, rest)
        check("E the PTY has the asked size", r.until(b"20 90"), r.out[-200:].decode("utf-8", "replace"))
        pid = int(r.out.split(b"pid:", 1)[1].split(b"\r", 1)[0].split(b"\n", 1)[0]) if b"pid:" in r.out else 0
        ws_send(s, {"t": "in", "d": "你好，世界 🚀\r"})
        check("E CJK text arrives whole", r.until("got:你好，世界 🚀".encode("utf-8")), r.out[-200:].decode("utf-8", "replace"))
        ws_send(s, {"t": "resize", "cols": 120, "rows": 40})
        time.sleep(0.2)
        ws_send(s, {"t": "in", "d": "x\r"})
        check("E a resize reaches the program", r.until(b"40 120"), r.out[-200:].decode("utf-8", "replace"))

        s.close()
        gone = False
        for _ in range(40):
            try:
                os.kill(pid, 0)
            except OSError:
                gone = True
                break
            time.sleep(0.1)
        check("G the PTY's program is gone after the browser goes", pid > 0 and gone, "pid %d" % pid)
    finally:
        srv.terminate()
        srv.wait(5)

    bad = subprocess.run([sys.executable, SERVER, "--bind", "0.0.0.0"], capture_output=True, text=True, timeout=10)
    check("F --bind is refused", bad.returncode == 2 and "127.0.0.1" in bad.stderr, bad.stderr)

    node = shutil.which("node")
    if not node:
        print("SKIP H: no node")
    else:
        js = r"""
const K = require(process.argv[1]); const out = [];
const eq = (n, a, b) => out.push([n, a === b, JSON.stringify(a)]);
eq('bracketed paste wraps', K.encodeCompose('你好\n第二行', true), '\x1b[200~你好\r第二行\x1b[201~');
eq('plain when not asked', K.encodeCompose('a\r\nb', false), 'a\rb');
eq('ESC cannot end the paste', K.encodeCompose('x\x1b[201~y', true), '\x1b[200~x[201~y\x1b[201~');
eq('empty is nothing', K.encodeCompose('', true), '');
eq('shift-tab', K.keySeq('stab', false), '\x1b[Z');
eq('up, normal', K.keySeq('up', false), '\x1b[A');
eq('up, app cursor', K.keySeq('up', true), '\x1bOA');
eq('ctrl-c via ctrlOf', K.ctrlOf('c'), '\x03');
eq('ctrl-[ is ESC', K.ctrlOf('['), '\x1b');
eq('wheel up', K.wheelSeq(true, 3, 4), '\x1b[<64;3;4M');
console.log(JSON.stringify(out));
"""
        res = subprocess.run([node, "-e", js, KEYS], capture_output=True, text=True, timeout=20)
        try:
            for name, ok, got in json.loads(res.stdout):
                check("H " + name, ok, got)
        except ValueError:
            check("H keys.js runs under node", False, res.stderr[-300:])

    print("fleet-webterm-selftest: %s" % ("FAIL " + ", ".join(fails) if fails else "OK"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
