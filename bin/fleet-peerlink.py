#!/usr/bin/env python3
"""fleet-peerlink.py — the home machine's standing connections to the other
machines (issue #3002, EPIC #2999 C5; 共同约定 7).

The ONE owner of every machine-to-machine ssh master on this login: only it
builds, checks and closes them. Yesterday's three ways a standing connection went
bad (#2987) are each ruled out by construction and drilled in docs/BREAK-IT.md:

  - the wrong login: every link is named (machine, login), opened with `-l <login>`,
    and checked with `id -un` on the master before it counts — a master that
    answers as anyone else (a stray one on the path included) is closed and rebuilt
    (`peerlink-wrong-login`);
  - a control file deleted under a live master: the file lives in
    $FLEET_CONF_DIR/peerlink/ (0700, never $TMPDIR), and every beat checks
    「file there · master alive · `ssh -O check` answers」 — any one off and the
    master is killed and rebuilt (`peerlink-sock-deleted`);
  - two keepers: `run` holds an flock on peerlink/.lock and re-checks every beat
    that the file it holds IS the path's — a second one exits at once, and one that
    lost its file to another quits (`peerlink-two-keepers`).

Certificates (#1626): a master is opened with the five-minute certificate
`fleet-peer-cert.sh <machine> view` hands out; it is checked only at the
handshake, so the master — and every channel opened on it later — outlives it
(`peerlink-cert-expiry`). A hub that is down opens no NEW link and never falls back
to a standing key; the links already up go on (`peerlink-hub-down`).

    run                       the keeper (KeepAlive: launchd/com.claude-fleet.peerlink,
                              or the node supervisor's account table on a managed machine)
    sock <machine> <login>    the control socket of a HEALTHY link (rc 0), else rc 1 —
                              C4 gets a socket only through this, never by a path it builds
    pane <machine> <login> <view>   the pane program of a view's window onto that machine
                              (C4): rides the link, waits for it while it is down, and
                              lands each (re)connect on the window's @peer_want / @peer_cur
    status [--check|--json]   the doctor's `peerlink` row (rc 0 ok · 1 WARN · 2 no row)

What to connect, every beat (FLEET_PEERLINK_TICK, 2 s): while this machine has a
thin view with a client attached — a row of $FLEET_CONF_DIR/remote-views/ whose kind
is `thin` and whose attach pid lives (C1) — one link per (machine, login) the hub's
session table (global/remote_<sess>) shows your sessions on, this machine's own login
excepted; a lost machine is not asked. A link no longer wanted closes
FLEET_PEERLINK_LINGER (600 s) after it last was.

state.json (peerlink/): {v, pid, ts, me, views, hub_down, links[{machine, login, host,
route, sock, pid, phase up|connecting|verifying|down, since, last_check, rtt_ms, fails,
err, bad_since, want_ts}], events[{ts, machine, login, what}]} — C1's top line, the
doctor and C10 read it.

Seams: FLEET_PEERLINK_SSH (else FLEET_REMOTE_SSH_CMD, else ssh) · FLEET_PEERLINK_CERT_CMD
(else `bash fleet-peer-cert.sh`) · FLEET_PEERLINK_HOME (this machine's label) ·
FLEET_PEERLINK=0 keeps `run` idle.
"""
import errno
import fcntl
import json
import os
import pwd
import shlex
import signal
import socket
import subprocess
import sys
import threading
import time

BIN = os.path.dirname(os.path.abspath(__file__))
US = "\x1f"


def env(k, d=""):
    v = os.environ.get(k)
    return d if v is None or v == "" else v


def fenv(k, d):
    try:
        return float(env(k, str(d)))
    except ValueError:
        return float(d)


