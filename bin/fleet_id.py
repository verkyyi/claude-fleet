#!/usr/bin/env python3
"""fleet_id.py — the node's ID ledger: one window, one ID, its native segments
(EPIC T497 C1; design page §3, §4.1, §4.2).

A window's ID is its @fleet_id (a UUIDv4, minted once at spawn — fleet_fid_mint).
What a person reads is its SHORT CODE: `T-` + the ID's first characters in
lowercase Crockford base32 (no i l o u), 5 by default, one longer for as long as
another ID this login knows shares the prefix (like git's short SHA). An address
`T-<prefix>` resolves to every known ID whose code starts with it: one ⇒ that ID,
several ⇒ refused with the candidates (rc 2), never a pick.

The ledger is $FLEET_CONF_DIR/ids/<ID>.ndjson, one event a line, each with its
(ID, seq): `opened` (the spawn: agent, window, repo, title …), `native` (a native
session the window went through — a new segment, or `compact: true` counting one
compaction on the current segment), `result`, `closed`. Appends hold an flock;
seq is the line's number. The ledger is double-written beside the old task record
and nothing decides anything off it yet (EPIC rule: 先双写、后切换).

The SessionStart hook (`fleet-id.sh hook`, both agents — the Codex table is the
same one) appends segments by the rules of §4.2:
  claude startup   no segment ⇒ segment 1 (startup); same native id ⇒ nothing;
                   another ⇒ a new segment (resume: a restore that changed the id)
  claude resume    another id ⇒ a new segment (resume), with the ID/segment it came from
  claude clear     a new segment: handoff when the cycle marked it, else clear
  claude compact   the current segment counts one more compaction
  codex  (first turn of each thread) another id ⇒ a new segment; startup ⇒ new, resume ⇒ resume
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

ALPHABET = "0123456789abcdefghjkmnpqrstvwxyz"   # Crockford base32, lowercase
SHORT_MIN = 5
ADDR_MIN = 4
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
    """The ID's full code: 128 bits → 26 base32 characters, most significant first."""
    n = int(fid.replace("-", ""), 16) << 2   # 130 bits = 26 × 5
    return "".join(ALPHABET[(n >> (5 * (25 - i))) & 31] for i in range(26))


def norm_code(s):
    """A typed code → its canonical lowercase form, or None. Takes `T-` / `t-` or bare;
    Crockford's reading of i/l (1) and o (0); u is no digit."""
    s = (s or "").strip()
    if s[:2] in ("T-", "t-"):
        s = s[2:]
    s = s.lower().replace("i", "1").replace("l", "1").replace("o", "0")
    if len(s) < ADDR_MIN or len(s) > 26 or any(c not in ALPHABET for c in s):
        return None
    return s


def short_for(fid, known):
    """The shortest code (≥ SHORT_MIN) no other known ID shares, as `T-<code>`."""
    me = encode(fid)
    others = [encode(k) for k in known if is_fid(k) and k != fid]
    n = SHORT_MIN
    while n < 26 and any(o[:n] == me[:n] for o in others):
        n += 1
    return "T-" + me[:n]


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
    rec = {"opened": {}, "segments": [], "results": [], "closed": None}
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
        elif kind == "closed":
            rec["closed"] = {"ts": ev.get("ts"), "reason": ev.get("reason", "")}
            if rec["segments"] and rec["segments"][-1]["end"] is None:
                rec["segments"][-1]["end"] = ev.get("ts")
    if lazy:
        rec["opened"]["lazy"] = True
    return rec


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
    elif agent == "codex":
        trigger = "new"     # a new thread in the same Codex window (/new)
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
    code = norm_code(a)
    if code is None:
        return 1, []
    hits = sorted(f for f in known_ids(extra_known) if encode(f).startswith(code))
    if not hits:
        return 1, []
    return (0 if len(hits) == 1 else 2), hits


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
        record_native(fid, agent, native, source, hint)
        short = fold(read(fid))["opened"].get("short")
        if short and wopt(pane, "@task_short") != short:
            wset(pane, "@task_short", short)
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
    if rec["closed"]:
        lines.append("  结束 %s  %s" % (hhmm(rec["closed"]["ts"]), rec["closed"]["reason"]))
    return "\n".join(lines)


def main(argv):
    if not argv:
        print("usage: fleet_id.py short|open|native|result|close|get|resolve|hook …", file=sys.stderr)
        return 2
    cmd, args = argv[0], argv[1:]
    # Live windows' IDs ride in as FLEET_ID_LIVE (newline-separated): fleet-id.sh fills it.
    live = [x for x in os.environ.get("FLEET_ID_LIVE", "").split() if is_fid(x)]
    if cmd == "hook":
        try:
            hook(sys.stdin.read())
        except Exception:   # never block the agent, never speak
            pass
        return 0
    if cmd == "encode" and args:
        print(encode(args[0]))
        return 0
    if cmd == "short" and args:
        if not is_fid(args[0]):
            return 2
        have = fold(read(args[0]))["opened"].get("short")
        print(have or short_for(args[0], known_ids(live)))
        return 0
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
        if a.startswith("--") and i + 1 < len(args):
            opts[a[2:]] = args[i + 1]
            i += 2
        else:
            pos.append(a)
            i += 1
    if not pos:
        return 2
    target = pos[0]
    if not is_fid(target):
        rc, hits = resolve(target, live)
        if rc != 0:
            return main(["resolve", target])
        target = hits[0]
    if cmd == "open":
        print(open_id(target, opts, live))
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
        append(target, ev)
        return 0
    if cmd == "close":
        def decide(evs):
            return None if fold(evs)["closed"] else {"ev": "closed", "reason": opts.get("reason", "")}
        append(target, None, decide=decide)
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
