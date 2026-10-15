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


def conf_dir():
    return os.environ.get("FLEET_CONF_DIR") or os.path.join(os.path.expanduser("~"), ".config/claude-fleet")


def state_dir():
    d = os.path.join(conf_dir(), "webterm")
    os.makedirs(os.path.join(d, "control"), mode=0o700, exist_ok=True)
    for p in (d, os.path.join(d, "control")):
        os.chmod(p, 0o700)
    return d


def out(obj, rc=0):
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
    def __init__(self, name):
        self.path = os.path.join(state_dir(), name)

    def __enter__(self):
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *a):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)


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
        if w == c or ("/" in c and ((fid and fid == c.rsplit("/", 1)[1]) or pc in (c, "wid:" + c))):
            return w
    return None


def cmd_attach(args):
    conn = opt(args, "--conn", CONN, need=True)
    worker = opt(args, "--worker")
    device = opt(args, "--device", B64) or ""
    lang = opt(args, "--lang", LANG)
    st = read_json(os.path.join(state_dir(), "terminal.json"))
    state, sess, sock, win, _ = reading(st)
    if state != "live":
        out(view(st, state), RC[state])
    want = None
    if "--shell" not in args:
        want = worker or st.get("last_worker")
        if want and not worker and not worker_live(sess, sock, want):
            want = None          # the remembered one is gone: home, never a replacement
    argv = ["bash", os.path.join(BIN, "fleet-remote-view.sh"), "attach", "--thin", "--browser",
            "--view", "wt-" + conn, "--home", win, "--route", "webterm", "--device", device]
    if want:
        argv += ["--want", want]
    if lang is not None:
        argv += ["--lang", lang]
    env = dict(os.environ)
    env.pop("TMUX", None)
    env.pop("TMUX_PANE", None)
    sys.stdout.flush()
    os.execvpe(argv[0], argv, env)


def cmd_release(args):
    conn = opt(args, "--conn", CONN, need=True)
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


def cmd_control(args):
    if not args or args[0] not in ("claim", "take", "check", "renew", "release", "resize"):
        out({"state": "error", "error": "control claim|take|check|renew|release|resize"}, 2)
    op = args[0]
    target = opt(args, "--target", need=True)
    conn = opt(args, "--conn", CONN, need=True)
    epoch = opt(args, "--epoch", re.compile(r"[0-9]{1,12}"), need=op not in ("claim", "take"))
    path = os.path.join(state_dir(), "control", hashlib.sha256(target.encode()).hexdigest()[:32] + ".json")
    now = time.time()
    with Lock("control/.lock"):
        L = read_json(path) or {"target": target, "epoch": 0, "conn": None, "ts": 0}
        fresh = L.get("conn") and now - float(L.get("ts") or 0) < lease_secs()
        mine = L.get("conn") == conn and (epoch is None or int(epoch) == L["epoch"])
        if op in ("claim", "take"):
            if op == "claim" and fresh and L["conn"] != conn:
                out({"state": "paused", "target": target, "epoch": L["epoch"]}, 4)
            if L.get("conn") != conn or op == "take":
                L["epoch"] = int(L["epoch"]) + 1
            L.update(conn=conn, ts=now)
            write_json(path, L)
            out({"state": "controller", "target": target, "epoch": L["epoch"]})
        if not mine or epoch is None or int(epoch) != L["epoch"]:
            out({"state": "stale", "target": target, "epoch": L["epoch"]}, 1)
        if op == "release":
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
            "attach": cmd_attach, "release": cmd_release, "control": cmd_control}
    if not argv or argv[0] not in cmds:
        sys.stderr.write(__doc__)
        return 2
    cmds[argv[0]](argv[1:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
