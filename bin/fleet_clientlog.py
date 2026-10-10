#!/usr/bin/env python3
"""fleet_clientlog — the client's own record of where it went and why it stopped
(claude-fleet#2896, EPIC #2889 C7; docs/CLIENT-LOGS.md is the contract).

Every connection, every session it asks a machine to open, every keeper renewal
and every login leaves ONE line on this computer, so a «stuck at 正在连接» is
read off the person's own disk instead of asking them to run it again:

    <dir>/connect.log  place.log  keeper.log  login.log   (+ one .1 each)

<dir> is FLEET_CLIENT_LOG_DIR, else the shell's cache (FLEET_SHELL_CACHE, else
${XDG_CACHE_HOME:-~/.cache}/claude-fleet/shell) + /logs. A file past
FLEET_CLIENT_LOG_MAX bytes (512 KiB) is renamed to <name>.1 — one old copy, the
older one gone. FLEET_CLIENT_LOG=0 writes nothing.

A line is TSV, seven fields, fields only ever added at the end:

    time(UTC, …Z)  event  machine  route(direct|relay|-)  ms  result  reason

Tabs and newlines in a field become spaces; the reason is cut at 2000 bytes (a
cut mid-character drops that character) and then every shape in
conf/secret-shapes.list is replaced by <redacted:NAME> — the same table, the
same order, as the sh writer `fleet_clientlog` in bin/fleet-client-lib.sh,
which this file is held byte for byte against (bin/client-log-selftest.sh).

Writing never fails its caller: any error is swallowed.

    fleet_clientlog.py write <kind> <event> [machine] [route] [ms] [result] [reason]
    fleet_clientlog.py redact            (stdin → stdout, one line at a time)
    fleet_clientlog.py dir               (prints the directory)
"""
import os
import re
import sys
import time

KINDS = ("connect", "place", "keeper", "login")
REASON_MAX = 2000
HERE = os.path.dirname(os.path.abspath(__file__))
SHAPES_FILE = os.path.join(os.path.dirname(HERE), "conf", "secret-shapes.list")
_shapes = None


def shapes():
    """[(name, compiled)] from conf/secret-shapes.list; none readable = []."""
    global _shapes
    if _shapes is None:
        out = []
        try:
            with open(os.environ.get("FLEET_SECRET_SHAPES") or SHAPES_FILE, encoding="utf-8") as f:
                for line in f:
                    line = line.rstrip("\n")
                    if not line or line.startswith("#") or "\t" not in line:
                        continue
                    name, pat = line.split("\t", 1)
                    try:
                        out.append((name, re.compile(pat)))
                    except re.error:
                        pass
        except OSError:
            pass
        _shapes = out
    return _shapes


def redact(text):
    for name, rx in shapes():
        text = rx.sub(lambda _m, n=name: "<redacted:%s>" % n, text)
    return text


def flat(s):
    return str(s if s is not None else "").replace("\t", " ").replace("\r", " ").replace("\n", " ")


def cut(s, limit=REASON_MAX):
    b = s.encode("utf-8", "replace")
    if len(b) <= limit:
        return s
    return b[:limit].decode("utf-8", "ignore")


def log_dir():
    d = os.environ.get("FLEET_CLIENT_LOG_DIR")
    if d:
        return d
    cache = os.environ.get("FLEET_SHELL_CACHE") or os.path.join(
        os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache"), "claude-fleet", "shell")
    return os.path.join(cache, "logs")


def log_max():
    try:
        return int(os.environ.get("FLEET_CLIENT_LOG_MAX") or 524288)
    except ValueError:
        return 524288


def rotate(path, limit=None):
    """<path> past the limit → <path>.1 (the older .1 gone)."""
    try:
        if os.path.getsize(path) >= (log_max() if limit is None else limit):
            os.replace(path, path + ".1")
    except OSError:
        pass


def line(event, machine="", route="", ms="", result="", reason=""):
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    f = [flat(x) for x in (event, machine, route, ms, result)]
    f.append(redact(cut(flat(reason))))
    return ts + "\t" + "\t".join(f) + "\n"


def write(kind, event, machine="", route="", ms="", result="", reason=""):
    if os.environ.get("FLEET_CLIENT_LOG") == "0" or kind not in KINDS:
        return
    try:
        d = log_dir()
        os.makedirs(d, mode=0o700, exist_ok=True)
        path = os.path.join(d, kind + ".log")
        rotate(path)
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, line(event, machine, route, ms, result, reason).encode("utf-8", "replace"))
        finally:
            os.close(fd)
    except Exception:  # never the caller's failure
        pass


def main(argv):
    if argv and argv[0] == "write" and len(argv) >= 3:
        write(*argv[1:9])
        return 0
    if argv and argv[0] == "redact":
        for ln in sys.stdin:
            sys.stdout.write(redact(cut(flat(ln.rstrip("\n")))) + "\n")
        return 0
    if argv and argv[0] == "dir":
        print(log_dir())
        return 0
    sys.stderr.write(__doc__.split("\n\n")[-1])
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
