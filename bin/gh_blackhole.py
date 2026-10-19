#!/usr/bin/env python3
"""gh_blackhole.py — the two moving parts of the GitHub black-hole drill
(issue #4840, EPIC #4839 C1). Driven by bin/gh-blackhole-selftest.sh (the
sandbox) and bin/fleet-gh-blackhole.sh run (the live drill).

  gh_blackhole.py proxy --mode hang|refuse|limit --ports N --portfile F --log F
      a local HTTP(S) proxy on N ephemeral 127.0.0.1 ports (one per drill row, so
      every row's network tries are counted apart). Every request line (a CONNECT
      or a plain GET) is one GitHub try, logged `<port>\t<first line>`; then:
        hang    accept, read, never answer — "连上不回" (the socket stays open)
        refuse  answer 502 at once — what a failed name lookup / refused
                connection looks like to the caller ("域名解析失败")
        limit   answer 403 at once — GitHub answering "no" ("额度用尽")
      Runs until killed; writes the ports (one per line, in order) to F once bound.

  gh_blackhole.py cell --cap S --out F -- <argv…>
      run one row: <argv> in its own process group, cut at S seconds (the whole
      group killed, grandchildren too). Writes `<result>\t<secs>\t<rc>` to F:
        ok  exit 0 · fail  exit ≠ 0 · hang  still running at S — cut
      How long it took is the caller's to judge. Exits 0 (the verdict is in F).

  gh_blackhole.py count --log F --port P
      how many tries the proxy logged for port P.
"""
import argparse
import os
import signal
import socket
import subprocess
import sys
import threading
import time


def proxy(a):
    socks = []
    for _ in range(a.ports):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", 0))
        s.listen(64)
        socks.append(s)
    lock = threading.Lock()
    held = []  # hang mode: keep every socket open (never answered, never closed)

    def serve(conn, port):
        try:
            conn.settimeout(10)
            buf = b""
            while b"\n" not in buf and len(buf) < 8192:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                buf += chunk
            line = buf.split(b"\n", 1)[0].decode("latin-1").strip()
            if not line:
                conn.close()
                return
            with lock:
                with open(a.log, "a", encoding="utf-8") as f:
                    f.write("%d\t%s\n" % (port, line))
            if a.mode == "hang":
                held.append(conn)
                return
            if a.mode == "limit":
                conn.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n"
                             b"X-Drill: API rate limit exceeded\r\n\r\n")
            else:
                conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n"
                             b"X-Drill: Could not resolve host\r\n\r\n")
            conn.close()
        except OSError:
            try:
                conn.close()
            except OSError:
                pass

    def accept(s):
        port = s.getsockname()[1]
        while True:
            try:
                conn, _ = s.accept()
            except OSError:
                return
            threading.Thread(target=serve, args=(conn, port), daemon=True).start()

    for s in socks:
        threading.Thread(target=accept, args=(s,), daemon=True).start()
    tmp = a.portfile + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for s in socks:
            f.write("%d\n" % s.getsockname()[1])
    os.replace(tmp, a.portfile)
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    while True:
        time.sleep(3600)


def cell(a):
    argv = a.argv[1:] if a.argv and a.argv[0] == "--" else a.argv
    t0 = time.monotonic()
    p = subprocess.Popen(argv, start_new_session=True, stdin=subprocess.DEVNULL)
    rc = None
    try:
        rc = p.wait(timeout=a.cap)
    except subprocess.TimeoutExpired:
        pass
    secs = time.monotonic() - t0
    # the whole group goes, finished or not: a row's leftovers never outlive it
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(p.pid, sig)
        except (ProcessLookupError, PermissionError):
            break
        time.sleep(0.2)
    if rc is None:
        try:
            p.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        res, rc = "hang", "-"
    else:
        res = "ok" if rc == 0 else "fail"
    with open(a.out, "w", encoding="utf-8") as f:
        f.write("%s\t%.1f\t%s\n" % (res, secs, rc))
    return 0


def count(a):
    n = 0
    try:
        with open(a.log, encoding="utf-8") as f:
            for line in f:
                if line.split("\t", 1)[0] == str(a.port):
                    n += 1
    except OSError:
        pass
    print(n)
    return 0


def main():
    ap = argparse.ArgumentParser(prog="gh_blackhole.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("proxy")
    p.add_argument("--mode", choices=("hang", "refuse", "limit"), required=True)
    p.add_argument("--ports", type=int, default=1)
    p.add_argument("--portfile", required=True)
    p.add_argument("--log", required=True)
    c = sub.add_parser("cell")
    c.add_argument("--cap", type=float, default=20)
    c.add_argument("--out", required=True)
    c.add_argument("argv", nargs=argparse.REMAINDER)
    k = sub.add_parser("count")
    k.add_argument("--log", required=True)
    k.add_argument("--port", required=True)
    a = ap.parse_args()
    return {"proxy": proxy, "cell": cell, "count": count}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
