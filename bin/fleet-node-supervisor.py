#!/usr/bin/env python3
"""fleet-node-supervisor.py — the machine's ONE fleet daemon (issue #2331, EPIC #2329 C3).

`com.claude-fleet.node` runs this as root under launchd (KeepAlive). It does the
machine's work ONCE, however many logins the machine carries:

  * children  — long-running programs it keeps up: the shared credential proxy
                (today's `cred-proxy-shared` launcher) and, from C5, the node
                program. A child that dies is restarted after a backoff that
                doubles on every quick death (1 s … FLEET_NODE_BACKOFF_MAX) and
                resets once it has stayed up FLEET_NODE_BACKOFF_RESET seconds.
                While a child's OLD LaunchDaemon is still installed, launchd owns
                it and this daemon only reports it (`legacy`) — 共同约定 5.
  * tasks     — the machine-level periodic jobs (diskguard, memguard, the orphan
                watchdog …), each run as at most ONE copy: a task still running
                when it is due again is skipped, and every run holds
                `locks/<task>.lock`, so a hand-run `tick` cannot double it either.
                Account-scoped jobs (collect, base-sync) are listed as `deferred`:
                C4 runs them per account, as that account.
  * sweep     — fleet plist leftovers (`*.plist.bak*`, `.pre-move`, `.retired*`,
                `.disabled*` …) in /Library/LaunchDaemons and every login's
                ~/Library/LaunchAgents are MOVED to the attic
                (`/var/db/fleet-node/attic/`), kept FLEET_NODE_ATTIC_DAYS (7) days,
                and can be put back (`attic restore <id>`). A fleet plist the
                machine's expected state (`expected.json`, written from the hub —
                C2) does not name is only REPORTED, never moved: it may be loaded.

State survives a restart: `state.json` (0644, so any login's doctor can read it)
carries every task's last run and every child's pid; a restarted supervisor ADOPTS
a child still alive from the last run instead of starting a second one.

Root only ever runs code from the root runtime (共同约定 3,
`/Library/Application Support/claude-fleet/current`), and refuses a script there
that is not root-owned or that a group / other may write.

Usage:
  fleet-node-supervisor.py run                 the daemon loop (what launchd runs)
  fleet-node-supervisor.py tick                one pass: due tasks (waited for) + the sweep
  fleet-node-supervisor.py status [--json] [--check]
                                               one line per item: what · last run · result.
                                               --check: exit 0 healthy · 1 installed but not
                                               running (stale heartbeat) · 2 not installed
  fleet-node-supervisor.py sweep [--dry-run]   the leftover sweep, now
  fleet-node-supervisor.py attic [list | restore <id> | purge]
  fleet-node-supervisor.py install | uninstall write / remove the LaunchDaemon (root)

Seams (sandbox tests, docs/BREAK-IT.md `node-supervisor-dead`):
  FLEET_NODE_STATE      /var/db/fleet-node          FLEET_NODE_LOG   /var/log/fleet-node
  FLEET_NODE_RUNTIME    /Library/Application Support/claude-fleet/current
  FLEET_NODE_DAEMON_DIR /Library/LaunchDaemons      FLEET_NODE_USERS /Users
  FLEET_NODE_TABLE      a JSON {"children": [...], "tasks": [...]} that REPLACES the
                        built-in table
  FLEET_NODE_TICK (1 s)  FLEET_NODE_BACKOFF_MAX (60)  FLEET_NODE_BACKOFF_RESET (60)
  FLEET_NODE_ATTIC_DAYS (7)  FLEET_NODE_SWEEP_EVERY (3600)  FLEET_NODE_HEARTBEAT_STALE (120)
  FLEET_NODE_LAUNCHCTL  launchctl's path ('' = do not load/unload)
  FLEET_NODE_TEST=1     skip the root-ownership check on the runtime
"""
from __future__ import print_function

import errno
import fcntl
import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import time

