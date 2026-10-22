#!/usr/bin/env python3
"""fleet_session_gate.py — the session gate (task HHV0, 会话合一 ①).

A person talks to a SESSION from the web: a window on this login (any of its
fleets) named by its `@fleet_id`. The web never holds the conversation and never
takes it over — the session runs in its own window, and the web and the terminal
are two mouths saying one sentence into it, first come first in. This file is the
gate's whole logic; extras/web-chat/server.mjs (the login's chat service) calls it
and the idle reaper / memguard call its park.

    fleet_session_gate.py say    --fid F [--text-file P|-] [--image PATH]… [--delivery UUID]
    fleet_session_gate.py tick   [--fid F]
    fleet_session_gate.py status --fid F
    fleet_session_gate.py ack    --fid F --delivery UUID       (the page took a returned one back)
    fleet_session_gate.py stop   --fid F
    fleet_session_gate.py answer --fid F --fp FP --pick LABEL…
    fleet_session_gate.py park   --fid F [--why idle|memory] [--force]
    fleet_session_gate.py wake   --fid F [--seed-file P]
    fleet_session_gate.py pending                                (fids with words waiting)
    fleet_session_gate.py watched --fid F                        (exit 0 = a person looks at it)
    fleet_session_gate.py name   --fid F --name N                (the title every list shows)

Every command prints one JSON line.

Saying (`say`): each sentence is a record with its own id (`delivery`), written
to disk BEFORE anything is handed over — $FLEET_CONF_DIR/session-gate/<fid>/ — so
a restart of the chat service loses nothing and never sends twice. The answer is
`{delivery, state: sent|queued|refused, reason}`:

  * Claude — the fleet mod's conditional accept (`idle.v2`, mod/fleet/hooks/accept.ts,
    mod ≥ 0.7.0): posted to the pane's inbox slot and checked AGAIN at the engine's
    entry boundary — no turn running, no draft in the box, no /clear since. Accepted
    = a turn of its own (sent); refused = it stays queued and the next tick tries
    again once the session is idle (a person typing, an answer running, a question
    open); unanswered = settled by its receipt (the mod's receipt file, else the
    delivery id in the turn's hidden context) — never a second post of the same id.
  * Codex — its own queue (`thread/queue/add` with clientUserMessageId = delivery,
    then `thread/queue/start`, Codex ≥ 0.162): idle ⇒ started (sent); answering ⇒ it
    sits in Codex's queue and starts when the turn ends (queued, settled by the
    receipt scan).
  * A parked session (below) is woken with the sentence as its first turn.
  * One sentence at a time a session, oldest first: two sentences are two turns.
  * Returned to the page (state `returned`, its `why`): queued over
    FLEET_GATE_QUEUE_SECS (1800) · the conversation changed (a /clear, another id) ·
    the window gone · a wake that did not come up in FLEET_GATE_WAKE_SECS (20).

can_talk: a Claude pane whose mod says `@mod_accept idle.v2` (a fresh window or
one parked — its next start loads the current mod), a Codex pane whose app-server
is ≥ 0.162. Anything else is read-only (an older Claude Code / mod / Codex).

Parking (`park`): the agent's process ends IN ITS OWN WINDOW — the window, its
@fleet_id, its conversation id, its session credential (never revoked: minting one
again is the slow part of a start) and its row in every list stay; the window says
`done` (idle), so nobody can tell. bin/fleet-session-wrap.sh holds the parked
window; `wake` (or a person switching to it, or ↵ in it) resumes the SAME
conversation there, the first sentence riding the start (no inbox round). Never
while it answers, asks, holds a background job or while a person looks at it
(`watched`: a terminal client showing the window).

Seams (selftest): FLEET_GATE_DIR (the records' root), FLEET_GATE_WIN_CMD (argv
printing `<socket>\\t<window>` for a fid, else bash fleet_id_window),
FLEET_GATE_TMUX (the tmux binary), FLEET_GATE_ACCEPT_CMD (argv run with the inbox
request on stdin, printing the mod's answer — instead of the inbox slot),
FLEET_GATE_CODEX (a python file defining identity / client for the Codex road),
FLEET_GATE_EXIT_CMD (argv + the pane, instead of the mod's /exit — its exit code
read as fleet_session_command's), FLEET_GATE_NOW (epoch).
"""
import argparse
import fcntl
import socket
import glob
import json
import os
import re
import shlex
import subprocess
import sys
import time
import uuid
from pathlib import Path

BIN = Path(__file__).absolute().parent
FID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
UUID_RE = FID_RE
ACCEPT = "idle.v2"
ACCEPT_WINDOW = 5.0        # the request's deadline, seconds from the post
ACCEPT_GRACE = 3.0         # the mod's ACCEPT_GRACE_S
ACCEPT_POLL = 2.0          # the inbox poll (INBOX_MS) and one tmux round
RECEIPT_PREFIX = "fleet idle-accept receipt delivery_id="
CODEX_MIN = (0, 162)
CODEX_NOT_IDLE = "thread already has an active or pending turn"
TEXT_MAX = 65536
IMAGES_MAX = 4
KEEP_SENT = 86400          # a sent record is kept a day (the page's ✓), then pruned
KEEP_RETURNED = 3600       # a returned one an hour (the page puts it back in the box)

# the window's options one read gets (tab-separated, in this order)
WIN_FMT = "\t".join(["#{pane_id}", "#{@cc_agent}", "#{@mod_accept}", "#{@parked}", "#{@claude_state}",
                     "#{@claude_needs}", "#{@agent_status}", "#{@cc_session_id}", "#{@codex_session_id}",
                     "#{@mod_alive}", "#{@session_origin}", "#{window_activity}", "#{@park_wake}",
                     "#{@claude_state_ts}", "#{@loop}", "#{socket_path}",
                     "#{@park_wrap_ver}", "#{@park_relay}", "#{pane_pid}",
                     "#{@park_presence}", "#{@park_watched_at}", "#{@park_start}"])
