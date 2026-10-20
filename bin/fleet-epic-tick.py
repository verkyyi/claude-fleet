#!/usr/bin/env python3
"""fleet-epic-tick.py — one EPIC batch, read off the hub (issue #4957).

An EPIC is a parent hub task (T<n>) whose record holds the charter (its
dispatch body), and its members are child tasks (`parent_task`). This is the
deterministic half of /fleet-epic-run's tick and /fleet-epic-report's gather:
it reads the parent's record and its children and says, for every member of the
charter, where it stands and what to dispatch next. It reads only the hub — no
gh, no GitHub, no tmux, no local book — so a driver that lost its context
re-reads the whole batch with one call.

  fleet-epic-tick.py status [--task T<n>] [--cap N] [--line]
      --task  the parent; default: this window's own @task (the driver's record)
      --cap   how many members may run at once (default: the charter's cap=, else 4)
      --line  one human line instead of the JSON

The charter (written by /fleet-epic-plan, the parent's body):

  <!-- fleet:epic repo=<owner/name> short=<简称> agent=<claude|codex> cap=<N> -->
  - [ ] **C1** <title>                       a core member in the marker's repo
  - [ ] **C2** <owner/name> — <title> (codex) one in another repo, on Codex
  - [ ] **R1** <title>                       reserve: never dispatched by itself
  ## C1 · <title>                            its detail, handed to its session

A member's child task is titled `<key> · <title>`; a child whose title carries a
key the charter does not list (`C5 · …`, a member added within scope) is a
member too.

By ID (EPIC T497 C5). Every session is a window ID (`@fleet_id`, short code
`T-xxxxx` — docs/dev/FLEET-ID.md): the parent's ID is the driver's (the second
half of the parent record's worker_id), each child's is its record's. One read of
`fleet-id.sh family <parent ID>` (this machine's ledgers + the hub mirror's
`?parent=`) gives every member's ID, its results, and every ID that continued it
down `prev` — a redo dispatched with `<!-- fleet:prev <ID> -->` in its body (the
spawner records it), or a 「从这一段继续」 from /fleet-history with no record of its
own. A member is its chain of batons (its records, oldest first, each followed by
the IDs that continued it); the newest baton is where it stands. A baton's outcome
is its record's when the record has one, else its ID's newest result (merged /
succeeded ⇒ succeeded, failed ⇒ failed), else — the ID closed with no result —
`exited`, counted as a failure. A record with no worker_id (the ID switch
dispatches records nobody claims — C14) is the family's ID opened on it (`task`),
the newest down `prev` when several were. The driver is its whole LINE (C18): the
parent's ID — else, a parent record nobody claims, the ID this machine opened for
it (`task`) where its prev chain starts — and every ID that continued it down
`prev` (a 「从这一段继续」 successor; `lineage` in the answer). A child record the
hub does not file under the parent (a successor's dispatch carries
parent_session only) is still a member when its ID's `parent` is on the line, and
`last_tick` is the newest word down the line. No family (no hub, an old hub, no
IDs) ⇒ the records alone, as before.

Per member, off its batons:
  succeeded  one baton succeeded
  running    the newest baton has no outcome yet
  retry      one failed — dispatch it once more (the retry rule), prev = its ID
  blocked    failed twice, or cancelled (the person stopped it), or a member it
             waits on is blocked
  waiting    unstarted, and a member it depends on has not succeeded yet
  unstarted  no baton yet
Dependencies are the charter's `## 依赖顺序` table (`| C5 | C4 | |`, `C1–C6` a
range), else a section's `**依赖** 依赖 C4 · 被依赖 …` line; only a BARE `C<n>` is
this batch's member. A key behind a `T<n>` — `T542 C5`, `T542 C7、C8` (the prefix
holds over the keys that follow it, until other words or a `+` / `;`) — is the
member of ANOTHER batch: released once that parent's child task titled `C5 · …`
succeeded, waited on otherwise (`waits_on` names it `T542 C5`), never a node of
this batch's graph and never let through by the cycle rule (each member's
`outside` lists them with `done`, so a released one is said, not dropped); a key behind `#<n>`
(a GitHub ticket) is the driver's to judge and ignored here. A dependency is
released by its member's newest baton — by ID, not by which record it was (拍板 6).
`next` is what to dispatch now: retries first, then unstarted core members in
charter order, as many as the free slots (cap − running). `done` is true when
every core (and added) member is succeeded or blocked and nothing runs.
`last_tick` is the driver's newest progress word: its ID's (`fleet-id.sh progress`,
which `fleet_task_control.py progress` writes with the ID switch on — EPIC T497
C12), else the record's `progress` from before the switch (`last_tick_src` id |
record); `report` is that word's `report: <pending | link>` (fleet-epic-run §4).
`mark` is what the heartbeat stamps the batch as: the parent's short code
(`T-xxxxx`), else its record `T<n>`.

Exit: 0 read · 1 the hub did not answer · 2 usage / no parent / no charter ·
3 no hub here (fleet-task-record.sh exit 3).
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

BIN = Path(__file__).resolve().parent
TREF = re.compile(r"^T[1-9][0-9]{0,9}$")
MARK = re.compile(r"<!--\s*fleet:epic\b([^>]*)-->")
LINE = re.compile(r"^\s*[-*] \[[ xX]\] \*\*([CR][1-9][0-9]*)\*\*\s+(.+?)\s*$")
REPO = re.compile(r"^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\s+(?:—|--|-)\s+(.+)$")
AGENT = re.compile(r"^(.*?)\s*\((codex|claude)\)$")
HEAD = re.compile(r"^#{2,4}\s+")
# a closing tick's `report: <pending | link>` (fleet-epic-run §4, issue #852)
REPORT_RE = re.compile(r"(?:^|·)\s*report:\s*([^\s·]+)")
FID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
DEPS_HEAD = re.compile(r"^#{2,4}\s+依赖")
# a dependency cell, token by token: an outside batch's parent (T<n>) or ticket
# (#<n>) scopes the keys right after it; only these between them keep the scope
DEP_TOK = re.compile(r"(?<![A-Za-z0-9])(?:(?P<scope>T[1-9][0-9]{0,9}|#[1-9][0-9]*)"
                     r"|(?P<a>[CR])(?P<lo>[1-9][0-9]*)(?:\s*[–—~-]\s*[CR]?(?P<hi>[1-9][0-9]*))?)(?![0-9])")
DEP_GLUE = re.compile(r"^[\s、,，/:：]*$")
DEP_LINE = re.compile(r"\*\*依赖\*\*\s*依赖\s*(.*?)(?:·|$)")
FAILED = ("failed", "refused", "exited")
KEYED = re.compile(r"^([CR][1-9][0-9]*)\s*·\s*(.*)$")
TITLE_MAX = 200


class Fail(Exception):
    def __init__(self, rc, msg):
        super().__init__(msg)
        self.rc = rc


def record(*args):
    p = subprocess.run(["bash", str(BIN / "fleet-task-record.sh")] + list(args),
                       capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    if p.returncode == 3:
        raise Fail(3, "no hub here")
    if p.returncode:
        raise Fail(1, (p.stderr.strip() or "the hub did not answer").splitlines()[-1])
    try:
        return json.loads(p.stdout)
    except ValueError:
        raise Fail(1, "the hub's answer is not JSON")


def own_task():
    p = subprocess.run(["bash", str(BIN / "fleet-task-record.sh"), "of"], capture_output=True, text=True,
                       timeout=10, stdin=subprocess.DEVNULL)
    t = p.stdout.strip()
    if p.returncode or not TREF.match(t):
        raise Fail(2, "this window carries no task (@task): name the parent with --task T<n>")
    return t


def id_of(task):
    """A record's window ID: the second half of its worker_id (`<fleet>/<ID>`)."""
    for k in ("worker_id", "execution_owner"):
        tail = str(task.get(k) or "").rpartition("/")[2]
        if FID.match(tail):
            return tail
    return ""


