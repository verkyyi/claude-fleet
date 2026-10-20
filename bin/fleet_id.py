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
The hook never blocks the agent and never prints: a write that fails is kept on
the window (@id_retry) and flushed by the next hook.
"""
import fcntl
import json
import os
import re
import subprocess
import sys
import time
import uuid

ALPHABET = "0123456789abcdefghjkmnpqrstvwxyz"   # Crockford base32, lowercase — the old code (compat-1v)
DIGITS = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"     # the display code: Crockford base32, uppercase
LETTERS = "ABCDEFGHJKMNPQRSTVWXYZ"              # its first character: a letter, never a digit
SHORT_MIN = 4
ADDR_MIN = 4
LEGACY_MIN = 4   # an old `T-` address's least length (compat-1v)
CODE_SPAN = 22 * 32 ** 25   # 26 places: one letter, 25 base32 — more than 2^128, so no two IDs share a full code
FID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
TRIGGERS = ("startup", "clear", "handoff", "transfer", "resume", "new", "migrated")
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


def parse_code(s):
    """A typed code → (canonical code, legacy?) or None. `K3F9` / `#k3f9` / any case,
    Crockford's reading of I/L (1) and O (0), U no digit, the first character a letter;
    `T-…` / `t-…` is the old lowercase code (compat-1v: 下一批删)."""
    s = (s or "").strip()
    if s[:2] in ("T-", "t-"):
        s = s[2:].lower().replace("i", "1").replace("l", "1").replace("o", "0")
        if len(s) < LEGACY_MIN or len(s) > 26 or any(c not in ALPHABET for c in s):
            return None
        return s, True
    if s[:1] == "#":
        s = s[1:]
    s = s.upper().replace("I", "1").replace("L", "1").replace("O", "0")
    if len(s) < ADDR_MIN or len(s) > 26 or s[0] not in LETTERS or any(c not in DIGITS for c in s):
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
        return ev
    finally:
        os.close(fd)


def fold(events):
    """The ledger read as one record: opened fields (first value wins), segments,
    results, closed."""
    rec = {"opened": {}, "segments": [], "results": [], "closed": None, "progress": None}
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
                if k == "short" and not is_short(v):
                    continue   # an old `T-…` code (compat-1v): today's is recomputed from the ID
                if v not in (None, "") and k not in rec["opened"]:
                    rec["opened"][k] = v
        elif kind == "native":
            if ev.get("compact"):
                if rec["segments"]:
                    rec["segments"][-1]["compactions"] += 1
                continue
            seg = {"n": len(rec["segments"]) + 1, "agent": ev.get("agent", ""), "native": ev.get("native", ""),
                   "trigger": ev.get("trigger", ""), "start": ev.get("ts"), "end": None, "compactions": 0}
            for k in ("from", "conflict"):
                if ev.get(k):
                    seg[k] = ev[k]
            if rec["segments"]:
                rec["segments"][-1]["end"] = ev.get("ts")
            rec["segments"].append(seg)
        elif kind == "result":
            rec["results"].append({k: v for k, v in ev.items() if k not in ("ev", "id")})
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
    if source == "compact":
        if last and last["native"] == native:
            return {"ev": "native", "compact": True, "agent": agent, "native": native, "seg": last["n"]}
        trigger = "resume" if last else "startup"
    elif last and last["native"] == native and last["agent"] == agent:
        return None   # the same segment going on: a restore, a ↵, a retried hook
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
          "seg": len(segs) + 1}
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


def open_id(fid, fields, extra_known=()):
    """The spawn's `opened` (idempotent: a second one only fills what the first left)."""
    short = short_for(fid, known_ids(extra_known))
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


# ---- results, parents, successors (EPIC T497 C4; design page §4.3–§4.5) ----------
#
# What a window is doing is read off its ID, never off a task record's generation
# or a native process: a result is an event on the ledger (several are fine — the
# newest counts, S2), a window the fleet closed without one has 已退出 (S7), and a
# native segment live in two windows at once is a conflict in both until one of
# them closes (S9). A message or a child's report for an ID that has closed goes
# to its successor — the newest live ID whose `prev` it is, down the chain (S8:
# 「从这一段继续」 opens a new ID with `prev`) — else up its `parent`, else nobody
# here: the caller hands it to the person's reminder. A /clear, /compact, handoff
# or agent switch never changes the ID, so none of them loses a report.
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
    return rec["results"][-1] if rec["results"] else None


