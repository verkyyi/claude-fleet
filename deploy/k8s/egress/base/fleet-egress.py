#!/usr/bin/env python3
"""The cluster's one way out for user pods (claude-fleet#3547, EPIC #3500 C2).

An HTTP CONNECT proxy, Service `fleet-egress:3128` in fleet-workers. A user pod's
own egress guard rejects the public internet (render.py --egress-closed), so
everything a login fetches from outside — GitHub, package sources, the provider
endpoints Claude Code / Codex call besides the API, a cluster API on 6443, a
cloud log service — comes through here. It opens a tunnel ONLY:

  - for CONNECT (nothing plain, nothing decrypted),
  - from a source address in FLEET_EGRESS_SOURCES (the cluster's pod range —
    ACK's flannel enforces no NetworkPolicy, so this is the wall that holds),
  - to a host FLEET_EGRESS_ALLOW names (`name` exact, `.name` = it and every
    subdomain, `*` = any host — the default since #4311: any public host),
  - on a port FLEET_EGRESS_PORTS names (`*` = any — the default since #4311;
    the run egress, fleet-egress-run, keeps 443),
  - to an address that resolves public (never the VPC, metadata, loopback or a
    private range: every answer, so a rebinding name is refused too) — or
    through the parent FLEET_EGRESS_VIA names for that host (`PATTERN=HOST:PORT`:
    the LLM endpoints and GitHub through the US egress). A host
    FLEET_EGRESS_REQUIRE_VIA names must have such a parent (refused at start
    otherwise) and is never opened directly: the parent's refusal is ours.

Subscription traffic never comes here: a session's API calls go to the cluster
credential proxy (fleet-credproxy), which forwards them through fleet-relay.
Nothing is decrypted; one JSON line per request on stdout (src, host, via,
code, bytes each way, ms) — the per-pod ledger.

  fleet-egress.py            serve (FLEET_EGRESS_LISTEN, default 0.0.0.0:3128)
  fleet-egress.py --selftest offline checks, exit 0 = pass
"""
import asyncio
import ipaddress
import json
import os
import socket
import sys
import time

ALLOW = '*'         # FLEET_EGRESS_ALLOW: any public host (#4311); the address check below is the wall
PORTS = '*'         # FLEET_EGRESS_PORTS: any port (#4311); the run egress sets 443
SOURCES = ''        # FLEET_EGRESS_SOURCES: the cluster's own pod range (an overlay's), never a built-in
MAX_HEAD = 8192
MAX_TUNNELS = int(os.environ.get('FLEET_EGRESS_MAX', '256'))
IDLE = float(os.environ.get('FLEET_EGRESS_IDLE', '600'))
CONNECT_TIMEOUT = 15.0


def patterns(text):
    return tuple(p.strip().lower().rstrip('.') for p in text.split() if p.strip())


def match(host, pats):
    for p in pats:
        if p == '*':
            return p
        if p.startswith('.'):
            if host == p[1:] or host.endswith(p):
                return p
        elif host == p:
            return p
    return None


def config(env=os.environ):
    allow = patterns(env.get('FLEET_EGRESS_ALLOW', ALLOW))
    sources = [ipaddress.ip_network(s.strip(), strict=False)
               for s in env.get('FLEET_EGRESS_SOURCES', SOURCES).replace(',', ' ').split() if s.strip()]
    ports = env.get('FLEET_EGRESS_PORTS', PORTS).replace(',', ' ').split()
    ports = None if '*' in ports else frozenset(int(p) for p in ports)
    via = []
    for item in env.get('FLEET_EGRESS_VIA', '').split():
        pat, sep, parent = item.partition('=')
        host, _, port = parent.rpartition(':')
        if not sep or not host or not port.isdigit():
            raise ValueError('FLEET_EGRESS_VIA takes PATTERN=HOST:PORT, not %r' % item)
        via.append((pat.lower().rstrip('.'), (host, int(port))))
    # a host that must never leave from here (the LLM endpoints): refuse an
    # incomplete policy at start. An ancestor mapping covers a whole suffix; an
    # exact one cannot cover a required suffix.
    for pat in patterns(env.get('FLEET_EGRESS_REQUIRE_VIA', '')):
        if not any(p == pat or (p.startswith('.') and match(pat.lstrip('.'), (p,))) for p, _ in via):
            raise ValueError('FLEET_EGRESS_REQUIRE_VIA has no parent mapping for %s' % pat)
    return allow, sources, ports, via


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
    if not sep or not port.isdigit() or not 0 < int(port) < 65536 or host.startswith('['):
        raise ValueError('bad CONNECT target')
    return method, host.lower().rstrip('.'), int(port)


