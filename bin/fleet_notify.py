#!/usr/bin/env python3
"""fleet_notify.py — a session needs you: THIS computer says so (issue #2759,
EPIC #2756 C3).

The ONE place that decides a notification. The client's refresh loop
(fleet-hub-sessions.sh --loop, client mode) calls `beat()` on every round that
brought rows, with the rows it just wrote — so it runs whether a terminal is
attached to the client or not (the old road, fleet_alerts_notify on the bar's
status-right job, ran only while a client drew that bar: a client in the
background, or `fleet claude`'s own view, never notified — #1951's 0%).

What counts, per row (a session on any machine, the orchestrator and the
steward included):
  ask    `needs` perm / ask / auth / anything but blocked, or the orchestrator's
         `decide=N` going red — 在问你; sound; the phone too
  stuck  `needs` blocked, or `failed` — 卡住; sound; the phone too
  done   `done` from anything else (never the steward's) — 做完; no sound, never
         the phone; one batch's dones within FLEET_NOTIFY_DONE_MERGE (600 s) are
         ONE notification (the same group, its count growing)
A notification is for ENTERING one of them: the key (worker id, kind, a hash of
what it asks) differs from the row's last one. Asked, answered, asked again is
two; the same question every beat is one; a row the hub briefly lost keeps its
key. The first beat (no state file) only remembers. Quiet hours
(FLEET_NOTIFY_QUIET, 23:00-08:00 local): no sound, no phone — still in the
Notification Centre. FLEET_NOTIFY=0: nothing at all, as before #1951's road;
FLEET_NOTIFY_DONE=0: no 做完. A client in standby (another device holds the
person's lease, issue #1715) asks the hub nothing, so it never gets here.

Every event is one line of logs/notify.ndjson (ts · key · state · sent | skip),
written by the sender (fleet-client-actions.py notify --log-*) once it knows
what happened — the metric's source. The phone's address
(FLEET_NOTIFY_BARK_URL) is read from secrets.env alone, by the sender, and is
never written anywhere.

  python3 fleet_notify.py quiet [HH:MM]   exit 0 inside quiet hours (tests)
"""
import hashlib
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
STATE = "notify.state.json"
KEEP = 3600            # a row not seen for this long is forgotten
DONE_MERGE = 600       # one batch's dones in this window are one notification


def env_on(name, default="1"):
    return (os.environ.get(name) or default) != "0"


def log_path():
    return os.environ.get("FLEET_NOTIFY_LOG") or os.path.join(os.path.dirname(HERE), "logs", "notify.ndjson")


def log(rec):
    """One line of logs/notify.ndjson; never raises."""
    p = log_path()
    try:
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "a", encoding="utf-8") as f:
            f.write(json.dumps(dict({"ts": int(time.time())}, **rec), ensure_ascii=False) + "\n")
    except OSError:
        pass


def quiet(now=None, spec=None):
    """Inside FLEET_NOTIFY_QUIET (`HH:MM-HH:MM`, local time; across midnight
    when the end is earlier; `off` / empty = never)."""
    spec = os.environ.get("FLEET_NOTIFY_QUIET", "23:00-08:00") if spec is None else spec
    try:
        a, b = spec.split("-", 1)
        ah, am = (int(x) for x in a.strip().split(":"))
        bh, bm = (int(x) for x in b.strip().split(":"))
    except ValueError:
        return False
    t = time.localtime(time.time() if now is None else now)
    m, s, e = t.tm_hour * 60 + t.tm_min, ah * 60 + am, bh * 60 + bm
    if s == e:
        return False
    return s <= m < e if s < e else (m >= s or m < e)


def classify(r):
    """(kind, sub, words) of a row that wants you, else None."""
    st, nd = r.get("state") or "", r.get("needs") or ""
    ask = r.get("ask") or ()
    words = (ask[1] if len(ask) > 1 and ask[1] else "") or r.get("detail") or ""
    if r.get("role") == "orchestrator" and str(r.get("decide") or "0") not in ("", "0") and st != "needs":
        return "ask", "decide", r.get("decide")
    if st == "needs":
        if nd == "blocked":
            return "stuck", "blocked", words
        sub = (ask[0] if ask and ask[0] else "") or nd
        return "ask", {"permission": "perm", "question": "ask"}.get(sub, sub), words
    if st == "failed":
        return "stuck", "failed", words
    if st == "done" and r.get("role") != "steward":
        return "done", "", ""
    return None


def subject(r):
    if r.get("role") == "orchestrator":
        return ui("notify_who_orch")
    if r.get("role") == "steward":
        return ui("notify_who_steward")
    return ("#%s" % r["issue"]) if r.get("issue") else (r.get("name") or r.get("wid") or "?")