WIN_KEYS = ["pane", "agent", "mod_accept", "parked", "state", "needs", "agent_status", "cc_sid", "codex_sid",
            "mod_alive", "origin", "activity", "park_wake", "state_ts", "loop", "socket_path",
            "wrap_ver", "relay", "pane_pid", "presence", "watched_at", "park_start"]


def now():
    v = os.environ.get("FLEET_GATE_NOW", "")
    return float(v) if re.fullmatch(r"\d+(\.\d+)?", v) else time.time()


def num_env(name, default):
    v = os.environ.get(name, "")
    return int(v) if re.fullmatch(r"\d{1,7}", v) else default


def conf_dir():
    return Path(os.environ.get("FLEET_CONF_DIR") or Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "claude-fleet")


def gate_root():
    return Path(os.environ.get("FLEET_GATE_DIR") or conf_dir() / "session-gate")


def fid_dir(fid):
    d = gate_root() / fid
    d.mkdir(parents=True, exist_ok=True, mode=0o700)
    return d


def write_json(path, record):
    path = Path(path)
    tmp = path.with_name("." + path.name + ".tmp")
    with tmp.open("w") as f:
        json.dump(record, f, ensure_ascii=False, separators=(",", ":"))
        f.flush()
        os.fsync(f.fileno())
    tmp.replace(path)


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None


def out(obj, rc=0):
    print(json.dumps(obj, ensure_ascii=False, separators=(",", ":")))
    return rc


# ---- the window -----------------------------------------------------------------
def tmux(sock, *args):
    tm = os.environ.get("FLEET_GATE_TMUX", "tmux")
    argv = [tm] + (["-L", sock] if sock else []) + list(args)
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return p.stdout if p.returncode == 0 else None


def locate(fid):
    """(socket, window) for a fleet_id on this login, or None."""
    seam = os.environ.get("FLEET_GATE_WIN_CMD")
    argv = shlex.split(seam) + [fid] if seam else [
        "bash", "-c", '. "$1/fleet-lib.sh" >/dev/null 2>&1; fleet_id_window "$2"', "gate", str(BIN), fid]
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    line = p.stdout.strip().splitlines()[0] if p.returncode == 0 and p.stdout.strip() else ""
    if "\t" not in line:
        return None
    sock, win = line.split("\t", 1)
    return sock, win.strip()


def window(fid):
    """The window's facts as a dict, or None (no such window)."""
    loc = locate(fid)
    if loc is None:
        return None
    sock, win = loc
    raw = tmux(sock, "display-message", "-p", "-t", win, WIN_FMT)
    if raw is None:
        return None
    vals = raw.rstrip("\n").split("\t")
    vals += [""] * (len(WIN_KEYS) - len(vals))
    w = dict(zip(WIN_KEYS, vals))
    w.update(sock=sock, win=win, fid=fid)
    w["agent"] = w["agent"] or "claude"
    w["sid"] = w["codex_sid"] if w["agent"] == "codex" else w["cc_sid"]
    try:
        st = json.loads(w["agent_status"]) if w["agent_status"].startswith("{") else {}
    except ValueError:
        st = {}
    w["word"] = st.get("state", "") if isinstance(st, dict) else ""
    return w


def busy_of(w):
    """'' when the session can take a sentence now, else why not (busy · asking)."""
    if w["parked"]:
        return ""
    if w["state"] == "needs" or w["word"] == "blocked":
        return "asking"
    if w["state"] in ("working", "looping") or w["word"] == "working":
        return "busy"
    return ""


def codex_api():
    """The Codex road's two calls: identity(pane, socket) and client(remote)."""
    seam = os.environ.get("FLEET_GATE_CODEX")
    if seam:
        import runpy
        g = runpy.run_path(seam)
        return g["identity"], g["client"]
    import runpy
    sess = runpy.run_path(str(BIN / "fleet-codex-session.py"))
    rpc = runpy.run_path(str(BIN / "fleet-codex-rpc.py"))
    return sess["identity"], (lambda remote: rpc["Client"](remote, timeout=5))


def codex_version(client):
    m = re.search(r"/(\d+)\.(\d+)\.(\d+)", str((getattr(client, "initialized", None) or {}).get("userAgent", "")))
    return tuple(int(x) for x in m.groups()) if m else None


def can_talk(w):
    """(True, '') or (False, why): may the web say a sentence into this session?"""
    if w is None:
        return False, "no_session"
    if w["agent"] not in ("claude", "codex"):
        return False, "agent"
    if w["parked"]:
        return True, ""          # its next start is the current agent with the current mod
    if w["state"] == "exited":
        return False, "exited"
    if w["agent"] == "claude":
        return (True, "") if w["mod_accept"] == ACCEPT else (False, "old_version")
    try:
        identity, client = codex_api()
        data = identity(w["pane"], w["sock"])
        if not data or not str(data.get("remote", "")).startswith("unix://"):
            return False, "old_version"
        c = client(data["remote"])
        try:
            v = codex_version(c)
        finally:
            c.close()
        return (True, "") if v is not None and v[:2] >= CODEX_MIN else (False, "old_version")
    except Exception:  # noqa: BLE001 — an unreachable server is read-only for now
        return False, "unreachable"


# ---- watched: a person looking at the window --------------------------------------
def watched(w):
    """A terminal client (not control mode) whose current window is this one."""
    raw = tmux(w["sock"], "list-clients", "-F", "#{client_control_mode}\t#{window_id}")
    if not raw:
        return False
    for line in raw.splitlines():
        ctl, _, wid = line.partition("\t")
        if ctl != "1" and wid.strip() == w["win"]:
            return True
    return False


# ---- records ---------------------------------------------------------------------
def records(fid):
    d = gate_root() / fid
    rows = []
    for p in sorted(d.glob("*.json")) if d.is_dir() else []:
        r = read_json(p)
        if isinstance(r, dict) and r.get("delivery"):
            r["_path"] = str(p)
            rows.append(r)
    rows.sort(key=lambda r: (r.get("at", 0), r.get("delivery", "")))
    return rows


