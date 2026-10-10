#!/usr/bin/env python3
"""fleet_decision.py — THE one reader and writer of the decision format (issue
#2669, EPIC #2668 C1). docs/DECISIONS.md is the spec; nothing else parses,
renders or judges a question's deadline.

A worker's `ask` (bin/fleet-mcp.py tool_ask) posts a ⛔ comment on its own
issue. With the new optional fields it carries one machine marker:

    <!-- fleet:ask v=1 id=<uuid> asked=<ISO> due=<ISO> kind=<kind> item=<q> suggest=<q> default=<q> -->

(values percent-encoded, so a marker never holds a space or a `-->`). A row is
    item · suggest · default · due(ISO) · src(gh:owner/repo#N + comment URL) · kind
with kind `normal` or `never:rule|money|publish`. A row with no default — an old
`ask` with no fields, or a ⛔ comment from before this format — reads 「等你」 and
is never defaulted; neither is a `never` row, whatever its caller declared.

    fleet_decision.py ask-body --question Q [--suggest S] [--default D] [--due T]
                               [--class K] [--head question|permission] [--now ISO]
    fleet_decision.py parse  (--repo R --issue N | --comments-json FILE|-)   → one row per line (JSON)
    fleet_decision.py render [--demo] [--rows FILE|-] [--id UUID] [--samples FILE]
                                                                            → Markdown table + marker
    fleet_decision.py group  [--rows FILE|-]   (rows, or a steward.state.json) → one merged group per line
    fleet_decision.py due    [--rows FILE|- | --repo R --issue N…] [--now ISO] [--apply]
    fleet_decision.py record --row JSON --parent owner/repo#N               → 「默认拍板」 on the parent
    fleet_decision.py decided [--date D] [--epic gh:R#N…] [--repo R…] [--json]  → that day's 默认拍板, one line each

`due --apply` answers each due row on its own issue (fleet-comment.sh
--to-worker, marker `fleet:answer row=<id> by=default`) and records it on the
issue's EPIC parent (marker `fleet:default-decided row=<id>`) — each at most
once: a row already answered or recorded is skipped. Seams for the selftest:
FLEET_DECISION_COMMENTS_CMD (prints an issue's comments JSON: argv + repo N),
FLEET_DECISION_POST_CMD (posts: argv + repo N mode, body on stdin),
FLEET_DECISION_PARENT_CMD (prints `owner/repo#N` or nothing: argv + repo N).

`decided` (issue #2679, EPIC #2668 R3) is the daily brief's section 「替你按建议定了
什么」: every `fleet:default-decided` record posted on the person's day (their zone),
read off the EPIC tickets through fleet-ticket.sh — the ones named with --epic, else
every `epic` ticket of the hosted repos updated since that day plus the running
marks. One line per record, its 翻案 link the asking comment on the original ticket;
so the count is exactly the records on the tickets. Seam: FLEET_DECISION_EPICS_CMD
(prints one `gh:owner/repo#N` per line: argv + the date).
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import uuid
from pathlib import Path
from urllib.parse import quote, unquote

import fleet_iso   # the one ISO reader for bin/ (issue #2024)

BIN = Path(__file__).resolve().parent
V = "1"
ASK_HEAD = {"question": "⛔ blocked: ", "permission": "⛔ blocked — needs authorization: "}
ASK_RE = re.compile(r"<!-- fleet:ask v=(\d+) ([^>]*?) ?-->")
ANSWER_RE = re.compile(r"<!-- fleet:answer row=([A-Za-z0-9-]+)")
RECORD_RE = re.compile(r"<!-- fleet:default-decided row=([A-Za-z0-9-]+)")
RECORD_FIELDS_RE = re.compile(r"<!-- fleet:default-decided ([^>]*?) ?-->")
TICKET_RE = re.compile(r"^(?:gh:)?([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)#(\d+)$")
FROM_MARK = "<!-- fleet:from "
URL_RE = re.compile(r"https://github\.com/([^/\s]+/[^/\s]+)/issues/(\d+)")
WAIT = None          # a row whose default is WAIT reads 「等你」 and is never defaulted
DUE_DEFAULT_S = 4 * 3600
NIGHT_FROM, NIGHT_TO, MORNING = 23, 8, 9
CLASSES = ("rule", "money", "publish")

# The keyword backstop (EPIC #2668 共同约定 3): any hit makes the row `never`,
# whatever the caller declared. A false hit only sends a question to a person —
# the safe direction — so these lean wide. The words are the rule table's `ask`
# rows (conf/role-rules.default.md + the person's layer, bin/fleet_rules.py —
# issue #2786); this list is only the backstop for a table that cannot be read.
NEVER_WORDS = {
    "rule": ("claude.md", "agents.md", "break-it", "铁律", "改约定", "删约定"),
    "money": ("付费", "花钱", "云机器", "购买", "充值", "账单", "预算", "billing", "purchase", "paid plan"),
    "publish": ("stable", "发布", "对外", "公开", "publish", "release"),
}


# ---- strings: THE table is bin/fleet-ui-lang.sh (共同约定 11) -------------------

def _load_text():
    try:
        out = subprocess.run(["sh", str(BIN / "fleet-ui-lang.sh"), "dump", "decision_"],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        out = b""
    parts = out.decode("utf-8", "replace").split("\0")
    return dict(zip(parts[0::2], parts[1::2]))


_TEXT = None


def tr(key, *args):
    global _TEXT
    if _TEXT is None:
        _TEXT = _load_text()
    text = _TEXT.get(key, key)   # a missing key shows itself, never a blank
    for arg in args:
        text = text.replace("\x01", str(arg), 1)
    return text.replace("\x01", "")


# ---- time ----------------------------------------------------------------------

def zone():
    """The person's clock — night is THEIR night. FLEET_DECISION_TZ (an IANA name,
    e.g. Asia/Shanghai), else this machine's zone."""
    name = os.environ.get("FLEET_DECISION_TZ", "")
    if name:
        try:
            from zoneinfo import ZoneInfo
            return ZoneInfo(name)
        except Exception:    # no zoneinfo / unknown name: the machine's zone
            pass
    return dt.datetime.now().astimezone().tzinfo


