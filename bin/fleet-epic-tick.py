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
member too. Per member, off its children (oldest first):
  succeeded  one child succeeded
  running    the newest child has no outcome yet
  retry      one failed — dispatch it once more (the retry rule)
  blocked    failed twice, or cancelled (the person stopped it)
  unstarted  no child yet
`next` is what to dispatch now: retries first, then unstarted core members in
charter order, as many as the free slots (cap − running). `done` is true when
every core (and added) member is succeeded or blocked and nothing runs.

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


def judge(member, kids):
    tasks = [dict(task=c.get("id"), outcome=c.get("outcome") or "", pr=child_pr(c)) for c in kids]
    member["tasks"] = tasks
    won = [t for t in tasks if t["outcome"] == "succeeded"]
    failed = [t for t in tasks if t["outcome"] in ("failed", "refused")]
    if won:
        member.update(state="succeeded", task=won[0]["task"], pr=won[0]["pr"])
    elif tasks and not tasks[-1]["outcome"]:
        member.update(state="running", task=tasks[-1]["task"])
    elif any(t["outcome"] == "cancelled" for t in tasks) or len(failed) >= 2:
        member.update(state="blocked", task=tasks[-1]["task"])
    elif failed:
        member.update(state="retry", task=tasks[-1]["task"])
    else:
        member.update(state="unstarted", task="")
    return member


def dispatch_of(parent, member):
    title = "%s · %s" % (member["key"], member["title"])
    if len(title) > TITLE_MAX:
        title = title[:TITLE_MAX - 1] + "…"
    body = ["父任务 %s（%s）的成员 %s：%s。" % (parent["id"], parent.get("title", ""), member["key"], member["title"]),
            "做完开 PR，门禁绿了自己合并，然后 report merged；做不成就 report failed 写清原因。"]
    if member.get("detail"):
        body += ["", member["detail"]]
    if member["state"] == "retry":
        body += ["", "这是重试：上一次（%s）失败了，先读它的结果再动手。" % member["task"]]
    return dict(key=member["key"], title=title, repo=member["repo"], agent=member["agent"],
                retry_of=member["task"] if member["state"] == "retry" else "", body="\n".join(body))


def status(parent_ref, cap):
    got = record("get", parent_ref)
    parent = got.get("task") or {}
    if parent.get("authority_version") != 1:
        raise Fail(2, "%s is not an authoritative task: an EPIC is a parent task opened by /fleet-epic-plan" % parent_ref)
    meta, members = parse_charter(charter_of(parent))
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
    for m in members:
        judge(m, by_key.get(m["key"], []))
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
    counts = dict(core=len(counted), succeeded=0, running=0, retry=0, blocked=0, unstarted=0)
    for m in counted:
        counts[m["state"]] += 1
    done = running == 0 and all(m["state"] in ("succeeded", "blocked") for m in counted)
    progress = got.get("progress") or {}
    return dict(parent=parent_ref, title=parent.get("title", ""), short=meta.get("short", ""), repo=meta.get("repo", ""),
                outcome=parent.get("outcome", ""), cap=cap, running=running, free=free, counts=counts, done=done,
                members=[{k: v for k, v in m.items() if k != "detail"} for m in members],
                next=nxt, no_repo=norepo, last_tick=progress.get("summary", ""), summary=kids.get("summary") or {})


def line(s):
    c = s["counts"]
    out = "%s · 核心 %d：合 %d · 在跑 %d · 重试 %d · 卡住 %d · 未开始 %d · 空位 %d/%d" % (
        s["parent"], c["core"], c["succeeded"], c["running"], c["retry"], c["blocked"], c["unstarted"], s["free"], s["cap"])
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
