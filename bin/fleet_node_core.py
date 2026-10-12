"""fleet_node_core.py — the root core's wire protocol and its client (issue #3555,
EPIC #3500 C13).

The core (bin/fleet-node-core.py, root) listens on ONE local socket and does only
what its fixed action table names; this module is the half every caller shares —
the table's shape (so a caller can tell a typo from a refusal), the socket path,
and `call`. The node daemon asks through it; nothing else on the machine can,
because the core checks the peer's uid before it reads a byte.

A request is one line of JSON, {"op": <name>, "args": {…}} — no other key, and
each op takes exactly its own args. A reply is one line: {"ok": true, …},
{"refused": <op>, "why": …} (outside the table: nothing ran) or {"error": …}
(inside the table, but it could not be done). `run-as` answers twice on the same
connection: {"ok": true, "pid": N} when the job starts, {"exit": rc} when it ends;
so does `machine` with action start.

FLEET_NODE_CORE=0 makes `available()` false everywhere: every caller then takes
its old road, byte for byte (共同约定 11).
"""
import json
import os
import socket
import struct
import sys

SOCK = "/var/run/fleet-node-core.sock"
MAX_LINE = 65536

# op -> {arg: type}. The core's table; also what `call` checks before it sends.
OPS = {
    "run-as": {"login": str, "job": str},
    "stop-as": {"login": str, "job": str},
    "exec-as": {"login": str, "argv": list},
    "kill": {"pid": int},
    "memguard": {"level": str},
    "power": {"profile": str},
    "switch": {"sha": str},
    "rollback": {},
    # the seated daemon's root half (#3668, EPIC #3500 C14): a machine job by its
    # NAME in the core's own table (start · stop · reload), the leftover sweep,
    # one entry-port pass, and a read-only report (table · fda · tenants · lanes)
    "machine": {"job": str, "action": str},
    "sweep": {},
    "entry": {},
    "report": {"kind": str},
    # the seated updater's root half (#3670): one step of `fleet-node-update.py
    # root <step>` from <current>/bin — outside · credsep · prune, never an argv
    "update": {"step": str},
}


def sock_path():
    return os.environ.get("FLEET_NODE_CORE_SOCK") or SOCK


def off():
    return os.environ.get("FLEET_NODE_CORE", "") == "0"


def connect(timeout=5.0):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(sock_path())
    except (OSError, socket.error):
        s.close()
        raise
    return s


def available():
    """True when the core answers here (its socket is there and takes us)."""
    if off() or not os.path.exists(sock_path()):
        return False
    # a sandbox (FLEET_NODE_TEST) reaches only a core it named itself, never the
    # machine's real one
    if os.environ.get("FLEET_NODE_TEST") == "1" and not os.environ.get("FLEET_NODE_CORE_SOCK"):
        return False
    try:
        s = connect(1.0)
    except (OSError, socket.error):
        return False
    s.close()
    return True


def read_line(s, limit=MAX_LINE):
    buf = b""
    while b"\n" not in buf:
        try:
            got = s.recv(4096)
        except socket.timeout:
            raise
        if not got:
            break
        buf += got
        if len(buf) > limit:
            raise ValueError("reply longer than %d bytes" % limit)
    line, _, rest = buf.partition(b"\n")
    return line, rest


# exec-as may carry the caller's stdin, stdout and stderr with its request line
# (SCM_RIGHTS, issue #3669): the job then runs on them, its {"ok","pid"} and
# {"exit"} come back as run-as's do, and the caller going away stops it — what
# the node program (`ccquota core-exec`) needs for a command that reads its input
# or streams its output. Exactly FDS_EXEC of them, and only on exec-as.
FDS_EXEC = 3


