"""fleet_trial.py — what a trial login's guard does to its processes (claude-fleet
WACK C4), shared by the root core's `trial` op (bin/fleet-node-core.py) and the
guard's own road when no core answers (bin/fleet-trial-guard.py, as root).

  renice  every process of the uid to nice FLEET_TRIAL_NICE (10) — never lower
          one a person set higher
  pause   SIGSTOP every process of the uid (its sessions freeze; nothing is lost)
  resume  SIGCONT every process of the uid, and nice back to 0

The pids are the uid's own, read here from `ps` — a caller never names one, so
nobody can steer the action at a process of another login. uid 0 and the
caller's own uid are refused. Plain Python 3, no fleet imports: the core imports
it by path.
"""
import os
import signal
import subprocess

ACTIONS = ("renice", "pause", "resume")


def nice_level():
    v = os.environ.get("FLEET_TRIAL_NICE", "10")
    return int(v) if v.isdigit() and 0 < int(v) <= 20 else 10


def ps_rows():
    """[(pid, uid, pcpu, rss_kb, name, args)] of every process — one `ps`; name is
    the base of argv[0] (a `comm` column could hold a space). FLEET_TRIAL_PS_CMD
    (a test seam) stands in for it: its output in the same columns,
    pid uid pcpu rss args."""
    cmd = os.environ.get("FLEET_TRIAL_PS_CMD")
    argv = ["/bin/sh", "-c", cmd] if cmd else ["ps", "-A", "-ww", "-o", "pid=,uid=,pcpu=,rss=,args="]
    try:
        out = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             universal_newlines=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    rows = []
    for line in out.splitlines():
        p = line.split(None, 4)
        if len(p) < 5:
            continue
        try:
            rows.append((int(p[0]), int(p[1]), float(p[2]), int(p[3]), os.path.basename(p[4].split()[0]), p[4]))
        except ValueError:
            continue
    return rows


def uid_pids(uid, rows=None):
    return [r[0] for r in (ps_rows() if rows is None else rows) if r[1] == uid and r[0] > 1]


def act(uid, action, rows=None):
    """Do action to every process of uid: {"pids": n, "done": m}. Raises
    ValueError on a uid or action outside the rule."""
    if action not in ACTIONS:
        raise ValueError("action %r — one of %s" % (action, ", ".join(ACTIONS)))
    if isinstance(uid, bool) or not isinstance(uid, int) or uid <= 0:
        raise ValueError("uid %r is not a login's" % (uid,))
    # never the caller's own processes (a sandbox, FLEET_NODE_TEST, lists only its
    # own through FLEET_TRIAL_PS_CMD)
    if uid == os.getuid() and os.environ.get("FLEET_NODE_TEST") != "1":
        raise ValueError("uid %d is the caller's own" % uid)
    pids = uid_pids(uid, rows)
    done = 0
    for pid in pids:
        try:
            if action == "pause":
                os.kill(pid, signal.SIGSTOP)
            elif action == "resume":
                os.kill(pid, signal.SIGCONT)
                try:
                    os.setpriority(os.PRIO_PROCESS, pid, 0)
                except OSError:
                    pass  # only root lowers a nice; the SIGCONT is what counts
            else:
                if os.getpriority(os.PRIO_PROCESS, pid) < nice_level():
                    os.setpriority(os.PRIO_PROCESS, pid, nice_level())
            done += 1
        except (OSError, PermissionError):
            continue
    return {"pids": len(pids), "done": done}
