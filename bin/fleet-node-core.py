#!/usr/bin/env python3
"""fleet-node-core.py — the machine's root core: the ONLY fleet program that needs
root, and all it does is a fixed table (issue #3555, EPIC #3500 C13).

`com.claude-fleet.node-core` (macOS LaunchDaemon) / `fleet-node-core.service`
(a Linux host's systemd unit) runs `serve` as root. It opens no network port and
reads nothing the hub sends: it listens on ONE local socket,
/var/run/fleet-node-core.sock (0660, the peer's group), and every connection is
checked first — the peer's uid (getpeereid: LOCAL_PEERCRED on macOS, SO_PEERCRED
on Linux) must be the node daemon's account (FLEET_NODE_CORE_PEER: `_fleetnode` /
`fleetnode` once C14 made it, else root — today's daemon); anyone else is cut off
and logged before a byte is read.

A request is one line {"op", "args"} — not one key more (bin/fleet_node_core.py
holds the wire half). The table, written here and nowhere else:

  run-as   {login, job}   start one of <login>'s jobs as <login>: a unit of the
                          account task table (the runtime's launchd templates,
                          fleet-node-supervisor.py's `account_units` — never an
                          argv) or `svc:<name>` of its service register. Answers
                          {"ok", "pid"} at the start and {"exit": rc} at the end,
                          on the same connection; one copy per (login, job)
  stop-as  {login, job}   stop that job (its process group: TERM, 5 s, KILL)
  exec-as  {login, argv}  run argv as <login> and answer its rc + output; argv[0]
                          must be a file under <current>/bin/ (runas.go's
                          prepCmd rule, moved here), root-owned, nobody else may write
  kill     {pid}          TERM, 5 s, KILL — only a process of a managed login or a
                          job this core started
  memguard {level}        fleet-memguard.sh --once as root (once · report)
  power    {profile}      spotlight-off (macOS): fleet-spotlight.sh off --tick
  switch   {sha}          the release in <state>/staging/<sha>/ (a non-root
                          updater's) or <root>/<sha>/ (today's root updater's):
                          ITS signature re-checked with the core's own key
                          (<state>/release.pub) and every file's digest, staging
                          moved in as root's, then `.prev` = old, `current` = new
  rollback {}             `current` ⇄ `.prev`, the target re-checked the same way

A login must be a managed one (<state>/accounts.json); never uid 0. Anything else —
another op, an extra key, a wrong type, an argv outside bin/, an unsigned release —
is answered {"refused": op}, runs nothing, and is one line in the core log
(/var/log/fleet-node-core.log: time · peer uid · op · args digest · why); more than
FLEET_NODE_CORE_ALERT_N (10) refusals in a minute write ONE alert,
<state>/core/alert.json, which the node daemon carries on. `account adopt|release`
is not in the table: only a person with sudo does that.

No core installed = every caller's old road (fleet_node_core.available() false),
byte for byte (共同约定 11). A new privileged op is a BREAK-IT row first, then a
line here.

Usage:
  fleet-node-core.py serve                       the daemon (what launchd / systemd runs)
  fleet-node-core.py call <op> [<args JSON>] [--follow]
                                                 one request, the reply on stdout; exit 0 ok
                                                 · 2 refused · 1 error / no core. --follow
                                                 (run-as): wait for the job and exit with its rc;
                                                 SIGTERM asks stop-as first (the node daemon's
                                                 child for a job the core runs)
  fleet-node-core.py status [--check]            installed · socket · refusals; --check: 0 serving
                                                 · 1 installed, not answering · 2 not installed
  fleet-node-core.py verify <dir>                the switch's check on a release dir, offline
  fleet-node-core.py install | uninstall | install --check

Seams: FLEET_NODE_CORE_SOCK · FLEET_NODE_CORE_LOG · FLEET_NODE_CORE_PEER ·
FLEET_NODE_CORE_PEER_UID (FLEET_NODE_TEST only) · FLEET_NODE_CORE_ALERT_N ·
FLEET_NODE_STATE · FLEET_NODE_ROOT · FLEET_NODE_RUNTIME · FLEET_NODE_LOG ·
FLEET_NODE_TABLE / FLEET_NODE_PASSWD (the supervisor's) · FLEET_NODE_TEST=1.
"""
from __future__ import print_function

import base64
import collections
import grp
import hashlib
import importlib.util
import json
import os
import plistlib
import pwd
import re
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fleet_ed25519  # noqa: E402
import fleet_node_core as wire  # noqa: E402

_spec = importlib.util.spec_from_file_location("fleet_node_supervisor", os.path.join(HERE, "fleet-node-supervisor.py"))
sup = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sup)

