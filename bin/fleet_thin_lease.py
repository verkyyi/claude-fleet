#!/usr/bin/env python3
"""fleet_thin_lease.py — the home machine holds a thin client's lease, and its
notifications go to that client's terminal (issue #3005, EPIC #2999 C8).

A thin client (bin/fleet-thin.py) runs no loop of its own: it attaches a 看台
here (`fleet-remote-view.sh attach --thin`) and says once where it is (the
registry row's `device=`, base64 JSON — fleet-client-lease.py's `where`). So this
machine does what the client's own loops did:

  beat     on the collector's beat (fleet-hub-sessions.sh --loop, every round):
           for every thin 看台 here with a client attached, acquire / renew the
           person's client lease with the NODE token (POST /v1/node/client) —
           device / os / terminal from `device=`, via thin, host this machine,
           last input the client's #{client_activity}, viewing its `cur=` — at
           most every FLEET_THIN_LEASE_RENEW (15 s) unless the client was used;
           a 看台 nobody is attached to any more is released and no longer
           renewed. A `<id>-via-<home>` 看台 (C4: another home's window onto
           this machine) is never leased — its home holds the person's lease.
           A lease the hub says was taken over (the person's other clients past
           the limit) is not asked for again until the 看台 gets a new client.
           The book is $FLEET_CONF_DIR/thin-lease.json (views · primary · at).
  holder   the 看台 HERE holding the person's PRIMARY lease, one JSON line
           {view, sess, session, tty, termtype, focused}; exit 1 = none — no
           thin 看台, no hub, or the person is on another client / machine.
  notify   fleet_notify.beat's sender on the home machine: OSC 9 to the holder's
           terminal (fleet-client-escape.sh — the one escape channel), and
           `@notify_jump "<epoch> <wid:…>"` on the 看台 session while its
           terminal is not in front, for the focus-in to take
           (fleet-remote-view.sh notify-jump). No holder ⇒ nothing sent ("no
           lease"): one person, one notification — only the machine whose 看台
           holds the primary sends.
  where    no hub here: the newest thin 看台 with a client attached, as
           fleet-client-where.sh's local source reads it (JSON, exit 3 = none).

No thin 看台 ever here ⇒ no book, nothing asked, nothing sent — byte for byte as
before. Seams (tests): FLEET_THIN_LEASE_CMD (the hub call: the JSON body on
stdin, the answer on stdout), FLEET_THIN_ESCAPE_CMD (the writer: the escape on
stdin, `--socket --session --client` argv), FLEET_THIN_TMUX (tmux).
"""
import base64
import importlib.util
import json
import os
import shlex
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
RENEW = 15
TAKEN_RETRY = 600


def conf_dir():
    return os.environ.get("FLEET_CONF_DIR") or os.path.join(os.path.expanduser("~"), ".config", "claude-fleet")


def views_dir():
    return os.path.join(conf_dir(), "remote-views")


def book_path():
    return os.path.join(conf_dir(), "thin-lease.json")


def tmux_bin():
    return os.environ.get("FLEET_THIN_TMUX") or "tmux"


def tmux(sock, *args):
    try:
        r = subprocess.run([tmux_bin(), "-L", sock] + list(args), capture_output=True, text=True, timeout=5,
                           stdin=subprocess.DEVNULL)
        return r.stdout if r.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def socket_path(sock):
    return tmux(sock, "display-message", "-p", "#{socket_path}").strip()


def rows():
    """{view: row} of every thin 看台 registered here."""
    out = {}
    try:
        names = sorted(os.listdir(views_dir()))
    except OSError:
        return out
    for v in names:
        p = os.path.join(views_dir(), v)
        if v.startswith(".") or not os.path.isfile(p):
            continue
        try:
            with open(p, encoding="utf-8") as f:
                cols = f.readline().rstrip("\n").split("\t")
        except OSError:
            continue
        if len(cols) < 5 or cols[2] != "thin":
            continue
        r = {"view": v, "tty": cols[0], "sess": cols[1], "since": cols[3], "pid": cols[4]}
        for kv in cols[5:]:
            k, eq, val = kv.partition("=")
            if eq:
                r[k] = val
        out[v] = r
    return out


_CLIENTS = {}


def clients(sess):
    """[{session, tty, activity, termtype, focused}] of every client of a fleet's server."""
    if sess not in _CLIENTS:
        cl = []
        for line in tmux(sess, "list-clients", "-F",
                         "#{client_session}\t#{client_tty}\t#{client_activity}\t#{client_termtype}\t#{client_flags}"
                         ).splitlines():
            p = line.split("\t")
            if len(p) < 5:
                continue
            try:
                act = int(p[2])
            except ValueError:
                act = 0
            cl.append({"session": p[0], "tty": p[1], "activity": act, "termtype": p[3],
                       "focused": "focused" in p[4].split(",")})
        _CLIENTS[sess] = cl
    return _CLIENTS[sess]


