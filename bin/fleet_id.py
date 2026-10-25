#!/usr/bin/env python3
"""fleet_id.py — the node's ID ledger: one window, one ID, its native segments
(EPIC T497 C1; design page §3, §4.1, §4.2).

A window's ID is its @fleet_id (a UUIDv4, minted once at spawn — fleet_fid_mint).
What a person reads is its SHORT CODE (EPIC T497 C11): the first characters of the
ID's display code — uppercase Crockford base32 (no I L O U) whose FIRST character is
always a letter, so a code is never a number an issue or PR could be — 4 by default,
one longer for as long as another ID this login knows shares the prefix (like git's
short SHA). It is recomputed from the 128-bit ID, never stored as the truth. Panels
print it bare (`K3F9`), a message `#K3F9`. An address (`K3F9`, `#k3f9`, any case;
I/L read 1, O read 0) resolves to every known ID whose code starts with it: one ⇒
that ID, several ⇒ refused with the candidates (rc 2), never a pick. The old code
`T-` + 5 lowercase (`T-hfkc7`, the ID's plain base32) still resolves for one version
(compat-1v), and a ledger's stored `T-…` short is read as nothing.

That 4-place code is the one WRITTEN down (details, copies, logs, reports). What a
panel, ⌘P, the top bar and a notification title SHOW is shorter (EPIC T644 C4):
display_short — at least 2, one longer for as long as another UNFINISHED ID shares
the prefix (`K5`, `K5H` beside another open K5…). The unfinished set is the panel's
(ids/.open, open_save); a typed prefix of 2+ is looked up there first, then in the
whole history (resolve_open).

The ledger is $FLEET_CONF_DIR/ids/<ID>.ndjson, one event a line, each with its
(ID, seq): `opened` (the spawn: agent, window, repo, title …), `native` (a native
session the window went through — a new segment, or `compact: true` counting one
compaction on the current segment), `result`, `progress` (the window's newest
progress word — an EPIC driver's tick, never a result: EPIC T497 C12), `closed`. Appends hold an flock;
seq is the line's number. The ledger is double-written beside the old task record
and nothing decides anything off it yet (EPIC rule: 先双写、后切换).

The SessionStart hook (`fleet-id.sh hook`, both agents — the Codex table is the
same one) appends segments by the rules of §4.2:
  claude startup   no segment ⇒ segment 1 (startup); same native id ⇒ nothing;
                   another ⇒ a new segment (resume: a restore that changed the id)
  claude resume    another id ⇒ a new segment (resume), with the ID/segment it came from
  claude clear     a new segment: handoff when the cycle marked it, else clear
  claude compact   the current segment counts one more compaction
  codex  (its runtime witnesses each thread/started — the table's sid_source — and its
         first-turn hook finds the same id) another id ⇒ a new segment; an agent whose
         start never says /clear (clear_said 0) ⇒ new, resume ⇒ resume
  any    the agent differs from the last segment's ⇒ transfer
  any    the window's @id_next_trigger says `reopen` (the recovery page's ↵, a restore —
         EPIC T644 C2) ⇒ a new segment (reopen), even on the same native id
  any    the ID's attempt moved past the last segment's (a task's redo) ⇒ redo

A task's sessions all go by the task's ID (EPIC T644 C2): the first window a
task opens takes the hub's fid for it (`take`), and a redo of that task here is
the same ID's next ATTEMPT — a `reopened` event carrying `attempt` n (the hub
clears its close off the same event); every segment records the attempt it ran
in (1 when nothing says otherwise). A fid two live windows carry is a conflict in
both (`conflicts`), as two windows on one native segment are.
The hook never blocks the agent and never prints: a write that fails is kept on
the window (@id_retry) and flushed by the next hook.
"""
import fcntl
import json
import os
import re
import runpy
import subprocess
import sys
import time
import uuid
import unicodedata

ALPHABET = "0123456789abcdefghjkmnpqrstvwxyz"   # Crockford base32, lowercase — the old code (compat-1v)
DIGITS = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"     # the display code: Crockford base32, uppercase
LETTERS = "ABCDEFGHJKMNPQRSTVWXYZ"              # its first character: a letter, never a digit
SHORT_MIN = 4
DISPLAY_MIN = 2   # the code a panel shows (EPIC T644 C4): unique among the unfinished only
ADDR_MIN = 4
LEGACY_MIN = 4   # an old `T-` address's least length (compat-1v)
CODE_SPAN = 22 * 32 ** 25   # 26 places: one letter, 25 base32 — more than 2^128, so no two IDs share a full code
FID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
TRIGGERS = ("startup", "clear", "handoff", "transfer", "resume", "new", "migrated", "reopen", "redo")
NEXT_TRIGGER_TTL = 600   # @id_next_trigger older than this is stale


def conf_dir():
    return os.environ.get("FLEET_CONF_DIR") or os.path.join(os.path.expanduser("~"), ".config", "claude-fleet")


def ids_dir():
    return os.environ.get("FLEET_ID_DIR") or os.path.join(conf_dir(), "ids")


def is_fid(s):
    return isinstance(s, str) and bool(FID_RE.match(s))


def encode(fid):
    """The ID's full display code: 26 places, most significant first — the 128 bits
    scaled onto one letter place (22) and 25 base32 places, so the order and the
    prefixes are the ID's own and the first character is always a letter."""
    v = (int(fid.replace("-", ""), 16) * CODE_SPAN) >> 128
    out = []
    for _ in range(25):
        v, d = divmod(v, 32)
        out.append(DIGITS[d])
    out.append(LETTERS[v])
    return "".join(reversed(out))


def legacy_encode(fid):
    """The OLD full code (`T-` addresses, compat-1v: 下一批删): 128 bits → 26
    lowercase base32 characters, most significant first."""
    n = int(fid.replace("-", ""), 16) << 2   # 130 bits = 26 × 5
    return "".join(ALPHABET[(n >> (5 * (25 - i))) & 31] for i in range(26))


def parse_code(s, least=ADDR_MIN):
    """A typed code → (canonical code, legacy?) or None. `K3F9` / `#k3f9` / any case,
    Crockford's reading of I/L (1) and O (0), U no digit, the first character a letter;
    `T-…` / `t-…` is the old lowercase code (compat-1v: 下一批删). `least` is the
    shortest a new code may be typed: ADDR_MIN, DISPLAY_MIN where only the
    unfinished are searched (resolve_open, ⌘P)."""
    s = (s or "").strip()
    if s[:2] in ("T-", "t-"):
        s = s[2:].lower().replace("i", "1").replace("l", "1").replace("o", "0")
        if len(s) < LEGACY_MIN or len(s) > 26 or any(c not in ALPHABET for c in s):
            return None
        return s, True
    if s[:1] == "#":
        s = s[1:]
    s = s.upper().replace("I", "1").replace("L", "1").replace("O", "0")
    if len(s) < least or len(s) > 26 or s[0] not in LETTERS or any(c not in DIGITS for c in s):
        return None
    return s, False


def norm_code(s):
    """A typed NEW code → its canonical uppercase form, or None (an old `T-` code is None)."""
    p = parse_code(s)
    return p[0] if p and not p[1] else None


def is_short(s):
    """A stored short in today's form (`K3F9`), not an old `T-…` one."""
    return isinstance(s, str) and norm_code(s) == s


def short_for(fid, known):
    """The shortest code (≥ SHORT_MIN) no other known ID shares: `K3F9`."""
    me = encode(fid)
    others = [encode(k) for k in known if is_fid(k) and k != fid]
    n = SHORT_MIN
    while n < 26 and any(o[:n] == me[:n] for o in others):
        n += 1
    return me[:n]


def display_short(fid, open_ids):
    """The code a panel, ⌘P, the top bar and a notification title SHOW (EPIC T644 C4,
    convention 2): the shortest prefix (≥ DISPLAY_MIN) no other UNFINISHED ID
    shares — `K5`, `K5H` while another open one starts K5, `K5` again once it ends.
    Never written down: details, copies, logs and messages write short_for's."""
    me = encode(fid)
    others = [encode(k) for k in open_ids if is_fid(k) and k != fid]
    n = DISPLAY_MIN
    while n < 26 and any(o[:n] == me[:n] for o in others):
        n += 1
    return me[:n]


def open_path():
    """The unfinished IDs the panel last showed (C4): one ID a line — written by
    fleet_view's frame (open_save), read by the top bar and the notifications so
    every place shows the same length."""
    return os.path.join(ids_dir(), ".open")


def open_ids():
    try:
        with open(open_path(), encoding="utf-8") as fh:
            return {line.strip() for line in fh if is_fid(line.strip())}
    except OSError:
        return set()


def open_save(ids):
    """Write the unfinished set when it changed (one rename); never raises."""
    ids = {x for x in ids if is_fid(x)}
    if ids == open_ids() and os.path.exists(open_path()):
        return
    try:
        os.makedirs(ids_dir(), exist_ok=True)
        tmp = "%s.%d" % (open_path(), os.getpid())
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write("".join(x + "\n" for x in sorted(ids)))
        os.replace(tmp, open_path())
    except OSError:
        pass


def shown(fid, open_set=None):
    """display_short over the unfinished book (open_ids), the ID itself counted."""
    return display_short(fid, open_ids() if open_set is None else open_set) if is_fid(fid) else ""


def hub_short(fid, s):
    """A short the hub answered: today's form as is; an old hub's `T-…` (compat-1v) or
    none ⇒ recomputed here."""
    return s if is_short(s) else short_for(fid, known_ids([fid]))


def task_codes_path():
    """The book of task codes (EPIC T644 C3): `T<n>\t<code>\t<ID>` per task this
    login heard a code for — fleet-task-record.sh writes it off every hub answer."""
    return os.path.join(ids_dir(), "task-codes.tsv")


def task_code(ref):
    """A task's written code off the book (`T649` or its code → `K5H0`), or ""."""
    want = (ref or "").strip().lstrip("#")
    up = want.upper()
    try:
        with open(task_codes_path()) as f:
            for line in f:
                row = line.rstrip("\n").split("\t")
                if len(row) >= 2 and (row[0] == want or row[1] == up):
                    return row[1]
    except OSError:
        pass
    return ""


def tag(short):
    """A short code as a message writes it: `#K3F9` (bare in a panel's column)."""
    return "#" + short if short else ""


def ledger_path(fid):
    return os.path.join(ids_dir(), fid + ".ndjson")


def ledger_ids():
    try:
        names = os.listdir(ids_dir())
    except OSError:
        return []
    return [n[:-7] for n in names if n.endswith(".ndjson") and is_fid(n[:-7])]


def known_ids(extra=()):
    """Every ID this login knows: the ledger, the hub's list (ids/.known, one ID a
    line — the mirror fills it), and whatever the caller adds (live windows)."""
    out = set(ledger_ids())
    out.update(cache_ids())
    try:
        with open(os.path.join(ids_dir(), ".known"), encoding="utf-8") as fh:
            out.update(line.strip() for line in fh if is_fid(line.strip()))
    except OSError:
        pass
    out.update(x for x in extra if is_fid(x))
    return out