def now_local(given=None):
    if given:
        return parse_time(given)
    return dt.datetime.now(zone())


def parse_time(s):
    t = fleet_iso.parse(s)
    return t.astimezone(zone()) if t.tzinfo else t.replace(tzinfo=zone())


def iso(t):
    return t.isoformat(timespec="seconds")


def _night(t):
    return t.hour >= NIGHT_FROM or t.hour < NIGHT_TO


def _morning_after(t):
    day = t.date() if t.hour < NIGHT_TO else t.date() + dt.timedelta(days=1)
    return t.replace(year=day.year, month=day.month, day=day.day, hour=MORNING, minute=0, second=0,
                     microsecond=0)


def due_at(asked, given=None):
    """The deadline: an ISO time, or a duration (`90m`, `4h`, `1d`) from `asked`,
    default 4 hours. A question asked at night, or one whose deadline lands at
    night (23:00–08:00), waits for 09:00 the next morning (发起人拍板 2)."""
    if given:
        m = re.fullmatch(r"\s*(\d+)\s*([smhd])\s*", given)
        if not m:
            return parse_time(given)            # an explicit time is taken as written
        due = asked + dt.timedelta(seconds=int(m.group(1)) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)])
    else:
        due = asked + dt.timedelta(seconds=DUE_DEFAULT_S)
    if _night(asked):
        return _morning_after(asked)
    if _night(due):
        return _morning_after(due)
    return due


# ---- kind ----------------------------------------------------------------------

_WORDS = None


def never_words():
    """{class: keywords} off the merged rule table, read once a process; the
    code's NEVER_WORDS when the table cannot be read or names no class at all."""
    global _WORDS
    if _WORDS is None:
        try:
            import fleet_rules
            got = fleet_rules.never_words(fleet_rules.load())
            _WORDS = got if any(got.values()) else NEVER_WORDS
        except Exception:    # any failure: the backstop, never no words
            _WORDS = NEVER_WORDS
    return _WORDS


def classify(declared, *texts):
    """`never:<class>` when the caller declared one OR a keyword hits; else normal.
    A declared `normal` never beats a keyword (BREAK-IT decision-never-defaulted)."""
    if declared and declared.startswith("never:") and declared[6:] in CLASSES:
        return declared
    hay = " ".join(t for t in texts if t).lower()
    words = never_words()
    for cls in CLASSES:
        if any(w in hay for w in words.get(cls, ())):
            return "never:" + cls
    return "normal"