def claimed_by(task, fam):
    """A record's ID: its worker_id's, else — a record the ID switch dispatched
    stays accepted and is never claimed (EPIC T497 C14) — the family's ID opened
    on it (`task`), the newest down `prev` when several were."""
    fid = id_of(task)
    if fid or not task.get("id"):
        return fid
    mine = [r for r in fam if r.get("task") == task["id"]]
    if not mine:
        return ""
    prevs = {r.get("prev") for r in mine}
    tips = [r for r in mine if r["id"] not in prevs] or mine
    return max(tips, key=lambda r: r.get("opened_at") or 0)["id"]


def task_root(ref):
    """The ID this machine opened for the record `ref` where its line starts (an
    unclaimed parent record — the ID switch, C14/C18); '' when none."""
    sys.path.insert(0, str(BIN))
    try:
        import fleet_id
        return fleet_id.task_root(ref)
    except (ImportError, OSError, ValueError):
        return ""
    finally:
        sys.path.pop(0)


def adopted(rows, line, have):
    """Child records the driver's LINE spawned that the hub does not file under the
    parent (C18): an ID whose `parent` is any ID of the line, opened for a record
    T<n> (its `task`) not among `have` — a 「从这一段继续」 successor's dispatches
    carry parent_session only. Each record read once; an unreadable one skipped."""
    out, seen = [], set(have)
    for r in rows:
        t = str(r.get("task") or "")
        if r.get("parent") not in line or not TREF.match(t) or t in seen:
            continue
        seen.add(t)
        try:
            c = (record("get", t).get("task") or {})
        except (Fail, OSError, subprocess.SubprocessError):
            continue
        if c.get("id") == t:
            out.append(c)
    return out


