#!/usr/bin/env python3
# selftest-entry
"""T1270: a separated login's peer relay through the real HTTP broker."""
import base64
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import socket
import struct
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


cp = module("credproxy", "fleet-cred-proxy.py")
fc = module("connect", "fleet-connect.py")


class Hub(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    log_message = lambda *args: None

    def do_GET(self):
        self.server.seen.append(dict(self.headers))
        if self.headers.get("Authorization") != "Bearer upstream-node":
            return self.reply(401, b"wrong node credential")
        if "denied" in self.path:
            return self.reply(403, b"target belongs to another person")
        if self.headers.get("Upgrade", "").lower() != "websocket" or "upgrade" not in self.headers.get("Connection", "").lower():
            return self.reply(426, b"Connection header does not contain Upgrade")
        key = self.headers["Sec-WebSocket-Key"]
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
        if "bad-accept" in self.path:
            accept = b"invalid"
        # Coalesce the 101 with the first frame: a buffered HTTP reader must
        # not lose the first bytes of the upgraded stream.
        self.connection.sendall(b"HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n\x81\x05ready")
        ws = fc.WS.__new__(fc.WS)
        ws.sock, ws.buf, ws.wlock = self.connection, b"", threading.Lock()
        try:
            while True:
                op, data = ws.recv()
                n = len(data)
                size = bytes([n]) if n < 126 else (b"\x7e" + struct.pack("!H", n) if n < 65536 else b"\x7f" + struct.pack("!Q", n))
                self.connection.sendall(bytes([0x80 | op]) + size + data)
                if op == 8:
                    break
        except (OSError, EOFError):
            pass
        finally:
            self.close_connection = True
            self.server.closed.set()

    def reply(self, code, body):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class BrokerWebSocket(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.hub = ThreadingHTTPServer(("127.0.0.1", 0), Hub)
        self.hub.seen, self.hub.closed = [], threading.Event()
        ne = Path(self.tmp.name) / "node.env"
        ne.write_text("CCQUOTA_HUB_URL=http://127.0.0.1:%d\nCCQUOTA_TOKEN=upstream-node\n" % self.hub.server_port)
        keys = cp.Keys(self.tmp.name)
        self.token = keys.mint("", "node", 60, cp.NODE_TAG)
        self.logs = []
        tenant = SimpleNamespace(cfg=SimpleNamespace(broker=True, node_env=str(ne), timeout=0.2),
                                 keys=keys, log=lambda **kv: self.logs.append(kv))
        handler = type("Broker", (cp.Proxy,), {"T": tenant, "tenants": {}, "fixed": None})
        self.broker = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        for srv in (self.hub, self.broker):
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            self.addCleanup(srv.server_close)
            self.addCleanup(srv.shutdown)
        # The ordinary HTTP forwarder cannot carry upgrades. Never send this
        # request there, even when a warm socket exists.
        self.fwd = patch.object(cp, "hub_fwd_sock", return_value="/unused/hub.sock").start()
        self.addCleanup(patch.stopall)

    def connect(self, node="pod"):
        url = "http://127.0.0.1:%d/hub/v1/node/peer-relay?node=%s" % (self.broker.server_port, node)
        ws = fc.WS(url, {"Authorization": "Bearer " + self.token}, timeout=3)
        ws.sock.settimeout(3)
        return ws

    def test_upgrade_binary_idle_and_close(self):
        ws = self.connect()
        try:
            self.assertEqual(ws.recv(), (1, b"ready"))
            # A quiet terminal outlives the HTTP request timeout.
            time.sleep(0.3)
            data = os.urandom(131073)
            ws.send(2, data)
            self.assertEqual(ws.recv(), (2, data))
            ws.send(8, b"\x03\xe8")
            self.assertEqual(ws.recv(), (8, b"\x03\xe8"))
        finally:
            ws.close()
        self.assertTrue(self.hub.closed.wait(2))
        self.assertEqual(self.hub.seen[0]["Authorization"], "Bearer upstream-node")
        self.assertNotIn(self.token, json.dumps(self.logs))
        self.assertNotIn("upstream-node", json.dumps(self.logs))
        self.fwd.assert_not_called()

    def test_client_disconnect_closes_upstream(self):
        ws = self.connect()
        self.assertEqual(ws.recv(), (1, b"ready"))
        ws.sock.shutdown(socket.SHUT_RDWR)
        ws.sock.close()
        self.assertTrue(self.hub.closed.wait(2))

    def test_refusal_remains_http(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.broker.server_port, timeout=3)
        conn.request("GET", "/hub/v1/node/peer-relay?node=denied", headers={
            "Authorization": "Bearer " + self.token, "Connection": "Upgrade", "Upgrade": "websocket"})
        resp = conn.getresponse()
        self.assertEqual(resp.status, 403)
        self.assertEqual(resp.read(), b"target belongs to another person")
        conn.close()

    def test_invalid_upstream_upgrade_is_not_tunnelled(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.broker.server_port, timeout=3)
        conn.request("GET", "/hub/v1/node/peer-relay?node=bad-accept", headers={
            "Authorization": "Bearer " + self.token, "Connection": "Upgrade", "Upgrade": "websocket",
            "Sec-WebSocket-Key": base64.b64encode(os.urandom(16)).decode(), "Sec-WebSocket-Version": "13"})
        resp = conn.getresponse()
        self.assertEqual(resp.status, 502)
        self.assertIn(b"invalid upstream WebSocket upgrade", resp.read())
        conn.close()
        self.assertTrue(self.hub.closed.wait(2))

    def test_broker_auth_and_pool_denial_precede_upgrade(self):
        for token, path, status in [
            ("forged", "/v1/node/peer-relay", 401),
            (self.token, "/v1/node/credentials", 403),
        ]:
            conn = http.client.HTTPConnection("127.0.0.1", self.broker.server_port, timeout=3)
            conn.request("GET", "/hub" + path, headers={"Authorization": "Bearer " + token,
                         "Connection": "Upgrade", "Upgrade": "websocket"})
            resp = conn.getresponse()
            self.assertEqual(resp.status, status)
            resp.read()
            conn.close()
        self.assertEqual(self.hub.seen, [])


if __name__ == "__main__":
    unittest.main()