def never(row):
    return str(row.get("kind", "")).startswith("never:")


# ---- on / off (共同约定 9) --------------------------------------------------------

def _conf_val(key):
    v = os.environ.get(key)
    if v is not None:
        return v
    conf = Path(os.environ.get("FLEET_CONF_DIR") or (Path.home() / ".config" / "claude-fleet")) / "fleet.conf"
    try:
        lines = conf.read_text().splitlines()
    except OSError:
        return None
    found = None
    for line in lines:
        m = re.match(r"\s*(?:export\s+)?%s\s*=\s*['\"]?([^'\"#\s]*)" % key, line)
        if m:
            found = m.group(1)
    return found


def steward_on():
    """FLEET_STEWARD, default FLEET_ORCHESTRATOR, default FLEET_HOST — the same
    chain fleet-orchestrator.sh reads. Off ⇒ an ask with no new field is today's."""
    for key in ("FLEET_STEWARD", "FLEET_ORCHESTRATOR", "FLEET_HOST"):
        v = _conf_val(key)
        if v not in (None, ""):
            return v not in ("0", "off", "no", "false")
    return False


# ---- the ask comment -----------------------------------------------------------

def ask_body(question, suggest=None, default=None, due=None, cls=None, head="question", now=None,
             row_id=None):
    asked = now_local(now)
    if default is None and suggest:
        default = suggest                       # 「到点没人答就按建议走」
    kind = classify(cls, question, suggest, default)
    row = {"id": row_id or str(uuid.uuid4()), "asked": iso(asked), "due": iso(due_at(asked, due)),
           "kind": kind, "item": question, "suggest": suggest or "", "default": default or ""}
    lines = [ASK_HEAD.get(head, ASK_HEAD["question"]) + question, ""]
    if suggest:
        lines.append("- " + tr("decision_suggest_fmt", suggest))
    lines.append("- " + tr("decision_default_fmt", default_text(row)))
    if row_default(row) is not WAIT and not never(row):   # nothing goes ahead at the deadline
        lines.append("- " + tr("decision_due_fmt", show_time(parse_time(row["due"]))))
    lines += ["", marker(row)]
    return "\n".join(lines), row


def marker(row):
    keys = ("id", "asked", "due", "kind", "item", "suggest", "default")
    return "<!-- fleet:ask v=%s %s -->" % (V, " ".join("%s=%s" % (k, quote(str(row.get(k, "")), safe=""))
                                                       for k in keys))


def row_default(row):
    d = row.get("default") or ""
    return WAIT if not d else d


def default_text(row):
    if never(row):
        return tr("decision_never_fmt", tr("decision_class_" + row["kind"][6:]))
    d = row_default(row)
    return tr("decision_wait") if d is WAIT else d


def show_time(t):
    return t.strftime("%m-%d %H:%M")


# ---- parse ---------------------------------------------------------------------

def _src(url, repo=None, number=None):
    m = URL_RE.search(url or "")
    if m:
        repo, number = m.group(1), m.group(2)
    return "gh:%s#%s" % (repo or "?", number or "?")


def parse_comments(comments, repo=None, number=None):
    """Comments (gh --json comments shape: body, url, createdAt) → rows, each with
    a `state`: open · answered · defaulted. Answered = a later comment carrying
    `fleet:answer row=<id>`, a later human comment (no fleet:from marker), or a
    later direct-route decision (first line 「决定」…, 共同约定 5)."""
    rows = []
    for i, c in enumerate(comments):
        body = c.get("body") or ""
        m = ASK_RE.search(body)
        if m:
            row = {}
            for pair in m.group(2).split():
                k, _, v = pair.partition("=")
                row[k] = unquote(v)
            row["v"] = m.group(1)
        elif body.startswith(ASK_HEAD["question"]) or body.startswith(ASK_HEAD["permission"]):
            # a ⛔ comment from before this format (or an old session's ask): a row
            # that waits for you, never defaulted
            first = body.split("\n", 1)[0]
            q = first.split(": ", 1)[1] if ": " in first else first
            key = c.get("url") or body
            row = {"id": "legacy-" + hashlib.sha1(key.encode()).hexdigest()[:16], "asked": c.get("createdAt", ""),
                   "due": "", "kind": classify(None, q), "item": q, "suggest": "", "default": "", "v": "0"}
        else:
            continue
        row["src"] = _src(c.get("url"), repo, number)
        row["url"] = c.get("url") or ""
        row["state"] = "open"
        for later in comments[i + 1:]:
            lb = later.get("body") or ""
            a = ANSWER_RE.search(lb)
            if a and a.group(1) == row["id"]:
                row["state"] = "defaulted" if "by=default" in lb else "answered"
                break
            if a or ASK_RE.search(lb):
                continue
            if FROM_MARK not in lb or lb.lstrip().startswith("决定"):
                row["state"] = "answered"
                break
        rows.append(row)
    return rows