def code_of(fid):
    """An ID with no record anywhere still has a code: its first five (fleet_id.py's
    encoding — a longer one only where the ledger or the hub says so)."""
    if not fid:
        return ""
    sys.path.insert(0, str(BIN))
    try:
        import fleet_id
        return "T-" + fleet_id.encode(fid)[:fleet_id.SHORT_MIN]
    except (ImportError, ValueError):
        return ""
    finally:
        sys.path.pop(0)


def family_of(pid, seeds=()):
    """`fleet-id.sh family <pid> <member ID>…` — {} when there is no ID, no hub, or
    no answer. The seeds are the children's own IDs: a ledger may name no parent."""
    if not pid:
        return {}
    try:
        p = subprocess.run(["bash", str(BIN / "fleet-id.sh"), "family", pid] + list(seeds), capture_output=True, text=True,
                           timeout=60, stdin=subprocess.DEVNULL)
        got = json.loads(p.stdout) if p.returncode == 0 else {}
    except (OSError, subprocess.SubprocessError, ValueError):
        return {}
    return got if isinstance(got, dict) else {}


def charter_of(task):
    """The parent's charter: the body it was dispatched with."""
    raw = task.get("request_payload") or ""
    try:
        payload = json.loads(raw) if isinstance(raw, str) else dict(raw)
    except ValueError:
        payload = {}
    return str(payload.get("body") or "")


def parse_charter(text):
    meta = {}
    m = MARK.search(text)
    if m:
        for word in m.group(1).split():
            k, _, v = word.partition("=")
            if v:
                meta[k] = v
    members, order = {}, []
    for line in text.splitlines():
        m = LINE.match(line)
        if not m or m.group(1) in members:
            continue
        key, rest = m.group(1), m.group(2)
        repo, agent = meta.get("repo", ""), ""
        a = AGENT.match(rest)
        if a:
            rest, agent = a.group(1), a.group(2)
        r = REPO.match(rest)
        if r:
            repo, rest = r.group(1), r.group(2)
        members[key] = dict(key=key, title=rest.strip(), repo=repo.lower(), agent=agent or meta.get("agent", ""),
                            layer="reserve" if key.startswith("R") else "core", detail=detail(text, key))
        order.append(key)
    return meta, [members[k] for k in order]


def detail(text, key):
    """The `## <key> · …` section of the charter, heading to next heading."""
    out, on = [], False
    for line in text.splitlines():
        if HEAD.match(line):
            if on:
                break
            on = bool(re.match(r"^#{2,4}\s+" + re.escape(key) + r"\b", line))
        if on:
            out.append(line)
    return "\n".join(out).strip()