def _index():
    """Every ledger here, folded once: {ID: rec}."""
    return {f: fold(read(f)) for f in ledger_ids()}


def conflicts(fid, live, idx=None):
    """The other live IDs whose CURRENT segment is this ID's current segment (S9):
    both windows run one native session. Empty once either closes."""
    idx = idx if idx is not None else _index()
    rec = idx.get(fid) or fold(read(fid))
    if not rec["segments"] or not alive(fid, rec, live):
        return []
    mine = rec["segments"][-1]["native"]
    out = []
    for other, orec in idx.items():
        if other == fid or not orec["segments"] or not alive(other, orec, live):
            continue
        if orec["segments"][-1]["native"] == mine:
            out.append(other)
    return sorted(out)


def status(fid, live, idx=None):
    """{state, label, result, conflict}: the one word a reader shows for an ID.
    state ∈ running · conflict · done · failed · asking · exited (+ the result's own
    state in `result`). The newest result counts (S2); closed with none = exited (S7)."""
    idx = idx if idx is not None else _index()
    rec = idx.get(fid) or fold(read(fid))
    r = last_result(rec)
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
    """Who takes what was meant for fid → (ID, how): how = self · successor · parent ·
    '' (nobody here: the person's reminder) · unknown (no ledger here — the caller's
    old road, e.g. another machine's ID)."""
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

    cur, how = fid, "self"
    while cur and cur not in seen:
        seen.add(cur)
        rec = idx.get(cur)
        if rec is None:
            return cur, "unknown"
        if alive(cur, rec, live):
            return cur, how
        nxt = down(cur)
        if nxt:
            return nxt, "successor" if how == "self" else how
        cur, how = rec["opened"].get("parent", ""), "parent"
        if cur and not is_fid(cur):
            cur = ""
    return "", ""


def children_of(fid, live, idx=None):
    idx = idx if idx is not None else _index()
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
    """Backfill (EPIC T497 C9): an ID opened for a task T<n> whose `opened` names no
    parent — a `task` dispatch before C9 — takes the parent its record names. Dry
    unless apply; an applied one is a fill-only `opened` (the hub folds it the same
    way) and is pushed. rc 3 no hub here."""
    n = done = 0
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
        if apply:
            open_id(fid, {"parent": par})
            push_later(fid)
            done += 1
        print("%s  %s  → %s%s" % (code, task, par, "" if apply else "  (dry)"))
    print("%d without a parent · %d %s" % (n, done, "filled" if apply else "to fill (--apply)"))
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
    rec = {"opened": {"short": hub_short(fid, ans.get("short", "")), "title": ans.get("title", ""), "parent": ans.get("parent", ""),
                      "prev": ans.get("prev", "")}, "segments": [], "closed": None,
           "results": [{"state": r.get("state", ""), "summary": r.get("summary", ""), "pr": r.get("pr", ""),
                        "ts": r.get("at")} for r in ans.get("results") or [] if isinstance(r, dict)]}
    if ans.get("closed_at"):
        rec["closed"] = {"ts": ans["closed_at"], "reason": ans.get("close_reason", "")}
    pg = ans.get("progress")
    rec["progress"] = {"summary": pg.get("summary", ""), "state": pg.get("state", ""), "ts": pg.get("at"),
                       "seq": pg.get("seq")} if isinstance(pg, dict) and pg.get("summary") else None
    return rec


def _family_row(fid, rec, st, src):
    o = rec["opened"]
    return {"id": fid, "short": st["short"], "task": o.get("task", ""), "title": o.get("title", ""),
            "parent": o.get("parent", ""), "prev": o.get("prev", ""), "opened_at": o.get("ts"),
            "state": st["state"], "label": st["label"], "alive": st["alive"], "result": st["result"],
            "closed": rec["closed"], "src": src, "segments": len(rec["segments"]), "progress": rec.get("progress"),
            **({"agent": False} if st.get("agent") is False else {})}