def save(r):
    path = r.pop("_path", None) or str(fid_dir(r["fid"]) / ("%d-%s.json" % (int(r["at"] * 1000), r["delivery"])))
    write_json(path, r)
    r["_path"] = path


def lock(fid):
    f = (fid_dir(fid) / ".lock").open("a")
    fcntl.flock(f, fcntl.LOCK_EX)
    return f


def compose(r):
    text = r["text"]
    pics = [p for p in r.get("images") or [] if p]
    if pics:
        text += "\n\n" + "\n".join("[附图] " + p for p in pics)
    return text


def ret(r, why):
    r.update(state="returned", why=why, returned_at=now())
    save(r)
    log("returned", r, why)


def log(ev, r, why=""):
    try:
        d = conf_dir() / "logs"
        if d.is_dir():
            with (d / "session-gate.log").open("a") as f:
                f.write("%s %s fid=%s delivery=%s agent=%s state=%s why=%s\n" % (
                    time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now())), ev, r.get("fid", "-"),
                    r.get("delivery", "-"), r.get("agent", "-"), r.get("state", "-"), why or "-"))
    except OSError:
        pass


# ---- Claude: the mod's inbox slot --------------------------------------------------
def claude_inbox(w):
    label = Path(w["socket_path"]).name if w["socket_path"] else w["sock"]
    if not label or not re.fullmatch(r"%[0-9]+", w["pane"] or ""):
        return None
    d = conf_dir() / "global/mod-inbox" / label / w["pane"][1:]
    d.mkdir(parents=True, exist_ok=True, mode=0o700)
    return d


def claude_post(directory, request, wait):
    """One idle.v2 request in the pane's fixed slot; the mod's answer (a dict)."""
    seam = os.environ.get("FLEET_GATE_ACCEPT_CMD")
    if seam:
        p = subprocess.run(shlex.split(seam), input=json.dumps(request), capture_output=True, text=True, timeout=60)
        try:
            return json.loads(p.stdout)
        except ValueError:
            return dict(state="unknown", reason="seam")
    base = Path(directory) / "idle-accept"
    with base.with_suffix(".lock").open("a") as lk:
        try:
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return dict(state="rejected", reason="accept_slot_busy")
        tmp = Path(directory) / ".idle-accept.tmp"
        paths = [base.with_suffix(x) for x in (".json", ".taken", ".done")]
        try:
            for path in paths:
                path.unlink(missing_ok=True)
            tmp.write_text(json.dumps(request))
            tmp.replace(paths[0])
            deadline = time.monotonic() + wait
            while time.monotonic() < deadline:
                done = read_json(paths[2])
                if done is not None:
                    if done.get("ok") is not True:
                        return dict(state="rejected", reason="mod_refused:" + str(done.get("error", ""))[:80])
                    if done.get("nonce") != request["nonce"] or done.get("delivery_id") != request["delivery_id"]:
                        return dict(state="unknown", reason="mod_answer_mismatch")
                    return done
                time.sleep(.05)
            try:
                # never taken: the same rename the mod claims with, so one side wins
                paths[0].rename(base.with_suffix(".cancelled"))
                return dict(state="rejected", reason="not_taken")
            except FileNotFoundError:
                return dict(state="unknown", reason="entry_unanswered")
        finally:
            for path in [tmp, *paths, base.with_suffix(".cancelled")]:
                path.unlink(missing_ok=True)


def claude_transcript(sid):
    root = Path(os.environ.get("FLEET_CC_PROJECTS_DIR") or os.environ.get("CLAUDE_PROJECTS_DIR")
                or Path.home() / ".claude/projects")
    hits = list(root.glob("*/" + sid + ".jsonl")) if sid else []
    return hits[0] if len(hits) == 1 else None


def claude_receipt(directory, delivery, sid):
    """True (delivered) · False (not in the conversation) · None (cannot tell)."""
    if directory is not None:
        r = read_json(Path(directory) / ("idle-accept-%s.receipt" % delivery))
        if isinstance(r, dict) and r.get("delivery_id") == delivery and r.get("state") == "accepted":
            return True
    t = claude_transcript(sid)
    if t is None:
        return None
    try:
        with open(t, "rb") as f:
            return (RECEIPT_PREFIX + delivery).encode() in f.read()
    except OSError:
        return None


REFUSAL_WHY = {"draft_present": "typing", "precheck_not_idle": "busy", "not_idle_at_entry": "busy",
               "session_changed": "busy", "accept_slot_busy": "busy", "not_taken": "busy",
               "not_submitted": "busy", "deadline_passed": "busy", "dropped_beneath": "busy"}


def claude_try(r, w):
    directory = claude_inbox(w)
    if directory is None:
        return "queued", "no_inbox"
    if r.get("state") == "trying":
        # settle the earlier attempt before anything new: never a blind resend
        got = claude_receipt(directory, r["delivery"], w["sid"] or r.get("sid", ""))
        if got:
            return "sent", "receipt"
        if now() < r.get("deadline", 0) + ACCEPT_GRACE + ACCEPT_POLL:
            return "trying", "unsettled"
        if got is None and w["sid"]:
            return "trying", "receipt_unreadable"
        # past its deadline the mod drops it at entry: it never ran
    request = dict(accept=ACCEPT, nonce=uuid.uuid4().hex, delivery_id=r["delivery"], text=compose(r),
                   deadline=now() + ACCEPT_WINDOW)
    r.update(state="trying", nonce=request["nonce"], deadline=request["deadline"], tries=r.get("tries", 0) + 1,
             method="mod/idle.v2", last=now())
    save(r)
    done = claude_post(directory, request, ACCEPT_WINDOW + ACCEPT_GRACE + ACCEPT_POLL)
    st, why = done.get("state"), str(done.get("reason") or "")
    if st == "accepted" and done.get("turn_id"):
        r["turn"] = done["turn_id"]
        return "sent", why
    if st == "rejected":
        return "queued", REFUSAL_WHY.get(why, why or "busy")
    return "trying", why or "unknown"