CONF = env("FLEET_CONF_DIR", os.path.join(os.path.expanduser("~"), ".config", "claude-fleet"))
D = os.path.join(CONF, "peerlink")
STATE = os.path.join(D, "state.json")
LOCK = os.path.join(D, ".lock")
RUNS = os.path.join(D, "runs")
VIEWS = os.path.join(CONF, "remote-views")
# fleet-lib.sh's FLEET_C, spelled the same way
FLEET_C = env("FLEET_C", os.path.join(env("TMPDIR", "/tmp/claude-fleet-%d" % os.getuid()), ".claude-dash"))
GLOBAL = os.path.join(FLEET_C, "global")

TICK = fenv("FLEET_PEERLINK_TICK", 2)
LINGER = fenv("FLEET_PEERLINK_LINGER", 600)
PROBE = fenv("FLEET_PEERLINK_PROBE_SECS", 30)
CONNECT = fenv("FLEET_PEERLINK_CONNECT_SECS", 15)
BACKOFF_MAX = fenv("FLEET_PEERLINK_BACKOFF_MAX", 30)
STALE = fenv("FLEET_PEERLINK_STALE", 30)          # state older than this: the keeper is not running
BAD_WARN = fenv("FLEET_PEERLINK_BAD_WARN", 60)    # a link failing its check this long: WARN
MAX_EVENTS = 50


def me_login():
    return pwd.getpwuid(os.getuid()).pw_name


def ssh_cmd():
    return shlex.split(env("FLEET_PEERLINK_SSH", env("FLEET_REMOTE_SSH_CMD", "ssh")))


def cert_cmd():
    c = env("FLEET_PEERLINK_CERT_CMD")
    return shlex.split(c) if c else ["bash", os.path.join(BIN, "fleet-peer-cert.sh")]


def aliases():
    """FLEET_NODE_ALIASES `macmini=m5 mini2=m4`: hostname → label."""
    out = {}
    for w in env("FLEET_NODE_ALIASES").split():
        h, _, a = w.partition("=")
        if h and a:
            out[h.lower()] = a
    return out


def home_label():
    h = env("FLEET_PEERLINK_HOME")
    if h:
        return h
    h = socket.gethostname().split(".")[0].lower()
    return aliases().get(h, h)


def ssh_host(machine):
    """FLEET_REMOTE_SSH `m4=m4-lan m5=macmini`, else the label itself (the route)."""
    for w in env("FLEET_REMOTE_SSH").split():
        n, _, h = w.partition("=")
        if n == machine and h:
            return h
    return machine


def sock_path(machine, login):
    return os.path.join(D, "%s@%s.sock" % (machine, login))


def safe(s):
    return bool(s) and all(c.isalnum() or c in "._-" for c in s)


def read_json(p, d):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return d


def write_json(p, obj):
    tmp = "%s.%d.tmp" % (p, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1, sort_keys=True)
    os.replace(tmp, p)


def pid_alive(pid):
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
    except OSError as e:
        return e.errno == errno.EPERM
    return True


# --- what to connect ---------------------------------------------------------------
def live_thin_views():
    """The ids of thin views (C1) with a client attached: kind `thin`, attach pid alive."""
    out = []
    try:
        names = sorted(os.listdir(VIEWS))
    except OSError:
        return out
    for n in names:
        p = os.path.join(VIEWS, n)
        if not os.path.isfile(p):
            continue
        try:
            with open(p, encoding="utf-8", errors="replace") as f:
                cols = f.readline().rstrip("\n").split("\t")
        except OSError:
            continue
        # a 看台 a home machine opened HERE for its own client (`<id>-via-<home>`,
        # C4) is that home's link, not a client of ours: it wants no links of its own
        if len(cols) < 5 or cols[2] != "thin" or "-via-" in n:
            continue
        try:
            pid = int(cols[4])
        except ValueError:
            continue
        if pid_alive(pid):
            out.append(n)
    return out


def fleet_logins():
    m = {}
    try:
        with open(os.path.join(GLOBAL, "fleet_logins"), encoding="utf-8") as f:
            for line in f:
                u, _, lg = line.rstrip("\n").partition("\t")
                if u and lg:
                    m[u] = lg
    except OSError:
        pass
    return m