def is_due(row, now):
    if row.get("state") != "open" or never(row) or row_default(row) is WAIT or not row.get("due"):
        return False
    return parse_time(row["due"]) <= now


# ---- render --------------------------------------------------------------------

def _cell(s):
    return str(s).replace("|", "\\|").replace("\n", " ")


def render_samples(samples):
    """The read-only `samples` area (issue #2678): one finished batch's member and
    its evidence each — never a row, never counted, never answered."""
    out = ["### " + tr("decision_samples_head"), ""]
    for s in samples:
        mem = s.get("member", "")
        ref = s["epic"] if not mem else "%s → %s" % (s["epic"], mem if "#" in mem else "#" + mem)
        if s.get("none"):
            out.append("- " + tr("decision_sample_none_fmt", s["epic"], s.get("members", 0)))
        else:
            out.append("- " + tr("decision_sample_fmt", ref, s.get("note") or "—", s.get("ts", "")))
            if s.get("kind") == "image":
                out.append("  ![%s](%s)" % (_cell(s.get("note") or mem), s["path"]))
            else:
                out.append("  `%s`" % s["path"])
            if s.get("text"):
                out += ["  ```"] + ["  " + x for x in s["text"].split("\n")] + ["  ```"]
        out.append("  <!-- fleet:sample epic=%s member=%s -->" % (s["epic"], mem or "none"))
    return out


def _due_show(r):
    return "—" if (row_default(r) is WAIT or never(r) or not r.get("due")) else show_time(parse_time(r["due"]))


def _asked_show(r):
    try:
        return show_time(parse_time(r["asked"]))
    except (KeyError, TypeError, ValueError):
        return "?"


def _open_key(r):
    return (not never(r), r.get("due") or "9", r.get("asked") or "")


def group(rows):
    """THE merge rule (issue #2832): the rows still open on ONE ticket (`src`) are
    one thing — the latest ask speaks for them (its item, suggestion, default,
    deadline); every other row stands alone. The sheet's text and the panel
    (mod/fleet/hooks/sheet.tsx, which only draws what the steward keeps as
    `groups`) both go through here, so they never count differently.

    → [{gid, ids, item, suggest, default, due, due_show, kind, never, src, url,
        from, state, by, answer, closed_at, asked, asks}] — open groups first in
    the sheet's order (never first, the nearest deadline, the earliest ask),
    then the closed rows, the last closed first. `gid` is the latest row's id;
    `asks` every row's own words, oldest first; `from` says how often it was
    asked when more than once. A row of the old format (v=0, no fields) groups
    the same way: it has a src."""
    by_src, order, closed = {}, [], []
    for r in rows:
        if r.get("state") != "open":
            closed.append([r])
            continue
        key = r.get("src") or r.get("id")
        if key not in by_src:
            by_src[key] = []
            order.append(key)
        by_src[key].append(r)
    out = []
    # ties (the same deadline, asked the same second) break by ticket, never by
    # the order a dict happened to keep
    for rs in sorted((by_src[k] for k in order), key=lambda rs: (min(_open_key(r) for r in rs), rs[0].get("src") or "")):
        out.append(_group_of(sorted(rs, key=lambda r: r.get("asked") or "")))
    closed.sort(key=lambda rs: rs[0].get("closed_at") or rs[0].get("asked") or "", reverse=True)
    return out + [_group_of(rs) for rs in closed]