LABEL = "com.claude-fleet.node"
# A fleet plist name, and a LEFTOVER of one: anything after `.plist`.
FLEET_PLIST_RE = re.compile(r"^(com\.claude-fleet\.|com\.ccquota\.)")
LEFTOVER_RE = re.compile(r"^(com\.claude-fleet\.|com\.ccquota\.).*\.plist\..+$")


def env(name, default):
    v = os.environ.get(name)
    return default if v is None or v == "" else v


def env_num(name, default):
    try:
        return float(env(name, default))
    except ValueError:
        return float(default)


class Paths(object):
    def __init__(self):
        self.state = env("FLEET_NODE_STATE", "/var/db/fleet-node")
        self.log = env("FLEET_NODE_LOG", "/var/log/fleet-node")
        self.runtime = env("FLEET_NODE_RUNTIME", "/Library/Application Support/claude-fleet/current")
        self.daemon_dir = env("FLEET_NODE_DAEMON_DIR", "/Library/LaunchDaemons")
        self.users = env("FLEET_NODE_USERS", "/Users")
        self.state_file = os.path.join(self.state, "state.json")
        self.attic = os.path.join(self.state, "attic")
        self.attic_index = os.path.join(self.attic, "index.json")
        self.locks = os.path.join(self.state, "locks")
        self.main_lock = os.path.join(self.state, "supervisor.lock")
        self.expected = os.path.join(self.state, "expected.json")
        self.plist = os.path.join(self.daemon_dir, LABEL + ".plist")


def now():
    return time.time()


