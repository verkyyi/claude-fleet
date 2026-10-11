#!/usr/bin/env python3
"""GitHub-only forward proxy on the Singapore relay (claude-fleet#3348).

The ACK cluster's egress (Shenzhen) cannot reach github.com's git transport;
the relay can. This is an HTTP CONNECT proxy that opens a tunnel ONLY:

  - from a source address in GH_RELAY_SOURCES (the cluster egress /32 — the
    Lightsail firewall says the same thing; this is the second wall),
  - to a host in GH_RELAY_HOSTS (GitHub's own names, exact match),
  - on port 443,
  - to an address that resolves public (never the VPC, metadata or loopback).

Anything else is answered 403 and closed. No plain-HTTP proxying, no auth
header, nothing decrypted: the client's TLS runs end to end to GitHub. One JSON
line per request on stdout (journald): src, host, code, bytes each way, ms.

  gh-relay.py            serve (GH_RELAY_LISTEN, default 0.0.0.0:3128)
  gh-relay.py --selftest offline checks, exit 0 = pass
"""
import asyncio
import ipaddress
import json
import os
import socket
import sys
import time

HOSTS = ('github.com api.github.com codeload.github.com uploads.github.com '
         'objects.githubusercontent.com raw.githubusercontent.com '
         'release-assets.githubusercontent.com github-releases.githubusercontent.com '
         'objects-origin.githubusercontent.com media.githubusercontent.com '
         'github-cloud.githubusercontent.com ghcr.io pkg-containers.githubusercontent.com')
SOURCES = '47.106.171.142/32'
MAX_HEAD = 8192
MAX_TUNNELS = int(os.environ.get('GH_RELAY_MAX', '64'))
IDLE = float(os.environ.get('GH_RELAY_IDLE', '300'))
CONNECT_TIMEOUT = 15.0


def config(env=os.environ):
    hosts = frozenset(h.strip().lower() for h in env.get('GH_RELAY_HOSTS', HOSTS).split() if h.strip())
    sources = [ipaddress.ip_network(s.strip(), strict=False)
               for s in env.get('GH_RELAY_SOURCES', SOURCES).replace(',', ' ').split() if s.strip()]
    return hosts, sources


def source_ok(addr, sources):
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return False
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return any(ip in n for n in sources)


def parse_head(head):
    """(method, host, port) of a CONNECT request head; ValueError otherwise."""
    line = head.split(b'\r\n', 1)[0].decode('latin-1')
    parts = line.split(' ')
    if len(parts) != 3 or not parts[2].startswith('HTTP/1.'):
        raise ValueError('bad request line')
    method, target = parts[0], parts[1]
    if method != 'CONNECT':
        return method, '', 0
    host, sep, port = target.rpartition(':')
    if not sep or not port.isdigit() or host.startswith('['):
        raise ValueError('bad CONNECT target')
    return method, host.lower().rstrip('.'), int(port)


def decide(method, host, port, hosts):
    """None = tunnel; else the refusal reason."""
    if method != 'CONNECT':
        return 'method_not_allowed'
    if port != 443:
        return 'port_not_allowed'
    if host not in hosts:
        return 'host_not_allowed'
    return None


def public(addr):
    ip = ipaddress.ip_address(addr)
    return ip.is_global and not ip.is_multicast


async def resolve(host, port):
    infos = await asyncio.get_running_loop().getaddrinfo(host, port, type=socket.SOCK_STREAM)
    addrs = [i[4][0] for i in infos]
    # every answer must be public: one private answer is a rebinding attempt
    if not addrs or not all(public(a) for a in addrs):
        raise PermissionError('blocked_address')
    return addrs[0]


def log(**kw):
    sys.stdout.write(json.dumps(kw, separators=(',', ':')) + '\n')
    sys.stdout.flush()


async def pipe(reader, writer, count):
    try:
        while True:
            data = await asyncio.wait_for(reader.read(65536), IDLE)
            if not data:
                break
            count[0] += len(data)
            writer.write(data)
            await writer.drain()
    except (asyncio.TimeoutError, ConnectionError, OSError):
        pass
    finally:
        try:
            writer.close()
        except OSError:
            pass


class Proxy(object):
    def __init__(self, hosts, sources, resolver=resolve, opener=None):
        self.hosts, self.sources, self.resolver = hosts, sources, resolver
        self.opener = opener or asyncio.open_connection
        self.active = 0

    async def handle(self, reader, writer):
        t0 = time.monotonic()
        src = (writer.get_extra_info('peername') or ('?',))[0]
        rec = {'src': src, 'host': '', 'code': 0, 'up': 0, 'down': 0}

        def answer(code, reason):
            rec.update(code=code, why=reason)
            writer.write(b'HTTP/1.1 %d %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
                         % (code, reason.encode()))

        try:
            if not source_ok(src, self.sources):
                rec.update(code=403, why='source_not_allowed')
                return  # not even an answer for a stranger
            try:
                head = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 10)
                method, host, port = parse_head(head[:MAX_HEAD])
            except (asyncio.TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError, ValueError):
                return answer(400, 'bad_request')
            rec['host'] = host
            why = decide(method, host, port, self.hosts)
            if why:
                return answer(403, why)
            if self.active >= MAX_TUNNELS:
                return answer(503, 'busy')
            try:
                addr = await self.resolver(host, port)
                up_r, up_w = await asyncio.wait_for(self.opener(addr, port), CONNECT_TIMEOUT)
            except PermissionError:
                return answer(403, 'blocked_address')
            except (OSError, asyncio.TimeoutError):
                return answer(502, 'upstream_failed')
            writer.write(b'HTTP/1.1 200 Connection established\r\n\r\n')
            await writer.drain()
            rec['code'] = 200
            self.active += 1
            up, down = [0], [0]
            try:
                await asyncio.gather(pipe(reader, up_w, up), pipe(up_r, writer, down))
            finally:
                self.active -= 1
            rec.update(up=up[0], down=down[0])
        finally:
            rec['ms'] = int((time.monotonic() - t0) * 1000)
            log(**rec)
            try:
                await writer.drain()
                writer.close()
            except (ConnectionError, OSError):
                pass