def wanted_targets():
    """{(machine, login)} the hub's session table shows your sessions on — every
    fleet's global/remote_<sess> — minus this machine's own login and lost machines."""
    me, mine = home_label(), me_login()
    logins = fleet_logins()
    out = set()
    try:
        names = os.listdir(GLOBAL)
    except OSError:
        return out
    for n in sorted(names):
        if not n.startswith("remote_") or n.endswith(".tmp"):
            continue
        here = me
        try:
            lines = open(os.path.join(GLOBAL, n), encoding="utf-8", errors="replace").read().splitlines()
        except OSError:
            continue
        for line in lines:
            p = line.split(US)
            if p[0] == "#me" and len(p) > 1 and p[1]:
                here = p[1]
        for line in lines:
            p = line.split(US)
            if not p[0].startswith("wid:") or len(p) < 3:
                continue
            node, av = p[1], p[2]
            if av == "lost" or not safe(node):
                continue
            fid = p[0][4:].split("/", 1)[0]
            login = logins.get(fid) or mine
            if not safe(login):
                continue
            if node in (here, me) and login == mine:
                continue
            out.add((node, login))
    return out


# --- ssh -----------------------------------------------------------------------------
def ssh_run(args, timeout=5, capture=False):
    try:
        r = subprocess.run(ssh_cmd() + args, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                           stderr=subprocess.PIPE, timeout=timeout)
        return r.returncode, (r.stdout or b"").decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        return 124, "", "timed out"
    except OSError as e:
        return 127, "", str(e)


def master_check(sock, host):
    """`ssh -O check` → (ok, master pid or 0)."""
    if not os.path.exists(sock):
        return False, 0
    rc, _, err = ssh_run(["-S", sock, "-O", "check", host], timeout=3)
    pid = 0
    if "pid=" in err:
        try:
            pid = int(err.split("pid=", 1)[1].split(")", 1)[0])
        except ValueError:
            pid = 0
    return rc == 0, pid