def iso(t):
    if not t:
        return "-"
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def ago(t):
    if not t:
        return "-"
    s = int(max(0, now() - t))
    if s < 120:
        return "%ds" % s
    if s < 7200:
        return "%dm" % (s // 60)
    if s < 172800:
        return "%dh" % (s // 3600)
    return "%dd" % (s // 86400)


def write_json(path, obj, mode=0o644):
    d = os.path.dirname(path)
    tmp = os.path.join(d, ".%s.%d" % (os.path.basename(path), os.getpid()))
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=1, sort_keys=True)
        f.write("\n")
    os.chmod(tmp, mode)
    os.rename(tmp, path)


def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (IOError, OSError, ValueError):
        return default


def pid_alive(pid):
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
    except OSError as e:
        return e.errno == errno.EPERM
    return True


def pid_cmd(pid):
    try:
        return subprocess.check_output(["ps", "-o", "command=", "-p", str(int(pid))],
                                       stderr=subprocess.DEVNULL).decode("utf-8", "replace").strip()
    except Exception:
        return ""


def trusted(path, as_root=None):
    """Root runs only a root-owned script no group / other may write, in a dir
    likewise. Off under FLEET_NODE_TEST, and for a non-root supervisor."""
    if as_root is None:
        as_root = os.geteuid() == 0 and env("FLEET_NODE_TEST", "") != "1"
    if not as_root:
        return os.path.exists(path)
    p = os.path.realpath(path)
    while True:
        try:
            st = os.stat(p)
        except OSError:
            return False
        if st.st_uid != 0 or st.st_mode & 0o022:
            return False
        parent = os.path.dirname(p)
        if parent == p:
            return True
        p = parent


# --------------------------------------------------------------- the table -----
def default_table(paths):
    rt_bin = os.path.join(paths.runtime, "bin")
    cred_lib = env("FLEET_CREDSEP_LIB", "/Library/Application Support/claude-fleet/credsep")
    launcher = os.path.join(cred_lib, "fleet-credsep-launch.py")
    return {
        "children": [
            {"name": "cred-proxy-shared",
             "cmd": ["/usr/bin/python3", "-I", launcher, "shared"],
             "legacy": "com.claude-fleet.cred-proxy-shared"},
            # C5 (#2333) fills in the one node program for every login.
            {"name": "node-agent", "cmd": [], "note": "C5 #2333"},
        ],
        "tasks": [
            # --watch runs the orphan watchdog too; it is its own task below, all
            # users at once, so it is switched off here (one copy).
            {"name": "diskguard", "every": 60,
             "cmd": ["/bin/bash", os.path.join(rt_bin, "fleet-diskguard.sh"), "--watch"],
             "env": {"FLEET_ORPHAN_CPU_PCT": "0"}},
            {"name": "memguard", "every": 10,
             "cmd": ["/bin/bash", os.path.join(rt_bin, "fleet-memguard.sh"), "--once"]},
            {"name": "orphans", "every": 60,
             "cmd": ["/bin/bash", os.path.join(rt_bin, "fleet-diskguard.sh"), "--orphan-watch"],
             "env": {"FLEET_ORPHAN_ALL_USERS": "1"}},
            {"name": "collect", "scope": "account", "note": "C4 #2332"},
            {"name": "base-sync", "scope": "account", "note": "C4 #2332"},
        ],
    }


def load_table(paths):
    path = os.environ.get("FLEET_NODE_TABLE")
    if path:
        t = read_json(path, None)
        if not isinstance(t, dict):
            raise SystemExit("fleet-node-supervisor: FLEET_NODE_TABLE %s is not a JSON object" % path)
        t.setdefault("children", [])
        t.setdefault("tasks", [])
        return t
    return default_table(paths)


# --------------------------------------------------------------- the daemon -----
class Supervisor(object):
    def __init__(self, paths, table):
        self.p = paths
        self.table = table
        self.state = read_json(paths.state_file, {})
        self.state.setdefault("version", 1)
        self.state.setdefault("tasks", {})
        self.state.setdefault("children", {})
        self.state.setdefault("sweep", {})
        self.procs = {}       # child name -> Popen (started by us)
        self.adopted = {}     # child name -> pid (left alive by an earlier run)
        self.running = {}     # task name -> (Popen, lock fd, t0, log fh)
        self.dirty = True
        self.stop = False
        self.backoff_max = env_num("FLEET_NODE_BACKOFF_MAX", 60)
        self.backoff_reset = env_num("FLEET_NODE_BACKOFF_RESET", 60)
        self.last_save = 0

    # -- plumbing
    def ensure_dirs(self):
        for d, m in ((self.p.state, 0o755), (self.p.locks, 0o755), (self.p.attic, 0o700),
                     (self.p.log, 0o755), (os.path.join(self.p.log, "tasks"), 0o755),
                     (os.path.join(self.p.state, "home"), 0o700),
                     (os.path.join(self.p.state, "conf"), 0o700),
                     (os.path.join(self.p.state, "tmp"), 0o700)):
            if not os.path.isdir(d):
                os.makedirs(d)
                os.chmod(d, m)

    def save(self, force=False):
        t = now()
        if not force and not self.dirty and t - self.last_save < 15:
            return
        self.state["supervisor"] = dict(self.state.get("supervisor") or {}, pid=os.getpid(), heartbeat=t)
        write_json(self.p.state_file, self.state)
        self.dirty = False
        self.last_save = t

    def log(self, msg):
        sys.stderr.write("%s %s\n" % (iso(now()), msg))
        sys.stderr.flush()

    def legacy_installed(self, label):
        return bool(label) and os.path.exists(os.path.join(self.p.daemon_dir, label + ".plist"))

    def logfile(self, name, sub=""):
        d = os.path.join(self.p.log, sub) if sub else self.p.log
        path = os.path.join(d, name + ".log")
        try:
            if os.path.getsize(path) > 1 << 20:
                os.rename(path, path + ".1")
        except OSError:
            pass
        return open(path, "ab")

    def child_env(self, extra):
        e = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "HOME": os.path.join(self.p.state, "home"),
            "FLEET_CONF_DIR": os.path.join(self.p.state, "conf"),
            "TMPDIR": os.path.join(self.p.state, "tmp"),
            "LANG": "en_US.UTF-8",
            "FLEET_NODE": "1",
        }
        for k in ("FLEET_CREDSEP_LIB",):
            if os.environ.get(k):
                e[k] = os.environ[k]
        e.update(extra or {})
        return e

    def script_of(self, cmd):
        """The file root would run: the first argv entry after an interpreter."""
        for a in cmd[1:] if len(cmd) > 1 and os.path.basename(cmd[0]) in (
                "bash", "sh", "python3", "python") else cmd[:1]:
            if not a.startswith("-"):
                return a
        return cmd[0]

    # -- children
    def adopt(self):
        for c in self.table["children"]:
            cs = self.state["children"].get(c["name"]) or {}
            pid = cs.get("pid")
            if pid and pid_alive(pid) and cs.get("cmd") and pid_cmd(pid) == cs["cmd"]:
                self.adopted[c["name"]] = int(pid)
                self.log("adopted child %s pid %s" % (c["name"], pid))

    def child_status(self, c):
        if not c.get("cmd"):
            return "pending"
        if self.legacy_installed(c.get("legacy")):
            return "legacy"
        if not trusted(self.script_of(c["cmd"])):
            return "untrusted"
        return "supervised"

    def tend_children(self):
        t = now()
        for c in self.table["children"]:
            name = c["name"]
            cs = self.state["children"].setdefault(name, {})
            st = self.child_status(c)
            if cs.get("status") != st:
                cs["status"] = st
                self.dirty = True
            if st != "supervised":
                continue
            # an adopted pid: we cannot wait() on it, so poll
            if name in self.adopted:
                if pid_alive(self.adopted[name]):
                    continue
                del self.adopted[name]
                self.died(name, cs, None, t)
                continue
            p = self.procs.get(name)
            if p is not None:
                rc = p.poll()
                if rc is None:
                    if cs.get("fails") and t - (cs.get("started") or t) >= self.backoff_reset:
                        cs["fails"] = 0
                        self.dirty = True
                    continue
                del self.procs[name]
                self.died(name, cs, rc, t)
            if t < (cs.get("next_start") or 0):
                continue
            self.start_child(c, cs, t)

    def died(self, name, cs, rc, t):
        up = t - (cs.get("started") or t)
        fails = 0 if up >= self.backoff_reset else (cs.get("fails") or 0) + 1
        delay = 0 if fails == 0 else min(self.backoff_max, 2 ** (fails - 1))
        cs.update(pid=None, last_exit=t, last_rc=rc, fails=fails, next_start=t + delay,
                  restarts=(cs.get("restarts") or 0) + 1)
        self.dirty = True
        self.log("child %s exited rc=%s after %ds; restart in %ds" % (name, rc, up, delay))

    def start_child(self, c, cs, t):
        try:
            fh = self.logfile(c["name"])
            p = subprocess.Popen(c["cmd"], stdin=subprocess.DEVNULL, stdout=fh, stderr=fh,
                                 env=self.child_env(c.get("env")), start_new_session=True,
                                 close_fds=True)
            fh.close()
        except OSError as e:
            self.died(c["name"], cs, "spawn: %s" % e, t)
            return
        self.procs[c["name"]] = p
        cs.update(pid=p.pid, started=t, cmd=pid_cmd(p.pid) or " ".join(c["cmd"]))
        self.dirty = True
        self.log("child %s started pid %d" % (c["name"], p.pid))

    def stop_children(self):
        pids = [p.pid for p in self.procs.values()] + list(self.adopted.values())
        for pid in pids:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
        deadline = now() + 5
        while now() < deadline and any(pid_alive(x) for x in pids):
            for p in self.procs.values():
                p.poll()
            time.sleep(0.1)
        for pid in pids:
            if pid_alive(pid):
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
        for c in self.procs.values():
            try:
                c.wait(timeout=1)
            except Exception:
                pass
        for name in list(self.procs) + list(self.adopted):
            self.state["children"].get(name, {})["pid"] = None
        self.procs.clear()
        self.adopted.clear()
        self.dirty = True

    # -- tasks
    def task_due(self, tk, t):
        ts = self.state["tasks"].get(tk["name"]) or {}
        return t - (ts.get("last_start") or 0) >= float(tk.get("every", 60))

    def task_runnable(self, tk):
        if tk.get("scope") == "account" or not tk.get("cmd"):
            return "deferred"
        if not trusted(self.script_of(tk["cmd"])):
            return "untrusted"
        return None

    def start_task(self, tk, t):
        name = tk["name"]
        ts = self.state["tasks"].setdefault(name, {})
        why = self.task_runnable(tk)
        if why:
            if ts.get("result") != why:
                ts["result"] = why
                self.dirty = True
            return False
        if name in self.running:
            return False
        lf = os.open(os.path.join(self.p.locks, name + ".lock"), os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(lf, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(lf)
            ts.update(result="busy", skipped=(ts.get("skipped") or 0) + 1)
            self.dirty = True
            return False
        fh = self.logfile(name, "tasks")
        fh.write(("--- %s %s\n" % (iso(t), " ".join(tk["cmd"]))).encode())
        fh.flush()
        try:
            p = subprocess.Popen(tk["cmd"], stdin=subprocess.DEVNULL, stdout=fh, stderr=fh,
                                 env=self.child_env(tk.get("env")), start_new_session=True,
                                 close_fds=True)
        except OSError as e:
            fh.close()
            os.close(lf)
            ts.update(last_start=t, last_end=t, rc=None, result="spawn failed: %s" % e)
            self.dirty = True
            return False
        self.running[name] = (p, lf, t, fh, tk)
        ts.update(last_start=t, result="running", pid=p.pid)
        self.dirty = True
        return True

    def reap_tasks(self, wait=False):
        t = now()
        for name, (p, lf, t0, fh, tk) in list(self.running.items()):
            rc = p.poll()
            limit = float(tk.get("timeout", min(600, max(30, float(tk.get("every", 60)) * 5))))
            if rc is None and t - t0 > limit:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except OSError:
                    pass
                rc = p.wait()
                result = "timeout"
            elif rc is None:
                if not wait:
                    continue
                rc = p.wait()
                result = None
            else:
                result = None
            t1 = now()
            fh.close()
            os.close(lf)
            del self.running[name]
            ts = self.state["tasks"].setdefault(name, {})
            ts.update(last_end=t1, rc=rc, duration=round(t1 - t0, 2), pid=None,
                      runs=(ts.get("runs") or 0) + 1,
                      result=result or ("ok" if rc == 0 else "failed"))
            self.dirty = True

    def tend_tasks(self, t):
        for tk in self.table["tasks"]:
            if self.task_due(tk, t) or self.task_runnable(tk):
                self.start_task(tk, t)
        self.reap_tasks()

    # -- sweep
    def sweep_due(self, t):
        return t - (self.state["sweep"].get("last") or 0) >= env_num("FLEET_NODE_SWEEP_EVERY", 3600)

    def do_sweep(self, dry=False):
        res = sweep(self.p, dry=dry)
        if not dry:
            sw = self.state["sweep"]
            sw.update(last=now(), moved=len(res["moved"]), extra=len(res["extra"]),
                      purged=res["purged"], total_moved=(sw.get("total_moved") or 0) + len(res["moved"]))
            self.dirty = True
        return res

    # -- loops
    def run(self):
        self.ensure_dirs()
        lk = os.open(self.p.main_lock, os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.log("another supervisor holds %s — exiting" % self.p.main_lock)
            return 3
        for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(s, self.on_signal)
        sv = self.state.get("supervisor") or {}
        self.state["supervisor"] = dict(sv, started=now(), starts=(sv.get("starts") or 0) + 1)
        # a task an earlier run left mid-flight is not running any more
        for ts in self.state["tasks"].values():
            if ts.get("result") == "running":
                ts.update(result="interrupted", pid=None)
        self.adopt()
        self.log("supervisor up pid %d (start #%d)" % (os.getpid(), self.state["supervisor"]["starts"]))
        tick = env_num("FLEET_NODE_TICK", 1)
        while not self.stop:
            t = now()
            self.tend_children()
            self.tend_tasks(t)
            if self.sweep_due(t):
                try:
                    self.do_sweep()
                except Exception as e:  # a sweep must never take the daemon down
                    self.log("sweep failed: %s" % e)
            self.save()
            time.sleep(tick)
        self.log("supervisor stopping")
        self.stop_children()
        for name, (p, lf, t0, fh, tk) in list(self.running.items()):
            try:
                os.killpg(p.pid, signal.SIGTERM)
            except OSError:
                pass
        self.reap_tasks(wait=True)
        self.save(force=True)
        return 0

    def on_signal(self, signum, frame):
        self.stop = True

    def tick_once(self):
        self.ensure_dirs()
        lk = os.open(self.p.main_lock, os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("fleet-node-supervisor: a supervisor is running (%s held) — its next pass does this"
                  % self.p.main_lock, file=sys.stderr)
            return 3
        t = now()
        for tk in self.table["tasks"]:
            if self.task_due(tk, t) or self.task_runnable(tk):
                self.start_task(tk, t)
        self.reap_tasks(wait=True)
        self.do_sweep()
        self.dirty = True
        write_json(self.p.state_file, self.state)
        return 0


# --------------------------------------------------------------- the sweep -----
def _agent_dirs(paths):
    out = [paths.daemon_dir]
    try:
        for u in sorted(os.listdir(paths.users)):
            d = os.path.join(paths.users, u, "Library", "LaunchAgents")
            if os.path.isdir(d):
                out.append(d)
    except OSError:
        pass
    return out


def _plist_label(path):
    try:
        with open(path, "rb") as f:
            return plistlib.load(f).get("Label") or ""
    except Exception:
        return ""


def sweep(paths, dry=False):
    moved, extra = [], []
    expected = read_json(paths.expected, None)
    labels = set(expected.get("labels") or []) if isinstance(expected, dict) else None
    index = read_json(paths.attic_index, [])
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    for d in _agent_dirs(paths):
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for n in names:
            src = os.path.join(d, n)
            if not os.path.isfile(src) or os.path.islink(src):
                continue
            if LEFTOVER_RE.match(n):
                ident = "%s-%d" % (stamp, len(index) + len(moved) + 1)
                dst = os.path.join(paths.attic, ident, n)
                moved.append({"id": ident, "src": src, "dst": dst})
                if not dry:
                    st = os.stat(src)
                    os.makedirs(os.path.dirname(dst), 0o700)
                    shutil.move(src, dst)
                    index.append({"id": ident, "src": src, "dst": dst, "moved": now(),
                                  "uid": st.st_uid, "gid": st.st_gid, "mode": st.st_mode & 0o7777})
            elif labels is not None and n.endswith(".plist") and FLEET_PLIST_RE.match(n):
                lb = _plist_label(src) or n[:-len(".plist")]
                if lb not in labels and lb != LABEL:
                    extra.append(src)
    purged = 0 if dry else attic_purge(paths, index)
    if not dry and (moved or purged):
        write_json(paths.attic_index, index, 0o600)
    return {"moved": moved, "extra": extra, "purged": purged}


def attic_purge(paths, index):
    keep = env_num("FLEET_NODE_ATTIC_DAYS", 7) * 86400
    t = now()
    gone = 0
    for e in list(index):
        if t - e.get("moved", t) > keep:
            shutil.rmtree(os.path.dirname(e["dst"]), ignore_errors=True)
            index.remove(e)
            gone += 1
    return gone


def attic_restore(paths, ident):
    index = read_json(paths.attic_index, [])
    for e in index:
        if e["id"] == ident:
            if os.path.exists(e["src"]):
                print("fleet-node-supervisor: %s already exists — not overwriting" % e["src"], file=sys.stderr)
                return 1
            shutil.move(e["dst"], e["src"])
            try:
                os.chown(e["src"], e["uid"], e["gid"])
            except OSError:
                pass
            os.chmod(e["src"], e["mode"])
            shutil.rmtree(os.path.dirname(e["dst"]), ignore_errors=True)
            index.remove(e)
            write_json(paths.attic_index, index, 0o600)
            print("restored %s" % e["src"])
            return 0
    print("fleet-node-supervisor: no attic entry %s (see `attic list`)" % ident, file=sys.stderr)
    return 1


# --------------------------------------------------------------- status ---------
def installed(paths):
    return os.path.exists(paths.plist) or os.path.exists(paths.state_file)


def health(paths, state):
    """(code, word): 0 ok · 1 installed but not running · 2 not installed."""
    if not installed(paths):
        return 2, "not installed"
    sv = state.get("supervisor") or {}
    stale = env_num("FLEET_NODE_HEARTBEAT_STALE", 120)
    hb = sv.get("heartbeat") or 0
    if not pid_alive(sv.get("pid")):
        return 1, "DOWN (pid %s gone, heartbeat %s ago)" % (sv.get("pid") or "-", ago(hb))
    if now() - hb > stale:
        return 1, "STALE (heartbeat %s ago)" % ago(hb)
    return 0, "ok"


def status_lines(paths, table, state):
    code, word = health(paths, state)
    sv = state.get("supervisor") or {}
    out = ["supervisor  %s · pid %s · up %s · heartbeat %s ago · starts %s"
           % (word, sv.get("pid") or "-", ago(sv.get("started")), ago(sv.get("heartbeat")),
              sv.get("starts") or 0)]
    sup = Supervisor.__new__(Supervisor)
    sup.p = paths
    for c in table["children"]:
        cs = state.get("children", {}).get(c["name"]) or {}
        st = sup.child_status(c)
        if st == "pending":
            what = "not yet (%s)" % c.get("note", "")
        elif st == "legacy":
            what = "legacy — launchd's %s still runs it" % c.get("legacy")
        elif st == "untrusted":
            what = "REFUSED — %s is not root-owned / is writable" % sup.script_of(c["cmd"])
        elif pid_alive(cs.get("pid")):
            what = "running pid %s · up %s" % (cs["pid"], ago(cs.get("started")))
        else:
            what = "down · restart at %s" % iso(cs.get("next_start"))
        out.append("child  %-18s %s · restarts %s · last exit %s rc=%s"
                   % (c["name"], what, cs.get("restarts") or 0, iso(cs.get("last_exit")), cs.get("last_rc")))
    for tk in table["tasks"]:
        ts = state.get("tasks", {}).get(tk["name"]) or {}
        if tk.get("scope") == "account" or not tk.get("cmd"):
            out.append("task   %-18s deferred — an account task (%s)" % (tk["name"], tk.get("note", "")))
            continue
        out.append("task   %-18s last %s · %s rc=%s · %ss · runs %s"
                   % (tk["name"], iso(ts.get("last_start")), ts.get("result") or "never",
                      ts.get("rc"), ts.get("duration", "-"), ts.get("runs") or 0))
    sw = state.get("sweep") or {}
    out.append("sweep  %-18s last %s · moved %s (total %s) · extra %s (report only) · attic %d entries"
               % ("leftovers", iso(sw.get("last")), sw.get("moved", 0), sw.get("total_moved", 0),
                  sw.get("extra", 0), len(read_json(paths.attic_index, []))))
    return code, out


# --------------------------------------------------------------- install --------
def plist_body(paths):
    script = os.path.join(paths.runtime, "bin", "fleet-node-supervisor.py")
    return {
        "Label": LABEL,
        "ProgramArguments": ["/usr/bin/python3", "-I", script, "run"],
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 5,
        "ProcessType": "Standard",
        "SoftResourceLimits": {"NumberOfFiles": 65536},
        "HardResourceLimits": {"NumberOfFiles": 65536},
        # root logs never land in a login's directory (EPIC #2293, credsep `rootlog`)
        "StandardOutPath": os.path.join(paths.log, "supervisor.log"),
        "StandardErrorPath": os.path.join(paths.log, "supervisor.log"),
    }


def launchctl(*args):
    lc = os.environ.get("FLEET_NODE_LAUNCHCTL", "/bin/launchctl")
    if not lc:
        return 0
    return subprocess.call([lc] + list(args), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def install(paths):
    if os.geteuid() != 0 and env("FLEET_NODE_TEST", "") != "1":
        print("fleet-node-supervisor: install writes %s — run it as root (sudo)" % paths.plist, file=sys.stderr)
        return 1
    script = os.path.join(paths.runtime, "bin", "fleet-node-supervisor.py")
    if not trusted(script):
        print("fleet-node-supervisor: %s is missing, not root-owned or writable — root runs only the root "
              "runtime (共同约定 3); stage it first" % script, file=sys.stderr)
        return 1
    Supervisor(paths, {"children": [], "tasks": []}).ensure_dirs()
    tmp = paths.plist + ".tmp-node"
    with open(tmp, "wb") as f:
        plistlib.dump(plist_body(paths), f)
    os.chmod(tmp, 0o644)
    launchctl("bootout", "system/" + LABEL)
    os.rename(tmp, paths.plist)
    rc = launchctl("bootstrap", "system", paths.plist)
    print("installed %s%s" % (paths.plist, "" if rc == 0 else " (launchctl bootstrap rc=%d)" % rc))
    return 0 if rc == 0 else 1


def uninstall(paths):
    launchctl("bootout", "system/" + LABEL)
    try:
        os.remove(paths.plist)
    except OSError:
        pass
    print("removed %s (state kept in %s)" % (paths.plist, paths.state))
    return 0


# --------------------------------------------------------------- main -----------
def main(argv):
    paths = Paths()
    cmd = argv[1] if len(argv) > 1 else "status"
    rest = argv[2:]
    if cmd in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    if cmd == "install":
        return install(paths)
    if cmd == "uninstall":
        return uninstall(paths)
    table = load_table(paths)
    if cmd == "run":
        return Supervisor(paths, table).run()
    if cmd == "tick":
        return Supervisor(paths, table).tick_once()
    if cmd == "status":
        state = read_json(paths.state_file, {})
        code, lines = status_lines(paths, table, state)
        if "--json" in rest:
            print(json.dumps({"health": code, "state": state}, indent=1, sort_keys=True))
        elif "--check" in rest:
            print(lines[0])
        else:
            print("\n".join(lines))
        return code if "--check" in rest else 0
    if cmd == "sweep":
        dry = "--dry-run" in rest
        sup = Supervisor(paths, table)
        sup.ensure_dirs()
        res = sup.do_sweep(dry=dry)
        if not dry:
            write_json(paths.state_file, sup.state)
        for m in res["moved"]:
            print("%s %s -> attic %s" % ("would move" if dry else "moved", m["src"], m["id"]))
        for x in res["extra"]:
            print("extra (not in expected.json, left in place): %s" % x)
        return 0
    if cmd == "attic":
        sub = rest[0] if rest else "list"
        if sub == "list":
            for e in read_json(paths.attic_index, []):
                print("%s  %s  moved %s" % (e["id"], e["src"], iso(e.get("moved"))))
            return 0
        if sub == "restore" and len(rest) > 1:
            return attic_restore(paths, rest[1])
        if sub == "purge":
            index = read_json(paths.attic_index, [])
            n = attic_purge(paths, index)
            write_json(paths.attic_index, index, 0o600)
            print("purged %d" % n)
            return 0
    print("usage: fleet-node-supervisor.py run|tick|status [--json|--check]|sweep [--dry-run]|"
          "attic [list|restore <id>|purge]|install|uninstall", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
