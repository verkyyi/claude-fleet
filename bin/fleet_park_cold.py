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

FLEET_PARK_COLD gates creation only. Existing cold records remain recoverable
even after cooling is disabled. BREAK-IT `park-cold-wake`.
"""
import argparse
import fcntl
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


def records(session=None):
    """Every cold park of this login (of one fleet session, when named)."""
    out = []
    try:
        dirs = sorted(gate.gate_root().iterdir())
    except OSError:
        return out
    for d in dirs:
        r = read(d.name) if gate.FID_RE.fullmatch(d.name) else None
        if r and (session is None or r.get("session") == session):
            out.append(r)
    return out


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
    w = gate.window(fid)
    if w:
        for key in ("name_manual", "task_line", "pin", "born", "from_fid"):
            value = r.get(key)
            if value:
                gate.tmux(w['sock'], 'set-option', '-w', '-t', w['win'], '@' + key, str(value))
        for key, opt in (("reap", "@reap_policy"), ("source", "@session_source")):
            if r.get(key):
                gate.tmux(w['sock'], 'set-option', '-w', '-t', w['win'], opt, str(r[key]))
    clear(fid)
    return True


def restore_titles(fid, sock, win):
    """Restore before releasing the spawner's launch barrier, including old records."""
    import fleet_id
    opened = fleet_id.fold(fleet_id.read(fid))['opened']
    r = read(fid) or {}
    manual = r.get('name_manual') or (opened.get('title') if opened.get('title_source') == 'manual' else '')
    title = r.get('task_line') or (opened.get('title') if opened.get('title_source') != 'default' else '')
    for opt, value in (('@name_manual', manual), ('@task_line', title)):
        if value:
            gate.tmux(sock, 'set-option', '-w', '-t', win, opt, value)


def doctor():
    """One login's local ledgers vs actual windows; no cached remote ID is ours."""
    import fleet_id
    script = '. "$1/fleet-lib.sh"; for s in $(fleet_sockets); do fleet_lw "#{@fleet_id}" tmux -L "$s"; done'
    try:
        p = subprocess.run(['bash', '-c', script, 'cold-doctor', str(BIN)],
                           capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        print('WARN window census unavailable; retry fleet doctor --park')
        return
    live = set(p.stdout.split())
    failures = {}
    try:
        with (gate.conf_dir() / 'logs/park.ndjson').open() as log:
            for line in log:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if str(event.get('event', '')).startswith('cold-warm'):
                    failures[event.get('fid')] = event
    except OSError:
        pass
    count = 0
    for fid in fleet_id.ledger_ids():
        rec = fleet_id.fold(fleet_id.read(fid))
        if rec['closed'] is not None or fid in live:
            continue
        r = read(fid)
        fail = failures.get(fid, {})
        failed = r and bool(fail) and fail.get('event') != 'cold-warm' and fail.get('ts', 0) >= r.get('at', 0)
        if r and not failed and (not r.get('worktree') or Path(r['worktree']).is_dir()):
            continue
        reason = ('cold wake failed: ' + (fail.get('detail') or fail.get('event', 'unknown'))) if failed else (
            'cold worktree missing' if r else 'open ID has no window or cold record')
        print('WARN %s %s — %s; Restore: fleet-id.sh reopen %s --exec --rebuild' %
              (fid, rec['opened'].get('title', ''), reason, fid))
        count += 1
    if not count:
        print('INFO no orphaned open IDs or missing cold worktrees on this login')


def warm(fid, wait=None):
    """Reopen a cold park's window into park_hold; True once it holds."""
    # A separate lock: the wrapper must be free to take the gate lock while it
    # acknowledges park_hold. Concurrent select/chat/relay requests join one reopen.
    if not read(fid):
        return gate.window(fid) is not None
    wait = env_int("FLEET_PARK_COLD_WAKE_SECS", 20, 1) if wait is None else wait
    with (path(fid).parent / 'warm.lock').open('a') as lock:
        end = time.monotonic() + max(30, wait) + wait
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= end:
                    return False
                time.sleep(0.1)
        return _warm(fid, wait)


def _warm(fid, wait):
    if gate.window(fid) is not None:
        return True
    r = read(fid)
    if not r:
        return False
    env = dict(os.environ, FLEET_PARK_RESTORE_FID=fid)
    if r.get("session"):
        env.update(FLEET_SESSION=r["session"], TARGET_SESS=r["session"])
    # The requested login/fleet owns the reopen, never a caller's tmux pane.
    env.pop('TMUX', None)
    env.pop('TMUX_PANE', None)
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
    p.add_argument("command", choices=("take", "warm", "status", "titles", "doctor", "protect-worktree"))
    p.add_argument("--fid")
    p.add_argument("--sid", default="")
    p.add_argument("--session", default="")
    p.add_argument("--socket", default="")
    p.add_argument("--window", default="")
    p.add_argument("--worktree", default="")
    a = p.parse_args()
    if a.command == 'doctor':
        doctor()
        return 0
    if a.command == 'protect-worktree':
        return 0 if a.worktree and any(r.get('worktree') and Path(r['worktree']).resolve() == Path(a.worktree).resolve()
                                      for r in records()) else 1
    if not gate.FID_RE.fullmatch(a.fid or ''):
        return 2
    if a.command == 'titles':
        restore_titles(a.fid, a.socket, a.window)
        return 0
    if a.command == "take":
        return 0 if take(a.fid, a.sid) else 1
    if a.command == "warm":
        if a.session:
            r = read(a.fid)
            if not r or r.get('session') != a.session:
                return 1
        return 0 if warm(a.fid) else 1
    r = read(a.fid)
    if r:
        print(json.dumps(r))
    return 0 if r else 1


if __name__ == "__main__":
    raise SystemExit(main())