def _group_of(rs):
    head = rs[-1]
    g = {"gid": head.get("id", ""), "ids": [r.get("id", "") for r in rs]}
    for k in ("item", "suggest", "due", "kind", "src", "url", "state", "by", "answer", "closed_at", "asked"):
        g[k] = head.get(k) or ""
    g["default"] = default_text(head)
    g["due_show"] = _due_show(head)
    g["never"] = never(head)
    g["from"] = tr("decision_group_from_fmt", len(rs), _asked_show(rs[0]), _asked_show(head)) if len(rs) > 1 else ""
    g["asks"] = [{"id": r.get("id", ""), "item": r.get("item", ""), "asked": r.get("asked", ""),
                  "url": r.get("url", "")} for r in rs]
    return g


def render(rows, sheet_id=None, samples=None):
    """The sheet's table: one line a group (group()); a line that stands for
    several asks says so in its source cell. Rows that merge nothing render
    byte for byte as before."""
    out = []
    if rows or not samples:
        out = ["| # | %s | %s | %s | %s | %s |" % tuple(tr(k) for k in (
                   "decision_col_item", "decision_col_suggest", "decision_col_default", "decision_col_due",
                   "decision_col_src")),
               "|---|---|---|---|---|---|"]
    for n, g in enumerate(group(rows), 1):
        src = g["src"]
        if g["url"]:
            src = "[%s](%s)" % (src, g["url"])
        if g["from"]:
            src += " · " + g["from"]
        out.append("| %d | %s | %s | %s | %s | %s |" % (n, _cell(g["item"]), _cell(g["suggest"] or "—"),
                                                       _cell(g["default"]), g["due_show"], _cell(src)))
    if samples:
        out += ([""] if out else []) + render_samples(samples)
    out += ["", "<!-- fleet:decision v=%s id=%s -->" % (V, sheet_id or uuid.uuid4())]
    return "\n".join(out)


def demo_rows():
    base = dt.datetime(2026, 10, 9, 14, 5, tzinfo=zone())
    rows = []
    for q, s, cls, n in (
            ("试水名单先发 20 家还是 50 家？", "20 家：批次约定写了先小后大", None, 2701),
            ("要不要开一台云机器跑抓取？", "不开，用 mini2", None, 2702),
            ("合并后 move stable 吗？", "等批末统一发", None, 2703),
            ("旧接口的兼容腿留几个版本？", None, None, 2704)):
        body, row = ask_body(q, s, None, None, cls, now=iso(base), row_id="demo-%d" % n)
        row.update(src="gh:verkyyi/claude-fleet#%d" % n, state="open",
                   url="https://github.com/verkyyi/claude-fleet/issues/%d#issuecomment-1" % n)
        rows.append(row)
    return rows


# ---- GitHub: through the fleet's own channels ------------------------------------

def _seam(name, argv, **kw):
    cmd = os.environ.get(name)
    return subprocess.run((cmd.split() if cmd else []) + argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True, timeout=60, **kw) if cmd else None