# ---- Codex: its own queue -------------------------------------------------------------
def codex_receipt(client, sid, delivery, pages=20):
    cursor = None
    for _ in range(pages):
        params = dict(threadId=sid, limit=50, sortDirection="desc", itemsView="summary")
        if cursor:
            params["cursor"] = cursor
        try:
            page = client.call("thread/turns/list", params)
        except ValueError as e:
            if "not supported" not in str(e) or cursor:
                raise
            turns = client.call("thread/read", dict(threadId=sid, includeTurns=True))["thread"].get("turns") or []
            return any(i.get("type") == "userMessage" and i.get("clientId") == delivery
                       for t in turns for i in t.get("items") or [])
        for t in page.get("data") or []:
            if any(i.get("type") == "userMessage" and i.get("clientId") == delivery for i in t.get("items") or []):
                return True
        cursor = page.get("nextCursor")
        if not page.get("data") or not cursor:
            return False
    return None


def codex_queued(client, sid, delivery):
    cursor = None
    for _ in range(20):
        params = dict(threadId=sid, limit=50)
        if cursor:
            params["cursor"] = cursor
        page = client.call("thread/queue/list", params)
        for q in page.get("data") or []:
            if q.get("clientUserMessageId") == delivery:
                return q.get("id")
        cursor = page.get("nextCursor")
        if not cursor:
            return None
    return None


def codex_try(r, w):
    identity, mkclient = codex_api()
    data = identity(w["pane"], w["sock"])
    if not data or not str(data.get("remote", "")).startswith("unix://"):
        return "queued", "unreachable"
    sid = data.get("session_id") or w["sid"]
    client = mkclient(data["remote"])
    try:
        v = codex_version(client)
        if v is None or v[:2] < CODEX_MIN:
            return "returned", "old_version"
        if r.get("state") in ("trying", "native"):
            if codex_receipt(client, sid, r["delivery"]):
                return "sent", "receipt"
            qid = codex_queued(client, sid, r["delivery"])
            if qid is not None:
                return start_queued(client, sid, qid, r)
            if r.get("state") == "native":
                return "returned", "dropped"   # gone from Codex's queue, never run
        r.update(state="trying", tries=r.get("tries", 0) + 1, method="thread/queue", last=now(), sid=r.get("sid") or sid)
        save(r)
        try:
            q = client.call("thread/queue/add", dict(threadId=sid, clientUserMessageId=r["delivery"],
                                                     input=[dict(type="text", text=compose(r))]))["queuedSubmission"]
        except ValueError:
            return "queued", "native_add_refused"
        return start_queued(client, sid, q.get("id"), r)
    finally:
        client.close()


def start_queued(client, sid, qid, r):
    try:
        turn = client.call("thread/queue/start", dict(threadId=sid, queuedSubmissionId=qid))["turn"]
    except ValueError as e:
        # answering: it waits in Codex's own queue and starts when the turn ends
        return ("native", "busy") if CODEX_NOT_IDLE in str(e) else ("native", "start_refused")
    r["turn"] = (turn or {}).get("id")
    return "sent", "native_started"


# ---- one session's tick ------------------------------------------------------------
def settle(fid, wait_new=None):
    """Deliver what is due for one session: the oldest live record only. Returns the
    record that was `wait_new` (by delivery id) after the pass, if given."""
    queue_secs = num_env("FLEET_GATE_QUEUE_SECS", 1800)
    with lock(fid):
        rows = records(fid)
        t = now()
        for r in rows:          # prune what the page no longer needs
            if (r.get("state") == "sent" and t - r.get("sent_at", t) > KEEP_SENT) or \
               (r.get("state") == "returned" and t - r.get("returned_at", t) > KEEP_RETURNED):
                Path(r["_path"]).unlink(missing_ok=True)
        live = [r for r in rows if r.get("state") in ("queued", "trying", "native", "waking")]
        if not live:
            return find(rows, wait_new)
        w = window(fid)
        if w is None:
            for r in live:
                ret(r, "no_session")
            return find(rows, wait_new)
        for r in live:
            if r.get("sid") and w["sid"] and r["sid"] != w["sid"] and not w["parked"]:
                ret(r, "session_changed")       # a /clear or another conversation: never into it
            elif r.get("state") == "queued" and t - r.get("at", t) > queue_secs:
                ret(r, "expired")
        live = [r for r in live if r.get("state") in ("queued", "trying", "native", "waking")]
        if not live:
            return find(rows, wait_new)
        r = live[0]
        ok, why = can_talk(w)
        if not ok:
            for x in live:
                ret(x, why)
            return find(rows, wait_new)
        st, why = deliver(r, w)
        if st == "sent":
            r.update(state="sent", why="", sent_at=now(), how=why)
            save(r)
            log("sent", r, why)
        elif st == "returned":
            ret(r, why)
        else:
            if r.get("state") != st or r.get("why") != why:
                r.update(state=st, why=why)
                save(r)
        return find(rows, wait_new)


def find(rows, delivery):
    if not delivery:
        return None
    return next((r for r in rows if r.get("delivery") == delivery), None)


def deliver(r, w):
    """(state, why) after one attempt: sent · queued · trying · native · waking · returned."""
    if r.get("state") == "waking" or w["parked"]:
        return wake_try(r, w)
    b = busy_of(w)
    if b == "asking" and r.get("state") == "queued":
        return "queued", b                     # the question first: the page shows its card
    if w["agent"] == "codex":
        return codex_try(r, w)                 # answering: it waits in Codex's own queue
    if b and r.get("state") == "queued":
        return "queued", b
    return claude_try(r, w)


# ---- park / wake ----------------------------------------------------------------------
def wake_path(fid, delivery):
    return fid_dir(fid) / ("wake-%s.txt" % (delivery or "bare"))


