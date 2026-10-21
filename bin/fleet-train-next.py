#!/usr/bin/env python3
"""fleet-train-next.py — after a release train: was its red only flaky, and does
the lane need another train? (issue #4913, EPIC #4810 S1; BREAK-IT train-red-stalls)

A red train used to stop the lane until the next merge: master's head sat
unreleased for hours behind a flake. Now the train's `next` job (and the
10-minute backstop, .github/workflows/release-train-next.yml) asks this script,
which only READS files the workflow fetched — every gh call stays in the YAML.

  judge  --sha S --jobs JOBS.ndjson [--results DIR] [--flaky-issues FILE]
         [--lost "K …"] [--moved true] [--held "N …"] [--superseded true]
      the run's verdict as one JSON object {sha, verdict, tests, why}:
        shipped     stable moved
        held        green, but an open `release-hold` issue kept publish + move
        flaky       red ONLY because of instability: every red Linux shard's
                    runner was lost, or it was cut short with no test red, or
                    each of its red tests has an open `flaky` issue naming it
        red         anything else red (a test with no flaky issue, precheck,
                    the hub, the release …) — a real red, wait for the fix
        superseded  green, but stable was already ahead (nothing to ship)
        cancelled   nothing red and nothing shipped (a person cancelled it)
      JOBS: the run's jobs, one GitHub job object a line (name, conclusion).
      DIR: the train-result-* artifacts (train-result-Linux-K/train-result.txt).
      FILE: open flaky issues, "<number>\\t<title>" a line.
      --lost: the shard numbers whose runner went away (fleet-train-runner.sh lost).

  decide --verdict FILE --head H --stable S --active N --retries N
         [--holds "N …"] [--max 2]
      action=dispatch|wait and reason=… (stdout and $GITHUB_OUTPUT): one more
      train on master's head, or none. Dispatch only when the head is not on
      stable, no train runs or waits, no release-hold is open, this head has had
      fewer than --max re-sends, and the last verdict on it is flaky / held (the
      hold is gone now) / unknown — or the head is newer than the verdict's sha
      (its push train was lost). A real red waits for its fix: the fix's merge
      boards the next train by itself.

  retries --runs RUNS.json --sha S
      how many re-sends this sha already had: release-train runs whose title
      carries 「补发 <sha7> 」 (the `resend` input, below). RUNS: the API's
      {"workflow_runs": [...]} or a list of runs.

  resend --sha S --n N --max M --why W
      the `resend` input of the dispatched train: "<sha7> · N/M · W" — its run
      name becomes 「release train (补发 <sha7> · N/M · W)」, which retries counts.

  notice --verdict FILE --action A --retries N [--max 2] [--run-url U]
         [--merges FILE] [--holds "N …"] [--now ISO]
      the ONE line the hub notifies (POST /v1/fleet/release/notice):
        已上线 <sha7> · 含 PR #… · 合并→生效 N 分钟
        红：<test> · 不稳，已补发（第 n/2 次）
        红：<test> · 真红，等修复
        <sha7> 测完未发布：release-hold #N 挡着
      with --run-id R: the whole notice body as JSON — the line as "text", plus
      what the hub words its push with (T893): "tests", "holds", "url",
      "action" (only red · held · a flaky no re-send saved are pushed at once;
      shipped is the hub's 09:00 digest).

Exit: 0 · 2 usage.
"""
import datetime
import json
import os
import re
import sys

# jobs that only watch, sum up or follow the run: never the reason it is red
WATCHERS = {"红灯即停", "train", "ledger", "next", "node tools", "node image", "Linux 补跑?"}
SHARD = re.compile(r"^Linux(?: rescue)? / shard (\d+)$")
RED = re.compile(r"^(FAIL|TIMEOUT)\s+(\S+)")
RED_JOB = ("failure", "timed_out")


def die(msg, code=2):
    sys.stderr.write("fleet-train-next: %s\n" % msg)
    sys.exit(code)


def opts(args, flags):
    out = {}
    while args:
        k = args[0]
        if not k.startswith("--") or k[2:] not in flags:
            die("unknown argument %s" % k)
        if len(args) < 2:
            die("%s needs a value" % k)
        out[k[2:]] = args[1]
        args = args[2:]
    return out


def emit(pairs):
    gh = os.environ.get("GITHUB_OUTPUT")
    for k, v in pairs:
        print("%s=%s" % (k, v))
        if gh:
            with open(gh, "a") as f:
                f.write("%s=%s\n" % (k, v))


def words(s):
    return [w for w in re.split(r"[\s,]+", s or "") if w]


def read_jobs(path):
    jobs = []
    with open(path, errors="replace") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    jobs.append(json.loads(line))
                except ValueError:
                    continue
    return jobs


