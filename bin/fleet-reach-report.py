#!/usr/bin/env python3
"""fleet-reach-report — this view machine's reachability, folded and sent to the
hub (task FQAR; docs/dev/HEALTH.md «会话可达性»). The hub cannot see it itself: its own
pings measure hub↔node only, so a view→pod road broken through the peer relay
left /status green for hours (2026-11-02).

Reads two ledgers this login already writes, under $FLEET_CONF_DIR/logs/:

  view-switch.ndjson   every session enter of a 看台 (bin/fleet_view.py go): its
                       method says how it went — select-window / web-go /
                       peer-window / peer-select entered, peer-wait waited on a
                       link that was down, gone / far-none / unsupported failed
  peerlink.ndjson      every standing link's up / down / retry / probe
                       ({ts, machine, login, route, event, cause, detail, gap_s,
                       rtt_ms}; bin/fleet-peerlink.py)

and folds the last FLEET_REACH_HOURS (48) hours into one row per (hour, link,
route class) — counts and histograms only:

  attempts / ok     session enters, and those whose pane was there within 10 s
                    (a success slower than that, a failure, a peer-wait no `up`
                    answered within 10 s: not ok)
  enter[13]         the ok enters' ms, in the hub's buckets (store.ReachBounds)
  want_ms / up_ms   how long the link was wanted that hour, and up: from each
                    ledger event to the next, at most FLEET_REACH_STALE_SECS
                    (900) past the last one — a link nobody heard of for that
                    long is no longer counted as wanted
  recover[13]       each down→up's ms (gap_s when the ledger has it)

route class: local (the view's own machine) · direct (tailnet / lan / entry) ·
relay (peer-relay / hub-relay) · unknown. A link is NEVER named: it is the first
16 hex of sha256(salt, machine, login), the salt a random file of this login's
($FLEET_CONF_DIR/reach-salt, 0600) — the hub cannot reverse it. Rows are sent
whole, so a resend replaces them (POST /v1/fleet/reach-stats).

    fleet-reach-report.py tick      at most once an hour (FLEET_REACH_REPORT_SECS,
                                    3600; 600 after a failed send) — the cleanup
                                    daemon's tick calls it; prints nothing
    fleet-reach-report.py send      fold and send now; prints `sent N` / `failed`
    fleet-reach-report.py fold      print the rows as JSON (nothing sent)

FLEET_REACH_REPORT=0 folds and sends nothing. Seams (selftest): FLEET_REACH_NOW,
FLEET_REACH_VIEW_LOG, FLEET_REACH_PEERLINK_LOG, FLEET_REACH_POST_CMD (run with
the JSON body on stdin in place of the POST; exit 0 = taken).
"""
import bisect
import hashlib
import importlib.util
import json
import os
import secrets
import shlex
import subprocess
import sys
import time

BIN = os.path.dirname(os.path.abspath(__file__))
PATH = "/v1/fleet/reach-stats"
NAMESPACE = "fleet-reach-stats@claude-fleet"
# store.ReachBounds (tokenledger/hub/store/reach_stats.go): keep in step.
BOUNDS = [150, 200, 300, 500, 1000, 2000, 5000, 10000, 30000, 60000, 300000, 1800000]
NBUCKETS = len(BOUNDS) + 1
ENTER_OK_MS = 10000
ROUTE_CLASS = {"tailnet": "direct", "lan": "direct", "entry": "direct",
               "peer-relay": "relay", "hub-relay": "relay"}
ENTERED_LOCAL = {"select-window"}
ENTERED_FAR = {"peer-window", "peer-select", "web-go"}
FAILED = {"gone", "far-none", "unsupported"}
WAITED = {"peer-wait"}


def _num(name, default):
    try:
        return float(os.environ.get(name, "") or default)
    except ValueError:
        return float(default)


def conf_dir():
    return os.environ.get("FLEET_CONF_DIR") or os.path.join(os.path.expanduser("~"), ".config", "claude-fleet")


def now():
    return _num("FLEET_REACH_NOW", time.time())


def enabled():
    return os.environ.get("FLEET_REACH_REPORT", "1") != "0"


def read_ndjson(path, since=None):
    out = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(d, dict):
                    continue
                try:
                    ts = float(d.get("ts"))
                except (TypeError, ValueError):
                    continue
                if since is not None and ts < since:
                    continue
                d["ts"] = ts
                out.append(d)
    except OSError:
        pass
    out.sort(key=lambda d: d["ts"])
    return out


