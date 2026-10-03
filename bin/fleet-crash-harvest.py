#!/usr/bin/env python3
"""fleet-crash-harvest.py — summarize the machine's own crash reports (issue #1294).

WHY: the Mac mini froze and rebooted twice in a week (2026-09-27, 2026-10-03).
Answering "why" took over an hour of walking /Library/Logs/DiagnosticReports by
hand and decoding multi-MB JSON reports one at a time. Both report kinds the
kernel leaves behind are plain JSON after a one-line header, so this reads them:

  panic-*.panic       panicString's first line (what killed the kernel) and its
                      "Compressor Info:" line (100% (BAD) = memory exhaustion),
                      plus the five largest resident processes at panic time when
                      the report carries processByPid (a `panic-full`).
  JetsamEvent-*.ips   largestProcess, and the five processes holding the most
                      pages — pages × pageSize, so `git … 336.0 GB` reads as such.

and, when --metrics-dir holds the fleet's own per-minute machine rows
(bin/fleet-diskguard.sh writes them, memguard every 10s under pressure), how
much of the run-up to each panic was recorded: the evidence the reports lack.

Called by `fleet-diskguard.sh --harvest-crash` (and its boot-change tick). It
prints the markdown summary of the selected reports on stdout; with --record it
appends every report it has not seen before to the --seen ledger and writes their
summary to <machine-dir>/incident-<stamp>.md, whose path goes to --path-file.
A report already in the ledger is never recorded twice.

Exit 0 = at least one report selected, 1 = none, 2 = usage.
"""
import argparse
import datetime as dt
import glob
import json
import os
import re
import sys

STAMP_RE = re.compile(r"(\d{4}-\d{2}-\d{2})-(\d{2})(\d{2})(\d{2})")
KINDS = (("panic-", "panic"), ("JetsamEvent-", "jetsam"))


def kind_of(name):
    for prefix, kind in KINDS:
        if name.startswith(prefix):
            return kind
    return None


def name_iso(name):
    """The local timestamp the system wrote into the report's NAME."""
    m = STAMP_RE.search(name)
    if not m:
        return None
    return "%sT%s:%s:%s" % m.groups()


def norm_since(s):
    s = (s or "").strip().replace(" ", "T")
    if not s:
        return ""
    if len(s) == 10:            # a bare date
        s += "T00:00:00"
    elif len(s) == 16:          # YYYY-MM-DDTHH:MM
        s += ":00"
    return s[:19]


def load(path):
    """(header, body) dicts — the reports are a JSON header line + a JSON body."""
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    head, _, body = text.partition("\n")
    try:
        header = json.loads(head)
    except ValueError:
        header = {}
    try:
        return header, json.loads(body)
    except ValueError:
        # an older/odd report: the whole file is one object
        return header, json.loads(text)


def report_epoch(header, body):
    for d in (body.get("date"), header.get("timestamp")):
        if not d:
            continue
        for fmt in ("%Y-%m-%d %H:%M:%S.%f %z", "%Y-%m-%d %H:%M:%S %z"):
            try:
                return dt.datetime.strptime(d, fmt).timestamp()
            except ValueError:
                pass
    return None


