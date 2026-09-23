#!/usr/bin/env python3
"""fleet-report-stats.py — the five child-report quality metrics of EPIC #935 (issue #941).

    fleet-report-stats.py [--since <iso|date|live>] [--until <iso|date>] [--repo <slug>] [--json]
                          [--projects <dir>] [--ledger-root <dir>]

Read-only. Scans Claude transcripts (~/.claude/projects/**/*.jsonl) and the
child-report ledgers ($FLEET_CONF_DIR/fleets/*/children/*.ndjson) and prints one
5-row table — the same numbers the EPIC's design page lists under 「现在」, so a
batch report (and every later re-read) gets them from one command instead of a
one-off analysis script.

What counts as a report: a user entry whose text is a peer delivery
(`<cross-session-message …>`) carrying `[child-report] <child>\nstate: <STATE> · branch`.
Quoted reports — a tool_result that printed a transcript, a selftest's expected
envelope, a status-classifier screen — are NOT deliveries and never count.
Reports are deduplicated on (timestamp, child, state): a forked or copied
transcript carries the same entry twice.

The five rows (口径 = the EPIC page's 「怎么量」):

  1 misfire     STOPPED reports whose child still wrote an assistant entry AFTER
                the report ÷ STOPPED reports whose child transcript was found
                (`*-issue-<N>/*.jsonl`, the one whose last entry at report time is
                newest). A scratch child has no issue transcript → unresolved.
  2 stopped     STOPPED ÷ all delivered child-reports.
  3 wake        parent wake-ups (delivered [child-report] + [children-digest]
                messages) ÷ report events (ledger events ∪ delivered reports that
                match no ledger event — so pre-ledger history is 1.0 by definition).
  4 verify      mean tool_use calls the parent made after a STOPPED report, up to
                its next user message that is not a tool_result (the baseline's
                definition); the JSON also carries the mean over every report.
  5 dup         STOPPED/REAPED reports for a child that had already reported
                MERGED — delivered to this same parent, or visible in the child's
                own transcript as a `fleet-report-parent.sh --state merged` call
                (a MERGED the parent never got still means the work had landed).

--since / --until take an ISO instant, a date (local midnight; --until <date>
includes that whole day), or for --since, `live`: the last time the live install
(~/.claude/fleet) moved, from its git reflog — the 「只统计本机 live install 同步之后」
window for reading a fix after it lands.
"""

import argparse
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
import glob
import json
import os
import re
import subprocess
import sys

REPORT_RX = re.compile(r"\[child-report\] (.*?)\nstate: (\S+)(?: \(([^)\n]*)\))? · branch (\S+)")
DIGEST = "[children-digest]"
ENVELOPE = "<cross-session-message"
ENVELOPE_B, REPORT_B, DIGEST_B = ENVELOPE.encode(), b"[child-report]", DIGEST.encode()
CHILD_RX = re.compile(r"^(?:(\S+/\S+) )?(issue #|scratch ~)(\d+)")
LEDGER_MATCH_SECS = 1800     # a queued delivery can land well after the ledger write
VERIFY_CMDS = ("gh pr", "capture-pane", "gh run", "git log")


def parse_ts(value):
    try:
        t = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


def parse_bound(value, end=False, live_dir=None):
    """--since/--until → aware datetime. A bare date is LOCAL midnight; as an --until
    it means 'through that day' (the next local midnight, exclusive)."""
    if value is None:
        return None
    if value == "live" and not end:
        return live_sync_time(live_dir)
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        d = datetime.strptime(value, "%Y-%m-%d").astimezone()   # local tz
        return d + timedelta(days=1) if end else d
    t = parse_ts(value)
    if t is None:
        raise SystemExit("fleet-report-stats: not a date/ISO time: %r" % value)
    return t


def live_sync_time(live_dir):
    d = live_dir or os.path.expanduser("~/.claude/fleet")
    try:
        out = subprocess.run(["git", "-C", d, "log", "-g", "-1", "--date=iso-strict", "--format=%gd"],
                             capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        out = ""
    m = re.search(r"\{(.+)\}", out)
    t = parse_ts(m.group(1)) if m else None
    if t is None:
        raise SystemExit("fleet-report-stats: --since live: no reflog in %s" % d)
    return t


def entry_text(entry):
    """The delivered text of a user entry — plain string or text blocks. Never a
    tool_result: that is a quote of a report, not a delivery."""
    c = (entry.get("message") or {}).get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(b.get("text", "") for b in c
                         if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str))
    return ""


