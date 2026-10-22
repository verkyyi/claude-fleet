#!/usr/bin/env python3
"""fleet-service-takeover.py — before a registered service binds its unix
socket, take it back from an orphan of the same service (task BZGP).

A service the daemon keeps up (fleet service, docs/dev/MANAGED-NODE.md §10)
exits 3 when another server already answers on its socket. When that server
is an ORPHAN of the same service — an old copy left behind by a release switch
or a dead parent (PPID 1, its argv the service's own) — the managed copy would
exit every 30 s forever («已退出·待重启» on the alert bar, 2026-10-21:
an old `server.mjs --socket` from 10-15 on the old code path). So:

    fleet-service-takeover.py --name <svc> --socket <path> [--pidfile <file>]
                              --match <argv word>… [--shell-match <argv word>…]
                              [--busy <http path>…]

  * nobody answers on <path>                ⇒ exit 0, nothing done
  * the holder is an orphan of <svc>        ⇒ TERM, wait FLEET_SERVICE_TAKEOVER_WAIT
    (PPID 1, every --match in its argv,       (10 s), then KILL; one line on stderr
    our own uid, not this process's own       naming what it stopped; exit 0
    ancestor)
  * the holder's launching SHELL is the    ⇒ the same, the holder first, then the
    orphan (task CVC4: `fleet-webchat.sh     shell if it is still there
    serve` re-parented to init, its node
    child still on the socket): the holder
    has every --match, an ancestor with
    PPID 1 has every --shell-match, both
    our uid
  * anything else (a person's own copy in a ⇒ left alone; one line naming the holder
    terminal, another managed copy, a          (pid · command · started) and the next
    holder we cannot find)                    step; exit 3

The holder is found by the pid file the server writes when it listens, else
`lsof -t <path>`. Exit 2 = usage. Seams: FLEET_SERVICE_TAKEOVER_WAIT,
FLEET_SERVICE_TAKEOVER_REAPER (a pid that counts as init).

An orphan still in the middle of something is not cut off (task WD8F: the old
web chat copy stopped mid-answer at every release and takeover). With --busy,
before the TERM the holder is asked over its own socket — `GET <path>`, the
first path that answers 200 with a JSON `busy` decides (a newer and an older
server's word: `--busy /api/busy --busy /api/state`) — and while it says busy
the takeover waits, every 2 s, at most FLEET_SERVICE_TAKEOVER_BUSY_SECS (900);
one line says it waited. No answer is not busy: an old copy that cannot say
is stopped as before.
"""
import json
import os
import signal
import socket
import subprocess
import sys
import time


def busy(path, paths):
    """The holder's own word on whether it is in the middle of something: the
    first of `paths` it answers 200 with a JSON {"busy": …} — else None."""
    for p in paths:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(3)
        try:
            s.connect(path)
            s.sendall(("GET %s HTTP/1.0\r\nHost: localhost\r\n\r\n" % p).encode())
            buf = b""
            while len(buf) < 65536:
                b = s.recv(4096)
                if not b:
                    break
                buf += b
        except OSError:
            continue
        finally:
            s.close()
        head, _, body = buf.partition(b"\r\n\r\n")
        if not head.startswith(b"HTTP/") or head.split(b" ", 2)[1:2] != [b"200"]:
            continue
        try:
            v = json.loads(body.decode("utf-8", "replace"))
        except ValueError:
            continue
        if isinstance(v, dict) and "busy" in v:
            return bool(v["busy"])
    return None


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


def reaped(pid):
    # PPID 1 = re-parented to init; a Linux sandbox whose orphans land on a
    # subreaper names it (FLEET_SERVICE_TAKEOVER_REAPER, the selftests' seam)
    return ps(pid, "ppid") in ("1", os.environ.get("FLEET_SERVICE_TAKEOVER_REAPER") or "1")


def ours(pid, words):
    args = ps(pid, "args")
    return bool(args) and all(w in args for w in words) and ps(pid, "uid") == str(os.getuid())


def orphan(pid, words, shell_words=(), me=()):
    """The pids to stop, holder first — [] when it is not an orphan of ours.
    Either the holder itself is re-parented (PPID 1, argv the service's), or
    its launching shell is (CVC4): the holder's argv is the service's and the
    nearest ancestor that init adopted carries every --shell-match."""
    if not ours(pid, words):
        return []
    if reaped(pid):
        return [pid]
    if not shell_words:
        return []
    p = pid
    for _ in range(8):
        pp = ps(p, "ppid")
        if not pp.isdigit() or int(pp) <= 1:
            return []
        p = int(pp)
        if p in me:
            return []
        if reaped(p):
            return [pid, p] if ours(p, shell_words) else []
    return []


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
    words, shell, busy_paths = [], [], []
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
        elif a == "--shell-match":
            shell.append(v)
        elif a == "--busy":
            busy_paths.append(v)
        else:
            break
    else:
        if name and sock and words:
            return run(name, sock, pidfile, words, shell, busy_paths)
    print(__doc__.split("\n\n")[2], file=sys.stderr)
    return 2


def wait_idle(name, sock, paths):
    """While the holder says it is busy, wait (bounded); True once it is not."""
    try:
        cap = float(os.environ.get("FLEET_SERVICE_TAKEOVER_BUSY_SECS") or 900)
    except ValueError:
        cap = 900.0
    t0 = time.time()
    while busy(sock, paths):
        if time.time() - t0 >= cap:
            print("fleet-service %s: %s 的旧副本忙了 %ds 还没停，不再等" % (name, sock, cap), file=sys.stderr)
            return False
        time.sleep(2)
    if time.time() - t0 >= 1:
        print("fleet-service %s: 等旧副本答完手上那一轮（%ds）再接管" % (name, time.time() - t0), file=sys.stderr)
    return True


def run(name, sock, pidfile, words, shell=(), busy_paths=()):
    if not os.path.exists(sock) or not answers(sock):
        return 0
    try:
        wait = float(os.environ.get("FLEET_SERVICE_TAKEOVER_WAIT") or 10)
    except ValueError:
        wait = 10.0
    pids = holders(sock, pidfile)
    me = ancestors()
    orph = []
    for p in pids:
        orph += [q for q in orphan(p, words, shell, me) if q not in orph]
    if not orph:
        who = " ； ".join(describe(p) for p in pids) or "找不到是哪个进程（无 pid 文件，lsof 也没看到）"
        print("fleet-service %s: %s 被占着：%s — 不是本服务的孤儿，没动它；它是手动起的就停掉它（kill <pid>），"
              "是另一个受管副本就 fleet service stop %s 只留一个" % (name, sock, who, name), file=sys.stderr)
        return 3
    if busy_paths:
        wait_idle(name, sock, busy_paths)
    for p in orph:
        if not alive(p):  # a shell that ended with its child
            continue
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
