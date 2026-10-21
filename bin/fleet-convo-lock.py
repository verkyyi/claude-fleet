#!/usr/bin/env python3
"""fleet-convo-lock.py — which side holds a conversation: the terminal or WebChat
(task T810). ONE record per (agent, session id), written only here:

  $FLEET_CONF_DIR/convo-lock/<agent>-<sid>.json
    {"holder": "terminal" | "webchat", "window_fid": "…", "label": "…",
     "machine": "…", "since": "<ISO>"}

The side that holds it talks; the other reads along. Whether a side is ANSWERING
is never stored — the caller reads it live (the window's state, WebChat's own
turn), so a dead process can never leave the record stuck. No record = nobody
ever handed it over: everything as before.

  fleet-convo-lock.py path
  fleet-convo-lock.py get  --agent A --sid S              the record (JSON), or {} — rc 0
  fleet-convo-lock.py set  --agent A --sid S --holder H [--fid F] [--label L] [--machine M]
                                                          [--if-holder H0]   rc 3 when the
                                                          holder is not H0 (someone moved first)
  fleet-convo-lock.py drop --agent A --sid S
"""
import argparse
import fcntl
import json
import os
import re
import sys
import time

SID_RE = re.compile(r"^[A-Za-z0-9_-]{1,80}$")
AGENT_RE = re.compile(r"^[a-z0-9_]{1,20}$")


def lock_dir():
    conf = os.environ.get("FLEET_CONF_DIR") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config"), "claude-fleet")
    return os.path.join(conf, "convo-lock")


def record_path(agent, sid):
    if not AGENT_RE.match(agent or "") or not SID_RE.match(sid or ""):
        raise ValueError("bad agent or session id")
    return os.path.join(lock_dir(), f"{agent}-{sid}.json")


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            r = json.load(f)
        return r if isinstance(r, dict) else {}
    except (OSError, ValueError):
        return {}


class Held:
    """The directory's flock: every write is one read-modify-rename under it."""
    def __enter__(self):
        d = lock_dir()
        os.makedirs(d, mode=0o700, exist_ok=True)
        self.fd = os.open(os.path.join(d, ".lock"), os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *_):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)


def write(path, rec):
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(rec, f, ensure_ascii=False)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def main(argv=None):
    p = argparse.ArgumentParser(description="which side holds a conversation (T810)")
    p.add_argument("op", choices=["path", "get", "set", "drop"])
    p.add_argument("--agent", default="claude")
    p.add_argument("--sid", default="")
    p.add_argument("--holder", choices=["terminal", "webchat"])
    p.add_argument("--if-holder", dest="if_holder", default=None)
    p.add_argument("--fid", default=None)
    p.add_argument("--label", default=None)
    p.add_argument("--machine", default=None)
    a = p.parse_args(argv)
    if a.op == "path":
        print(lock_dir())
        return 0
    try:
        path = record_path(a.agent, a.sid)
    except ValueError as e:
        print(f"fleet-convo-lock: {e}", file=sys.stderr)
        return 2
    if a.op == "get":
        print(json.dumps(read(path), ensure_ascii=False))
        return 0
    with Held():
        cur = read(path)
        if a.if_holder is not None and cur.get("holder", "") != a.if_holder:
            print(json.dumps(cur, ensure_ascii=False))
            return 3
        if a.op == "drop":
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
            return 0
        if not a.holder:
            print("fleet-convo-lock: set needs --holder", file=sys.stderr)
            return 2
        rec = dict(cur)
        rec["holder"] = a.holder
        for k, v in (("window_fid", a.fid), ("label", a.label), ("machine", a.machine)):
            if v is not None:
                rec[k] = v
        rec["since"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        write(path, rec)
        print(json.dumps(rec, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