def _hub_status(fid, rec, short):
    """status()'s reading of a hub-mirror record (no window here to ask)."""
    r = next((x for x in reversed(rec["results"]) if x.get("state") not in SILENT_STATES), None) \
        or last_result(rec)
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
    idx = idx if idx is not None else _index()
    line = lineage_of(fid, idx)
    seeds = [x for x in dict.fromkeys(seeds) if is_fid(x) and x not in line]
    rows, seen = {}, set(line)
    first = []
    for x in seeds:
        if x in idx:
            seen.add(x)
            first.append(x)
            rows[x] = _family_row(x, idx[x], status(x, live, idx), "local")
    frontier, key = list(line), "parent"
    while frontier:
        nxt, first = first, []
        for f in frontier:
            for other, o in idx.items():
                if other not in seen and o["opened"].get(key) == f:
                    seen.add(other)
                    nxt.append(other)
                    rows[other] = _family_row(other, o, status(other, live, idx), "local")
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
            p = dict(p, src="local") if p else None
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


def continue_plan(fid, seg=None):
    """What 「从这一段继续」 (a new window, a new ID, prev = fid — S8) or 「恢复这个窗口」
    (the same ID, its newest segment) resumes: {native, agent, seg, worktree, repo, title,
    task, parent} — the record and the parent ride along (C18): a driver's successor
    still owns its batch."""
    rec = fold(read(fid))
    segs = rec["segments"]
    if not segs:
        raise ValueError("%s has no native segment to resume" % fid)
    n = len(segs) if seg is None else int(seg)
    if n < 1 or n > len(segs):
        raise ValueError("%s has segments 1..%d, not %s" % (fid, len(segs), seg))
    s = segs[n - 1]
    o = rec["opened"]
    return {"id": fid, "seg": n, "native": s["native"], "agent": s["agent"], "worktree": o.get("worktree", ""),
            "repo": o.get("repo", ""), "title": o.get("title", ""), "closed": rec["closed"] is not None,
            "task": o.get("task", ""), "parent": o.get("parent", "")}


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
    while True:
        events = [e for e in read(fid) if isinstance(e.get("seq"), int)]
        todo = [e for e in events if e["seq"] > seq][:PUSH_BATCH]
        if not todo:
            _hub_set(fid, seq)
            return 0
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
    else the cycle's own claim on the window (@handoff_cycle)."""
    if source != "clear":
        return ""
    nt = wopt(pane, "@id_next_trigger")
    if nt:
        wset(pane, "@id_next_trigger")
        kind, _, at = nt.partition(":")
        if kind == "handoff" and at.isdigit() and time.time() - int(at) <= NEXT_TRIGGER_TTL:
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
    fid = window_fid(pane)
    if not fid:
        return
    source = payload.get("source") or "startup"
    hint = hook_hint(pane, source)
    try:
        if not os.path.exists(ledger_path(fid)):
            # A window opened before the ledger, or by a road that wrote no `opened`.
            open_id(fid, {"lazy": True, "agent": agent, "window": tmux(["display-message", "-p", "-t", pane, "#{window_id}"])})
        hook_retry_flush(pane, fid)
        ev = record_native(fid, agent, native, source, hint)
        # the agent is up (T642): a start word the wrapper left is answered
        pg = fold(read(fid))["progress"]
        if pg and pg.get("state") in START_WORDS:
            record_progress(fid, "起来了", "started")
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
    rec = fold(read(fid))
    o = rec["opened"]
    short = o.get("short") or short_for(fid, known_ids())
    lines = ["%s  %s" % (short, fid)]
    bits = ["opened %s" % hhmm(o.get("ts"))]
    for k in ("agent", "repo", "key", "task", "title", "parent", "prev"):
        if o.get(k):
            bits.append("%s %s" % (k, o[k]))
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
        print("usage: fleet_id.py short|open|native|result|progress|close|get|resolve|push|hook|status|route|children|await|history|continue|reopen|family|parents|backfill …", file=sys.stderr)
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
    if cmd == "resolve" and args:
        rc, hits = resolve(args[0], live)
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
    if cmd == "close":
        def decide(evs):
            return None if fold(evs)["closed"] else {"ev": "closed", "reason": opts.get("reason", "")}
        append(target, None, decide=decide)
        push_later(target)
        return 0
    if cmd == "get":
        if not os.path.exists(ledger_path(target)):
            print("fleet-id: %s has no ledger here" % target, file=sys.stderr)
            return 1
        if opts.get("json") or "--json" in pos:
            print(json.dumps(fold(read(target)), ensure_ascii=False))
        else:
            print(render(target))
        return 0
    print("fleet-id: unknown command %s" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
