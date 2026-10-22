#!/usr/bin/env python3
"""fleet_cred_ctl.py — the credential proxy's control socket, asked with nothing
but the standard library's lightest parts (T716).

    fleet_cred_ctl.py node-token     → `<broker url>\t<fcpn1.…>` (the hub broker)

`fleet-cred-proxy.sh node-token` answers the same, but through a bash that sources
its confs and the proxy's whole 3600-line module (argparse, http.client, ssl,
http.server): on a machine whose disk is busy that was ~6 s, paid before EVERY
hub call a start makes. This reads credsep.json's run dir, sends one line, prints
the answer — the proxy's own wire (fleet-cred-proxy.py ctl_call), nothing else.
Exit 3: no proxy answering (not separated, not running); 1: it said no. The
caller (_fleet_node_broker) falls back to the old road on anything but 0.
"""
import errno
import json
import os
import random
import socket
import sys
import time


def conf_dir():
    return os.environ.get("FLEET_CONF_DIR") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config"), "claude-fleet")


def connect(path, tries=6):
    """A connected socket, or None. A full backlog is refused at once on macOS
    (T903: a reconnect's burst of re-reads): a refused connect is tried again a
    few times, ~3 s in all, before the caller falls back."""
    for i in range(tries):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(30)
        try:
            s.connect(path)
            return s
        except OSError as e:
            s.close()
            if e.errno not in (errno.ECONNREFUSED, errno.EAGAIN) or i == tries - 1:
                return None
            time.sleep(0.1 * (2 ** i) * (0.5 + random.random()))
    return None


def ctl(op):
    conf = conf_dir()
    try:
        with open(os.path.join(conf, "credsep.json")) as f:
            run = json.load(f).get("run") or ""
    except (OSError, ValueError, AttributeError):
        return None, 3
    run = os.environ.get("FLEET_CRED_CTL_DIR") or run or os.path.join(conf, "cred-proxy")
    req = {"op": op}
    if os.environ.get("FLEET_CRED_AS"):
        req["as"] = os.environ["FLEET_CRED_AS"]
    s = connect(os.path.join(run, "ctl.sock"))
    if s is None:
        return None, 3
    try:
        s.sendall((json.dumps(req) + "\n").encode())
        buf = b""
        while b"\n" not in buf:
            d = s.recv(65536)
            if not d:
                break
            buf += d
    except OSError:
        return None, 3
    finally:
        s.close()
    try:
        res = json.loads(buf or b"{}")
    except ValueError:
        return None, 1
    return (res, 0) if res.get("ok") else (None, 1)


def main(argv):
    if argv != ["node-token"]:
        sys.stderr.write("usage: fleet_cred_ctl.py node-token\n")
        return 2
    res, rc = ctl("node-token")
    if rc:
        return rc
    try:
        print("%s\t%s" % (res["url"], res["token"]))
    except (KeyError, TypeError):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
