#!/usr/bin/env python3
"""fleet-epic-tick.py — one EPIC batch, read off the hub (issue #4957).

An EPIC is a parent hub task (T<n>) whose record holds the charter (its
dispatch body), and its members are child tasks (`parent_task`). This is the
deterministic half of /fleet-epic-run's tick and /fleet-epic-report's gather:
it reads the parent's record and its children and says, for every member of the
charter, where it stands and what to dispatch next. It reads only the hub — no
gh, no GitHub, no tmux, no local book — so a driver that lost its context
re-reads the whole batch with one call.

  fleet-epic-tick.py status [--task <code|T<n>>] [--cap N] [--line]
      --task  the parent — its code (K5H0, EPIC T644) or T<n> (read one more
              version, compat-1v: 下一批删); default: this window's own @task
      --cap   how many members may run at once (default: the charter's cap=, else 4)
      --line  one human line instead of the JSON

The charter (written by /fleet-epic-plan, the parent's body):

  <!-- fleet:epic repo=<owner/name> short=<简称> agent=<claude|codex> cap=<N> -->
  - [ ] **C1** <title>                       a core member in the marker's repo
  - [ ] **C2** <owner/name> — <title> (codex) one in another repo, on Codex
  - [ ] **R1** <title>                       reserve: never dispatched by itself
  ## C1 · <title>                            its detail, handed to its session
  ## 共同约定                                  handed to every member's session too

A member's body carries the local files its words name (T793,
fleet_local_refs.py: `~/fleet-drafts/…/C3.md` read on this machine, else off the
charter's own carried copy); one that cannot come is that item's `uncarried` and
a line of `warnings` — the session would be placed where the file is not.

A member's child task is titled `<key> · <title>`; a child whose title carries a
key the charter does not list (`C5 · …`, a member added within scope) is a
member too.

By ID (EPIC T497 C5). Every session is a window ID (`@fleet_id`, short code
`K3F9` — docs/dev/FLEET-ID.md): the parent's ID is the driver's (the second
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
  running    the newest baton has no outcome yet, and its agent is up
  stalled    the newest baton has no outcome, but its agent never came up or went
             down (T642, fleet_id.start_word — the wrapper's 「未起来」/「已掉」 word on
             its ID, its window here holding no agent, the hub's live word, or no
             native segment FLEET_START_GRACE after the record opened): `stall` =
             {word, why, hint} — the hint restarts it ON ITS RECORD
             (`fleet-task-record.sh respawn T<n> --prev <ID>`, or ↵ / `fleet-id.sh
             reopen`), never a new T; it keeps its slot and the batch is not done
  retry      one failed — dispatch it once more (the retry rule), prev = its ID
  blocked    failed twice, or cancelled (the person stopped it), or a member it
             waits on is blocked
  waiting    unstarted, and a member it depends on has not succeeded yet
  unstarted  no baton yet
Dependencies are the charter's `## 依赖顺序` table — `| C5 | C4 | |`, or the plan's
`| 波次 | 成员 | 等谁 | 可并行 |` (every key of the 成员 cell waits on the 等谁 cell, or
its `C2 ← C1；C7 ← C5` pairs; `C1–C6` a range) — else a section's `**依赖** 依赖 C4 · 被依赖 …` line; only a BARE `C<n>` is
this batch's member. A key behind a `T<n>` — `T542 C5`, `T542 C7、C8` (the prefix
holds over the keys that follow it, until other words or a `+` / `;`) — is the
member of ANOTHER batch: released once that parent's child task titled `C5 · …`
succeeded, waited on otherwise (`waits_on` names it `T542 C5`), never a node of
this batch's graph and never let through by the cycle rule (each member's
`outside` lists them with `done`, so a released one is said, not dropped); a key behind `#<n>`
(a GitHub ticket) is the driver's to judge and ignored here — but `PR #<n>` (`PR
#5182 #5189 #5192`: every `#<n>` right after `PR`) is an in-flight PR gate (T843):
gh reads it in the member's repo, and a member still to start waits (`waits_on`
names it `PR #5189`) until it is MERGED; one gh cannot read, or closed unmerged, is
held and said in `warnings`. A dependency is
released by its member's newest baton — by ID, not by which record it was (拍板 6).
`warnings` says a dependency was written but none could be read (a table that
gave no key, a section line naming `M1` rather than `C1` — T692): the driver holds
those members by hand; `--line` ends with them (`⚠ …`).
`next` is what to dispatch now: retries first, then unstarted core members in
charter order, as many as the free slots (cap − running). `done` is true when
every core (and added) member is succeeded or blocked and nothing runs.
`last_tick` is the driver's newest progress word: its ID's (`fleet-id.sh progress`,
which `fleet_task_control.py progress` writes with the ID switch on — EPIC T497
C12), else the record's `progress` from before the switch (`last_tick_src` id |
record); `report` is that word's `report: <pending | link>` (fleet-epic-run §4).
`mark` is what the heartbeat stamps the batch as: the parent's short code
(`K3F9`), else its record `T<n>`.

By the task's code (EPIC T644 C5). A task's record carries its own ID (`fid`, C1)
and every session opened for it goes by that ID (C2): a member IS its record's ID,
and its redo is that ID's next ATTEMPT — `fleet-task-record.sh respawn <code>
--redo` on the same record, never a new task (`next`'s retry item carries it as
`respawn`; a record from before C1 — no `fid` — keeps the old road: a new task
whose body names the failed ID as its `prev`, read one more version). A baton's
attempts are its ID's (`attempt` on its family row): the record's failure belongs
to an earlier attempt once a later one runs, each attempt past the first is one
try used, and the attempt that merges ends the member. Every name the answer gives
a person is a CODE: `parent` (the parent's, else T<n>; `parent_task` keeps the
T<n> — compat-1v: 下一批删), each member's `code`, `waits_on` / `outside` naming
another batch by its parent's code; a dependency cell may write that batch either
way — `K5H0 C5` (`#K5H0 C5`) or `T542 C5` (compat-1v) — and this batch's own code
or T<n> as the prefix is the same as none.

Exit: 0 read · 1 the hub did not answer · 2 usage / no parent / no charter (or a
code naming several tasks) · 3 no hub here (fleet-task-record.sh exit 3).
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
import fleet_local_refs  # noqa: E402 — the one carrying rule (T793)
TREF = re.compile(r"^T[1-9][0-9]{0,9}$")
# a task's reference as a person writes it: its code (`K5H0`, `#k5h0`), its full ID
# or T<n> — what fleet-task-record.sh's one resolver reads (EPIC T644 C3)
TASK_REF = re.compile(r"^(?:T[1-9][0-9]{0,9}|#?[A-Za-z][0-9A-Za-z]{1,25}"
                      r"|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$")
MARK = re.compile(r"<!--\s*fleet:epic\b([^>]*)-->")
LINE = re.compile(r"^\s*[-*] \[[ xX]\] \*\*([CR][1-9][0-9]*)\*\*\s+(.+?)\s*$")
REPO = re.compile(r"^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\s+(?:—|--|-)\s+(.+)$")
AGENT = re.compile(r"^(.*?)\s*\((codex|claude)\)$")
HEAD = re.compile(r"^#{2,4}\s+")
# a closing tick's `report: <pending | link>` (fleet-epic-run §4, issue #852)
REPORT_RE = re.compile(r"(?:^|·)\s*report:\s*([^\s·]+)")
FID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
DEPS_HEAD = re.compile(r"^#{2,4}\s+依赖")
# a dependency cell, token by token: an outside batch's parent — its code
# (`K5H0`, `#K5H0`: a letter, then Crockford base32, 4–26 places — EPIC T644 C5) or
# T<n> (compat-1v) — or a ticket (#<n>) scopes the keys right after it; only these
# between them keep the scope. A member key (`C12`) is never read as a code.
CODE_TOK = r"#?(?![CR][0-9]+(?![0-9A-Z]))[A-HJKMNP-TV-Z][0-9A-HJKMNP-TV-Z]{3,25}(?![0-9A-Za-z])"
DEP_TOK = re.compile(r"(?<![A-Za-z0-9])(?:(?P<scope>T[1-9][0-9]{0,9}(?![0-9A-Za-z])|#[1-9][0-9]*(?![0-9A-Za-z])|"
                     + CODE_TOK + r")"
                     r"|(?P<a>[CR])(?P<lo>[1-9][0-9]*)(?:\s*[–—~-]\s*[CR]?(?P<hi>[1-9][0-9]*))?)(?![0-9])")
DEP_GLUE = re.compile(r"^[\s、,，/:：]*$")
DEP_LINE = re.compile(r"\*\*依赖\*\*\s*依赖\s*(.*?)(?:·|$)")
# an in-flight PR gate in a dependency cell (T843): `PR #5191`, `PR #5182 #5189、#5192`
# — every `#<n>` right after `PR` (glue only between them) is a PR of the member's repo
PR_GATE = re.compile(r"(?<![A-Za-z])PRs?\s*((?:#[1-9][0-9]*(?![0-9A-Za-z])(?:[\s、,，/和及与&+]*(?=#[1-9]))?)+)", re.I)
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
    if p.returncode == 2 and '"AMBIGUOUS"' in p.stdout:   # a code naming several tasks: never a pick
        raise Fail(2, "%s names more than one task — name it longer" % (args[-1] if args else ""))
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
    if p.returncode or not TASK_REF.match(t):
        raise Fail(2, "this window carries no task (@task): name the parent with --task <code>")
    return t


def code_rec(task):
    """A record's written code (EPIC T644 C1): the hub's `short`, else this login's
    book (fleet_id.task_code — every answer that carried one wrote it), else ''."""
    c = str(task.get("short") or "")
    if c or not TREF.match(str(task.get("id") or "")):
        return c
    try:
        return ids().task_code(task["id"])
    except (ImportError, OSError, ValueError):
        return ""


def is_self(scope, selves):
    """Is a dependency's prefix this batch's own parent — its T<n>, or its code (any
    prefix of it as long as the written one, either way round)?"""
    sc = scope.lstrip("#")
    for me in selves:
        if not me:
            continue
        if sc == me or (not TREF.match(me) and not TREF.match(sc) and len(sc) >= 4 and
                        (me.startswith(sc) or sc.startswith(me))):
            return True
    return False


def id_of(task):
    """A record's window ID: the second half of its worker_id (`<fleet>/<ID>`);
    a record from before C8 (EPIC T497) may name it as execution_owner only."""
    for k in ("worker_id", "execution_owner"):
        tail = str(task.get(k) or "").rpartition("/")[2]
        if FID.match(tail):
            return tail
    return ""


def claimed_by(task, fam):
    """A record's ID: the task's own (`fid`, EPIC T644 C1 — every session opened for
    it goes by it, C2; one that could not take it continues it down `prev`), else its
    worker_id's, else — a record the ID switch dispatched stays accepted and is never
    claimed (EPIC T497 C14) — the family's ID opened on it (`task`), the newest down
    `prev` when several were."""
    if FID.match(str(task.get("fid") or "")):
        return task["fid"]
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
    """An ID with no record anywhere still has a code: its first four (fleet_id.py's
    encoding — a longer one only where the ledger or the hub says so)."""
    if not fid:
        return ""
    sys.path.insert(0, str(BIN))
    try:
        import fleet_id
        return fleet_id.encode(fid)[:fleet_id.SHORT_MIN]
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


def shared_of(text):
    """The charter's `## 共同约定` — every member works under it (T793)."""
    out, on = [], False
    for line in text.splitlines():
        if re.match(r"^##\s", line):
            if on:
                break
            on = bool(re.match(r"^##\s+共同约定", line))
        if on:
            out.append(line)
    body = "\n".join(out[1:]).strip()
    return "## 共同约定（全批）\n" + body if body else ""