def dep_refs(text, self_ref=""):
    """[(scope, key)] in order: scope "" for a bare key (this batch), `T<n>` for
    another batch's member, `#<n>` for a ticket's. `self_ref` (this batch's own
    T<n>) written as a prefix is the same as none."""
    out, scope, end = [], "", 0
    for m in DEP_TOK.finditer(text):
        if not DEP_GLUE.match(text[end:m.start()]):
            scope = ""
        end = m.end()
        if m.group("scope"):
            scope = "" if m.group("scope") == self_ref else m.group("scope")
            continue
        a, lo, hi = m.group("a"), int(m.group("lo")), int(m.group("hi") or m.group("lo"))
        out += [(scope, "%s%d" % (a, i)) for i in range(lo, hi + 1)]
    return out



def parse_deps(text, members, self_ref=""):
    """({key: [keys it waits on]}, {key: [(T<n>, key) of other batches]}) off the
    `## 依赖顺序` table, else each section's `**依赖**` line; local ones only the
    charter's own member keys, never itself; `#<n>` ones dropped."""
    known = {m["key"] for m in members}
    deps, on = {}, False
    for line in text.splitlines():
        if HEAD.match(line):
            on = bool(DEPS_HEAD.match(line))
            continue
        if not on or not line.strip().startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) >= 2 and cells[0] in known:
            deps[cells[0]] = cells[1]
    for m in members:
        if m["key"] not in deps:
            d = DEP_LINE.search(m.get("detail") or "")
            if d:
                deps[m["key"]] = d.group(1)
    out, ext = {}, {}
    for k, cell in deps.items():
        refs = list(dict.fromkeys(dep_refs(cell, self_ref)))
        got = [x for sc, x in refs if not sc and x in known and x != k]
        far = [(sc, x) for sc, x in refs if sc.startswith("T")]
        if got:
            out[k] = got
        if far:
            ext[k] = far
    return out, ext


def outside_done(ext):
    """{(T<n>, key): True when that batch's member succeeded} — each outside parent
    read the way this batch is (batch_of + judge: a redo's newest baton, an ID's
    result the record does not carry yet); an unreadable one counts as not done
    (waited on)."""
    done = {}
    for ref in sorted({sc for refs in ext.values() for sc, _ in refs}):
        try:  # the parent's record only names its ID; its children are the batch
            parent = record("get", ref).get("task") or {}
        except (Fail, OSError, subprocess.SubprocessError):
            parent = {}
        try:
            _, children, _, _, rows, _ = batch_of(ref, parent)
        except (Fail, OSError, subprocess.SubprocessError):
            continue
        by_key = {}
        for c in children:
            k, _ = child_key(c)
            if k:
                by_key.setdefault(k, []).append(c)
        for k, kids in by_key.items():
            if judge(dict(key=k), kids, rows)["state"] == "succeeded":
                done[(ref, k)] = True
    return done


def projected(children):
    """An open child's outcome off its own record read: with the ID switch on the
    hub projects the window ID's result there, never into `children` (T622 — T542's
    C5 merged, yet its children row still said accepted). One read per open child;
    an unreadable one stays open."""
    for c in children:
        if c.get("outcome") or not TREF.match(str(c.get("id") or "")):
            continue
        try:
            t = record("get", c["id"]).get("task") or {}
        except (Fail, OSError, subprocess.SubprocessError):
            continue
        if t.get("id") == c["id"] and t.get("outcome"):
            c["outcome"], c["state"] = t["outcome"], t.get("state") or c.get("state")
    return children