def shard_tests(results):
    """{shard K: [red test, …]} off the train-result-Linux-K artifacts."""
    out = {}
    if not results or not os.path.isdir(results):
        return out
    for root, _, names in os.walk(results):
        m = re.search(r"train-result-Linux-(\d+)", root)
        if not m or "train-result.txt" not in names:
            continue
        k = int(m.group(1))
        with open(os.path.join(root, "train-result.txt"), errors="replace") as f:
            for line in f:
                r = RED.match(line)
                if r and r.group(2) not in out.setdefault(k, []):
                    out[k].append(r.group(2))
    return out


def flaky_titles(path):
    out = []
    if path and os.path.isfile(path):
        with open(path, errors="replace") as f:
            for line in f:
                num, _, title = line.rstrip("\n").partition("\t")
                if num.strip().isdigit():
                    out.append((int(num), title))
    return out


def judge(o):
    sha = o.get("sha") or die("judge needs --sha")
    jobs = read_jobs(o.get("jobs") or die("judge needs --jobs"))
    tests_of = shard_tests(o.get("results"))
    flaky = flaky_titles(o.get("flaky-issues"))
    lost = {int(k) for k in words(o.get("lost")) if k.isdigit()}
    # a shard counts by its last attempt: a green rescue clears a red shard
    last = {}
    other = []
    for j in jobs:
        name, concl = (j.get("name") or "").strip(), j.get("conclusion") or ""
        if name in WATCHERS:
            continue
        m = SHARD.match(name)
        if m:
            k = int(m.group(1))
            if name.startswith("Linux rescue") or k not in last:
                last[k] = concl
            continue
        if concl in RED_JOB:
            other.append(name)
    v = {"sha": sha, "verdict": "", "tests": [], "why": ""}
    red_shards = sorted(k for k, c in last.items() if c in RED_JOB)
    if other:
        v.update(verdict="red", why="红在 " + "、".join(other))
        for k in red_shards:
            v["tests"] += [t for t in tests_of.get(k, []) if t not in v["tests"]]
        return v
    if red_shards:
        why, real = [], []
        for k in red_shards:
            if k in lost:
                why.append("片 %d 机器丢了" % k)
                continue
            tests = tests_of.get(k, [])
            if not tests:
                why.append("片 %d 被截断、没有测试红" % k)
                continue
            for t in tests:
                v["tests"].append(t)
                hit = [n for n, title in flaky if t in title]
                if hit:
                    why.append("%s 有时好时坏单 #%d" % (t, hit[0]))
                else:
                    real.append(t)
        if real:
            v.update(verdict="red", why="没有时好时坏单：" + "、".join(real))
        else:
            v.update(verdict="flaky", why="；".join(why))
        return v
    if o.get("moved") == "true":
        v.update(verdict="shipped", why="stable 已挪")
    elif words(o.get("held")):
        v.update(verdict="held", why="release-hold " + " ".join("#" + n for n in words(o.get("held"))))
    elif o.get("superseded") == "true":
        v.update(verdict="superseded", why="stable 已在前面")
    else:
        v.update(verdict="cancelled", why="没有红、也没发（被取消）")
    return v


def load_verdict(path):
    if not path or path == "-" or not os.path.isfile(path):
        return {}
    try:
        with open(path) as f:
            v = json.load(f)
        return v if isinstance(v, dict) else {}
    except ValueError:
        return {}


def decide(o):
    v = load_verdict(o.get("verdict"))
    head, stable = o.get("head", ""), o.get("stable", "")
    active, retries, mx = int(o.get("active") or 0), int(o.get("retries") or 0), int(o.get("max") or 2)
    holds = words(o.get("holds"))
    verdict, vsha = v.get("verdict", ""), v.get("sha", "")

    def wait(why):
        return [("action", "wait"), ("reason", why)]

    if not head:
        return wait("master 的头读不到")
    if head == stable:
        return wait("stable 已在 master 的头")
    if active > 0:
        return wait("有车在跑或排队（%d）" % active)
    if holds:
        return wait("release-hold " + " ".join("#" + n for n in holds) + " 挡着")
    if retries >= mx:
        return wait("%s 已补发 %d 次，不再补发" % (head[:7], retries))
    if vsha and vsha != head:
        return [("action", "dispatch"), ("reason", "新头")]
    if verdict == "flaky":
        return [("action", "dispatch"), ("reason", "不稳")]
    if verdict == "held":
        return [("action", "dispatch"), ("reason", "挡发单已关")]
    if not verdict:
        return [("action", "dispatch"), ("reason", "上一趟没留下结论")]
    if verdict == "red":
        return wait("真红，等修复")
    return wait("上一趟 %s" % verdict)