def dep_refs(text, self_ref=""):
    """[(scope, key)] in order: scope "" for a bare key (this batch), a code
    (`K5H0`, the `#` dropped) or `T<n>` for another batch's member, `#<n>` for a
    ticket's. `self_ref` (this batch's own T<n> and / or code — a string or a tuple)
    written as a prefix is the same as none."""
    selves = (self_ref,) if isinstance(self_ref, str) else tuple(self_ref)
    out, scope, end = [], "", 0
    for m in DEP_TOK.finditer(text):
        if not DEP_GLUE.match(text[end:m.start()]):
            scope = ""
        end = m.end()
        if m.group("scope"):
            sc = m.group("scope")
            sc = sc if re.match(r"^#[0-9]", sc) else sc.lstrip("#")
            scope = "" if is_self(sc, selves) else sc
            continue
        a, lo, hi = m.group("a"), int(m.group("lo")), int(m.group("hi") or m.group("lo"))
        out += [(scope, "%s%d" % (a, i)) for i in range(lo, hi + 1)]
    return out


def pr_refs(text):
    """[n] of every `PR #n` gate in a dependency cell, in order (T843)."""
    return list(dict.fromkeys(int(n) for m in PR_GATE.finditer(text)
                              for n in re.findall(r"#([1-9][0-9]*)", m.group(1))))


