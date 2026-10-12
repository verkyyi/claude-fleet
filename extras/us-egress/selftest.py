#!/usr/bin/env python3
"""Offline transport tests: auth, domain isolation, binary relay, outage closure."""
import asyncio
import contextlib
import importlib.util
import ipaddress
import os
import ssl
import sys
import tempfile
import time
from unittest.mock import Mock
from unittest.mock import patch
import websockets

HERE = os.path.dirname(os.path.abspath(__file__))
s = importlib.util.spec_from_file_location("us_egress", os.path.join(HERE, "us-egress.py"))
m = importlib.util.module_from_spec(s)
s.loader.exec_module(m)

async def main():
    secret = "offline-test-secret-with-at-least-32-bytes"
    g = m.Gateway(secret, "127.0.0.0/8")
    assert m.allowed("platform.claude.com")
    assert m.allowed("mcp-proxy.anthropic.com")
    assert m.allowed("downloads.claude.ai")
    assert m.allowed("bridge.claudeusercontent.com")
    assert m.allowed("a.claudemcpcontent.com")
    assert not m.allowed("evil-anthropic.com")
    assert not m.allowed("api.anthropic.com.evil.test")
    assert m.allowed("github.com")
    assert not m.allowed("github.com.evil.test")

    async with websockets.serve(g.connector, "127.0.0.1", 0,
                                process_request=g.process_request,
                                ping_interval=None) as ws_server:
        wport = ws_server.sockets[0].getsockname()[1]
        url = "ws://127.0.0.1:%d%s" % (wport, m.PATH)
        try:
            async with websockets.connect(url):
                raise AssertionError("unauthorized connector accepted")
        except websockets.InvalidStatusCode as e:
            assert e.status_code == 403

        tcp = await asyncio.start_server(g.handle, "127.0.0.1", 0)
        port = tcp.sockets[0].getsockname()[1]
        async def request(host, payload=b""):
            r, w = await asyncio.open_connection("127.0.0.1", port)
            w.write(("CONNECT %s:443 HTTP/1.1\r\n\r\n" % host).encode())
            await w.drain()
            head = await r.readuntil(b"\r\n\r\n")
            if payload:
                w.write(payload)
                await w.drain()
                assert await r.readexactly(len(payload)) == payload
            w.close()
            await w.wait_closed()
            return head

        # A denied target never reaches the US connector.
        assert (await request("api.anthropic.com.evil.test")).startswith(b"HTTP/1.1 403")
        # No connector is a closed route, never a request to the public provider.
        assert (await request("api.anthropic.com")).startswith(b"HTTP/1.1 502")
        async def echo_connector():
            async with websockets.connect(url, extra_headers={"Authorization":"Bearer " + secret}) as ws:
                assert await ws.recv() == "api.anthropic.com:443"
                await ws.send("OK")
                data = await ws.recv()
                assert isinstance(data, bytes)
                await ws.send(data)
                await ws.wait_closed()

        task = asyncio.create_task(echo_connector())
        while not g.connected:
            await asyncio.sleep(0.01)
        data = bytes(range(256)) * 100
        assert (await request("api.anthropic.com", data)).startswith(b"HTTP/1.1 200")
        await task

        # Remote refusal yields an error, not a local DNS/direct fallback.
        async def failing_connector():
            async with websockets.connect(url, extra_headers={"Authorization":"Bearer " + secret}) as ws:
                await ws.recv()
                await ws.send("ERR")
                await ws.wait_closed()
        task = asyncio.create_task(failing_connector())
        while not g.connected:
            await asyncio.sleep(0.01)
        assert (await request("api.anthropic.com")).startswith(b"HTTP/1.1 502")
        await task
        tcp.close()
        await tcp.wait_closed()

    loop = asyncio.get_running_loop()
    async def private(*args, **kwargs):
        return [(2, 1, 6, "", ("127.0.0.1", 443))]
    with patch.object(loop, "getaddrinfo", private):
        try:
            await m.connect_public("api.anthropic.com", 443)
            raise AssertionError("private destination accepted")
        except PermissionError:
            pass
    # An IPv6 blackhole cannot impose its timeout on a working IPv4 route.
    async def dual(*args, **kwargs):
        return [(10, 1, 6, "", ("2606:4700::1111", 443, 0, 0)),
                (2, 1, 6, "", ("1.1.1.1", 443))]
    async def connect(sock, addr):
        if ":" in addr[0]:
            await asyncio.sleep(10)
    writer = Mock()
    async def stream(**kwargs):
        return object(), writer
    with patch.object(loop, "getaddrinfo", dual), patch.object(loop, "sock_connect", connect), \
            patch.object(m.asyncio, "open_connection", stream):
        start = time.monotonic()
        _, winning_writer = await m.connect_public("api.anthropic.com", 443)
        assert time.monotonic() - start < 2
        assert winning_writer is writer
        writer.close.assert_not_called()
    print("US reverse egress transport tests: PASS")

if __name__ == "__main__":
    asyncio.run(main())
