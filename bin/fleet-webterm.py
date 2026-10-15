#!/usr/bin/env python3
"""fleet-webterm.py — a browser's ONE personal terminal on this login (issue
#4373, EPIC #3836 C4).

One logical terminal per person, bound to the login's fleet HOME pane — never
one per tab, never one per browser. The browser's connection (C1's PTY relay)
is disposable: each attach is a grouped 看台 of its own (`<fleet>@view-wt-<conn>`,
fleet-remote-view.sh `attach --thin --browser`), released when the browser
goes; the home pane and whatever runs in it stay.

    ensure [--init] [--renew]   the terminal, created once (a per-login lock):
                                the fleet's home window (made when missing, its
                                pane stamped @webterm_id, the window
                                `@reap_policy keep`). No fleet: rc 3, or with
                                --init the existing lifecycle entry brings a
                                no-repo one up (fleet-up.sh --no-repo --no-attach
                                — no issue, no agent, no orchestrator). The pane
                                lost (shell exited, server gone): rc 5 `ended` —
                                nothing is recreated until --renew (generation +1).
    status                      the same reading, nothing written: rc 0 live ·
                                3 no fleet · 4 no terminal yet · 5 ended
    select --worker <wid>       remember the session last looked at
    attach --conn <id> [--worker <wid> | --shell] [--device b64] [--lang L]
                                exec the native Fleet client on that connection:
                                the worker named (else the remembered one, if
                                still live), else the home pane; never a new one
    connect --conn <id> --target personal|worker:<fleet_id> [--generation N]
                                C1's authorized PTY entry: ensure, claim, attach,
                                renew while connected, epoch-scoped cleanup
    release --conn <id>         drop that connection's 看台 (the work stays)
    control claim|take|check|renew|release|resize --target T --conn C [--epoch E]
                                the one-controller lease per target: claim wins
                                only when free / expired / already ours (rc 4
                                `paused` otherwise — the browser offers Use here);
                                take = Use here (epoch + 1); check / renew /
                                resize / release answer rc 1 `stale` for any epoch
                                but the current one, so an old tab's input, resize
                                or cleanup never touches the new controller.
                                resize also prints the clamped `cols rows`.

State: $FLEET_CONF_DIR/webterm/ (0700): terminal.json (id, generation, the home
pane's identity, the last worker — no credential ever), control/<target>.json,
.lock. Every write is a rename. One JSON object on stdout per call.
"""
import fcntl
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time
import uuid

BIN = os.path.dirname(os.path.abspath(__file__))
SAFE = re.compile(r"[A-Za-z0-9@][A-Za-z0-9._:/-]{0,199}")
CONN = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,63}")
B64 = re.compile(r"[A-Za-z0-9+/=_-]{0,4096}")
LANG = re.compile(r"[A-Za-z0-9._@-]{0,64}")
COLS, ROWS = (20, 500), (5, 200)
ADMISSION_FD = None

def admission(obj):
    global ADMISSION_FD
    if ADMISSION_FD is not None:
        with os.fdopen(ADMISSION_FD, "w") as f:
            json.dump(obj, f); f.write("\n")
        ADMISSION_FD = None


def conf_dir():
    return os.environ.get("FLEET_CONF_DIR") or os.path.join(os.path.expanduser("~"), ".config/claude-fleet")


def state_dir():
    d = os.path.join(conf_dir(), "webterm")
    os.makedirs(os.path.join(d, "control"), mode=0o700, exist_ok=True)
    for p in (d, os.path.join(d, "control")):
        os.chmod(p, 0o700)
    return d


def out(obj, rc=0):
    admission(dict(obj, state={"paused": "open_elsewhere", "taken": "open_elsewhere", "nofleet": "ended"}.get(obj.get("state"), obj.get("state"))))
    sys.stdout.write(json.dumps(obj, sort_keys=True) + "\n")
    sys.exit(rc)