def pr_state(repo, n, cache):
    """A PR's state as gh says it (MERGED / OPEN / CLOSED), '' when it cannot be read.
    `FLEET_EPIC_TICK_GH` names the gh to run (a selftest's stub)."""
    if (repo, n) not in cache:
        try:
            p = subprocess.run([os.environ.get("FLEET_EPIC_TICK_GH") or "gh", "pr", "view", str(n), "-R", repo,
                                "--json", "state", "-q", ".state"], capture_output=True, text=True, timeout=30,
                               stdin=subprocess.DEVNULL)
            st = p.stdout.strip().upper() if p.returncode == 0 else ""
        except (OSError, subprocess.SubprocessError):
            st = ""
        cache[(repo, n)] = st if st in ("MERGED", "OPEN", "CLOSED") else ""
    return cache[(repo, n)]


def pr_gates(members, prs, repo=""):
    """({key: ['PR #n' not merged yet]}, [warnings]) — only for a member still to
    start (unstarted / waiting); a PR that cannot be read is held AND said, a closed
    unmerged one held and said: the driver decides."""
    open_, warn, cache = {}, [], {}
    for m in members:
        ns = prs.get(m["key"])
        if not ns or m["state"] not in ("unstarted", "waiting"):
            continue
        r = m.get("repo") or repo
        for n in ns:
            st = pr_state(r, n, cache) if r else ""
            if st == "MERGED":
                continue
            open_.setdefault(m["key"], []).append("PR #%d" % n)
            if not st:
                warn.append("%s 等的 PR #%d 读不出状态（%s）——请驱动手动压住" % (m["key"], n, r or "没写仓库"))
            elif st == "CLOSED":
                warn.append("%s 等的 PR #%d 已关闭却没合——请驱动判断" % (m["key"], n))
    return open_, warn


