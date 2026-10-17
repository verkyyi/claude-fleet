#!/usr/bin/env python3
"""Real denied-access controls inside a C9 test endpoint; no fixture shim."""
import ctypes
import json
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import sys
import ssl
import urllib.parse
import urllib.request

from nogh_live_contract import Refused, read_private, require, write_private


def receive(sock, size):
    blocks = bytearray()
    while len(blocks) < size:
        part = sock.recv(size - len(blocks))
        require(part, 'DNS_TRUNCATED')
        blocks.extend(part)
    return bytes(blocks)


def allowed(plan, name):
    from nogh_live_identity import NoRedirect, reader
    if name == 'hub':
        value = reader(plan)('/version')
        commit = value.get('commit', '')
        require(isinstance(commit, str) and 7 <= len(commit) <= 40
                and plan['hub']['commit'].startswith(commit), 'HUB_CONTROL_FAILED')
        return
    request = json.loads(Path('/run/c9-control/provider-probe.json').read_bytes())
    require(set(request) == {'url', 'method', 'headers', 'body'} and request['method'] in ('GET', 'POST')
            and isinstance(request['headers'], dict), 'PROVIDER_CONTROL_INPUT')
    url = urllib.parse.urlsplit(request['url'])
    require(url.scheme == 'https' and not url.username and not url.password
            and (url.hostname, url.port or 443) in
            {(urllib.parse.urlsplit(r['origin']).hostname, r['port']) for r in plan['routes']
             if r['to'] == 'provider-origin'}, 'PROVIDER_CONTROL_ORIGIN')
    require(all(k.lower() not in ('host', 'connection', 'content-length', 'transfer-encoding', 'upgrade')
                for k in request['headers']), 'PROVIDER_CONTROL_HEADERS')
    data = request['body'].encode('utf-8')
    require(len(data) <= 65536, 'PROVIDER_CONTROL_LIMIT')
    context = ssl.create_default_context(cafile='/run/c9-credentials/ca.pem')
    opener = urllib.request.build_opener(NoRedirect(), urllib.request.HTTPSHandler(context=context))
    with opener.open(urllib.request.Request(request['url'], data=data if data else None,
                     method=request['method'], headers=request['headers']), timeout=2) as response:
        require(200 <= response.status < 300 and response.read(1), 'PROVIDER_CONTROL_FAILED')


def refused(operation):
    try:
        operation()
    except OSError:
        return
    raise ValueError('DENY_CONTROL_SUCCEEDED')