async def serve(listen):
    host, _, port = listen.rpartition(':')
    hosts, sources = config()
    p = Proxy(hosts, sources)
    server = await asyncio.start_server(p.handle, host or '0.0.0.0', int(port), limit=MAX_HEAD)
    log(event='listening', listen=listen, hosts=len(hosts), sources=[str(s) for s in sources])
    async with server:
        await server.serve_forever()


def selftest():
    hosts, sources = config({})
    assert source_ok('47.106.171.142', sources) and source_ok('::ffff:47.106.171.142', sources)
    assert not source_ok('47.106.171.143', sources) and not source_ok('nonsense', sources)
    assert parse_head(b'CONNECT github.com:443 HTTP/1.1\r\nHost: github.com:443\r\n\r\n') == ('CONNECT', 'github.com', 443)
    assert parse_head(b'CONNECT GitHub.com.:443 HTTP/1.1\r\n\r\n')[1] == 'github.com'
    assert parse_head(b'GET http://github.com/ HTTP/1.1\r\n\r\n')[0] == 'GET'
    for bad in (b'CONNECT github.com HTTP/1.1\r\n\r\n', b'CONNECT [::1]:443 HTTP/1.1\r\n\r\n', b'junk\r\n\r\n'):
        try:
            parse_head(bad)
            raise AssertionError('parsed %r' % bad)
        except ValueError:
            pass
    assert decide('CONNECT', 'github.com', 443, hosts) is None
    assert decide('CONNECT', 'codeload.github.com', 443, hosts) is None
    assert decide('CONNECT', 'github.com', 22, hosts) == 'port_not_allowed'
    assert decide('CONNECT', 'evil.github.com.example', 443, hosts) == 'host_not_allowed'
    assert decide('CONNECT', 'example.com', 443, hosts) == 'host_not_allowed'
    assert decide('GET', 'github.com', 80, hosts) == 'method_not_allowed'
    for a in ('127.0.0.1', '10.0.0.1', '172.26.0.2', '169.254.169.254', '100.100.100.200', '::1', 'fd00::1'):
        assert not public(a), a
    assert public('140.82.112.3')

    async def live():
        # an upstream on loopback, reached through a resolver the test controls
        async def echo(r, w):
            w.write(await r.read(5))
            await w.drain()
            w.close()
        up = await asyncio.start_server(echo, '127.0.0.1', 0)
        uport = up.sockets[0].getsockname()[1]

        async def fake(host, port):
            if host == 'raw.githubusercontent.com':
                raise PermissionError('blocked_address')
            if host == 'api.github.com':
                raise OSError('no route')
            return '127.0.0.1'
        p = Proxy(hosts, [ipaddress.ip_network('127.0.0.0/8')], resolver=fake,
                  opener=lambda addr, port: asyncio.open_connection(addr, uport))
        srv = await asyncio.start_server(p.handle, '127.0.0.1', 0, limit=MAX_HEAD)
        pport = srv.sockets[0].getsockname()[1]

        async def ask(req, payload=b''):
            r, w = await asyncio.open_connection('127.0.0.1', pport)
            w.write(req + payload)
            await w.drain()
            try:
                out = await asyncio.wait_for(r.read(), 5)
            except ConnectionResetError:
                out = b''
            w.close()
            return out
        out = await ask(b'CONNECT api.github.com:443 HTTP/1.1\r\n\r\n')
        assert out.startswith(b'HTTP/1.1 502 upstream_failed'), out
        out = await ask(b'CONNECT example.com:443 HTTP/1.1\r\n\r\n')
        assert out.startswith(b'HTTP/1.1 403 host_not_allowed'), out
        out = await ask(b'CONNECT raw.githubusercontent.com:443 HTTP/1.1\r\n\r\n')
        assert out.startswith(b'HTTP/1.1 403 blocked_address'), out
        out = await ask(b'GET http://github.com/ HTTP/1.1\r\n\r\n')
        assert out.startswith(b'HTTP/1.1 403 method_not_allowed'), out
        # a real round trip, to the echo server's port
        out = await ask(b'CONNECT github.com:443 HTTP/1.1\r\n\r\n', b'hello')
        assert out == b'HTTP/1.1 200 Connection established\r\n\r\nhello', out
        # a stranger gets nothing at all
        p.sources = [ipaddress.ip_network('192.0.2.0/24')]
        out = await ask(b'CONNECT github.com:443 HTTP/1.1\r\n\r\n')
        assert out == b'', out
        srv.close()
        up.close()
    sys.stdout = open(os.devnull, 'w')
    try:
        asyncio.run(live())
    finally:
        sys.stdout = sys.__stdout__
    print('gh-relay selftest: ok')
    return 0


if __name__ == '__main__':
    if sys.argv[1:] == ['--selftest']:
        sys.exit(selftest())
    asyncio.run(serve(os.environ.get('GH_RELAY_LISTEN', '0.0.0.0:3128')))