def batch_of(parent_ref, parent):
    """One batch's children as the tick judges them: the hub's list, the ones the
    driver's line adopted (C18), each open one's projected outcome, oldest first —
    with the parent's ID, its family and ID rows. Own batch and outside batches alike."""
    kids = record("children", parent_ref)
    children = list(kids.get("children") or [])
    # the parent's ID: its record's worker_id, else — a record the ID switch never
    # claims — the ID this machine opened for it, where its line starts (C18)
    pid = id_of(parent) or task_root(parent_ref)
    fam = family_of(pid, [i for i in (id_of(c) for c in children) if i])
    rows = [r for r in fam.get("ids") or [] if isinstance(r, dict) and FID.match(str(r.get("id", "")))]
    line = [x for x in fam.get("lineage") or [pid] if x]
    children += adopted(rows, line, {c.get("id") for c in children})
    children = sorted(projected(children), key=lambda c: int(str(c.get("id", "T0"))[1:] or 0))
    return kids, children, pid, fam, rows, line


def child_key(child):
    m = KEYED.match(str(child.get("title") or ""))
    return (m.group(1), m.group(2).strip()) if m else (None, "")


def child_pr(child):
    try:
        ev = json.loads(child.get("evidence") or "{}")
    except ValueError:
        ev = {}
    pr = str((ev.get("pr") if isinstance(ev, dict) else "") or child.get("pr") or "")
    return pr


def batons_of(kids, fam):
    """A member's chain: its records oldest first, each followed by the IDs that
    continued it down `prev` (a redo, a 「从这一段继续」) — newest last."""
    rows = {r["id"]: r for r in fam}
    placed = set()
    out = []

    def add(task, outcome, pr, fid):
        row = rows.get(fid) if fid else None
        if not outcome and row:
            outcome = {"done": "succeeded", "failed": "failed", "exited": "exited"}.get(row.get("state"), "")
        if not pr and row:
            pr = str((row.get("result") or {}).get("pr") or "")
        out.append(dict(task=task, outcome=outcome, pr=pr, id=fid, short=(row or {}).get("short", "") or code_of(fid),
                        prev=(row or {}).get("prev", "")))
        if fid:
            placed.add(fid)
            for r in fam:
                if r.get("prev") == fid and r["id"] not in placed and r["id"] not in kid_ids:
                    add(r.get("task", ""), "", "", r["id"])

    kid_ids = {claimed_by(c, fam) for c in kids} - {""}
    for c in kids:
        fid = claimed_by(c, fam)
        if fid in placed:
            continue
        add(c.get("id"), c.get("outcome") or "", child_pr(c), fid)
    return out


def judge(member, kids, fam=()):
    tasks = batons_of(kids, list(fam))
    member["tasks"] = tasks
    won = [t for t in tasks if t["outcome"] == "succeeded"]
    failed = [t for t in tasks if t["outcome"] in FAILED]
    last = tasks[-1] if tasks else {}
    member.update(id=last.get("id", ""), short=last.get("short", ""),
                  ids=[dict(id=t["id"], short=t["short"], task=t["task"], prev=t["prev"], outcome=t["outcome"])
                       for t in tasks if t["id"]])
    if won:
        member.update(state="succeeded", task=won[0]["task"], pr=won[0]["pr"], id=won[0]["id"] or member["id"],
                      short=won[0]["short"] or member["short"])
    elif tasks and not last["outcome"]:
        member.update(state="running", task=last["task"])
    elif any(t["outcome"] == "cancelled" for t in tasks) or len(failed) >= 2:
        member.update(state="blocked", task=last["task"])
    elif failed:
        member.update(state="retry", task=last["task"])
    else:
        member.update(state="unstarted", task="")
    return member


