#!/usr/bin/env python3
"""fleet-nightly-report.py — the nightly full run's two readings (T517, EPIC T516 C1).

  summary   --jobs FILE --results DIR [--planned JSON] [--started ISO] [--repo R]
      The 全量 line, and which red shards never ran. Every Linux shard either left
      its `train-result-Linux-<K>` artifact (it ran: a red there is a red TEST, named
      by its FAIL / TIMEOUT lines) or did not. A shard with no artifact never ran a
      step — 2026-10-14..19 every one of them was refused by the fleet-ack runner's
      job gate (bin/fleet-ci-job-gate.sh: «this runner takes only the merged train»),
      and the run read as six red nights of tests. So such a shard's job log is
      asked for the gate's `refused:` line (`gh api …/actions/jobs/<id>/logs`), and
      the summary says 拒收 (or 没跑) — never 测试红. Exit 1 when any shard did not
      run, else 0 (a red test already reds its own shard).
      --jobs is the run's jobs as TSV: name · conclusion · started · completed · id.

  baseline  --results DIR [--bin DIR] [--run ID] [--sha SHA]
      `baseline.json` on stdout, the batch's starting numbers (the selftests-baseline
      artifact): files / lines = bin/*selftest*, tests / per_test{} / seconds_total /
      seconds_breakit off every shard's train-times.txt (a test seen twice — a
      cut-short attempt and its rerun — counts its last). A batch report reads the
      same format to compare.

Env: FLEET_NR_GH  the gh to ask for a job's log (default gh) — a selftest seam.
"""
import argparse
import datetime
import glob
import json
import os
import re
import subprocess
import sys

SHARD_RE = re.compile(r"^Linux / shard (\d+)$")
TIME_RE = re.compile(r"^(PASS|FAIL|TIMEOUT|FLAKY) +([A-Za-z0-9_.+-]+-selftest\.(?:sh|py)(?:#[0-9]+)?) +([0-9]+(?:\.[0-9]+)?)s")
RED_RE = re.compile(r"^(FAIL|TIMEOUT) +(\S+)")
REFUSED_RE = re.compile(r"fleet-ci: .*refused: .*")


def ts(s):
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ") if s else None
    except ValueError:
        return None


def shard_dirs(results):
    out = {}
    for d in glob.glob(os.path.join(results, "train-result-Linux-*")):
        k = d.rsplit("-", 1)[-1]
        if k.isdigit() and os.path.isdir(d):
            out[int(k)] = d
    return out


def refused_line(repo, job_id):
    if not repo or not job_id:
        return ""
    gh = os.environ.get("FLEET_NR_GH", "gh")
    try:
        log = subprocess.run([gh, "api", "repos/%s/actions/jobs/%s/logs" % (repo, job_id)],
                             capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    m = REFUSED_RE.search(log or "")
    return m.group(0).strip() if m else ""


def summary(a):
    rows = []
    for line in open(a.jobs, encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        if len(f) >= 2 and SHARD_RE.match(f[0]):
            f += [""] * (5 - len(f))
            rows.append(f)
    try:
        planned = len(json.loads(a.planned or "[]"))
    except ValueError:
        planned = 0
    ran = shard_dirs(a.results)
    ends = [ts(r[3]) for r in rows if ts(r[3])]
    start = ts(a.started)
    wall = "%dm%02ds" % divmod(int((max(ends) - start).total_seconds()), 60) if ends and start else "?"
    red_tests, unrun = [], []
    for r in rows:
        k = int(SHARD_RE.match(r[0]).group(1))
        if k in ran:
            p = os.path.join(ran[k], "train-result.txt")
            if os.path.exists(p):
                red_tests += [m.group(2) for m in map(RED_RE.match, open(p, encoding="utf-8")) if m]
        elif r[1] != "success":
            unrun.append((k, r[1] or "?", refused_line(a.repo, r[4])))
    red = sum(1 for r in rows if r[1] in ("failure", "timed_out"))
    print("### 全量：%d 片（计划 %d）· 红 %d 片 · 开始到最后一片跑完 %s" % (len(rows), planned, red, wall))
    print()
    print("红测试 %d 个%s" % (len(red_tests), "：" + " ".join(sorted(set(red_tests))) if red_tests else ""))
    if planned and not rows:
        print()
        print("**一片都没列出来** — 分片没有开始（GitHub 没排上，或上游的 job 先红了），不是测试红")
        return 1
    if unrun:
        refused = [u for u in unrun if u[2]]
        print()
        print("**%d 片一步没跑（不是测试红）**：%s" % (len(unrun), " ".join(
            "%d(%s)" % (k, "拒收" if why else c) for k, c, why in sorted(unrun))))
        if refused:
            print()
            print("拒收：跑这些分片的 runner 不收这个 workflow — `%s`。夜跑只排 GitHub 自带的 ubuntu-24.04"
                  "（bin/fleet-ci-job-gate.sh 只收列车）" % refused[0][2])
        return 1
    return 0


def baseline(a):
    files = sorted(glob.glob(os.path.join(a.bin, "*selftest*")))
    lines = 0
    for p in files:
        with open(p, "rb") as fh:
            lines += fh.read().count(b"\n")
    per = {}
    for k, d in sorted(shard_dirs(a.results).items()):
        p = os.path.join(d, "train-times.txt")
        if not os.path.exists(p):
            continue
        for line in open(p, encoding="utf-8"):
            m = TIME_RE.match(line)
            if m:
                per[m.group(2)] = float(m.group(3))
    total = round(sum(per.values()), 1)
    breakit = round(sum(v for t, v in per.items() if t.startswith("fleet-break-it")), 1)
    json.dump({"run": a.run, "sha": a.sha, "files": len(files), "lines": lines,
               "tests": len(per), "seconds_total": total, "seconds_breakit": breakit,
               "per_test": dict(sorted(per.items()))}, sys.stdout, indent=1, ensure_ascii=False)
    print()
    return 0


def main():
    ap = argparse.ArgumentParser(prog="fleet-nightly-report.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("summary")
    s.add_argument("--jobs", required=True)
    s.add_argument("--results", required=True)
    s.add_argument("--planned", default="")
    s.add_argument("--started", default="")
    s.add_argument("--repo", default="")
    b = sub.add_parser("baseline")
    b.add_argument("--results", required=True)
    b.add_argument("--bin", default=os.path.dirname(os.path.abspath(__file__)))
    b.add_argument("--run", default="")
    b.add_argument("--sha", default="")
    a = ap.parse_args()
    return summary(a) if a.cmd == "summary" else baseline(a)


if __name__ == "__main__":
    sys.exit(main())
