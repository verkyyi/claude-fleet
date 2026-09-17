#!/usr/bin/env python3
"""Bounded JSON-RPC over Codex's local Unix WebSocket transport (stdlib only)."""
import argparse
import base64
import hashlib
import json
import os
import socket
import struct
import sys
import time


class Client:
    def __init__(self, remote, timeout=10):
        if not remote.startswith('unix:///'):
            raise ValueError('an explicit local unix:///path endpoint is required')
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.timeout = timeout
        self.deadline = time.monotonic() + timeout
        self.sequence = 0
        try:
            self.socket.settimeout(timeout)
            self.socket.connect(remote[7:])
            key = base64.b64encode(os.urandom(16)).decode()
            self.socket.sendall(('GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n'
                'Connection: Upgrade\r\nSec-WebSocket-Key: ' + key + '\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
            headers = b''
            while not headers.endswith(b'\r\n\r\n'):
                if len(headers) > 16384:
                    raise ValueError('oversized WebSocket handshake')
                headers += self.read(1)
            expected = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            fields = dict(line.split(':', 1) for line in headers.decode().split('\r\n')[1:] if ':' in line)
            fields = {k.lower(): v.strip() for k, v in fields.items()}
            if b' 101 ' not in headers.split(b'\r\n')[0] or fields.get('sec-websocket-accept') != expected:
                raise ValueError('invalid Codex WebSocket handshake')
            self.call('initialize', {'clientInfo': {'name': 'claude_fleet', 'version': '1'},
                                     'capabilities': {'experimentalApi': True}})
            self.send({'method': 'initialized'})
        except Exception:
            self.close()
            raise

    def close(self):
        self.socket.close()

    def read(self, count):
        data = b''
        while len(data) < count:
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('Codex RPC deadline exceeded')
            self.socket.settimeout(remaining)
            chunk = self.socket.recv(count - len(data))
            if not chunk:
                raise EOFError('Codex RPC connection closed')
            data += chunk
        return data

    def frame(self, payload, opcode=1):
        length = len(payload)
        head = bytes([0x80 | opcode])
        if length < 126:
            head += bytes([0x80 | length])
        elif length < 65536:
            head += b'\xfe' + struct.pack('!H', length)
        else:
            head += b'\xff' + struct.pack('!Q', length)
        mask = os.urandom(4)
        self.socket.sendall(head + mask + bytes(value ^ mask[i % 4] for i, value in enumerate(payload)))

    def send(self, value):
        self.frame(json.dumps(value, separators=(',', ':')).encode())

    def receive(self):
        chunks = b''
        while True:
            first, second = self.read(2)
            opcode, length = first & 15, second & 127
            if length == 126:
                length = struct.unpack('!H', self.read(2))[0]
            elif length == 127:
                length = struct.unpack('!Q', self.read(8))[0]
            if length + len(chunks) > 4 * 1024 * 1024:
                raise ValueError('Codex RPC frame exceeds 4 MiB')
            mask = self.read(4) if second & 128 else None
            payload = self.read(length)
            if mask:
                payload = bytes(value ^ mask[i % 4] for i, value in enumerate(payload))
            if opcode == 8:
                raise EOFError('Codex RPC closed')
            if opcode == 9:
                self.frame(payload, 10)
                continue
            if opcode == 10:
                continue
            if opcode not in (0, 1):
                raise ValueError('unexpected Codex RPC frame')
            chunks += payload
            if first & 128:
                return json.loads(chunks)

    def call(self, method, params):
        self.deadline = time.monotonic() + self.timeout
        self.socket.settimeout(self.timeout)
        self.sequence += 1
        sequence = self.sequence
        self.send({'id': sequence, 'method': method, 'params': params})
        while True:
            data = self.receive()
            if data.get('id') != sequence or 'method' in data:
                continue
            if 'error' in data:
                raise ValueError(data['error'].get('message', 'Codex RPC error'))
            return data.get('result')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--remote', required=True)
    parser.add_argument('--method', required=True)
    parser.add_argument('--params', default='{}')
    args = parser.parse_args()
    client = None
    try:
        client = Client(args.remote)
        print(json.dumps(client.call(args.method, json.loads(args.params))))
    except (OSError, EOFError, ValueError) as exc:
        print('fleet-codex-rpc: ' + str(exc), file=sys.stderr)
        sys.exit(1)
    finally:
        if client is not None:
            client.close()