def read(fid):
    try:
        with open(ledger_path(fid), encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return []
    out = []
    for line in lines:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if isinstance(ev, dict):
            out.append(ev)
    return out


def append(fid, ev, decide=None):
    """Append one event under the ledger's lock. With `decide(events) → event|None`
    the event is computed from what is already there, inside the lock (two hooks
    racing on one window cannot both open a segment). Returns the written event."""
    os.makedirs(ids_dir(), exist_ok=True)
    fd = os.open(ledger_path(fid), os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        with os.fdopen(os.dup(fd), "r", encoding="utf-8") as fh:
            fh.seek(0)
            events = []
            for line in fh.read().splitlines():
                try:
                    events.append(json.loads(line))
                except ValueError:
                    events.append({})
        if decide is not None:
            ev = decide([e for e in events if isinstance(e, dict)])
            if ev is None:
                return None
        ev = dict(ev)
        ev["id"] = fid
        ev["seq"] = len(events) + 1
        ev.setdefault("ts", int(time.time()))
        os.write(fd, (json.dumps(ev, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8"))
        os.fsync(fd)
        return ev
    finally:
        os.close(fd)


def fold(events):
    """The ledger read as one record: opened fields (first value wins), segments,
    results, closed."""
    rec = {"opened": {}, "segments": [], "results": [], "closed": None, "progress": None, "attempt": 1}
    lazy = None
    for ev in events:
        kind = ev.get("ev")
        if kind == "opened":
            # `lazy`: written by the hook for a window no spawn recorded — true only
            # while no spawn's own `opened` has come.
            lazy = bool(ev.get("lazy")) if lazy is None else (lazy and bool(ev.get("lazy")))
            for k, v in ev.items():
                if k in ("ev", "seq", "id", "lazy"):
                    continue
                if k == "title":
                    v = clean_title(v)
                if k == "short" and not is_short(v):
                    continue   # an old `T-…` code (compat-1v): today's is recomputed from the ID
                if v not in (None, "") and k not in rec["opened"]:
                    rec["opened"][k] = v
        elif kind == "named":
            title, source = clean_title(ev.get("title")), ev.get("source")
            o = rec["opened"]
            if title and source in ("auto", "manual", "recovered"):
                if source == "manual" or (o.get("title_source") != "manual" and
                                         (source != "recovered" or not o.get("title"))):
                    o["title"], o["title_source"] = title, source
        elif kind == "native":
            if ev.get("compact"):
                if rec["segments"]:
                    rec["segments"][-1]["compactions"] += 1
                continue
            seg = {"n": len(rec["segments"]) + 1, "agent": ev.get("agent", ""), "native": ev.get("native", ""),
                   "trigger": ev.get("trigger", ""), "start": ev.get("ts"), "end": None, "compactions": 0,
                   "attempt": rec["attempt"]}
            for k in ("from", "conflict"):
                if ev.get(k):
                    seg[k] = ev[k]
            if rec["segments"]:
                rec["segments"][-1]["end"] = ev.get("ts")
            rec["segments"].append(seg)
        elif kind == "result":
            r = {k: v for k, v in ev.items() if k not in ("ev", "id")}
            r.setdefault("attempt", rec["attempt"])   # which attempt said it (C2)
            rec["results"].append(r)
        elif kind == "progress":
            rec["progress"] = {k: v for k, v in ev.items() if k not in ("ev", "id")}
        elif kind == "short":
            # the hub's code for this ID (EPIC T497 C2): only ever longer
            have = rec["opened"].get("short", "")
            if is_short(ev.get("short")) and len(ev["short"]) > len(have):
                rec["opened"]["short"] = ev["short"]
        elif kind == "closed":
            if rec["closed"] is None:
                rec["closed"] = {"ts": ev.get("ts"), "reason": ev.get("reason", "")}
            if rec["segments"] and rec["segments"][-1]["end"] is None:
                rec["segments"][-1]["end"] = ev.get("ts")
        elif kind == "reopened":
            # 「恢复这个窗口」(EPIC T497 C4): the same ID goes on in a new window
            rec["closed"] = None
            if ev.get("window"):
                rec["opened"]["window"] = ev["window"]
            # a task's redo (EPIC T644 C2): the same ID, its next attempt
            if isinstance(ev.get("attempt"), int) and ev["attempt"] > rec["attempt"]:
                rec["attempt"] = ev["attempt"]
    if lazy:
        rec["opened"]["lazy"] = True
    return rec


def record_progress(fid, summary, state="", event="", newest=False):
    """One progress word on an ID (EPIC T497 C12) — what an EPIC driver's tick wrote
    on its task record before the switch. A repeated --event writes nothing (a
    retried tick) — with `newest`, only while it is still the newest word (a start
    word said again after the agent came up in between is said again); → the
    written event, or None."""
    def decide(evs):
        if event:
            words = [e for e in evs if e.get("ev") == "progress"]
            if newest:
                words = words[-1:]
            if any(e.get("event") == event for e in words):
                return None
        ev = {"ev": "progress", "state": state, "summary": summary[:2000]}
        if event:
            ev["event"] = event
        return ev
    return append(fid, None, decide=decide)


# ---- did its agent come up? (T642) ------------------------------------------------
#
# A session that never started — a launch refused before the agent ran, an agent
# that died in its first seconds — used to leave its record `accepted` for ever:
# a driver read it as running. The wrapper (fleet-session-wrap.sh) now says so on
# the window's ID — a progress word in START_WORDS, through `start-word` below —
# and the agent's first SessionStart (hook) answers `started` over it. start_word
# is the ONE reader the EPIC tick, `await` and the children lists judge a running
# member by: the word, this machine's window (an ID in NOAGENT — its window holds
# no agent: the wrapper gone, the pane dead, the recovery page), the hub's live
# word, and — no native segment past FLEET_START_GRACE (300 s) — never came up.

START_WORDS = ("not_started", "dropped")
NOAGENT = set()   # IDs whose live window here holds no agent (FLEET_ID_NOAGENT, fleet-id.sh)


def start_grace():
    try:
        return max(0, int(os.environ.get("FLEET_START_GRACE", "300")))
    except ValueError:
        return 300


def _epoch(v):
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str) and v:
        try:
            import fleet_iso
            return fleet_iso.parse(v, utc=True).timestamp()
        except (ImportError, ValueError):
            return None
    return None


def start_word(view=None, row=None, now=None, grace=None):
    """Is a member the records call running really up? → {} (nothing says otherwise)
    or {word: not_started | dropped, why}. `view` is the hub's record read
    (`fleet-task-record.sh get`: task · started · progress · live), `row` an ID's
    row (status / family: agent · segments · progress · opened_at · src)."""
    view, row = view or {}, row or {}
    now = time.time() if now is None else now
    grace = start_grace() if grace is None else grace
    pg = row.get("progress") or view.get("progress") or {}
    if isinstance(pg, dict) and (pg.get("state") or pg.get("status")) in START_WORDS:
        return {"word": pg.get("state") or pg.get("status"), "why": str(pg.get("summary") or "")}
    segs = row.get("segments") or (view.get("started") or {}).get("segments") or 0
    if row.get("agent") is False:
        return {"word": "dropped" if segs else "not_started",
                "why": "窗口还在，里面没有 agent（只剩 shell，或停在恢复页）"}
    t0 = _epoch((view.get("task") or {}).get("created_at")) or _epoch(row.get("opened_at"))
    if (row.get("src") == "local" and row.get("alive") is False and row.get("closed") is None
            and t0 is not None and now - t0 >= grace):
        # its ID is this machine's, open, and no window here carries it any more
        return {"word": "dropped" if segs else "not_started", "why": "窗口已经不在了，ID 没有结果也没收尾"}
    live = view.get("live") or {}
    if live.get("state") == "exited" and not live.get("stale"):
        return {"word": "dropped", "why": "agent 已退出，窗口停在恢复页"}
    # never came up: only a reader that would know — the hub's read (its `started`)
    # or this machine's own ledger (its segments); a hub-mirror row has none
    if not segs and (view.get("task") or row.get("src") == "local"):
        if t0 is not None and now - t0 >= grace:
            return {"word": "not_started", "why": "开了 %d 分钟，agent 还没起来（没有一段原生会话）" % int((now - t0) // 60)}
    return {}


def task_row(task, live, idx=None):
    """This machine's newest ID opened for the record `task` (its ledger's `task`),
    the newest down `prev` when several were — its status row; {} when none here."""
    idx = idx if idx is not None else _index()
    mine = {f: o for f, o in idx.items() if o["opened"].get("task") == task}
    if not mine:
        return {}
    prevs = {o["opened"].get("prev") for o in mine.values()}
    tips = [f for f in mine if f not in prevs] or list(mine)
    fid = max(tips, key=lambda f: (mine[f]["opened"].get("ts") or 0, f))
    return dict(status(fid, live, idx), src="local", opened_at=mine[fid]["opened"].get("ts"))


def start_hint(word, task="", fid="", short=""):
    """What a driver does about it: the same record, never a new T<n>."""
    code = short or fid
    if word == "dropped" and code:
        return ("窗口还在就到那里按 ↵ 续上；窗口没了：fleet-id.sh reopen %s --exec（同一个 ID、同一条记录）" % code)
    if task:
        return ("用原记录重起：fleet-task-record.sh respawn %s%s（同一条记录，不新开 T）" %
                (task, (" --prev %s" % fid) if fid else ""))
    return "到它的窗口看它为什么没起来"


def say_start(fid, word, why):
    """The wrapper's word (T642): written on the ID unless it is already the newest
    one for that cause, or the ID is over (closed, or a result that ends it).
    → True when written."""
    if word not in START_WORDS or not os.path.exists(ledger_path(fid)):
        return False
    rec = fold(read(fid))
    r = last_result(rec)
    if rec["closed"] is not None or (r and r.get("state") in DONE_STATES + FAIL_STATES):
        return False
    label = "未起来" if word == "not_started" else "已掉"
    why = " ".join((why or "").split())[:300]
    ev = record_progress(fid, "%s：%s" % (label, why or "-"), word,
                         # one cause, however many seconds it took this time
                         "%s:%d:%s" % (word, len(rec["segments"]), re.sub(r"[0-9]+", "#", why)[:80]), newest=True)
    if ev:
        push_later(fid)
    return bool(ev)


def progress_of(fid):
    """An ID's newest progress word {summary, state, ts, seq, src}: this machine's
    ledger, else the hub mirror's record; None when neither has one."""
    if os.path.exists(ledger_path(fid)):
        p = fold(read(fid))["progress"]
        if p:
            return dict(p, src="local")
    one = _hub_record(fid)
    if one and one.get("progress"):
        return dict(one["progress"], src="hub")
    return None


def owner_of(native, skip=""):
    """Which ID's which segment a native session id belongs to (the newest one), or None."""
    best = None
    for fid in ledger_ids():
        if fid == skip:
            continue
        rec = fold(read(fid))
        for seg in rec["segments"]:
            if seg["native"] == native and (best is None or (seg["start"] or 0) > best[2]):
                best = (fid, seg["n"], seg["start"] or 0, rec)
    return best


def _says_clear(agent):
    """Does this agent's session start say it came from /clear? (the adapter table's
    clear_said, T629 C5) — an unknown agent reads as it always did: yes."""
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import fleet_agent_adapter
        return fleet_agent_adapter.get(agent, "clear_said") != "0"
    except (ImportError, KeyError):
        return True


def next_native(events, agent, native, source, hint):
    """§4.2's rule: the native event this SessionStart adds, or None."""
    rec = fold(events)
    segs = rec["segments"]
    last = segs[-1] if segs else None
    redo = bool(last) and rec["attempt"] > last.get("attempt", 1)
    if source == "compact":
        if last and last["native"] == native:
            return {"ev": "native", "compact": True, "agent": agent, "native": native, "seg": last["n"]}
        trigger = "resume" if last else "startup"
    elif redo:
        trigger = "redo"      # a task's next attempt (EPIC T644 C2): its first segment
    elif hint == "reopen":
        trigger = "reopen"    # the recovery page's ↵ / a restore (C2): a new segment, the same ID
    elif last and last["native"] == native and last["agent"] == agent:
        return None   # the same segment going on: a retried hook, a mod reload
    elif last and last["agent"] != agent:
        trigger = "transfer"
    elif source == "clear":
        trigger = "handoff" if hint == "handoff" else "clear"
    elif not last:
        trigger = "resume" if source == "resume" else "startup"
    elif source == "resume":
        trigger = "resume"
    elif not _says_clear(agent):
        trigger = "new"     # a new conversation in the same window that never says /clear (Codex's /new)
    else:
        trigger = "resume"  # a restart that came back on another id
    ev = {"ev": "native", "agent": agent, "native": native, "trigger": trigger, "source": source or "",
          "seg": len(segs) + 1, "attempt": rec["attempt"]}
    if trigger == "resume":
        own = owner_of(native, skip=events[0].get("id", "") if events else "")
        if own:
            ev["from"] = "%s#%d" % (own[0], own[1])
            other = own[3]
            if other["closed"] is None and other["segments"] and other["segments"][-1]["native"] == native:
                ev["conflict"] = own[0]
    return ev


def record_native(fid, agent, native, source, hint=""):
    return append(fid, None, decide=lambda evs: next_native(evs, agent, native, source, hint))


def title_audit(board_path, proof_path, directories):
    """Read-only review manifest. Inputs must be the same person's ticket reads.

    Original ledgers are matched by full FID only. No native transcript, window
    number, task body, deleted-row heuristic, or write/apply mode is used here.
    """
    import hashlib
    from pathlib import Path
    board_bytes, proof_bytes = Path(board_path).read_bytes(), Path(proof_path).read_bytes()
    snapshot, proof = json.loads(board_bytes), json.loads(proof_bytes)
    if not proof.get("read_only") or not proof.get("person"):
        raise ValueError("needs the same owner's read-only /me receipt")
    rows = snapshot.get("board", {}).get("rows", [])
    result = []
    for row in rows:
        fid = row.get("id", "")
        if row.get("group") != "gone" or clean_title(row.get("title")) or not is_fid(fid):
            continue
        item = {"id": fid, "code": row.get("code"), "machine": row.get("machine"),
                "login": row.get("login"), "task": row.get("task", ""),
                "candidate": "", "decision": "short-code-only", "source": "unavailable",
                "fallback": "会话 " + (row.get("code") or short_for(fid, [fid]))}
        files = [Path(d) / (fid + ".ndjson") for d in directories if (Path(d) / (fid + ".ndjson")).is_file()]
        if len(files) > 1:
            item["source"] = "multiple-ledgers-review"
        elif files:
            raw = files[0].read_bytes()
            item.update(ledger=str(files[0]), sha256=hashlib.sha256(raw).hexdigest())
            try:
                evs = [json.loads(line) for line in raw.splitlines() if line.strip()]
                if not all(isinstance(e, dict) and e.get("id") == fid and e.get("seq") == n
                           for n, e in enumerate(evs, 1)):
                    raise ValueError("identity or sequence mismatch")
                rec = fold(evs)
                opened = [e for e in evs if e.get("ev") == "opened"]
                item["source"] = ("hook-lazy-open" if opened[0].get("lazy") else "spawn-open-entry-unknown") if opened else "no-opened-event"
                item["events"] = [e.get("ev") for e in evs]
                item["closed"] = rec["closed"]
                item["seq"] = len(evs)
                item["facts"] = {k: rec["opened"][k] for k in ("agent", "task", "parent", "prev", "key", "origin", "reap_origin", "test_identity") if k in rec["opened"]}
                title = clean_title(rec["opened"].get("title"))
                if title:
                    item.update(candidate=title, decision="review-ledger-resync", title_source=rec["opened"].get("title_source", "opened"))
                # A lack of title never proves a web entrance or a test/probe.
            except (ValueError, TypeError, KeyError):
                item["source"] = "invalid-ledger-review"
        result.append(item)
    return {"mode": "dry-run", "writes": 0, "board_sha256": hashlib.sha256(board_bytes).hexdigest(),
            "owner_proof_sha256": hashlib.sha256(proof_bytes).hexdigest(), "rows": result,
            "counts": {source: sum(r["source"] == source for r in result) for source in sorted({r["source"] for r in result})}}


def clean_title(value):
    """One bounded display line; never derive a title from a prompt/body."""
    if not isinstance(value, str):
        return ""
    line = ""
    for raw in re.split(r"[\r\n]", value):
        line = " ".join("".join(" " if unicodedata.category(c) == "Cc" else c for c in raw).split())
        if line:
            break
    return line if len(line) <= 80 else line[:79].rstrip() + "…"


def record_title(fid, title, source, update=None, only_default=False):
    """A real naming event, serialized with every other event on this identity.

    Manual wins over automatic forever; recovered only fills an empty title.
    update runs under the same lock so concurrent window renames cannot invert
    the ledger order. Repeated names still repair the window without an event.
    """
    title = clean_title(title)
    if not is_fid(fid) or not title or source not in ("auto", "manual", "recovered"):
        return None
    def decide(evs):
        o = fold(evs)["opened"]
        if only_default and o.get("title_source") != "default":
            return None
        if source != "manual" and (o.get("title_source") == "manual" or
                                   (source == "recovered" and o.get("title"))):
            return None
        if update is not None:
            update(title)
        if o.get("title") == title and o.get("title_source") == source:
            return None
        return {"ev": "named", "title": title, "source": source}
    return append(fid, None, decide=decide)


def name_window(window, title, source="manual", socket="", fid="", binary="tmux", rename=True):
    """The web, Terminal, control adapter and prompt hook's one rename road."""
    title = clean_title(title)
    if not title:
        raise ValueError("empty title")
    prefix = [binary] + (["-L", socket] if socket else [])
    def run(*args):
        return subprocess.run(prefix + list(args), text=True, capture_output=True,
                              timeout=10, check=True).stdout.strip()
    def check_target():
        fmt = "#{window_id}" if window.startswith("@") else "#{pane_id}"
        if not window.startswith(("@", "%")) or run("display-message", "-p", "-t", window, fmt) != window:
            raise ValueError("window or pane no longer exists")
    check_target()
    found = run("display-message", "-p", "-t", window, "#{@fleet_id}")
    if fid and found != fid:
        raise ValueError("window identity changed")
    def update(value):
        check_target()
        if found and run("display-message", "-p", "-t", window, "#{@fleet_id}") != found:
            raise ValueError("window identity changed")
        # Old windows may have a manual stamp but no named event yet.
        manual = run("show-options", "-wqv", "-t", window, "@name_manual")
        if source != "manual" and manual:
            raise ValueError("manual title already set")
        if not rename:
            return
        args = ["rename-window", "-t", window, "--", value, ";",
                "set-option", "-w", "-t", window, "automatic-rename", "off"]
        if source == "manual":
            args += [";", "set-option", "-w", "-t", window, "@name_manual", value]
        run(*args)
    if is_fid(found):
        if not os.path.exists(ledger_path(found)):
            open_id(found, {"window": window, "lazy": True})
        ev = record_title(found, title, source, update)
        if source != "manual" and fold(read(found))["opened"].get("title_source") == "manual":
            raise ValueError("manual title already set")
        push_later(found)
        return ev
    # Older unstamped windows retain their rename behavior; never mint an ID.
    update(title)
    return None


def open_id(fid, fields, extra_known=()):
    """The spawn's `opened` (idempotent: a second one only fills what the first left)."""
    short = short_for(fid, known_ids(extra_known))
    fields = dict(fields)
    # compat-1v: 下一批删 — old callers may still pass Fleet task ancestry.
    # Keep historical events readable; never copy their relationship to an ID.
    for key in ("parent", "origin", "origin_fid", "origin_wid", "origin_gen", "origin_retired"):
        fields.pop(key, None)
    explicit_title = clean_title(fields.get("title"))
    fields["title"] = explicit_title or "会话 " + short
    fields.setdefault("title_source", "initial" if explicit_title else "default")
    def decide(evs):
        have = fold(evs)["opened"]
        ev = {"ev": "opened"}
        for k, v in fields.items():
            if v not in (None, "") and k not in have:
                ev[k] = v
        if not have.get("short"):
            ev["short"] = short
        if len(ev) == 1 and evs:
            return None
        return ev
    append(fid, None, decide=decide)
    if explicit_title:
        # A hook may have won the opening race with a default. Promote through
        # the real naming protocol; never alter opened or overwrite a newer name.
        record_title(fid, explicit_title, "auto", only_default=True)
    return fold(read(fid))["opened"].get("short") or short


def resolve(addr, extra_known=()):
    """An address → (rc, [IDs]): 0 one, 1 none / not an address, 2 ambiguous."""
    a = (addr or "").strip()
    if is_fid(a):
        return 0, [a]
    p = parse_code(a)
    if p is None:
        return 1, []
    code, legacy = p
    enc = legacy_encode if legacy else encode
    hits = sorted(f for f in known_ids(extra_known) if enc(f).startswith(code))
    if not hits:
        return 1, []
    return (0 if len(hits) == 1 else 2), hits


def resolve_open(addr, open_set, extra_known=()):
    """Convention 4 (EPIC T644): a typed prefix (≥ DISPLAY_MIN) is looked up among the
    unfinished first — one ⇒ it, several ⇒ rc 2 with them, never a pick; none there
    ⇒ the whole history (resolve: ≥ ADDR_MIN), same rule. (rc, [IDs])."""
    p = parse_code(addr, DISPLAY_MIN)
    if p is not None and not p[1]:
        hits = sorted(f for f in open_set if is_fid(f) and encode(f).startswith(p[0]))
        if hits:
            return (0 if len(hits) == 1 else 2), hits
    return resolve(addr, extra_known)


# ---- results, parents, successors (EPIC T497 C4; design page §4.3–§4.5) ----------
#
# What a window is doing is read off its ID, never off a task record's generation
# or a native process: a result is an event on the ledger (several are fine — the
# newest counts, S2), a window the fleet closed without one has 已退出 (S7), and a
# native segment live in two windows at once is a conflict in both until one of
# them closes (S9). A message for a closed ID may reach its successor — the
# newest live ID whose `prev` continues it. Historical Parent links are read-only
# and never redirect delivery. A /clear, /compact, handoff or agent switch keeps
# the same ID.
#
# `live` is the set of IDs a live window carries (fleet-id.sh scans the sockets
# into FLEET_ID_LIVE); None = not known (no tmux to ask) — then an ID is live
# while its ledger has not closed.

SILENT_STATES = ("waiting", "idle")
DONE_STATES = ("merged", "succeeded")
FAIL_STATES = ("failed",)
ASK_STATES = ("blocked", "needs")


def alive(fid, rec, live):
    if rec["closed"] is not None:
        return False
    return live is None or fid in live


def last_result(rec):
    """The newest result of the ID's CURRENT attempt (EPIC T644 C2): a task's redo
    starts with none — the attempt before it failed, this one has not said yet."""
    cur = rec.get("attempt", 1)
    rs = [r for r in rec["results"] if r.get("attempt", 1) >= cur]
    return rs[-1] if rs else None


def _index(cache=False):
    """Every ledger here, folded once: {ID: rec}. cache=True adds the ID cache's
    records of the IDs this machine has no ledger of (another machine's — EPIC
    T644 C7), each marked src=hub; a reader that decides something only this
    machine can know (route, history, a task's line here) keeps cache off."""
    idx = {f: record(f) for f in ledger_ids()}
    if cache:
        for f in cache_ids():
            if f not in idx:
                rec = cached(f)
                if rec is not None:
                    idx[f] = rec
    return idx


def conflicts(fid, live, idx=None):
    """The other live IDs whose CURRENT segment is this ID's current segment (S9):
    both windows run one native session. Empty once either closes."""
    idx = idx if idx is not None else _index()
    rec = idx.get(fid) or fold(read(fid))
    if rec.get("src") == "hub" or not alive(fid, rec, live):
        return []
    out = []
    if isinstance(live, (list, tuple)) and list(live).count(fid) > 1:
        out.append(fid)   # one task's ID carried by two live windows (EPIC T644 C2)
    if not rec["segments"]:
        return out
    mine = rec["segments"][-1]["native"]
    for other, orec in idx.items():
        if other == fid or orec.get("src") == "hub" or not orec["segments"] or not alive(other, orec, live):
            continue
        if orec["segments"][-1]["native"] == mine:
            out.append(other)
    return sorted(out)


def status(fid, live, idx=None):
    """{state, label, result, conflict}: the one word a reader shows for an ID.
    state ∈ running · conflict · done · failed · asking · exited (+ the result's own
    state in `result`). The newest result counts (S2); closed with none = exited (S7)."""
    idx = idx if idx is not None else _index(cache=True)
    rec = idx.get(fid) or record(fid) or fold([])
    if rec.get("src") == "hub":
        # another machine's ID, off the cache: no window here to ask (C7)
        hs = _hub_status(fid, rec, rec["opened"].get("short") or short_for(fid, known_ids(idx.keys())))
        return dict(hs, id=fid, closed=rec["closed"], segments=len(rec["segments"]), progress=rec.get("progress"),
                    src="hub")
    r = last_result(rec)
    from fleet_reap_policy import completion_hold
    if completion_hold(fid, rec=rec):
        r = None
    rs = (r or {}).get("state", "")
    up = alive(fid, rec, live)
    con = conflicts(fid, live, idx) if up else []
    if con:
        st, label = "conflict", "等你"
    elif rs in DONE_STATES:
        st, label = "done", "已完成"
    elif rs in FAIL_STATES:
        st, label = "failed", "失败"
    elif rs in ASK_STATES:
        st, label = "asking", "等你"
    elif up:
        st, label = "running", "运行中"
    elif rec["closed"] is not None or live is not None:
        st, label = "exited", "已退出"
    else:
        st, label = "running", "运行中"
    out = {"id": fid, "short": rec["opened"].get("short") or short_for(fid, known_ids(idx.keys())),
           "state": st, "label": label, "alive": up, "result": r, "closed": rec["closed"],
           "segments": len(rec["segments"]), "progress": rec.get("progress")}
    if up and fid in NOAGENT:
        out["agent"] = False   # its window is here, its agent is not (T642)
    if con:
        out["conflict"] = con
    return out


def successors(fid, idx):
    """IDs whose `prev` is fid, newest first."""
    kids = [(o["opened"].get("ts") or 0, f) for f, o in idx.items() if o["opened"].get("prev") == fid and f != fid]
    return [f for _, f in sorted(kids, reverse=True)]


def route(fid, live, idx=None):
    """Resolve the same conversation: self, a prev successor, or nobody.
    Historical Parent links never redirect a message to a different task.
    unknown means no local ledger (e.g. an ID on another machine)."""
    idx = idx if idx is not None else _index()
    if fid not in idx:
        return fid, "unknown"
    seen = set()

    def down(f):
        # the newest live ID down the prev chain
        for s in successors(f, idx):
            if s in seen:
                continue
            seen.add(s)
            if alive(s, idx[s], live):
                return s
            got = down(s)
            if got:
                return got
        return ""

    seen.add(fid)
    if alive(fid, idx[fid], live):
        return fid, "self"
    nxt = down(fid)
    if nxt:
        return nxt, "successor"
    return "", ""


def children_of(fid, live, idx=None):
    idx = idx if idx is not None else _index(cache=True)
    rows = []
    for f, o in idx.items():
        if o["opened"].get("parent") != fid:
            continue
        st = status(f, live, idx)
        rows.append(dict(st, title=o["opened"].get("title", ""), prev=o["opened"].get("prev", ""),
                         opened_at=o["opened"].get("ts")))
    return sorted(rows, key=lambda r: r.get("opened_at") or 0)


class NoHub(Exception):
    pass


def _task_parent(task):
    """The parent ID the hub's task record names: the tail of its parent_session
    (`<fleet UUID>/<ID>`), "" when it names none. FLEET_ID_TASK_GET is the
    selftest's seam (a command; the T<n> is appended)."""
    cmd = os.environ.get("FLEET_ID_TASK_GET", "")
    argv = (cmd.split() if cmd else
            ["bash", os.path.join(os.path.dirname(os.path.abspath(__file__)), "fleet-task-record.sh"), "get"]) + [task]
    try:
        r = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if r.returncode == 3:
        raise NoHub()
    if r.returncode != 0:
        return None
    try:
        d = json.loads(r.stdout)
    except ValueError:
        return None
    d = d.get("task", d) if isinstance(d, dict) else {}
    tail = str(d.get("parent_session") or "").rsplit("/", 1)[-1]
    return tail if is_fid(tail) else ""


def parents_cmd(apply, only=()):
    """Read old task relationships; the old backfill mutation is retired."""
    if apply:
        print("fleet-id: PARENT_RETIRED: Parent backfill is disabled", file=sys.stderr)
        return 2
    n = 0
    for fid in (only or ledger_ids()):
        o = fold(read(fid))["opened"]
        task = o.get("task", "")
        if o.get("parent") or not re.match(r"^T[1-9][0-9]{0,9}$", task):
            continue
        n += 1
        try:
            par = _task_parent(task)
        except NoHub:
            print("fleet-id: no hub here — the records cannot be read", file=sys.stderr)
            return 3
        code = o.get("short") or encode(fid)[:SHORT_MIN]
        if par is None:
            print("%s  %s  ?  (the record did not answer)" % (code, task))
            continue
        if not par or par == fid:
            print("%s  %s  -  (the record names no parent session)" % (code, task))
            continue
        print("%s  %s  → %s  (historical, read only)" % (code, task, par))
    print("%d without a parent · read only" % n)
    return 0


BACKFILL_COLS = ("socket", "fid", "window", "agent", "repo", "worktree", "task", "cc_sid", "codex_sid",
                 "codex_thread", "role")


def _backfill_windows():
    """FLEET_ID_BACKFILL (fleet-id.sh fills it): one live window a line, BACKFILL_COLS
    tab-separated — a session window with an ID, never home or a panel."""
    out = []
    for line in os.environ.get("FLEET_ID_BACKFILL", "").splitlines():
        parts = (line.split("\t") + [""] * len(BACKFILL_COLS))[:len(BACKFILL_COLS)]
        w = dict(zip(BACKFILL_COLS, (x.strip() for x in parts)))
        if is_fid(w["fid"]) and w["role"] not in ("home", "panel"):
            out.append(w)
    return out


def backfill_cmd(apply, only=()):
    """Backfill (EPIC T497 C17): a live window opened before C1 whose ledger has no
    `opened` or no native segment gets them — `opened` off the window's options
    (agent @cc_agent, window, repo, worktree, task; `backfill: true`) and its current
    native session (@cc_session_id / @codex_session_id) as segment 1, trigger
    `migrated`. Fill-only and idempotent: what the ledger has is never written again.
    Dry unless apply; an applied ID is pushed to the hub's mirror."""
    n = done = 0
    for w in _backfill_windows():
        fid = w["fid"]
        if only and fid not in only:
            continue
        rec = fold(read(fid))
        has_open = any(e.get("ev") == "opened" for e in read(fid))
        agent = w["agent"] if w["agent"] in ("claude", "codex") else (
            "codex" if (w["codex_sid"] or w["codex_thread"]) and not w["cc_sid"] else "claude")
        native = (w["codex_sid"] or w["codex_thread"]) if agent == "codex" else w["cc_sid"]
        want_open = not has_open or not (rec["opened"].get("agent") or rec["segments"])
        want_seg = not rec["segments"] and bool(native)
        if not (want_open or want_seg):
            continue
        n += 1
        code = rec["opened"].get("short") or short_for(fid, known_ids([x["fid"] for x in _backfill_windows()]))
        what = " + ".join(x for x in ("opened" if want_open else "", "段 1 migrated" if want_seg else "") if x)
        if apply:
            if want_open:
                open_id(fid, {"agent": agent, "window": w["window"], "repo": w["repo"], "worktree": w["worktree"],
                              "task": w["task"], "backfill": True})
            if want_seg:
                def decide(evs, agent=agent, native=native):
                    if fold(evs)["segments"]:
                        return None
                    return {"ev": "native", "agent": agent, "native": native, "trigger": "migrated",
                            "source": "backfill", "seg": 1}
                append(fid, None, decide=decide)
            push_later(fid)
            done += 1
        print("%s  %s  %s  %s%s%s" % (code, w["window"] or "-", agent, what,
                                       "" if native else "  (no native session id on the window)",
                                       "" if apply else "  (dry)"))
    print("%d to backfill · %d %s" % (n, done, "written" if apply else "to write (--apply)"))
    return 0


def _hub_record(fid):
    """The hub mirror's record of an ID this machine has no ledger of — folded into the
    ledger's shape — or None."""
    code, ans = _poster()("GET", "/v1/node/ids/" + fid)
    if code != 200 or not isinstance(ans, dict):
        return None
    if ans.get("id") == fid:
        cache_put(ans)   # what was read once is kept (C7)
    return hub_fold(fid, ans)


def _family_row(fid, rec, st, src):
    o = rec["opened"]
    return {"id": fid, "short": st["short"], "task": o.get("task", ""), "title": o.get("title", ""),
            "attempt": rec.get("attempt", 1),
            "parent": o.get("parent", ""), "prev": o.get("prev", ""), "opened_at": o.get("ts"),
            "state": st["state"], "label": st["label"], "alive": st["alive"], "result": st["result"],
            "closed": rec["closed"], "src": src, "segments": len(rec["segments"]), "progress": rec.get("progress"),
            **({"agent": False} if st.get("agent") is False else {})}


def _hub_status(fid, rec, short):
    """status()'s reading of a hub-mirror record (no window here to ask)."""
    cur = rec.get("attempt", 1)
    r = next((x for x in reversed(rec["results"]) if x.get("state") not in SILENT_STATES
              and x.get("attempt", 1) >= cur), None) or last_result(rec)
    rs = (r or {}).get("state", "")
    if rs in DONE_STATES:
        st, label = "done", "已完成"
    elif rs in FAIL_STATES:
        st, label = "failed", "失败"
    elif rs in ASK_STATES:
        st, label = "asking", "等你"
    elif rec["closed"] is not None:
        st, label = "exited", "已退出"
    else:
        st, label = "running", "运行中"
    return {"short": short, "state": st, "label": label, "alive": rec["closed"] is None, "result": r}


def lineage_of(fid, idx):
    """fid and every ID that continued it down `prev`, at any depth (a driver's
    「从这一段继续」 — EPIC T497 C18), oldest first: one session's whole line."""
    out, frontier = [fid], [fid]
    while frontier:
        nxt = []
        for f in frontier:
            for s in reversed(successors(f, idx)):
                if s not in out:
                    out.append(s)
                    nxt.append(s)
        frontier = nxt
    return out


def task_root(task, idx=None):
    """The ID opened for the record `task` (its ledger's `task`) that no other one
    opened for it continues — where that record's line of sessions starts; the
    oldest when several do. '' when this machine opened none (C18)."""
    idx = idx if idx is not None else _index()
    mine = {f: o for f, o in idx.items() if task and o["opened"].get("task") == task}
    roots = [f for f, o in mine.items() if o["opened"].get("prev") not in mine] or list(mine)
    return min(roots, key=lambda f: (mine[f]["opened"].get("ts") or 0, f)) if roots else ""


def family(fid, live, idx=None, seeds=()):
    """An EPIC driver's batch by ID (EPIC T497 C5): the IDs fid spawned (their
    `parent`), the `seeds` (IDs the caller knows are members — a child task's
    worker — whose ledger may name no parent), and every ID that continued one of
    them down `prev` — a member's redo or a 「从这一段继续」 — oldest first. This
    machine's ledgers first; the hub mirror's `GET /v1/node/ids?parent=<fid>&id=<seed>…`
    adds the ones other machines opened. A hub that does not know the query lists
    bare ids, which are dropped — the seeds it lacks are then read one by one.
    The driver is its whole line (C18): fid and every ID that continued IT down
    `prev` (`lineage`) — what any of them spawned is the batch's, and the newest
    progress word among them is the batch's; they are never members themselves."""
    idx = idx if idx is not None else _index(cache=True)
    line = lineage_of(fid, idx)
    seeds = [x for x in dict.fromkeys(seeds) if is_fid(x) and x not in line]
    rows, seen = {}, set(line)
    first = []
    for x in seeds:
        if x in idx:
            seen.add(x)
            first.append(x)
            rows[x] = _family_row(x, idx[x], status(x, live, idx), idx[x].get("src", "local"))
    frontier, key = list(line), "parent"
    while frontier:
        nxt, first = first, []
        for f in frontier:
            for other, o in idx.items():
                if other not in seen and o["opened"].get(key) == f:
                    seen.add(other)
                    nxt.append(other)
                    rows[other] = _family_row(other, o, status(other, live, idx), o.get("src", "local"))
        frontier, key = nxt, "prev"
    post = _poster()
    code, ans = post("GET", "/v1/node/ids?parent=" + fid + "".join("&id=" + x for x in seeds[:100]))
    hub = "ok" if code == 200 else ("none" if code == -3 else "down")
    got = (ans.get("ids") or []) if code == 200 and isinstance(ans, dict) else []
    if code == 200 and isinstance(ans, dict) and "parent" in ans:
        # a hub that reads the line itself names it; an older one is asked once
        # per ID of the line this machine knows
        hl = [x for x in ans.get("lineage") or [] if is_fid(x)]
        for x in hl:
            if x not in line:
                line.append(x)
        if "lineage" not in ans:
            for x in line[1:]:
                c2, a2 = post("GET", "/v1/node/ids?parent=" + x)
                if c2 == 200 and isinstance(a2, dict):
                    got = got + [r for r in a2.get("ids") or [] if isinstance(r, dict)]
    if code == 200 and isinstance(ans, dict) and "parent" not in ans:
        hub, got = "old", []
        for x in seeds:
            one = None if x in rows else _hub_record(x)
            if one is not None:
                o = one["opened"]
                got.append({"id": x, "short": o.get("short", ""), "title": o.get("title", ""),
                            "parent": o.get("parent", ""), "prev": o.get("prev", ""),
                            "results": [{"state": r.get("state", ""), "summary": r.get("summary", ""),
                                         "pr": r.get("pr", ""), "at": r.get("ts")} for r in one["results"]],
                            "closed_at": (one["closed"] or {}).get("ts"),
                            "close_reason": (one["closed"] or {}).get("reason", "")})
    for x in got:
        if not isinstance(x, dict) or not is_fid(x.get("id", "")) or x["id"] in rows or x["id"] in line:
            continue
        if "parent" not in x and "prev" not in x and "results" not in x:
            continue   # an older hub: the owner's bare id list
        rec = {"opened": {"short": hub_short(x["id"], x.get("short", "")), "title": x.get("title", ""), "parent": x.get("parent", ""),
                          "prev": x.get("prev", ""), "task": x.get("task", ""), "ts": x.get("opened_at")},
               "segments": [], "closed": None,
               "results": [{"state": r.get("state", ""), "summary": r.get("summary", ""), "pr": r.get("pr", ""),
                            "ts": r.get("at")} for r in x.get("results") or [] if isinstance(r, dict)]}
        if x.get("closed_at"):
            rec["closed"] = {"ts": x["closed_at"], "reason": x.get("close_reason", "")}
        rows[x["id"]] = _family_row(x["id"], rec, _hub_status(x["id"], rec, rec["opened"]["short"]), "hub")
    out = sorted((r for r in rows.values() if r["id"] not in line), key=lambda r: (r.get("opened_at") or 0, r["id"]))
    pg = None
    for f in line:   # the newest word down the line (C18)
        if f in idx:
            p = idx[f]["progress"]
            p = dict(p, src=idx[f].get("src", "local")) if p else None
        else:
            p = progress_of(f) if hub == "ok" or hub == "old" else None
        if p and (pg is None or (p.get("ts") or 0) >= (pg.get("ts") or 0)):
            pg = dict(p, id=f)
    return {"parent": fid, "progress": pg, "short": (idx.get(fid) or fold(read(fid)))["opened"].get("short")
            or short_for(fid, known_ids(idx.keys())), "hub": hub, "lineage": line, "ids": out}


AWAIT_RC = {"done": 0, "failed": 1, "asking": 1, "exited": 4}


def await_id(fid, timeout, interval, live_fn):
    """Wait until fid has a result that is not a turn boundary, or has closed (design
    §4.3). → the verdict block and its rc: 0 MERGED/SUCCEEDED · 1 FAILED/BLOCKED/
    STOPPED · 3 TIMEOUT · 4 EXITED (closed with no result)."""
    end = time.time() + timeout
    while True:
        local = os.path.exists(ledger_path(fid))
        rec = fold(read(fid)) if local else _hub_record(fid)
        if rec is not None:
            r = last_result(rec)
            short = rec["opened"].get("short") or short_for(fid, known_ids())
            if r and r.get("state") not in SILENT_STATES:
                word = r.get("state", "").upper() or "RESULT"
                lines = [word, "id: %s (%s)" % (tag(short), fid)]
                if r.get("pr"):
                    lines.append("pr: #%s" % str(r["pr"]).lstrip("#"))
                if r.get("summary"):
                    lines.append("summary: %s" % r["summary"])
                print("\n".join(lines))
                st = r.get("state")
                return 0 if st in DONE_STATES else 1
            if rec["closed"] is not None:
                print("EXITED\nid: %s (%s)\nnote: the window closed without a result" % (tag(short), fid))
                return 4
        left = end - time.time()
        if left <= 0:
            print("TIMEOUT\nid: %s\nnote: no result yet — run it again to keep waiting" % fid)
            return 3
        time.sleep(min(interval, left))


def history_rows(live, include_open=False, idx=None):
    """One row per ID (design §4.4: ID · 短名 · 结果 · 关闭时间), newest first —
    closed IDs only unless include_open."""
    idx = idx if idx is not None else _index()
    rows = []
    for f, o in idx.items():
        st = status(f, live, idx)
        if not include_open and st["alive"]:
            continue
        r = st["result"] or {}
        rows.append({"id": f, "short": st["short"], "title": o["opened"].get("title", ""), "state": st["state"],
                     "label": st["label"], "result": r.get("state", ""), "summary": r.get("summary", ""),
                     "pr": r.get("pr", ""), "closed_at": (o["closed"] or {}).get("ts"),
                     "opened_at": o["opened"].get("ts"), "segments": len(o["segments"]),
                     "prev": o["opened"].get("prev", ""), "parent": o["opened"].get("parent", "")})
    rows.sort(key=lambda r: r["closed_at"] or r["opened_at"] or 0, reverse=True)
    return rows


def take_task_id(fid):
    """May a window opened HERE for a task carry the task's ID `fid` (EPIC T644 C2)?
    `here` — this machine keeps its ledger (a redo, a re-dispatch: the same ID's next
    attempt); `first` — the hub minted it with the record and no machine has pushed
    it yet (seq 0), or the hub has no row of it; None — another machine holds it, or
    the hub could not say: the window then takes a NEW ID whose prev is the task's
    (the old road), so a ledger is never written under an ID another machine owns."""
    if os.path.exists(ledger_path(fid)):
        return "here"
    code, ans = _poster()("GET", "/v1/node/ids/" + fid)
    if code == 404:
        return "first"
    if code == 200 and isinstance(ans, dict) and not ans.get("seq"):
        return "first"
    return None


def next_attempt(fid, window=""):
    """A task's redo on its own ID (EPIC T644 C2): once the ledger has run a segment,
    the window opening now is the next attempt — one `reopened` event carrying it
    (the hub clears the close off the same event). → the attempt it is now."""
    def decide(evs):
        rec = fold(evs)
        if not rec["segments"] and rec["closed"] is None:
            return None   # opened, never started: still the first attempt
        ev = {"ev": "reopened", "attempt": rec["attempt"] + (1 if rec["segments"] else 0)}
        if window:
            ev["window"] = window
        return ev
    if append(fid, None, decide=decide):
        push_later(fid)
    return fold(read(fid))["attempt"]


def continue_plan(fid, seg=None):
    """What 「从这一段继续」 (a new window, a new ID, prev = fid — S8) or 「恢复这个窗口」
    (the same ID, its newest segment) resumes: {native, agent, seg, worktree, repo, title,
    task}. The task and native segment continue; old task ancestry does not."""
    rec = fold(read(fid))
    segs = rec["segments"]
    if not segs:
        raise ValueError("%s has no native segment to resume" % fid)
    n = len(segs) if seg is None else int(seg)
    if n < 1 or n > len(segs):
        raise ValueError("%s has segments 1..%d, not %s" % (fid, len(segs), seg))
    s = segs[n - 1]
    o = rec["opened"]
    placement = {}
    if s["agent"] == "codex":
        from fleet_history_read import landing
        placement = landing(fid, s["native"])
    return {"id": fid, "seg": n, "native": s["native"], "agent": s["agent"],
            "worktree": (o.get("legacy_cwds") or {}).get(s["native"], o.get("worktree", "")),
            "repo": o.get("repo", ""), "title": o.get("title", ""), "closed": rec["closed"] is not None,
            "task": o.get("task", ""),
            **({"codex_home": o["codex_home"]} if o.get("codex_home") else {}), **placement}



# ---- the hub mirror (EPIC T497 C2) ----------------------------------------------
#
# `push` hands each ledger to the hub (POST /v1/node/ids, the node token — through
# `fleet-id.sh _post`, so the token never leaves that shell) in (ID, seq) order,
# from the seq the hub last said it holds ($ids/.hub/<ID>.seq). The hub answers
# where it is: a resend is a no-op there, a gap is answered with its own seq and
# the node resends from it (a hub rebuilt empty gets every ledger again — the
# mirror is a replay). Its answer also carries the ID's code: a longer one than
# the ledger's (another ID of the owner shared the prefix, S12) is written down as
# a `short` event and moved onto the window's @task_short. A 409 DUPLICATE_ID (the
# full ID is another machine's — a cloned machine, S13) is kept as
# $ids/.hub/<ID>.refused, said on the window (@id_hub_error) and as one alert,
# and that ledger is never pushed again; the window keeps running.

PUSH_BATCH = 200
KNOWN_TTL = 600


def hub_dir():
    return os.path.join(ids_dir(), ".hub")


def _hub_state(fid):
    try:
        with open(os.path.join(hub_dir(), fid + ".seq"), encoding="utf-8") as fh:
            seq, _, size = fh.read().strip().partition(" ")
        return int(seq), int(size or -1)
    except (OSError, ValueError):
        return 0, -1


def _hub_set(fid, seq):
    os.makedirs(hub_dir(), exist_ok=True)
    try:
        size = os.path.getsize(ledger_path(fid))
        if any(e.get("seq", 0) > seq for e in read(fid)):
            size = -1  # an unsent suffix must retry even without a new append
    except OSError:
        size = -1
    tmp = os.path.join(hub_dir(), ".%s.%d" % (fid, os.getpid()))
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("%d %d\n" % (seq, size))
    os.replace(tmp, os.path.join(hub_dir(), fid + ".seq"))


def _poster():
    """(method, path, body|None) → (http code, parsed JSON | None); code 0 = unreachable,
    -3 = no hub here. FLEET_ID_HUB_POST is the seam (a command: METHOD PATH as args,
    the body on stdin, `<code>\n<body>` out)."""
    import shlex
    if not os.environ.get("FLEET_ID_HUB_POST"):
        # in-process (T992, fleet_node_http): fleet-id.sh _post's bash + its two
        # interpreters were ~1 s a call; a take is two
        try:
            import fleet_node_http as nh
        except ImportError:
            nh = None
        if nh is not None and nh.usable() and nh.pair():
            def direct(method, path, body=None):
                if not nh.pair():
                    return -3, None
                try:
                    code, text = nh.call(method, path, json.dumps(body, ensure_ascii=False) if body is not None else None)
                except nh.Unreachable:
                    return 0, None
                try:
                    return code, json.loads(text) if text.strip() else None
                except ValueError:
                    return code, None
            return direct
    cmd = shlex.split(os.environ.get("FLEET_ID_HUB_POST", "")) or \
        ["bash", os.path.join(os.path.dirname(os.path.abspath(__file__)), "fleet-id.sh"), "_post"]

    def call(method, path, body=None):
        try:
            p = subprocess.run(cmd + [method, path], input=json.dumps(body, ensure_ascii=False) if body is not None else "",
                               text=True, capture_output=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            return 0, None
        if p.returncode == 3:
            return -3, None
        code, _, rest = p.stdout.partition("\n")
        try:
            code = int(code.strip())
        except ValueError:
            return 0, None
        try:
            return code, json.loads(rest) if rest.strip() else None
        except ValueError:
            return code, None
    return call


# ---- the switch and the migration (EPIC T497 C6; design §5, §5.1) ---------------
#
# The switch is the hub's (`fleet.id_switch`); this node keeps its last word in
# $ids/.switch («on» / «off») — written by `fleet-id.sh switch` (the cleanup tick
# asks every round). Since C8 nothing here reads it to decide: the old road is
# gone, a spawn claims nothing and a report is a result on the window's ID
# whatever the word — the one gate is «the window has an ID». It is shown only.

def switch_path():
    return os.path.join(ids_dir(), ".switch")


def switch_on():
    """The hub's last word on the switch here; never heard = off. Shown only."""
    if os.environ.get("FLEET_ID_SWITCH") in ("on", "off"):   # the selftests' seam
        return os.environ["FLEET_ID_SWITCH"] == "on"
    try:
        with open(switch_path(), encoding="utf-8") as fh:
            return fh.read().split()[:1] == ["on"]
    except OSError:
        return False


def switch_note(on):
    """Write the hub's word down (atomic); never fails the caller."""
    try:
        os.makedirs(ids_dir(), exist_ok=True)
        tmp = "%s.%d" % (switch_path(), os.getpid())
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write("%s %d\n" % ("on" if on else "off", int(time.time())))
        os.replace(tmp, switch_path())
    except OSError:
        pass


def switch_cmd(word, call=None):
    """`fleet-id.sh switch [status|on|off]`: ask (or, on/off, set — the operator's
    machines only) the hub's switch and write it down. rc 0 · 3 no hub here (the
    note says what this node last heard) · 75 the hub did not answer · 1 refused."""
    call = call or _poster()
    if word in ("on", "off"):
        code, ans = call("POST", "/v1/node/ids/switch", {"on": word == "on"})
    else:
        code, ans = call("GET", "/v1/node/ids/switch")
    if code == -3:
        print("%s (no hub here — the last word this node heard)" % ("on" if switch_on() else "off"))
        return 3
    if code == 0:
        print("%s (the hub did not answer — the last word this node heard)" % ("on" if switch_on() else "off"), file=sys.stderr)
        return 75
    if code != 200 or not isinstance(ans, dict):
        why = (ans or {}).get("error") if isinstance(ans, dict) else ""
        print("fleet-id: the hub refused the switch (HTTP %s)%s" % (code, ": " + why if why else ""), file=sys.stderr)
        return 1
    on = bool(ans.get("on"))
    switch_note(on)
    print("on" if on else "off")
    return 0


MIGRATE_ORDER = ("live", "succeeded", "failed", "cancelled", "exited", "closed", "not_started", "wait")


def migrate_cmd(apply, only, as_json, call=None):
    """`fleet-id.sh migrate [--apply] [--only T1,T2] [--json]`: the hub settles every
    old T record by the §5 table, asking each worker's machine once, read-only. Dry
    by default — it prints what each record WOULD become and writes nothing; --apply
    writes each one's end and its audit row (action id_migrate). A record whose
    machine did not answer is never moved (等节点回答): run it again later."""
    call = call or _poster()
    body = {"apply": bool(apply)}
    if only:
        body["only"] = only
    code, ans = call("POST", "/v1/node/ids/migrate", body)
    if code == -3:
        print("fleet-id: no hub here — nothing to migrate", file=sys.stderr)
        return 3
    if code == 0:
        print("fleet-id: the hub did not answer — nothing was migrated", file=sys.stderr)
        return 75
    if code != 200 or not isinstance(ans, dict):
        why = (ans or {}).get("error") if isinstance(ans, dict) else ""
        print("fleet-id: the hub refused the migration (HTTP %s)%s" % (code, ": " + why if why else ""), file=sys.stderr)
        return 1
    if as_json:
        print(json.dumps(ans, ensure_ascii=False))
        return 0
    items = ans.get("items") or []
    print("%s · %d 条旧记录 · 开关 %s" % ("迁移（已写入）" if ans.get("apply") else "dry-run（只看，不改）",
                                     len(items), "开" if ans.get("switch") else "关"))
    for it in items:
        after = it.get("label", "")
        if it.get("verdict") == "live":
            after = "活着 → %s（别名 %s）" % (it.get("short") or "窗口没有 ID", it["task"])
            if it.get("result"):
                after += "，结果：" + {"succeeded": "已完成", "failed": "失败", "cancelled": "已取消"}.get(it["result"], it["result"])
        mark = "  ✓" if it.get("applied") else ""
        print("%-6s %-58s → %s%s" % (it.get("task", ""), it.get("before", ""), after, mark))
        print("       依据：%s" % it.get("evidence", ""))
    counts = ans.get("counts") or {}
    print("合计：" + " · ".join("%s %d" % (k, counts[k]) for k in MIGRATE_ORDER if counts.get(k)))
    return 0


def _windows():
    """FLEET_ID_WINDOWS (fleet-id.sh fills it): `<ID>\t<socket>\t<window>` lines."""
    out = {}
    for line in os.environ.get("FLEET_ID_WINDOWS", "").splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and is_fid(parts[0]):
            out[parts[0]] = (parts[1], parts[2])
    return out


def _wset_any(where, name, value):
    if not where:
        return
    sock, win = where
    try:
        subprocess.run(["tmux"] + (["-L", sock] if sock else []) + ["set-option", "-w", "-t", win, name, value],
                       capture_output=True, timeout=3)
    except (OSError, subprocess.TimeoutExpired):
        pass


def _refuse(fid, why, where):
    os.makedirs(hub_dir(), exist_ok=True)
    with open(os.path.join(hub_dir(), fid + ".refused"), "w", encoding="utf-8") as fh:
        fh.write(why.strip() + "\n")
    short = fold(read(fid))["opened"].get("short") or short_for(fid, known_ids())
    text = "%s: 完整 ID 已被另一台机器登记（整机克隆？）——hub 不收这个窗口的记录，窗口照常跑；开新窗口会有新 ID" % short
    _wset_any(where, "@id_hub_error", text)
    alerts = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fleet-alerts.sh")
    if os.path.exists(alerts) and os.environ.get("FLEET_ID_ALERT", "1") != "0":
        try:
            subprocess.run(["bash", alerts, "event", "id-duplicate", text], capture_output=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            pass


def push_one(fid, call, where=None):
    """Push one ledger. → 0 done (or nothing to do / refused) · 75 the hub did not answer · 3 no hub."""
    if os.path.exists(os.path.join(hub_dir(), fid + ".refused")):
        return 0
    seq, size = _hub_state(fid)
    try:
        if size >= 0 and os.path.getsize(ledger_path(fid)) == size:
            return 0   # nothing written since the hub last answered
    except OSError:
        return 0
    stuck = 0
    named_supported = False
    while True:
        events = [e for e in read(fid) if isinstance(e.get("seq"), int)]
        todo = [e for e in events if e["seq"] > seq][:PUSH_BATCH]
        if not todo:
            _hub_set(fid, seq)
            return 0
        if any(e.get("ev") == "named" for e in todo) and not named_supported:
            cap_code, caps = call("GET", "/v1/node/ids/capabilities", None)
            named_supported = cap_code == 200 and isinstance(caps, dict) and caps.get("named") is True
            if not named_supported:
                # Older hubs advance seq for unknown events. Hold the named
                # suffix locally until the hub knows it; never silently lose it.
                first = next(i for i, e in enumerate(todo) if e.get("ev") == "named")
                todo = todo[:first]
                if not todo:
                    return 76 if cap_code > 0 else (3 if cap_code == -3 else 75)
        code, ans = call("POST", "/v1/node/ids", {"id": fid, "events": todo})
        if code == -3:
            return 3
        if code == 409 and isinstance(ans, dict) and ans.get("code") == "DUPLICATE_ID":
            _refuse(fid, ans.get("error", "DUPLICATE_ID"), where)
            return 0
        if code != 200 or not isinstance(ans, dict) or not isinstance(ans.get("seq"), int):
            if code == 0 or code >= 500:
                return 75
            print("fleet-id: the hub refused %s (HTTP %s): %s" % (fid, code, (ans or {}).get("error", "")), file=sys.stderr)
            return 0
        got = ans["seq"]
        short = ans.get("short") or ""
        have = fold(read(fid))["opened"].get("short", "")
        if is_short(short) and len(short) > len(have):
            append(fid, {"ev": "short", "short": short, "by": "hub"})
            _wset_any(where, "@task_short", short)
        if got > seq or got < seq:
            stuck = 0 if got > seq else stuck + 1
            seq = got   # behind us (a hub rebuilt): resend from where it is
        else:
            stuck += 1
        if stuck > 2:
            return 0
        _hub_set(fid, seq)


def push(ids, call=None):
    call = call or _poster()
    wins = _windows()
    rc = 0
    for fid in ids or sorted(ledger_ids()):
        r = push_one(fid, call, wins.get(fid))
        if r == 76:
            rc = 75  # an older hub holds only this ID, not unrelated lifecycles
            continue
        if r in (3, 75):
            return r
        rc = rc or r
    # the owner's IDs the hub knows, for the short codes (known_ids) — at most every KNOWN_TTL
    kp = os.path.join(ids_dir(), ".known")
    try:
        fresh = time.time() - os.path.getmtime(kp) < KNOWN_TTL
    except OSError:
        fresh = False
    if not fresh:
        code, ans = call("GET", "/v1/node/ids")
        if code == 200 and isinstance(ans, dict) and isinstance(ans.get("ids"), list):
            os.makedirs(ids_dir(), exist_ok=True)
            tmp = kp + ".%d" % os.getpid()
            with open(tmp, "w", encoding="utf-8") as fh:
                for x in ans["ids"]:
                    if isinstance(x, dict) and is_fid(x.get("id")):
                        fh.write(x["id"] + "\n")
            os.replace(tmp, kp)
    return rc


def live_report(ids, dry=False, call=None, as_json=False):
    """Tell the hub which IDs this login's windows carry now (task BCYB): POST
    /v1/node/ids/live. The hub closes this machine's open IDs the list leaves out
    and answers what it closed / reopened; the answer is kept in $ids/.hub/live.json
    (the doctor's `ids` row). → 0 · 3 no hub here · 75 the hub did not answer."""
    call = call or _poster()
    code, ans = call("POST", "/v1/node/ids/live", {"ids": sorted(i for i in ids if is_fid(i)), "dry": bool(dry)})
    if code == -3:
        return 3
    if code != 200 or not isinstance(ans, dict):
        if code in (404, 405):
            return 0   # an older hub: no reconcile road
        print("fleet-id: the hub did not take the live list (HTTP %s)" % code, file=sys.stderr)
        return 75
    ans["at"] = int(time.time())
    if not dry:
        os.makedirs(hub_dir(), exist_ok=True)
        tmp = os.path.join(hub_dir(), ".live.%d" % os.getpid())
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(ans, fh, ensure_ascii=False)
        os.replace(tmp, os.path.join(hub_dir(), "live.json"))
        if ans.get("closed") or ans.get("reopened"):
            pull_later()
    if as_json:
        print(json.dumps(ans, ensure_ascii=False))
        return 0
    word = "would close" if dry else "closed"
    print("%s %d · reopened %d · kept %d · live %d" % (word, len(ans.get("closed") or []),
                                                      len(ans.get("reopened") or []), ans.get("kept", 0), ans.get("live", 0)))
    for x in ans.get("closed") or []:
        print("  %-6s %-10s %-15s %s" % (x.get("short", ""), x.get("machine") or "-", x.get("reason", ""), x.get("title", "")))
    for x in ans.get("reopened") or []:
        print("  reopened %-6s %s" % (x.get("short", ""), x.get("title", "")))
    return 0


def push_later(fid):
    """Hand one ID to `fleet-id.sh push` in the background — never waited for."""
    if os.environ.get("FLEET_ID_PUSH", "1") == "0":
        return
    try:
        subprocess.Popen(["bash", os.path.join(os.path.dirname(os.path.abspath(__file__)), "fleet-id.sh"), "push", fid],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    except OSError:
        pass


# ---- the ID cache (EPIC T644 C7) --------------------------------------------------
#
# This machine's ledgers are the writer: a write lands here first and is pushed. What
# every machine of the owner wrote is CACHED here, one hub record a file
# ($ids/.cache/<ID>.json, the hub's own shape) — so a panel whose home is this
# machine reads another machine's ID (its short code, parent, task, results,
# progress) exactly as that machine's panel does. `pull` fills it from
# GET /v1/node/ids?since=<cursor> (the cleanup tick, after push; every CACHE_FULL a
# full pass that also drops a file the hub no longer lists), `pull <ID>…` one by one
# (a reader that missed one asks in the background: pull_later). No reader ever waits
# on the hub: no hub, or a silent one, leaves the cache as it was. On a conflict the
# hub wins (record): a ledger here is filled from its cached record — an `opened`
# field it lacks, a longer short — and keeps what it wrote itself (results, closing:
# not yet pushed, or the same).

CACHE_FULL = 3600
PULL_PAGES = 40


def cache_dir():
    return os.path.join(ids_dir(), ".cache")


def cache_path(fid):
    return os.path.join(cache_dir(), fid + ".json")


def cache_ids():
    try:
        names = os.listdir(cache_dir())
    except OSError:
        return []
    return [n[:-5] for n in names if n.endswith(".json") and is_fid(n[:-5])]


def cache_raw(fid):
    try:
        with open(cache_path(fid), encoding="utf-8") as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        return None
    return d if isinstance(d, dict) and d.get("id") == fid else None


def cache_put(ans):
    """Write one hub record into the cache (atomic); a record no newer than the one
    kept (its seq) changes nothing. → True when written."""
    fid = ans.get("id") if isinstance(ans, dict) else ""
    if not is_fid(fid or ""):
        return False
    have = cache_raw(fid)
    if have is not None and have == ans:
        return False
    os.makedirs(cache_dir(), exist_ok=True)
    tmp = os.path.join(cache_dir(), ".%s.%d" % (fid, os.getpid()))
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(ans, fh, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, cache_path(fid))
    return True


def hub_fold(fid, ans):
    """A hub record (GET /v1/node/ids…) in fold()'s shape, marked src=hub."""
    o = {"short": hub_short(fid, ans.get("short", ""))}
    for k in ("title", "title_source", "parent", "prev", "task", "repo", "agent", "key", "machine", "login"):
        if ans.get(k):
            o[k] = ans[k]
    if ans.get("opened_at"):
        o["ts"] = ans["opened_at"]
    segs = []
    for n in ans.get("natives") or []:
        if isinstance(n, dict):
            segs.append({"n": n.get("n") or len(segs) + 1, "agent": n.get("agent", ""), "native": n.get("native", ""),
                         "trigger": n.get("trigger", ""), "start": n.get("start"), "end": n.get("end") or None,
                         "compactions": n.get("compactions") or 0})
    rec = {"opened": o, "segments": segs, "closed": None, "src": "hub",
           "results": [{"state": r.get("state", ""), "summary": r.get("summary", ""), "pr": r.get("pr", ""),
                        "ts": r.get("at")} for r in ans.get("results") or [] if isinstance(r, dict)]}
    if ans.get("closed_at"):
        rec["closed"] = {"ts": ans["closed_at"], "reason": ans.get("close_reason", "")}
    pg = ans.get("progress")
    rec["progress"] = {"summary": pg.get("summary", ""), "state": pg.get("state", ""), "ts": pg.get("at"),
                       "seq": pg.get("seq")} if isinstance(pg, dict) and pg.get("summary") else None
    return rec


def cached(fid):
    """The cache's record of fid, folded (hub_fold), or None."""
    ans = cache_raw(fid)
    return hub_fold(fid, ans) if ans is not None else None


def record(fid, cached_here=None):
    """fid's one record: this machine's ledger filled from the cache (the hub wins:
    an `opened` field the ledger lacks, a longer short), else the cache's record
    (src=hub), else None. Every reader that shows an ID reads this. cached_here:
    the caller already knows whether the cache holds fid (False skips the read)."""
    have = os.path.exists(ledger_path(fid))
    rec = fold(read(fid)) if have else None
    hub = cached(fid) if cached_here is not False else None
    if rec is None:
        return hub
    if hub is not None:
        o, ho = rec["opened"], hub["opened"]
        for k, v in ho.items():
            if k == "short":
                if is_short(v) and len(v) > len(o.get("short") or ""):
                    o["short"] = v
            elif v not in (None, "") and k not in o:
                o[k] = v
    return rec


def _cursor_path():
    return os.path.join(cache_dir(), ".cursor")


def pull(ids=(), call=None, full=False):
    """Fill the cache from the hub: the IDs named one by one, else every record that
    changed after the cursor (a full pass when asked, with no cursor, or every
    CACHE_FULL). → 0 · 3 no hub here · 75 the hub did not answer (the cache stays)."""
    call = call or _poster()
    if ids:
        rc = 0
        for fid in ids:
            code, ans = call("GET", "/v1/node/ids/" + fid)
            if code == -3:
                return 3
            if code == 0:
                return 75
            if code == 200 and isinstance(ans, dict) and ans.get("id") == fid:
                cache_put(ans)
        return rc
    cur, stamp = "", 0
    try:
        with open(_cursor_path(), encoding="utf-8") as fh:
            cur, _, stamp = fh.read().strip().partition(" ")
        stamp = int(stamp or 0)
    except (OSError, ValueError):
        cur, stamp = "", 0
    if full or not cur or time.time() - stamp >= CACHE_FULL:
        cur, full = "", True
    seen, done = set(), False
    for _ in range(PULL_PAGES):
        code, ans = call("GET", "/v1/node/ids?since=" + urllib_quote(cur))
        if code == -3:
            return 3
        if code != 200 or not isinstance(ans, dict):
            return 75
        if "cursor" not in ans:
            return 0   # an older hub: no sync road — the cache stays as it is
        for x in ans.get("ids") or []:
            if isinstance(x, dict) and is_fid(x.get("id") or ""):
                seen.add(x["id"])
                cache_put(x)
        cur = str(ans.get("cursor") or cur)
        if not ans.get("more"):
            done = True
            break
    os.makedirs(cache_dir(), exist_ok=True)
    if full and done:
        # a full pass: what the hub no longer lists is gone from the cache too
        for f in cache_ids():
            if f not in seen:
                try:
                    os.unlink(cache_path(f))
                except OSError:
                    pass
        stamp = int(time.time())
    tmp = _cursor_path() + ".%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("%s %d\n" % (cur, stamp))
    os.replace(tmp, _cursor_path())
    return 0


def urllib_quote(s):
    from urllib.parse import quote
    return quote(s, safe="")


def pull_later(ids=()):
    """Hand `fleet-id.sh pull [<ID>…]` to the background — never waited for; one at a
    time ($ids/.cache/.pulling, a dir: one older than two minutes is a dead puller's)."""
    if os.environ.get("FLEET_ID_PULL", "1") == "0":
        return False
    lock = os.path.join(cache_dir(), ".pulling")
    try:
        os.makedirs(cache_dir(), exist_ok=True)
        os.mkdir(lock)
    except FileExistsError:
        try:
            if time.time() - os.path.getmtime(lock) < 120:
                return False
            os.utime(lock)
        except OSError:
            return False
    except OSError:
        return False
    sh = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fleet-id.sh")
    cmd = 'bash "$1" pull "${@:3}"; rmdir "$2"'
    try:
        subprocess.Popen(["bash", "-c", cmd, "bash", sh, lock] + [x for x in ids if is_fid(x)][:50],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    except OSError:
        try:
            os.rmdir(lock)
        except OSError:
            pass
        return False
    return True


# ---- the hook -------------------------------------------------------------------

def tmux(args):
    return subprocess.run(["tmux"] + args, text=True, capture_output=True, timeout=3).stdout.strip()


def wopt(pane, name):
    return tmux(["show-options", "-wqv", "-t", pane, name])


def wset(pane, name, value=None):
    if value is None:
        tmux(["set-option", "-wu", "-t", pane, name])
    else:
        tmux(["set-option", "-w", "-t", pane, name, value])


def window_fid(pane):
    f = wopt(pane, "@fleet_id")
    if is_fid(f):
        return f
    tmux(["set-option", "-wo", "-t", pane, "@fleet_id", str(uuid.uuid4())])
    f = wopt(pane, "@fleet_id")
    return f if is_fid(f) else ""


def hook_agent(pane):
    """claude | codex | None (not this pane's agent: a headless child, a stale launcher)."""
    owner = os.environ.get("FLEET_CODEX_LAUNCHER_PID", "")
    if owner:
        got = tmux(["display-message", "-p", "-t", pane, "#{@cc_agent}|#{@cc_launcher_pid}"])
        return "codex" if got == "codex|" + owner else None
    if os.environ.get("CLAUDE_CODE_ENTRYPOINT", "cli") != "cli":
        return None
    return "claude"


def hook_hint(pane, source):
    """handoff when the handoff cycle typed this /clear: its @id_next_trigger (fresh),
    else the cycle's own claim on the window (@handoff_cycle). reopen when the
    recovery page's ↵ or a restore relaunched the agent (`reopen:<epoch>`, EPIC T644
    C2) — read by any start but a compaction; a handoff mark waits for its /clear."""
    if source == "compact":
        return ""
    nt = wopt(pane, "@id_next_trigger")
    kind, _, at = nt.partition(":")
    fresh = at.isdigit() and time.time() - int(at) <= NEXT_TRIGGER_TTL
    if kind == "reopen":
        wset(pane, "@id_next_trigger")
        return "reopen" if fresh else ""
    if source != "clear":
        return ""
    if nt:
        wset(pane, "@id_next_trigger")
        if kind == "handoff" and fresh:
            return "handoff"
    return "handoff" if wopt(pane, "@handoff_cycle") else ""


def hook_retry_flush(pane, fid):
    raw = wopt(pane, "@id_retry")
    if not raw:
        return
    try:
        pend = json.loads(raw)
    except ValueError:
        pend = []
    left = []
    for p in pend if isinstance(pend, list) else []:
        try:
            if p.get("fid") == fid:
                record_native(fid, p["agent"], p["native"], p["source"], p.get("hint", ""))
        except (OSError, KeyError, TypeError, AttributeError):
            left.append(p)
    wset(pane, "@id_retry", json.dumps(left) if left else None)


def hook_timing_ready(pane):
    """A new session clocked from its ↵ (T684): the window's @timing_t0 is that ↵;
    the agent's native session is up now — `ready` under that run (fleet_timing.py),
    once: @timing_ready remembers it. The stamp stays for `input` (T716), which
    clears both; @timing_what names a node-clocked run (`session.node`)."""
    t0 = wopt(pane, "@timing_t0")
    if not t0 or wopt(pane, "@timing_ready") == t0:
        return
    wset(pane, "@timing_ready", t0)
    what = wopt(pane, "@timing_what")
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import fleet_timing
        if 0 < time.time() - float(t0) < 3600:
            fleet_timing.Run(what if what == "session.node" else "session", float(t0)).at("ready")
    except (ImportError, ValueError):
        pass


def fleet_server():
    """Whether this pane's tmux server is one of this login's fleets: its socket's
    label names a configured fleet ($FLEET_CONF_DIR/fleets/<label>)."""
    sock = os.environ.get("TMUX", "").split(",")[0]
    label = os.path.basename(sock)
    return bool(label) and os.path.isdir(os.path.join(conf_dir(), "fleets", label))


def hook(stdin):
    if os.environ.get("FLEET_ID_HOOK", "1") == "0":
        return
    pane = os.environ.get("TMUX_PANE", "")
    if not pane or not os.environ.get("TMUX"):
        return
    try:
        payload = json.loads(stdin or "{}")
    except ValueError:
        return
    if not isinstance(payload, dict):
        return
    native = payload.get("session_id")
    if not isinstance(native, str) or not native.strip():
        return
    agent = hook_agent(pane)
    if agent is None:
        return
    if agent == "codex":
        # Same authority check as @codex_identity's writer. Native background
        # SessionStart inherits our launcher and pane, but owns neither identity.
        native_reader = runpy.run_path(os.path.join(os.path.dirname(__file__), "fleet-codex-session.py"))
        if not native_reader['session_start_root'](native):
            return
    fid = window_fid(pane)
    if not fid:
        return
    source = payload.get("source") or "startup"
    hint = hook_hint(pane, source)
    try:
        if not os.path.exists(ledger_path(fid)):
            # A window opened before the ledger, or by a road that wrote no `opened`.
            # Only on one of this login's fleets (BCYB): a test's or a drill's tmux
            # server run with the real FLEET_CONF_DIR wrote 53 IDs here that no
            # window of the fleet ever carried, and the hub kept them open.
            if not fleet_server():
                return
            open_id(fid, {"lazy": True, "agent": agent, "window": tmux(["display-message", "-p", "-t", pane, "#{window_id}"])})
        hook_retry_flush(pane, fid)
        ev = record_native(fid, agent, native, source, hint)
        # the agent is up (T642): a start word the wrapper left is answered
        pg = fold(read(fid))["progress"]
        if pg and pg.get("state") in START_WORDS:
            record_progress(fid, "起来了", "started")
        hook_timing_ready(pane)
        if ev and ev.get("from") and ev.get("seg") == 1:
            # a new window that resumed another ID's segment is a new ID whose prev is
            # that one (S9; a spawn with --resume already wrote it — first value wins)
            open_id(fid, {"prev": ev["from"].split("#")[0]})
        # an old `T-…` stamp (compat-1v) is replaced by today's code on the next hook
        short = fold(read(fid))["opened"].get("short") or short_for(fid, known_ids([fid]))
        if short and wopt(pane, "@task_short") != short:
            wset(pane, "@task_short", short)
        push_later(fid)
    except OSError:
        raw = wopt(pane, "@id_retry")
        try:
            pend = json.loads(raw) if raw else []
        except ValueError:
            pend = []
        if not isinstance(pend, list):
            pend = []
        pend.append({"fid": fid, "agent": agent, "native": native, "source": source, "hint": hint})
        wset(pane, "@id_retry", json.dumps(pend[-20:]))


# ---- what a person reads --------------------------------------------------------

def hhmm(ts):
    return time.strftime("%m-%d %H:%M", time.localtime(ts)) if isinstance(ts, (int, float)) else "?"


def render(fid):
    rec = record(fid) or fold([])
    o = rec["opened"]
    short = o.get("short") or short_for(fid, known_ids())
    lines = ["%s  %s" % (short, fid)]
    bits = ["opened %s" % hhmm(o.get("ts"))]
    for k in ("agent", "repo", "key", "task", "title", "parent", "prev"):
        if o.get(k):
            bits.append("%s %s" % (k, o[k]))
    if rec.get("attempt", 1) > 1:
        bits.append("第 %d 次" % rec["attempt"])
    lines.append("  " + " · ".join(bits))
    for s in rec["segments"]:
        span = "%s–%s" % (hhmm(s["start"]), hhmm(s["end"]) if s["end"] else "")
        extra = ""
        if s["compactions"]:
            extra += "  压缩×%d" % s["compactions"]
        if s.get("from"):
            extra += "  from %s" % s["from"]
        if s.get("conflict"):
            extra += "  冲突: 与 %s 共用原生段" % s["conflict"]
        if s.get("attempt", 1) > 1:
            extra += "  第 %d 次" % s["attempt"]
        lines.append("  段 %d  %-6s %s  %s  %s%s" % (s["n"], s["agent"], s["native"], span, s["trigger"], extra))
    for r in rec["results"]:
        lines.append("  结果 %s  %s%s  %s" % (hhmm(r.get("ts")), r.get("state", ""),
                                             (" · PR #%s" % r["pr"]) if r.get("pr") else "", r.get("summary", "")))
    if rec["progress"]:
        p = rec["progress"]
        lines.append("  进度 %s  %s" % (hhmm(p.get("ts")), p.get("summary", "")))
    if rec["closed"]:
        lines.append("  结束 %s  %s" % (hhmm(rec["closed"]["ts"]), rec["closed"]["reason"]))
    return "\n".join(lines)


def main(argv):
    if not argv:
        print("usage: fleet_id.py short|display|open|native|result|progress|close|revive|get|resolve|push|hook|status|route|children|await|history|continue|reopen|family|parents|backfill …", file=sys.stderr)
        return 2
    cmd, args = argv[0], argv[1:]
    # Live windows' IDs ride in as FLEET_ID_LIVE (newline-separated): fleet-id.sh fills it.
    live = [x for x in os.environ.get("FLEET_ID_LIVE", "").split() if is_fid(x)]
    NOAGENT.update(x for x in os.environ.get("FLEET_ID_NOAGENT", "").split() if is_fid(x))
    if cmd == "hook":
        try:
            hook(sys.stdin.read())
        except Exception:   # never block the agent, never speak
            pass
        return 0
    if cmd == "push":
        return push([a for a in args if is_fid(a)])
    if cmd == "live":
        return live_report([x for x in os.environ.get("FLEET_ID_LIVE", "").split() if is_fid(x)],
                           dry="--dry" in args, as_json="--json" in args)
    if cmd == "pull":
        return pull([a for a in args if is_fid(a)], full="--full" in args)
    if cmd == "switch":
        if args[:1] and args[0] not in ("status", "on", "off"):
            return 2
        return switch_cmd(args[0] if args else "status")
    if cmd == "migrate":
        only = []
        for i, a in enumerate(args):
            if a == "--only" and i + 1 < len(args):
                only += [x.strip() for x in args[i + 1].split(",") if x.strip()]
        if any(not re.match(r"^T[1-9][0-9]{0,9}$", x) for x in only):
            print("fleet-id: --only takes task numbers T<n>,…", file=sys.stderr)
            return 2
        return migrate_cmd("--apply" in args, only, "--json" in args)
    if cmd == "parents":
        return parents_cmd("--apply" in args, [a for a in args if is_fid(a)])
    if cmd == "backfill":
        return backfill_cmd("--apply" in args, [a for a in args if is_fid(a)])
    if cmd == "encode" and args:
        print(encode(args[0]))
        return 0
    if cmd == "short" and args:
        if not is_fid(args[0]):
            return 2
        have = fold(read(args[0]))["opened"].get("short")
        print(have or short_for(args[0], known_ids(live)))
        return 0
    if cmd == "task-code" and args:
        c = task_code(args[0])
        if c:
            print(c)
        return 0 if c else 1
    if cmd == "display" and args:
        if not is_fid(args[0]):
            return 2
        print(shown(args[0]))
        return 0
    if cmd == "resolve" and args:
        rc, hits = resolve_open(args[0], open_ids(), live)
        if rc == 0:
            print(hits[0])
        elif rc == 2:
            every = known_ids(live)
            print("fleet-id: %s is ambiguous — %d IDs: %s" % (
                args[0], len(hits), ", ".join("%s (%s)" % (short_for(h, every), h) for h in hits)), file=sys.stderr)
        else:
            print("fleet-id: no ID answers to %s" % args[0], file=sys.stderr)
        return rc
    opts, pos = {}, []
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("--json", "--all"):
            pos.append(a)
            i += 1
        elif a.startswith("--") and i + 1 < len(args):
            opts[a[2:]] = args[i + 1]
            i += 2
        else:
            pos.append(a)
            i += 1
    if cmd == "title-audit":
        try:
            report = title_audit(opts.get("board", ""), opts.get("owner-proof", ""),
                                 opts.get("ledger-dir", ids_dir()).split(os.pathsep))
        except (OSError, ValueError) as e:
            print("fleet-id: audit refused: %s" % e, file=sys.stderr)
            return 1
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0
    if cmd in ("name-window", "title-window"):
        try:
            name_window(opts.get("window", ""), opts.get("title", ""), opts.get("source", "manual"),
                        opts.get("socket", ""), opts.get("fid", ""), rename=cmd == "name-window")
        except (OSError, ValueError, subprocess.SubprocessError) as e:
            print("fleet-id: rename failed: %s" % e, file=sys.stderr)
            return 1
        return 0
    if cmd == "history":
        lv = live if "FLEET_ID_LIVE" in os.environ else None
        rows = history_rows(lv, include_open="--all" in pos)
        flt = [p for p in pos if p != "--all" and p != "--json"]
        if flt:
            w = flt[0].lower()
            rows = [r for r in rows if w in (r["short"] + " " + r["id"] + " " + r["title"] + " " + r["summary"]).lower()]
        if "--json" in pos:
            print(json.dumps(rows, ensure_ascii=False))
            return 0
        for r in rows:
            print("%-9s %-6s %-9s %-11s %s" % (r["short"], r["label"], r["result"] or "-",
                                             hhmm(r["closed_at"]) if r["closed_at"] else "-", r["title"]))
        return 0
    tpos = [p for p in pos if not p.startswith("--")]
    if not tpos:
        return 2
    if cmd == "of-task":
        # this machine's newest ID opened for a record — its status row (T642)
        if not re.match(r"^T[1-9][0-9]{0,9}$", tpos[0]):
            return 2
        print(json.dumps(task_row(tpos[0], live if "FLEET_ID_LIVE" in os.environ else None), ensure_ascii=False))
        return 0
    target = tpos[0]
    if not is_fid(target):
        rc, hits = resolve(target, live)
        if rc != 0:
            return main(["resolve", target])
        target = hits[0]
    lv = live if "FLEET_ID_LIVE" in os.environ else None
    if cmd == "open":
        nat = opts.pop("from-native", "")
        if nat and not opts.get("prev"):
            # a new window resuming another ID's segment (S8 / S9): that ID is its prev
            own = owner_of(nat, skip=target)
            if own:
                opts["prev"] = own[0]
        print(open_id(target, opts, live))
        return 0
    if cmd == "take":
        # May a window opened here for a task go by the task's own ID (EPIC T644 C2)?
        got = take_task_id(target)
        print(got or "elsewhere")
        return 0 if got else 1
    if cmd == "attempt":
        n = next_attempt(target, opts.get("window", ""))
        print(n)
        return 0
    if cmd == "status":
        print(json.dumps(status(target, lv), ensure_ascii=False))
        return 0
    if cmd == "route":
        got, how = route(target, lv)
        print("%s\t%s" % (got, how))
        return 0 if got else 1
    if cmd == "children":
        rows = children_of(target, lv)
        if "--json" in pos or opts.get("json"):
            print(json.dumps(rows, ensure_ascii=False))
        else:
            for r in rows:
                res = r["result"] or {}
                print("%s  %s  %s%s  %s" % (r["short"], r["label"], res.get("state", "-"),
                                            (" · PR #%s" % res["pr"]) if res.get("pr") else "", r["title"]))
            print("%d children" % len(rows))
        return 0
    if cmd == "family":
        print(json.dumps(family(target, lv, seeds=[p for p in tpos[1:] if is_fid(p)]), ensure_ascii=False))
        return 0
    if cmd == "await":
        try:
            timeout = max(1, int(opts.get("timeout", "7200")))
            interval = max(1, int(opts.get("interval", "15")))
        except ValueError:
            return 2
        return await_id(target, timeout, interval, None)
    if cmd in ("continue", "reopen"):
        try:
            plan = continue_plan(target, opts.get("seg"))
        except ValueError as e:
            print("fleet-id: %s" % e, file=sys.stderr)
            return 1
        if cmd == "reopen":
            rec = fold(read(target))
            if alive(target, rec, lv):
                print("fleet-id: %s is still open in a window — nothing to reopen" % target, file=sys.stderr)
                return 1
            if opts.get("window"):
                append(target, {"ev": "reopened", "window": opts["window"]})
                push_later(target)
        print(json.dumps(plan, ensure_ascii=False))
        return 0
    if cmd == "native":
        ev = record_native(target, opts.get("agent", "claude"), opts.get("native", ""), opts.get("source", "startup"),
                           opts.get("hint", ""))
        if ev:
            print(json.dumps(ev, ensure_ascii=False))
        return 0
    if cmd == "result":
        ev = {"ev": "result", "state": opts.get("state", ""), "summary": opts.get("summary", "")}
        for k in ("pr", "agent"):
            if opts.get(k):
                ev[k] = opts[k]
        if opts.get("issues"):
            ev["issues"] = [x.strip() for x in opts["issues"].split(",") if x.strip()]
        append(target, ev)
        push_later(target)
        return 0
    if cmd == "start-word":
        # the wrapper's 「未起来」/「已掉」 (T642): WRITTEN, or SAME (already said, or over)
        word = opts.get("word", "")
        if word not in START_WORDS:
            print("fleet-id: start-word needs --word %s" % "|".join(START_WORDS), file=sys.stderr)
            return 2
        print("WRITTEN" if say_start(target, word, opts.get("why", "")) else "SAME")
        return 0
    if cmd == "progress":
        summary = opts.get("summary", "").strip()
        if not summary:
            print("fleet-id: progress needs a --summary", file=sys.stderr)
            return 2
        ev = record_progress(target, summary, opts.get("state", ""), opts.get("event", ""))
        if ev:
            push_later(target)
        print("RECORDED\nid: %s\nseq: %s" % (target, ev["seq"] if ev else "-"))
        return 0
    if cmd == "revive":
        # T847: an ID closed while a window here still carries it (a copy's reap ended
        # it, and with it the record) goes on — one `reopened` event naming that
        # window; the hub clears the close and puts back the record it had ended.
        # Only this machine's own ledger: an ID another machine holds is refused.
        if not os.path.exists(ledger_path(target)):
            print("fleet-id: %s has no ledger here — revive it on the machine that holds it" % target, file=sys.stderr)
            return 1
        def decide(evs):
            if fold(evs)["closed"] is None:
                return None
            ev = {"ev": "reopened"}
            if opts.get("window"):
                ev["window"] = opts["window"]
            return ev
        print("REOPENED" if append(target, None, decide=decide) else "OPEN")
        push_later(target)
        return 0
    if cmd == "close":
        def decide(evs):
            return None if fold(evs)["closed"] else {"ev": "closed", "reason": opts.get("reason", "")}
        append(target, None, decide=decide)
        push_later(target)
        return 0
    if cmd == "get":
        rec = record(target)
        if rec is None:
            # nothing here and nothing cached yet: ask for it in the background (C7)
            pull_later([target])
            print("fleet-id: %s has no ledger here (nothing cached yet — asked the hub)" % target, file=sys.stderr)
            return 1
        if opts.get("json") or "--json" in pos:
            print(json.dumps(rec, ensure_ascii=False))
        else:
            print(render(target))
        return 0
    print("fleet-id: unknown command %s" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