def fetch_comments(repo, number):
    r = _seam("FLEET_DECISION_COMMENTS_CMD", [repo, str(number)])
    if r is None:
        r = subprocess.run(["bash", str(BIN / "fleet-ticket.sh"), "read", "gh:%s#%s" % (repo, number),
                            "--json", "comments", "--max-age", "60"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=60)
    if r.returncode != 0:
        raise RuntimeError("cannot read %s#%s: %s" % (repo, number, r.stderr.strip()))
    data = json.loads(r.stdout or "{}")
    return data.get("comments", data) if isinstance(data, dict) else data


def post(repo, number, body, mode="note"):
    r = _seam("FLEET_DECISION_POST_CMD", [repo, str(number), mode], input=body)
    if r is None:
        # fleet-comment.sh writes through fleet_gh_write (共同约定 7); C8's
        # fleet-ticket.sh comment wraps this same script.
        r = subprocess.run(["bash", str(BIN / "fleet-comment.sh"), str(number), "--repo", repo,
                            "--to-worker" if mode == "to-worker" else "--note", "--body-file", "-"],
                           input=body, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
                           timeout=60)
    if r.returncode != 0:
        raise RuntimeError("cannot comment on %s#%s: %s" % (repo, number, r.stderr.strip()))
    return r.stdout.strip()


def parent_of(repo, number):
    r = _seam("FLEET_DECISION_PARENT_CMD", [repo, str(number)])
    if r is None:
        r = subprocess.run(["gh", "api", "repos/%s/issues/%s/parent" % (repo, number), "--jq",
                            '.repository_url + "#" + (.number|tostring)'],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=30)
        if r.returncode != 0:
            return None
        out = r.stdout.strip()
        m = re.match(r"https://api\.github\.com/repos/([^/]+/[^/#]+)#(\d+)$", out)
        return (m.group(1), m.group(2)) if m else None
    m = re.match(r"([^\s#]+)#(\d+)$", r.stdout.strip())
    return (m.group(1), m.group(2)) if m else None


def split_src(src):
    m = re.match(r"gh:([^#]+)#(\d+)$", src or "")
    if not m:
        raise ValueError("not a gh:owner/repo#N source: %r" % src)
    return m.group(1), m.group(2)


def answer_body(row):
    return "\n".join([tr("decision_answer_fmt", row["default"]), "",
                      tr("decision_answer_item_fmt", row["item"], row.get("url", "")), "",
                      "<!-- fleet:answer row=%s by=default -->" % row["id"]])


def record_body(row):
    repo, n = split_src(row["src"])
    return "\n".join([tr("decision_record_fmt", "%s#%s" % (repo, n), row["item"], row["default"]), "",
                      tr("decision_record_why_fmt", row.get("suggest") or "—", show_time(parse_time(row["due"])),
                         row.get("url", "")),
                      tr("decision_record_undo_fmt", "%s#%s" % (repo, n)), "",
                      record_marker(row)])


def record_marker(row):
    """`row=` first (RECORD_RE, the once-only check), then what the daily brief
    prints without re-reading the worker's ticket (issue #2679)."""
    keys = (("src", row.get("src", "")), ("item", row.get("item", "")), ("default", row.get("default", "")),
            ("ask", row.get("url", "")))
    return "<!-- fleet:default-decided row=%s %s -->" % (
        row["id"], " ".join("%s=%s" % (k, quote(str(v), safe="")) for k, v in keys))


def record(row, parent):
    """「默认拍板」 on the parent, once per row (an existing marker is a no-op)."""
    prepo, pn = parent
    for c in fetch_comments(prepo, pn):
        m = RECORD_RE.search(c.get("body") or "")
        if m and m.group(1) == row["id"]:
            return None
    return post(prepo, pn, record_body(row), "note")


def apply_due(row):
    """Answer one due row by its default, then record it. Re-judged right here, so
    a `never` row (or one with nothing to default to) is never answered."""
    if never(row) or row_default(row) is WAIT:
        return {"id": row["id"], "skipped": "never" if never(row) else "wait"}
    repo, n = split_src(row["src"])
    rows = [r for r in parse_comments(fetch_comments(repo, n), repo, n) if r["id"] == row["id"]]
    if not rows or rows[0]["state"] != "open":
        return {"id": row["id"], "skipped": rows[0]["state"] if rows else "gone"}
    answered = post(repo, n, answer_body(row), "to-worker")
    parent = parent_of(repo, n)
    recorded = record(row, parent) if parent else None
    return {"id": row["id"], "answered": answered, "recorded": recorded,
            "parent": "%s#%s" % parent if parent else None}


# ---- the day's 默认拍板 (issue #2679) ---------------------------------------------

def _record_fields(body):
    m = RECORD_FIELDS_RE.search(body)
    kv = {}
    for pair in (m.group(1).split() if m else []):
        k, _, v = pair.partition("=")
        kv[k] = unquote(v)
    return kv


def decided_rows(comments, epic, day):
    """The records on one EPIC posted on `day` (a date in the person's zone)."""
    out = []
    for c in comments:
        body = c.get("body") or ""
        if not RECORD_RE.search(body) or not c.get("createdAt"):
            continue
        at = parse_time(c["createdAt"])
        if at.date() != day:
            continue
        kv = _record_fields(body)
        first = body.split("\n", 1)[0].strip()
        if not kv.get("ask"):                      # a record from before the fields: 「原话：<url>」
            m = re.search(r"https://github\.com/\S+/issues/\d+#issuecomment-\d+", body)
            kv["ask"] = m.group(0) if m else ""
        out.append({"id": kv.get("row", ""), "at": iso(at), "epic": epic, "src": kv.get("src", ""),
                    "item": kv.get("item", ""), "default": kv.get("default", ""), "line": first,
                    "undo": kv.get("ask") or c.get("url") or "", "record": c.get("url") or ""})
    return out


def _sh_lines(argv):
    try:
        r = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
                           timeout=60)
    except (OSError, subprocess.SubprocessError):
        return []
    return [x.strip() for x in r.stdout.splitlines() if x.strip()] if r.returncode == 0 else []


