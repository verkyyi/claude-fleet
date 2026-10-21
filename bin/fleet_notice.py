#!/usr/bin/env python3
"""fleet_notice.py — THE one way the fleet tells the person something on screen
(T675, after issue #1618's fleet_ui_fail): three tiers, every notice recorded,
ONE book for every kind of reminder (T701) — a top-line notice, a session asking /
stuck / done (bin/fleet_notify.py), an alert (bin/fleet-alerts.sh), a result
nobody took (bin/fleet-report-parent.sh's orphan()) — drawn on the 看台's message
row under its top line (bin/fleet-topbar.py inbox) and read back from ⌘P's FIRST
row 「✦ 消息」; fleet takes no key of its own for it.

    fleet_notice.py notify <error|warn|info> <text> [--next <下一步>] [--client <name>]
                    [--sock <label>] [--all] [--view <看台 session>] [--source <name>]
                    [--secs N] [--tag T] [--no-draw] [--no-record]
                    [--kind session|alert|orphan] [--sub S] [--ref ID] [--wid W]
    fleet_notice.py list [--n 50] [--json]     the newest first (`fleet notices`)
    fleet_notice.py page [--view V]            「✦ 消息」 (⌘P's first row; the words 消息)
    fleet_notice.py unread                     how many are not seen yet (every kind, every machine)
    fleet_notice.py read [<id>…]               mark them seen: all, or those ids (an orphan's
                                               result read in its own book too)
    fleet_notice.py seen <tag>                 rc 0 when a notice carrying <tag> was recorded
    fleet_notice.py cell                       the node inventory's `notices=` cell (column 33)

THE TIERS. error — red, on the message row until seen (opening ⌘P's 消息; a key
clears nothing); warn — yellow, 6 s; info — grey, 3 s. The newest live one is
drawn, 「✦ N · ⌘P」 beside it — every one is in ⌘P's 消息.

WHO SEES IT. Only the client that asked (`--client`, a bind's #{client_name};
fleet_ui_fail passes FLEET_UI_CLIENT). With none named, tmux's own current
client — what display-message picked before; `--all` (a background alert that
needs you NOW): every client of the server. A 看台 (a session marked @view_thin)
gets its message row opened at once (`status 2` on a 看台 wearing `@view_inbox 1`;
`@view_notice` — base64 JSON: level · text · next · ts · until · hold · more — is
still stamped for an older reader). Any other client (a direct attach, an old
client) gets a display-message held for the tier.

THE RECORD. Every notice is one row of $FLEET_CONF_DIR/logs/notices.ndjson (ts ·
id · level · text · next · source · client · view · tag · kind · sub · ref · wid),
7 days kept (an old FIRST row costs one rewrite); the same level + text within
10 s is one row. Nothing is ever a credential: callers say what happened, never
what a token was.

THE MESSAGE ROW (T701). A notice the person has not seen — after the read mark
(logs/notices.read, moved by opening the page) and not in logs/notices.readids
(one marked read) — is unseen. The row under the 看台's top line is there while
one is LIVE: an error or a result nobody took until seen, a warn its 6 s, an info
its 3 s; it shows the newest live one and 「✦ N · ⌘P」, N every unseen one. The
other machines' books come from the hub's caches (`notices_<fleet>`,
`orphanrep_<fleet>`, bin/fleet-hub-sessions.sh — union by id) and the read mark
is the latest of every machine's, so another home sees the same messages.
"""
import base64
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

BIN = Path(__file__).absolute().parent
LEVELS = ("error", "warn", "info")
TIER = {"error": 10, "warn": 6, "info": 3}
KEEP = 7 * 86400
DEDUP = 10
PAGE_N = 50
KINDS = ("notice", "session", "alert", "orphan")
ID_RE = re.compile(r"[0-9a-f]{12}")
# the classes a message is shown as (fleet_view.MSG_GLYPHS — the one glyph table),
# in the page's order
CLASSES = ("ask", "error", "warn", "orphan", "done", "info")


def conf_dir():
    return Path(os.environ.get("FLEET_CONF_DIR") or os.path.join(os.path.expanduser("~"), ".config", "claude-fleet"))


def log_path():
    return conf_dir() / "logs" / "notices.ndjson"


def read_mark():
    return conf_dir() / "logs" / "notices.read"


def read_ids_path():
    return conf_dir() / "logs" / "notices.readids"