def decide(method, host, port, allow, ports):
    """None = tunnel; else the refusal reason."""
    if method != 'CONNECT':
        return 'method_not_allowed'
    if ports is not None and port not in ports:
        return 'port_not_allowed'
    if not match(host, allow):
        return 'host_not_allowed'
    return None


def parent_for(host, via):
    for pat, parent in via:
        if match(host, (pat,)):
            return parent
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


async def through_parent(opener, parent, host, port):
    """A tunnel opened by the parent proxy: CONNECT host:port there, its 200 or OSError."""
    r, w = await asyncio.wait_for(opener(*parent), CONNECT_TIMEOUT)
    w.write(b'CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n\r\n' % (host.encode(), port, host.encode(), port))
    await w.drain()
    head = await asyncio.wait_for(r.readuntil(b'\r\n\r\n'), CONNECT_TIMEOUT)
    status = head.split(b'\r\n', 1)[0].split(b' ')
    if len(status) < 2 or status[1] != b'200':
        w.close()
        raise OSError('parent said %s' % b' '.join(status[1:]).decode('latin-1'))
    return r, w


class Proxy(object):
    def __init__(self, allow, sources, ports, via=(), resolver=resolve, opener=None):
        self.allow, self.sources, self.ports, self.via = allow, sources, ports, list(via)
        self.resolver = resolver
        self.opener = opener or asyncio.open_connection
        self.active = 0

    async def handle(self, reader, writer):
        t0 = time.monotonic()
        src = (writer.get_extra_info('peername') or ('?',))[0]
        rec = {'src': src, 'host': '', 'via': '', 'code': 0, 'up': 0, 'down': 0}

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
            why = decide(method, host, port, self.allow, self.ports)
            if why:
                return answer(403, why)
            if self.active >= MAX_TUNNELS:
                return answer(503, 'busy')
            parent = parent_for(host, self.via)
            try:
                if parent:
                    rec['via'] = '%s:%d' % parent
                    up_r, up_w = await through_parent(self.opener, parent, host, port)
                else:
                    addr = await self.resolver(host, port)
                    up_r, up_w = await asyncio.wait_for(self.opener(addr, port), CONNECT_TIMEOUT)
            except PermissionError:
                return answer(403, 'blocked_address')
            except (OSError, asyncio.TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError):
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
    allow, sources, ports, via = config()
    p = Proxy(allow, sources, ports, via)
    server = await asyncio.start_server(p.handle, host or '0.0.0.0', int(port), limit=MAX_HEAD)
    if not sources:
        log(event='unconfigured', key='FLEET_EGRESS_SOURCES', note='未配置 FLEET_EGRESS_SOURCES — every source is refused')
    log(event='listening', listen=listen, allow=len(allow), ports=sorted(ports) if ports is not None else '*',
        sources=[str(s) for s in sources], via=['%s=%s:%d' % (pat, h, n) for pat, (h, n) in via])
    async with server:
        await server.serve_forever()


