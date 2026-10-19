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
`exited`, counted as a failure. No family (no hub, an old hub, no IDs) ⇒ the
records alone, as before.

Per member, off its batons:
  succeeded  one baton succeeded
  running    the newest baton has no outcome yet
  retry      one failed — dispatch it once more (the retry rule), prev = its ID
  blocked    failed twice, or cancelled (the person stopped it), or a member it
             waits on is blocked
  waiting    unstarted, and a member it depends on has not succeeded yet
  unstarted  no baton yet
Dependencies are the charter's `## 依赖顺序` table (`| C5 | C4 | |`, `C1–C6` a
range), else a section's `**依赖** 依赖 C4 · 被依赖 …` line; only member keys count
(an outside ticket is the driver's to judge). A dependency is released by its
member's newest baton — by ID, not by which record it was (拍板 6).
`next` is what to dispatch now: retries first, then unstarted core members in
charter order, as many as the free slots (cap − running). `done` is true when
every core (and added) member is succeeded or blocked and nothing runs.
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
FID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
DEPS_HEAD = re.compile(r"^#{2,4}\s+依赖")
DEP_RANGE = re.compile(r"([CR])([1-9][0-9]*)\s*[–—~-]\s*[CR]?([1-9][0-9]*)")
DEP_KEY = re.compile(r"(?<![A-Za-z0-9])([CR][1-9][0-9]*)(?![0-9])")
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


def dep_keys(text):
    keys = []
    for a, lo, hi in DEP_RANGE.findall(text):
        keys += ["%s%d" % (a, i) for i in range(int(lo), int(hi) + 1)]
    keys += DEP_KEY.findall(DEP_RANGE.sub(" ", text))
    return keys


def parse_deps(text, members):
    """{key: [keys it waits on]} off the `## 依赖顺序` table, else each section's
    `**依赖**` line; only the charter's own member keys, never itself."""
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
    out = {}
    for k, cell in deps.items():
        got = [x for x in dict.fromkeys(dep_keys(cell)) if x in known and x != k]
        if got:
            out[k] = got
    return out


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

    kid_ids = {id_of(c) for c in kids} - {""}
    for c in kids:
        fid = id_of(c)
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


def hold_on_deps(members, deps):
    """An unstarted member whose dependencies have not all succeeded waits; one whose
    dependency is blocked is blocked too. A cycle (everything waiting, nothing to
    run) is let through rather than stalled."""
    by = {m["key"]: m for m in members}
    for _ in range(len(members)):
        moved = False
        for m in members:
            if m["state"] not in ("unstarted", "waiting") or m["key"] not in deps:
                continue
            ds = [by[d] for d in deps[m["key"]] if d in by]
            stuck = [d["key"] for d in ds if d["state"] == "blocked"]
            open_ = [d["key"] for d in ds if d["state"] != "succeeded"]
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
        for m in members:
            if m["state"] == "waiting":
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
    kids = record("children", parent_ref)
    children = sorted(kids.get("children") or [], key=lambda c: int(str(c.get("id", "T0"))[1:] or 0))
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
    pid = id_of(parent)
    fam = family_of(pid, [i for i in (id_of(c) for c in children) if i])
    rows = [r for r in fam.get("ids") or [] if isinstance(r, dict) and FID.match(str(r.get("id", "")))]
    for m in members:
        judge(m, by_key.get(m["key"], []), rows)
    hold_on_deps(members, parse_deps(text, members))
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
    progress = got.get("progress") or {}
    pshort = str(fam.get("short") or code_of(pid)) if pid else ""
    return dict(parent=parent_ref, parent_id=pid, parent_short=pshort, mark=pshort or parent_ref,
                ids=fam.get("hub", "none") if pid else "none",
                title=parent.get("title", ""), short=meta.get("short", ""), repo=meta.get("repo", ""),
                outcome=parent.get("outcome", ""), cap=cap, running=running, free=free, counts=counts, done=done,
                members=[{k: v for k, v in m.items() if k != "detail"} for m in members],
                next=nxt, no_repo=norepo, last_tick=progress.get("summary", ""), summary=kids.get("summary") or {})


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
        out += " · 核心空了，该写报告"
    return out


def main(argv=None):
    p = argparse.ArgumentParser(prog="fleet-epic-tick.py", description=__doc__.split("\n")[0])
    p.add_argument("action", choices=("status",))
    p.add_argument("--task", default="")
    p.add_argument("--cap", type=int, default=None)
    p.add_argument("--line", action="store_true")
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
