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
    exec <machine> [--login <l>] -- <words…>
                              one command on <machine> over its healthy link (issue #3538:
                              fleet-open hands a page to the thin client's HOME this way);
                              stdout/stderr/rc are the command's; rc 3 = no link up
    fwd <machine> <login> <rport> [--secs N]
                              add `-L 127.0.0.1:P:127.0.0.1:<rport>` to that link's master and
                              print P (issue #3538: a page on <machine>'s loopback, reached
                              from here without a tailnet); cancelled after N s
                              (FLEET_OPEN_PAGE_SECS, 1800) or with the master; rc 3 = no link

What to connect, every beat (FLEET_PEERLINK_TICK, 2 s) — FLEET_PEERLINK_MODE, the
environment else fleet.conf's line (issue #3482):

  all (the default)   one link per OTHER login of the same person: the hub's
                      /v1/node/peers (bin/fleet-peer-list.sh, asked every
                      FLEET_PEERLINK_PEERS_SECS, 60 s; its last answer kept in
                      peerlink/peers.json for a hub that is down) plus every
                      (machine, login) the session table shows your sessions on.
                      Held whether or not a view is attached, never closed for
                      want of use; a link that drops is rebuilt with backoff. Only
                      one the hub answers is no longer yours (and no session of
                      yours is there) closes — 「关闭：已不是你的登录」.
  demand              #3002's rule: only while this machine has a thin view with a
                      client attached — a row of $FLEET_CONF_DIR/remote-views/ whose
                      kind is `thin` and whose attach pid lives (C1) — one link per
                      (machine, login) the hub's session table (global/remote_<sess>)
                      shows your sessions on; a link no longer wanted closes
                      FLEET_PEERLINK_LINGER (600 s) after it last was.

Either way this machine's own login is excepted and a lost machine is not asked.

Where to connect (issue #3482): a machine's name resolves only on a tailnet, and a
machine outside it (a cluster machine with only its entry port) was never reached.
So a link dials the routes the hub lists for that login: FLEET_REMOTE_SSH's word for
the machine when there is one, else the tailnet name (only when this machine is on a
tailnet), a LAN address on this machine's own network, the entry port the hub
reached (`entry`), any other direct route — the next one after each failure, the
backoff doubling only once the list wrapped. No routes known (no hub): the bare name,
as before. The certificate is the same five-minute one; its HostKeyAlias makes the
host key check the hub's word whatever address is dialled.

state.json (peerlink/): {v, pid, ts, me, views, hub_down, links[{machine, login, host,
route, sock, pid, phase up|connecting|verifying|down, since, last_check, rtt_ms, fails,
err, bad_since, want_ts}], events[{ts, machine, login, what}], mode, peers_err} — C1's
top line, the doctor and C10 read it.

Seams: FLEET_PEERLINK_SSH (else FLEET_REMOTE_SSH_CMD, else ssh) · FLEET_PEERLINK_CERT_CMD
(else `bash fleet-peer-cert.sh`) · FLEET_PEERLINK_PEERS_CMD (else `bash fleet-peer-list.sh`) ·
FLEET_PEERLINK_HOME (this machine's label) · FLEET_PEERLINK=0 keeps `run` idle.
"""
import errno
import fcntl
import json
import os
import pwd
import re
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
PEERS = os.path.join(D, "peers.json")
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
PEERS_SECS = fenv("FLEET_PEERLINK_PEERS_SECS", 60)  # how often the hub is asked for your logins
MAX_EVENTS = 50


def me_login():
    return pwd.getpwuid(os.getuid()).pw_name


def ssh_cmd():
    return shlex.split(env("FLEET_PEERLINK_SSH", env("FLEET_REMOTE_SSH_CMD", "ssh")))


def cert_cmd():
    c = env("FLEET_PEERLINK_CERT_CMD")
    return shlex.split(c) if c else ["bash", os.path.join(BIN, "fleet-peer-cert.sh")]


def aliases():
    """FLEET_NODE_ALIASES `mac-b.local=mac-b mac-a.local=mac-a`: hostname → label."""
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
    """FLEET_REMOTE_SSH `mac-a=mac-a-lan mac-b=mac-b.local`, else the label itself (the route)."""
    return ssh_host_set(machine) or machine


def ssh_host_set(machine):
    """FLEET_REMOTE_SSH's word for machine, "" when it says nothing."""
    for w in env("FLEET_REMOTE_SSH").split():
        n, _, h = w.partition("=")
        if n == machine and h:
            return h
    return ""


def conf_val(key):
    """The environment, else fleet.conf's last `KEY=value` line (fleet_decision's
    reading — the keeper is a daemon and sources no shell file)."""
    v = os.environ.get(key)
    if v is not None:
        return v
    try:
        with open(os.path.join(CONF, "fleet.conf"), encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return None
    found = None
    for line in lines:
        m = re.match(r"\s*(?:export\s+)?%s\s*=\s*['\"]?([^'\"#\s]*)" % key, line)
        if m:
            found = m.group(1)
    return found


def mode():
    """FLEET_PEERLINK_MODE: `all` (the default — every login of yours, held) or
    `demand` (#3002: only while a thin view is attached, closed after the linger)."""
    return "demand" if (conf_val("FLEET_PEERLINK_MODE") or "").strip().lower() == "demand" else "all"


def label(hostname):
    """A hub hostname as this machine names it — the session table's rule
    (fleet-hub-sessions.sh): FLEET_NODE_ALIASES, else the first label."""
    h = (hostname or "").lower()
    short = h.split(".")[0]
    a = aliases()
    return a.get(h) or a.get(short) or short


# --- the routes (issue #3482) -----------------------------------------------------------
_FC = []


def connect_mod():
    """bin/fleet-connect.py as a module — the client's own reading of a route
    (is_tailnet · is_lan · is_entry · lan_reachable · has_tailnet); None when it
    cannot load, and every route is then tried in the hub's order."""
    if not _FC:
        mod = None
        try:
            import importlib.util
            spec = importlib.util.spec_from_file_location("fleet_connect", os.path.join(BIN, "fleet-connect.py"))
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
        except Exception:  # noqa: BLE001 — a route order, never a crash
            mod = None
        _FC.append(mod)
    return _FC[0]


def route_candidates(machine, routes):
    """[(host, port, label)] to dial, best first: FLEET_REMOTE_SSH's word; else the
    hub's routes — tailnet (only with a tailnet here), a LAN on this network, the
    entry port, any other direct line (never the relay: ssh cannot ride it); else
    the bare name (no hub, nothing known — the old way)."""
    h = ssh_host_set(machine)
    if h:
        return [(h, 0, h)]
    rows = [r for r in routes or [] if isinstance(r, dict) and safe(str(r.get("host") or "").strip("[]").replace(":", "."))
            and r.get("kind", "direct") == "direct"]
    fc = connect_mod()
    tail, lan, entry, other = [], [], [], []
    for r in rows:
        try:
            port = int(r.get("port") or 0)
        except (TypeError, ValueError):
            port = 0
        c = (str(r["host"]).strip("[]"), port, "%s %s%s" % (r.get("name") or "?", r["host"], ":%d" % port if port else ""))
        if fc is None:
            other.append(c)
        elif fc.is_tailnet(r):
            if fc.has_tailnet():
                tail.append(c)
        elif fc.is_lan(r):
            if fc.lan_reachable(r):
                lan.append(c)
        elif fc.is_entry(r):
            entry.append(c)
        else:
            other.append(c)
    out = tail + lan + entry + other
    return out or [(machine, 0, machine)]


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


def peers_cmd():
    c = env("FLEET_PEERLINK_PEERS_CMD")
    return shlex.split(c) if c else ["bash", os.path.join(BIN, "fleet-peer-list.sh")]


def fetch_peers():
    """(peers list | None, err): the hub's answer — a list (maybe empty) on rc 0,
    None + "" with no hub here (rc 3), None + why when it is down or refused."""
    try:
        r = subprocess.run(peers_cmd(), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, "入口不在：%s" % e
    if r.returncode == 3:
        return None, ""
    if r.returncode != 0:
        why = (r.stderr.decode("utf-8", "replace").strip().splitlines() or ["the hub did not answer"])[-1]
        return None, "入口不在或拒绝：%s" % why.replace("fleet-peer-list: ", "")
    try:
        d = json.loads(r.stdout.decode("utf-8", "replace"))
        peers = d.get("peers")
        if not isinstance(peers, list):
            raise ValueError("no peers")
    except (ValueError, AttributeError) as e:
        return None, "入口的回答读不懂：%s" % e
    return [p for p in peers if isinstance(p, dict)], ""


def peer_map(peers):
    """{(machine label, login): its entry} — your logins elsewhere, this one excepted."""
    me, mine = home_label(), me_login()
    out = {}
    for p in peers or []:
        m, lg = label(p.get("hostname") or ""), p.get("login") or ""
        if not (safe(m) and safe(lg)) or (m == me and lg == mine):
            continue
        out[(m, lg)] = p
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
        # a link a keeper before us left up keeps the address it dialled
        self.host = prev.get("host") or ssh_host(machine)
        self.port = int(prev.get("port") or 0)
        self.route = prev.get("route") or self.host
        self.routes = []            # the hub's routes for this login (issue #3482)
        self.route_i = 0
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
        return {"machine": self.machine, "login": self.login, "host": self.host, "route": self.route, "port": self.port,
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
        self.mode = "all"
        self.peers = None           # the hub's last answer (a list), None when never had
        self.peers_ok = False       # the LAST ask answered (so a link absent from it is not yours)
        self.peers_err = ""
        self.peers_at = 0.0
        self.peers_job = None       # ([result], started) while an ask runs
        cached = read_json(PEERS, {})
        if isinstance(cached.get("peers"), list):
            self.peers = cached["peers"]
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
        l.phase = "down"
        # the next route at once; the backoff doubles once every route was tried
        l.route_i += 1
        if l.route_i < len(route_candidates(l.machine, l.routes)):
            l.next_try = now
            return
        l.route_i = 0
        l.backoff = min(BACKOFF_MAX, max(1.0, l.backoff * 2 if l.backoff else 1.0))
        l.next_try = now + l.backoff

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
            i = l.route_i
            self.fail(l, why, now)
            l.route_i = i
            l.backoff, l.next_try = 0.0, now + TICK
            return
        self.hub_down = ""
        cands = route_candidates(l.machine, l.routes)
        l.host, l.port, l.route = cands[l.route_i % len(cands)]
        argv = ssh_cmd() + opts + (["-p", str(l.port)] if l.port else []) + ["-M", "-N", "-o", "ControlPersist=no", "-o", "ServerAliveInterval=2",
                                   "-o", "ServerAliveCountMax=3", "-o", "BatchMode=yes",
                                   "-o", "ConnectTimeout=%d" % max(1, int(CONNECT)),
                                   "-S", l.sock, "-l", l.login, l.host]
        try:
            errf = open(l.sock[:-5] + ".err", "w")
            # its own session: a keeper stopped by launchd / systemd (an install switch
            # restarts it) does not take its masters' process group with it — under
            # `all` they outlive it and the next keeper adopts them (issue #3482)
            l.proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=errf,
                                      start_new_session=True)
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
                           "mode": self.mode, "peers_err": self.peers_err,
                           "links": links, "events": self.events})

    def refresh_peers(self, now):
        """Ask the hub for your logins every PEERS_SECS, off the beat (a thread):
        an answer replaces the list (and peers.json), a hub that is down keeps the
        last one, no hub here keeps nothing and closes nothing."""
        if self.peers_job:
            res, t0 = self.peers_job
            if not res:
                return
            self.peers_job = None
            peers, err = res[0]
            self.peers_err = err
            self.peers_ok = peers is not None
            if peers is not None:
                self.peers = peers
                try:
                    write_json(PEERS, {"ts": round(now, 3), "peers": peers})
                except OSError:
                    pass
            elif not err:
                self.peers = None       # no hub here (rc 3): nothing to go by
            return
        if self.peers_at and now - self.peers_at < PEERS_SECS:
            return
        self.peers_at = now
        res = []
        threading.Thread(target=lambda: res.append(fetch_peers()), daemon=True).start()
        self.peers_job = (res, now)

    def beat(self, now):
        self.views = live_thin_views()
        self.mode = mode()
        self.refresh_peers(now)
        peers = peer_map(self.peers)
        if self.mode == "all":
            want = set(peers) | wanted_targets()
        else:
            want = wanted_targets() if self.views else set()
        for k in want:
            if k not in self.links:
                self.links[k] = Link(k[0], k[1], self.prev.get(k))
            self.links[k].want_ts = now
        for k, l in self.links.items():
            l.routes = (peers.get(k) or {}).get("routes") or []
        for k in list(self.links):
            l = self.links[k]
            if k not in want:
                # all: held until the hub says the login is no longer yours;
                # demand: closed FLEET_PEERLINK_LINGER after it was last wanted
                why = ""
                if self.mode == "all":
                    if self.peers_ok:
                        why = "关闭：已不是你的登录"
                elif now - l.want_ts > LINGER:
                    why = "关闭：没人要了"
                if why:
                    if l.phase != "down" or os.path.exists(l.sock):
                        self.drop(l, why, now)
                    del self.links[k]
                    continue
            self.step(l, now)
        if not any(l.phase == "down" and l.err.startswith("入口") for l in self.links.values()):
            self.hub_down = ""

    def close_all(self):
        """The keeper is going. `demand`: every link closes. `all` (issue #3482): an
        up master stays for the next keeper, which adopts it after `id -un` —
        a restart must not cost every link a rebuild; one not up yet closes."""
        now = time.time()
        for l in self.links.values():
            if l.phase == "up" and self.mode == "all":
                self.event(l, "交给下一个管理者")
                l.proc = None
                continue
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


def link_host(machine, login):
    """The address the link dialled (a channel on its master names the same one —
    the bare name may not resolve here, issue #3482), else ssh_host(machine)."""
    for l in read_json(STATE, {}).get("links") or []:
        if l.get("machine") == machine and l.get("login") == login and l.get("host"):
            return l["host"]
    return ssh_host(machine)


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
                                          link_host(machine, login), remote])
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
    # each other end: 已连上 · 重连中 · 连不上（why） — the last one WARNs (issue #3482)
    for l in links:
        name = "%s@%s" % (l.get("machine"), l.get("login"))
        if l.get("phase") == "up":
            rtt = l.get("rtt_ms")
            parts.append("%s 已连上 · 路线 %s · %s · 往返 %s · 失败 %d" % (
                name, l.get("route") or l.get("host"), ago(now - float(l.get("since") or now)),
                "%dms" % rtt if isinstance(rtt, int) else "—", int(l.get("fails") or 0)))
            continue
        err = l.get("err") or l.get("phase")
        bad = float(l.get("bad_since") or 0)
        if (err or "").startswith("登录不符"):
            warns.append("%s 登录不符" % name)
        elif (err or "").startswith("入口"):
            warns.append("%s 开不了新连接：%s" % (name, err))
        elif bad and now - bad > BAD_WARN:
            warns.append("%s 连不上已 %s：%s" % (name, ago(now - bad), err))
        else:
            parts.append("%s 重连中（%s）· 失败 %d" % (name, err, int(l.get("fails") or 0)))
            continue
        parts.append("%s 连不上：%s · 失败 %d" % (name, err, int(l.get("fails") or 0)))
    md = st.get("mode") or "demand"
    if links:
        head = "%d 条常开连接（%s）" % (len(links), "全连" if md == "all" else "按需")
    elif md == "all":
        head = "没有常开连接（全连：没有你在别的机器上的登录）"
    else:
        head = "没有常开连接（无看台）" if not st.get("views") else "没有常开连接"
    if st.get("peers_err"):
        head += "；对端名单用上次的（%s）" % st.get("peers_err")
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


def link_for(machine, login=""):
    """(machine, login, sock, host) of the UP link to <machine> — matched as named,
    else by this machine's label rule; <login> picks one, else this login's name,
    else the only one. None when no link is up."""
    links = [l for l in read_json(STATE, {}).get("links") or [] if l.get("phase") == "up"]
    want = (machine or "").lower()
    cands = [l for l in links if (l.get("machine") or "").lower() == want] \
        or [l for l in links if label(l.get("machine") or "") == label(machine)]
    if login:
        cands = [l for l in cands if l.get("login") == login]
    elif len(cands) > 1:
        cands = [l for l in cands if l.get("login") == me_login()] or cands[:1]
    for l in cands:
        s = l.get("sock") or ""
        if s and os.path.exists(s):
            return l["machine"], l["login"], s, l.get("host") or ssh_host(l["machine"])
    return None


def cmd_exec(args):
    login, words = "", []
    if "--" in args:
        i = args.index("--")
        args, words = args[:i], args[i + 1:]
    if len(args) == 3 and args[1] == "--login":
        login = args[2]
        args = args[:1]
    if len(args) != 1 or not words or not safe(args[0]) or (login and not safe(login)):
        sys.stderr.write("usage: fleet-peerlink.py exec <machine> [--login <l>] -- <words…>\n")
        return 2
    hit = link_for(args[0], login)
    if not hit:
        sys.stderr.write("fleet-peerlink: no link up to %s\n" % args[0])
        return 3
    _, l, sock, host = hit
    remote = " ".join(shlex.quote(w) for w in words)
    return subprocess.call(ssh_cmd() + ["-S", sock, "-o", "ControlMaster=no", "-T", "-l", l, host, remote],
                           stdin=subprocess.DEVNULL)


def free_port():
    so = socket.socket()
    try:
        so.bind(("127.0.0.1", 0))
        return so.getsockname()[1]
    finally:
        so.close()


def cmd_fwd(args):
    secs = env("FLEET_OPEN_PAGE_SECS", "1800")
    if len(args) == 5 and args[3] == "--secs":
        secs, args = args[4], args[:3]
    if len(args) != 3 or not (safe(args[0]) and safe(args[1])) or not args[2].isdigit() \
            or not 0 < int(args[2]) < 65536 or not secs.isdigit():
        sys.stderr.write("usage: fleet-peerlink.py fwd <machine> <login> <rport> [--secs N]\n")
        return 2
    hit = link_for(args[0], args[1])
    if not hit:
        sys.stderr.write("fleet-peerlink: no link up to %s@%s\n" % (args[1], args[0]))
        return 3
    _, l, sock, host = hit
    for _ in range(3):
        lport = free_port()
        spec = "127.0.0.1:%d:127.0.0.1:%s" % (lport, args[2])
        rc, _, err = ssh_run(["-S", sock, "-O", "forward", "-L", spec, "-l", l, host], timeout=5)
        if rc == 0:
            break
    else:
        sys.stderr.write("fleet-peerlink: the master refused the forward (%s)\n" % err.strip()[:160])
        return 1
    # the cancel, detached: a forward never outlives its deadline (the master's end ends it too)
    try:
        subprocess.Popen([sys.executable, os.path.abspath(__file__), "unfwd", sock, host, l, spec, secs],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, cwd="/")
    except OSError:
        pass
    print(lport)
    return 0


def cmd_unfwd(args):
    if len(args) != 5 or not args[4].isdigit():
        return 2
    sock, host, l, spec, secs = args
    time.sleep(int(secs))
    ssh_run(["-S", sock, "-O", "cancel", "-L", spec, "-l", l, host], timeout=5)
    return 0


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
    if cmd == "exec":
        return cmd_exec(args)
    if cmd == "fwd":
        return cmd_fwd(args)
    if cmd == "unfwd":
        return cmd_unfwd(args)
    sys.stderr.write("fleet-peerlink: unknown command %r\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
