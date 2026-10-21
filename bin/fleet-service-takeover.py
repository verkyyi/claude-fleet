#!/usr/bin/env python3
"""fleet-service-takeover.py — before a registered service binds its unix
socket, take it back from an orphan of the same service (task BZGP).

A service the daemon keeps up (fleet service, docs/dev/MANAGED-NODE.md §10)
exits 3 when another server already answers on its socket. When that server
is an ORPHAN of the same service — an old copy left behind by a release switch
or a dead parent (PPID 1, its argv the service's own) — the managed copy would
exit every 30 s forever («已退出·待重启» on the alert bar, mini2 2026-10-21:
an old `server.mjs --socket` from 10-15 on the old code path). So:

    fleet-service-takeover.py --name <svc> --socket <path> [--pidfile <file>]
                              --match <argv word>…

  * nobody answers on <path>                ⇒ exit 0, nothing done
  * the holder is an orphan of <svc>        ⇒ TERM, wait FLEET_SERVICE_TAKEOVER_WAIT
    (PPID 1, every --match in its argv,       (10 s), then KILL; one line on stderr
    our own uid, not this process's own       naming what it stopped; exit 0
    ancestor)
  * anything else (a person's own copy in a ⇒ left alone; one line naming the holder
    terminal, another managed copy, a          (pid · command · started) and the next
    holder we cannot find)                    step; exit 3

The holder is found by the pid file the server writes when it listens, else
`lsof -t <path>`. Exit 2 = usage. Seams: FLEET_SERVICE_TAKEOVER_WAIT,
FLEET_SERVICE_TAKEOVER_REAPER (a pid that counts as init).
"""
import os
import signal
import socket
import subprocess
import sys
import time


def answers(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2)
    try:
        s.connect(path)
        return True
    except OSError:
        return False
    finally:
        s.close()


def ps(pid, field):
    try:
        r = subprocess.run(["ps", "-o", field + "=", "-p", str(pid)], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def ancestors():
    out, p = set(), os.getpid()
    for _ in range(64):
        out.add(p)
        pp = ps(p, "ppid")
        if not pp.isdigit() or int(pp) <= 1:
            break
        p = int(pp)
    return out


def holders(path, pidfile):
    """Candidate pids holding the socket: the pid file's first, then lsof's."""
    pids = []
    if pidfile:
        try:
            t = open(pidfile).read().strip()
            if t.isdigit() and alive(int(t)):
                pids.append(int(t))
        except OSError:
            pass
    try:
        r = subprocess.run(["lsof", "-t", "--", path], capture_output=True, text=True, timeout=10)
        pids += [int(x) for x in r.stdout.split() if x.isdigit() and int(x) not in pids]
    except (OSError, subprocess.SubprocessError):
        pass
    me = ancestors()
    return [p for p in pids if p not in me]


def describe(pid):
    return "pid %d · %s · 起于 %s" % (pid, ps(pid, "args")[:300] or "?", ps(pid, "lstart") or "?")


def orphan(pid, words):
    # PPID 1 = re-parented to init; a Linux sandbox whose orphans land on a
    # subreaper names it (FLEET_SERVICE_TAKEOVER_REAPER, the selftests' seam)
    if ps(pid, "ppid") not in ("1", os.environ.get("FLEET_SERVICE_TAKEOVER_REAPER") or "1"):
        return False
    args = ps(pid, "args")
    if not args or not all(w in args for w in words):
        return False
    return ps(pid, "uid") == str(os.getuid())


def stop(pid, wait):
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return "TERM"
    end = time.time() + wait
    while time.time() < end:
        if not alive(pid):
            return "TERM"
        time.sleep(0.2)
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        return "TERM"
    for _ in range(25):
        if not alive(pid):
            break
        time.sleep(0.2)
    return "KILL"


def main(argv):
    name = sock = pidfile = None
    words = []
    it = iter(argv)
    for a in it:
        v = next(it, None)
        if v is None:
            break
        if a == "--name":
            name = v
        elif a == "--socket":
            sock = v
        elif a == "--pidfile":
            pidfile = v
        elif a == "--match":
            words.append(v)
        else:
            break
    else:
        if name and sock and words:
            return run(name, sock, pidfile, words)
    print(__doc__.split("\n\n")[2], file=sys.stderr)
    return 2


def run(name, sock, pidfile, words):
    if not os.path.exists(sock) or not answers(sock):
        return 0
    try:
        wait = float(os.environ.get("FLEET_SERVICE_TAKEOVER_WAIT") or 10)
    except ValueError:
        wait = 10.0
    pids = holders(sock, pidfile)
    orph = [p for p in pids if orphan(p, words)]
    if not orph:
        who = " ； ".join(describe(p) for p in pids) or "找不到是哪个进程（无 pid 文件，lsof 也没看到）"
        print("fleet-service %s: %s 被占着：%s — 不是本服务的孤儿，没动它；它是手动起的就停掉它（kill <pid>），"
              "是另一个受管副本就 fleet service stop %s 只留一个" % (name, sock, who, name), file=sys.stderr)
        return 3
    for p in orph:
        d = describe(p)
        how = stop(p, wait)
        print("fleet-service %s: 接管 %s：停掉了旧孤儿（%s，%s）" % (name, sock, d, how), file=sys.stderr)
    if answers(sock):
        print("fleet-service %s: %s 停掉孤儿后仍有进程在答：%s" % (name, sock, " ； ".join(describe(p) for p in holders(sock, None)) or "?"),
              file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