def peer_opts(machine):
    """(opts, err): the certificate's ssh options without its `-l` (the link says
    which login), [] when no hub is here (rc 3), err on a hub that said no / is down."""
    try:
        r = subprocess.run(cert_cmd() + [machine, "view"], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, "入口不在：%s" % e
    if r.returncode == 3:
        return [], ""
    if r.returncode != 0:
        why = (r.stderr.decode("utf-8", "replace").strip().splitlines() or ["the hub did not answer"])[-1]
        return None, "入口不在或拒绝：%s" % why.replace("fleet-peer-cert: ", "")
    opts, skip = [], False
    for o in r.stdout.decode("utf-8", "replace").splitlines():
        o = o.strip()
        if not o:
            continue
        if skip:
            skip = False
            continue
        if o == "-l":
            skip = True
            continue
        opts.append(o)
    return opts, ""


def kill_pid(pid):
    if not pid_alive(pid):
        return
    try:
        os.kill(int(pid), signal.SIGTERM)
    except OSError:
        return
    for _ in range(20):
        try:
            if os.waitpid(int(pid), os.WNOHANG)[0]:
                return
        except ChildProcessError:
            if not pid_alive(pid):
                return
        time.sleep(0.05)
    try:
        os.kill(int(pid), signal.SIGKILL)
        os.waitpid(int(pid), os.WNOHANG)
    except (OSError, ChildProcessError):
        pass


def unlink(p):
    try:
        os.unlink(p)
    except OSError:
        pass


# --- the keeper ------------------------------------------------------------------------
class Link:
    def __init__(self, machine, login, prev=None):
        prev = prev or {}
        self.machine, self.login = machine, login
        self.host = ssh_host(machine)
        self.sock = sock_path(machine, login)
        self.pid = 0
        self.proc = None            # our own master, when we started it
        self.phase = "down"
        self.since = 0.0
        self.last_check = 0.0
        self.rtt_ms = prev.get("rtt_ms")
        self.fails = int(prev.get("fails") or 0)
        self.err = prev.get("err") or ""
        self.bad_since = prev.get("bad_since") or 0.0
        self.want_ts = float(prev.get("want_ts") or 0)
        self.next_try = 0.0
        self.backoff = 0.0
        self.verify = None          # (Popen, started)
        self.probe = None           # ([rc, ms] once done, started)
        self.last_probe = 0.0
        self.rebuild_why = ""
        self.last_loss = 0.0

    def name(self):
        return "%s@%s" % (self.machine, self.login)

    def alive(self):
        # our own master is our child: a dead one is a zombie kill(0) still finds
        if self.proc is not None:
            return self.proc.poll() is None
        return pid_alive(self.pid)

    def dump(self):
        return {"machine": self.machine, "login": self.login, "host": self.host, "route": self.host,
                "sock": self.sock, "pid": self.pid, "phase": self.phase, "since": self.since,
                "last_check": self.last_check, "rtt_ms": self.rtt_ms, "fails": self.fails,
                "err": self.err, "bad_since": self.bad_since, "want_ts": self.want_ts}


class Keeper:
    def __init__(self):
        self.links = {}
        self.events = []
        self.hub_down = ""
        self.lock_fd = None
        self.views = []
        prev = read_json(STATE, {})
        self.events = list(prev.get("events") or [])[-MAX_EVENTS:]
        self.prev = {(l.get("machine"), l.get("login")): l for l in prev.get("links") or []
                     if isinstance(l, dict)}

    # the lock: one keeper, and one that lost its file quits
    def lock(self):
        os.makedirs(D, mode=0o700, exist_ok=True)
        os.chmod(D, 0o700)
        fd = os.open(LOCK, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            holder = ""
            try:
                holder = os.pread(fd, 32, 0).decode("ascii", "replace").strip()
            except OSError:
                pass
            os.close(fd)
            return holder or "?"
        os.ftruncate(fd, 0)
        os.pwrite(fd, ("%d\n" % os.getpid()).encode(), 0)
        if self.lock_fd is not None:
            os.close(self.lock_fd)
        self.lock_fd = fd
        return ""

    def still_mine(self):
        try:
            return os.fstat(self.lock_fd).st_ino == os.stat(LOCK).st_ino
        except OSError:
            return False

    def event(self, l, what):
        self.events.append({"ts": round(time.time(), 3), "machine": l.machine, "login": l.login, "what": what})
        self.events = self.events[-MAX_EVENTS:]
        sys.stderr.write("fleet-peerlink: %s %s\n" % (l.name(), what))
        sys.stderr.flush()

    def fail(self, l, why, now):
        l.fails += 1
        l.err = why
        if not l.bad_since:
            l.bad_since = now
        l.backoff = min(BACKOFF_MAX, max(1.0, l.backoff * 2 if l.backoff else 1.0))
        l.next_try = now + l.backoff
        l.phase = "down"

    def drop(self, l, why, now, exit_master=True):
        """Kill the master, clear the path, rebuild on the next beat."""
        if exit_master and os.path.exists(l.sock):
            ssh_run(["-S", l.sock, "-O", "exit", l.host], timeout=3)
        if l.proc is not None:
            kill_pid(l.proc.pid)
            l.proc = None
        if l.pid:
            kill_pid(l.pid)
        for p in (l.verify,):
            if p:
                try:
                    p[0].kill()
                    p[0].wait(timeout=1)
                except (OSError, subprocess.TimeoutExpired):
                    pass
        l.verify = l.probe = None
        unlink(l.sock)
        l.pid = 0
        l.phase = "down"
        if why:
            self.event(l, why)

    def start(self, l, now):
        l.rebuild_why = l.rebuild_why or ("rebuilt" if l.since else "built")
        # a master already on the path (one we lost track of, or a stray): it is
        # adopted only after it says who it is logged in as
        ok, pid = master_check(l.sock, l.host)
        if ok:
            l.pid, l.proc, l.since, l.phase = pid, None, now, "connecting"
            if l.rebuild_why == "built":
                l.rebuild_why = "adopted"
            return
        unlink(l.sock)
        opts, why = peer_opts(l.machine)
        if opts is None:
            # asking again is cheap (the cert's connect is bounded), so a hub that
            # comes back is noticed within a beat, not after a doubled backoff
            self.hub_down = why
            self.fail(l, why, now)
            l.backoff, l.next_try = 0.0, now + TICK
            return
        self.hub_down = ""
        argv = ssh_cmd() + opts + ["-M", "-N", "-o", "ControlPersist=no", "-o", "ServerAliveInterval=2",
                                   "-o", "ServerAliveCountMax=3", "-o", "BatchMode=yes",
                                   "-o", "ConnectTimeout=%d" % max(1, int(CONNECT)),
                                   "-S", l.sock, "-l", l.login, l.host]
        try:
            errf = open(l.sock[:-5] + ".err", "w")
            l.proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=errf)
            errf.close()
        except OSError as e:
            self.fail(l, "ssh did not start: %s" % e, now)
            return
        l.pid, l.since, l.phase = l.proc.pid, now, "connecting"

    def last_err(self, l):
        try:
            lines = [x for x in open(l.sock[:-5] + ".err", encoding="utf-8", errors="replace").read().splitlines() if x.strip()]
            return lines[-1] if lines else ""
        except OSError:
            return ""

    def step(self, l, now):
        if l.phase == "down":
            if now >= l.next_try:
                self.start(l, now)
            return
        if l.phase == "connecting":
            if l.proc is not None and l.proc.poll() is not None:
                why = self.last_err(l) or "ssh exited %s" % l.proc.returncode
                l.proc = None
                self.drop(l, "", now, exit_master=False)
                self.fail(l, why, now)
                return
            ok, pid = master_check(l.sock, l.host)
            if ok:
                if pid and l.pid and pid != l.pid and l.proc is not None:
                    pass   # an ssh wrapper's child: trust what the master says
                l.pid = pid or l.pid
                cmd = ssh_cmd() + ["-S", l.sock, "-o", "ControlMaster=no", "-l", l.login, l.host, "id", "-un"]
                try:
                    l.verify = (subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                                 stderr=subprocess.DEVNULL), now)
                    l.phase = "verifying"
                except OSError as e:
                    self.drop(l, "", now)
                    self.fail(l, "id -un did not start: %s" % e, now)
                return
            if now - l.since > CONNECT:
                self.drop(l, "", now)
                self.fail(l, self.last_err(l) or "no master after %ds" % CONNECT, now)
            return
        if l.phase == "verifying":
            p, t0 = l.verify
            if p.poll() is None:
                if now - t0 > 10:
                    self.drop(l, "", now)
                    self.fail(l, "id -un did not answer", now)
                return
            got = (p.stdout.read() or b"").decode("utf-8", "replace").strip()
            l.verify = None
            if p.returncode != 0 or got != l.login:
                why = "登录不符：连上的是 %s，要的是 %s" % (got or "?", l.login)
                self.drop(l, why, now)
                self.fail(l, why, now)
                return
            l.phase, l.since, l.last_check = "up", now, now
            l.err, l.bad_since = "", 0.0
            self.event(l, l.rebuild_why or "built")
            l.rebuild_why = ""
            l.last_probe = 0.0
            return
        # up: file there · master alive · -O check answers · a channel opens
        why = ""
        if not os.path.exists(l.sock):
            why = "控制文件没了"
        elif l.pid and not l.alive():
            why = "主进程没了"
        else:
            ok, pid = master_check(l.sock, l.host)
            if not ok:
                why = "ssh -O check 不通"
            elif pid and l.pid and pid != l.pid:
                why = "控制文件换了主人（pid %s，不是 %s）" % (pid, l.pid)
        if l.probe and not why:
            res, t0 = l.probe
            if res:
                l.probe = None
                if res[0] == 0:
                    l.rtt_ms = res[1]
                else:
                    why = "新通道开不了（exit %s）" % res[0]
            elif now - t0 > 10:
                l.probe = None
                why = "新通道没回应"
        if why:
            # the first loss is rebuilt at once; a link that keeps falling over
            # within a minute of coming up backs off 1 → 30 s
            again = now - l.since <= 60 and now - l.last_loss <= 60
            self.drop(l, "重建：" + why, now)
            l.fails += 1
            l.err = why
            l.bad_since = l.bad_since or now
            l.last_loss = now
            l.backoff = min(BACKOFF_MAX, max(1.0, l.backoff * 2 if l.backoff else 1.0)) if again else 0.0
            l.next_try = now + l.backoff
            l.rebuild_why = "rebuilt (%s)" % why
            if l.next_try <= now:
                self.start(l, now)
            return
        l.last_check = now
        if not l.probe and now - l.last_probe >= PROBE:
            # a channel opened on the master, timed: the round trip, and the proof
            # a new channel still opens (the certificate is long gone by now)
            res = []
            cmd = ["-S", l.sock, "-o", "ControlMaster=no", "-l", l.login, l.host, "true"]

            def probe(res=res, cmd=cmd):
                t = time.time()
                rc = ssh_run(cmd, timeout=10)[0]
                res.extend((rc, int((time.time() - t) * 1000)))
            threading.Thread(target=probe, daemon=True).start()
            l.probe, l.last_probe = (res, now), now

    def adopt_leftovers(self):
        """Control files left by a keeper that died: verified like any start."""
        try:
            names = os.listdir(D)
        except OSError:
            return
        for n in names:
            if not n.endswith(".sock") or "@" not in n:
                continue
            m, _, lg = n[:-5].rpartition("@")
            if not (safe(m) and safe(lg)) or (m, lg) in self.links:
                continue
            l = Link(m, lg, self.prev.get((m, lg)))
            if not l.want_ts:
                l.want_ts = time.time()
            self.links[(m, lg)] = l

    def save(self, now):
        links = [self.links[k].dump() for k in sorted(self.links)]
        write_json(STATE, {"v": 1, "pid": os.getpid(), "ts": round(now, 3), "me": home_label(),
                           "login": me_login(), "views": self.views, "hub_down": self.hub_down,
                           "links": links, "events": self.events})

    def beat(self, now):
        self.views = live_thin_views()
        want = wanted_targets() if self.views else set()
        for k in want:
            if k not in self.links:
                self.links[k] = Link(k[0], k[1], self.prev.get(k))
            self.links[k].want_ts = now
        for k in list(self.links):
            l = self.links[k]
            if k not in want and now - l.want_ts > LINGER:
                if l.phase != "down" or os.path.exists(l.sock):
                    self.drop(l, "关闭：没人要了", now)
                del self.links[k]
                continue
            self.step(l, now)
        if not any(l.phase == "down" and l.err.startswith("入口") for l in self.links.values()):
            self.hub_down = ""

    def close_all(self):
        now = time.time()
        for l in self.links.values():
            if l.phase != "down":
                self.drop(l, "关闭：管理者退出", now)
        self.save(now)

    def heartbeat(self):
        os.makedirs(RUNS, exist_ok=True)
        p = os.path.join(RUNS, str(os.getpid()))
        with open(p, "w") as f:
            f.write("%d\n" % os.getpid())

    def run(self):
        holder = self.lock()
        if holder:
            sys.stderr.write("fleet-peerlink: another keeper holds %s (pid %s) — exiting\n" % (LOCK, holder))
            return 3
        stop = []
        signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
        signal.signal(signal.SIGINT, lambda *_: stop.append(1))
        self.adopt_leftovers()
        try:
            while not stop:
                now = time.time()
                if not self.still_mine():
                    holder = self.lock()
                    if holder:
                        sys.stderr.write("fleet-peerlink: %s now belongs to pid %s — this keeper quits\n" % (LOCK, holder))
                        return 0      # its masters are the new keeper's to adopt
                self.heartbeat()
                if env("FLEET_PEERLINK", "1") != "0":
                    self.beat(now)
                self.save(now)
                busy = any(l.phase in ("connecting", "verifying") or (l.phase == "down" and l.next_try - now < TICK)
                           for l in self.links.values())
                end = time.time() + (0.2 if busy else TICK)
                while not stop and time.time() < end:
                    time.sleep(0.1)
                    # the cheap half of the check between beats: a vanished file or
                    # master is acted on at once, not at the next beat
                    if any(l.phase == "up" and (not os.path.exists(l.sock) or not l.alive())
                           for l in self.links.values()):
                        break
        finally:
            unlink(os.path.join(RUNS, str(os.getpid())))
        self.close_all()
        return 0