def wake_try(r, w):
    wake_secs = num_env("FLEET_GATE_WAKE_SECS", 20)
    seed = wake_path(r["fid"], r["delivery"])
    if r.get("state") == "waking":
        if Path(str(seed) + ".launched").exists():
            return "sent", "woken"
        if now() - r.get("wake_at", now()) <= wake_secs:
            return "waking", "waking"
        # not up in time: take the seed back (the wrapper claims it by the same
        # rename, so one side wins) — taken = it is starting, wait for it
        try:
            seed.rename(str(seed) + ".cancelled")
        except FileNotFoundError:
            if Path(str(seed) + ".taken").exists() and now() - r.get("wake_at", now()) <= wake_secs * 3:
                return "waking", "starting"
            return ("sent", "woken") if Path(str(seed) + ".launched").exists() else ("returned", "wake_timeout")
        tmux(w["sock"], "set-option", "-wu", "-t", w["win"], "@park_wake")
        park_log(r["fid"], "fail", "网页", now() - r.get("wake_at", now()), "wake_timeout")
        return "returned", "wake_timeout"
    seed.write_text(compose(r))
    r.update(state="waking", wake_at=now(), method="wake", tries=r.get("tries", 0) + 1)
    save(r)
    log("wake", r, "seed")
    requested = wake_request(w, seed, "网页")
    if not requested.get("ok"):
        seed.unlink(missing_ok=True)
        return "queued", requested["why"]
    # the wrapper polls; give it a moment so a quick start answers `sent` at once
    end = time.monotonic() + min(wake_secs, float(os.environ.get("FLEET_GATE_WAKE_WAIT", "3")))
    while time.monotonic() < end:
        if Path(str(seed) + ".launched").exists():
            return "sent", "woken"
        time.sleep(.1)
    return "waking", "waking"


