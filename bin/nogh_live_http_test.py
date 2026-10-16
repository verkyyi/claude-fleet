#!/usr/bin/env python3
"""Actual local TLS/HTTP/WebSocket isolation checks, never live C9 evidence.

The 20-second entry includes certificate generation, listeners and cleanup.
"""
import base64
import hashlib
import http.client
import http.server
import io
import json
import os
from pathlib import Path
import signal
import socket
import ssl
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

import nogh_live_http as adapter
from nogh_live_contract import Refused

GITHUB_HOST = 'api.github.com'  # dist-ok: local TLS authority-denial test; no GitHub request is made


class Adapter(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='c9-tls-')
        cls.addClassCleanup(cls.temporary.cleanup)
        root = Path(cls.temporary.name)
        cert, key = root / 'tls.crt', root / 'tls.key'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-subj', '/CN=provider.test', '-addext', 'subjectAltName=DNS:provider.test',
                        '-keyout', str(key), '-out', str(cert)], check=True, timeout=3,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        cls.context = ssl.create_default_context(cafile=str(cert))
        cls.requests, cls.events = [], []

        class Origin(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *_): pass
            def do_GET(self):
                cls.requests.append(self.path)
                if self.headers.get('Upgrade') == 'websocket':
                    accept = base64.b64encode(hashlib.sha1((self.headers['Sec-WebSocket-Key'] +
                        '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
                    self.send_response_only(101)
                    for k, v in [('Upgrade', 'websocket'), ('Connection', 'Upgrade'),
                                 ('Sec-WebSocket-Accept', accept)]: self.send_header(k, v)
                    self.end_headers(); self.wfile.flush()
                    adapter.websocket_frame(self.rfile, True)
                    self.wfile.write(b'\x81\x02ok'); self.wfile.flush()
                    adapter.websocket_frame(self.rfile, True)
                    self.close_connection = True
                else:
                    self.send_response_only(200); self.send_header('Content-Length', '2')
                    self.end_headers(); self.wfile.write(b'ok')

        cls.origin = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Origin)
        cls.origin.daemon_threads = True
        cls.origin.socket = context.wrap_socket(cls.origin.socket, server_side=True)
        cls.addClassCleanup(cls.origin.server_close)
        threading.Thread(target=cls.origin.serve_forever, kwargs={'poll_interval': 0.01}, daemon=True).start()
        cls.addClassCleanup(cls.origin.shutdown)
        cls.port = cls.origin.server_port

        class Policy:
            plan = {'budget_seconds': 5}
            sources = {'127.0.0.1': 'node-a'}
            def phase(self): return 'row:A1'
            def allowed_origin(self, host, port, phase):
                return ('127.0.0.1', 'allow_provider') if (host, port) == ('provider.test', cls.port) else None
            def denied_category(self, host): return 'github_network' if host == GITHUB_HOST else 'unknown'
            def record(self, source, category, phase): cls.events.append((source, category, phase))

        class LocalPinned(adapter.PinnedHTTPS):
            def __init__(self, *args):
                super().__init__(*args)
                self._context = cls.context

        cls.private = patch.object(adapter, 'PRIVATE', root)
        cls.private.start(); cls.addClassCleanup(cls.private.stop)
        cls.pinned = patch.object(adapter, 'PinnedHTTPS', LocalPinned)
        cls.pinned.start(); cls.addClassCleanup(cls.pinned.stop)
        cls.proxy = adapter.server(Policy(), '127.0.0.1', 0, 'sha256:' + hashlib.sha256(cert.read_bytes()).hexdigest())
        cls.addClassCleanup(cls.proxy.server_close)
        threading.Thread(target=cls.proxy.serve_forever, kwargs={'poll_interval': 0.01}, daemon=True).start()
        cls.addClassCleanup(cls.proxy.shutdown)

    def connect(self, host='provider.test', port=None):
        port = self.port if port is None else port
        raw = socket.create_connection(self.proxy.server_address, timeout=2)
        self.addCleanup(raw.close)
        raw.sendall(('CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n\r\n' % (host, port, host, port)).encode())
        header = bytearray()
        while not header.endswith(b'\r\n\r\n'):
            block = raw.recv(1)
            self.assertTrue(block); header.extend(block)
        if host == GITHUB_HOST: return bytes(header)
        self.assertTrue(header.startswith(b'HTTP/1.1 200'))
        secured = self.context.wrap_socket(raw, server_hostname='provider.test')
        self.addCleanup(secured.close)
        return secured

    def test_allowed_tls_and_changed_http_authority(self):
        before = len(self.requests)
        with self.connect() as client:
            client.sendall(('GET /ok HTTP/1.1\r\nHost: provider.test:%d\r\n\r\n' % self.port).encode())
            response = http.client.HTTPResponse(client); response.begin()
            self.assertEqual((response.status, response.read()), (200, b'ok'))
        self.assertEqual(len(self.requests), before + 1)
        with self.connect() as client:
            client.sendall(('GET /SECRET_SENTINEL HTTP/1.1\r\nHost: %s\r\n\r\n' % GITHUB_HOST).encode())
            self.assertEqual(client.recv(1024), b'')
        self.assertEqual(len(self.requests), before + 1)
        self.assertNotIn('SECRET_SENTINEL', json.dumps(self.events))

    def test_github_deny_is_not_unknown(self):
        before = len(self.events)
        self.assertIn(b'403', self.connect(GITHUB_HOST, 443))
        self.assertEqual([e[1] for e in self.events[before:]], ['github_network'])

    def test_websocket_upgrade_is_framed_and_pinned(self):
        with self.connect() as client:
            client.sendall(('GET /ws HTTP/1.1\r\nHost: provider.test:%d\r\nUpgrade: websocket\r\n'
                            'Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n'
                            'Sec-WebSocket-Key: %s\r\n\r\n' %
                            (self.port, base64.b64encode(os.urandom(16)).decode())).encode())
            response = adapter.UpgradeResponse(client); response.begin()
            self.assertEqual(response.status, 101)
            client.sendall(b'\x81\x82\x00\x00\x00\x00hi')
            frame, opcode, final = adapter.websocket_frame(response.fp, False)
            self.assertEqual((frame, opcode, final), (b'\x81\x02ok', 1, True))
            client.sendall(b'\x88\x80\x00\x00\x00\x00')

    def test_invalid_websocket_mask_and_length_refuse(self):
        for wire in (b'\x81\x00', b'\x81\xff' + (2 ** 63).to_bytes(8, 'big'), b'\x89\xfe\x00\x80'):
            with self.assertRaises(Refused): adapter.websocket_frame(io.BytesIO(wire), True)


if __name__ == '__main__':
    signal.alarm(20)
    unittest.main()