def day_epics(day, repos):
    """Every EPIC ticket a record of `day` can sit on: `epic` tickets updated since
    that day in each hosted repo (a record bumps its EPIC's updatedAt), plus the
    running marks (global/epic-running.d)."""
    r = _seam("FLEET_DECISION_EPICS_CMD", [day.isoformat()])
    if r is not None:
        return [x.strip() for x in r.stdout.splitlines() if x.strip()]
    if not repos:
        repos = _sh_lines(["bash", "-c", '. "$1/fleet-lib.sh" >/dev/null 2>&1; fleet_repos "${FLEET_SESSION:-fleet}"',
                           "_", str(BIN)])
    out = []
    for repo in repos:
        for line in _sh_lines(["bash", str(BIN / "fleet-ticket.sh"), "list", "--repo", repo, "--label", "epic",
                               "--state", "all", "--since", (day - dt.timedelta(days=1)).isoformat()]):
            out.append(line.split("\t", 1)[0])
    gd = Path(os.environ.get("FLEET_CONF_DIR") or (Path.home() / ".config" / "claude-fleet")) / "global"
    for f in sorted((gd / "epic-running.d").glob("*")):
        try:
            kv = dict(line.split(": ", 1) for line in f.read_text().splitlines() if ": " in line)
        except (OSError, ValueError):
            continue
        e, rp = kv.get("epic", "").strip(), kv.get("repo", "").strip()
        if e.isdigit() and "/" in rp:
            out.append("gh:%s#%s" % (rp, e))
    return out


def decided(day, epics):
    seen, rows, failed = set(), [], []
    for e in epics:
        m = TICKET_RE.match(e)
        if not m or (m.group(1), m.group(2)) in seen:
            continue
        seen.add((m.group(1), m.group(2)))
        try:
            got = decided_rows(fetch_comments(m.group(1), m.group(2)), "gh:%s#%s" % (m.group(1), m.group(2)), day)
        except (RuntimeError, ValueError, subprocess.SubprocessError) as err:
            failed.append("%s: %s" % (e, err))
            continue
        rows += [x for x in got if not x["id"] or x["id"] not in {y["id"] for y in rows}]
    rows.sort(key=lambda x: x["at"])
    return rows, failed


def decided_md(rows, day):
    out = ["### " + tr("decision_digest_head_fmt", day.strftime("%m-%d"), len(rows))]
    if not rows:
        return "\n".join(out + ["", tr("decision_digest_none")])
    out.append("")
    for x in rows:
        hm = parse_time(x["at"]).strftime("%H:%M")
        if x["item"]:
            src = x["src"][3:] if x["src"].startswith("gh:") else x["src"]
            what = tr("decision_digest_line_fmt", src, x["item"], x["default"])
        else:
            what = x["line"]
        link = " · [%s](%s)" % (tr("decision_digest_undo"), x["undo"]) if x["undo"] else ""
        out.append("- %s %s%s" % (hm, _cell(what), link))
    return "\n".join(out)


# ---- CLI -----------------------------------------------------------------------

def _read_rows(path):
    text = sys.stdin.read() if path == "-" else Path(path).read_text()
    text = text.strip()
    if text.startswith("["):
        return json.loads(text)
    return [json.loads(line) for line in text.splitlines() if line.strip()]


def _rows_of(path):
    """--rows: a JSON list, JSON lines, or a steward state (its `rows` map)."""
    text = sys.stdin.read() if path == "-" else Path(path).read_text()
    text = text.strip()
    if text.startswith("{") and "\n{" not in text:
        d = json.loads(text)
        if isinstance(d.get("rows"), dict):
            return list(d["rows"].values())
        return [d]
    if text.startswith("["):
        return json.loads(text)
    return [json.loads(line) for line in text.splitlines() if line.strip()]


