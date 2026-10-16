#!/usr/bin/env python3
"""C9-only HTTP/1 adapter; never a transparent CONNECT tunnel.

TLS terminates with the owner's test CA. Each request's authority is checked,
then a new TLS connection uses the pinned origin address and verified hostname.
No request headers, URLs, bodies, exception strings or credentials are logged.
Unsupported protocols fail closed; this does not relax the production proxy.
"""
import hashlib
import http.client
import http.server
from pathlib import Path
import socket
import ssl
import threading

from nogh_live_contract import require

MAX_BODY = 16 * 1024 * 1024
PRIVATE = Path('/run/c9-proxy-private')


def authority(value):
    # CONNECT carries a DNS name and an explicit port; never an IP, userinfo,
    # whitespace, escaped spelling, trailing dot or inferred port.
    require(isinstance(value, str) and value.count(':') == 1, 'HTTP_AUTHORITY')
    host, raw = value.rsplit(':', 1)
    require(host and host == host.lower() and not host.endswith('.')
            and all(c in 'abcdefghijklmnopqrstuvwxyz0123456789-.' for c in host)
            and raw.isdecimal() and str(int(raw)) == raw and 0 < int(raw) < 65536,
            'HTTP_AUTHORITY')
    return host, int(raw)


class PinnedHTTPS(http.client.HTTPSConnection):
    def __init__(self, host, port, address):
        super().__init__(host, port, timeout=2, context=ssl.create_default_context())
        self.address = address

    def connect(self):
        # No resolver, proxy environment, redirect or shared upstream tunnel.
        raw = socket.create_connection((self.address, self.port), timeout=self.timeout)
        try:
            self.sock = self._context.wrap_socket(raw, server_hostname=self.host)
        except BaseException:
            raw.close()
            raise


def tls_context(expected_digest):
    cert = PRIVATE / 'tls.crt'
    require('sha256:' + hashlib.sha256(cert.read_bytes()).hexdigest() == expected_digest,
            'PROXY_CERTIFICATE_CHANGED')
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.set_alpn_protocols(['http/1.1'])
    context.load_cert_chain(cert, PRIVATE / 'tls.key')
    return context


def server(policy, host, port, expected_cert):
    context = tls_context(expected_cert)

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *_):
            pass

        def handle(self):
            # BaseHTTPRequestHandler may otherwise include a malformed request
            # in its HTML error response. Never echo it, even to the workload.
            try:
                self.connection.settimeout(2)
                super().handle()
            except BaseException:
                self.close_connection = True

        def send_error(self, code, *_):
            if self.client_address[0] in policy.sources:
                policy.record(self.client_address[0], 'unknown', policy.phase())
            self.close_connection = True
            self.send_response_only(code)
            self.send_header('Content-Length', '0')
            self.send_header('Connection', 'close')
            self.end_headers()

        def do_CONNECT(self):
            source = self.client_address[0]
            before = policy.phase()
            upstream = None
            try:
                require(source in policy.sources, 'FOREIGN_PROXY_SOURCE')
                host, port = authority(self.path)
                route = policy.allowed_origin(host, port, before)
                if route is None:
                    policy.record(source, policy.denied_category(host), before)
                    self.close_connection = True
                    self.send_response_only(403)
                    self.send_header('Content-Length', '0')
                    self.send_header('Connection', 'close')
                    self.end_headers()
                    return
                target, category = route
                require(not self.headers.get('Transfer-Encoding') and
                        self.headers.get('Content-Length', '0') == '0', 'CONNECT_BODY')
                self.send_response_only(200)
                self.end_headers()
                self.wfile.flush()
                # The client is given no byte tunnel. TLS is ours, HTTP is
                # parsed below, and Host is verified before an origin socket.
                self.connection = context.wrap_socket(self.connection, server_side=True)
                self.rfile = self.connection.makefile('rb', -1)
                self.wfile = self.connection.makefile('wb', 0)
                self.raw_requestline = self.rfile.readline(65537)
                require(len(self.raw_requestline) <= 65536 and self.parse_request(), 'HTTP_REQUEST')
                require(self.command in ('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD')
                        and self.path.startswith('/') and not self.path.startswith('//')
                        and self.request_version == 'HTTP/1.1', 'HTTP_PROTOCOL')
                names = self.headers.get_all('Host', [])
                require(len(names) == 1 and names[0] in
                        (('%s:%d' % (host, port), host) if port == 443 else ('%s:%d' % (host, port),)),
                        'HTTP_AUTHORITY_CHANGED')
                require(not self.headers.get('Upgrade') and not self.headers.get('Transfer-Encoding')
                        and not self.headers.get('Expect'), 'HTTP_TUNNEL_OR_FRAMING')
                lengths = self.headers.get_all('Content-Length', [])
                require(len(lengths) <= 1, 'HTTP_LENGTH')
                length = lengths[0] if lengths else '0'
                require(length.isdecimal() and int(length) <= MAX_BODY, 'HTTP_BODY_LIMIT')
                body = self.rfile.read(int(length))
                require(len(body) == int(length), 'HTTP_BODY_TRUNCATED')
                # Re-evaluate after TLS/body reception: a restored A4 interval
                # cannot lend an open connection to a subsequent zero interval.
                require(policy.allowed_origin(host, port, policy.phase()) == route, 'HTTP_PHASE_CHANGED')
                headers = {}
                for name in self.headers.keys():
                    require(len(self.headers.get_all(name)) == 1, 'HTTP_DUPLICATE_HEADER')
                    if name.lower() not in ('host', 'connection', 'proxy-connection', 'proxy-authorization',
                                             'content-length', 'transfer-encoding', 'upgrade', 'te', 'trailer'):
                        headers[name] = self.headers[name]
                headers.update(Host='%s:%d' % (host, port), Connection='close')
                upstream = PinnedHTTPS(host, port, target)
                upstream.request(self.command, self.path, body=body, headers=headers)
                response = upstream.getresponse()
                require(response.status != 101, 'HTTP_UPGRADE_REFUSED')
                policy.record(source, category, before)
                if 200 <= response.status < 300:
                    policy.record(source, 'success_' + category.removeprefix('allow_'), before)
                self.send_response_only(response.status)
                for name, value in response.getheaders():
                    if name.lower() not in ('connection', 'content-length', 'transfer-encoding', 'upgrade',
                                             'alt-svc', 'trailer', 'te'):
                        self.send_header(name, value)
                self.send_header('Connection', 'close')
                self.end_headers()
                while True:
                    block = response.read1(65536)
                    if not block:
                        break
                    self.wfile.write(block)
            except BaseException:
                if source in policy.sources:
                    policy.record(source, 'unknown', before)
            finally:
                self.close_connection = True
                if upstream is not None:
                    upstream.close()

    class BoundedServer(http.server.ThreadingHTTPServer):
        daemon_threads = True

        def __init__(self):
            self.slots = threading.BoundedSemaphore(32)
            super().__init__((host, port), Handler)

        def process_request(self, request, client_address):
            if not self.slots.acquire(blocking=False):
                if client_address[0] in policy.sources:
                    policy.record(client_address[0], 'unknown', policy.phase())
                self.shutdown_request(request)
                return
            super().process_request(request, client_address)

        def process_request_thread(self, *args):
            try:
                super().process_request_thread(*args)
            finally:
                self.slots.release()

        def handle_error(self, *_):
            pass

    return BoundedServer()
