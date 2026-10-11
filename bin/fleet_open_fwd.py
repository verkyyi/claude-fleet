"""fleet_open_fwd.py — the person's side of a forwarded page or OAuth callback
(issue #3236): ONE bookkeeping for the thin loop (fleet-thin.py) and the
client's action loop (fleet-client-actions.py).

A session on a machine asks the person's computer to open a page; when the page
is on that machine's loopback (`rport`) or is an OAuth page whose callback server
listens there (`cport`), the person's side forwards a local port over its own
ssh to 127.0.0.1:<port> on that machine first. This module keeps those forwards
honest:

  * a callback port is forwarded AS ITSELF (localhost:P here ⇒ 127.0.0.1:P
    there) — the browser's redirect names that port; busy here ⇒ refused;
  * every forward says one line (`notice`) — the port, the session it is for,
    when it closes — and one TSV line in the log (open · close · fail);
  * it closes as soon as the far end's server is gone (a probe through it:
    connected and at once closed ⇒ nothing listens there any more), or at its
    deadline (FLEET_OPEN_CALLBACK_SECS, 600; a page FLEET_OPEN_PAGE_SECS, 1800).

Log TSV (fields only ever added at the end):
    time(UTC)  event  port  machine  who  lport  reason
Standard library only.
"""
import os
import select
import socket
import threading
import time

GRACE = 15        # never probe a forward younger than this (the page is loading)
EVERY = 5         # one probe per forward per this many seconds


def env_num(name, default):
    try:
        return float(os.environ.get(name) or default)
    except ValueError:
        return float(default)


def free(port):
    """True when 127.0.0.1:<port> can be listened on here (as ssh's -L listens:
    SO_REUSEADDR, so a just-closed forward's TIME_WAIT is no obstacle; a live
    listener still is)."""
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def any_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def up(port, secs=8.0, alive=None):
    """Wait until 127.0.0.1:<port> accepts (the forward is listening). `alive`:
    a callable — False ⇒ the forwarding process died, stop waiting."""
    end = time.time() + secs
    while time.time() < end:
        if alive is not None and not alive():
            return False
        try:
            socket.create_connection(("127.0.0.1", port), timeout=1).close()
            return True
        except OSError:
            time.sleep(0.2)
    return False


def gone(port, wait=1.5):
    """True when nothing answers at the far end of the forward on <port>: the
    local connect is refused (the forward is down), or ssh accepts it and closes
    it at once (its channel to the far port was refused). A live server holds an
    idle connection open — no bytes are sent, so it sees no request."""
    try:
        c = socket.create_connection(("127.0.0.1", port), timeout=1)
    except OSError:
        return True
    try:
        r, _, _ = select.select([c], [], [], wait)
        if not r:
            return False
        try:
            return c.recv(1) == b""
        except OSError:
            return True
    finally:
        c.close()


def notice(port, machine, who, secs, callback=True, lport=None):
    """The one line the person sees when a forward opens."""
    what = ("%s 的授权回调" % who) if callback else ("%s 的网页" % who)
    here = "localhost:%d" % (lport or port)
    mins = max(1, int(round(secs / 60.0)))
    return "fleet · 转发 %s → %s:%d（%s），%s或 %d 分钟后关闭" % (
        here, machine or "?", port, what, "回调完成" if callback else "网页停了", mins)


def closed_line(port, machine, reason, lport=None):
    return "fleet · 已关闭转发 localhost:%d → %s:%d（%s）" % (lport or port, machine or "?", port, reason)


class Forwards:
    """The forwards this process opened: [{port, lport, machine, who, close, at, until, last}]."""

    def __init__(self, logfile, say=None):
        self.logfile = logfile
        self.say = say or (lambda text: None)
        self.items = []
        self.lock = threading.Lock()

    def log(self, event, port, machine, who, lport, reason):
        try:
            os.makedirs(os.path.dirname(self.logfile), exist_ok=True)
            with open(self.logfile, "a") as f:
                f.write("%s\t%s\t%s\t%s\t%s\t%s\t%s\n" % (
                    time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), event, port, machine or "-",
                    (who or "-").replace("\t", " ")[:80], lport or port, (reason or "").replace("\t", " ")))
        except OSError:
            pass

    def held(self, port):
        with self.lock:
            return any(f["lport"] == port for f in self.items)

    def add(self, port, machine, who, close, callback=True, lport=None, ttl=None):
        """Book a forward that is up; say it; log it."""
        secs = float(ttl) if ttl else env_num("FLEET_OPEN_CALLBACK_SECS" if callback else "FLEET_OPEN_PAGE_SECS",
                                              600 if callback else 1800)
        now = time.time()
        with self.lock:
            self.items.append({"port": port, "lport": lport or port, "machine": machine, "who": who,
                               "close": close, "at": now, "until": now + secs, "last": now})
        self.log("open", port, machine, who, lport, "callback" if callback else "page")
        self.say(notice(port, machine, who, secs, callback, lport))

    def fail(self, port, machine, who, why):
        self.log("fail", port, machine, who, "", why)

    def tick(self):
        """Close what is done: its server gone, or past its deadline."""
        now = time.time()
        with self.lock:
            items = list(self.items)
        for f in items:
            reason = ""
            if now >= f["until"]:
                reason = "到时"
            elif now - f["at"] >= GRACE and now - f["last"] >= EVERY:
                f["last"] = now
                if gone(f["lport"]):
                    reason = "回调完成"
            if not reason:
                continue
            with self.lock:
                if f not in self.items:
                    continue
                self.items.remove(f)
            try:
                f["close"]()
            except Exception:
                pass
            self.log("close", f["port"], f["machine"], f["who"], f["lport"], reason)
            self.say(closed_line(f["port"], f["machine"], reason, f["lport"]))

    def close_all(self, reason="客户端退出"):
        with self.lock:
            items, self.items = list(self.items), []
        for f in items:
            try:
                f["close"]()
            except Exception:
                pass
            self.log("close", f["port"], f["machine"], f["who"], f["lport"], reason)

    def start(self, every=2.0):
        """A daemon thread ticking (for a loop that blocks elsewhere)."""
        def run():
            while True:
                time.sleep(every)
                try:
                    self.tick()
                except Exception:
                    pass
        t = threading.Thread(target=run, daemon=True)
        t.start()
        return t