def gb(nbytes):
    return "%.1f GB" % (nbytes / 1073741824.0) if nbytes >= 1073741824 else "%d MB" % (nbytes // 1048576)


def summarize_panic(body):
    lines = (body.get("panicString") or "").split("\n")
    first = next((l.strip() for l in lines if l.strip()), "(no panicString)")
    comp = next((l.strip() for l in lines if l.strip().startswith("Compressor Info")), "")
    out = {"panic": first, "compressor": comp, "top": []}
    procs = body.get("processByPid")
    if isinstance(procs, dict):
        rows = []
        for p in procs.values():
            if isinstance(p, dict) and isinstance(p.get("residentMemoryBytes"), int):
                rows.append((p["residentMemoryBytes"], p.get("procname", "?"), p.get("pid", "?")))
        rows.sort(reverse=True)
        out["top"] = ["%s (pid %s) %s" % (n, pid, gb(b)) for b, n, pid in rows[:5]]
    return out


def summarize_jetsam(body):
    ms = body.get("memoryStatus") or {}
    page = ms.get("pageSize") or body.get("pageSize") or 16384
    rows = []
    for p in body.get("processes") or []:
        pages = p.get("rpages") or 0
        rows.append((pages, p.get("name", "?"), p.get("pid", "?"), p.get("reason")))
    rows.sort(key=lambda r: -r[0])
    largest = body.get("largestProcess") or (rows[0][1] if rows else "?")
    largest_b = next((r[0] * page for r in rows if r[1] == largest), 0)
    top = []
    for pages, name, pid, reason in rows[:5]:
        top.append("%s (pid %s) %s%s" % (name, pid, gb(pages * page), " · killed: %s" % reason if reason else ""))
    mp = ms.get("memoryPages") or {}
    mem = ""
    if mp:
        mem = "free %s · compressor %s" % (gb((mp.get("free") or 0) * page), gb((ms.get("compressorSize") or 0) * page))
    return {"largest": largest, "largest_size": gb(largest_b) if largest_b else "", "top": top, "memory": mem}


def metrics_rows(mdir):
    rows = []
    for f in sorted(glob.glob(os.path.join(mdir, "metrics-*.tsv"))):
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if line.startswith("#") or not line.strip():
                        continue
                    cols = line.rstrip("\n").split("\t")
                    try:
                        t = dt.datetime.strptime(cols[0], "%Y-%m-%dT%H:%M:%S%z").timestamp()
                    except ValueError:
                        continue
                    rows.append((t, line.rstrip("\n")))
        except OSError:
            continue
    rows.sort()
    return rows


def coverage(rows, crash_t, gap=180):
    """Minutes of CONTIGUOUS fleet metrics right before crash_t (no gap > `gap`s)."""
    before = [r for r in rows if r[0] <= crash_t]
    if not before:
        return None
    last = before[-1][0]
    start = last
    n = 1
    for t, _ in reversed(before[:-1]):
        if start - t > gap:
            break
        start = t
        n += 1
    return {"minutes": (last - start) / 60.0, "lag": crash_t - last, "rows": n, "tail": [l for _, l in before[-3:]]}


def headline(items):
    parts = []
    for it in items:
        if it["kind"] == "panic":
            p = re.sub(r"^panic\(cpu \d+ caller 0x[0-9a-f]+\):\s*", "", it["s"]["panic"])
            p = re.sub(r"\s*\([^()]*\)$", "", p)          # "(54622 total checkins …)"
            parts.append("%s panic: %s" % (it["when"], p[:90]))
            m = re.search(r"(\d+)% of compressed pages limit \((\w+)\)", it["s"]["compressor"])
            if m:
                parts.append("compressor %s%% (%s)" % m.groups())
            if it["s"]["top"]:
                parts.append("top=%s" % re.sub(r" \(pid \S+\)", "", it["s"]["top"][0]))
        elif it["kind"] == "jetsam":
            parts.append("%s jetsam largest=%s%s" % (it["when"], it["s"]["largest"],
                                                     " (%s)" % it["s"]["largest_size"] if it["s"]["largest_size"] else ""))
    return " · ".join(parts)


def render(items, mrows, title):
    out = ["# %s" % title, "", "headline: %s" % headline(items), ""]
    for it in items:
        out.append("## %s — %s" % (it["name"], it["when"]))
        s = it["s"]
        if it["kind"] == "error":
            out.append("- unreadable: %s" % s)
        elif it["kind"] == "panic":
            out.append("- panic: `%s`" % s["panic"])
            if s["compressor"]:
                out.append("- compressor: `%s`" % s["compressor"])
            if s["top"]:
                out.append("- largest resident at panic: " + "; ".join(s["top"]))
            cov = coverage(mrows, it["epoch"]) if (mrows is not None and it["epoch"]) else None
            if mrows is not None:
                if cov:
                    out.append("- fleet metrics before the panic: %.0f min contiguous (%d rows), last row %ds before it"
                               % (cov["minutes"], cov["rows"], int(cov["lag"])))
                    for l in cov["tail"]:
                        out.append("    %s" % l)
                else:
                    out.append("- fleet metrics before the panic: none recorded")
        else:
            out.append("- largest process: **%s**%s" % (s["largest"], " (%s)" % s["largest_size"] if s["largest_size"] else ""))
            if s["top"]:
                out.append("- top 5 by pages: " + "; ".join(s["top"]))
            if s["memory"]:
                out.append("- memory: %s" % s["memory"])
        out.append("")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--since", default="")
    ap.add_argument("--seen", default="")
    ap.add_argument("--new-only", action="store_true", help="select only reports not in --seen")
    ap.add_argument("--record", action="store_true", help="append new reports to --seen + write the incident")
    ap.add_argument("--machine-dir", default="")
    ap.add_argument("--metrics-dir", default="")
    ap.add_argument("--path-file", default="")
    ap.add_argument("--host", default="")
    a = ap.parse_args()

    since = norm_since(a.since)
    seen = set()
    if a.seen and os.path.exists(a.seen):
        with open(a.seen, encoding="utf-8", errors="replace") as f:
            seen = {l.strip() for l in f if l.strip()}

    cands = []
    try:
        names = os.listdir(a.dir)
    except OSError:
        names = []
    for n in names:
        k = kind_of(n)
        iso = name_iso(n)
        if not k or not iso or (since and iso < since):
            continue
        if a.new_only and n in seen:
            continue
        cands.append((iso, n, k))
    cands.sort()
    if not cands:
        return 1

    items = []
    for iso, n, k in cands:
        when = iso.replace("T", " ")[:16]
        try:
            header, body = load(os.path.join(a.dir, n))
            s = summarize_panic(body) if k == "panic" else summarize_jetsam(body)
            items.append({"name": n, "kind": k, "when": when, "s": s, "epoch": report_epoch(header, body)})
        except (OSError, ValueError) as e:
            items.append({"name": n, "kind": "error", "when": when, "s": str(e)[:200], "epoch": None})

    mrows = metrics_rows(a.metrics_dir) if a.metrics_dir else None
    host = (" · " + a.host) if a.host else ""
    sys.stdout.write(render(items, mrows, "crash reports%s · %s" % (host, ", ".join(i["when"] for i in items))))

    if a.record:
        new = [i for i in items if i["name"] not in seen]
        if new and a.machine_dir:
            os.makedirs(a.machine_dir, exist_ok=True)
            stamp = re.sub(r"[^0-9]", "", new[-1]["when"])  # YYYYMMDDHHMM of the newest
            path = os.path.join(a.machine_dir, "incident-%s-%s.md" % (stamp[:8], stamp[8:]))
            with open(path, "w", encoding="utf-8") as f:
                f.write(render(new, mrows, "死机报告摘要%s · %s" % (host, ", ".join(i["when"] for i in new))))
                f.write("source: %s\n" % a.dir)
            if a.path_file:
                with open(a.path_file, "w", encoding="utf-8") as f:
                    f.write(path + "\n")
        if new and a.seen:
            with open(a.seen, "a", encoding="utf-8") as f:
                for i in new:
                    f.write(i["name"] + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
