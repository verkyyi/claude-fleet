#!/usr/bin/env python3
"""Cold park: a parked session that keeps no window and no process (step 1).

A parked window still holds a tmux window, two wrapper shells and the hold page
(fleet-park-page.py). Dozens of them make every tmux query on the login slower
(one server, one thread) and keep ~40 MB each. With FLEET_PARK_COLD=1 the idle
reaper (fleet-cleanup-idle.py) closes a park older than FLEET_PARK_COLD_AFTER
seconds — every park but the FLEET_PARK_WARM newest on the fleet — after the
same live checks as a retention reap, writing `cold.json` beside the park's
saved screen first. The conversation's ID stays open (no `closed`), so a wake
reopens the same ID: `fleet-id.sh reopen <fid> --exec` with
FLEET_PARK_RESTORE_FID, which lands the new wrapper straight in park_hold (the
saved screen, no agent) and then takes the wake as any parked window does.

    fleet_park_cold.py take --fid F [--sid S]   the wrapper's: rc 0 = a cold park
                                                of F (and S) was waiting; it is
                                                consumed, hold the window parked
    fleet_park_cold.py warm --fid F             reopen F's window if it is cold;
                                                rc 0 once the window holds parked
    fleet_park_cold.py status --fid F           the record, or rc 1

No FLEET_PARK_COLD (or 0) ⇒ nothing is written and every reader is a no-op —
byte for byte as before. BREAK-IT `park-cold-wake`.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
import fleet_session_gate as gate  # noqa: E402

NAME = "cold.json"


def enabled():
    return os.environ.get("FLEET_PARK_COLD", "0") == "1"


def env_int(name, default, low=0):
    try:
        return max(low, int(os.environ.get(name, "") or default))
    except ValueError:
        return default


def after():
    """Seconds parked before a park goes cold (≥ 60)."""
    return env_int("FLEET_PARK_COLD_AFTER", 1800, 60)


def warm_keep():
    """How many of the newest parks on a fleet stay warm (a window kept)."""
    return env_int("FLEET_PARK_WARM", 10, 0)


def path(fid):
    if not gate.FID_RE.fullmatch(fid or ""):
        raise ValueError("invalid session identity")
    return gate.fid_dir(fid) / NAME


def read(fid):
    try:
        r = json.loads(path(fid).read_text())
    except (OSError, ValueError):
        return None
    return r if isinstance(r, dict) and r.get("fid") == fid else None


def write(fid, record):
    p = path(fid)
    r = dict(record, v=1, fid=fid, at=int(time.time()))
    tmp = p.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(r, f)
    tmp.replace(p)
    return r


def clear(fid):
    try:
        path(fid).unlink()
    except (OSError, ValueError):
        pass


def due(parks, now=None):
    """The fids to cool, from [(fid, park_since)] of one fleet's held parks:
    every park but the warm_keep() newest, parked at least after() seconds."""
    now = int(time.time()) if now is None else now
    ranked = sorted((p for p in parks if gate.FID_RE.fullmatch(p[0] or "")),
                    key=lambda p: p[1], reverse=True)
    return [fid for fid, since in ranked[warm_keep():] if since and now - since >= after()]


def take(fid, sid=""):
    """The wrapper's check (FLEET_PARK_RESTORE_FID): a cold park of this fid —
    and, when both say one, this conversation — waits for its window."""
    r = read(fid)
    if not r:
        return False
    if sid and r.get("sid") and r["sid"] != sid:
        return False
    clear(fid)
    return True


def warm(fid, wait=None):
    """Reopen a cold park's window into park_hold; True once it holds."""
    if gate.window(fid) is not None:
        return True
    r = read(fid)
    if not r:
        return False
    wait = env_int("FLEET_PARK_COLD_WAKE_SECS", 20, 1) if wait is None else wait
    env = dict(os.environ, FLEET_PARK_RESTORE_FID=fid)
    if r.get("session"):
        env.update(FLEET_SESSION=r["session"], TARGET_SESS=r["session"])
    seam = os.environ.get("FLEET_PARK_COLD_REOPEN_CMD")
    argv = seam.split() + [fid] if seam else ["bash", str(BIN / "fleet-id.sh"), "reopen", fid, "--exec"]
    try:
        p = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=max(30, wait),
                           stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError) as exc:
        gate_log(fid, "cold-warm-failed", str(exc))
        return False
    if p.returncode != 0:
        gate_log(fid, "cold-warm-failed", (p.stderr or p.stdout).strip()[-200:])
        return False
    end = time.monotonic() + wait
    while time.monotonic() < end:
        w = gate.window(fid)
        if w is not None and w.get("park_held"):
            gate_log(fid, "cold-warm", "")
            return True
        time.sleep(0.2)
    gate_log(fid, "cold-warm-timeout", "")
    return False


def gate_log(fid, event, detail):
    try:
        d = gate.conf_dir() / "logs"
        d.mkdir(parents=True, exist_ok=True)
        with (d / "park.ndjson").open("a") as f:
            f.write(json.dumps(dict(ts=time.time(), fid=fid, event=event, detail=detail)) + "\n")
    except OSError:
        pass


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    p.add_argument("command", choices=("take", "warm", "status"))
    p.add_argument("--fid", required=True)
    p.add_argument("--sid", default="")
    a = p.parse_args()
    if not gate.FID_RE.fullmatch(a.fid):
        return 2
    if a.command == "take":
        return 0 if take(a.fid, a.sid) else 1
    if a.command == "warm":
        return 0 if warm(a.fid) else 1
    r = read(a.fid)
    if r:
        print(json.dumps(r))
    return 0 if r else 1


if __name__ == "__main__":
    raise SystemExit(main())