def batch_of(r):
    e = r.get("epic") or ""
    return e.split(":", 1)[0] if e else ""


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def save(path, d):
    tmp = "%s.%d" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def ui(key, *args):
    try:
        r = subprocess.run(["sh", os.path.join(HERE, "fleet-ui-lang.sh"), "t", key] + [str(a) for a in args],
                           capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=5)
        return r.stdout.strip() or key
    except (OSError, subprocess.SubprocessError):
        return key


TITLE = {("ask", "perm"): "notify_perm", ("ask", "auth"): "notify_auth", ("ask", "decide"): "notify_decide",
         ("stuck", "failed"): "notify_failed", ("stuck", "blocked"): "notify_stuck"}


def send(ev, session):
    """Hand one event to fleet-client-actions.py notify, detached: the loop never
    waits on a notifier."""
    cmd = os.environ.get("FLEET_NOTIFY_SEND_CMD")
    argv = (cmd.split() if cmd else [sys.executable, os.path.join(HERE, "fleet-client-actions.py")]) + [
        "notify", "--title", ev["title"], "--body", ev["body"], "--jump", ev["jump"], "--session", session,
        "--group", ev["group"], "--log-key", ev["key"], "--log-state", ev["kind"]]
    if ev["sound"]:
        argv.append("--sound")
    if ev["phone"]:
        argv.append("--phone")
    try:
        subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    except OSError as e:
        log({"key": ev["key"], "state": ev["kind"], "skip": "spawn:%s" % e.__class__.__name__})


def beat(rows, gdir, session, now=None):
    """One round's rows → the notifications they call for; returns the events
    handed on (tests read them)."""
    if not env_on("FLEET_NOTIFY"):
        return []
    now = int(time.time() if now is None else now)
    path = os.path.join(gdir, STATE)
    st = load(path)
    seed = st is None
    st = st or {}
    seen = st.get("rows") if isinstance(st.get("rows"), dict) else {}
    batches = st.get("done") if isinstance(st.get("done"), dict) else {}
    hush = quiet(now)
    events = []
    here = set()
    for r in rows:
        wid = r.get("wid") or ""
        if not wid or wid in here:
            continue
        here.add(wid)
        c = classify(r)
        key = ""
        if c:
            key = "%s:%s" % (c[0], hashlib.sha1(("%s\x1f%s" % (c[1], c[2])).encode("utf-8")).hexdigest()[:12])
        prev = seen.get(wid)
        seen[wid] = {"k": key, "t": now}
        if seed or not c or (prev and prev.get("k") == key):
            continue
        kind, sub, words = c
        if kind == "done" and prev is None:
            continue                       # a row first seen finished: nothing happened in front of you
        who = subject(r)
        node = r.get("node") or ""
        ev = {"key": wid, "kind": kind, "jump": "wid:" + wid, "group": "fleet-%s" % wid,
              "sound": kind != "done" and not hush, "phone": kind != "done" and not hush}
        if kind == "done":
            if not env_on("FLEET_NOTIFY_DONE"):
                log({"key": wid, "state": kind, "skip": "done-off"})
                continue
            b = batch_of(r)
            merge = int(os.environ.get("FLEET_NOTIFY_DONE_MERGE") or DONE_MERGE)
            if b:
                cur = batches.get(b)
                if not cur or now - int(cur.get("t", 0)) > merge:
                    cur = {"t": now, "n": 0}
                cur["n"] = int(cur.get("n", 0)) + 1
                batches[b] = cur
                ev["group"] = "fleet-done-%s" % b
                if cur["n"] > 1:
                    ev["title"] = ui("notify_done_batch", b[b.find("#"):] if "#" in b else b, cur["n"])
                    ev["body"] = ui("notify_done_last", who) + (" · " + node if node else "")
                    events.append(ev)
                    continue
            ev["title"] = ui("notify_done", who)
            ev["body"] = node
        else:
            ev["title"] = ui(TITLE.get((kind, sub), "notify_ask"), who)
            if sub == "decide":
                words = ui("notify_decide_body", words)
            ev["body"] = " · ".join(x for x in (words, node) if x)
        events.append(ev)
    for wid in [w for w, v in seen.items() if w not in here and now - int(v.get("t", 0)) > KEEP]:
        del seen[wid]
    for b in [b for b, v in batches.items() if now - int(v.get("t", 0)) > 2 * KEEP]:
        del batches[b]
    save(path, {"rows": seen, "done": batches, "ts": now})
    for ev in events:
        send(ev, session)
    return events


def main(argv):
    if argv[:1] == ["quiet"]:
        now = None
        if len(argv) > 1:
            h, m = argv[1].split(":")
            t = time.localtime()
            now = time.mktime((t.tm_year, t.tm_mon, t.tm_mday, int(h), int(m), 0, 0, 0, -1))
        return 0 if quiet(now) else 1
    sys.stderr.write("usage: fleet_notify.py quiet [HH:MM]\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