# --- readers -----------------------------------------------------------------------------
def healthy_sock(machine, login):
    st = read_json(STATE, {})
    for l in st.get("links") or []:
        if l.get("machine") == machine and l.get("login") == login and l.get("phase") == "up":
            s = l.get("sock") or ""
            if s and master_check(s, l.get("host") or ssh_host(machine))[0]:
                return s
    return ""


def cmd_sock(args):
    if len(args) != 2 or not (safe(args[0]) and safe(args[1])):
        sys.stderr.write("usage: fleet-peerlink.py sock <machine> <login>\n")
        return 2
    s = healthy_sock(args[0], args[1])
    if not s:
        return 1
    print(s)
    return 0


def up_sock(machine, login):
    """The link's control socket while state.json says it is up and its file is
    there — no `-O check` (C4's switch path: the channel it opens IS the check, and
    a failed one falls back to the window's own wait). "" otherwise."""
    for l in read_json(STATE, {}).get("links") or []:
        if l.get("machine") == machine and l.get("login") == login and l.get("phase") == "up":
            s = l.get("sock") or ""
            if s and os.path.exists(s):
                return s
    return ""


def remote_bin():
    return env("FLEET_REMOTE_BIN", ".claude/fleet/bin")


def via_view(view):
    """The id of the 看台 this machine keeps on the far one for `view` (共同约定 1)."""
    return "%s-via-%s" % (view, home_label())