def is_tool_result_carrier(entry):
    c = (entry.get("message") or {}).get("content")
    return isinstance(c, list) and any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c)


def load_jsonl(path):
    out = []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        pass
    return out


def repo_matches(slug, text):
    """Does a transcript dir / ledger session / label prefix belong to repo <slug>?"""
    if not slug or not text:
        return False
    if text == slug:
        return True
    name = re.escape(slug.rstrip("/").split("/")[-1])
    return re.search(r"(^|[-/])%s($|[-/:])" % name, text) is not None


def child_key(label):
    """`verkyyi/x issue #12 "title"` → ('verkyyi/x', 'issue', '12'); unknown → None."""
    m = CHILD_RX.match(label)
    if not m:
        return None
    return (m.group(1) or "", "issue" if m.group(2).startswith("issue") else "scratch", m.group(3))


class Scan:
    def __init__(self, projects, ledger_root, since, until, repo):
        self.projects, self.ledger_root = projects, ledger_root
        self.since, self.until, self.repo = since, until, repo
        self.files = {}       # path → entries (parent transcripts only)
        self._child = {}      # child transcript cache

    def in_window(self, t):
        return t is not None and (self.since is None or t >= self.since) and (self.until is None or t < self.until)

    def wanted(self, parent_dir, prefix):
        if not self.repo:
            return True
        return repo_matches(self.repo, prefix) if prefix else repo_matches(self.repo, parent_dir)

    # --- parent side: deliveries -------------------------------------------------
    def deliveries(self):
        reports, wakes = {}, {}
        for path in sorted(glob.glob(os.path.join(self.projects, "**", "*.jsonl"), recursive=True)):
            try:
                with open(path, "rb") as fh:
                    blob = fh.read()
            except OSError:
                continue
            # bytes first: most of ~/.claude/projects never received a report, and
            # decoding gigabytes only to find that out is most of the runtime.
            if ENVELOPE_B not in blob or (REPORT_B not in blob and DIGEST_B not in blob):
                continue
            raw = blob.decode("utf-8", errors="replace")
            entries = []
            for line in raw.splitlines():
                try:
                    entries.append(json.loads(line))
                except ValueError:
                    continue
            self.files[path] = entries
            parent = os.path.basename(os.path.dirname(path))
            for i, e in enumerate(entries):
                if e.get("type") != "user":
                    continue
                text = entry_text(e)
                if ENVELOPE not in text:
                    continue
                ts = parse_ts(e.get("timestamp"))
                if not self.in_window(ts):
                    continue
                found = list(REPORT_RX.finditer(text))
                kept = False
                for m in found:
                    key = child_key(m.group(1))
                    if not self.wanted(parent, key[0] if key else ""):
                        continue
                    kept = True
                    dk = (e.get("timestamp"), m.group(1), m.group(2), m.group(3) or "")
                    reports.setdefault(dk, dict(ts=ts, file=path, idx=i, parent=parent, label=m.group(1),
                                                child=key, state=m.group(2), detail=m.group(3) or ""))
                if DIGEST in text and self.wanted(parent, ""):
                    kept = True
                if kept:
                    wakes.setdefault((e.get("timestamp"), text[:200]), dict(ts=ts, digest=DIGEST in text))
        return sorted(reports.values(), key=lambda r: (r["ts"], r["file"])), list(wakes.values())

    # --- the ledger ----------------------------------------------------------------
    def ledger_events(self):
        out = []
        for path in sorted(glob.glob(os.path.join(self.ledger_root, "*", "children", "*.ndjson"))):
            sess = os.path.basename(os.path.dirname(os.path.dirname(path)))
            for ev in load_jsonl(path):
                if not isinstance(ev, dict):
                    continue
                ts = parse_ts(ev.get("ts"))
                if not self.in_window(ts):
                    continue
                child = str(ev.get("child", ""))
                prefix, _, bare = child.rpartition(":")
                if not self.wanted(sess, prefix):
                    continue
                m = re.fullmatch(r"(issue|scratch)-(\d+)", bare)
                out.append(dict(ts=ts, state=str(ev.get("state", "")),
                                child=(prefix, m.group(1), m.group(2)) if m else None))
        return out

    # --- child side: did it keep working after the report? ---------------------------
    def child_transcripts(self, report):
        """{path: [(ts, type, sent_merged)]} for the report's child — its `*-issue-<N>`
        transcripts, narrowed to the child's repo when one is known."""
        key = report["child"]
        if not key or key[1] != "issue":
            return {}
        cands = glob.glob(os.path.join(self.projects, "*-issue-%s" % key[2], "*.jsonl"))
        slug = key[0] or self.repo_of_parent(report["parent"])
        if slug:
            same = [c for c in cands if repo_matches(slug, os.path.basename(os.path.dirname(c)))]
            cands = same or cands
        out = {}
        for path in cands:
            if path not in self._child:
                self._child[path] = [(parse_ts(e.get("timestamp")), e.get("type"), sent_merged(e))
                                     for e in load_jsonl(path) if e.get("timestamp")]
            out[path] = self._child[path]
        return out

    def child_after(self, report):
        """True/False = the child did / did not write an assistant entry after the
        report; None = no issue transcript to judge by."""
        best = None
        for entries in self.child_transcripts(report).values():
            prev = [t for t, _, _ in entries if t and t <= report["ts"]]
            if prev and (best is None or max(prev) > best[0]):
                best = (max(prev), entries)
        if best is None:
            return None
        return any(t and t > report["ts"] and typ == "assistant" for t, typ, _ in best[1])

    def child_sent_merged_before(self, report):
        """Had the child itself already run `fleet-report-parent.sh --state merged`?
        A MERGED the parent never received (a migrated or re-spawned parent) is
        still one the child sent — the report after it is the duplicate."""
        return any(m and t and t < report["ts"]
                   for entries in self.child_transcripts(report).values() for t, _, m in entries)

    def repo_of_parent(self, parent_dir):
        return self.repo if self.repo and repo_matches(self.repo, parent_dir) else ""

    # --- parent's follow-up after a report ----------------------------------------------
    def tool_uses_after(self, report):
        entries = self.files.get(report["file"], [])
        n, cmds = 0, Counter()
        for e in entries[report["idx"] + 1:]:
            if e.get("type") == "user":
                if is_tool_result_carrier(e):
                    continue
                break
            if e.get("type") != "assistant":
                continue
            for b in (e.get("message") or {}).get("content") or []:
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    n += 1
                    cmd = str((b.get("input") or {}).get("command", ""))
                    for k in VERIFY_CMDS:
                        if k in cmd:
                            cmds[k] += 1
        return n, cmds


