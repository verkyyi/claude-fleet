#!/usr/bin/env python3
"""fleet_client_events — the client's connection events, sent to the hub
(claude-fleet T689, 稳定性①; docs/dev/CLIENT-LOGS.md «Sent to the hub»).

thin.log stays this computer's own record; this is the part of it the hub and
the doctor read: what the line did, as events of METADATA only —

    start    a `fleet` start (one id per start: every later event carries it)
    up       the view drawn — phase start (ms = from the start) or reconnect
             (ms = from the drop: the reconnect time)
    drop     the line ended while up, not by the person — reason = what ssh said
             last (timeout · reset · broken-pipe · closed-remote · …) else rc<N>
    fail     a connection that did not come up — phase start (起不来) or
             reconnect; reason = home:<the hub's code> · pick · no_fleet ·
             opening · first_session · never_up · <ssh's word>
    rehome   the home changed (home → to), or `no_other` (back to the same)
    offline  three tries failed and the hub did not answer either
    quit     the person ended it (rc)

Every field is a code, a machine name or a number — never a credential, never
the person's words, never a byte of the terminal; the hub refuses any event
that is not (hub/api/fleet_client_events.go).

The spool: ${XDG_CACHE_HOME:-~/.cache}/claude-fleet/client-events.ndjson
(FLEET_CLIENT_EVENTS_SPOOL), one JSON line per event, at most
FLEET_CLIENT_EVENTS_MAX (2000) — the oldest go first. `kick()` sends it on a
daemon thread (one sender at a time: a flock), FLEET_CLIENT_EVENTS_BATCH (200)
a POST; an event leaves the spool only when the hub has answered for it, so a
line that is down keeps them and the next kick — the next event, the next
start — sends them late. Nothing here ever blocks or writes to the terminal.
FLEET_CLIENT_EVENTS=0 records and sends nothing.

Seam (tests): FLEET_CLIENT_EVENTS_POST_CMD — run with the batch's JSON body on
stdin in place of the POST; exit 0 = the hub took it.

    fleet_client_events.py record <event> [key=value …]
    fleet_client_events.py flush          (sends now, in the foreground; prints sent / left)
    fleet_client_events.py status         (the spool: how many wait, the oldest)
    fleet_client_events.py report [--summary]   the hub's GET answer on stdin → the
                                          doctor's table (or its one row: LEVEL<TAB>words)
"""
import fcntl
import importlib.util
import json
import os
import random
import re
import shlex
import socket
import subprocess
import sys
import threading
import time

BIN = os.path.dirname(os.path.abspath(__file__))
EVENTS = ("start", "up", "drop", "fail", "rehome", "offline", "quit")
PHASES = ("", "start", "reconnect")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}$")
REASON_RE = re.compile(r"^[a-z0-9][a-z0-9_.:-]{0,47}$")
VER_RE = re.compile(r"^[0-9A-Za-z._-]{1,64}$")
NAMESPACE = "fleet-client-events@claude-fleet"
PATH = "/v1/fleet/client-events"
_lock = threading.Lock()
_sender = None


def enabled():
    return os.environ.get("FLEET_CLIENT_EVENTS", "1") != "0"


def spool_path():
    p = os.environ.get("FLEET_CLIENT_EVENTS_SPOOL")
    if p:
        return p
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, "claude-fleet", "client-events.ndjson")


def _num(name, default):
    try:
        return int(os.environ.get(name) or default)
    except ValueError:
        return default


def new_id():
    """Milliseconds then randomness: the hub orders a second's events by it."""
    return "%011x%08x" % (int(time.time() * 1000), random.getrandbits(32))


def name(s):
    """A machine / route name as the hub takes it, else ''."""
    s = str(s or "")
    return s if NAME_RE.match(s) and s != "-" else ""


def code(s):
    """A reason as a code: lower case, words joined by _, cut — '' when nothing is left."""
    s = re.sub(r"[^a-z0-9_.:-]+", "_", str(s or "").strip().lower()).strip("_.:-")[:48]
    return s if REASON_RE.match(s) else ""


def device():
    return name(socket.gethostname().split(".")[0]) or "?"