def park_log(fid, act, why, secs=0, result="ok", next_at=0, started=0):
    """Only actions, never a polling skip. One append ≤ PIPE_BUF."""
    row = dict(ts=int(now()), fid=fid, act=act, why=why, secs=round(secs, 3),
               result=result, next=next_at, started=started)
    try:
        directory = conf_dir() / "logs"
        directory.mkdir(parents=True, exist_ok=True)
        fd = os.open(directory / "park.ndjson", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(fd, (json.dumps(row, ensure_ascii=False) + "\n").encode())
        finally:
            os.close(fd)
    except OSError:
        pass


def presence(w):
    """Recent first-person input / an open web page; missing evidence is conservative.

    @park_presence is an epoch: the web / keyboard reader refreshes it, peer
    messages never do. Browser-owned human work already holds the bg gate.
    """
    import fleet_reap_policy
    stamp = w.get("presence", "")
    return not stamp.isdigit() or now() - int(stamp) < fleet_reap_policy.park_presence_secs()


def park_background(w):
    seam = os.environ.get("FLEET_GATE_BG_CMD")
    argv = shlex.split(seam) if seam else [
        "bash", "-c", '. "$1/fleet-lib.sh" >/dev/null 2>&1; '
        'fleet_window_bg_busy "$2" "$3" "" 1', "park-bg", str(BIN), w["sock"], w["win"]]
    env = dict(os.environ)
    # These helpers inherit the window's server, never the caller's socket.
    if w.get("socket_path"):
        env["TMUX"] = w["socket_path"] + ",0,0"
    try:
        p = subprocess.run(argv, capture_output=True, timeout=15, env=env)
        return p.returncode != 1            # unknown / failed probes hold too
    except (OSError, subprocess.SubprocessError):
        return True


def relay_request(w, request):
    """The 7501 relay owns the pty. No tmux keys and no Escape fallback."""
    path = w.get("relay", "")
    if not path:
        return dict(ok=False, why="no_relay")
    try:
        with socket.socket(socket.AF_UNIX) as c:
            c.settimeout(3)
            c.connect(path)
            c.sendall((json.dumps(request) + "\n").encode())
            raw = c.recv(4096)
        return json.loads(raw)
    except (OSError, ValueError):
        return dict(ok=False, why="relay_unavailable")


def park_proof(w):
    seam = os.environ.get("FLEET_GATE_PARK_PROBE_CMD")
    if seam:
        try:
            p = subprocess.run(shlex.split(seam), capture_output=True, text=True, timeout=5)
            return json.loads(p.stdout) if p.returncode == 0 else dict(ok=False, why="probe_failed")
        except (OSError, ValueError, subprocess.SubprocessError):
            return dict(ok=False, why="probe_failed")
    directory = claude_inbox(w)
    if directory is None:
        return dict(ok=False, why="no_probe")
    nonce = uuid.uuid4().hex
    base = directory / ("%d-park-%s" % (int(now()), nonce))
    pending = Path(str(base) + ".json")
    write_json(pending, dict(query="park.v1", nonce=nonce, deadline=now() + 5))
    end = time.monotonic() + 5
    while time.monotonic() < end:
        answer = read_json(str(base) + ".done")
        if isinstance(answer, dict):
            for suffix in (".done", ".taken"):
                Path(str(base) + suffix).unlink(missing_ok=True)
            return answer
        time.sleep(.05)
    # Late probes are read-only; cancel when still unclaimed.
    pending.unlink(missing_ok=True)
    return dict(ok=False, why="probe_timeout")


def park_saved_mb(w):
    """RSS of this window's agent tree; no command text or credentials logged."""
    try:
        rows = subprocess.run(["ps", "-axo", "pid=,ppid=,rss="], capture_output=True,
                              text=True, timeout=5).stdout.splitlines()
        tree = [tuple(map(int, line.split())) for line in rows if len(line.split()) == 3]
        owned = {int(w.get("pane_pid") or 0)}
        for _ in range(len(tree)):
            more = {pid for pid, ppid, rss in tree if ppid in owned}
            if more <= owned:
                break
            owned |= more
        return round(sum(rss for pid, ppid, rss in tree if pid in owned) / 1024, 1)
    except (OSError, ValueError, subprocess.SubprocessError):
        return 0


def park(fid, why="idle", force=False):
    with lock(fid):
        return park_locked(fid, why, force)


def park_locked(fid, why, force):
    import fleet_agent_adapter
    w = window(fid)
    if w is None:
        return dict(ok=False, why="no_session")
    if w["parked"]:
        return dict(ok=True, already=True)
    if not w.get("wrap_ver", "").isdigit() or int(w["wrap_ver"]) < 1:
        return dict(ok=False, why="old_wrapper")
    adapter = fleet_agent_adapter.ADAPTERS.get(w["agent"], {})
    if adapter.get("park_resume") != "1" or not w["sid"]:
        return dict(ok=False, why="not_resumable")
    if w["state"] not in ("done", "looping"):
        return dict(ok=False, why=busy_of(w) or "not_idle")
    if busy_of(w) and not w["loop"]:
        return dict(ok=False, why=busy_of(w))
    if watched(w):
        tmux(w["sock"], "set-option", "-w", "-t", w["win"], "@park_watched_at", str(int(now())))
        return dict(ok=False, why="watched")
    if park_background(w):
        return dict(ok=False, why="bg")
    if any(r.get("state") in ("queued", "trying", "native", "waking") for r in records(fid)):
        return dict(ok=False, why="words_waiting")
    # C3 hands timers out before the process goes away. Until it is installed,
    # a live timer is a hold, never a silently lost wakeup.
    if w["loop"]:
        p = subprocess.run([sys.executable, str(BIN / "fleet_loop_mark.py"), "export", "--fid", fid],
                           capture_output=True, timeout=10)
        if p.returncode != 0:
            return dict(ok=False, why="wake_contract")
    generation = relay_request(w, dict(op="status"))
    seam = os.environ.get("FLEET_GATE_EXIT_CMD")
    if not generation.get("ok") and not seam:
        return generation
    proof = park_proof(w)
    if not proof.get("ok"):
        return dict(ok=False, why=proof.get("why") or proof.get("error") or "not_idle")
    # Recheck after the native proof: a client / queued turn may have arrived.
    current = window(fid)
    if (current is None or current["sid"] != w["sid"] or current["word"] in ("working", "blocked")
            or current["state"] in ("working", "needs", "exited") or watched(current)):
        return dict(ok=False, why="changed")
    started = time.monotonic()
    since = str(int(now()))
    for option, value in (("@parked", since), ("@park_since", since), ("@park_why", why),
                          ("@park_saved_mb", str(park_saved_mb(w)))):
        tmux(w["sock"], "set-option", "-w", "-t", w["win"], option, value)
    if seam:
        rc = subprocess.run(shlex.split(seam) + [w["pane"]], capture_output=True, timeout=5).returncode
        sent = dict(ok=rc in (0, 6))
    else:
        sent = relay_request(w, dict(op="exit", generation=generation.get("generation")))
    if sent.get("ok"):
        end = time.monotonic() + num_env("FLEET_GATE_PARK_SECS", 15)
        while time.monotonic() < end:
            held = tmux(w["sock"], "display-message", "-p", "-t", w["win"], "#{@park_held}")
            if held and held.strip():
                park_log(fid, "park", why, time.monotonic() - started)
                return dict(ok=True, why=why)
            time.sleep(.1)
    for option in ("@parked", "@park_since", "@park_why", "@park_saved_mb"):
        tmux(w["sock"], "set-option", "-wu", "-t", w["win"], option)
    park_log(fid, "fail", why, time.monotonic() - started, sent.get("why") or "exit_failed")
    return dict(ok=False, why=sent.get("why") or "exit_failed")


def wake_request(w, seed, why):
    """Called under the fid lock: one owned seed, never replace another wake."""
    active = w.get("park_wake") or w.get("park_start")
    if active:
        return dict(ok=False, why="wake_pending")
    meta = dict(fid=w["fid"], why=why, started=now(), seed=str(seed),
                next=(read_json(conf_dir() / "wake" / (w["fid"] + ".json")) or {}).get("next", 0))
    write_json(str(seed) + ".meta", meta)
    tmux(w["sock"], "set-option", "-w", "-t", w["win"], "@park_wake", str(seed))
    return dict(ok=True, seed=str(seed))


def wake_ready(pane):
    """7501's first native report: the resumed engine is up, not merely forked."""
    raw = tmux("", "display-message", "-p", "-t", pane, "#{@park_start}")
    if not raw or not raw.strip():
        return
    path = Path(raw.strip())
    try:
        path.rename(str(path) + ".claimed")
    except OSError:
        return
    meta = read_json(str(path) + ".claimed") or {}
    seed = meta.get("seed", "")
    if seed:
        Path(seed + ".launched").touch()
        Path(seed + ".taken").unlink(missing_ok=True)
    park_log(meta.get("fid", ""), "wake", meta.get("why", ""),
             max(0, now() - meta.get("started", now())), "resumed", meta.get("next", 0), meta.get("started", 0))
    # Also clear for a wrapper already running the previous release's hold page.
    tmux("", "set-option", "-wu", "-t", pane, "@park_since")
    tmux("", "set-option", "-wu", "-t", pane, "@park_start")
    Path(str(path) + ".claimed").unlink(missing_ok=True)


def wake(fid, seed_file=None, why="网页", request_only=False):
    with lock(fid):
        w = window(fid)
        if w is None:
            return dict(ok=False, why="no_session")
        if not w["parked"]:
            return dict(ok=True, already=True)
        seed = wake_path(fid, uuid.uuid4().hex)
        seed.write_text(Path(seed_file).read_text() if seed_file else "")
        result = wake_request(w, seed, why)
        if not result.get("ok"):
            seed.unlink(missing_ok=True)
            return result
    if request_only:
        return result
    end = time.monotonic() + num_env("FLEET_GATE_WAKE_SECS", 20)
    while time.monotonic() < end:
        if Path(str(seed) + ".launched").exists():
            return dict(ok=True)
        time.sleep(.1)
    # Reclaim only an unclaimed seed. A launch in progress owns its first words.
    try:
        seed.rename(str(seed) + ".cancelled")
        tmux(w["sock"], "set-option", "-wu", "-t", w["win"], "@park_wake")
    except FileNotFoundError:
        pass
    park_log(fid, "fail", why, num_env("FLEET_GATE_WAKE_SECS", 20), "wake_timeout")
    return dict(ok=False, why="wake_timeout", seed=str(seed))


# ---- stop -------------------------------------------------------------------------------
def stop(fid):
    w = window(fid)
    if w is None:
        return dict(ok=False, why="no_session")
    if w["parked"] or not busy_of(w) == "busy":
        return dict(ok=True, how="idle")
    if w["agent"] == "codex":
        identity, mkclient = codex_api()
        data = identity(w["pane"], w["sock"])
        if not data:
            return dict(ok=False, why="unreachable")
        c = mkclient(data["remote"])
        try:
            page = c.call("thread/turns/list", dict(threadId=data["session_id"], limit=1, sortDirection="desc",
                                                    itemsView="summary"))
            t = (page.get("data") or [{}])[0]
            if t.get("status") not in ("inProgress", "in_progress", "running"):
                return dict(ok=True, how="idle")
            c.call("turn/interrupt", dict(threadId=data["session_id"], turnId=t.get("id")))
        finally:
            c.close()
        return dict(ok=True, how="turn/interrupt")
    # Claude: Esc stops a running turn (0.34 s measured); only when its own report
    # says it is working — never on a question or an idle prompt (Esc clears a draft)
    if w["word"] and w["word"] != "working":
        return dict(ok=True, how="idle")
    sk = os.environ.get("FLEET_GATE_TMUX", "tmux")
    p = subprocess.run([sk, "-L", w["sock"], "send-keys", "-t", w["pane"], "Escape"],
                       env=dict(os.environ, FLEET_ALLOW_SENDKEYS="1"), capture_output=True, timeout=10)
    return dict(ok=p.returncode == 0, how="escape")


# ---- what the session asks (the page's card) ---------------------------------------------
def needs_detail():
    import runpy
    return runpy.run_path(str(BIN / "fleet_needs_detail.py"))


def permission_view(w):
    seam = os.environ.get("FLEET_GATE_PERMISSION_CMD")
    argv = (shlex.split(seam) if seam else ["bash", str(BIN / "fleet-permission.sh")]) + \
        ["-L", w["sock"], "--show", "--json", w["win"]]
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=30)
        return json.loads(p.stdout) if p.returncode == 0 and p.stdout.strip().startswith("{") else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def ask_card(w):
    """The open question as the page draws it, or None: an AskUserQuestion
    ({fp, kind: question, questions: [{question, header, multiSelect, options:
    [{label}]}]}) or a permission prompt ({fp, kind: permission, tool, summary})."""
    import hashlib
    if w is None or busy_of(w) != "asking":
        return None
    if w["needs"] in ("perm", "permission") or '"kind":"permission"' in w["agent_status"].replace(" ", ""):
        v = permission_view(w)
        if not isinstance(v, dict):
            return None
        fp = hashlib.sha1(json.dumps(v, sort_keys=True, ensure_ascii=False).encode()).hexdigest()[:16]
        summary = str(v.get("command") or v.get("summary") or v.get("input") or "")[:400]
        return dict(fp=fp, kind="permission", tool=str(v.get("tool") or v.get("name") or ""), summary=summary)
    t = claude_transcript(w["sid"]) if w["agent"] == "claude" else None
    if t is None:
        return None
    nd = needs_detail()
    d = nd["pending_dialog"](str(t))
    if not d:
        return None
    return dict(fp=nd["dialog_fp"](d), kind="question",
                questions=[dict(question=q["question"], header=q.get("header", ""), multiSelect=bool(q.get("multiSelect")),
                                options=[dict(label=o) for o in q["options"]]) for q in d["questions"]])