def pane_opt(name, value=None):
    """Read (value None) or set ("" unsets) an option of this pane's own window."""
    pane = env("TMUX_PANE")
    if not pane or not env("TMUX"):
        return ""
    if value is None:
        try:
            return subprocess.run(["tmux", "display-message", "-p", "-t", pane, "#{%s}" % name],
                                  capture_output=True, text=True, timeout=3).stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            return ""
    args = ["set-option", "-w", "-t", pane] + (["-u", name] if value == "" else [name, value])
    try:
        subprocess.run(["tmux"] + args, capture_output=True, timeout=3)
    except (OSError, subprocess.TimeoutExpired):
        pass
    return value


def cmd_pane(args):
    """C4's pane program: the view onto <machine> as <login>, riding the link.
    Each (re)connect lands on what the window asks for: `@peer_want` (a go that
    found the link down), else `@peer_cur` (what it showed), else the far 看台's
    own cur= (`--resume`)."""
    if len(args) != 3 or not all(safe(a) for a in args):
        sys.stderr.write("usage: fleet-peerlink.py pane <machine> <login> <view>\n")
        return 2
    machine, login, view = args
    base = "bash %s/fleet-remote-view.sh attach --thin --view %s" % (remote_bin(), shlex.quote(via_view(view)))
    said, pause = False, 0.5
    while True:
        s = healthy_sock(machine, login)
        if not s:
            if not said:
                sys.stdout.write("\r\n正在连 %s（%s）…\r\n" % (machine, login))
                sys.stdout.flush()
                said = True
            time.sleep(1)
            continue
        said = False
        want = pane_opt("@peer_want")
        land = want or pane_opt("@peer_cur")
        tgt = land[4:] if land.startswith("wid:") else ""
        remote = base + (" --want %s" % shlex.quote(tgt) if tgt else " --resume")
        if want:
            pane_opt("@peer_cur", want)
            pane_opt("@peer_want", "")
        t0 = time.time()
        rc = subprocess.call(ssh_cmd() + ["-S", s, "-o", "ControlMaster=no", "-tt", "-l", login,
                                          ssh_host(machine), remote])
        if rc == 0:
            return 0
        sys.stdout.write("\r\n到 %s 的连接断了，等它回来…\r\n" % machine)
        sys.stdout.flush()
        # a far end that keeps refusing at once (no fleet there) is not asked every second
        pause = 0.5 if time.time() - t0 > 30 else min(pause * 2, 15.0)
        time.sleep(pause)