def read_json(path):
    try:
        with open(path) as f:
            v = json.load(f)
        return v if isinstance(v, dict) else None
    except (OSError, ValueError):
        return None


def write_json(path, obj):
    tmp = "%s.%d.tmp" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


class Lock:
    def __init__(self, name, nonblocking=False):
        self.path = os.path.join(state_dir(), name)
        self.nonblocking = nonblocking

    def __enter__(self):
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | (fcntl.LOCK_NB if self.nonblocking else 0))
        except BlockingIOError:
            os.close(self.fd)
            out({"state": "taken"}, 5)
        return self

    def __exit__(self, *a):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)


class ConnectionLock(Lock):
    """Dispose per-connection lock files without opening an inode reuse race."""
    def __enter__(self):
        with Lock("connections.lock"):
            return super().__enter__()

    def __exit__(self, *a):
        with Lock("connections.lock"):
            os.unlink(self.path)
            super().__exit__(*a)


def lib(cmd, *a):
    """One fleet-lib.sh function's answer (the one resolver, never a copy);
    its arguments are $2, $3, … — never spliced into the command."""
    r = subprocess.run(["bash", "-c", '. "$1/fleet-lib.sh" >/dev/null 2>&1; ' + cmd, "_", BIN] + list(a),
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True)
    return r.stdout.strip()


def fleet():
    """(session, socket) of the login's fleet — fleet-remote-view.sh's own pick."""
    s = lib("fleet_sockets | head -n 1")
    if not s:
        return None, None
    return s, lib('fleet_socket "$2"', s) or s


def tm(sock, *args):
    r = subprocess.run(["tmux", "-L", sock] + list(args), stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, universal_newlines=True)
    return r.returncode, r.stdout.rstrip("\n")


def home_window(sess, sock):
    rc, rows = tm(sock, "list-windows", "-t", "=" + sess, "-F",
                  "#{window_id}\t#{?@fleet_role,=#{@fleet_role},#{window_name}}")
    for line in rows.splitlines():
        wid, _, role = line.partition("\t")
        if role in ("=home", "home"):
            return wid
    return None


def home_pane(sock, win, tid=None):
    """The window's stamped pane (ours), else its first."""
    rc, rows = tm(sock, "list-panes", "-t", win, "-F", "#{pane_id}\t#{pane_pid}\t#{@webterm_id}\t#{pane_dead}")
    panes = [r.split("\t") for r in rows.splitlines() if r.count("\t") == 3]
    for p in panes:
        if tid and p[2] == tid:
            return p[0], ("dead" if p[3] == "1" else p[1])
    return (panes[0][0], ("dead" if panes[0][3] == "1" else panes[0][1])) if panes else (None, None)


def server_pid(sock):
    rc, v = tm(sock, "display-message", "-p", "#{pid}")
    return v if rc == 0 else ""


def reading(st):
    """(state, session, socket, window, pane): what the record's pane is now."""
    sess, sock = fleet()
    if not sess:
        # the host's fleet is gone: a terminal that existed has ENDED (its
        # processes went with the server) — said, never silently remade
        return ("ended" if st else "nofleet"), None, None, None, None
    win = home_window(sess, sock)
    if st is None:
        return "none", sess, sock, win, None
    if not win:
        return "ended", sess, sock, None, None
    pane, pid = home_pane(sock, win, st.get("id"))
    if (pane, pid, server_pid(sock), sess) != (st.get("pane"), st.get("pane_pid"),
                                               st.get("server_pid"), st.get("session")):
        return "ended", sess, sock, win, pane
    return "live", sess, sock, win, pane


def view(st, state):
    v = {"state": state}
    if st:
        for k in ("id", "generation", "session", "window", "pane", "last_worker"):
            if st.get(k) is not None:
                v[k] = st[k]
    return v


RC = {"live": 0, "nofleet": 3, "none": 4, "ended": 5}


def cmd_status(args):
    st = read_json(os.path.join(state_dir(), "terminal.json"))
    state = reading(st)[0]
    out(view(st, state), RC[state])