def _emit(rows):
    for r in rows:
        print(json.dumps(r, ensure_ascii=False, sort_keys=True))


def main(argv=None):
    ap = argparse.ArgumentParser(prog="fleet_decision.py")
    sub = ap.add_subparsers(dest="cmd")
    a = sub.add_parser("ask-body")
    a.add_argument("--question", required=True)
    a.add_argument("--suggest")
    a.add_argument("--default")
    a.add_argument("--due")
    a.add_argument("--class", dest="cls")
    a.add_argument("--head", default="question", choices=sorted(ASK_HEAD))
    a.add_argument("--now")
    p = sub.add_parser("parse")
    p.add_argument("--repo")
    p.add_argument("--issue")
    p.add_argument("--comments-json")
    r = sub.add_parser("render")
    r.add_argument("--demo", action="store_true")
    r.add_argument("--rows")
    r.add_argument("--id")
    r.add_argument("--samples")
    g = sub.add_parser("group")
    g.add_argument("--rows", default="-")
    d = sub.add_parser("due")
    d.add_argument("--rows")
    d.add_argument("--repo")
    d.add_argument("--issue", action="append", default=[])
    d.add_argument("--now")
    d.add_argument("--apply", action="store_true")
    c = sub.add_parser("record")
    c.add_argument("--row", required=True)
    c.add_argument("--parent", required=True)
    k = sub.add_parser("decided")
    k.add_argument("--date")
    k.add_argument("--epic", action="append", default=[])
    k.add_argument("--repo", action="append", default=[])
    k.add_argument("--json", action="store_true")
    o = ap.parse_args(argv)

    if o.cmd == "ask-body":
        body, _ = ask_body(o.question, o.suggest, o.default, o.due, o.cls, o.head, o.now)
        print(body)
    elif o.cmd == "parse":
        if o.comments_json:
            data = json.loads(sys.stdin.read() if o.comments_json == "-" else Path(o.comments_json).read_text())
            comments = data.get("comments", []) if isinstance(data, dict) else data
        elif o.repo and o.issue:
            comments = fetch_comments(o.repo, o.issue)
        else:
            ap.error("parse needs --comments-json, or --repo and --issue")
        _emit(parse_comments(comments, o.repo, o.issue))
    elif o.cmd == "render":
        rows = demo_rows() if o.demo else _read_rows(o.rows or "-")
        samples = json.loads(Path(o.samples).read_text()) if o.samples else None
        print(render(rows, o.id or ("demo" if o.demo else None), samples))
    elif o.cmd == "group":
        _emit(group(_rows_of(o.rows)))
    elif o.cmd == "due":
        if o.rows:
            rows = _read_rows(o.rows)
        elif o.repo and o.issue:
            rows = [x for n in o.issue for x in parse_comments(fetch_comments(o.repo, n), o.repo, n)]
        else:
            ap.error("due needs --rows, or --repo and --issue")
        now = now_local(o.now)
        due = [x for x in rows if is_due(x, now)]
        if not o.apply:
            _emit(due)
            return 0
        rc = 0
        for x in due:
            try:
                _emit([apply_due(x)])
            except (RuntimeError, ValueError, subprocess.SubprocessError) as e:
                print("fleet_decision: %s: %s" % (x.get("id"), e), file=sys.stderr)
                rc = 1
        return rc
    elif o.cmd == "record":
        row = json.loads(o.row)
        m = re.match(r"([^\s#]+)#(\d+)$", o.parent)
        if not m:
            ap.error("--parent is owner/repo#N")
        out = record(row, (m.group(1), m.group(2)))
        print(out or "already recorded")
    elif o.cmd == "decided":
        m = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})", o.date or "")
        if o.date and not m:
            ap.error("--date is YYYY-MM-DD")
        try:
            day = dt.date(*map(int, m.groups())) if m else now_local().date()
        except ValueError:
            ap.error("--date is YYYY-MM-DD")
        rows, failed = decided(day, o.epic or day_epics(day, o.repo))
        for f in failed:
            print("fleet_decision: cannot read %s" % f, file=sys.stderr)
        if o.json:
            _emit(rows)
        else:
            print(decided_md(rows, day))
        return 1 if failed else 0
    else:
        ap.print_help(sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