def hold_on_deps(members, deps, ext=None, ext_done=None):
    """An unstarted member whose dependencies have not all succeeded waits; one whose
    dependency is blocked is blocked too. Another batch's member (`ext`) holds it
    until `ext_done` says it succeeded. A cycle among this batch's own members
    (everything waiting, nothing to run) is let through rather than stalled — never
    a member still waiting on another batch, directly or through this batch's
    members it waits on: both halves must hold before a member is due."""
    ext, ext_done = ext or {}, ext_done or {}
    by = {m["key"]: m for m in members}
    for _ in range(len(members) + 1):
        moved = False
        for m in members:
            if m["state"] not in ("unstarted", "waiting") or (m["key"] not in deps and m["key"] not in ext):
                continue
            ds = [by[d] for d in deps.get(m["key"], []) if d in by]
            stuck = [d["key"] for d in ds if d["state"] == "blocked"]
            open_ = [d["key"] for d in ds if d["state"] != "succeeded"]
            open_ += ["%s %s" % r for r in ext.get(m["key"], []) if not ext_done.get(tuple(r))]
            if stuck:
                new = dict(state="blocked", blocked_by=stuck)
            elif open_:
                new = dict(state="waiting", waits_on=open_)
            else:
                new = dict(state="unstarted")
            if m["state"] != new["state"] or m.get("waits_on") != new.get("waits_on"):
                moved = True
            m.pop("waits_on", None)
            m.pop("blocked_by", None)
            m.update(new)
        if not moved:
            break
    live = [m for m in members if m["layer"] != "reserve" and m["state"] in ("running", "retry", "unstarted")]
    if not live:
        # a member waiting on another batch — itself, or through any of this
        # batch's members it waits on — is held, not a cycle (T599: C6 ← C4 ← T542 C5)
        held = {m["key"] for m in members if m["state"] == "waiting" and any(" " in w for w in m.get("waits_on", []))}
        while True:
            more = {m["key"] for m in members if m["state"] == "waiting" and m["key"] not in held
                    and any(w in held for w in m.get("waits_on", []))}
            if not more:
                break
            held |= more
        for m in members:
            if m["state"] == "waiting" and m["key"] not in held:
                m["state"] = "unstarted"
                m["cycle"] = True


def dispatch_of(parent, member):
    title = "%s · %s" % (member["key"], member["title"])
    if len(title) > TITLE_MAX:
        title = title[:TITLE_MAX - 1] + "…"
    body = ["父任务 %s（%s）的成员 %s：%s。" % (parent["id"], parent.get("title", ""), member["key"], member["title"]),
            "做完开 PR，门禁绿了自己合并，然后 report merged；做不成就 report failed 写清原因。"]
    if member.get("detail"):
        body += ["", member["detail"]]
    retry = member["state"] == "retry"
    if retry:
        who = member["task"] or member.get("short") or "上一棒"
        if member.get("short") and member["task"]:
            who = "%s，编号 %s" % (member["task"], member["short"])
        body += ["", "这是重试：上一次（%s）失败了，先读它的结果再动手。" % who]
        if member.get("id"):
            # the spawner reads this into the new window's ledger as its prev
            # (dash-raw-session.sh): the redo is the next baton of the same member
            body += ["<!-- fleet:prev %s -->" % member["id"]]
    return dict(key=member["key"], title=title, repo=member["repo"], agent=member["agent"],
                retry_of=member["task"] if retry else "", prev=member.get("id", "") if retry else "",
                body="\n".join(body))