def cmd_ensure(args):
    init, renew = "--init" in args, "--renew" in args
    path = os.path.join(state_dir(), "terminal.json")
    with Lock(".lock"):
        st = read_json(path)
        state, sess, sock, win, _ = reading(st)
        if sess is None and init:
            up = os.environ.get("FLEET_WEBTERM_UP_CMD")   # the selftest's seam
            subprocess.run(["sh", "-c", up] if up else
                           ["bash", os.path.join(BIN, "fleet-up.sh"), "--no-repo", "--no-attach"],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            state, sess, sock, win, _ = reading(st)
        if sess is None:
            out(view(st, state), RC[state])
        if state == "live":
            out(view(st, state))
        if state == "ended" and not renew:
            out(view(st, state), 5)
        if not win:
            rc, win = tm(sock, "new-window", "-d", "-P", "-F", "#{window_id}", "-t", "=%s:" % sess, "-n", "home")
            if rc != 0 or not win:
                out({"state": "error", "error": "no home window"}, 1)
            lib('fleet_home_resident "$2" "$3" "$4"', sock, sess, win)
        pane, pid = home_pane(sock, win, (st or {}).get("id"))
        if pid == "dead":
            tm(sock, "respawn-pane", "-k", "-t", pane)
            pane, pid = home_pane(sock, win, (st or {}).get("id"))
        if not pane or pid == "dead":
            out({"state": "error", "error": "no home pane"}, 1)
        new = {"id": (st or {}).get("id") or str(uuid.uuid4()),
               "generation": int((st or {}).get("generation") or 0) + 1,
               "session": sess, "window": win, "pane": pane, "pane_pid": pid,
               "server_pid": server_pid(sock), "created": int(time.time()),
               "last_worker": (st or {}).get("last_worker")}
        tm(sock, "set-option", "-p", "-t", pane, "@webterm_id", new["id"])
        tm(sock, "set-option", "-w", "-t", win, "@webterm_home", new["id"])
        tm(sock, "set-option", "-w", "-t", win, "@reap_policy", "keep")
        write_json(path, new)
        out(view(new, "live"))


def opt(args, name, rx=SAFE, need=False):
    if name in args:
        i = args.index(name)
        v = args[i + 1] if i + 1 < len(args) else ""
        if not rx.fullmatch(v):
            out({"state": "error", "error": "bad " + name}, 2)
        return v
    if need:
        out({"state": "error", "error": "missing " + name}, 2)
    return None


def cmd_select(args):
    w = opt(args, "--worker", need=True)
    path = os.path.join(state_dir(), "terminal.json")
    with Lock(".lock"):
        st = read_json(path)
        if st is None:
            out(view(None, "none"), 4)
        st["last_worker"] = w
        write_json(path, st)
    out(view(st, "live"))


def worker_live(sess, sock, wid):
    """The window a worker id names here (fleet-remote-view.sh's own rule)."""
    c = wid[4:] if wid.startswith("wid:") else wid
    rc, rows = tm(sock, "list-windows", "-t", "=" + sess, "-F", "#{window_id}|#{@fleet_id}|#{@peer_cur}")
    for line in rows.splitlines():
        w, fid, pc = (line.split("|") + ["", ""])[:3]
        if w == c or (c.startswith("worker:") and fid == c[7:]) or ("/" in c and ((fid and fid == c.rsplit("/", 1)[1]) or pc in (c, "wid:" + c))):
            return w
    return None


def cmd_attach(args):
    conn = opt(args, "--conn", CONN, need=True)
    worker = opt(args, "--worker")
    device = opt(args, "--device", B64) or ""
    lang = opt(args, "--lang", LANG)
    generation = opt(args, "--generation", re.compile(r"[0-9]+"))
    st = read_json(os.path.join(state_dir(), "terminal.json"))
    state, sess, sock, win, _ = reading(st)
    if state != "live":
        out(view(st, state), RC[state])
    if generation is not None and str(st.get("generation")) != generation:
        out(view(st, "ended"), 5)
    want = None
    if "--shell" not in args:
        want = worker or st.get("last_worker")
        if want and not worker and not worker_live(sess, sock, want):
            out(view(st, "ended"), 5)
    argv = ["bash", os.path.join(BIN, "fleet-remote-view.sh"), "attach", "--thin", "--browser",
            "--view", "wt-" + conn, "--home", win, "--route", "webterm", "--device", device]
    if want:
        argv += ["--want", worker_live(sess, sock, want) or want]
    if lang is not None:
        argv += ["--lang", lang]
    env = dict(os.environ)
    env.pop("TMUX", None)
    env.pop("TMUX_PANE", None)
    sys.stdout.flush()
    os.execvpe(argv[0], argv, env)


def close_view(lease):
    """Fence a connected controller before replacing its epoch. Session ids
    are never reused by a running tmux server; also check the connection mark.
    No worker/home window is killed, and no newer view is looked up by name.
    """
    sock, gid = lease.get("socket"), lease.get("view")
    if sock and gid and lease.get("conn") and server_pid(sock) == lease.get("server_pid"):
        rc, rows = tm(sock, "list-sessions", "-F", "#{session_id}|#{session_name}")
        if rc == 0 and gid + "|" + lease.get("session", "") in rows.splitlines():
            return tm(sock, "kill-session", "-t", gid)[0] == 0
    return True


def cmd_connect(args):
    """C1's authorized PTY entry. C3 can claim/take with the SAME target/conn
    before calling connect, and pass --generation on reconnect. No automatic
    take or renew of an ended terminal. Wire hello/status remains C3's job.
    """
    global ADMISSION_FD
    fd = os.environ.pop("FLEET_TERM_ADMISSION_FD", "")
    if fd == "3":
        ADMISSION_FD = 3
        os.set_inheritable(3, False)
    conn = opt(args, "--conn", CONN, need=True)
    target = opt(args, "--target", re.compile(r"personal|worker:[A-Za-z0-9-]+"), need=True)
    generation = opt(args, "--generation", re.compile(r"[0-9]+"))
    # Hold this until cleanup finishes: duplicate relay ids may neither attach
    # nor remove the first connection's resources.
    with ConnectionLock("conn-" + conn + ".lock", nonblocking=True):
        try:
            return connect(args, conn, target, generation)
        finally:
            admission({"state": "ended"})


def connect(args, conn, target, generation):
    sess, sock = fleet()
    worker = None
    if target.startswith("worker:"):
        if not sess:
            out({"state": "nofleet"}, 3)
        # Only the exact fleet_id authorized by C1, never a window name/path or
        # another host. Revalidate in attach before creating any grouped view.
        rc, rows = tm(sock, "list-windows", "-t", "=" + sess, "-F", "#{window_id}|#{@fleet_id}")
        matches = [r.split("|")[0] for r in rows.splitlines() if r.partition("|")[2] == target[7:]]
        if len(matches) != 1:
            out({"state": "ended", "target": target}, 4)
        worker = matches[0]
    # Only first use may initialize the no-repo fleet/home. --renew is never
    # implicit; a previously lost pane or server stays ended.
    st = read_json(os.path.join(state_dir(), "terminal.json"))
    if generation is not None and (not st or str(st.get("generation")) != generation):
        out(view(st, "ended"), 5)
    resume = os.environ.pop("FLEET_TERM_RESUME", "")
    if resume and (not st or resume != "%s:%s" % (st.get("id"), st.get("generation"))):
        out({"state": "interrupted"}, 5)
    take = os.environ.pop("FLEET_TERM_TAKE", "") == "1"
    ensure = [sys.executable, __file__, "ensure"]
    if target == "personal" and not st:
        ensure += ["--init"]
    r = subprocess.run(ensure, stdout=subprocess.PIPE, universal_newlines=True)
    if r.returncode:
        sys.stdout.write(r.stdout)
        sys.exit(r.returncode)
    st = json.loads(r.stdout)
    if generation is not None and str(st.get("generation")) != generation:
        out(view(st, "ended"), 5)
    sess, sock = fleet()
    if tm(sock, "has-session", "-t", "=%s@view-wt-%s" % (sess, conn))[0] == 0:
        out({"state": "taken"}, 5)
    path = control_path(target)
    child, lease = None, None
    stopped = [False]
    for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *a: stopped.__setitem__(0, True))
    try:
        # Serialize claim AND view creation with take. An epoch cannot be
        # handed over while an old attachment is still about to appear.
        with Lock("control/.lock"), Lock(".lock"):
            current = read_json(os.path.join(state_dir(), "terminal.json"))
            if not current or current.get("generation") != st["generation"] or reading(current)[0] != "live":
                out(view(current, "ended"), 5)
            lease, rc = control_claim(path, target, conn, "take" if take else "claim")
            if rc:
                out(lease, rc)
            selected = target
            if target == "personal":
                selected = current.get("last_worker") or "personal"
                if selected != "personal":
                    worker = worker_live(sess, sock, selected)
                    if not worker:
                        out({"state": "ended"}, 5)
            if selected != target:
                secondary, rc = control_claim(control_path(selected), selected, conn, "take" if take else "claim")
                if rc: out(secondary, rc)
                lease.update(selected_lease=control_path(selected), selected_epoch=secondary["epoch"])
            write_json(path, lease)
            write_json(connection_path(conn), {"target": target, "epoch": lease["epoch"]})
            argv = [sys.executable, __file__, "attach", "--conn", conn, "--generation", str(st["generation"])]
            if worker:
                argv += ["--worker", worker]
            child = subprocess.Popen(argv)
            deadline = time.monotonic() + 15
            g = "%s@view-wt-%s" % (sess, conn)
            attached = False
            while child.poll() is None and not stopped[0] and time.monotonic() < deadline:
                rc, gid = tm(sock, "display-message", "-p", "-t", "=" + g + ":", "#{session_id}")
                if rc == 0 and gid.startswith("$"):
                    lease.update(socket=sock, view=gid, session=g, server_pid=server_pid(sock), generation=st["generation"])
                    write_json(path, lease)
                    tm(sock, "set-option", "-t", gid, "@webterm_conn", conn)
                    if lease.get("selected_lease"):
                        secondary = read_json(lease["selected_lease"]) or {}
                        secondary.update({k: lease[k] for k in ("socket", "view", "session", "server_pid")})
                        write_json(lease["selected_lease"], secondary)
                    if tm(sock, "list-clients", "-t", "=" + g, "-F", "#{client_pid}")[1]:
                        attached = True
                        break
                time.sleep(0.05)
            if not attached:
                return 1
        admission({"state": "controller", "term": st["id"], "gen": "%s:%s" % (st["id"], st["generation"]),
                   "conn": conn, "epoch": lease["epoch"], "lease": path, "ttl": lease_secs(),
                   "lock": os.path.join(state_dir(), "control/.lock")})
        while child.poll() is None and not stopped[0]:
            with Lock("control/.lock"):
                current = read_json(path) or {}
                if (current.get("conn"), current.get("epoch")) != (conn, lease["epoch"]):
                    break
                if time.time() - current["ts"] > lease_secs() / 3:
                    current["ts"] = time.time()
                    write_json(path, current)
                    if current.get("selected_lease"):
                        secondary = read_json(current["selected_lease"]) or {}
                        if (secondary.get("conn"), secondary.get("epoch")) != (conn, current["selected_epoch"]):
                            break
                        secondary["ts"] = current["ts"]
                        write_json(current["selected_lease"], secondary)
            time.sleep(0.2)
        return child.returncode or 0
    finally:
        # A stale connection only disposes its captured view and subprocess;
        # release the lease iff we still own the very same epoch.
        closed = not lease or close_view(lease)
        if child and child.poll() is None:
            try:
                # Closing the view makes tmux return. Let the native attach's
                # EXIT trap finish its row/peer cleanup before sending TERM;
                # a signal DURING that trap can interrupt the cleanup itself.
                child.wait(timeout=1)
            except subprocess.TimeoutExpired:
                child.terminate()
                try:
                    child.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
        if closed and lease and "epoch" in lease:
            with Lock("control/.lock"):
                current = read_json(path) or {}
                if (current.get("conn"), current.get("epoch")) == (conn, lease["epoch"]):
                    release_selected(current)
                    current.update(conn=None, ts=0)
                    write_json(path, current)
            try:
                os.unlink(connection_path(conn))
            except FileNotFoundError:
                pass


