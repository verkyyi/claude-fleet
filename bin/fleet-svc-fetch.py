#!/usr/bin/python3 -I
"""Read one public HTTP(S) page, with bounded redirects, bytes and time.

DNS is checked at every redirect and the connection uses the checked address;
HTTPS still verifies the original hostname. No proxy, cookies or credentials.
"""
import http.client
import ipaddress
import socket
import ssl
import sys
import time
import urllib.parse

MAX_BYTES = 2 * 1024 * 1024


def public_addresses(host, port):
    addresses = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    if not addresses:
        raise ValueError('host has no address')
    for _, _, _, _, address in addresses:
        ip = ipaddress.ip_address(address[0])
        if not ip.is_global or ip.is_multicast or getattr(ip, 'ipv4_mapped', None):
            raise ValueError('non-public address refused')
    return addresses


def fetch(url):
    deadline = time.monotonic() + 30
    for _ in range(6):
        target = urllib.parse.urlsplit(url)
        if target.scheme not in ('http', 'https') or not target.hostname or target.username or target.password:
            raise ValueError('only public HTTP(S) URLs without credentials are accepted')
        port = target.port or (443 if target.scheme == 'https' else 80)
        addresses = public_addresses(target.hostname, port)
        left = deadline - time.monotonic()
        if left <= 0:
            raise TimeoutError('fetch deadline exceeded')
        family, kind, proto, _, address = addresses[0]
        sock = socket.socket(family, kind, proto)
        conn = http.client.HTTPConnection(target.hostname, port, timeout=left)
        try:
            sock.settimeout(left)
            sock.connect(address)
            if target.scheme == 'https':
                sock = ssl.create_default_context().wrap_socket(sock, server_hostname=target.hostname)
            conn.sock = sock
            path = urllib.parse.urlunsplit(('', '', target.path or '/', target.query, ''))
            conn.request('GET', path, headers={'User-Agent': 'Fleet-Report-Reader/1', 'Accept-Encoding': 'identity'})
            response = conn.getresponse()
            if response.status in (301, 302, 303, 307, 308):
                location = response.getheader('Location')
                if not location:
                    raise ValueError('redirect without location')
                url = urllib.parse.urljoin(url, location)
                continue
            if response.status != 200:
                raise ValueError('HTTP %d' % response.status)
            if response.getheader('Content-Encoding', 'identity').lower() != 'identity':
                raise ValueError('compressed response refused')
            chunks, size = [], 0
            while True:
                left = deadline - time.monotonic()
                if left <= 0:
                    raise TimeoutError('fetch deadline exceeded')
                sock.settimeout(left)
                chunk = response.read1(min(65536, MAX_BYTES + 1 - size))
                if not chunk:
                    return b''.join(chunks)
                size += len(chunk)
                if size > MAX_BYTES:
                    raise ValueError('response exceeds 2 MB')
                chunks.append(chunk)
        finally:
            conn.close()
            sock.close()
    raise ValueError('too many redirects')


if __name__ == '__main__':
    try:
        if len(sys.argv) != 2:
            raise ValueError('usage: fleet-svc-fetch.py URL')
        sys.stdout.buffer.write(fetch(sys.argv[1]))
    except (OSError, ValueError, http.client.HTTPException):
        # URLs may themselves contain secrets; never echo them or exception text.
        print('page fetch refused or unavailable', file=sys.stderr)
        sys.exit(1)