def main(name):
    plan = read_private('/run/fleet-c9/plan.json')
    probes = plan['probes']
    if name in ('hub', 'provider'):
        return allowed(plan, name)
    if name == 'identity':
        from nogh_live_identity import reader, await_ready
        await_ready(plan, reader(plan))
        return
    host4, host6 = probes['github_ipv4'], probes['github_ipv6']
    if name in ('github-v4', 'github-v6', 'proxy-bypass'):
        family = socket.AF_INET6 if name == 'github-v6' else socket.AF_INET
        host = host6 if name == 'github-v6' else probes['bypass_ipv4'] if name == 'proxy-bypass' else host4
        port = probes['bypass_port'] if name == 'proxy-bypass' else 443
        with socket.socket(family, socket.SOCK_STREAM) as sock:
            sock.settimeout(1); refused(lambda: sock.connect((host, port)))
    elif name in ('dns-udp', 'dns-tcp'):
        host = next(e['pod_ip'] for e in plan['endpoints'] if e['role'] == 'dns')
        query = struct.pack('!6H', 1234, 0x100, 1, 0, 0, 0) + b'\x03api\x06github\x03com\x00' + struct.pack('!HH', 1, 1)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM if name == 'dns-udp' else socket.SOCK_STREAM) as sock:
            sock.settimeout(1)
            if name == 'dns-udp':
                sock.sendto(query, (host, 53)); answer = sock.recv(4096)
            else:
                sock.connect((host, 53)); sock.sendall(struct.pack('!H', len(query)) + query)
                size = struct.unpack('!H', receive(sock, 2))[0]
                require(size <= 4096, 'DNS_LIMIT')
                answer = receive(sock, size)
            require(len(answer) >= 12 and answer[3] & 15 == 3, 'DNS_NOT_REFUSED')
    elif name in ('gh-path', 'gh-absolute', 'execveat', 'github-name'):
        require(Path('/usr/bin/gh').is_file(), 'GH_TOOL_MISSING')
        if name == 'github-name':
            command = ['/usr/bin/curl', '-fsS', '--connect-timeout', '1', '--max-time', '1',
                       'https://api.github.com/rate_limit']  # dist-ok: intentional denied-access control, never code distribution
        elif name == 'execveat':
            pid = os.fork()
            if pid == 0:
                libc = ctypes.CDLL(None, use_errno=True)
                argv = (ctypes.c_char_p * 4)(b'gh', b'api', b'/rate_limit', None)
                env = (ctypes.c_char_p * 1)(None)
                libc.execveat(-100, b'/usr/bin/gh', argv, env, 0)
                os._exit(126)
            _, status = os.waitpid(pid, 0)
            require(os.WIFEXITED(status) and 0 < os.WEXITSTATUS(status) < 126, 'GH_NOT_REFUSED')
            return
        else:
            command = ['gh' if name == 'gh-path' else '/usr/bin/gh', 'api', '/rate_limit']
        result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=1.5)
        require(result.returncode != 0, 'GH_NOT_REFUSED')
    elif name == 'sendmsg':
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            refused(lambda: sock.sendmsg([b'c9'], [], 0, (host4, 443)))
    elif name == 'sendmmsg':
        class Addr(ctypes.Structure):
            _fields_ = [('family', ctypes.c_ushort), ('port', ctypes.c_ushort),
                        ('addr', ctypes.c_ubyte * 4), ('zero', ctypes.c_ubyte * 8)]
        class IOV(ctypes.Structure):
            _fields_ = [('base', ctypes.c_void_p), ('length', ctypes.c_size_t)]
        class MSG(ctypes.Structure):
            _fields_ = [('name', ctypes.c_void_p), ('namelen', ctypes.c_uint), ('iov', ctypes.POINTER(IOV)),
                        ('iovlen', ctypes.c_size_t), ('control', ctypes.c_void_p),
                        ('controllen', ctypes.c_size_t), ('flags', ctypes.c_int)]
        class MMSG(ctypes.Structure):
            _fields_ = [('header', MSG), ('length', ctypes.c_uint)]
        address = Addr(socket.AF_INET, socket.htons(443), (ctypes.c_ubyte * 4)(*socket.inet_aton(host4)))
        payload = ctypes.create_string_buffer(b'c9'); iov = IOV(ctypes.addressof(payload), 2)
        message = MMSG(MSG(ctypes.addressof(address), ctypes.sizeof(address), ctypes.pointer(iov), 1, None, 0, 0), 0)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            require(ctypes.CDLL(None).sendmmsg(sock.fileno(), ctypes.byref(message), 1, 0) == -1,
                    'SENDMMSG_NOT_REFUSED')
    else:
        raise ValueError('UNKNOWN_PROBE')


if __name__ == '__main__':
    try:
        main(sys.argv[1])
    except BaseException as exc:
        # Only the fixed code (an identifier) crosses to the broker, so a live
        # control failure says WHICH check failed (#4625); never a message.
        code = str(exc) if isinstance(exc, Refused) and re.fullmatch(r'[A-Z0-9_]{1,64}', str(exc)) \
            else type(exc).__name__.upper()[:64]
        try:
            write_private(Path('/run/fleet-c9/control.refusal'), code)
        except BaseException:
            pass
        sys.exit(1)
