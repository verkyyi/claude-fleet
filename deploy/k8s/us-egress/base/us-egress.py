#!/usr/bin/env python3
"""Authenticated outbound reverse CONNECT bridge for a private US egress host.

The ACK side exposes only the WebSocket path through the existing TLS ingress.
The US host initiates all connections, so home-router port forwarding is unnecessary.
No TLS inspection. Secrets are read at startup; neither headers nor payloads are logged.
Requires websockets==12.0. Gateway/client listen endpoints are separate.
"""
import asyncio
import contextlib
import hmac
import http
import ipaddress
import json
import os
import socket
import sys
import time
from urllib.parse import urlsplit

import websockets

PATH = "/_fleet/us-egress"
DOMAINS = (".anthropic.com .claude.ai .claude.com .claudeusercontent.com "
           ".claudemcpcontent.com http-intake.logs.us5.datadoghq.com "
           "browser-intake-us5-datadoghq.com storage.googleapis.com "
           ".github.com .githubusercontent.com ghcr.io registry.npmjs.org formulae.brew.sh")
MAX_HEAD = 8192
IDLE = 600
CONNECT_TIMEOUT = 12


def allowed(host, patterns=None):
    host = host.lower().rstrip(".")
    for p in (patterns or DOMAINS).split():
        if host == p.lstrip(".") or (p.startswith(".") and host.endswith(p)):
            return True
    return False


def target(text, patterns=None):
    host, sep, port = text.rpartition(":")
    if not sep or port != "443" or not allowed(host, patterns):
        raise ValueError("target_not_allowed")
    return host.lower().rstrip("."), 443


def token():
    value = os.environ.get("FLEET_US_EGRESS_TOKEN", "")
    if len(value) < 32:
        raise ValueError("FLEET_US_EGRESS_TOKEN must be supplied at startup")
    return value


def log(**fields):
    print(json.dumps(fields, separators=(",", ":")), flush=True)


async def connect_public(host, port):
    loop = asyncio.get_running_loop()
    infos = await loop.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    # Reject mixed public/private answers as well as private-only answers.
    if not infos or any(not ipaddress.ip_address(i[4][0]).is_global
                        or ipaddress.ip_address(i[4][0]).is_multicast for i in infos):
        raise PermissionError("non_public_target")
    # Race validated numeric addresses. A slow IPv6 route must not hold the
    # usable IPv4 route behind a full connection timeout. No second DNS lookup.
    async def dial(info, delay):
        await asyncio.sleep(delay)
        sock = socket.socket(info[0], info[1], info[2])
        sock.setblocking(False)
        try:
            await loop.sock_connect(sock, info[4])
            return await asyncio.open_connection(sock=sock)
        except BaseException:
            sock.close()
            raise

    tasks = [asyncio.create_task(dial(info, i * 0.25)) for i, info in enumerate(infos)]
    winner = None
    async def first():
        nonlocal winner
        last = OSError("no_public_route")
        for task in asyncio.as_completed(tasks):
            try:
                winner = await task
                return winner
            except OSError as e:
                last = e
        raise last
    try:
        return await asyncio.wait_for(first(), CONNECT_TIMEOUT)
    finally:
        for task in tasks:
            if not task.done():
                task.cancel()
        results = await asyncio.gather(*tasks, return_exceptions=True)
        for result in results:
            if isinstance(result, tuple) and result is not winner:
                result[1].close()


async def bridge(reader, writer, ws):
    async def outbound():
        while True:
            data = await asyncio.wait_for(reader.read(65536), IDLE)
            if not data:
                return
            await ws.send(data)

    async def inbound():
        async for data in ws:
            if not isinstance(data, bytes):
                raise ValueError("unexpected_control_frame")
            writer.write(data)
            await writer.drain()

    tasks = [asyncio.create_task(outbound()), asyncio.create_task(inbound())]
    try:
        done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for t in done:
            t.result()
    finally:
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        writer.close()
        with contextlib.suppress(Exception):
            await writer.wait_closed()
        await ws.close()