def attached(r):
    """The newest client attached to a 看台's session, or None."""
    want = "%s@view-%s" % (r["sess"], r["view"])
    cl = [c for c in clients(r["sess"]) if c["session"] == want]
    return max(cl, key=lambda c: c["activity"]) if cl else None


def device_of(r):
    try:
        d = json.loads(base64.b64decode(r.get("device") or "").decode("utf-8"))
        return d if isinstance(d, dict) else {}
    except (ValueError, UnicodeDecodeError):
        return {}


def caps_of(dev, termtype):
    """What the person's terminal can do through this machine's tmux: an OSC 9
    always (a terminal that does not know it ignores it); open / show / the
    iTerm2 script with an iTerm2; else a link."""
    term = "%s %s" % (dev.get("terminal") or "", termtype or "")
    return ["notify", "open_url", "show_file", "iterm2"] if "iterm" in term.lower() else ["notify", "link"]


def load_book():
    try:
        with open(book_path(), encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def save_book(d):
    p = book_path()
    tmp = "%s.%d" % (p, os.getpid())
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False, sort_keys=True)
        os.replace(tmp, p)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def lease_mod():
    spec = importlib.util.spec_from_file_location("fleet_client_lease", os.path.join(HERE, "fleet-client-lease.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def hub_call(body):
    """The hub's answer to one POST /v1/node/client: (dict, why). dict None =
    not asked / not answered; why 'nohub' = no node token here, or a hub without
    the door (404 / 405)."""
    seam = os.environ.get("FLEET_THIN_LEASE_CMD")
    if seam:
        try:
            r = subprocess.run(shlex.split(seam), input=json.dumps(body), capture_output=True, text=True, timeout=15)
            return (json.loads(r.stdout or "{}"), "") if r.returncode == 0 else (None, "seam rc %d" % r.returncode)
        except (OSError, ValueError, subprocess.SubprocessError) as e:
            return None, str(e)
    import urllib.error
    import urllib.request
    m = lease_mod()
    url, tok = m.node_pair(os.environ.get("FLEET_HUB_URL") or "")
    if not url or not tok:
        return None, "nohub"
    req = urllib.request.Request(url.rstrip("/") + "/v1/node/client", data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": "Bearer " + tok})
    try:
        with urllib.request.urlopen(req, timeout=float(os.environ.get("FLEET_CLIENT_LEASE_TIMEOUT") or 8)) as r:
            return json.loads(r.read() or b"{}"), ""
    except urllib.error.HTTPError as e:
        return None, "nohub" if e.code in (404, 405) else "HTTP %d" % e.code
    except (OSError, ValueError) as e:
        return None, str(e)


def this_machine(r):
    return r.get("node") or os.uname()[1].split(".", 1)[0]


def beat(now=None):
    """One round: the leases of this machine's thin 看台 kept, the gone ones
    released. Returns the book."""
    now = int(time.time() if now is None else now)
    _CLIENTS.clear()
    rs = rows()
    book = load_book()
    if not rs and not book:
        return {}                              # never a thin 看台 here: nothing at all
    views = book.get("views") if isinstance(book.get("views"), dict) else {}
    every = int(os.environ.get("FLEET_THIN_LEASE_RENEW") or RENEW)
    if book.get("nohub") and now - int(book.get("nohub") or 0) < TAKEN_RETRY:
        rs = {}                                # an older hub / no token: ask again later
        views = {}
    primary = book.get("primary") or ""
    nohub = 0
    for v, r in rs.items():
        if "-via-" in v:
            continue                           # another home's window here: its home holds the lease
        c = attached(r)
        if c is None:
            continue
        cur = views.get(v) or {}
        if cur.get("taken") and cur.get("pid") == r["pid"] and now - int(cur.get("at") or 0) < TAKEN_RETRY:
            continue                           # asked to leave: not again until a new client comes
        dev = device_of(r)
        body = {"device": dev.get("device") or "", "os": dev.get("os") or "",
                "terminal": dev.get("terminal") or c["termtype"] or "", "via": "thin", "host": this_machine(r),
                "caps": caps_of(dev, c["termtype"]), "viewing": r.get("cur", "") if "/" in r.get("cur", "") else ""}
        if c["activity"] > 0:
            body["last_input"] = c["activity"]
        lease = cur.get("lease") or ""        # a reconnect of the same 看台 keeps its lease
        used = c["activity"] > int(cur.get("act") or 0)
        if lease and not used and now - int(cur.get("at") or 0) < every:
            continue
        body["action"] = "renew" if lease else "acquire"
        if lease:
            body["lease"] = lease
        d, why = hub_call(body)
        if d is None:
            if why == "nohub":
                nohub = now
                break
            continue                           # out of reach: the next round asks again
        st = d.get("state") or ""
        if st == "active" and d.get("lease"):
            views[v] = {"lease": d["lease"].get("id") or lease, "at": now, "act": c["activity"], "pid": r["pid"]}
            primary = d.get("primary") or primary
        else:
            views[v] = {"taken": st or "none", "at": now, "pid": r["pid"]}
    # a 看台 gone, or with nobody attached: its lease goes
    for v in list(views):
        r = rs.get(v)
        if r is not None and "-via-" not in v and attached(r) is not None:
            continue
        lid = (views.pop(v) or {}).get("lease")
        if lid:
            hub_call({"action": "release", "lease": lid})
    out = {"views": views, "primary": primary if views else "", "at": now}
    if nohub:
        out["nohub"] = nohub
    save_book(out)
    return out


def holder():
    """The 看台 here holding the person's primary lease, or None."""
    book = load_book()
    prim = book.get("primary") or ""
    views = book.get("views") if isinstance(book.get("views"), dict) else {}
    if not prim:
        return None
    _CLIENTS.clear()
    rs = rows()
    for v, b in views.items():
        if b.get("lease") != prim or v not in rs:
            continue
        r = rs[v]
        c = attached(r)
        if c is None:
            return None
        return {"view": v, "sess": r["sess"], "session": c["session"], "tty": c["tty"], "termtype": c["termtype"],
                "focused": c["focused"]}
    return None


def osc9(title, body):
    msg = ("%s: %s" % (title, body) if body else title)
    msg = "".join(ch if ch >= " " and ch != "\x7f" else " " for ch in msg)
    return ("\033]9;%s\a" % msg).encode("utf-8")


def write_escape(h, data):
    """(ok, why): the escape on the holder's terminal, through the one channel."""
    seam = os.environ.get("FLEET_THIN_ESCAPE_CMD")
    sock = socket_path(h["sess"]) if not seam else h["sess"]
    argv = (shlex.split(seam) if seam else ["bash", os.path.join(HERE, "fleet-client-escape.sh")]) + [
        "--socket", sock, "--session", h["sess"], "--client", h["tty"]]
    try:
        r = subprocess.run(argv, input=data, capture_output=True, timeout=20)
    except (OSError, subprocess.SubprocessError) as e:
        return False, str(e)
    return r.returncode == 0, (r.stderr.decode("utf-8", "replace").strip().splitlines() or [""])[-1]


def notify(title, body, jump, key, state):
    import fleet_notify
    h = holder()
    if h is None:
        fleet_notify.log({"key": key, "state": state, "skip": "no-lease"})
        return 1
    if jump and not h["focused"]:
        tmux(h["sess"], "set-option", "-t", "=" + h["session"] + ":", "@notify_jump", "%d %s" % (time.time(), jump))
    ok, why = write_escape(h, osc9(title, body))
    rec = {"key": key, "state": state, "via": "thin:" + h["view"]}
    rec.update({"sent": "osc9"} if ok else {"skip": "escape:" + (why or "failed")})
    fleet_notify.log(rec)
    return 0 if ok else 1


def where():
    """No hub: the newest thin 看台 with a client attached here — its device."""
    best = None
    for v, r in rows().items():
        if "-via-" in v:
            continue
        c = attached(r)
        if c and (best is None or c["activity"] > best[1]["activity"]):
            best = (r, c)
    if best is None:
        return None
    r, c = best
    dev = device_of(r)
    return {"device": dev.get("device") or "未知设备", "os": dev.get("os") or "",
            "terminal": dev.get("terminal") or c["termtype"] or "", "via": "thin", "host": this_machine(r),
            "caps": caps_of(dev, c["termtype"]), "since": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(r["since"])))
            if r["since"].isdigit() else ""}


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="fleet_thin_lease")
    ap.add_argument("action", choices=["beat", "holder", "notify", "where"])
    for k in ("title", "body", "jump", "session", "group", "log-key", "log-state"):
        ap.add_argument("--" + k, default="")
    ap.add_argument("--sound", action="store_true")
    ap.add_argument("--phone", action="store_true")
    a = ap.parse_args(argv)
    if a.action == "beat":
        beat()
        return 0
    if a.action == "holder":
        h = holder()
        if h is None:
            return 1
        print(json.dumps(h, ensure_ascii=False))
        return 0
    if a.action == "where":
        w = where()
        if w is None:
            return 3
        print(json.dumps(w, ensure_ascii=False))
        return 0
    sys.path.insert(0, HERE)
    return notify(a.title or "fleet", a.body, a.jump, a.log_key, a.log_state)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
