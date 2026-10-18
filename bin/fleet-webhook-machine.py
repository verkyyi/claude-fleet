#!/usr/bin/env python3
"""fleet-webhook-machine.py — the machine's ONE webhook forwarder (issue #4358, EPIC #4354 C4).

Before this, a managed machine ran bin/fleet-webhook.sh once PER LOGIN (the
`webhook` account unit): each one a bash loop forking a `sleep` every 5 s and a
rescan every 30 s, each binding the same 127.0.0.1:8917 — the second login's
handler never bound, and a TERM to the bash wrapper left its python on the port
as a PPID-1 orphan that every later handler crash-looped against. Two logins'
copies were the third-largest source of the idle machine's cost (C1's reading).

Now the node daemon (bin/fleet-node-supervisor.py) runs THIS program as one child,
`webhook-machine`, for every login it took over (not while it is seated — the
seat has no road to run as a login itself, so the account unit stays there):

  * ONE listener on 127.0.0.1 (FLEET_NODE_WEBHOOK_PORT, 8917; taken ⇒ any free
    port — this program writes both ends of the URL). A delivery to /u/<login>
    is ACKed and handed to that login's `fleet-webhook.sh --route --event E`, run
    AS the login (its HOME, its conf, its HMAC secret, its single-writer
    refreshers). A login this program does not serve is answered 404 and routed
    nowhere.
  * Per served login, the repos `fleet-webhook.sh --desired` names (run as the
    login: its live fleets, its per-repo FLEET_WEBHOOK opt-in), each with ONE
    forward: `fleet-webhook.sh --forward <repo> --url …/u/<login>` as the login —
    it reaps the repo's orphaned relay hook (#391), stamps the pidfiles
    fleet_wh_live reads and execs `gh webhook forward`, so the forward is this
    program's own child in its own process group. A (re)connect is followed by
    `--catchup <repo>` (#410, throttled there). A forward that dies is restarted
    after a backoff that doubles on each quick death (5 s … 300 s; one that lived
    30 s starts over), reaped at once — SIGCHLD wakes the loop.
  * A login is served while the node daemon would run its `session` units: its
    collector publishes a session count above 0, or none it can read; a login at
    0 for FLEET_NODE_SESSION_HOLD (120 s) has its forwards stopped.

IDLE: the loop wakes on a delivery, a child exiting, a TERM — and otherwise
every FLEET_NODE_WEBHOOK_TICK (60 s), when it only stats files: a login is
rescanned (one demoted bash) when its conf files or its tmux sockets changed,
on a host wake, and as a backstop every FLEET_NODE_WEBHOOK_RESCAN (600 s).
A host SUSPEND (#410) shows as the wall clock running ahead of the monotonic
one (which stops while the machine sleeps): by FLEET_NODE_WEBHOOK_WAKE_SLACK
(5 s) ⇒ every backoff is cleared, every login rescanned and the next catch-up
forced — at most one tick after the wake (a forward the sleep killed wakes the
loop sooner, by its exit).

Who is served is <state>/webhook-machine.logins ("<pid> <epoch>", then a login
a line, 0644): fleet-webhook.sh's supervise reads it and exits (compat for one
version), and fleet_wh_live's pidfiles name this pid as the handler. The full
picture — logins, forwards, port — is <state>/webhook-machine.json.

Usage:
  fleet-webhook-machine.py run              the loop (the node daemon's child)
  fleet-webhook-machine.py status [--json]  the last state this program wrote
"""
import errno
import fcntl
import http.server
import importlib.util
import json
import os
import re
import select
import signal
import socket
import socketserver
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def load_sup():
    spec = importlib.util.spec_from_file_location("fleet_node_supervisor",
                                                  os.path.join(HERE, "fleet-node-supervisor.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


sup = load_sup()
env, env_num = sup.env, sup.env_num

PORT = int(env_num("FLEET_NODE_WEBHOOK_PORT", 8917))
TICK = max(1.0, env_num("FLEET_NODE_WEBHOOK_TICK", 60))
RESCAN = max(TICK, env_num("FLEET_NODE_WEBHOOK_RESCAN", 600))
SLACK = max(1.0, env_num("FLEET_NODE_WEBHOOK_WAKE_SLACK", 5))
BACKOFF_BASE = max(1.0, env_num("FLEET_WH_BACKOFF_BASE", 5))
BACKOFF_CAP = max(BACKOFF_BASE, env_num("FLEET_WH_BACKOFF_CAP", 300))
BACKOFF_RESET = env_num("FLEET_NODE_WEBHOOK_BACKOFF_RESET", 30)
BODY_MAX = 26 * 1024 * 1024        # GitHub caps a delivery at 25 MB
LOGIN_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$")

# A login's TMPDIR as ACCOUNT_SH gives it, its stderr to the unit's own log
# (opened by the demoted process — root never writes in a login's directory —
# in a directory it makes; `true`, never `:`: dash exits on a special builtin's
# failed redirection, #4668),
# stdout left to the caller (--desired is read from it).
WRAP_SH = ('TMPDIR="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"; [ -n "$TMPDIR" ] || { TMPDIR="/tmp/claude-fleet-$(id -u)"; mkdir -p -m 700 "$TMPDIR" 2>/dev/null; }; export TMPDIR; '
           'mkdir -p "${1%/*}" 2>/dev/null; '
           'if true >>"$1" 2>/dev/null; then exec 2>>"$1"; else exec 2>/dev/null; fi; '
           'shift; exec "$@"')


def wall():
    """The wall clock — plus, under FLEET_NODE_TEST=1, the seconds a selftest
    writes to FLEET_WH_TEST_SKEW_FILE: a host suspend, without one."""
    t = time.time()
    f = os.environ.get("FLEET_WH_TEST_SKEW_FILE")
    if f and env("FLEET_NODE_TEST", "") == "1":
        try:
            with open(f) as fh:
                t += float(fh.read().strip() or 0)
        except (OSError, ValueError):
            pass
    return t


def log(msg):
    sys.stderr.write("%s fleet-webhook-machine: %s\n" % (time.strftime("%H:%M:%S"), msg))
    sys.stderr.flush()


def state_files(paths):
    return (os.path.join(paths.state, "webhook-machine.logins"),
            os.path.join(paths.state, "webhook-machine.json"))


def webhook_unit(paths):
    for u in sup.account_units(paths):
        if u.get("name") == "webhook":
            return u
    return None


class Login(object):
    def __init__(self, ent):
        self.ent = ent
        self.forwards = {}      # repo → Forward
        self.desired = None     # set of repos, None = never scanned
        self.sig = None
        self.scanned = 0.0
        self.force = set()      # repos whose next catch-up skips the throttle (a wake)

    @property
    def login(self):
        return self.ent["account"]

    def argv(self, *args):
        base = self.ent["cmd"][6:]                    # ["/bin/bash", <home>/.claude/fleet/bin/fleet-webhook.sh]
        return ["/bin/sh", "-c", WRAP_SH, "fleet-webhook", self.ent["cmd"][5]] + base + list(args)

    def kw(self, extra=None):
        e = dict(self.ent["env"])
        e.update(extra or {})
        kw = dict(env=e, close_fds=True)
        kw.update(sup.demote_kw(self.login, self.ent["uid"], self.ent["gid"], self.ent["home"]))
        return kw


class Forward(object):
    def __init__(self, proc, t):
        self.proc = proc
        self.started = t
        self.fails = 0
        self.until = 0.0        # a dead forward respawns once now >= until


def login_sig(lg):
    """What `--desired` depends on, as stat()s: the login's fleet confs (the
    machine's, each fleet's, each repo overlay), the install's fleet.conf, and
    the names of its tmux sockets. No fork."""
    conf = lg.ent["env"].get("FLEET_CONF_DIR") or os.path.join(lg.ent["home"], ".config", "claude-fleet")
    out = []

    def st(p):
        try:
            s = os.stat(p)
            out.append((p, s.st_mtime_ns, s.st_size))
        except OSError:
            out.append((p, None))

    def ls(d):
        try:
            return sorted(os.listdir(d))
        except OSError:
            return []

    for p in (os.path.join(conf, "fleet.conf"), os.path.join(conf, "fleet.settings"),
              os.path.join(lg.ent["home"], ".claude", "fleet", "fleet.conf")):
        st(p)
    for n in ls(conf):
        if n.endswith(".conf"):
            st(os.path.join(conf, n))
    fd = os.path.join(conf, "fleets")
    st(fd)
    for n in ls(fd):
        st(os.path.join(fd, n, "conf"))
        rd = os.path.join(fd, n, "repos")
        st(rd)
        for r in ls(rd):
            st(os.path.join(rd, r))
    tdir = os.path.join(lg.ent["env"].get("TMUX_TMPDIR") or ("/private/tmp" if sys.platform == "darwin" else "/tmp"),
                        "tmux-%d" % lg.ent["uid"])
    out.append(("tmux", tuple(ls(tdir))))
    return tuple(out)


class Handler(http.server.BaseHTTPRequestHandler):
    timeout = 30
    machine = None

    def log_message(self, *a):
        pass

    def do_POST(self):
        m = re.match(r"^/u/([^/?#]+)$", self.path or "")
        login = m.group(1) if m else ""
        lg = self.machine.served_login(login) if LOGIN_RE.match(login) else None
        if lg is None:
            self.send_response(404)
            self.end_headers()
            log("delivery for %r: not a login this machine serves — routed nowhere" % login[:64])
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = -1
        if n < 0 or n > BODY_MAX:
            self.send_response(413)
            self.end_headers()
            return
        try:
            body = self.rfile.read(n) if n > 0 else b""
        except (OSError, socket.timeout):
            self.send_response(400)
            self.end_headers()
            return
        event = self.headers.get("X-GitHub-Event", "") or ""
        sig = self.headers.get("X-Hub-Signature-256", "") or ""
        # ACK first — decouple the relay from the kick's latency
        self.send_response(200)
        self.end_headers()
        try:
            self.wfile.write(b"ok")
        except OSError:
            pass
        self.machine.route(lg, event, sig, body)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class Machine(object):
    def __init__(self, paths):
        self.p = paths
        self.logins = {}            # login → Login (the served ones)
        self.busy_at = {}           # login → last time its count was above 0 (or unknown)
        self.catchups = []          # (Login, Popen)
        self.lock = threading.Lock()
        self.stop = False
        self.drift = wall() - time.monotonic()
        self.port = None
        self.server = None
        self.written = None
        self.unit = None
        self.unit_at = -1e9

    # -- who is served
    def served_login(self, login):
        with self.lock:
            return self.logins.get(login)

    def wanted(self, t):
        """{login: entry} the node daemon would run the `webhook` session unit for."""
        if t - self.unit_at >= 60:
            self.unit, self.unit_at = webhook_unit(self.p), t
        if not self.unit:
            return {}
        brew = sup.brew_prefix()
        out = {}
        hold = env_num("FLEET_NODE_SESSION_HOLD", 120)
        for login, why in sup.managed_accounts(self.p).items():
            if why or not LOGIN_RE.match(login):
                continue
            ident = sup.account_ident(login)
            if ident is None:
                continue
            ent = sup.account_entry(self.unit, login, ident, brew)
            if sup.account_runnable(ent):
                continue
            n = sup.login_sessions(ident, t)
            if n is None or n > 0:
                self.busy_at[login] = t
            elif env("FLEET_NODE_SESSION_UNITS", "1") != "0" and t - self.busy_at.get(login, 0) >= hold:
                continue
            out[login] = ent
        return out

    # -- running things as a login
    def run_as(self, lg, args, data=None, extra=None, timeout=60, capture=False):
        try:
            r = subprocess.run(lg.argv(*args), input=data,
                               stdin=None if data is not None else subprocess.DEVNULL,
                               stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=timeout, **lg.kw(extra))
            return r.returncode, (r.stdout or b"").decode("utf-8", "replace")
        except (OSError, subprocess.SubprocessError) as e:
            log("%s: %s failed: %s" % (lg.login, args[0] if args else "?", e))
            return None, ""

    def route(self, lg, event, sig, body):
        rc, _ = self.run_as(lg, ["--route", "--event", event], data=body,
                            extra={"FLEET_DELIVERY_SIG": sig}, timeout=180)
        if rc not in (0, None):
            log("%s: route %s exited %s" % (lg.login, event or "-", rc))

    def url(self, lg):
        return "http://127.0.0.1:%d/u/%s" % (self.port, lg.login)

    def spawn(self, lg, repo, fw, t):
        try:
            p = subprocess.Popen(lg.argv("--forward", repo, "--url", self.url(lg)),
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True,
                                 **lg.kw({"FLEET_WH_MACHINE_PID": str(os.getpid())}))
        except (OSError, subprocess.SubprocessError) as e:
            log("%s: forward %s could not start: %s" % (lg.login, repo, e))
            return None
        if fw is None:
            fw = Forward(p, t)
        fw.proc, fw.started = p, t
        lg.forwards[repo] = fw
        log("%s: forward up %s (pid %d)" % (lg.login, repo, p.pid))
        args = ["--catchup", repo] + (["--force"] if repo in lg.force else [])
        lg.force.discard(repo)
        try:
            self.catchups.append((lg, subprocess.Popen(lg.argv(*args), stdin=subprocess.DEVNULL,
                                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                                       **lg.kw())))
        except (OSError, subprocess.SubprocessError) as e:
            log("%s: catch-up %s could not start: %s" % (lg.login, repo, e))
        return fw

    def stop_forwards(self, items, why):
        targets = []
        for lg, repo, fw in items:
            if fw.proc.poll() is None:
                targets.append((fw.proc.pid, True))
                log("%s: forward down %s (%s)" % (lg.login, repo, why))
        if targets:
            sup.stop_processes(targets, grace=3.0, reap=lambda: [fw.proc.poll() for _, _, fw in items])
        for _, _, fw in items:
            try:
                fw.proc.wait(timeout=1)
            except Exception:
                pass

    # -- one pass
    def reconcile(self, t, woke):
        want = self.wanted(t)
        gone = [lg for name, lg in self.logins.items() if name not in want]
        for lg in gone:
            self.stop_forwards([(lg, r, f) for r, f in lg.forwards.items()], "no session on this login")
            lg.forwards.clear()
        with self.lock:
            for lg in gone:
                self.logins.pop(lg.login, None)
            for name, ent in want.items():
                if name in self.logins:
                    self.logins[name].ent = ent
                else:
                    self.logins[name] = Login(ent)
            logins = list(self.logins.values())
        for lg in logins:
            if woke:
                lg.force.update(lg.forwards.keys())
                for fw in lg.forwards.values():
                    # a wake is the real outage: a dead one is due now, its count starts over
                    fw.fails = 0
                    if fw.proc.poll() is not None:
                        fw.until = t
            sig = login_sig(lg)
            if lg.desired is None or woke or sig != lg.sig or t - lg.scanned >= RESCAN:
                rc, out = self.run_as(lg, ["--desired"], capture=True, timeout=120)
                if rc == 0:
                    lg.desired = set(r.strip() for r in out.splitlines() if re.match(r"^[\w.-]+/[\w.-]+$", r.strip()))
                    lg.sig, lg.scanned = sig, t
                elif lg.desired is None:
                    lg.desired = set()
                    lg.scanned = t
            drop = [(lg, r, f) for r, f in lg.forwards.items() if r not in lg.desired]
            if drop:
                self.stop_forwards(drop, "no longer an opted-in repo of a live fleet")
                for _, r, _ in drop:
                    lg.forwards.pop(r, None)
            for repo in sorted(lg.desired):
                fw = lg.forwards.get(repo)
                if fw is not None and fw.proc.poll() is None:
                    continue
                if fw is not None and fw.until == 0.0:
                    # just died: back off — a forward that lived long enough starts over
                    if t - fw.started >= BACKOFF_RESET:
                        fw.fails = 0
                    fw.fails += 1
                    backoff = min(BACKOFF_CAP, BACKOFF_BASE * (2 ** (fw.fails - 1)))
                    fw.until = t + backoff
                    log("%s: forward %s died (rc %s, fail #%d) — restart in %ds"
                        % (lg.login, repo, fw.proc.returncode, fw.fails, backoff))
                if fw is not None and t < fw.until:
                    continue
                fw = self.spawn(lg, repo, fw, t)
                if fw is not None:
                    fw.until = 0.0
        self.catchups = [(lg, p) for lg, p in self.catchups if p.poll() is None]
        self.write_state(t)

    def next_due(self, t):
        due = [fw.until for lg in self.logins.values() for fw in lg.forwards.values()
               if fw.until > t and fw.proc.poll() is not None]
        return min(due) - t if due else None

    # -- the books
    def write_state(self, t):
        with self.lock:
            logins = sorted(self.logins)
            forwards = dict((n, sorted(r for r, f in lg.forwards.items() if f.proc.poll() is None))
                            for n, lg in self.logins.items())
            groups = [{"login": n, "uid": lg.ent["uid"], "repo": r, "pid": f.proc.pid}
                      for n, lg in self.logins.items() for r, f in lg.forwards.items() if f.proc.poll() is None]
        snap = (logins, forwards, self.port)
        if snap == self.written:
            return
        lf, jf = state_files(self.p)
        tmp = lf + ".tmp.%d" % os.getpid()
        with open(tmp, "w") as f:
            f.write("%d %d\n" % (os.getpid(), int(t)))
            for n in logins:
                f.write(n + "\n")
        os.chmod(tmp, 0o644)
        os.rename(tmp, lf)
        sup.write_json(jf, {"pid": os.getpid(), "at": int(t), "port": self.port, "logins": logins,
                            "forwards": forwards, "groups": groups})
        self.written = snap

    def clear_state(self):
        for f in state_files(self.p):
            try:
                os.unlink(f)
            except OSError:
                pass

    def stop_leftovers(self):
        """Forwards an earlier run of this program left (it was killed with no
        chance to stop them — each forward is its own process group): the groups
        its book names, still led by that pid, run by that uid and forwarding
        that repo. Never a process found by its name alone."""
        old = sup.read_json(state_files(self.p)[1], {}) or {}
        victims = []
        for g in old.get("groups") or []:
            try:
                pid, uid, repo = int(g["pid"]), int(g["uid"]), str(g["repo"])
            except (KeyError, TypeError, ValueError):
                continue
            # the lock is ours: no earlier copy is alive to own them (whoever adopted them)
            if pid <= 1 or not sup.pid_alive(pid) or sup.pid_uid(pid) != uid:
                continue
            if not sup.child_group(pid) or (" --repo %s " % repo) not in (sup.pid_cmd(pid) or "") + " ":
                continue
            victims.append((pid, True))
            log("forward %s of %s pid %d: left by an earlier run — stopped" % (repo, g.get("login"), pid))
        if victims:
            sup.stop_processes(victims)

    # -- the loop
    def bind(self):
        Handler.machine = self
        for port in ([PORT] if PORT > 0 else []) + [0]:
            try:
                self.server = Server(("127.0.0.1", port), Handler)
                break
            except OSError as e:
                log("listener on 127.0.0.1:%d: %s%s" % (port, e, " — taking a free port" if port else ""))
        if self.server is None:
            raise SystemExit(1)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, name="listener", daemon=True).start()
        log("listening on 127.0.0.1:%d (one for every login)" % self.port)

    def run(self):
        os.makedirs(self.p.locks, 0o755, exist_ok=True)
        lk = os.open(os.path.join(self.p.locks, "webhook-machine.lock"), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o644)
        try:
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            log("another copy holds the lock — this one exits")
            return 1
        rfd, wfd = os.pipe()
        for fd in (rfd, wfd):
            fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) | os.O_NONBLOCK)
        signal.set_wakeup_fd(wfd)

        def on_term(signum, frame):
            self.stop = True
        signal.signal(signal.SIGTERM, on_term)
        signal.signal(signal.SIGINT, on_term)
        signal.signal(signal.SIGCHLD, lambda s, f: None)
        self.stop_leftovers()
        self.bind()
        try:
            while not self.stop:
                t, w, m = time.time(), wall(), time.monotonic()
                jump, self.drift = (w - m) - self.drift, w - m
                woke = jump >= SLACK
                if woke:
                    log("host wake (the wall clock ran %ds ahead of the monotonic one) — reconciling now" % int(jump))
                self.reconcile(t, woke)
                wait = TICK
                d = self.next_due(time.time())
                if d is not None:
                    wait = max(0.2, min(wait, d))
                try:
                    select.select([rfd], [], [], wait)
                except (OSError, ValueError) as e:
                    if getattr(e, "errno", None) != errno.EINTR:
                        time.sleep(1)
                try:
                    while os.read(rfd, 512):
                        pass
                except OSError:
                    pass
        finally:
            items = [(lg, r, f) for lg in self.logins.values() for r, f in lg.forwards.items()]
            self.stop_forwards(items, "the machine's forwarder stops")
            for _, p in self.catchups:
                if p.poll() is None:
                    p.terminate()
            if self.server is not None:
                self.server.shutdown()
            self.clear_state()
            log("stopped")
        return 0


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "run"
    paths = sup.Paths()
    if cmd == "run":
        return Machine(paths).run()
    if cmd == "status":
        st = sup.read_json(state_files(paths)[1], None)
        if st is None or not sup.pid_alive(st.get("pid") or 0):
            print("webhook-machine: not running")
            return 1
        if "--json" in argv:
            print(json.dumps(st, sort_keys=True))
        else:
            print("webhook-machine: pid %s · 127.0.0.1:%s · %d login(s)" % (st["pid"], st.get("port"), len(st.get("logins") or [])))
            for n in st.get("logins") or []:
                print("  %s: %s" % (n, ", ".join((st.get("forwards") or {}).get(n) or []) or "no repo opted in"))
        return 0
    sys.stderr.write(__doc__.split("Usage:")[1])
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
