#!/usr/bin/env python3
"""fleet-peerlink-fake-ssh.py — a stand-in `ssh` for the peerlink tests (issue #3002):
bin/fleet-peerlink-selftest.sh and bin/fleet-break-it-peerlink-selftest.sh point
FLEET_PEERLINK_SSH at it. No network, no sshd: a master is a process serving a unix
socket at its `-S` path, and every other call talks to that socket, as ssh's own
multiplexing does.

  -M -N -S <sock> -l <login> [-o CertificateFile=<f>] <host>   a master: refuses when
        $FAKESSH_DIR/down/<host> exists or the certificate file holds an epoch already
        past (checked ONCE, at the handshake — like sshd); answers `id -un` with
        $FAKESSH_DIR/login/<host> when that exists (a master logged in as someone
        else), else <login>. Logs `master <host> <login> <pid>` to $FAKESSH_DIR/log.
  -S <sock> -O check|exit <host>      ssh's control commands
  -S <sock> [...] <host> <cmd...>     a channel on the master (`id -un`, `true`, anything)
"""
import os
import signal
import socket
import sys
import threading
import time

WITH_ARG = set("SolipOFLRDJWbcemw")


def parse(argv):
    o = {"opts": [], "flags": set(), "cmd": []}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a.startswith("-") and len(a) >= 2 and "host" not in o:
            for j, c in enumerate(a[1:]):
                if c in WITH_ARG:
                    v = a[j + 2:] or (argv[i + 1] if i + 1 < len(argv) else "")
                    if not a[j + 2:]:
                        i += 1
                    if c == "o":
                        o["opts"].append(v)
                    else:
                        o[c] = v
                    break
                o["flags"].add(c)
            i += 1
            continue
        if "host" not in o:
            o["host"] = a
        else:
            o["cmd"].append(a)
        i += 1
    return o


def d(*p):
    return os.path.join(os.environ.get("FAKESSH_DIR", "/tmp"), *p)


def log(line):
    try:
        with open(d("log"), "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def talk(sock, msg):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(sock)
    s.sendall((msg + "\n").encode())
    buf = b""
    while True:
        b = s.recv(4096)
        if not b:
            break
        buf += b
    s.close()
    return buf.decode()


def master(o):
    host, sock = o.get("host", ""), o.get("S", "")
    login = o.get("l") or os.environ.get("USER", "")
    if os.path.exists(d("down", host)):
        sys.stderr.write("ssh: connect to host %s port 22: Connection refused\n" % host)
        return 255
    for opt in o["opts"]:
        if opt.startswith("CertificateFile="):
            try:
                exp = float(open(opt.split("=", 1)[1]).read().strip())
            except (OSError, ValueError):
                exp = 0
            if exp < time.time():
                sys.stderr.write("%s@%s: Permission denied (certificate expired).\n" % (login, host))
                return 255
    try:
        login = open(d("login", host)).read().strip() or login
    except OSError:
        pass
    if os.path.exists(sock):
        sys.stderr.write("ControlSocket %s already exists, disabling multiplexing\n" % sock)
        return 255
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock)
    srv.listen(16)
    ino = os.stat(sock).st_ino
    log("master %s %s %d" % (host, login, os.getpid()))

    def bye(*_):
        try:
            if os.stat(sock).st_ino == ino:
                os.unlink(sock)
        except OSError:
            pass
        os._exit(0)

    signal.signal(signal.SIGTERM, bye)
    signal.signal(signal.SIGINT, bye)

    def serve(c):
        try:
            line = c.makefile().readline().strip()
            if line == "check":
                c.sendall(("pid %d\n" % os.getpid()).encode())
            elif line == "exit":
                c.sendall(b"ok\n")
                c.close()
                bye()
            elif line.startswith("run "):
                cmd = line[4:]
                log("channel %s %s %s" % (host, login, cmd))
                if cmd == "id -un":
                    c.sendall(("0\n%s\n" % login).encode())
                elif cmd == "false":
                    c.sendall(b"1\n")
                else:
                    c.sendall(("0\nran %s\n" % cmd).encode())
        except OSError:
            pass
        finally:
            try:
                c.close()
            except OSError:
                pass

    while True:
        try:
            c, _ = srv.accept()
        except OSError:
            continue
        threading.Thread(target=serve, args=(c,), daemon=True).start()


def main():
    o = parse(sys.argv[1:])
    sock = o.get("S", "")
    if "M" in o["flags"]:
        return master(o)
    if "O" in o:
        try:
            r = talk(sock, o["O"])
        except OSError as e:
            sys.stderr.write("Control socket connect(%s): %s\n" % (sock, e.strerror or e))
            return 255
        if o["O"] == "check":
            sys.stderr.write("Master running (pid=%s)\n" % r.split()[1])
        else:
            sys.stderr.write("Exit request sent.\n")
        return 0
    if not sock:
        sys.stderr.write("fake ssh: only multiplexed channels here\n")
        return 255
    try:
        r = talk(sock, "run " + " ".join(o["cmd"]))
    except OSError as e:
        sys.stderr.write("Control socket connect(%s): %s\n" % (sock, e.strerror or e))
        return 255
    rc, _, out = r.partition("\n")
    sys.stdout.write(out)
    return int(rc or 255)


if __name__ == "__main__":
    sys.exit(main())