# the supervisor's word, so a Linux sandbox with a fake launchctl is a Mac to both
MAC = sup.MAC
DARWIN = sys.platform == "darwin"   # the kernel's: which peer-credential call answers
LABEL = "com.claude-fleet.node-core"
SYSTEMD_UNIT = "fleet-node-core.service"
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
LEVELS = ("once", "report")
PROFILES = ("spotlight-off",)
EXEC_TIMEOUT = 1800
OUT_MAX = 65536
CORE_SH = ('TMPDIR="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"; [ -n "$TMPDIR" ] || '
           '{ TMPDIR="/tmp/claude-fleet-$(id -u)"; mkdir -p -m 700 "$TMPDIR" 2>/dev/null; }; export TMPDIR; exec "$@"')
# what a staged release may carry beside its signed files: the updater's own
# products, each checked another way below
STAGE_EXTRAS = (".release/staged.json", ".release/manifest.json", ".release/manifest.sig", "bin/ccquota")


def env(name, default):
    v = os.environ.get(name)
    return default if v is None or v == "" else v


def testing():
    return env("FLEET_NODE_TEST", "") == "1"


def now():
    return time.time()


def iso(t=None):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now() if t is None else t))


class Paths(object):
    def __init__(self):
        self.state = env("FLEET_NODE_STATE", "/var/db/fleet-node")
        self.root = env("FLEET_NODE_ROOT", sup.DEFAULT_ROOT)
        self.runtime = env("FLEET_NODE_RUNTIME", os.path.join(self.root, "current"))
        self.log = env("FLEET_NODE_LOG", "/var/log/fleet-node")
        self.core_log = env("FLEET_NODE_CORE_LOG", "/var/log/fleet-node-core.log")
        self.sock = wire.sock_path()
        self.current = os.path.join(self.root, "current")
        self.prev = os.path.join(self.root, ".prev")
        self.pubkey = os.path.join(self.state, "release.pub")
        self.staging = os.path.join(self.state, "staging")
        self.core = os.path.join(self.state, "core")
        self.alert = os.path.join(self.core, "alert.json")
        self.daemon_dir = env("FLEET_NODE_DAEMON_DIR", "/Library/LaunchDaemons" if MAC else "/etc/systemd/system")
        self.unit = os.path.join(self.daemon_dir, LABEL + ".plist" if MAC else SYSTEMD_UNIT)

    def rel(self, sha):
        return os.path.join(self.root, sha)


class Refused(Exception):
    pass


# ------------------------------------------------------------- the peer --------
def peer_uid(conn):
    """The connecting process's uid, from the kernel — never from the request."""
    if DARWIN:
        b = conn.getsockopt(0, 1, 76)          # SOL_LOCAL, LOCAL_PEERCRED: struct xucred
        return struct.unpack_from("<II", b)[1]
    b = conn.getsockopt(socket.SOL_SOCKET, getattr(socket, "SO_PEERCRED", 17), struct.calcsize("3i"))
    return struct.unpack("3i", b)[1]


def allowed_peer():
    """(uid, gid) the core takes requests from: the node daemon's account."""
    if testing() and env("FLEET_NODE_CORE_PEER_UID", ""):
        u = int(env("FLEET_NODE_CORE_PEER_UID", "0"))
        return u, os.getegid()
    names = [env("FLEET_NODE_CORE_PEER", "")] if env("FLEET_NODE_CORE_PEER", "") else ["_fleetnode", "fleetnode"]
    for n in names:
        try:
            pw = pwd.getpwnam(n)
            return pw.pw_uid, pw.pw_gid
        except KeyError:
            continue
    return 0, 0