DEP_ARROW = re.compile(r"\s*(?:←|⟵|<-+)\s*")
DEP_CLAUSE = re.compile(r"\s*(?:[；;]|<br\s*/?>)\s*")
DEP_NONE = re.compile(r"^[\s—–\-无/·.。*]*$")
# `C6 等 C2 C3 C4` / `C2 不等` (T851): a clause that starts with member keys and 等 / 不等
DEP_WAITS = re.compile(r"^(?P<keys>(?:[CR][1-9][0-9]*(?:\s*[–\-~～]\s*[CR]?[1-9][0-9]*)?[\s、,，/]*)+?)\s*(?P<no>不)?等(?!于|同)\s*(?P<on>.*)$")
DEP_ALL_CORE = re.compile(r"核心全部|全部核心")


def dep_table_row(cells, cols, known, put):
    """One row of the `## 依赖顺序` table into `put(key, cell)`: the member column's
    keys (`C2 C3 C4`, `C5 · C6（并行）`, a range) each wait on the wait column — or,
    when that cell carries per-key clauses — `X ← Y` pairs (`C2 ← C1；C7 ← C5`) or
    `X 等 Y` / `X 不等` (`C6 等 C2 C3 C4；C8 等 C2 C3 C5`, T851) — each X on its Y
    (an X need not be in the member column), and a row member no clause names on
    nothing. A whole-cell wait never makes a row member wait on another of the same
    row (one row is one wave: `R1 R2 R3` beside a remark naming R2), and 「核心全部」
    is every core member (the plan template's reserve row). Only the wait column is
    read — never 可并行 or a remark column."""
    mc, wc = cols
    if max(mc, wc) >= len(cells):
        return False
    keys = [k for sc, k in dep_refs(cells[mc]) if not sc and k in known]
    wait = cells[wc]
    clauses = DEP_CLAUSE.split(wait)
    row = set(keys)
    pairs = [DEP_ARROW.split(c, 1) for c in clauses if DEP_ARROW.search(c)]
    if not pairs:  # `X 等 Y` only when every X is this row's member (`C1 C2 等全部合并` is "etc.")
        waits = [DEP_WAITS.match(c) for c in clauses]
        waits = [m for m in waits if m and {k for sc, k in dep_refs(m.group("keys"))} <= row]
        pairs = [[m.group("keys"), "" if m.group("no") else m.group("on")] for m in waits]
    if not keys and not pairs:
        return False
    if pairs:
        for k in keys:
            put(k, "")
        for lhs, rhs in pairs:
            for sc, k in dep_refs(lhs):
                if not sc and k in known:
                    put(k, rhs)
        return True
    wait = strip_keys(wait, row)
    if DEP_ALL_CORE.search(wait):
        wait = " ".join(sorted((x for x in known if not x.startswith("R")), key=lambda x: int(x[1:]))) + " " + wait
    for k in keys:
        put(k, wait)
    return True


def strip_keys(cell, drop):
    """`cell` without the bare member keys in `drop` (a same-row mention, T851)."""
    return DEP_TOK.sub(lambda m: "" if not m.group("scope") and m.group(0) in drop else m.group(0), cell)