def attach_pids(conn):
    """This login's attach processes for that connection (the attach and the
    subshells it backgrounds carry its argv) — never anyone else's."""
    want = "fleet-remote-view.sh attach --thin --browser --view wt-%s " % conn
    r = subprocess.run(["ps", "-ax", "-o", "pid=", "-o", "uid=", "-o", "command="],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True)
    pids = []
    for line in r.stdout.splitlines():
        f = line.split(None, 2)
        if len(f) == 3 and f[1] == str(os.getuid()) and want in f[2] + " " and int(f[0]) != os.getpid():
            pids.append(int(f[0]))
    return pids


def cmd_release(args):
    conn = opt(args, "--conn", CONN, need=True)
    for sig in (15, 9):
        pids = attach_pids(conn)
        for p in pids:
            try:
                os.kill(p, sig)
            except OSError:
                pass
        for _ in range(10):
            if not attach_pids(conn):
                break
            time.sleep(0.1)
    sess, sock = fleet()
    gone = False
    if sess:
        g = "%s@view-wt-%s" % (sess, conn)
        if tm(sock, "has-session", "-t", "=" + g)[0] == 0:
            gone = tm(sock, "kill-session", "-t", "=" + g)[0] == 0
    try:
        os.unlink(os.path.join(conf_dir(), "remote-views", "wt-" + conn))
    except OSError:
        pass
    out({"state": "released", "conn": conn, "view_closed": gone})