# A merged report RUN as a command — not one quoted in a heredoc (a handoff doc
# telling the next session to send it) or an echo.
MERGED_CALL = re.compile(r"(?:^|[;&|(]|\n)[ \t]*(?:\S*/)?fleet-report-parent\.sh\b[^\n]*--state[ =]merged\b")
HEREDOC = re.compile(r"<<-?[ \t]*(['\"]?)(\w+)\1[^\n]*\n.*?\n[ \t]*\2[ \t]*(?=\n|$)", re.S)


def sent_merged(entry):
    if entry.get("type") != "assistant":
        return False
    for b in (entry.get("message") or {}).get("content") or []:
        if isinstance(b, dict) and b.get("type") == "tool_use":
            cmd = str((b.get("input") or {}).get("command", "")).replace("\\\n", " ")
            if MERGED_CALL.search(HEREDOC.sub("", cmd)):
                return True
    return False


def ratio(num, den):
    return (num / den) if den else None


def compute(scan):
    reports, wakes = scan.deliveries()
    events = scan.ledger_events()
    states = Counter(r["state"] for r in reports)
    counted = [r for r in reports if r["state"] not in ("WAITING", "IDLE")]
    stopped = [r for r in counted if r["state"] == "STOPPED"]

    # 1 misfire
    judged = [(r, scan.child_after(r)) for r in stopped]
    resolved = [(r, a) for r, a in judged if a is not None]
    misfires = sum(1 for _, a in resolved if a)

    # 3 wake: ledger events ∪ deliveries that match none of them
    pool = defaultdict(list)
    for ev in events:
        if ev["child"]:
            pool[(ev["child"][1], ev["child"][2], ev["state"])].append(ev["ts"])
    for v in pool.values():
        v.sort()
    unmatched = 0
    for r in reports:
        k = (r["child"][1], r["child"][2], r["state"]) if r["child"] else None
        cand = pool.get(k, [])
        hit = next((t for t in cand if t <= r["ts"] <= t + timedelta(seconds=LEDGER_MATCH_SECS)), None)
        if hit is None:
            unmatched += 1
        else:
            cand.remove(hit)
    denom = len(events) + unmatched

    # 4 verify
    per, cmds, all_n = [], Counter(), []
    for r in reports:
        n, c = scan.tool_uses_after(r)
        all_n.append(n)
        if r["state"] == "STOPPED":
            per.append(n)
            cmds.update(c)

    # 5 dup after MERGED (same parent, same child)
    merged_at, dups = {}, []
    for r in reports:
        if not r["child"]:
            continue
        k = (r["parent"], r["child"][1], r["child"][2])
        if r["state"] == "MERGED":
            merged_at.setdefault(k, r["ts"])
        elif r["state"] in ("STOPPED", "REAPED") and (k in merged_at or scan.child_sent_merged_before(r)):
            dups.append(r)

    return dict(
        window=dict(since=scan.since.isoformat() if scan.since else None,
                    until=scan.until.isoformat() if scan.until else None, repo=scan.repo or None),
        reports=len(reports), states=dict(states),
        misfire=dict(value=ratio(misfires, len(resolved)), misfires=misfires, resolved=len(resolved),
                     unresolved=len(judged) - len(resolved)),
        stopped_share=dict(value=ratio(len(stopped), len(counted)), stopped=len(stopped), reports=len(counted)),
        wake=dict(value=ratio(len(wakes), denom), wakes=len(wakes), digests=sum(1 for w in wakes if w["digest"]),
                  events=denom, ledger_events=len(events), unledgered_reports=unmatched),
        verify=dict(value=ratio(sum(per), len(per)), tool_uses=sum(per), reports=len(per), commands=dict(cmds),
                    all_reports_mean=ratio(sum(all_n), len(all_n))),
        dup_after_merged=dict(value=len(dups), cases=[dict(parent=d["parent"], child=d["label"].split(' "')[0],
                                                             state=d["state"], ts=d["ts"].isoformat())
                                                        for d in dups]),
    )