def parse_deps(text, members, self_ref=""):
    """({key: [keys it waits on]}, {key: [(T<n>, key) of other batches]},
    {key: [PR numbers it waits on]}, [warnings])
    off the `## 依赖顺序` table — `| 成员 | 依赖 |` or the plan's `| 波次 | 成员 | 等谁 |`
    (columns found by the header; see dep_table_row) — else each section's `**依赖**`
    line; local ones only the charter's own member keys, never itself; `#<n>` ones
    dropped; `PR #<n>` ones are PR gates (T843). A warning says a dependency was written but none could be read from it
    (a table that gave nothing, a section line naming no key — `M1`): the driver
    holds those members by hand (T692)."""
    known = {m["key"] for m in members}
    deps, on, cols, rows, read = {}, False, None, 0, 0

    def put(k, cell):
        deps[k] = (deps[k] + "；" + cell) if deps.get(k) and cell else (deps.get(k) or cell)

    for line in text.splitlines():
        if HEAD.match(line):
            on, cols = bool(DEPS_HEAD.match(line)), None
            continue
        if not on or not line.strip().startswith("|"):
            if on and not line.strip():
                cols = None
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if all(re.match(r"^:?-+:?$", c) for c in cells if c):
            continue
        if cols is None:
            mc = next((i for i, c in enumerate(cells) if "成员" in c), None)
            wc = next((i for i, c in enumerate(cells) if i != mc and re.search(r"等谁|等待", c)),
                      next((i for i, c in enumerate(cells) if i != mc and re.search(r"(?<!被)依赖", c)), None))
            if mc is not None or wc is not None:
                cols = (mc if mc is not None else 0, wc if wc is not None else (mc or 0) + 1)
                continue
            cols = (0, 1)   # no header: the old `| C5 | C4 |`
        rows += 1
        read += dep_table_row(cells, cols, known, put)
    warn = []
    if rows and not read:
        warn.append("依赖顺序表有 %d 行，一个成员键都没读出来——依赖请驱动手动压住" % rows)
    unread = []
    for m in members:
        if m["key"] not in deps:
            d = DEP_LINE.search(m.get("detail") or "")
            if d:
                deps[m["key"]] = d.group(1)
                if not dep_refs(d.group(1)) and not pr_refs(d.group(1)) and not DEP_NONE.match(d.group(1)):
                    unread.append(m["key"])
    if unread:
        warn.append("%s 的 **依赖** 行写了依赖却没有成员键（只认 C<n> / R<n>）——请驱动手动压住" % "、".join(unread))
    out, ext, prs = {}, {}, {}
    for k, cell in deps.items():
        if pr_refs(cell):
            prs[k] = pr_refs(cell)
        refs = list(dict.fromkeys(dep_refs(cell, self_ref)))
        got = [x for sc, x in refs if not sc and x in known and x != k]
        far = [(sc, x) for sc, x in refs if sc and not sc.startswith("#")]
        if got:
            out[k] = got
        if far:
            ext[k] = far
    return out, ext, prs, warn


def outside_done(ext):
    """({(ref, key): True when that batch's member succeeded}, {ref: its code}) —
    each outside parent (written as its code or T<n>) read the way this batch is
    (batch_of + judge: a redo's newest attempt or baton, an ID's result the record
    does not carry yet); an unreadable one counts as not done (waited on), named as
    written."""
    done, names = {}, {}
    for ref in sorted({sc for refs in ext.values() for sc, _ in refs}):
        try:  # the parent's record only names its ID; its children are the batch
            parent = record("get", ref).get("task") or {}
        except (Fail, OSError, subprocess.SubprocessError):
            parent = {}
        names[ref] = code_rec(parent) if parent.get("id") else ref
        names[ref] = names[ref] or ref
        try:
            _, children, _, _, rows, _ = batch_of(parent.get("id") or ref, parent)
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
    return done, names


def ids():
    """bin/fleet_id.py, imported once (the start word's one reader — T642)."""
    if str(BIN) not in sys.path:
        sys.path.insert(0, str(BIN))
    import fleet_id
    return fleet_id


