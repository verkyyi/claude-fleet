#!/usr/bin/env python3
"""Dedicated, bounded C9 gateways: pinned DNS and exact CONNECT origins.

No environment defaults, shared proxy, upstream resolver or payload logging.
Only this test program, independently traced by the supervisor, emits gateway
metadata; the hub, node and provider applications cannot submit these counts.
"""
import asyncio
import ipaddress
import json
from pathlib import Path
import struct
import sys
import threading

from nogh_live_contract import canonical, origin, read_private, require, write_private
from nogh_live_observer import PHASES

ROOT = Path(__file__).resolve().parent
STATE = Path('/run/fleet-c9')


def github(host):
    return any(host == name or host.endswith('.' + name) for name in
               ('github.com', 'githubusercontent.com', 'githubassets.com', 'github.io'))


class Policy:
    def __init__(self, plan, role):
        self.plan, self.role = plan, role
        self.output_lock = threading.Lock()
        self.sources = {e['pod_ip']: e['role'] for e in plan['endpoints']}
        self.hosts, self.origins, self.restored_hosts = {}, {}, set()
        for route in plan['routes']:
            if not route['origin']:
                continue
            host, port = origin(route['origin'])
            self.hosts.setdefault(host, set()).add(route['ip'])
            if route['purpose'] == 'github_restored':
                self.restored_hosts.add(host)
            if route['from'] == 'proxy' and route['to'] in ('provider-origin', 'forge-origin', 'github-origin'):
                self.origins[(host, port)] = (route['ip'], 'allow_' + route['purpose'])

    def allowed_origin(self, host, port, phase):
        route = self.origins.get((host, port))
        if route and route[1] == 'allow_github_restored' and phase != 'row:A4-restored':
            return None
        return route

    def denied_category(self, host):
        return 'github_network' if github(host) else 'unknown'

    def phase(self):
        phase = (STATE / 'phase').read_text()
        require(phase in PHASES, 'GATEWAY_PHASE')
        return phase

    def record(self, source, category, before):
        require(source in self.sources, 'FOREIGN_GATEWAY_SOURCE')
        # A request crossing a phase transition contaminates both intervals.
        with self.output_lock:
            for phase in sorted({before, self.phase()}):
                value = dict(type='gateway', source=self.sources[source], category=category, phase=phase)
                sys.stdout.buffer.write(canonical(value) + b'\n')
            sys.stdout.buffer.flush()

    def dns(self, packet, source):
        before = self.phase()
        require(source in self.sources and 12 <= len(packet) <= 4096, 'DNS_INPUT')
        ident, flags, qd, an, ns, ar = struct.unpack('!6H', packet[:12])
        require(qd == 1 and not (flags & 0xF800) and an == 0 and ns == 0, 'DNS_FORMAT')
        offset, labels = 12, []
        while True:
            require(offset < len(packet), 'DNS_TRUNCATED')
            size = packet[offset]; offset += 1
            require(size <= 63 and offset + size <= len(packet), 'DNS_COMPRESSED_OR_TRUNCATED')
            if not size: break
            label = packet[offset:offset + size].decode('ascii').lower()
            require(all(c.isalnum() or c == '-' for c in label), 'DNS_LABEL')
            labels.append(label); offset += size
        require(offset + 4 <= len(packet), 'DNS_TRUNCATED')
        qtype, qclass = struct.unpack('!HH', packet[offset:offset + 4]); offset += 4
        require(qclass == 1 and qtype in (1, 28), 'DNS_TYPE')
        host = '.'.join(labels)
        addresses = self.hosts.get(host)
        if host in self.restored_hosts and before != 'row:A4-restored':
            addresses = None
        if addresses is None:
            self.record(source, 'github_network' if github(host) else 'unknown', before)
            return struct.pack('!6H', ident, 0x8183, 1, 0, 0, 0) + packet[12:offset]
        family = 4 if qtype == 1 else 6
        packed = [ipaddress.ip_address(ip).packed for ip in sorted(addresses)
                  if ipaddress.ip_address(ip).version == family]
        self.record(source, 'allow_dns', before)
        header = struct.pack('!6H', ident, 0x8180, 1, len(packed), 0, 0)
        answer = b''.join(b'\xc0\x0c' + struct.pack('!HHIH', qtype, 1, 0, len(ip)) + ip for ip in packed)
        return header + packet[12:offset] + answer


class DNSDatagram(asyncio.DatagramProtocol):
    def __init__(self, policy):
        self.policy = policy

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, packet, addr):
        try:
            self.transport.sendto(self.policy.dns(packet, addr[0]), addr)
        except Exception:
            # Malformed requests are never silently accepted as no attempts.
            if addr[0] in self.policy.sources:
                self.policy.record(addr[0], 'unknown', self.policy.phase())


async def dns_tcp(policy, reader, writer):
    source = writer.get_extra_info('peername')[0]
    try:
        size = struct.unpack('!H', await asyncio.wait_for(reader.readexactly(2), 1))[0]
        require(size <= 4096, 'DNS_LIMIT')
        packet = await asyncio.wait_for(reader.readexactly(size), 1)
        answer = policy.dns(packet, source)
        writer.write(struct.pack('!H', len(answer)) + answer); await writer.drain()
    except Exception:
        if source in policy.sources: policy.record(source, 'unknown', policy.phase())
    finally:
        writer.close()


async def serve(role):
    from nogh_live_runtime import private_process
    private_process()
    plan = read_private(STATE / 'plan.json')
    ep = next(e for e in plan['endpoints'] if e['role'] == role)
    policy = Policy(plan, role)
    # This is the explicitly isolated pod's address, never a host-wide bind.
    host = ep['pod_ip']
    incoming = {r['port'] for r in plan['routes'] if r['to'] == role}
    require(len(incoming) == 1, 'GATEWAY_PORT_AMBIGUOUS')
    port = next(iter(incoming))
    if role == 'dns':
        require(port == 53, 'DNS_PORT')
        loop = asyncio.get_running_loop()
        transport, _ = await loop.create_datagram_endpoint(lambda: DNSDatagram(policy), local_addr=(host, port))
        server = await asyncio.start_server(lambda r, w: dns_tcp(policy, r, w), host, port)
        write_private(STATE / 'gateway-ready.json', dict(role=role))
        try:
            async with server: await server.serve_forever()
        finally:
            transport.close()
    else:
        from nogh_live_http import server
        adapter = server(policy, host, port, ep['tls_cert_digest'])
        write_private(STATE / 'gateway-ready.json', dict(role=role))
        try:
            await asyncio.to_thread(adapter.serve_forever, poll_interval=0.1)
        finally:
            adapter.server_close()


if __name__ == '__main__':
    try:
        require(len(sys.argv) == 2 and sys.argv[1] in ('dns', 'proxy'), 'GATEWAY_ROLE')
        asyncio.run(serve(sys.argv[1]))
    except BaseException:
        sys.exit(125)