def status(parent_ref, cap):
    got = record("get", parent_ref)
    parent = got.get("task") or {}
    if parent.get("authority_version") != 1:
        raise Fail(2, "%s is not an authoritative task: an EPIC is a parent task opened by /fleet-epic-plan" % parent_ref)
    text = charter_of(parent)
    meta, members = parse_charter(text)
    if not members:
        raise Fail(2, "%s's record has no charter member list (- [ ] **C1** …)" % parent_ref)
    kids, children, pid, fam, rows, line = batch_of(parent_ref, parent)
    by_key = {}
    for c in children:
        k, t = child_key(c)
        if k:
            by_key.setdefault(k, []).append(c)
    known = {m["key"] for m in members}
    for c in children:  # a member added within scope: its child carries a key the charter lacks
        k, t = child_key(c)
        if k and k not in known:
            known.add(k)
            members.append(dict(key=k, title=t, repo=str(c.get("repo") or "").lower(), agent="",
                                layer="added", detail=""))
    for m in members:
        judge(m, by_key.get(m["key"], []), rows)
    deps, ext = parse_deps(text, members, parent_ref)
    ext_done = outside_done(ext)
    hold_on_deps(members, deps, ext, ext_done)
    for m in members:   # another batch's members it depends on, and whether each merged
        if ext.get(m["key"]):
            m["outside"] = [dict(ref="%s %s" % r, done=bool(ext_done.get(tuple(r)))) for r in ext[m["key"]]]
    if cap is None:
        try:
            cap = int(meta.get("cap", "4"))
        except ValueError:
            cap = 4
    cap = max(1, cap)
    counted = [m for m in members if m["layer"] != "reserve"]
    running = sum(1 for m in members if m["state"] == "running")
    free = max(0, cap - running)
    pending = [m for m in counted if m["state"] == "retry"] + [m for m in counted if m["state"] == "unstarted"]
    nxt = [dispatch_of(parent, m) for m in pending if m["repo"]][:free]
    norepo = [m["key"] for m in pending if not m["repo"]]
    counts = dict(core=len(counted), succeeded=0, running=0, retry=0, blocked=0, unstarted=0, waiting=0)
    for m in counted:
        counts[m["state"]] += 1
    done = running == 0 and all(m["state"] in ("succeeded", "blocked") for m in counted)
    # the newest tick: the parent's ID's progress word (EPIC T497 C12), else — an ID
    # with none yet, or no ID — the one its record kept before the switch
    progress = fam.get("progress") or got.get("progress") or {}
    last = str(progress.get("summary") or "")
    rep = REPORT_RE.search(last)
    pshort = str(fam.get("short") or code_of(pid)) if pid else ""
    return dict(parent=parent_ref, parent_id=pid, parent_short=pshort, mark=pshort or parent_ref, lineage=line,
                ids=fam.get("hub", "none") if pid else "none",
                title=parent.get("title", ""), short=meta.get("short", ""), repo=meta.get("repo", ""),
                outcome=parent.get("outcome", ""), cap=cap, running=running, free=free, counts=counts, done=done,
                members=[{k: v for k, v in m.items() if k != "detail"} for m in members],
                next=nxt, no_repo=norepo, last_tick=last, last_tick_src=("id" if fam.get("progress") else "record") if last else "",
                report=rep.group(1) if rep else "", summary=kids.get("summary") or {})


def line(s):
    c = s["counts"]
    head = s["parent"] + (" (%s)" % s["parent_short"] if s.get("parent_short") else "")
    out = "%s · 核心 %d：合 %d · 在跑 %d · 重试 %d · 卡住 %d · 未开始 %d · 空位 %d/%d" % (
        head, c["core"], c["succeeded"], c["running"], c["retry"], c["blocked"], c["unstarted"], s["free"], s["cap"])
    if c.get("waiting"):
        out += " · 等依赖 %d" % c["waiting"]
    if s["next"]:
        out += " · 该派 " + " ".join(n["key"] for n in s["next"])
    if s["no_repo"]:
        out += " · 没写仓库 " + " ".join(s["no_repo"])
    if s["done"]:
        out += " · 核心空了，该写报告" if s.get("report") in ("", "pending") else " · 报告 " + s["report"]
    return out


def main(argv=None):
    p = argparse.ArgumentParser(prog="fleet-epic-tick.py", description=__doc__.split("\n")[0])
    p.add_argument("action", choices=("status",))
    p.add_argument("--task", default="")
    p.add_argument("--cap", type=int, default=None)
    p.add_argument("--line", action="store_true")
    # `status ${P:+--task "$P"}` under zsh is ONE word `--task T580`: split it, and
    # let the options come before or after the action
    argv = [w for a in (sys.argv[1:] if argv is None else argv)
            for w in (a.split(None, 1) if a.startswith("--") and " " in a.strip() else [a])]
    a = p.parse_args(argv)
    try:
        ref = a.task or own_task()
        if not TREF.match(ref):
            raise Fail(2, "--task wants T<n>, got %r" % ref)
        s = status(ref, a.cap)
    except Fail as e:
        print("fleet-epic-tick: %s" % e, file=sys.stderr)
        return e.rc
    except (OSError, subprocess.SubprocessError) as e:
        print("fleet-epic-tick: %s" % e, file=sys.stderr)
        return 1
    print(line(s) if a.line else json.dumps(s, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