# ------------------------------------------------------------- the table -------
def check_request(line):
    """(op, args) of a well-formed request inside the table, else Refused(op, why)."""
    try:
        req = json.loads(line.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise Refused("?", "not one line of JSON")
    if not isinstance(req, dict):
        raise Refused("?", "not a JSON object")
    op = req.get("op")
    op_s = op if isinstance(op, str) and len(op) <= 32 else "?"
    if set(req) != {"op", "args"}:
        raise Refused(op_s, "keys %s — only op and args" % sorted(req))
    if op not in wire.OPS:
        raise Refused(op_s, "not in the table")
    args = req["args"]
    want = wire.OPS[op]
    if not isinstance(args, dict) or set(args) != set(want):
        raise Refused(op, "args %s — %s takes %s" % (sorted(args) if isinstance(args, dict) else type(args).__name__,
                                                      op, sorted(want)))
    for k, t in want.items():
        v = args[k]
        if t is int and (isinstance(v, bool) or not isinstance(v, int)):
            raise Refused(op, "%s is not an integer" % k)
        if not isinstance(v, t):
            raise Refused(op, "%s is not a %s" % (k, t.__name__))
    return op, args


def managed_login(paths, login):
    """(uid, gid, home) of a login the daemon manages, else Refused."""
    if not sup.LOGIN_RE.match(login):
        raise Refused(None, "login %r is not a login name" % login)
    acc = sup.read_json(os.path.join(paths.state, "accounts.json"), {}) or {}
    if not isinstance(acc, dict) or not (acc.get(login) or {}).get("managed"):
        raise Refused(None, "login %s is not managed here (accounts.json)" % login)
    ident = sup.account_ident(login)
    if ident is None or ident[0] == 0:
        raise Refused(None, "login %s has no account (or is root)" % login)
    return ident


def resolve_job(paths, login, job, ident):
    """The entry for (login, job) the supervisor would build — from the table, never
    from the request — else Refused."""
    sp = sup.Paths()
    if job.startswith("svc:"):
        name = job[4:]
        if not sup.SVC_NAME_RE.match(name):
            raise Refused(None, "job %r is not a service name" % job)
        for lg, nm, path, svc, why in sup.service_files(sp):
            if lg == login and nm == name:
                if svc is None or svc.get("kind", "service") != "service":
                    raise Refused(None, "service %s/%s is not runnable: %s" % (login, name, why or "a task"))
                return sup.service_entry(sp, svc, path, ident)
        raise Refused(None, "no service %s/%s in the register" % (login, name))
    for u in sup.account_units(sp, sup.load_table(sp)):
        u = sup.account_unit_for(u, ident[2])
        if u["name"] == job:
            return sup.account_entry(u, login, ident, sup.brew_prefix())
    raise Refused(None, "job %r is not in the account task table" % job)


def bin_file(paths, argv0):
    """argv[0] resolved, if it is a file under <current>/bin/ root may run."""
    rt_bin = os.path.realpath(os.path.join(paths.runtime, "bin"))
    real = os.path.realpath(argv0)
    if not real.startswith(rt_bin + os.sep) or not os.path.isfile(real):
        raise Refused(None, "argv[0] %s is not a file under %s/" % (argv0, rt_bin))
    if not sup.trusted(real):
        raise Refused(None, "argv[0] %s is not root-owned, or someone else may write it" % argv0)
    return real


def interp(path):
    if path.endswith(".py"):
        return ["/usr/bin/python3", "-I", path]
    if path.endswith(".sh"):
        return ["/bin/bash", path]
    return [path]


def proc_uid(pid):
    try:
        if os.path.isdir("/proc/%d" % pid):
            return os.stat("/proc/%d" % pid).st_uid
        out = subprocess.run(["/bin/ps", "-o", "uid=", "-p", str(pid)], capture_output=True, text=True,
                             timeout=10).stdout.strip()
        return int(out) if out else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def stop_group(pid, grace=5.0, group=True):
    """TERM the process group (a job of ours: its own session) or, group=False,
    the one process; KILL what is left after grace."""
    for k in ((os.killpg, os.kill) if group else (os.kill,)):
        try:
            k(pid, signal.SIGTERM)
            break
        except OSError:
            continue
    end = now() + grace
    while now() < end and sup.pid_alive(pid):
        time.sleep(0.05)
    if sup.pid_alive(pid):
        for k in ((os.killpg, os.kill) if group else (os.kill,)):
            try:
                k(pid, signal.SIGKILL)
                break
            except OSError:
                continue
    return not sup.pid_alive(pid)


# ------------------------------------------------------------- releases --------
def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def read_pub(path):
    try:
        with open(path) as f:
            kind, b64 = f.read().split()[:2]
        raw = base64.b64decode(b64)
    except (OSError, ValueError, TypeError):
        return None
    return raw if kind == "ed25519" and len(raw) == 32 else None


def verify_release(paths, d, sha):
    """None when <d> is release <sha> exactly as its signed manifest says, by the
    core's own key; else why not. Every listed file present with its size and
    digest, every artifact present likewise, nothing unlisted but the updater's
    own products: bin/ccquota (the release's ccquota artifact, or on macOS that
    artifact re-signed with the machine's identity — codesign must accept it) and
    tools/ links into <root>/tools/<tool>/<sha256>/ (an artifact's digest) whose
    bytes are an artifact of the release."""
    pub = read_pub(paths.pubkey)
    if pub is None:
        return "no release key at %s" % paths.pubkey
    try:
        with open(os.path.join(d, ".release", "manifest.json"), "rb") as f:
            mb = f.read()
        with open(os.path.join(d, ".release", "manifest.sig")) as f:
            sig = base64.b64decode(f.read().strip())
    except (OSError, ValueError, TypeError) as e:
        return "no signed manifest: %s" % e
    if not fleet_ed25519.verify(pub, mb, sig):
        return "the signature is not the machine's release key's"
    try:
        m = json.loads(mb.decode("utf-8"))
    except ValueError:
        return "manifest is not JSON"
    if m.get("schema") != 1 or m.get("sha") != sha:
        return "manifest names %s, not %s" % (m.get("sha"), sha)
    listed = set()
    for fl in m.get("files") or []:
        p = str(fl.get("path", ""))
        if not p or p.startswith("/") or ".." in p.split("/"):
            return "manifest path %r" % p
        full = os.path.join(d, p)
        try:
            st = os.lstat(full)
        except OSError:
            return "%s: missing" % p
        if not stat.S_ISREG(st.st_mode):
            return "%s: not a regular file" % p
        if st.st_size != fl.get("size") or sha256_file(full) != fl.get("sha256"):
            return "%s: digest does not match the manifest" % p
        listed.add(p)
    arts = {}
    for a in m.get("artifacts") or []:
        name = str(a.get("name", ""))
        if not name or "/" in name or name.startswith("."):
            return "artifact name %r" % name
        arts[name] = a
        full = os.path.join(d, ".release", "artifacts", name)
        if not os.path.lexists(full):
            continue
        if not os.path.isfile(full) or os.path.islink(full):
            return "artifact %s: not a regular file" % name
        if os.path.getsize(full) != a.get("size") or sha256_file(full) != a.get("sha256"):
            return "artifact %s: digest does not match the manifest" % name
        listed.add(".release/artifacts/" + name)
    digests = set(a.get("sha256") for a in arts.values())
    tools = os.path.realpath(os.path.join(paths.root, "tools"))
    for top, dirs, files in os.walk(d):
        for n in files + [x for x in dirs if os.path.islink(os.path.join(top, x))]:
            full = os.path.join(top, n)
            rel = os.path.relpath(full, d)
            if rel in listed:
                continue
            if rel.startswith("tools/bin/"):
                real = os.path.realpath(full)
                h = os.path.basename(os.path.dirname(real))
                # <tools>/<tool>/<the tool's digest>/<file>: a helper sits beside its
                # tool, so its own bytes are another artifact of the release
                if not (os.path.islink(full) and real.startswith(tools + os.sep) and h in digests
                        and os.path.isfile(real) and sha256_file(real) in digests):
                    return "%s: not a link to a release artifact in %s" % (rel, tools)
                continue
            if rel == "bin/ccquota":
                h = sha256_file(full)
                if h in digests and any(k.startswith("ccquota-") for k, a in arts.items() if a.get("sha256") == h):
                    continue
                if DARWIN and subprocess.call(["/usr/bin/codesign", "--verify", "--strict", full],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0:
                    continue
                return "bin/ccquota: not the release's ccquota artifact"
            if rel in STAGE_EXTRAS:
                continue
            return "%s: not in the signed manifest" % rel
    return None


def swap_link(path, target):
    tmp = "%s.tmp-core-%d" % (path, os.getpid())
    try:
        os.remove(tmp)
    except OSError:
        pass
    os.symlink(target, tmp)
    os.rename(tmp, path)


def link_target(path):
    try:
        return os.path.basename(os.readlink(path).rstrip("/"))
    except OSError:
        return None


def chown_root(top):
    if os.geteuid() != 0:
        return
    for d, dirs, files in os.walk(top):
        for n in [d] + [os.path.join(d, x) for x in dirs + files]:
            os.lchown(n, 0, 0)


# ------------------------------------------------------------- the daemon ------
class Core(object):
    def __init__(self, paths):
        self.p = paths
        self.peer = allowed_peer()
        self.jobs = {}                 # (login, job) -> Popen
        self.lock = threading.Lock()
        self.refusals = collections.deque()
        self.alerted = 0
        self.stop = False
        self.tl = threading.local()     # the peer uid of the connection this thread serves
        self.me = sha256_file(os.path.abspath(__file__))

    # -- the log: one line a request (the refused ones are the evidence)
    def log(self, uid, op, args, verdict):
        digest = hashlib.sha256(json.dumps(args, sort_keys=True).encode()).hexdigest()[:12] if args is not None else "-"
        line = "%s peer=%s op=%s args=%s %s\n" % (iso(), uid, op, digest, verdict)
        try:
            fd = os.open(self.p.core_log, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o640)
            with os.fdopen(fd, "a") as f:
                f.write(line)
        except OSError:
            sys.stderr.write(line)

    def refused(self, uid, op, args, why):
        self.log(uid, op, args, "refused: %s" % why)
        t = now()
        with self.lock:
            self.refusals.append(t)
            while self.refusals and self.refusals[0] < t - 60:
                self.refusals.popleft()
            n = len(self.refusals)
            if n > int(env("FLEET_NODE_CORE_ALERT_N", "10")) and t - self.alerted >= 60:
                self.alerted = t
                try:
                    os.makedirs(self.p.core, 0o755, exist_ok=True)
                    sup.write_json(self.p.alert, {"at": t, "count": n, "last": op, "peer": uid, "why": why[:200]})
                except OSError:
                    pass
                self.log(uid, op, args, "ALERT: %d refusals in a minute — one alert written to %s" % (n, self.p.alert))

    # -- one connection
    def handle(self, conn):
        try:
            uid = peer_uid(conn)
        except (OSError, struct.error):
            uid = None
        if uid != self.peer[0]:
            self.log(uid, "-", None, "refused: peer uid %s is not the node daemon's (%d) — cut off" % (uid, self.peer[0]))
            conn.close()
            return
        conn.settimeout(10)
        try:
            line, _ = wire.read_line(conn)
        except (OSError, ValueError, socket.timeout):
            self.refused(uid, "?", None, "no request line")
            conn.close()
            return
        if not line.strip():
            conn.close()     # the client's `available()` knock: nothing asked, nothing logged
            return
        op, args = "?", None
        try:
            op, args = check_request(line)
            conn.settimeout(None)
            self.dispatch(conn, uid, op, args)
        except Refused as e:
            op = e.args[0] or op
            # refused before its args were read: the digest is the raw line's
            self.refused(uid, op, args if args is not None else line.decode("utf-8", "replace"), e.args[1])
            self.send(conn, {"refused": op, "why": e.args[1]})
        except Exception as e:     # inside the table, but it failed
            self.log(uid, op, args, "error: %s" % e)
            self.send(conn, {"error": str(e)[:300]})
        finally:
            conn.close()

    @staticmethod
    def send(conn, obj):
        try:
            conn.sendall((json.dumps(obj, sort_keys=True) + "\n").encode())
            return True
        except OSError:
            return False

    def dispatch(self, conn, uid, op, args):
        fn = getattr(self, "op_" + op.replace("-", "_"))
        self.tl.uid = uid
        try:
            r = fn(conn, args)
        except Refused as e:
            raise Refused(op, e.args[1])
        if r is not None:
            self.log(uid, op, args, "ok %s" % json.dumps(r, sort_keys=True)[:160])
            self.send(conn, r)

    # -- the ops
    def op_run_as(self, conn, a):
        ident = managed_login(self.p, a["login"])
        ent = resolve_job(self.p, a["login"], a["job"], ident)
        why = sup.account_runnable(ent)
        if why:
            raise Refused(None, why)
        key = (a["login"], a["job"])
        with self.lock:
            old = self.jobs.get(key)
            if old is not None and old.poll() is None:
                return {"error": "running", "pid": old.pid}
            e = ent["env"]
            if ent.get("service"):
                sup.service_logdir(ent)
                e = dict(e, **sup.service_creds(sup.Paths(), ent)[0])
            fh = self.logfile(a["login"])
            p = subprocess.Popen(ent["cmd"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=fh,
                                 env=e, start_new_session=True, close_fds=True,
                                 preexec_fn=sup.demote(ent["account"], ent["uid"], ent["gid"], ent["home"]))
            fh.close()
            self.jobs[key] = p
        self.log(self.tl.uid, "run-as", a, "ok pid %d" % p.pid)
        self.send(conn, {"ok": True, "pid": p.pid})
        rc = p.wait()
        with self.lock:
            if self.jobs.get(key) is p:
                del self.jobs[key]
        self.send(conn, {"exit": rc})
        return None

    def op_stop_as(self, conn, a):
        # only a job of this core's own book: a login being released (no longer
        # managed) still has its running job stopped
        if not sup.LOGIN_RE.match(a["login"]):
            raise Refused(None, "login %r is not a login name" % a["login"])
        with self.lock:
            p = self.jobs.get((a["login"], a["job"]))
        if p is None or p.poll() is not None:
            return {"ok": True, "stopped": False}
        return {"ok": True, "stopped": stop_group(p.pid)}

    def op_exec_as(self, conn, a):
        uid, gid, home = managed_login(self.p, a["login"])
        argv = a["argv"]
        if not argv or len(argv) > 64 or not all(isinstance(x, str) and len(x) <= 4096 and "\0" not in x for x in argv):
            raise Refused(None, "argv must be 1-64 strings")
        real = bin_file(self.p, argv[0])
        tb = os.path.join(self.p.current, "tools", "bin")
        e = {"HOME": home, "USER": a["login"], "LOGNAME": a["login"], "LANG": sup.NODE_LANG,
             "PATH": "%s:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" % tb,
             "FLEET_CONF_DIR": os.path.join(home, ".config", "claude-fleet"),
             "FLEET_NODE_ROOT": self.p.root, "FLEET_NODE_STATE": self.p.state}
        e.update(sup.node_environment())
        try:
            r = subprocess.run(["/bin/sh", "-c", CORE_SH, "fleet-core"] + interp(real) + argv[1:],
                               stdin=subprocess.DEVNULL, capture_output=True, env=e, timeout=EXEC_TIMEOUT,
                               preexec_fn=sup.demote(a["login"], uid, gid, home), close_fds=True)
            rc, out, err = r.returncode, r.stdout, r.stderr
        except subprocess.TimeoutExpired as x:
            rc, out, err = 124, x.stdout or b"", (x.stderr or b"") + b"\n(timed out)"
        return {"ok": True, "rc": rc, "out": out[-OUT_MAX:].decode("utf-8", "replace"),
                "err": err[-OUT_MAX:].decode("utf-8", "replace")}

    def op_kill(self, conn, a):
        pid = a["pid"]
        if pid <= 1:
            raise Refused(None, "pid %d" % pid)
        with self.lock:
            ours = any(p.pid == pid and p.poll() is None for p in self.jobs.values())
        if not ours:
            uid = proc_uid(pid)
            if uid is None:
                return {"ok": True, "gone": True}
            uids = set()
            for login, rec in (sup.read_json(os.path.join(self.p.state, "accounts.json"), {}) or {}).items():
                ident = sup.account_ident(login) if (rec or {}).get("managed") else None
                if ident and ident[0] != 0:
                    uids.add(ident[0])
            if uid not in uids:
                raise Refused(None, "pid %d belongs to uid %s — not a managed login's, not a job of mine" % (pid, uid))
        return {"ok": True, "gone": stop_group(pid, group=ours)}

    def root_script(self, name, args, extra_env, timeout):
        path = os.path.join(self.p.runtime, "bin", name)
        real = bin_file(self.p, path)
        e = dict(os.environ)
        e.update(extra_env)
        try:
            r = subprocess.run(interp(real) + args, stdin=subprocess.DEVNULL, capture_output=True, env=e,
                               timeout=timeout, close_fds=True)
            rc, out = r.returncode, r.stdout + r.stderr
        except subprocess.TimeoutExpired as x:
            rc, out = 124, (x.stdout or b"") + b"\n(timed out)"
        return {"ok": True, "rc": rc, "out": out[-4096:].decode("utf-8", "replace")}

    def op_memguard(self, conn, a):
        if a["level"] not in LEVELS:
            raise Refused(None, "level %r — one of %s" % (a["level"], ", ".join(LEVELS)))
        extra = {} if a["level"] == "once" else {"FLEET_MEM_SPIKE_ACTION": "report", "FLEET_MEM_ORPHAN_ACTION": "report"}
        return self.root_script("fleet-memguard.sh", ["--once"], extra, 120)

    def op_power(self, conn, a):
        if a["profile"] not in PROFILES:
            raise Refused(None, "profile %r — one of %s" % (a["profile"], ", ".join(PROFILES)))
        if not MAC and not testing():
            raise Refused(None, "no %s on this system" % a["profile"])
        return self.root_script("fleet-spotlight.sh", ["off", "--tick"], {}, 300)

    def op_switch(self, conn, a):
        sha = a["sha"]
        if not SHA_RE.match(sha):
            raise Refused(None, "sha %r is not a commit sha" % sha)
        staged = os.path.join(self.p.staging, sha)
        dest = self.p.rel(sha)
        src = staged if os.path.isdir(staged) and not os.path.islink(staged) else dest
        if not os.path.isdir(src) or os.path.islink(src):
            raise Refused(None, "no staged release %s" % sha[:12])
        why = verify_release(self.p, src, sha)
        if why:
            raise Refused(None, "%s: %s — current stays; the staged copy is kept as evidence" % (sha[:12], why))
        if src == staged:
            if os.path.lexists(dest):
                raise Refused(None, "%s already exists beside the staged copy" % dest)
            chown_root(staged)
            os.rename(staged, dest)
        old = link_target(self.p.current)
        if old and old != sha and os.path.isdir(self.p.rel(old)):
            swap_link(self.p.prev, self.p.rel(old))
        swap_link(self.p.current, dest)
        self.maybe_restart()
        return {"ok": True, "from": old, "to": sha}

    def op_rollback(self, conn, a):
        prev, cur = link_target(self.p.prev), link_target(self.p.current)
        if not prev or not SHA_RE.match(prev) or not os.path.isdir(self.p.rel(prev)):
            raise Refused(None, "no previous release to go back to")
        why = verify_release(self.p, self.p.rel(prev), prev)
        if why:
            raise Refused(None, "%s: %s — current stays" % (prev[:12], why))
        swap_link(self.p.current, self.p.rel(prev))
        if cur and os.path.isdir(self.p.rel(cur)):
            swap_link(self.p.prev, self.p.rel(cur))
        self.maybe_restart()
        return {"ok": True, "from": cur, "to": prev}

    def maybe_restart(self):
        """A switch that brought new core code: exit once the reply is out, and
        launchd / systemd start the new one (the jobs keep running: own sessions)."""
        mine = os.path.join(self.p.runtime, "bin", os.path.basename(__file__))
        try:
            if sha256_file(mine) != self.me:
                threading.Timer(1.0, self.quit).start()
        except OSError:
            pass

    def quit(self):
        self.stop = True
        try:
            os.unlink(self.p.sock)
        except OSError:
            pass
        os._exit(0)

    def logfile(self, login):
        d = os.path.join(self.p.log, "accounts")
        os.makedirs(d, 0o755, exist_ok=True)
        path = os.path.join(d, login + ".log")
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o644)
        return os.fdopen(fd, "ab")

    def serve(self):
        if os.geteuid() != 0 and not testing():
            print("fleet-node-core: serve runs as root (launchd / systemd)", file=sys.stderr)
            return 1
        d = os.path.dirname(self.p.sock)
        os.makedirs(d, exist_ok=True)
        try:
            os.unlink(self.p.sock)
        except OSError:
            pass
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        old = os.umask(0o177)
        try:
            s.bind(self.p.sock)
        finally:
            os.umask(old)
        if os.geteuid() == 0:
            os.chown(self.p.sock, 0, self.peer[1])
        os.chmod(self.p.sock, 0o660)
        s.listen(16)
        signal.signal(signal.SIGTERM, lambda *_: self.quit())
        self.log(os.geteuid(), "serve", None, "listening on %s for uid %d" % (self.p.sock, self.peer[0]))
        while not self.stop:
            try:
                conn, _ = s.accept()
            except OSError:
                continue
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()
        return 0


# ------------------------------------------------------------- the client ------
def cli_call(rest):
    follow = "--follow" in rest
    rest = [x for x in rest if x != "--follow"]
    if not rest:
        print("usage: fleet-node-core.py call <op> [<args JSON>] [--follow]", file=sys.stderr)
        return 1
    op = rest[0]
    try:
        args = json.loads(rest[1]) if len(rest) > 1 else {}
    except ValueError:
        print("fleet-node-core: args are not JSON", file=sys.stderr)
        return 1
    try:
        c = wire.Conn(op, args)
    except OSError as e:
        print("fleet-node-core: no core at %s (%s)" % (wire.sock_path(), e), file=sys.stderr)
        return 1
    try:
        r = c.reply()
    except OSError:      # cut off (a peer it does not take): a reset on Linux
        r = None
    r = r or {"error": "the core closed the connection"}
    print(json.dumps(r, sort_keys=True))
    sys.stdout.flush()
    if "refused" in r:
        return 2
    if not r.get("ok"):
        return 1
    if not (follow and op == "run-as"):
        return 0 if r.get("rc", 0) == 0 else r["rc"] if isinstance(r.get("rc"), int) and 0 < r["rc"] < 256 else 1

    # the job runs under the core; this process stands in for it under the node
    # daemon — its exit is the job's, a TERM to it stops the job first
    pid = r.get("pid")

    def term(*_):
        try:
            wire.call("stop-as", {"login": args.get("login"), "job": args.get("job")}, timeout=15)
        except (OSError, ValueError):
            pass
    signal.signal(signal.SIGTERM, term)
    signal.signal(signal.SIGINT, term)
    while True:
        try:
            r = c.reply()
            break
        except InterruptedError:
            continue
        except OSError:
            r = None
            break
    c.close()
    if r is not None and isinstance(r.get("exit"), int):
        rc = r["exit"]
        return rc if 0 <= rc < 256 else 128 + (-rc) if rc < 0 else 1
    # the core went (a restart): stand in until the job itself has gone
    while pid and sup.pid_alive(pid):
        time.sleep(1)
    return 0


def status(paths, check=False):
    inst = os.path.exists(paths.unit)
    up = wire.available()
    alert = sup.read_json(paths.alert, None)
    if check:
        return 0 if up else 1 if inst else 2
    print("core     %s · socket %s%s" % ("serving" if up else "installed, not answering" if inst else "not installed",
                                         paths.sock, "" if up else " (absent)" if not os.path.exists(paths.sock) else ""))
    if isinstance(alert, dict):
        print("refused  alert %s: %s refusals in a minute (last %s, peer %s)" % (
            iso(alert.get("at", 0)), alert.get("count"), alert.get("last"), alert.get("peer")))
    return 0


def plist_body(paths):
    script = os.path.join(paths.runtime, "bin", "fleet-node-core.py")
    return {"Label": LABEL, "ProgramArguments": ["/usr/bin/python3", "-I", script, "serve"],
            "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 5, "ProcessType": "Standard",
            "StandardOutPath": os.path.join(paths.log, "core.log"),
            "StandardErrorPath": os.path.join(paths.log, "core.log")}


def systemd_body(paths):
    values = sup.node_environment()
    values.update(FLEET_NODE_ROOT=paths.root, FLEET_NODE_RUNTIME=paths.runtime, FLEET_NODE_STATE=paths.state,
                  FLEET_NODE_LOG=paths.log)
    for v in values.values():
        if "\n" in v or "\r" in v or "%" in v:
            raise ValueError("invalid systemd setting")
    args = ["/usr/bin/python3", "-I", os.path.join(paths.runtime, "bin", "fleet-node-core.py"), "serve"]
    return ("[Unit]\nDescription=Fleet node root core\n\n[Service]\nType=simple\n" +
            "".join("Environment=%s\n" % json.dumps(k + "=" + v) for k, v in sorted(values.items())) +
            "ExecStart=%s\nRestart=always\nRestartSec=5\nKillMode=process\nUMask=0077\n\n"
            "[Install]\nWantedBy=multi-user.target\n" % " ".join(json.dumps(x) for x in args))


def install(paths):
    if os.geteuid() != 0 and not testing():
        print("fleet-node-core: install writes %s — run it as root (sudo)" % paths.unit, file=sys.stderr)
        return 1
    if not sup.trusted(os.path.join(paths.runtime, "bin", "fleet-node-core.py")):
        print("fleet-node-core: the runtime's fleet-node-core.py is missing or not root's", file=sys.stderr)
        return 1
    os.makedirs(paths.daemon_dir, exist_ok=True)
    tmp = paths.unit + ".tmp-core"
    if not MAC:
        with open(tmp, "w") as f:
            f.write(systemd_body(paths))
        os.chmod(tmp, 0o644)
        os.replace(tmp, paths.unit)
        if sup.systemctl("daemon-reload") or sup.systemctl("enable", "--now", SYSTEMD_UNIT):
            return 1
        return sup.systemctl("restart", SYSTEMD_UNIT)
    with open(tmp, "wb") as f:
        plistlib.dump(plist_body(paths), f)
    os.chmod(tmp, 0o644)
    sup.launchctl("bootout", "system/" + LABEL)
    os.rename(tmp, paths.unit)
    rc = sup.launchctl("bootstrap", "system", paths.unit)
    print("installed %s%s" % (paths.unit, "" if rc == 0 else " (launchctl bootstrap rc=%d)" % rc))
    return 0 if rc == 0 else 1


def install_check(paths):
    try:
        if MAC:
            with open(paths.unit, "rb") as f:
                same = plistlib.load(f) == plist_body(paths)
        else:
            with open(paths.unit) as f:
                same = f.read() == systemd_body(paths)
    except Exception:
        return 1
    return 0 if same and wire.available() else 1


def uninstall(paths):
    if MAC:
        sup.launchctl("bootout", "system/" + LABEL)
    else:
        sup.systemctl("disable", "--now", SYSTEMD_UNIT)
    try:
        os.remove(paths.unit)
    except OSError:
        pass
    print("removed %s — every caller takes its old road" % paths.unit)
    return 0


def main(argv):
    paths = Paths()
    cmd = argv[1] if len(argv) > 1 else ""
    rest = argv[2:]
    if cmd == "serve":
        return Core(paths).serve()
    if cmd == "call":
        return cli_call(rest)
    if cmd == "status":
        return status(paths, "--check" in rest)
    if cmd == "verify" and rest:
        d = os.path.abspath(rest[0])
        why = verify_release(paths, d, os.path.basename(d.rstrip("/")))
        print(why or "ok")
        return 1 if why else 0
    if cmd == "install":
        return install_check(paths) if "--check" in rest else install(paths)
    if cmd == "uninstall":
        return uninstall(paths)
    print(__doc__.split("Usage:")[1].split("Seams:")[0].rstrip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
