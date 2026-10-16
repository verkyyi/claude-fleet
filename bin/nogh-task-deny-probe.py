#!/usr/bin/env python3
"""Positive controls inside the acceptance namespace; no payloads in evidence."""
import ctypes as c
import errno
import json
import os
from pathlib import Path
import socket
import subprocess
import sys

work = Path(sys.argv[1])
sentinel = b"PAYLOAD_MUST_NOT_APPEAR"
results = []


def denied(label, function):
    try:
        function()
    except OSError as exc:
        assert exc.errno in (errno.ENETUNREACH, errno.EHOSTUNREACH, errno.EACCES), (label, exc)
        results.append(dict(probe=label, errno=exc.errno))
    else:
        raise AssertionError(label+" unexpectedly reached an external destination")


# PATH, absolute path, a fixture override, and execveat all remain visible to
# the independent observer; only the first two use the outer deny-shim counter.
for command in (["gh", sentinel.decode()], [str(work/"shim/gh"), sentinel.decode()]):
    assert subprocess.call(command) == 91
override = work/"probe-override"
override.mkdir()
gh = override/"gh"
gh.write_text('#!/bin/sh\nexit 91\n'); gh.chmod(0o700)
assert subprocess.call(["gh", sentinel.decode()], env=dict(os.environ, PATH=str(override))) == 91
libc = c.CDLL(None, use_errno=True)
pid = os.fork()
if pid == 0:
    argv = (c.c_char_p*3)(b"gh", sentinel, None)
    env = (c.c_char_p*2)(b"PROBE_PAYLOAD="+sentinel, None)
    libc.execveat(-100, os.fsencode(gh), argv, env, 0)
    os._exit(92)
assert os.waitpid(pid, 0)[1] == 91 << 8

for family, address in ((socket.AF_INET, ("192.0.2.1", 443)), (socket.AF_INET6, ("2001:db8::1", 443))):
    with socket.socket(family, socket.SOCK_STREAM) as sock:
        sock.settimeout(1)
        denied("tcp-"+str(family), lambda: sock.connect(address))
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    denied("sendto", lambda: sock.sendto(sentinel, ("192.0.2.1", 443)))
    denied("sendmsg", lambda: sock.sendmsg([sentinel], [], 0, ("192.0.2.1", 443)))

    class Address(c.Structure):
        _fields_ = [("family", c.c_ushort), ("port", c.c_ushort), ("address", c.c_ubyte*4), ("zero", c.c_ubyte*8)]
    class Vector(c.Structure):
        _fields_ = [("base", c.c_void_p), ("length", c.c_size_t)]
    class Message(c.Structure):
        _fields_ = [("name", c.c_void_p), ("namelen", c.c_uint), ("iov", c.POINTER(Vector)),
                    ("iovlen", c.c_size_t), ("control", c.c_void_p), ("controllen", c.c_size_t), ("flags", c.c_int)]
    class Multi(c.Structure):
        _fields_ = [("header", Message), ("length", c.c_uint)]
    address = Address(socket.AF_INET, socket.htons(443), (c.c_ubyte*4)(192, 0, 2, 1))
    payload = c.create_string_buffer(sentinel)
    vector = Vector(c.cast(payload, c.c_void_p), len(sentinel))
    messages = (Multi*2)()
    for m in messages:
        m.header = Message(c.addressof(address), c.sizeof(address), c.pointer(vector), 1)
    code = libc.sendmmsg(sock.fileno(), messages, 2, 0)
    assert code == -1 and c.get_errno() == errno.ENETUNREACH
    results.append(dict(probe="sendmmsg", errno=c.get_errno()))

(work/"evidence/positive-controls.json").write_text(json.dumps(results, indent=2)+"\n")
print("PASS independent gh PATH/absolute/override/execveat; IPv4/IPv6 TCP, UDP sendto/sendmsg/sendmmsg denied")