class Gateway:
    def __init__(self, secret, sources, patterns=DOMAINS):
        self.secret = secret
        self.sources = [ipaddress.ip_network(p) for p in sources.split()]
        self.patterns = patterns
        self.queue = asyncio.Queue(maxsize=128)
        self.connected = set()

    async def process_request(self, path, headers):
        if path == "/livez":
            return http.HTTPStatus.OK, [], b"alive\n"
        if path == "/healthz":
            code = http.HTTPStatus.OK if self.connected else http.HTTPStatus.SERVICE_UNAVAILABLE
            return code, [], b"ready\n" if self.connected else b"no_us_connector\n"
        if path != PATH:
            return http.HTTPStatus.NOT_FOUND, [], b"not_found\n"
        if not hmac.compare_digest(headers.get("Authorization", ""), "Bearer " + self.secret):
            return http.HTTPStatus.FORBIDDEN, [], b"forbidden\n"
        return None

    async def connector(self, ws, path):
        if len(self.connected) >= 128:
            await ws.close(code=1013, reason="connector_limit")
            return
        self.connected.add(ws)
        try:
            await self.queue.put(ws)
            started = time.monotonic()
            pong = await ws.ping()
            await asyncio.wait_for(pong, 15)
            log(event="us_link_rtt", ms=round((time.monotonic() - started) * 1000, 1))
            await ws.wait_closed()
        finally:
            self.connected.discard(ws)

    async def take(self):
        async def available():
            while True:
                ws = await self.queue.get()
                if not ws.closed:
                    return ws
        return await asyncio.wait_for(available(), 4)

    async def handle(self, reader, writer):
        ws = None
        code = 0
        host = ""
        started = time.monotonic()
        src = (writer.get_extra_info("peername") or ("",))[0]
        try:
            if not any(ipaddress.ip_address(src) in net for net in self.sources):
                return
            head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 8)
            if len(head) > MAX_HEAD:
                raise ValueError("header_too_large")
            line = head.split(b"\r\n", 1)[0].decode("ascii").split()
            if len(line) != 3 or line[0] != "CONNECT" or line[2] not in ("HTTP/1.0", "HTTP/1.1"):
                raise ValueError("connect_required")
            host, port = target(line[1], self.patterns)
            ws = await self.take()
            await ws.send(host + ":" + str(port))
            reply = await asyncio.wait_for(ws.recv(), CONNECT_TIMEOUT + 2)
            if reply != "OK":
                raise OSError("us_connect_failed")
            code = 200
            writer.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
            await writer.drain()
            await bridge(reader, writer, ws)
        except ValueError:
            code = 403
        except (OSError, asyncio.TimeoutError, websockets.exceptions.WebSocketException):
            if code != 200:
                code = 502
        except (asyncio.IncompleteReadError, asyncio.LimitOverrunError):
            code = 400
        finally:
            if code and code != 200:
                with contextlib.suppress(Exception):
                    writer.write(("HTTP/1.1 %d Egress unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" % code).encode())
                    await writer.drain()
            writer.close()
            if ws is not None:
                await ws.close()
            log(src=src, host=host, code=code, ms=round((time.monotonic()-started)*1000))


async def gateway():
    g = Gateway(token(), os.environ.get("FLEET_US_EGRESS_SOURCES", "172.20.0.0/16"),
                os.environ.get("FLEET_US_EGRESS_DOMAINS", DOMAINS))
    tcp_host, tcp_port = os.environ.get("FLEET_US_EGRESS_LISTEN", "127.0.0.1:3128").rsplit(":", 1)
    ws_host, ws_port = os.environ.get("FLEET_US_EGRESS_WS_LISTEN", "127.0.0.1:8090").rsplit(":", 1)
    srv = await asyncio.start_server(g.handle, tcp_host, int(tcp_port), limit=MAX_HEAD)
    async with srv, websockets.serve(g.connector, ws_host, int(ws_port),
                                    process_request=g.process_request, max_size=65536,
                                    max_queue=4, compression=None, ping_interval=20, ping_timeout=20):
        log(event="gateway_ready")
        await srv.serve_forever()


async def client():
    url = os.environ["FLEET_US_EGRESS_URL"]
    if urlsplit(url).scheme != "wss":
        raise ValueError("client requires authenticated TLS (wss)")
    secret = token()
    patterns = os.environ.get("FLEET_US_EGRESS_DOMAINS", DOMAINS)
    pool = int(os.environ.get("FLEET_US_EGRESS_CONNECTIONS", "16"))
    if not 1 <= pool <= 128:
        raise ValueError("connections must be 1..128")

    async def lane():
        delay = 1
        while True:
            try:
                async with websockets.connect(url, extra_headers={"Authorization": "Bearer " + secret},
                                              max_size=65536, compression=None,
                                              max_queue=4,
                                              ping_interval=20, ping_timeout=20,
                                              open_timeout=15) as ws:
                    delay = 1
                    text = await ws.recv()
                    if not isinstance(text, str):
                        raise ValueError("missing_target")
                    host, port = target(text, patterns)
                    try:
                        reader, writer = await connect_public(host, port)
                    except (OSError, asyncio.TimeoutError, PermissionError):
                        await ws.send("ERR")
                        continue
                    await ws.send("OK")
                    await bridge(reader, writer, ws)
            except (OSError, asyncio.TimeoutError, ValueError, websockets.exceptions.WebSocketException) as e:
                log(event="connector_retry", error=type(e).__name__,
                    status=getattr(e, "status_code", None))
                await asyncio.sleep(delay)
                delay = min(30, delay * 2)
    log(event="us_connector_start", connections=pool)
    await asyncio.gather(*(lane() for _ in range(pool)))


if __name__ == "__main__":
    if sys.argv[1:] not in (["gateway"], ["client"]):
        sys.exit("usage: us-egress.py gateway|client")
    asyncio.run(gateway() if sys.argv[1] == "gateway" else client())