def projected(children):
    """An open child's outcome off its own record read: with the ID switch on the
    hub projects the window ID's result there, never into `children` (T622 — T542's
    C5 merged, yet its children row still said accepted). One read per open child;
    an unreadable one stays open."""
    for c in children:
        if c.get("outcome") or not TREF.match(str(c.get("id") or "")):
            continue
        try:
            got = record("get", c["id"])
            t = got.get("task") or {}
        except (Fail, OSError, subprocess.SubprocessError):
            continue
        if t.get("id") == c["id"] and t.get("outcome"):
            c["outcome"], c["state"] = t["outcome"], t.get("state") or c.get("state")
        elif t.get("id") == c["id"]:
            # the read the start word judges an open child by (T642): started · progress · live
            c["_view"] = dict(got, task=t)
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
    seeds = [i for c in children for i in (str(c.get("fid") or ""), id_of(c)) if FID.match(i)]
    fam = family_of(pid, list(dict.fromkeys(seeds)))
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
    continued it down `prev` (an old-road redo, a 「从这一段继续」) — newest last. A
    baton is one ID; its `attempts` are that ID's (EPIC T644 C5: a redo on the
    task's own ID is its next attempt, not a new baton)."""
    rows = {r["id"]: r for r in fam}
    placed = set()
    out = []

    def add(task, outcome, pr, fid, view=None, code="", rec_outcome=""):
        row = rows.get(fid) if fid else None
        att = (row or {}).get("attempt")
        att = att if isinstance(att, int) and att > 0 else 1
        if row and att > 1 and outcome in FAILED:
            # the record's failure is an earlier attempt's: the ID's current attempt
            # (its family row reads only that one's results — C2) is where it stands
            outcome = ""
        if not outcome and row:
            # exited = closed with no result; an ID still open whose window is gone
            # is the start word's to judge (T642): restarted on its record, never a new T
            still_open = "closed" in row and row["closed"] is None
            outcome = {"done": "succeeded", "failed": "failed"}.get(row.get("state"), "") or \
                ("exited" if row.get("state") == "exited" and not still_open else "")
        if not pr and row:
            pr = str((row.get("result") or {}).get("pr") or "")
        short = (row or {}).get("short", "") or code or code_of(fid)
        if not code and TREF.match(str(task or "")):
            try:
                code = ids().task_code(task)
            except (ImportError, OSError, ValueError):
                code = ""
        out.append(dict(task=task, code=code or "", outcome=outcome, pr=pr, id=fid, short=short,
                        prev=(row or {}).get("prev", ""), attempts=att, rec_outcome=rec_outcome,
                        _view=view, _row=row))
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
        add(c.get("id"), c.get("outcome") or "", child_pr(c), fid, c.get("_view"), code_rec(c), c.get("outcome") or "")
    return out


def judge(member, kids, fam=()):
    tasks = batons_of(kids, list(fam))
    member["tasks"] = tasks
    won = [t for t in tasks if t["outcome"] == "succeeded"]
    # tries used: every failed baton, and every attempt of an ID past its first (a
    # redo on the task's own ID — EPIC T644 C5)
    failed = sum(1 for t in tasks if t["outcome"] in FAILED) + sum(t["attempts"] - 1 for t in tasks)
    last = tasks[-1] if tasks else {}
    member.update(id=last.get("id", ""), short=last.get("short", ""),
                  code=last.get("code", "") or last.get("short", ""), attempt=last.get("attempts", 1),
                  ids=[dict(id=t["id"], short=t["short"], code=t["code"], task=t["task"], prev=t["prev"],
                            attempt=t["attempts"], outcome=t["outcome"])
                       for t in tasks if t["id"]])
    # a running baton is judged by its agent, not only its record (T642): one that
    # never came up, or went down, is `stalled` — with what to do about it
    word = {}
    if not won and tasks and not last["outcome"]:
        word = ids().start_word(view=last.get("_view"), row=last.get("_row"))
    for t in tasks:
        t.pop("_view", None)
        t.pop("_row", None)
    if won:
        member.update(state="succeeded", task=won[0]["task"], pr=won[0]["pr"], id=won[0]["id"] or member["id"],
                      short=won[0]["short"] or member["short"], code=won[0]["code"] or won[0]["short"] or member["code"])
    elif tasks and not last["outcome"] and word:
        member.update(state="stalled", task=last["task"],
                      stall=dict(word, hint=ids().start_hint(word["word"], last["code"] or last["task"], last["id"],
                                                              last["short"])))
    elif tasks and not last["outcome"]:
        member.update(state="running", task=last["task"])
    elif any(t["outcome"] == "cancelled" for t in tasks) or failed >= 2:
        member.update(state="blocked", task=last["task"])
    elif failed:
        member.update(state="retry", task=last["task"])
    else:
        member.update(state="unstarted", task="")
    if member.get("state") == "retry":
        member["redo"] = redo_of(last)
    return member