def row_id(r):
    """A row's own id: written at record time, else the hash of what it says (an
    older row) — the same result read on any machine is the same id."""
    rid = str(r.get("id") or "")
    if ID_RE.fullmatch(rid):
        return rid
    return hashlib.sha1(("%s\x1f%s\x1f%s\x1f%s" % (r.get("ts"), r.get("level"), r.get("text"),
                                                      r.get("source", ""))).encode("utf-8")).hexdigest()[:12]


def kind_of(r):
    k = r.get("kind")
    if k in KINDS:
        return k
    return "alert" if str(r.get("source", "")).startswith("alert:") else "notice"


def cls_of(r):
    """The class a row is shown as: ask · error · warn · orphan · done · info."""
    k = kind_of(r)
    if k == "orphan":
        return "orphan"
    if k == "session":
        return {"ask": "ask", "stuck": "error", "done": "done"}.get(r.get("sub"), "info")
    return {"error": "error", "warn": "warn"}.get(r.get("level"), "info")


def sticky(r):
    """On the message row until seen (an error, a result nobody took); every other
    class only for its tier."""
    return cls_of(r) in ("error", "orphan")


def clean(text, limit=400):
    """One line, no control bytes, at most `limit` characters."""
    t = re.sub(r"[\x00-\x1f\x7f]+", " ", str(text or "")).strip()
    return t[:limit]


# --- the record --------------------------------------------------------------------