def keepers():
    n = 0
    try:
        for p in os.listdir(RUNS):
            f = os.path.join(RUNS, p)
            if p.isdigit() and pid_alive(int(p)) and time.time() - os.path.getmtime(f) < max(10, 3 * TICK):
                n += 1
    except OSError:
        pass
    return n


def ago(secs):
    secs = max(0, int(secs))
    if secs < 60:
        return "%ds" % secs
    if secs < 3600:
        return "%dm" % (secs // 60)
    return "%dh" % (secs // 3600)


def judge():
    """(rc, line, state): 0 ok · 1 WARN · 2 no state (no row)."""
    if not os.path.exists(STATE):
        return 2, "", {}
    st = read_json(STATE, {})
    now = time.time()
    links = st.get("links") or []
    warns, parts = [], []
    if now - float(st.get("ts") or 0) > STALE:
        warns.append("管理者没在跑（state.json %s 没更新）" % ago(now - float(st.get("ts") or 0)))
    k = keepers()
    if k > 1:
        warns.append("锁外发现第二个 run 进程（%d 个在跑）" % k)
    for l in links:
        name = "%s@%s" % (l.get("machine"), l.get("login"))
        if l.get("phase") == "up":
            rtt = l.get("rtt_ms")
            parts.append("%s 路线 %s · %s · 往返 %s · 失败 %d" % (
                name, l.get("route") or l.get("host"), ago(now - float(l.get("since") or now)),
                "%dms" % rtt if isinstance(rtt, int) else "—", int(l.get("fails") or 0)))
            continue
        err = l.get("err") or l.get("phase")
        parts.append("%s %s · 失败 %d" % (name, err, int(l.get("fails") or 0)))
        bad = float(l.get("bad_since") or 0)
        if (err or "").startswith("登录不符"):
            warns.append("%s 登录不符" % name)
        elif (err or "").startswith("入口"):
            warns.append("%s 开不了新连接：%s" % (name, err))
        elif bad and now - bad > BAD_WARN:
            warns.append("%s 核对失败已 %s：%s" % (name, ago(now - bad), err))
    head = "%d 条常开连接" % len(links) if links else "没有常开连接（无看台）" if not st.get("views") else "没有常开连接"
    line = head + ("：" + " ; ".join(parts) if parts else "")
    if warns:
        return 1, "；".join(warns) + " — " + line, st
    return 0, line, st


def cmd_status(args):
    rc, line, st = judge()
    if "--json" in args:
        print(json.dumps({"rc": rc, "line": line, "state": st}, ensure_ascii=False))
        return rc
    if rc == 2:
        if "--check" not in args:
            print("peerlink: never ran on this login")
        return 2
    print(line)
    if "--check" not in args:
        for e in (st.get("events") or [])[-10:]:
            print("  %s %s@%s %s" % (time.strftime("%H:%M:%S", time.localtime(e.get("ts") or 0)),
                                     e.get("machine"), e.get("login"), e.get("what")))
    return rc


def main(argv):
    if not argv:
        sys.stderr.write(__doc__)
        return 2
    cmd, args = argv[0], argv[1:]
    if cmd == "run":
        return Keeper().run()
    if cmd == "sock":
        return cmd_sock(args)
    if cmd == "pane":
        return cmd_pane(args)
    if cmd == "status":
        return cmd_status(args)
    sys.stderr.write("fleet-peerlink: unknown command %r\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