def answer(fid, fp, picks=None, answers=None, allow=None):
    loc = locate(fid)
    if loc is None:
        return dict(ok=False, why="no_session")
    w = window(fid)
    card = ask_card(w)
    if card is None or card["fp"] != fp:
        return dict(ok=False, why="changed")       # answered meanwhile, or another question now
    if card["kind"] == "permission":
        if allow is None:
            return dict(ok=False, why="allow_or_deny")
        seam = os.environ.get("FLEET_GATE_PERMISSION_CMD")
        argv = (shlex.split(seam) if seam else ["bash", str(BIN / "fleet-permission.sh")]) + \
            ["-L", w["sock"], "--by", "网页", "--allow" if allow else "--deny", w["win"]]
        p = subprocess.run(argv, capture_output=True, text=True, timeout=120)
        return dict(ok=p.returncode == 0, why={0: "", 3: "changed", 4: "unconfirmed"}.get(p.returncode, "failed"))
    picks = list(picks or [])
    if answers:
        qs = card["questions"]
        for i, q in enumerate(qs):
            got = answers.get(q["question"])
            if got is None:
                continue
            for label in (got if isinstance(got, list) else [got]):
                picks.append(str(label) if len(qs) == 1 else "%d=%s" % (i + 1, label))
    if not picks:
        return dict(ok=False, why="no_pick")
    seam = os.environ.get("FLEET_GATE_DIALOG_CMD")
    argv = (shlex.split(seam) if seam else ["bash", str(BIN / "fleet-dialog-answer.sh")]) + \
        [loc[1], "-L", loc[0], "--fp", fp, "--by", "person", "--basis", "网页上点选"] + sum((["--pick", x] for x in picks), [])
    p = subprocess.run(argv, capture_output=True, text=True, timeout=120)
    why = {0: "", 3: "changed", 4: "unconfirmed", 5: "typing"}.get(p.returncode, "failed")
    return dict(ok=p.returncode == 0, why=why, said=(p.stderr or p.stdout).strip()[-300:])