def rows(n=None):
    """Every recorded notice, oldest first (the last `n` when given)."""
    try:
        with open(log_path(), "rb") as fh:
            if n:
                fh.seek(0, os.SEEK_END)
                size = fh.tell()
                fh.seek(max(0, size - 4096 * max(1, n // 8 + 1)))
            raw = fh.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return []
    out = []
    for line in raw:
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if isinstance(r, dict) and isinstance(r.get("ts"), (int, float)):
            out.append(r)
    return out[-n:] if n else out


def record(level, text, nxt="", source="", client="", view="", tag="", now=None, kind="", sub="", ref="", wid=""):
    """Append one row; False when it was a repeat (same level + text within DEDUP)."""
    now = time.time() if now is None else now
    path = log_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a+", encoding="utf-8") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            fh.seek(0)
            first = fh.readline()
            try:
                t0 = json.loads(first).get("ts", now) if first else now
            except (ValueError, AttributeError):
                t0 = 0
            if t0 < now - KEEP:
                keep = []
                for line in [first] + fh.readlines():
                    try:
                        if json.loads(line).get("ts", 0) >= now - KEEP:
                            keep.append(line if line.endswith("\n") else line + "\n")
                    except (ValueError, AttributeError):
                        pass
                fh.seek(0)
                fh.truncate()
                fh.write("".join(keep))
            for r in rows(8):
                if r.get("level") == level and r.get("text") == text and now - r["ts"] < DEDUP:
                    return False
            ts = round(now, 3)
            row = {"ts": ts, "id": row_id({"ts": ts, "level": level, "text": text, "source": source}),
                   "level": level, "text": text}
            for k, v in (("next", nxt), ("source", source), ("client", client), ("view", view), ("tag", tag),
                         ("kind", kind if kind in KINDS and kind != "notice" else ""), ("sub", sub),
                         ("ref", ref), ("wid", wid)):
                if v:
                    row[k] = v
            fh.seek(0, os.SEEK_END)
            fh.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
        return True
    except OSError:
        return False


def local_mark():
    try:
        return float(read_mark().read_text().strip() or 0)
    except (OSError, ValueError):
        return 0.0


def read_ids():
    try:
        return {l.strip() for l in read_ids_path().read_text().splitlines() if ID_RE.fullmatch(l.strip())}
    except OSError:
        return set()


def mark_read(now=None, ids=None):
    """Opening the page: everything up to now is seen (`ids` none). With `ids`: just
    those (the page's 标为已读), a result nobody took read in its own book too."""
    if ids is None:
        p = read_mark()
        try:
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("%.3f\n" % (time.time() if now is None else now))
        except OSError:
            pass
        return
    ids = [i for i in ids if ID_RE.fullmatch(i)]
    if not ids:
        return
    p = read_ids_path()
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        keep = [l for l in (p.read_text().splitlines() if p.exists() else []) if ID_RE.fullmatch(l)][-500:]
        p.write_text("".join(i + "\n" for i in keep + [i for i in ids if i not in keep]))
    except OSError:
        pass
    refs = [r.get("ref") for r in inbox() if r["id"] in ids and r.get("ref") and r.get("here")]
    if refs:
        try:
            subprocess.run([sys.executable, str(BIN / "fleet-orphan-reports.py"), "read"] + refs,
                           stdin=subprocess.DEVNULL, capture_output=True, timeout=10)
        except (OSError, subprocess.SubprocessError):
            pass


# --- the other machines (the hub's caches, bin/fleet-hub-sessions.sh) ------------------

US, RS = "\x1f", "\x1e"


def gdir():
    """The collector's machine-wide cache dir (fleet_view.dash_global's)."""
    base = os.environ.get("TMPDIR") or "/tmp/claude-fleet-%d" % os.getuid()
    return Path(os.environ.get("FLEET_STATUS_G") or os.path.join(base.rstrip("/"), ".claude-dash", "global"))


def cache_rows(g=None):
    """(rows, marks) off the other machines: `notices_<fleet>` lines — id · node · mark
    · ts · level · kind · sub · wid · text · local — and `orphanrep_<fleet>`'s
    (id · node · av · ts · repo · child · state · pr · summary · local); a line of
    THIS machine (local 1) is skipped, its own book is read instead."""
    g = Path(g) if g else gdir()
    out, marks = [], []
    try:
        names = os.listdir(g)
    except OSError:
        return out, marks
    for name in names:
        if not (name.startswith("notices_") or name.startswith("orphanrep_")):
            continue
        try:
            lines = (g / name).read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            p = line.split(US)
            if name.startswith("notices_") and len(p) >= 10 and p[-1] != "1":
                rid, node, mark, ts, level, kind, sub, wid, text = p[:9]
                if mark.replace(".", "", 1).isdigit():
                    marks.append(float(mark))
                if not ID_RE.fullmatch(rid) or not ts.isdigit():
                    continue
                out.append({"ts": int(ts), "id": rid, "level": level if level in LEVELS else "info",
                            "kind": kind if kind in KINDS else "notice", "sub": sub, "wid": wid,
                            "text": clean(text, 200), "node": node})
            elif name.startswith("orphanrep_") and len(p) >= 10 and p[-1] != "1":
                rid, node, _av, ts, repo, child, state, pr, summ = p[:9]
                if not ID_RE.fullmatch(rid) or not ts.isdigit():
                    continue
                out.append({"ts": int(ts), "id": rid, "ref": rid, "level": "warn", "kind": "orphan",
                            "text": orphan_text(child, state, pr, summ), "node": node, "repo": repo})
    return out, marks


def orphan_text(child, state, pr, summary):
    return clean("%s %s%s — %s%s" % (child, state, " (PR #%s)" % pr if pr else "", say("notice_orphan_gone"),
                                      (": " + summary) if summary else ""), 400)


_ORPHANS = []


def orphan_book():
    """bin/fleet-orphan-reports.py, the book's ONE reader, loaded in-process (no
    fork each 2 s); None when it cannot be."""
    if not _ORPHANS:
        try:
            import importlib.util
            spec = importlib.util.spec_from_file_location("fleet_orphan_reports", str(BIN / "fleet-orphan-reports.py"))
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
        except Exception:   # noqa: BLE001 — the row never dies for a reminder
            mod = None
        _ORPHANS.append(mod)
    return _ORPHANS[0]


def orphan_rows_local():
    """THIS machine's results nobody took that its book still holds unread, as
    messages (None: no book). Nothing is read while the file is empty."""
    f = conf_dir() / "global" / "orphan-reports.ndjson"
    try:
        if f.stat().st_size == 0:
            return []
    except OSError:
        return []
    mod = orphan_book()
    if mod is None:
        return None
    try:
        got = mod.unread(10 ** 6)
    except Exception:   # noqa: BLE001
        return None
    return [{"ts": int(r["ts"]), "id": r["id"], "ref": r["id"], "level": "warn", "kind": "orphan", "here": True,
             "text": orphan_text(r.get("child_key", ""), r.get("state", ""), r.get("pr", ""),
                                 clean(r.get("summary", ""), 300)), "repo": r.get("repo", "")} for r in got]


def inbox(now=None, g=None, remote=True):
    """Every message of the week, newest first, deduped by id (a result nobody took
    by its own id) — this machine's book and, with `remote`, the other machines'
    caches — each with `id`, `cls`, `here` and `seen` (after the latest read mark
    of any machine, or marked read by id)."""
    book = orphan_rows_local()
    held = None if book is None else {r["ref"] for r in book}
    got = list(book or [])
    for r in rows(400):
        r = dict(r, id=row_id(r), here=True)
        if kind_of(r) == "orphan" and held is not None and r.get("ref") not in held:
            r["gone"] = True          # read (or handed on) in its own book
        got.append(r)
    marks = [local_mark()]
    if remote:
        far, fm = cache_rows(g)
        got += far
        marks += fm
    mark = max(marks)
    ids = read_ids()
    seen_keys, out = set(), []
    for r in sorted(got, key=lambda r: (r["ts"], bool(r.get("here"))), reverse=True):
        k = r.get("ref") or r["id"]
        if k in seen_keys:
            continue
        seen_keys.add(k)
        r["cls"] = cls_of(r)
        r["seen"] = r["ts"] <= mark or r["id"] in ids or (r.get("ref") or "") in ids or bool(r.pop("gone", False))
        out.append(r)
    return out


def unseen(msgs):
    return [m for m in msgs if not m["seen"]]


def is_live(m, now):
    return not m["seen"] and (sticky(m) or now < m["ts"] + TIER.get(m.get("level"), 3))


def line_state(now=None, g=None):
    """(the newest live unseen message or None, how many are unseen) — the row
    under the top line shows while the first is not None."""
    now = time.time() if now is None else now
    msgs = inbox(now, g)
    un = unseen(msgs)
    return next((m for m in un if is_live(m, now)), None), len(un)


def unread(now=None):
    """How many messages are not seen yet (⌘P's 「✦ 消息 N」)."""
    return len(unseen(inbox(now)))


def cell():
    """The node inventory's `notices=` cell (column 33, bin/fleet-control-read.sh):
    this login's read mark, then its unseen messages but the results nobody took
    (those ride `orphanrep=`), each `id US ts US level US kind US sub US wid US text`,
    RS-joined, at most 10 — the mark alone when nothing is unseen, empty when this
    login never read and has nothing unseen."""
    un = [m for m in unseen(inbox(remote=False)) if m["cls"] != "orphan"][:10]
    if not un and not local_mark():
        return ""
    ents = [US.join([m["id"], str(int(m["ts"])), m.get("level", "info"), kind_of(m), clean(m.get("sub", ""), 16),
                     clean(m.get("wid", ""), 120), clean(m.get("text", ""), 200).replace(US, " ").replace(RS, " ")])
            for m in un]
    return RS.join(["%d" % int(local_mark())] + ents)


def seen(tag):
    return bool(tag) and any(r.get("tag") == tag for r in rows(50))


# --- drawing ---------------------------------------------------------------------

def tmux(sock, *args, timeout=5):
    base = ["tmux"] + (["-L", sock] if sock else [])
    try:
        p = subprocess.run(base + list(args), capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL)
        return p.returncode, p.stdout.rstrip("\n")
    except (OSError, subprocess.SubprocessError):
        return 1, ""


def tgt(s):
    """A session target: an id ($N) as is, a name exactly (=name)."""
    return ("%s:" if s.startswith("$") else "=%s:") % s


def decode(b64):
    """@view_notice → dict, {} when empty or unreadable."""
    try:
        d = json.loads(base64.b64decode(b64 or "", validate=True).decode("utf-8"))
        return d if isinstance(d, dict) else {}
    except (ValueError, TypeError, UnicodeDecodeError):
        return {}


def encode(d):
    return base64.b64encode(json.dumps(d, ensure_ascii=False, separators=(",", ":")).encode("utf-8")).decode()


def live(n, now, acked):
    """Is notice `n` still on the line: its tier not over, or an error not yet
    answered by a key (`acked`: a key came after its hold)."""
    if not n:
        return False
    return now < n.get("until", 0) or (n.get("level") == "error" and not acked)


def targets(sock, client, everyone, view=""):
    """[(client name, its session)] to draw on; `view`: that 看台 session itself,
    whoever is (or is about to be) attached to it."""
    if view:
        return [("", view)]
    # list-clients, never `display -p -c <client>`: its formats are the current
    # pane's, so #{client_session} names whichever client tmux thinks is current
    rc, out = tmux(sock, "list-clients", "-F", "#{client_name}\t#{client_session}\t#{client_control_mode}")
    rows_ = [l.split("\t") for l in out.splitlines() if rc == 0 and l.count("\t") >= 2]
    if client:
        return [(c, s) for c, s, _ in rows_ if c == client][:1]
    if everyone:
        return [(c, s) for c, s, ctl in rows_ if ctl != "1"]
    rc, out = tmux(sock, "display-message", "-p", "#{client_name}\t#{client_session}")
    c, _, s = out.partition("\t")
    return [(c, s)] if rc == 0 and c and s else []


def palette(name):
    """A colour of conf/fleet-palette.conf — the ONE palette (fleet_ui_fail's)."""
    try:
        txt = (BIN.parent / "conf" / "fleet-palette.conf").read_text()
    except OSError:
        return ""
    m = re.search(r"^%%hidden %s='(#[0-9A-Fa-f]+)'" % name, txt, re.M)
    return m.group(1) if m else ""


def plain_line(level, text, nxt):
    """The display-message form for a client that is not a 看台."""
    glyph = {"error": "✗", "warn": "!", "info": "i"}[level]
    col = {"error": palette("PAL_RED"), "warn": palette("PAL_YELLOW"), "info": ""}[level]
    # only what tmux would read as a format is escaped: `#303` stays as it reads
    body = re.sub(r"#([{(\[#])", r"##\1", "%s — %s" % (text, nxt) if nxt else text)
    return "#[%sbold] %s %s " % ("fg=%s," % col if col else "", glyph, body)


def draw(level, text, nxt="", sock="", client="", everyone=False, secs=None, now=None, view=""):
    """Put the notice on the screen(s); the 看台 names drawn on, for the record."""
    now = time.time() if now is None else now
    if not (os.environ.get("TMUX") or sock):
        # no server named and none around us: nothing to draw on
        rc, _ = tmux(sock, "has-session")
        if rc != 0:
            return []
    tier = TIER[level]
    hold = max(tier, int(secs or 0))
    views, done = [], set()
    found = targets(sock, client, everyone, view)
    if not found and not view:
        # no client tmux can name (none attached, or a caller's own tmux stand-in):
        # the old display-message, held for the tier — never the ~0.75 s default
        tmux(sock, "display-message", *(["-c", client] if client else []), "-d", str(hold * 1000),
             plain_line(level, text, nxt))
    for c, s in found:
        if not s or s in done:
            continue
        done.add(s)
        rc, vt = tmux(sock, "show-options", "-qv", "-t", tgt(s), "@view_thin")
        if rc == 0 and vt and "-via-" not in vt:
            rc, old = tmux(sock, "show-options", "-qv", "-t", tgt(s), "@view_notice")
            prev = decode(old)
            _, acts = tmux(sock, "list-clients", "-F", "#{client_name}\t#{client_activity}") if c else (1, "")
            act = next((l.split("\t")[1] for l in acts.splitlines() if l.split("\t")[0] == c), "")
            acked = act.isdigit() and int(act) >= int(prev.get("hold", 0) or 0)
            more = (int(prev.get("more", 0)) + 1) if live(prev, now, acked) else 0
            n = {"seq": int(prev.get("seq", 0)) + 1, "level": level, "text": text, "next": nxt,
                 "ts": int(now), "until": int(now) + hold, "hold": int(now) + hold, "more": more}
            # a 看台 with the message row (@view_inbox, T701) opens it now — the top
            # line's own tick would in ≤ 2 s; the row reads the record, not this
            _, ib = tmux(sock, "show-options", "-qv", "-t", tgt(s), "@view_inbox")
            tmux(sock, "set-option", "-t", tgt(s), "@view_notice", encode(n), ";",
                 "set-option", "-t", tgt(s), "@view_notice_hold", str(n["hold"]),
                 *([";", "set-option", "-t", tgt(s), "status", "2"] if ib == "1" else []),
                 *([";", "refresh-client", "-S", "-t", c] if c else []))
            views.append(s)
        elif c:
            tmux(sock, "display-message", "-c", c, "-d", str(hold * 1000), plain_line(level, text, nxt))
    return views


def notify(level, text, nxt="", client="", sock="", everyone=False, source="", secs=None, tag="",
           draw_it=True, record_it=True, view="", kind="", sub="", ref="", wid=""):
    """The one entry: record (unless `record_it` is off) and draw (unless `draw_it`
    is off) — recorded FIRST, so the message row a draw opens finds it."""
    if level not in LEVELS:
        level = "warn"
    text, nxt = clean(text), clean(nxt, 200)
    if not text:
        return 2
    tag = tag or os.environ.get("FLEET_NOTICE_TAG", "")
    if record_it:
        record(level, text, nxt, source, client, "", tag, kind=kind, sub=clean(sub, 16),
               ref=ref if ID_RE.fullmatch(ref or "") else "", wid=clean(wid, 120))
    if draw_it:
        draw(level, text, nxt, sock, client, everyone, secs, view=view)
    return 0


# --- reading back ------------------------------------------------------------------

_WORDS = {}


def say(key, *args):
    if not _WORDS:
        try:
            out = subprocess.run(["sh", str(BIN / "fleet-ui-lang.sh"), "dump", "notice_"], capture_output=True,
                                 text=True, timeout=5, stdin=subprocess.DEVNULL).stdout
        except (OSError, subprocess.SubprocessError):
            out = ""
        raw = out.split("\0")
        _WORDS.update({k: v.replace("\1", "%s") for k, v in zip(raw[0::2], raw[1::2])})
        _WORDS.setdefault("_", "")
    text = _WORDS.get(key, key)
    try:
        return text % args if args else text
    except (TypeError, ValueError):
        return text


def fmt_row(r, color=False):
    when = time.strftime("%m-%d %H:%M:%S", time.localtime(r["ts"]))
    lvl = r.get("level", "info")
    word = say("notice_level_" + lvl)
    body = r.get("text", "") + ((" — " + r["next"]) if r.get("next") else "")
    src = (" · " + r["source"]) if r.get("source") else ""
    if color:
        c = {"error": "31", "warn": "33", "info": "90"}.get(lvl, "0")
        return "\x1b[90m%s\x1b[0m \x1b[%s;1m%s\x1b[0m %s\x1b[90m%s\x1b[0m" % (when, c, word, body, src)
    return "%s %s %s%s" % (when, word, body, src)


def cmd_list(args):
    n = PAGE_N
    if "--n" in args:
        try:
            n = max(1, int(args[args.index("--n") + 1]))
        except (IndexError, ValueError):
            pass
    got = list(reversed(rows(n)))
    if "--json" in args:
        print(json.dumps(got, ensure_ascii=False))
        return 0
    if not got:
        print(say("notice_none"))
        return 0
    tty = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
    for r in got:
        print(fmt_row(r, tty))
    return 0


def glyph_table():
    """fleet_view's MSG_GLYPHS / MSG_COLORS — the one table — or a plain copy when
    the panel cannot be loaded."""
    try:
        import fleet_view as FV
        return FV.msg_glyphs(), FV.MSG_COLORS, FV.color_on()
    except Exception:   # noqa: BLE001
        g = {"inbox": "*", "ask": "!", "error": "x", "warn": "^", "done": "+", "orphan": "+", "info": "."}
        return g, {k: 0 for k in g}, False


def when(ts, now=None):
    now = time.time() if now is None else now
    lt, ln = time.localtime(ts), time.localtime(now)
    return time.strftime("%H:%M" if lt[:3] == ln[:3] else "%m-%d %H:%M", lt)


def grouped(msgs):
    """The page's lines: [(None, header) | (msg, None)] — the classes in CLASSES
    order, each newest first."""
    out = []
    for c in CLASSES:
        got = [m for m in msgs if m["cls"] == c]
        if got:
            out.append((None, c))
            out += [(m, None) for m in got]
    return out


def orchestrator_fid():
    """The live orchestrator session's identity (a window started from the agent
    file `orchestrator`, @agent_def), '' when none runs."""
    rc, out = tmux("", "list-windows", "-a", "-F", "#{@agent_def}\t#{@fleet_id}")
    for line in out.splitlines() if rc == 0 else []:
        d, _, fid = line.partition("\t")
        if d == "orchestrator" and len(fid) == 36:
            return fid
    return ""


def act(m, key, view="", client=""):
    """One of the page's actions on message `m`: (said, rc) — rc 3 = the 看台 went."""
    if key == "r":
        mark_read(ids=[m["id"]])
        m["seen"] = True
        return say("notice_act_read"), 0
    if key == "g":
        wid = m.get("wid") or ""
        if not wid or not view:
            return say("notice_act_nojump"), 0
        try:
            rc = subprocess.run(["bash", str(BIN / "fleet-view-go.sh"), view, "wid:" + wid, "--how", "notice"]
                                + (["--client", client] if client else []), stdin=subprocess.DEVNULL,
                                capture_output=True, timeout=30).returncode
        except (OSError, subprocess.SubprocessError):
            rc = 1
        return (None, 3) if rc == 0 else (say("notice_act_jumpfail"), 0)
    if key == "f":
        if m["cls"] != "orphan" or not m.get("ref"):
            return say("notice_act_fwd_only"), 0
        if not m.get("here"):
            return say("notice_act_far_fmt", m.get("node") or "?"), 0
        fid = orchestrator_fid()
        if not fid:
            return say("notice_act_fwd_none"), 0
        try:
            ok = subprocess.run([sys.executable, str(BIN / "fleet-orphan-reports.py"), "redeliver", "--to", fid,
                                 "--id", m["ref"], "--since", "0", "--apply"], stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=90).stdout.startswith("redelivered")
        except (OSError, subprocess.SubprocessError):
            ok = False
        if not ok:
            return say("notice_act_fwd_fail"), 0
        mark_read(ids=[m["id"]])
        m["seen"] = True
        return say("notice_act_fwd_fmt", fid[:8]), 0
    return "", 0


def detail(m):
    """The message's whole text, for a person: a result nobody took is its book's
    `show` when it is this machine's."""
    lines = [m.get("text", "")]
    if m.get("next"):
        lines.append("→ " + m["next"])
    if m["cls"] == "orphan" and m.get("here") and m.get("ref"):
        try:
            full = subprocess.run([sys.executable, str(BIN / "fleet-orphan-reports.py"), "show", m["ref"]],
                                  capture_output=True, text=True, timeout=10, stdin=subprocess.DEVNULL).stdout
        except (OSError, subprocess.SubprocessError):
            full = ""
        if full.strip():
            lines = full.rstrip("\n").split("\n")
    meta = [time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(m["ts"]))]
    if m.get("node"):
        meta.append(say("notice_on_fmt", m["node"]))
    if m.get("source"):
        meta.append(m["source"])
    return lines + ["", " · ".join(meta)]


def wrap(text, cols):
    """`text` cut into lines of at most `cols` cells (wide characters 2)."""
    import unicodedata
    out, cur, used = [], "", 0
    for c in text:
        w = 2 if unicodedata.east_asian_width(c) in "WF" else 1
        if used + w > cols:
            out.append(cur)
            cur, used = "", 0
        cur, used = cur + c, used + w
    return out + [cur]


def page(args):
    """「✦ 消息」 in a popup (T701): every message of the week from the one book and
    the other machines', grouped (在问你 · 错误 · 警告 · 没人收的结果 · 做完 · 提示),
    the unseen ones bold; ↑↓ pick, ↵ the whole text, g the message's session, r mark
    read, f hand a result nobody took to the running orchestrator, q / Esc close.
    Opening it is seeing them: the read mark moves (the message row folds). Exit 3:
    the 看台 went to a session."""
    import shutil
    import termios
    import tty as ttym
    view, client = opt(args, "--view"), opt(args, "--client")
    msgs = inbox()[:200]
    n_unseen = len(unseen(msgs))
    mark_read()
    settle(view)
    gl, cols_, colour = glyph_table()
    colour = colour and not os.environ.get("NO_COLOR")
    lines = grouped(msgs)
    picks = [i for i, (m, _) in enumerate(lines) if m is not None]

    def fmt(m, hdr, sel, width):
        if hdr is not None:
            n = sum(1 for x in msgs if x["cls"] == hdr)
            g = gl[hdr]
            t = "%s %s (%d)" % (g, say("notice_cls_" + hdr), n)
            return ("\x1b[1;38;5;%dm%s\x1b[0m" % (cols_[hdr], t)) if colour else t
        node = (" · " + m["node"]) if m.get("node") else ""
        body = "  %s %s %s%s" % (gl[m["cls"]], when(m["ts"]), m.get("text", ""), node)
        body = wrap(body, max(10, width - 1))[0]
        if sel:
            return "\x1b[7m%s\x1b[0m" % body
        return ("\x1b[1m%s\x1b[0m" % body) if not m["seen"] else ("\x1b[90m%s\x1b[0m" % body if colour else body)

    head_t = "%s %s" % (gl["inbox"], say("notice_page_title")) + \
        ("  " + say("notice_unseen_fmt", n_unseen) if n_unseen else "")
    fd = sys.stdin.fileno()
    try:
        saved = termios.tcgetattr(fd)
    except (termios.error, OSError):
        print(head_t)
        for m, hdr in lines:
            print(fmt(m, hdr, False, 200))
        if not lines:
            print(say("notice_none"))
        return 0
    at, top, opened, said, rc = 0, 0, None, "", 0
    try:
        ttym.setraw(fd)
        while True:
            cols, rows_ = shutil.get_terminal_size((80, 24))
            room = max(1, rows_ - 3)
            keys = say("notice_detail_keys" if opened is not None else "notice_page_keys")
            out = ["\x1b[2J\x1b[H\x1b[1m%s\x1b[0m" % head_t, "\x1b[90m%s\x1b[0m" % wrap(keys, cols - 1)[0]]
            if opened is not None:
                body = []
                for ln in detail(opened):
                    body += wrap(ln, max(10, cols - 1))
                out += body[top:top + room]
            elif not picks:
                out.append(say("notice_none"))
            else:
                sel = picks[at]
                if sel < top:
                    top = sel - (1 if sel and lines[sel - 1][1] is not None else 0)
                if sel >= top + room:
                    top = sel - room + 1
                out += [fmt(m, hdr, i == sel, cols) for i, (m, hdr) in enumerate(lines)][top:top + room]
            if said:
                out.append("\x1b[33m%s\x1b[0m" % wrap(said, cols - 1)[0])
            sys.stdout.write("\r\n".join(out) + "\x1b[?25l")
            sys.stdout.flush()
            ch = os.read(fd, 8)
            said = ""
            cur = lines[picks[at]][0] if picks else None
            if opened is not None:
                if ch in (b"\r", b"\n", b"\x1b", b"\x7f"):
                    opened, top = None, 0
                elif ch in (b"\x1b[A", b"k"):
                    top = max(0, top - 1)
                elif ch in (b"\x1b[B", b"j"):
                    top += 1
                elif ch in (b"g", b"r", b"f"):
                    said, rc = act(opened, ch.decode(), view, client)
                    if rc == 3:
                        break
                elif ch in (b"q", b"\x03"):
                    break
                continue
            if ch in (b"\x1b[A", b"k"):
                at = max(0, at - 1)
            elif ch in (b"\x1b[B", b"j"):
                at = min(len(picks) - 1, at + 1) if picks else 0
            elif ch in (b"\x1b[5~", b"\x02"):
                at = max(0, at - room)
            elif ch in (b"\x1b[6~", b" ", b"\x06"):
                at = min(len(picks) - 1, at + room) if picks else 0
            elif ch in (b"\r", b"\n") and cur is not None:
                opened, top = cur, 0
            elif ch in (b"g", b"r", b"f") and cur is not None:
                said, rc = act(cur, ch.decode(), view, client)
                if rc == 3:
                    break
            elif ch in (b"q", b"\x1b", b"\x03"):
                break
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        sys.stdout.write("\x1b[?25h")
        sys.stdout.flush()
    return rc


def settle(view):
    """The 看台's message row folded at once when nothing live is left (its top
    line's tick would in ≤ 2 s)."""
    if not view or line_state()[0] is not None:
        return
    s = view if view.startswith("$") or "@view-" in view else ""
    if not s:
        rc, out = tmux("", "list-sessions", "-F", "#{session_name}\t#{@view_thin}")
        s = next((l.split("\t")[0] for l in out.splitlines() if rc == 0 and l.endswith("\t" + view)), "")
    if s:
        _, ib = tmux("", "show-options", "-qv", "-t", tgt(s), "@view_inbox")
        if ib == "1":
            tmux("", "set-option", "-t", tgt(s), "status", "on")


def opt(args, name, default=""):
    if name in args:
        i = args.index(name)
        if i + 1 < len(args):
            return args[i + 1]
    return default


def main(argv):
    if not argv:
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        return 2
    cmd, args = argv[0], argv[1:]
    if cmd == "notify":
        pos = [a for i, a in enumerate(args) if not a.startswith("--") and
               (i == 0 or args[i - 1] not in ("--next", "--client", "--sock", "--source", "--secs", "--tag", "--view",
                                              "--kind", "--sub", "--ref", "--wid"))]
        if len(pos) < 2:
            print("usage: fleet_notice.py notify <error|warn|info> <text> [--next …] [--client …]", file=sys.stderr)
            return 2
        secs = opt(args, "--secs")
        return notify(pos[0], pos[1], opt(args, "--next"), opt(args, "--client"), opt(args, "--sock"),
                      "--all" in args, opt(args, "--source"), int(secs) if secs.isdigit() else None,
                      opt(args, "--tag"), "--no-draw" not in args, "--no-record" not in args, opt(args, "--view"),
                      opt(args, "--kind"), opt(args, "--sub"), opt(args, "--ref"), opt(args, "--wid"))
    if cmd == "list":
        return cmd_list(args)
    if cmd == "page":
        return page(args)
    if cmd == "unread":
        print(unread())
        return 0
    if cmd == "read":
        mark_read(ids=args or None)
        return 0
    if cmd == "cell":
        print(cell())
        return 0
    if cmd == "seen":
        return 0 if args and seen(args[0]) else 1
    print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
