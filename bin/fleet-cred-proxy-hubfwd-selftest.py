#!/usr/bin/env python3
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
"""fleet-cred-proxy-hubfwd-selftest.py — the hub broker's warm road (claude-fleet T672).

bin/fleet-cred-proxy.py's /hub/ broker used to open a fresh HTTPS connection to
the hub for every brokered call (≈ 0.55 s each from a managed Mac). It now hands a
hub call to the node agent's forwarder socket (tokenledger/shared/hubfwd — plain
HTTP there, `X-Fleet-Hub` naming the hub) and goes direct only when nobody answers
on the socket or the forwarder refused BEFORE forwarding — never twice.

Drives Proxy.upstream() itself against a fake forwarder (a unix-socket HTTP server)
and a fake hub (loopback HTTP):
  F  a forwarder that answers: the request rides the socket — the hub never sees
     it directly, the forwarder saw X-Fleet-Hub + the node token, the client got
     the answer.
  R  a forwarder that refuses (X-Fleet-Hubfwd: refused): the same request once,
     straight to the hub.
  N  a socket nobody listens on: straight to the hub.
  O  not the hub (a provider call): never the socket.
"""
import importlib.util
import io
import os
import socket
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer, ThreadingHTTPServer

BIN = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("credproxy", os.path.join(BIN, "fleet-cred-proxy.py"))
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)

FAILS = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        FAILS.append(what)


class Seen(BaseHTTPRequestHandler):
    log_message = lambda *a: None

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        self.server.seen.append((self.path, dict(self.headers), body))
        refuse = getattr(self.server, "refuse", False)
        out = b"hubfwd: this forwarder serves https://other only" if refuse else b'{"ok":"' + self.server.name + b'"}'
        self.send_response(421 if refuse else 200)
        if refuse:
            self.send_header("X-Fleet-Hubfwd", "refused")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


class UnixServer(ThreadingHTTPServer):
    address_family = socket.AF_UNIX

    def server_bind(self):
        self.socket.bind(self.server_address)

    def get_request(self):
        r, _ = self.socket.accept()
        return r, ("unix", 0)


def serve(srv, name):
    srv.seen, srv.name = [], name
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


class FakeCfg:
    timeout = 10
    name = "t"


class FakeT:
    cfg = FakeCfg()

    def note_quota(self, *a):
        pass

    def log(self, **kv):
        pass


def run(fwd, provider="hub"):
    """One upstream() call as the broker makes it → (status line, body)."""
    h = cp.Proxy.__new__(cp.Proxy)
    h.t, h.command, h.path = FakeT(), "POST", "/hub/v1/node/place"
    h.request_version, h.close_connection = "HTTP/1.1", False
    h.wfile = io.BytesIO()
    h.hub_fwd = fwd
    out = {"Authorization": "Bearer ccq_NODE", "Content-Type": "application/json"}
    h.upstream("http://127.0.0.1:%d" % hub.server_address[1], "/v1/node/place", out, b'{"a":1}',
               "hub", "node", "-", "node", [], 0.0, provider, can_switch=False)
    raw = h.wfile.getvalue()
    return raw.split(b"\r\n", 1)[0], raw


d = tempfile.mkdtemp(prefix="hf", dir="/tmp")
hub = serve(HTTPServer(("127.0.0.1", 0), Seen), b"hub")
fwd = serve(UnixServer(os.path.join(d, "hub.sock"), Seen), b"fwd")
HUB = "https://hub.example"

# F — the forwarder answers
line, raw = run((os.path.join(d, "hub.sock"), HUB))
check(b" 200" in line and b'"fwd"' in raw, "F the answer came back through the forwarder: %r" % line)
check(len(fwd.seen) == 1 and not hub.seen, "F the hub was not asked directly (fwd %d, hub %d)" % (len(fwd.seen), len(hub.seen)))
if fwd.seen:
    p, hd, body = fwd.seen[0]
    check(p == "/v1/node/place" and hd.get("X-Fleet-Hub") == HUB and hd.get("Authorization") == "Bearer ccq_NODE"
          and body == b'{"a":1}', "F the forwarder saw the path, X-Fleet-Hub, the node token and the body")

# R — the forwarder refuses before forwarding: once, direct
fwd.seen.clear(); hub.seen.clear(); fwd.refuse = True
line, raw = run((os.path.join(d, "hub.sock"), HUB))
check(b" 200" in line and b'"hub"' in raw and len(hub.seen) == 1 and len(fwd.seen) == 1,
      "R a refusal ⇒ the same request once, straight to the hub (fwd %d, hub %d)" % (len(fwd.seen), len(hub.seen)))
if hub.seen:
    check("X-Fleet-Hub" not in hub.seen[0][1], "R the direct request carries no X-Fleet-Hub")
fwd.refuse = False

# N — nobody on the socket
fwd.seen.clear(); hub.seen.clear()
line, raw = run((os.path.join(d, "none.sock"), HUB))
check(b" 200" in line and len(hub.seen) == 1, "N no forwarder ⇒ the hub directly")

# O — a provider call never takes the socket
fwd.seen.clear(); hub.seen.clear()
line, raw = run((os.path.join(d, "hub.sock"), HUB), provider="claude")
check(not fwd.seen, "O a provider call never rides the hub's socket")

# hub_fwd_sock: off, a named one, none
os.environ["CCQUOTA_HUB_SOCK"] = "off"
check(cp.hub_fwd_sock() is None, "S CCQUOTA_HUB_SOCK=off ⇒ none")
os.environ["CCQUOTA_HUB_SOCK"] = os.path.join(d, "hub.sock")
check(cp.hub_fwd_sock() == os.path.join(d, "hub.sock"), "S a named socket")
os.environ["CCQUOTA_HUB_SOCK"] = os.path.join(d, "none.sock")
check(cp.hub_fwd_sock() is None, "S a name with no socket ⇒ none")

fwd.shutdown(); hub.shutdown()
if FAILS:
    print("fleet-cred-proxy-hubfwd selftest: %d FAILED" % len(FAILS))
    sys.exit(1)
print("fleet-cred-proxy-hubfwd selftest: all green")