def redo_of(last):
    """How a failed member goes again (EPIC T644 C5): on its OWN record, its next
    attempt — `fleet-task-record.sh respawn <code> --redo` (a record its ID's result
    failed; `respawn` alone for one left open by an ID that closed with no result) —
    when the record has a code; '' for one from before C1 (the old road: a new task,
    prev = the failed ID)."""
    t, code = str(last.get("task") or ""), str(last.get("code") or "")
    if not code or not TREF.match(t):
        return ""
    return "fleet-task-record.sh respawn %s%s" % (code, " --redo" if last.get("rec_outcome") in FAILED else "")


def hold_on_deps(members, deps, ext=None, ext_done=None, names=None, prs_open=None):
    """An unstarted member whose dependencies have not all succeeded waits; one whose
    dependency is blocked is blocked too. Another batch's member (`ext`) holds it
    until `ext_done` says it succeeded. A cycle among this batch's own members
    (everything waiting, nothing to run) is let through rather than stalled — never
    a member still waiting on another batch, directly or through this batch's
    members it waits on: both halves must hold before a member is due. A PR gate not
    merged yet (`prs_open`, `PR #n`) holds it like another batch's member (T843)."""
    ext, ext_done, names, prs_open = ext or {}, ext_done or {}, names or {}, prs_open or {}
    by = {m["key"]: m for m in members}
    for _ in range(len(members) + 1):
        moved = False
        for m in members:
            if m["state"] not in ("unstarted", "waiting") or (m["key"] not in deps and m["key"] not in ext
                                                             and m["key"] not in prs_open):
                continue
            ds = [by[d] for d in deps.get(m["key"], []) if d in by]
            stuck = [d["key"] for d in ds if d["state"] == "blocked"]
            open_ = [d["key"] for d in ds if d["state"] != "succeeded"]
            open_ += ["%s %s" % (names.get(r[0], r[0]), r[1]) for r in ext.get(m["key"], []) if not ext_done.get(tuple(r))]
            open_ += prs_open.get(m["key"], [])
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
    live = [m for m in members if m["layer"] != "reserve" and m["state"] in ("running", "stalled", "retry", "unstarted")]
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


def dispatch_of(parent, member, text=""):
    title = "%s · %s" % (member["key"], member["title"])
    if len(title) > TITLE_MAX:
        title = title[:TITLE_MAX - 1] + "…"
    pname = code_rec(parent) or parent["id"]
    body = ["父任务 %s（%s）的成员 %s：%s。" % (pname, parent.get("title", ""), member["key"], member["title"]),
            "做完开 PR，门禁绿了自己合并，然后 report merged；做不成就 report failed 写清原因。"]
    if member.get("detail"):
        body += ["", member["detail"]]
    shared = shared_of(text)
    if shared:
        body += ["", shared]
    retry = member["state"] == "retry"
    if retry:
        who = member.get("code") or member["task"] or member.get("short") or "上一棒"
        body += ["", "这是重试：上一次（%s）失败了，先读它的结果再动手。" % who]
        if member.get("id"):
            # the spawner reads this into the new window's ledger as its prev
            # (dash-raw-session.sh): the redo is the next baton of the same member
            body += ["<!-- fleet:prev %s -->" % member["id"]]
    # the local files its words name ride with it (T793): read here, else off the
    # charter's own carried copy — the driver may run on another machine than the plan
    words, uncarried = fleet_local_refs.carry("\n".join(body), have=fleet_local_refs.carried(text))
    # a retry on its own record keeps its code (EPIC T644 C5): `respawn` is the whole
    # dispatch — no new task; `body` / `prev` are the old road's (a record with no code)
    return dict(key=member["key"], title=title, repo=member["repo"], agent=member["agent"],
                retry_of=(member.get("code") or member["task"]) if retry else "",
                prev=member.get("id", "") if retry else "",
                respawn=member.get("redo", "") if retry else "",
                uncarried=["%s（%s）" % m for m in uncarried],
                body=words.rstrip("\n"))