def run_titles(path):
    with open(path) as f:
        d = json.load(f)
    runs = d.get("workflow_runs", []) if isinstance(d, dict) else d
    return [(r.get("display_title") or r.get("name") or "") if isinstance(r, dict) else str(r) for r in runs]


def retries(o):
    sha = o.get("sha") or die("retries needs --sha")
    tag = "补发 %s " % sha[:7]
    print(sum(1 for t in run_titles(o.get("runs") or die("retries needs --runs")) if tag in t))


def merged_prs(merges):
    prs = []
    for m in merges:
        for n in re.findall(r"\(#(\d+)\)", m.get("subject", "")):
            if "#" + n not in prs:
                prs.append("#" + n)
    return prs


def iso(s):
    try:
        return datetime.datetime.strptime(s.replace("Z", "+0000")[:24], "%Y-%m-%dT%H:%M:%S%z")
    except ValueError:
        return None


def notice_body(o):
    v = load_verdict(o.get("verdict"))
    body = {"run_id": o.get("run-id", ""), "sha": v.get("sha", ""), "verdict": v.get("verdict", ""),
            "text": notice(o), "action": o.get("action", "wait")}
    tests = "、".join(v.get("tests") or [])
    holds = " ".join("#" + h for h in words(o.get("holds"))) or (v.get("why", "") if body["verdict"] == "held" else "")
    for k, val in (("tests", tests), ("holds", holds), ("url", o.get("run-url", ""))):
        if val:
            body[k] = val
    return body


def notice(o):
    v = load_verdict(o.get("verdict"))
    sha7 = v.get("sha", "")[:7] or "?"
    verdict, action = v.get("verdict", ""), o.get("action", "wait")
    n, mx = int(o.get("retries") or 0), int(o.get("max") or 2)
    tests = "、".join(v.get("tests") or []) or v.get("why", "") or sha7
    url = o.get("run-url", "")
    tail = (" · " + url) if url else ""
    if verdict == "shipped":
        merges = []
        if o.get("merges") and os.path.isfile(o["merges"]):
            try:
                merges = json.load(open(o["merges"]))
            except ValueError:
                merges = []
        prs = merged_prs(merges)
        line = "已上线 %s" % sha7
        if prs:
            line += " · 含 PR " + " ".join(prs[:12]) + (" 等 %d 个" % len(prs) if len(prs) > 12 else "")
        now = iso(o.get("now", "")) or datetime.datetime.now(datetime.timezone.utc)
        times = [t for t in (iso(m.get("committed", "")) for m in merges) if t]
        if times:
            line += " · 合并→生效 %d 分钟" % max(0, round((now - min(times)).total_seconds() / 60))
        return line + tail
    if verdict == "flaky":
        if action == "dispatch":
            return "红：%s · 不稳，已补发（第 %d/%d 次）%s" % (tests, n + 1, mx, tail)
        return "红：%s · 不稳，没有补发（%s）%s" % (tests, o.get("reason", "") or "已到上限", tail)
    if verdict == "red":
        return "红：%s · 真红，等修复%s" % (tests, tail)
    if verdict == "held":
        holds = " ".join("#" + h for h in words(o.get("holds"))) or v.get("why", "")
        return "%s 测完未发布：%s 挡着%s" % (sha7, holds, tail)
    if verdict == "superseded":
        return "%s 没发：stable 已在前面%s" % (sha7, tail)
    return "%s 没发：%s%s" % (sha7, v.get("why", "") or "被取消", tail)


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        sys.stdout.write(__doc__)
        return 0 if len(argv) >= 2 else 2
    cmd, args = argv[1], argv[2:]
    if cmd == "judge":
        o = opts(args, {"sha", "jobs", "results", "flaky-issues", "lost", "moved", "held", "superseded"})
        print(json.dumps(judge(o), ensure_ascii=False))
    elif cmd == "decide":
        emit(decide(opts(args, {"verdict", "head", "stable", "active", "retries", "holds", "max"})))
    elif cmd == "retries":
        retries(opts(args, {"runs", "sha"}))
    elif cmd == "resend":
        o = opts(args, {"sha", "n", "max", "why"})
        print("%s · %s/%s · %s" % (o.get("sha", "")[:7], o.get("n", "1"), o.get("max", "2"), o.get("why", "")))
    elif cmd == "notice":
        o = opts(args, {"verdict", "action", "reason", "retries", "max", "run-url", "merges", "holds", "now", "run-id"})
        print(json.dumps(notice_body(o), ensure_ascii=False) if o.get("run-id") else notice(o))
    else:
        die("unknown command %s" % cmd)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