def pct(v):
    return "—" if v is None else "%.1f%%" % (v * 100)


def num(v, fmt="%.2f"):
    return "—" if v is None else fmt % v


def render(s):
    m, st, w, vf, d = s["misfire"], s["stopped_share"], s["wake"], s["verify"], s["dup_after_merged"]
    top = ", ".join("%s %d" % kv for kv in sorted(vf["commands"].items(), key=lambda kv: -kv[1])[:2])
    dup_children = ", ".join(sorted({c["child"] for c in d["cases"]}))
    rows = [
        ("「已停下」回报中的误报", pct(m["value"]),
         "%d / %d%s" % (m["misfires"], m["resolved"], " · 无子会话记录 %d" % m["unresolved"] if m["unresolved"] else "")),
        ("「已停下」回报在全部回报中的占比", pct(st["value"]), "%d / %d" % (st["stopped"], st["reports"])),
        ("主会话被叫醒的次数 ÷ 回报条数", num(w["value"]),
         "%d / %d（摘要 %d · 账本 %d）" % (w["wakes"], w["events"], w["digests"], w["ledger_events"])),
        ("主会话每收到一条回报，为核实多做的操作", num(vf["value"], "%.1f 次"),
         "%d / %d%s" % (vf["tool_uses"], vf["reports"], " · " + top if top else "")),
        ("合并以后又收到的重复回报", "%d 例" % d["value"], dup_children or "—"),
    ]
    out = ["| 指标 | 现在 | 分子 / 分母 |", "|---|---|---|"]
    out += ["| %s | %s | %s |" % r for r in rows]
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description="EPIC #935 child-report quality metrics (read-only)")
    ap.add_argument("--since")
    ap.add_argument("--until")
    ap.add_argument("--repo", help="owner/name — only reports whose child/parent belongs to it")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--projects", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--ledger-root", default=os.path.join(
        os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet"), "fleets"))
    ap.add_argument("--live-dir", help=argparse.SUPPRESS)
    a = ap.parse_args(argv)
    since = parse_bound(a.since, live_dir=a.live_dir)
    until = parse_bound(a.until, end=True)
    s = compute(Scan(a.projects, a.ledger_root, since, until, a.repo))
    if a.json:
        json.dump(s, sys.stdout, ensure_ascii=False, indent=2)
        print()
    else:
        print(render(s))
    return 0


if __name__ == "__main__":
    sys.exit(main())