def status(parent_ref, cap):
    got = record("get", parent_ref)
    parent = got.get("task") or {}
    if parent.get("authority_version") != 1:
        raise Fail(2, "%s is not an authoritative task: an EPIC is a parent task opened by /fleet-epic-plan" % parent_ref)
    # the record answers to its code too: read on by its T<n>, name it by its code
    parent_ref = parent.get("id") if TREF.match(str(parent.get("id") or "")) else parent_ref
    pcode = code_rec(parent)
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
    deps, ext, prs, dep_warn = parse_deps(text, members, (parent_ref, pcode))
    ext_done, names = outside_done(ext)
    prs_open, pr_warn = pr_gates(members, prs, meta.get("repo", ""))
    dep_warn = dep_warn + pr_warn
    hold_on_deps(members, deps, ext, ext_done, names, prs_open)
    for m in members:   # another batch's members it depends on, and whether each merged
        if ext.get(m["key"]):
            m["outside"] = [dict(ref="%s %s" % (names.get(r[0], r[0]), r[1]), done=bool(ext_done.get(tuple(r))))
                            for r in ext[m["key"]]]
    if cap is None:
        try:
            cap = int(meta.get("cap", "4"))
        except ValueError:
            cap = 4
    cap = max(1, cap)
    counted = [m for m in members if m["layer"] != "reserve"]
    running = sum(1 for m in members if m["state"] == "running")
    # a stalled member still holds its record — and its slot: it restarts on it (T642)
    stalled = [m for m in members if m["state"] == "stalled"]
    free = max(0, cap - running - len(stalled))
    pending = [m for m in counted if m["state"] == "retry"] + [m for m in counted if m["state"] == "unstarted"]
    nxt = [dispatch_of(parent, m, text) for m in pending if m["repo"]][:free]
    for n in nxt:   # said before the dispatch, so the driver never hands out a dead path
        dep_warn = dep_warn + ["%s 的本机文件没能随单带上：%s" % (n["key"], "、".join(n["uncarried"]))] \
            if n["uncarried"] else dep_warn
    norepo = [m["key"] for m in pending if not m["repo"]]
    counts = dict(core=len(counted), succeeded=0, running=0, stalled=0, retry=0, blocked=0, unstarted=0, waiting=0)
    for m in counted:
        counts[m["state"]] += 1
    done = running == 0 and not stalled and all(m["state"] in ("succeeded", "blocked") for m in counted)
    # the newest tick: the parent's ID's progress word (EPIC T497 C12), else — an ID
    # with none yet, or no ID — the one its record kept before the switch
    progress = fam.get("progress") or got.get("progress") or {}
    last = str(progress.get("summary") or "")
    rep = REPORT_RE.search(last)
    pshort = str(fam.get("short") or code_of(pid)) if pid else ""
    pshort = pcode if pcode and pid == parent.get("fid") else pshort
    return dict(parent=pcode or parent_ref, parent_task=parent_ref,   # compat-1v: 下一批删 (parent_task)
                parent_id=pid, parent_short=pshort, mark=pshort or pcode or parent_ref, lineage=line,
                ids=fam.get("hub", "none") if pid else "none",
                title=parent.get("title", ""), short=meta.get("short", ""), repo=meta.get("repo", ""),
                outcome=parent.get("outcome", ""), cap=cap, running=running, free=free, counts=counts, done=done,
                members=[{k: v for k, v in m.items() if k != "detail"} for m in members],
                next=nxt, no_repo=norepo, warnings=dep_warn,
                stalled=[dict(key=m["key"], task=m.get("task", ""), code=m.get("code", ""), short=m.get("short", ""),
                              **m["stall"]) for m in stalled],
                last_tick=last, last_tick_src=("id" if fam.get("progress") else "record") if last else "",
                report=rep.group(1) if rep else "", summary=kids.get("summary") or {})


def line(s):
    c = s["counts"]
    head = s["parent"] + (" (%s)" % s["parent_short"] if s.get("parent_short") and s["parent_short"] != s["parent"] else "")
    out = "%s · 核心 %d：合 %d · 在跑 %d · 重试 %d · 卡住 %d · 未开始 %d · 空位 %d/%d" % (
        head, c["core"], c["succeeded"], c["running"], c["retry"], c["blocked"], c["unstarted"], s["free"], s["cap"])
    if c.get("waiting"):
        out += " · 等依赖 %d" % c["waiting"]
    for st in s.get("stalled") or []:
        out += " · %s %s（%s）→ %s" % (st["key"], "未起来" if st["word"] == "not_started" else "已掉",
                                       st["why"], st["hint"])
    if s["next"]:
        out += " · 该派 " + " ".join(n["key"] + ("（%s 重做）" % n["retry_of"] if n.get("respawn") else "")
                                    for n in s["next"])
    if s["no_repo"]:
        out += " · 没写仓库 " + " ".join(s["no_repo"])
    for w in s.get("warnings") or []:
        out += " · ⚠ " + w
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
        ref = (a.task or own_task()).lstrip("#")
        if not TASK_REF.match(ref):
            raise Fail(2, "--task wants the parent's code (or T<n>), got %r" % ref)
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