def check_private():
    """BREAK-IT egress-private-via-proxy (#4311): every host and port is open, yet a
    name that resolves to the VPC, the metadata address, loopback, a private or the
    cluster's range — even ONE such answer among public ones — gets 403, never a tunnel."""
    for a in ('127.0.0.1', '10.0.0.1', '172.20.3.4', '172.21.0.1', '192.168.1.1', '100.100.100.200',
              '100.64.0.1', '169.254.169.254', '0.0.0.0', '224.0.0.1', '::1', 'fd00::1', 'fe80::1'):
        assert not public(a), a
    assert public('140.82.112.3') and public('47.107.64.148')

    async def run():
        answers = {'metadata.test': ['100.100.100.200'], 'vpc.test': ['172.20.3.4'],
                   'rebind.test': ['140.82.112.3', '10.0.0.1'], '100.100.100.200': ['100.100.100.200'],
                   '127.0.0.1': ['127.0.0.1'], 'ok.test': ['140.82.112.3']}
        loop = asyncio.get_running_loop()
        orig = loop.getaddrinfo

        async def fake(host, port, **kw):
            return [(socket.AF_INET, socket.SOCK_STREAM, 6, '', (a, port)) for a in answers[host]]
        loop.getaddrinfo = fake
        try:
            for host in ('metadata.test', 'vpc.test', 'rebind.test', '100.100.100.200', '127.0.0.1'):
                for port in (443, 80, 6443):
                    try:
                        await resolve(host, port)
                        raise AssertionError('resolved %s:%d' % (host, port))
                    except PermissionError:
                        pass
            assert await resolve('ok.test', 6443) == '140.82.112.3'
        finally:
            loop.getaddrinfo = orig
    asyncio.run(run())


def check_require_via():
    """BREAK-IT egress-required-via-direct (#4311): a host FLEET_EGRESS_REQUIRE_VIA
    names (the LLM endpoints) goes through its parent on every port, never direct —
    a policy that leaves one uncovered refuses to start, and the parent's refusal is
    ours (502), the direct resolver never asked."""
    for required, mappings in (('.claude.com', 'platform.claude.com=us:3128'),
                               ('.anthropic.com', '.claude.com=us:3128'),
                               ('registry.npmjs.org', '')):
        try:
            config({'FLEET_EGRESS_REQUIRE_VIA': required, 'FLEET_EGRESS_VIA': mappings})
            raise AssertionError('incomplete mandatory route accepted: %s' % required)
        except ValueError:
            pass
    req = '.anthropic.com .claude.ai .claude.com registry.npmjs.org'
    _, _, _, via = config({'FLEET_EGRESS_REQUIRE_VIA': req,
                           'FLEET_EGRESS_VIA': ' '.join(p + '=us:3128' for p in req.split())})
    for host in ('api.anthropic.com', 'anthropic.com', 'platform.claude.com', 'claude.ai', 'registry.npmjs.org'):
        assert parent_for(host, via) == ('us', 3128), host
    assert parent_for('api.anthropic.com.evil.test', via) is None

    async def run():
        asked = []

        async def parent(r, w):
            head = await r.readuntil(b'\r\n\r\n')
            asked.append(head.split(b'\r\n', 1)[0])
            w.write(b'HTTP/1.1 502 no_us_connector\r\n\r\n')
            await w.drain()
            w.close()
        par = await asyncio.start_server(parent, '127.0.0.1', 0)
        pport = par.sockets[0].getsockname()[1]

        async def forbidden_dns(host, port):
            raise AssertionError('a mandatory parent fell back to direct DNS: %s' % host)

        def opener(addr, port):
            assert (addr, port) == ('us', 3128), (addr, port)
            return asyncio.open_connection('127.0.0.1', pport)
        p = Proxy(('*',), [ipaddress.ip_network('127.0.0.0/8')], None, via,
                  resolver=forbidden_dns, opener=opener)
        srv = await asyncio.start_server(p.handle, '127.0.0.1', 0, limit=MAX_HEAD)
        sport = srv.sockets[0].getsockname()[1]
        for target in (b'api.anthropic.com:443', b'api.anthropic.com:8443', b'claude.ai:443'):
            r, w = await asyncio.open_connection('127.0.0.1', sport)
            w.write(b'CONNECT %s HTTP/1.1\r\n\r\n' % target)
            await w.drain()
            out = await asyncio.wait_for(r.read(), 5)
            w.close()
            assert out.startswith(b'HTTP/1.1 502 upstream_failed'), (target, out)
            assert asked[-1] == b'CONNECT %s HTTP/1.1' % target, asked
        srv.close()
        par.close()
    sys.stdout = open(os.devnull, 'w')
    try:
        asyncio.run(run())
    finally:
        sys.stdout = sys.__stdout__


