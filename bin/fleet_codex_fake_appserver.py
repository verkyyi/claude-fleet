#!/usr/bin/env python3
"""A fixture Codex app-server for selftests (T540): the WebSocket JSON-RPC that
fleet-codex-rpc.py speaks, on a Unix socket, answering only what the fleet asks a
private TUI server — initialize, thread/loaded/list, thread/read — and able to
broadcast thread/started the way Codex 0.162 does on /clear or /new. No model, no
network, no Codex. Threads are dicts; `loaded` is the server's loaded list in order.
"""
import base64
import hashlib
import json
import os
import socket
import struct
import threading
import uuid


def uuid7(ms):
    """A UUIDv7 made at `ms` (Codex thread ids are UUIDv7)."""
    rand = int.from_bytes(os.urandom(10), "big")
    value = (ms & ((1 << 48) - 1)) << 80 | 0x7 << 76 | (rand >> 68 & 0xFFF) << 64 | 0b10 << 62 | rand & ((1 << 62) - 1)
    return str(uuid.UUID(int=value))


def tui_thread(tid, **extra):
    return dict(dict(id=tid, parentThreadId=None, ephemeral=False, originator="codex-tui",
                     status={"type": "idle"}, path="", cwd="/fixture", model="gpt-fixture"), **extra)


class FakeAppServer:
    def __init__(self, path):
        self.path = path
        self.threads, self.loaded, self.requests = {}, [], []
        self.conns, self.lock = [], threading.Lock()
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        self.sock.listen(8)
        self.remote = "unix://" + path
        threading.Thread(target=self.accept, daemon=True).start()

    def add(self, thread, broadcast=False):
        with self.lock:
            self.threads[thread["id"]] = thread
            if thread["id"] not in self.loaded:
                self.loaded.append(thread["id"])
        if broadcast:
            self.broadcast({"method": "thread/started", "params": {"thread": thread}})

    def broadcast(self, message):
        with self.lock:
            conns = list(self.conns)
        for conn in conns:
            try:
                self.send(conn, message)
            except OSError:
                pass

    def close(self):
        self.sock.close()
        with self.lock:
            for conn in self.conns:
                try:
                    conn.close()
                except OSError:
                    pass
        try:
            os.unlink(self.path)
        except OSError:
            pass

    @staticmethod
    def read(conn, n):
        data = b""
        while len(data) < n:
            chunk = conn.recv(n - len(data))
            if not chunk:
                raise EOFError
            data += chunk
        return data

    @staticmethod
    def send(conn, value):
        payload = json.dumps(value).encode()
        n = len(payload)
        head = b"\x81" + (bytes([n]) if n < 126 else b"\x7e" + struct.pack("!H", n) if n < 65536
                          else b"\x7f" + struct.pack("!Q", n))
        conn.sendall(head + payload)

    def accept(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self.serve, args=(conn,), daemon=True).start()

    def serve(self, conn):
        try:
            head = b""
            while not head.endswith(b"\r\n\r\n"):
                head += self.read(conn, 1)
            key = [l.split(b":", 1)[1].strip() for l in head.split(b"\r\n") if l.lower().startswith(b"sec-websocket-key")][0]
            accept = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
            conn.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                         b"Sec-WebSocket-Accept: " + accept + b"\r\n\r\n")
            with self.lock:
                self.conns.append(conn)
            while True:
                first, second = self.read(conn, 2)
                length = second & 127
                if length == 126:
                    length = struct.unpack("!H", self.read(conn, 2))[0]
                elif length == 127:
                    length = struct.unpack("!Q", self.read(conn, 8))[0]
                mask = self.read(conn, 4) if second & 128 else b"\0\0\0\0"
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(self.read(conn, length)))
                if first & 15 == 8:
                    return
                msg = json.loads(payload)
                if "id" not in msg:
                    continue
                self.requests.append(msg)
                method, params = msg.get("method"), msg.get("params") or {}
                with self.lock:
                    if method == "initialize":
                        result = {"userAgent": "fixture/0.162.1"}
                    elif method == "thread/loaded/list":
                        result = {"data": list(self.loaded)}
                    elif method == "thread/read" and params.get("threadId") in self.threads:
                        result = {"thread": self.threads[params["threadId"]]}
                    else:
                        result = None
                if result is None:
                    self.send(conn, {"id": msg["id"], "error": {"message": "fixture: unsupported " + str(method)}})
                else:
                    self.send(conn, {"id": msg["id"], "result": result})
        except (OSError, EOFError, ValueError, IndexError):
            pass
        finally:
            with self.lock:
                if conn in self.conns:
                    self.conns.remove(conn)
            try:
                conn.close()
            except OSError:
                pass