def event(kind, **f):
    """The event as the hub takes it — every field checked, the rest dropped."""
    e = {"id": new_id(), "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "event": kind}
    if re.match(r"^[0-9a-f]{8,40}$", str(f.get("start") or "")):
        e["start"] = f["start"]
    if f.get("phase") in PHASES and f.get("phase"):
        e["phase"] = f["phase"]
    for k in ("home", "route", "to"):
        v = name(f.get(k))
        if v:
            e[k] = v
    for k in ("ms", "rc"):
        try:
            v = int(float(f.get(k)))
        except (TypeError, ValueError):
            continue
        if (k == "ms" and 0 <= v <= 30 * 86400 * 1000) or (k == "rc" and -1 <= v <= 1000):
            e[k] = v
    r = code(f.get("reason"))
    if r:
        e["reason"] = r
    v = str(f.get("ver") or "")
    if VER_RE.match(v):
        e["ver"] = v
    return e


def _locked(path, mode):
    """Open path's .lock and flock it (mode: LOCK_EX, maybe | LOCK_NB)."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, mode)
    except OSError:
        os.close(fd)
        raise
    return fd


def _read(path):
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    j = json.loads(line)
                except ValueError:
                    continue
                if isinstance(j, dict) and j.get("id"):
                    out.append(j)
    except OSError:
        pass
    return out


def _write(path, evs):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for e in evs:
            f.write(json.dumps(e, separators=(",", ":")) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def record(kind, **f):
    """Spool one event and kick the sender. Never raises; returns the event (or None)."""
    if not enabled() or kind not in EVENTS:
        return None
    try:
        e = event(kind, **f)
        path = spool_path()
        fd = _locked(path + ".spool", fcntl.LOCK_EX)
        try:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(e, separators=(",", ":")) + "\n")
            os.chmod(path, 0o600)
            cap = _num("FLEET_CLIENT_EVENTS_MAX", 2000)
            if os.path.getsize(path) > cap * 120:
                evs = _read(path)
                if len(evs) > cap:
                    _write(path, evs[-cap:])
        finally:
            os.close(fd)
        if f.get("send", True):
            kick()
        return e
    except Exception:
        return None


def hub_conf():
    """(hub URL, token, the fleet-connect module) — ('', '', None) with no hub."""
    try:
        spec = importlib.util.spec_from_file_location("fleet_connect", os.path.join(BIN, "fleet-connect.py"))
        fc = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fc)
        conf = fc.load_hub_conf()
        hub = os.environ.get("FLEET_HUB_URL") or fc.machine_conf_hub() or conf.get("url") or ""
        return hub, os.environ.get("FLEET_HUB_TOKEN") or conf.get("token") or "", fc
    except (Exception, SystemExit):
        return "", "", None


def post(batch, timeout=10):
    """Send one batch; True when the hub answered for it (taken, or refused for good)."""
    body = {"device": device(), "events": batch}
    seam = os.environ.get("FLEET_CLIENT_EVENTS_POST_CMD")
    if seam:
        try:
            r = subprocess.run(shlex.split(seam), input=json.dumps(body).encode(), stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=timeout)
            return r.returncode == 0
        except (OSError, subprocess.SubprocessError):
            return False
    import urllib.error
    import urllib.request
    hub, token, fc = hub_conf()
    if not hub:
        return False
    headers = {"Content-Type": "application/json"}
    try:
        if token:
            headers["Authorization"] = "Bearer " + token
        else:
            ts = int(time.time())
            cert, sig = fc.ssh_sign("fleet-client-events %d" % ts, NAMESPACE)
            body.update(cert=cert, sig=sig, ts=ts)
        req = urllib.request.Request(hub.rstrip("/") + PATH, data=json.dumps(body).encode(),
                                     method="POST", headers=headers)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            r.read()
        return True
    except urllib.error.HTTPError as e:
        # 400 / 413: this batch will never be taken — let it go, never jam the spool
        return e.code in (400, 413)
    except (Exception, SystemExit):
        return False


def flush(timeout=10):
    """Send the spool, batch by batch, until it is empty or a send fails.
    (sent, left); (0, -1) when another sender holds it."""
    if not enabled():
        return 0, 0
    path = spool_path()
    try:
        sfd = _locked(path + ".send", fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0, -1
    sent = 0
    try:
        batch_n = max(1, _num("FLEET_CLIENT_EVENTS_BATCH", 200))
        while True:
            evs = _read(path)
            if not evs:
                return sent, 0
            batch = evs[:batch_n]
            if not post(batch, timeout):
                return sent, len(evs)
            gone = {e["id"] for e in batch}
            fd = _locked(path + ".spool", fcntl.LOCK_EX)
            try:
                _write(path, [e for e in _read(path) if e.get("id") not in gone])
            finally:
                os.close(fd)
            sent += len(batch)
    except Exception:
        return sent, -1
    finally:
        os.close(sfd)


def kick():
    """Send the spool on a daemon thread, unless one is already sending."""
    global _sender
    if not enabled():
        return
    with _lock:
        if _sender is not None and _sender.is_alive():
            return
        _sender = threading.Thread(target=flush, name="client-events", daemon=True)
        _sender.start()


def status():
    evs = _read(spool_path())
    return {"spool": spool_path(), "waiting": len(evs), "oldest": evs[0]["at"] if evs else ""}


def _secs(ms):
    ms = int(ms or 0)
    if ms < 10000:
        return "%.1fs" % (ms / 1000.0)
    if ms < 120000:
        return "%ds" % round(ms / 1000.0)
    return "%dm%02ds" % (ms // 60000, (ms // 1000) % 60)


def _reasons(d, limit=4):
    items = sorted((d or {}).items(), key=lambda kv: (-kv[1], kv[0]))
    out = " ".join("%s×%d" % kv for kv in items[:limit])
    return out + (" …" if len(items) > limit else "") if out else "-"


def summary_row(rep):
    """(LEVEL, words) — the doctor's `clients` row off the hub's answer."""
    t = rep.get("total") or {}
    hours = rep.get("hours") or 24
    devs = len(rep.get("devices") or [])
    if not devs:
        return "INFO", "最近 %dh 入口没有收到客户端连接事件（客户端未连，或还没更新到上报版本）" % hours
    words = "最近 %dh · %d 台设备 · 启动 %d · 断线 %d · 重连 %d 次 p50 %s / p90 %s · 起不来 %d 次（%d 次启动）" % (
        hours, devs, t.get("starts", 0), t.get("drops", 0), t.get("reconnects", 0),
        _secs(t.get("reconnect_p50_ms")), _secs(t.get("reconnect_p90_ms")),
        t.get("fails", 0), t.get("starts_failed", 0))
    if t.get("fails"):
        words += " 原因 " + _reasons(t.get("fail_reasons"), 3)
    if t.get("reconnect_fails"):
        words += " · 重连没连上 %d 次" % t.get("reconnect_fails")
    if t.get("drops"):
        words += " · 断线原因 " + _reasons(t.get("drop_reasons"), 3)
    words += " — 详表 fleet doctor --clients"
    bad = t.get("starts_failed", 0) > 0 or int(t.get("reconnect_p90_ms") or 0) > 60000
    return ("WARN" if bad else "PASS"), words


def table(rep):
    """The doctor's --clients table: per device, then per device × home."""
    hours = rep.get("hours") or 24
    lines = ["客户端连接 · 最近 %dh（截至 %s）" % (hours, str(rep.get("at") or "")[:19].replace("T", " ") + "Z")]
    head = ("设备", "家机器", "启动", "连上", "断线", "重连", "p50", "p90", "重连没连上", "起不来", "换家", "断网",
            "起不来原因", "断线原因")
    rows = []
    by = {}
    for r in rep.get("by") or []:
        by.setdefault(r.get("device") or "?", []).append(r)
    for d in rep.get("devices") or []:
        dev = d.get("device") or "?"
        for r, home in [(d, "（全部）")] + [(x, x.get("home") or "-") for x in by.get(dev, [])]:
            rows.append((dev if home == "（全部）" else "", home, r.get("starts", 0), r.get("ups", 0),
                         r.get("drops", 0), r.get("reconnects", 0),
                         _secs(r.get("reconnect_p50_ms")) if r.get("reconnects") else "-",
                         _secs(r.get("reconnect_p90_ms")) if r.get("reconnects") else "-",
                         r.get("reconnect_fails", 0), "%d(%d)" % (r.get("fails", 0), r.get("starts_failed", 0)), r.get("rehomes", 0),
                         r.get("offline", 0), _reasons(r.get("fail_reasons")), _reasons(r.get("drop_reasons"))))
    if not rows:
        lines.append("  （没有事件）")
        return "\n".join(lines)
    cells = [tuple(str(c) for c in head)] + [tuple(str(c) for c in r) for r in rows]

    def width(s):
        return sum(2 if ord(ch) > 0x2E7F else 1 for ch in s)
    w = [max(width(r[i]) for r in cells) for i in range(len(head))]
    for r in cells:
        lines.append("  " + "  ".join(c + " " * (w[i] - width(c)) for i, c in enumerate(r)).rstrip())
    t = rep.get("total") or {}
    lines.append("  合计：启动 %d · 断线 %d · 重连 p50 %s / p90 %s（%d 次）· 起不来 %d 次（%d 次启动）" % (
        t.get("starts", 0), t.get("drops", 0), _secs(t.get("reconnect_p50_ms")), _secs(t.get("reconnect_p90_ms")),
        t.get("reconnects", 0), t.get("fails", 0), t.get("starts_failed", 0)))
    lines.append("  起不来 = 启动后、第一次画出看台前没连上的一次连接（括号里是一次都没连上的启动数）；"
                 "重连 = 断线到看台重新画出来；重连没连上 = 断线后没连上的一次连接")
    return "\n".join(lines)


def main(argv):
    if len(argv) >= 2 and argv[1] == "report":
        try:
            rep = json.load(sys.stdin)
        except ValueError:
            print("fleet_client_events: the hub's answer is not JSON", file=sys.stderr)
            return 1
        if "--summary" in argv[2:]:
            print("%s\t%s" % summary_row(rep))
        else:
            print(table(rep))
        return 0
    if len(argv) >= 2 and argv[1] == "record":
        if len(argv) < 3:
            print("usage: record <event> [key=value …]", file=sys.stderr)
            return 2
        f = dict(a.split("=", 1) for a in argv[3:] if "=" in a)
        f["send"] = False
        return 0 if record(argv[2], **f) else 1
    if len(argv) == 2 and argv[1] == "flush":
        sent, left = flush()
        print("sent %d · left %s" % (sent, "?" if left < 0 else left))
        return 0 if left == 0 else 1
    if len(argv) == 2 and argv[1] == "status":
        print(json.dumps(status(), ensure_ascii=False))
        return 0
    print("usage: fleet_client_events.py record <event> [key=value …] | flush | status", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