def salt():
    p = os.path.join(conf_dir(), "reach-salt")
    try:
        with open(p) as f:
            s = f.read().strip()
        if len(s) >= 32:
            return s
    except OSError:
        pass
    s = secrets.token_hex(32)
    try:
        os.makedirs(os.path.dirname(p), exist_ok=True)
        fd = os.open(p + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(s + "\n")
        os.replace(p + ".tmp", p)
    except OSError:
        pass
    return s


def link_id(machine, login, the_salt):
    return hashlib.sha256(("fleet-reach-link\0%s\0%s\0%s" % (the_salt, machine, login)).encode()).hexdigest()[:16]


def bucket_of(ms):
    """The index of the first bound ms is below; the open bucket past the last."""
    for i, b in enumerate(BOUNDS):
        if ms < b:
            return i
    return len(BOUNDS)


class Links:
    """The peerlink ledger, per (machine, login): its events, oldest first."""

    def __init__(self, events):
        self.by = {}
        for e in events:
            k = (str(e.get("machine") or ""), str(e.get("login") or ""))
            if k[0]:
                self.by.setdefault(k, []).append(e)
        self.ts = {k: [e["ts"] for e in v] for k, v in self.by.items()}

    def route_at(self, machine, login, ts):
        """The class of the last route the ledger named for this link at ts."""
        evs = self.by.get((machine, login)) or []
        i = bisect.bisect_right(self.ts.get((machine, login)) or [], ts)
        for e in reversed(evs[:i]):
            r = e.get("route")
            if r:
                return ROUTE_CLASS.get(r, "unknown")
        return "unknown"

    def up_within(self, machine, login, ts, secs):
        """The first `up` (or ok probe) at or after ts within secs — its ts, else None."""
        evs = self.by.get((machine, login)) or []
        i = bisect.bisect_left(self.ts.get((machine, login)) or [], ts)
        for e in evs[i:]:
            if e["ts"] - ts > secs:
                return None
            if e.get("event") == "up" or (e.get("event") == "probe" and e.get("cause") == "ok"):
                return e["ts"]
        return None


def _state(e):
    ev, cause = e.get("event"), e.get("cause")
    if ev == "up" or (ev == "probe" and cause == "ok"):
        return "up"
    if ev in ("down", "retry") or ev == "probe":
        return "down"
    return None


def fold(views, link_events, at, hours=48, stale=900.0, the_salt=""):
    """The rows for the hours [cur-hours+1, cur]: a list of dicts as the hub takes them."""
    cur = int(at // 3600)
    first = cur - hours + 1
    start = first * 3600
    rows = {}

    def row(hour, link, route):
        k = (hour, link, route)
        if k not in rows:
            rows[k] = {"hour": hour, "link": link, "route": route, "attempts": 0, "ok": 0,
                       "enter": [0] * NBUCKETS, "want_ms": 0, "up_ms": 0, "recover": [0] * NBUCKETS}
        return rows[k]

    links = Links(link_events)
    # ── enters ──
    for v in views:
        ts = v["ts"]
        if ts < start or ts > at:
            continue
        method = v.get("method")
        to = str(v.get("to") or "")
        machine, login = str(v.get("machine") or ""), str(v.get("login") or "")
        far = not to.startswith("@")
        if method in ENTERED_LOCAL or (method in FAILED and not far):
            link, route = "", "local"
        elif method in ENTERED_FAR | FAILED | WAITED:
            if machine:
                link = link_id(machine, login, the_salt)
                route = "relay" if method == "web-go" else links.route_at(machine, login, ts)
            else:
                link, route = "", "unknown"
        else:
            continue  # forward and the like: not an enter
        try:
            ms = float(v.get("ms") or 0)
        except (TypeError, ValueError):
            ms = 0.0
        ok = False
        if method in ENTERED_LOCAL or method in ENTERED_FAR:
            ok = ms <= ENTER_OK_MS
        elif method in WAITED and machine:
            up = links.up_within(machine, login, ts, ENTER_OK_MS / 1000.0)
            if up is not None:
                ms = ms + (up - ts) * 1000.0
                ok = ms <= ENTER_OK_MS
                route = links.route_at(machine, login, up)
        r = row(int(ts // 3600), link, route)
        r["attempts"] += 1
        if ok:
            r["ok"] += 1
            r["enter"][bucket_of(ms)] += 1
    # ── links: wanted / up time, recoveries ──
    for (machine, login), evs in links.by.items():
        link = link_id(machine, login, the_salt)
        state, route, down_since = None, "unknown", None
        for i, e in enumerate(evs):
            st = _state(e)
            if e.get("route"):
                route = ROUTE_CLASS.get(e.get("route"), "unknown")
            if st == "up" and state == "down":
                gap = e.get("gap_s")
                rec = None
                if isinstance(gap, (int, float)) and gap >= 0:
                    rec = gap * 1000.0
                elif down_since is not None:
                    rec = (e["ts"] - down_since) * 1000.0
                if rec is not None and start <= e["ts"] <= at:
                    row(int(e["ts"] // 3600), link, route)["recover"][bucket_of(rec)] += 1
            if st == "down" and state != "down":
                down_since = e["ts"]
            if st is not None:
                state = st
            # the segment this event opens
            seg_end = min(evs[i + 1]["ts"] if i + 1 < len(evs) else at, e["ts"] + stale, at)
            seg_start = max(e["ts"], start)
            if state is None or seg_end <= seg_start:
                continue
            t = seg_start
            while t < seg_end:
                h = int(t // 3600)
                t2 = min(seg_end, (h + 1) * 3600)
                r = row(h, link, route)
                r["want_ms"] += int(round((t2 - t) * 1000))
                if state == "up":
                    r["up_ms"] += int(round((t2 - t) * 1000))
                t = t2
    out = []
    for k in sorted(rows):
        r = rows[k]
        r["want_ms"] = min(r["want_ms"], 3600000)
        r["up_ms"] = min(r["up_ms"], r["want_ms"])
        if r["attempts"] or r["want_ms"] or any(r["recover"]):
            out.append(r)
    return out


def collect(at=None):
    at = now() if at is None else at
    hours = int(_num("FLEET_REACH_HOURS", 48))
    since = (int(at // 3600) - hours + 1) * 3600
    logs = os.path.join(conf_dir(), "logs")
    views = read_ndjson(os.environ.get("FLEET_REACH_VIEW_LOG") or os.path.join(logs, "view-switch.ndjson"), since)
    link_events = read_ndjson(os.environ.get("FLEET_REACH_PEERLINK_LOG") or os.path.join(logs, "peerlink.ndjson"))
    return fold(views, link_events, at, hours, _num("FLEET_REACH_STALE_SECS", 900), salt())


def hub_conf():
    """(hub URL, token, the fleet-connect module), through fleet_client_events.py's own reader."""
    try:
        spec = importlib.util.spec_from_file_location("fleet_client_events", os.path.join(BIN, "fleet_client_events.py"))
        fce = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fce)
        return fce.hub_conf()
    except (Exception, SystemExit):
        return "", "", None


def post(rows, timeout=15):
    """True when the hub answered for the batch (taken, or refused for good)."""
    body = {"rows": rows}
    seam = os.environ.get("FLEET_REACH_POST_CMD")
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
            cert, sig = fc.ssh_sign("fleet-reach-stats %d" % ts, NAMESPACE)
            body.update(cert=cert, sig=sig, ts=ts)
        req = urllib.request.Request(hub.rstrip("/") + PATH, data=json.dumps(body).encode(),
                                     method="POST", headers=headers)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            r.read()
        return True
    except urllib.error.HTTPError as e:
        return e.code in (400, 413)
    except (Exception, SystemExit):
        return False


def send():
    rows = collect()
    if not rows:
        return 0, True
    sent = 0
    for i in range(0, len(rows), 1000):
        if not post(rows[i:i + 1000]):
            return sent, False
        sent += len(rows[i:i + 1000])
    return sent, True


def stamp_path():
    return os.path.join(conf_dir(), "logs", ".reach-report.json")


def due(at):
    try:
        with open(stamp_path()) as f:
            st = json.load(f)
        last, ok = float(st.get("at", 0)), bool(st.get("ok"))
    except (OSError, ValueError, TypeError, AttributeError):
        return True
    every = _num("FLEET_REACH_REPORT_SECS", 3600) if ok else 600
    return at - last >= every or at < last


def tick():
    at = now()
    if not enabled() or not due(at):
        return 0
    logs = os.path.join(conf_dir(), "logs")
    if not any(os.path.exists(os.environ.get(k) or os.path.join(logs, f)) for k, f in
               (("FLEET_REACH_VIEW_LOG", "view-switch.ndjson"), ("FLEET_REACH_PEERLINK_LOG", "peerlink.ndjson"))):
        return 0  # not a view machine: nothing to say
    _, ok = send()
    try:
        os.makedirs(logs, exist_ok=True)
        with open(stamp_path() + ".tmp", "w") as f:
            json.dump({"at": at, "ok": ok}, f)
        os.replace(stamp_path() + ".tmp", stamp_path())
    except OSError:
        pass
    return 0


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "tick"
    if cmd == "tick":
        return tick()
    if not enabled():
        print("off (FLEET_REACH_REPORT=0)")
        return 0
    if cmd == "fold":
        json.dump(collect(), sys.stdout)
        sys.stdout.write("\n")
        return 0
    if cmd == "send":
        n, ok = send()
        print("sent %d" % n if ok else "failed (sent %d)" % n)
        return 0 if ok else 1
    print("usage: fleet-reach-report.py tick | send | fold", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