def lease_secs():
    try:
        return max(5, int(os.environ.get("FLEET_WEBTERM_LEASE_SECS", "30")))
    except ValueError:
        return 30


def clamp(v, lo_hi):
    try:
        n = int(v)
    except (TypeError, ValueError):
        out({"state": "error", "error": "bad size"}, 2)
    return max(lo_hi[0], min(lo_hi[1], n))


def connection_path(conn):
    return os.path.join(state_dir(), "connection-" + conn + ".json")


def release_selected(lease):
    path = lease.get("selected_lease")
    if path:
        current = read_json(path) or {}
        if (current.get("conn"), current.get("epoch")) == (lease.get("conn"), lease.get("selected_epoch")):
            current.update(conn=None, ts=0)
            write_json(path, current)


def cmd_switch(args):
    """Native menu/shell selection and control ownership are one transaction."""
    conn = opt(args, "--conn", CONN, need=True)
    win = opt(args, "--window", re.compile(r"@[0-9]+"), need=True)
    with Lock("control/.lock"):
        binding = read_json(connection_path(conn)) or {}
        path = control_path(binding.get("target", ""))
        lease = read_json(path) or {}
        if (lease.get("conn"), lease.get("epoch")) != (conn, binding.get("epoch")) or not lease.get("view"):
            out({"state": "stale"}, 4)
        sock, gid = lease["socket"], lease["view"]
        rc, identity = tm(sock, "display-message", "-p", "-t", gid + ":" + win, "#{@fleet_id}|#{@webterm_home}")
        fid, _, home = identity.partition("|")
        if rc or (not fid and not home):
            out({"state": "ended"}, 4)
        target = "personal" if home else "worker:" + fid
        selected = None
        if target != binding["target"]:
            selected, rc = control_claim(control_path(target), target, conn, "claim")
            if rc: out(selected, rc)
            selected.update({k: lease[k] for k in ("socket", "view", "session", "server_pid")})
            write_json(control_path(target), selected)
        rc, _ = tm(sock, "select-window", "-t", gid + ":" + win)
        if rc: out({"state": "ended"}, 4)
        if lease.get("selected_lease") != control_path(target):
            release_selected(lease)
        lease.pop("selected_lease", None); lease.pop("selected_epoch", None)
        if selected:
            lease.update(selected_lease=control_path(target), selected_epoch=selected["epoch"])
        write_json(path, lease)
        if binding["target"] == "personal":
            with Lock(".lock"):
                stpath = os.path.join(state_dir(), "terminal.json")
                st = read_json(stpath)
                if st:
                    st["last_worker"] = None if home else target
                    write_json(stpath, st)
        out({"state": "controller"})