def selftest():
    assert config({})[1] == []          # no range given: nobody may ask
    allow, sources, ports, via = config({'FLEET_EGRESS_VIA': '.github.com=198.51.100.7:3128',
                                         'FLEET_EGRESS_SOURCES': '10.244.0.0/16'})
    assert source_ok('10.244.3.4', sources) and not source_ok('10.0.1.240', sources)
    assert not source_ok('nonsense', sources)
    assert parse_head(b'CONNECT GitHub.com.:443 HTTP/1.1\r\n\r\n') == ('CONNECT', 'github.com', 443)
    for bad in (b'CONNECT github.com HTTP/1.1\r\n\r\n', b'CONNECT [::1]:443 HTTP/1.1\r\n\r\n', b'junk\r\n\r\n'):
        try:
            parse_head(bad)
            raise AssertionError('parsed %r' % bad)
        except ValueError:
            pass
    # the default (#4311): any host, any port — CONNECT only
    assert ports is None and allow == ('*',)
    for host, port in (('api.anthropic.com', 443), ('47.107.64.148', 6443), ('example.com', 22),
                       ('k8s-log-x.cn-shenzhen.log.aliyuncs.com', 443)):
        assert decide('CONNECT', host, port, allow, ports) is None, (host, port)
    assert decide('GET', 'github.com', 80, allow, ports) == 'method_not_allowed'
    for bad in (b'CONNECT a.com:0 HTTP/1.1\r\n\r\n', b'CONNECT a.com:65536 HTTP/1.1\r\n\r\n'):
        try:
            parse_head(bad)
            raise AssertionError('parsed %r' % bad)
        except ValueError:
            pass
    # a named list still narrows: the run egress (#4005) keeps 443, an overlay may list hosts
    named, _, p443, _ = config({'FLEET_EGRESS_ALLOW': '.anthropic.com registry.npmjs.org',
                                'FLEET_EGRESS_PORTS': '443'})
    assert decide('CONNECT', 'anthropic.com', 443, named, p443) is None
    assert decide('CONNECT', 'evil-anthropic.com', 443, named, p443) == 'host_not_allowed'
    assert decide('CONNECT', 'api.anthropic.com.example', 443, named, p443) == 'host_not_allowed'
    assert decide('CONNECT', 'registry.npmjs.org', 22, named, p443) == 'port_not_allowed'
    assert decide('CONNECT', 'example.com', 22, patterns('*'), p443) == 'port_not_allowed'
    assert parent_for('codeload.github.com', via) == ('198.51.100.7', 3128)
    assert parent_for('github.com', via) == ('198.51.100.7', 3128)
    assert parent_for('api.anthropic.com', via) is None
    for b in ('nope', '.x=host', '.x=host:port'):
        try:
            config({'FLEET_EGRESS_VIA': b})
            raise AssertionError('took %r' % b)
        except ValueError:
            pass
    check_private()
    check_require_via()

    async def live():
        async def echo(r, w):
            w.write(await r.read(5))
            await w.drain()
            w.close()
        up = await asyncio.start_server(echo, '127.0.0.1', 0)
        uport = up.sockets[0].getsockname()[1]

        # a parent that answers CONNECT then echoes; it records what it was asked
        asked = []

        async def parent(r, w):
            head = await r.readuntil(b'\r\n\r\n')
            asked.append(head.split(b'\r\n', 1)[0])
            if b'denied.github.com' in head:
                w.write(b'HTTP/1.1 403 host_not_allowed\r\n\r\n')
                await w.drain()
                w.close()
                return
            w.write(b'HTTP/1.1 200 Connection established\r\n\r\n')
            w.write(await r.read(5))
            await w.drain()
            w.close()
        par = await asyncio.start_server(parent, '127.0.0.1', 0)
        pport = par.sockets[0].getsockname()[1]

        async def fake(host, port):
            if host == 'pypi.org':
                raise PermissionError('blocked_address')
            if host == 'files.pythonhosted.org':
                raise OSError('no route')
            return '127.0.0.1'

        def opener(addr, port):
            return asyncio.open_connection(addr, pport if port == 3128 else uport)
        p = Proxy(allow, [ipaddress.ip_network('127.0.0.0/8')], ports,
                  [('.github.com', ('127.0.0.1', 3128))], resolver=fake, opener=opener)
        srv = await asyncio.start_server(p.handle, '127.0.0.1', 0, limit=MAX_HEAD)
        sport = srv.sockets[0].getsockname()[1]

        async def ask(req, payload=b''):
            r, w = await asyncio.open_connection('127.0.0.1', sport)
            w.write(req + payload)
            await w.drain()
            try:
                out = await asyncio.wait_for(r.read(), 5)
            except ConnectionResetError:
                out = b''
            w.close()
            return out
        out = await ask(b'CONNECT files.pythonhosted.org:443 HTTP/1.1\r\n\r\n')
        assert out.startswith(b'HTTP/1.1 502 upstream_failed'), out
        out = await ask(b'CONNECT example.com:6443 HTTP/1.1\r\n\r\n', b'kubec')
        assert out == b'HTTP/1.1 200 Connection established\r\n\r\nkubec', out
        out = await ask(b'GET http://example.com/ HTTP/1.1\r\n\r\n')
        assert out.startswith(b'HTTP/1.1 403 method_not_allowed'), out
        out = await ask(b'CONNECT pypi.org:443 HTTP/1.1\r\n\r\n')
        assert out.startswith(b'HTTP/1.1 403 blocked_address'), out
        # direct: a real round trip to the echo server
        out = await ask(b'CONNECT api.anthropic.com:443 HTTP/1.1\r\n\r\n', b'hello')
        assert out == b'HTTP/1.1 200 Connection established\r\n\r\nhello', out
        # through the parent: it is asked for the same host, and its 200 opens the tunnel
        out = await ask(b'CONNECT codeload.github.com:443 HTTP/1.1\r\n\r\n', b'gitgo')
        assert out == b'HTTP/1.1 200 Connection established\r\n\r\ngitgo', out
        assert asked[-1] == b'CONNECT codeload.github.com:443 HTTP/1.1', asked
        # the parent's refusal is ours
        out = await ask(b'CONNECT denied.github.com:443 HTTP/1.1\r\n\r\n')
        assert out.startswith(b'HTTP/1.1 502 upstream_failed'), out
        # a stranger gets nothing at all
        p.sources = [ipaddress.ip_network('192.0.2.0/24')]
        out = await ask(b'CONNECT api.anthropic.com:443 HTTP/1.1\r\n\r\n')
        assert out == b'', out
        srv.close()
        par.close()
        up.close()
    sys.stdout = open(os.devnull, 'w')
    try:
        asyncio.run(live())
    finally:
        sys.stdout = sys.__stdout__
    print('fleet-egress selftest: ok')
    return 0


if __name__ == '__main__':
    if sys.argv[1:] == ['--selftest']:
        sys.exit(selftest())
    if sys.argv[1:2] == ['--selftest'] and sys.argv[2:] in (['private'], ['require-via']):
        (check_private if sys.argv[2] == 'private' else check_require_via)()
        print('fleet-egress selftest %s: ok' % sys.argv[2])
        sys.exit(0)
    asyncio.run(serve(os.environ.get('FLEET_EGRESS_LISTEN', '0.0.0.0:3128')))