def read_request(s, limit=MAX_LINE):
    """(line, fds) of one request: the fds that came with its bytes (none on a
    Python without recvmsg — then a request carrying them is refused unread)."""
    buf, fds = b"", []
    while b"\n" not in buf:
        if hasattr(s, "recvmsg"):
            got, anc, _flags, _addr = s.recvmsg(4096, socket.CMSG_SPACE(8 * 4))
            for level, kind, data in anc:
                if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                    n = len(data) - len(data) % 4
                    fds.extend(struct.unpack("%di" % (n // 4), data[:n]))
        else:
            got = s.recv(4096)
        if not got:
            break
        buf += got
        if len(buf) > limit:
            for fd in fds:
                os.close(fd)
            raise ValueError("request longer than %d bytes" % limit)
    line, _, _rest = buf.partition(b"\n")
    return line, fds


class Conn(object):
    """One request on its own connection; `reply()` reads the next answer line."""

    def __init__(self, op, args, timeout=None):
        self.s = connect(5.0)
        self.s.settimeout(timeout)
        self.buf = b""
        self.s.sendall((json.dumps({"op": op, "args": args}, sort_keys=True) + "\n").encode())

    def reply(self):
        while b"\n" not in self.buf:
            got = self.s.recv(4096)
            if not got:
                if self.buf:
                    break
                return None
            self.buf += got
            if len(self.buf) > MAX_LINE * 16:
                raise ValueError("reply too long")
        line, _, self.buf = self.buf.partition(b"\n")
        try:
            r = json.loads(line.decode("utf-8", "replace"))
        except ValueError:
            return {"error": "unreadable reply"}
        return r if isinstance(r, dict) else {"error": "unreadable reply"}

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


def call(op, args, timeout=None):
    """One request, its first reply (a dict). OSError when the core is not there."""
    c = Conn(op, args, timeout)
    try:
        r = c.reply()
    finally:
        c.close()
    return r if r is not None else {"error": "the core closed the connection"}


# -- a release's bytecode (issue #3318, EPIC #3500 C6) ---------------------------
# A login imports the release's modules (fleet_view, fleet_keys, …) from root's
# <root>/<sha>/bin, where it cannot write a .pyc: every ⌘P compiled fleet_view.py
# again (283 ms against 89 ms with one). So root compiles a release's bin/ ONCE,
# after it is verified and before current points at it — the directory is
# content-addressed, the bytecode never goes stale. A .pyc is no file of the signed
# manifest: verify_release takes one only beside a listed .py, a regular file of
# the release's own owner nobody else may write (`pyc_source`); a seat never makes
# one (the core drops its __pycache__ on the copy, `private_copy`).

def pythons():
    """The interpreters that compile: this one, and /usr/bin/python3 when it is a
    different one root owns (a login's `python3` on a Mac) — never a binary another
    login could have replaced."""
    out, seen = [], set()
    for p in (sys.executable, "/usr/bin/python3"):
        try:
            real = os.path.realpath(p)
            st = os.stat(real)
        except (OSError, TypeError):
            continue
        if real in seen or (p != sys.executable and (st.st_uid != 0 or st.st_mode & 0o022)):
            continue
        seen.add(real)
        out.append(p)
    return out


def compile_release(d):
    """Compile <d>/bin with every interpreter of `pythons` -> None, or why not (the
    release stands either way: a missing .pyc is only slower)."""
    import subprocess
    b = os.path.join(d, "bin")
    if not os.path.isdir(b):
        return None
    why = []
    for py in pythons():
        try:
            p = subprocess.run([py, "-I", "-m", "compileall", "-q", b], stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
            if p.returncode != 0:
                why.append("%s: %s" % (py, (p.stdout or b"").decode("utf-8", "replace").strip()[-200:]))
        except (OSError, subprocess.SubprocessError) as e:
            why.append("%s: %s" % (py, e))
    return "; ".join(why) or None


def pyc_source(rel):
    """`<dir>/__pycache__/<mod>.<tag>.pyc` -> `<dir>/<mod>.py`, else None."""
    parts = rel.split("/")
    if len(parts) < 2 or parts[-2] != "__pycache__" or not parts[-1].endswith(".pyc"):
        return None
    mod = parts[-1][:-4].split(".")
    if len(mod) < 2 or not mod[0]:
        return None
    return "/".join(parts[:-2] + [".".join(mod[:-1]) + ".py"])