# ---- the CLI ------------------------------------------------------------------------------
def status(fid):
    w = window(fid)
    if w:
        # The web keeps this call open while its conversation page is present.
        tmux(w["sock"], "set-option", "-w", "-t", w["win"], "@park_presence", str(int(now())))
    ok, why = can_talk(w)
    q = [dict(delivery=r["delivery"], text=r["text"], why=r.get("why") or r.get("state"), state=r.get("state"))
         for r in records(fid) if r.get("state") in ("queued", "trying", "native", "waking", "returned")]
    try:
        ask = ask_card(w)
    except Exception:  # noqa: BLE001 — a card that cannot be read is no card
        ask = None
    return dict(can_talk=ok, why=why, agent=(w or {}).get("agent", ""), session=(w or {}).get("sid", ""),
                busy=bool(w and busy_of(w)), queue=q, ask=ask)


def say(args):
    fid = args.fid
    text = sys.stdin.read() if args.text_file in (None, "-") else Path(args.text_file).read_text()
    text = text.strip()
    images = [str(Path(p)) for p in args.image or []]
    if not text and not images:
        return out(dict(state="refused", reason="empty"), 2)
    if len(text) > TEXT_MAX or len(images) > IMAGES_MAX:
        return out(dict(state="refused", reason="too_large"), 2)
    delivery = args.delivery or str(uuid.uuid4())
    if not UUID_RE.match(delivery):
        return out(dict(state="refused", reason="bad_delivery"), 2)
    with lock(fid):
        known = find(records(fid), delivery)
    if known is not None:
        # the same sentence again (a retry after a dropped answer): never twice
        return out(dict(delivery=delivery, state=public(known), reason=known.get("why", "")))
    w = window(fid)
    ok, why = can_talk(w)
    if not ok:
        return out(dict(delivery=delivery, state="refused", reason=why))
    r = dict(v=1, delivery=delivery, fid=fid, text=text or "（图片）", images=images, at=now(), sid=w["sid"],
             agent=w["agent"], state="queued", why="", tries=0)
    with lock(fid):
        save(r)
    w = window(fid)
    if w:
        tmux(w["sock"], "set-option", "-w", "-t", w["win"], "@park_presence", str(int(now())))
    log("say", r)
    got = settle(fid, delivery) or r
    return out(dict(delivery=delivery, state=public(got), reason=got.get("why", "")))


def public(r):
    st = r.get("state")
    return "sent" if st == "sent" else "refused" if st == "returned" else "queued"


def main(argv=None):
    ap = argparse.ArgumentParser(prog="fleet_session_gate.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("say", "tick", "status", "ack", "stop", "answer", "park", "wake", "pending", "watched", "name"):
        p = sub.add_parser(name)
        if name not in ("pending",):
            p.add_argument("--fid", required=name != "tick")
        if name == "say":
            p.add_argument("--text-file")
            p.add_argument("--image", action="append")
            p.add_argument("--delivery")
        if name == "ack":
            p.add_argument("--delivery", required=True)
        if name == "answer":
            p.add_argument("--fp", required=True)
            p.add_argument("--pick", action="append")
            p.add_argument("--answers-json")
            p.add_argument("--allow", choices=["0", "1"])
        if name == "park":
            p.add_argument("--why", default="idle", choices=["idle", "memory"])
            p.add_argument("--force", action="store_true")
        if name == "wake":
            p.add_argument("--seed-file")
            p.add_argument("--why", default="网页")
            p.add_argument("--request-only", action="store_true")
        if name == "name":
            p.add_argument("--name", required=True)
    a = ap.parse_args(argv)
    if getattr(a, "fid", None) and not FID_RE.match(a.fid):
        return out(dict(ok=False, why="bad_fid"), 2)
    if a.cmd == "say":
        return say(a)
    if a.cmd == "tick":
        fids = [a.fid] if a.fid else pending_fids()
        for f in fids:
            settle(f)
        return out(dict(ok=True, ticked=len(fids)))
    if a.cmd == "status":
        settle(a.fid)
        return out(status(a.fid))
    if a.cmd == "ack":
        with lock(a.fid):
            for r in records(a.fid):
                if r["delivery"] == a.delivery and r.get("state") == "returned":
                    Path(r["_path"]).unlink(missing_ok=True)
        return out(dict(ok=True))
    if a.cmd == "stop":
        return out(stop(a.fid))
    if a.cmd == "answer":
        try:
            answers = json.loads(a.answers_json) if a.answers_json else None
        except ValueError:
            return out(dict(ok=False, why="bad_answers"), 2)
        if answers is not None and not isinstance(answers, dict):
            return out(dict(ok=False, why="bad_answers"), 2)
        return out(answer(a.fid, a.fp, a.pick, answers, None if a.allow is None else a.allow == "1"))
    if a.cmd == "park":
        return out(park(a.fid, a.why, a.force))
    if a.cmd == "wake":
        return out(wake(a.fid, a.seed_file, a.why, a.request_only))
    if a.cmd == "name":
        # a name the person gave it (@name_manual, issue #3317): every list's title
        loc = locate(a.fid)
        if loc is None or not a.name.strip() or len(a.name) > 80:
            return out(dict(ok=False, why="no_session" if loc is None else "bad_name"), 1)
        tmux(loc[0], "rename-window", "-t", loc[1], a.name)
        tmux(loc[0], "set-option", "-w", "-t", loc[1], "@name_manual", a.name)
        return out(dict(ok=True))
    if a.cmd == "pending":
        return out(dict(fids=pending_fids()))
    if a.cmd == "watched":
        w = window(a.fid)
        on = bool(w and watched(w))
        out(dict(watched=on))
        return 0 if on else 1
    return 2


def pending_fids():
    root = gate_root()
    fids = []
    for d in sorted(root.iterdir()) if root.is_dir() else []:
        if not FID_RE.match(d.name):
            continue
        for p in d.glob("*.json"):
            r = read_json(p)
            if isinstance(r, dict) and r.get("state") in ("queued", "trying", "native", "waking"):
                fids.append(d.name)
                break
    return fids


if __name__ == "__main__":
    sys.exit(main())