def control_path(target):
    return os.path.join(state_dir(), "control", hashlib.sha256(target.encode()).hexdigest()[:32] + ".json")


def control_claim(path, target, conn, op):
    L = read_json(path) or {"target": target, "epoch": 0, "conn": None, "ts": 0}
    fresh = L.get("conn") and time.time() - float(L.get("ts") or 0) < lease_secs()
    if op == "claim" and fresh and L["conn"] != conn:
        return {"state": "paused", "target": target, "epoch": L["epoch"]}, 4
    if L.get("conn") != conn or op == "take":
        if not close_view(L):  # fence old PTY before another epoch may attach
            return {"state": "error", "error": "old controller could not be closed"}, 1
        release_selected(L)
        L = {"target": target, "epoch": int(L["epoch"]) + 1}
    L.update(conn=conn, ts=time.time(), state="controller")
    write_json(path, L)
    return L, 0


def cmd_control(args):
    if not args or args[0] not in ("claim", "take", "check", "renew", "release", "resize"):
        out({"state": "error", "error": "control claim|take|check|renew|release|resize"}, 2)
    op = args[0]
    target = opt(args, "--target", need=True)
    conn = opt(args, "--conn", CONN, need=True)
    epoch = opt(args, "--epoch", re.compile(r"[0-9]{1,12}"), need=op not in ("claim", "take"))
    path = control_path(target)
    now = time.time()
    with Lock("control/.lock"):
        L = read_json(path) or {"target": target, "epoch": 0, "conn": None, "ts": 0}
        mine = L.get("conn") == conn and (epoch is None or int(epoch) == L["epoch"])
        if op in ("claim", "take"):
            result, rc = control_claim(path, target, conn, op)
            out(result, rc)
        if not mine or epoch is None or int(epoch) != L["epoch"]:
            out({"state": "stale", "target": target, "epoch": L["epoch"]}, 1)
        if op == "release":
            if not close_view(L):
                out({"state": "error", "error": "controller could not be closed"}, 1)
            L.update(conn=None, ts=0)
            write_json(path, L)
            out({"state": "released", "target": target, "epoch": L["epoch"]})
        if op == "renew":
            L["ts"] = now
            write_json(path, L)
        res = {"state": "controller", "target": target, "epoch": L["epoch"]}
        if op == "resize":
            res["cols"] = clamp(opt(args, "--cols", re.compile(r"[0-9]{1,6}"), need=True), COLS)
            res["rows"] = clamp(opt(args, "--rows", re.compile(r"[0-9]{1,6}"), need=True), ROWS)
        out(res)


def main(argv):
    cmds = {"ensure": cmd_ensure, "status": cmd_status, "select": cmd_select,
            "attach": cmd_attach, "connect": cmd_connect, "switch": cmd_switch, "release": cmd_release, "control": cmd_control}
    if not argv or argv[0] not in cmds:
        sys.stderr.write(__doc__)
        return 2
    return cmds[argv[0]](argv[1:]) or 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
