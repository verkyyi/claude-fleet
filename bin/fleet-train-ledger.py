#!/usr/bin/env python3
# fleet-train-ledger.py — a release-train run, as the hub's ledger keeps it
# (issue #3870, EPIC #3863 C7; 共同约定 7: the ledger is the one source of stage
# times — the /trains page, `fleet release stats` and the run summary all read it).
#
#   build --jobs <jobs.ndjson> [--results <dir>] [--run-id N] [--sha S] [--prev S]
#         [--conclusion C] [--merges-env MERGES] [--exclude <job name>]...
#       one JSON object on stdout: run_id · sha · prev_sha · conclusion ·
#       started_at · ended_at · merges · stages (name, started_at, ended_at,
#       result, queue_secs) · first_fail. A superset of the
#       publish's `train` part (#3140), so the release step sends the same file.
#       Jobs of one stage ("Linux / shard 3" → Linux) fold into one span; a
#       skipped job is no stage. --results: the train-result-* artifacts — the
#       first FAIL / TIMEOUT test by shard (a FLAKY or QUARANTINE line is not red).
#   build --mac --train-run N --jobs <jobs.ndjson> [--run-id N] [--conclusion C]
#       mac-follow's word on the train run that started it: one `mac follow`
#       stage, the run's span.
#   post <file> [--hub URL] [--summary <file>] [--to train|notice]
#       POST it to <hub>/v1/fleet/release/train (--to notice: …/notice, the
#       train's one line to the person — fleet-train-next.py, #4913) with this run's OIDC token (as
#       fleet-release-publish.sh: audience ccquota-fleet-release; else
#       FLEET_PUBLISH_TOKEN), print the answer, and with --summary append the
#       hub's 「卡在…」 line to it (GITHUB_STEP_SUMMARY). Exit 0 recorded · 1 refused
#       · 3 unreachable / no identity. Bookkeeping: the caller never reds on it.
#
# The token is read from the Actions runtime into memory only — never an argv,
# a file or a log line.
import datetime
import json
import os
import re
import sys
import urllib.error
import urllib.request

# never what made a train slow: a watcher spanning the run, this ledger, the
# node image built beside the release (the hub's stageOffPath, kept in step)
OFF_PATH = {"红灯即停", "ledger", "node tools", "node image", "mac follow"}
CONCLUSIONS = {"success", "failure", "cancelled", "superseded"}
# run-selftests.sh's own verdict lines — `FAIL  <test>  12.3s (exit 1)`,
# `TIMEOUT <test>  480s (limit …)` — never a FAIL a test prints of its own
RUNNER_RED = re.compile(r"^(FAIL|TIMEOUT) +(\S+) +[0-9.]+s \((exit|limit) ")


def die(msg, code=2):
    sys.stderr.write("fleet-train-ledger: %s\n" % msg)
    sys.exit(code)


def ts(s):
    if not s:
        return None
    return datetime.datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S")


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None, microsecond=0)


def read_jobs(path):
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def first_fail(results):
    """The first FAIL / TIMEOUT test, shards in number order."""
    if not results or not os.path.isdir(results):
        return ""
    files = []
    for root, _, names in os.walk(results):
        for n in names:
            if n == "train-result.txt" or (n.startswith("train-result") and n.endswith(".txt")):
                files.append(os.path.join(root, n))
    key = lambda p: [int(x) if x.isdigit() else x for x in re.split(r"(\d+)", p)]
    for p in sorted(files, key=key):
        with open(p, errors="replace") as f:
            for line in f:
                m = RUNNER_RED.match(line)
                if m:
                    return m.group(2)
    return ""


def fold(jobs, exclude):
    """Stages off a run's jobs: name → [start, end, result, queue]."""
    t_now = now()
    stages = {}
    created = []
    for j in jobs:
        name = j.get("name") or ""
        if name in exclude or j.get("conclusion") == "skipped":
            continue
        c = ts(j.get("created_at"))
        if c:
            created.append(c)
        a = ts(j.get("started_at"))
        if a is None:
            continue
        b = ts(j.get("completed_at")) or t_now   # still running: now
        if b < a:
            b = a
        stage = name.split(" / ")[0]
        concl = j.get("conclusion") or ("success" if j.get("status") == "completed" else "")
        q = max(0.0, (a - c).total_seconds()) if c else 0.0
        st = stages.get(stage)
        if st is None:
            st = stages[stage] = [a, b, "success", 0.0]
        st[0], st[1] = min(st[0], a), max(st[1], b)
        if concl in ("failure", "timed_out", "startup_failure"):
            st[2] = "failure"
        elif concl == "cancelled" and st[2] != "failure":
            st[2] = "cancelled"
        st[3] = max(st[3], q)
    return stages, created


def build(args):
    opts = {"exclude": []}
    mac = False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--mac":
            mac = True
            i += 1
            continue
        if i + 1 >= len(args):
            die("%s needs a value" % a)
        k = a.lstrip("-").replace("-", "_")
        if k == "exclude":
            opts["exclude"].append(args[i + 1])
        else:
            opts[k] = args[i + 1]
        i += 2
    if "jobs" not in opts:
        die("build needs --jobs")
    jobs = read_jobs(opts["jobs"])
    stages, created = fold(jobs, set(opts["exclude"]))
    run_id = opts.get("run_id") or os.environ.get("GITHUB_RUN_ID", "")
    concl = opts.get("conclusion", "success")
    if concl not in CONCLUSIONS:
        die("--conclusion: want one of %s, got %r" % ("|".join(sorted(CONCLUSIONS)), concl))
    if not stages:
        die("no stage: every job skipped or not started", 1)
    start = min(created) if created else min(s[0] for s in stages.values())
    if mac:
        if not opts.get("train_run"):
            die("--mac needs --train-run")
        end = max(s[1] for s in stages.values())
        out = {"run_id": run_id, "train_run_id": opts["train_run"], "conclusion": concl,
               "started_at": iso(start), "ended_at": iso(end),
               "stages": [{"name": "mac follow", "started_at": iso(start), "ended_at": iso(end), "result": concl}]}
        print(json.dumps(out))
        return 0
    on_path = [s for n, s in stages.items() if n not in OFF_PATH] or list(stages.values())
    end = max(s[1] for s in on_path)
    merges = []
    raw = os.environ.get(opts.get("merges_env", "MERGES"), "") or "[]"
    for m in json.loads(raw):
        merges.append({"sha": m["sha"], "merged_at": m.get("committed") or m.get("merged_at"),
                       "subject": (m.get("subject") or "")[:200]})
    out = {
        "run_id": run_id,
        "sha": opts.get("sha", ""),
        "prev_sha": opts.get("prev", ""),
        "conclusion": concl,
        "started_at": iso(start),
        "ended_at": iso(end),
        "merges": merges,
        "stages": [{"name": n, "started_at": iso(s[0]), "ended_at": iso(s[1]), "result": s[2],
                    "queue_secs": round(s[3], 1)}
                   for n, s in sorted(stages.items(), key=lambda kv: kv[1][0])],
        "first_fail": first_fail(opts.get("results")),
    }
    print(json.dumps(out, ensure_ascii=False))
    return 0


def fmt(s):
    n = int(round(float(s or 0)))
    return "%d 分 %02d 秒" % (n // 60, n % 60) if n >= 60 else "%d 秒" % n


def summary_line(ans):
    bn = ans.get("bottleneck")
    total = ans.get("total_secs")
    if bn and bn.get("stage"):
        return "### 🚂 卡在「%s」：%s——%s（共 %s）" % (bn["stage"], fmt(bn.get("secs")), bn.get("why", ""), fmt(total))
    if bn:
        return "### 🚂 没发出：%s" % bn.get("why", "")
    return "### 🚂 本趟 %s，没超 5 分钟" % fmt(total)


def identity():
    url, rtok = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_URL"), os.environ.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN")
    if url and rtok:
        aud = os.environ.get("FLEET_PUBLISH_AUDIENCE", "ccquota-fleet-release")
        req = urllib.request.Request(url + "&audience=" + aud, headers={"Authorization": "bearer " + rtok})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r).get("value") or ""
        except (urllib.error.URLError, ValueError) as e:
            die("no OIDC token from the Actions runtime (%s) — permissions: id-token: write?" % e, 3)
    return os.environ.get("FLEET_PUBLISH_TOKEN", "")


def post(args):
    if not args:
        die("post needs a file")
    path, hub, summ, to = args[0], os.environ.get("FLEET_HUB_URL", ""), "", "train"
    rest = args[1:]
    while rest:
        if rest[0] == "--hub" and len(rest) > 1:
            hub, rest = rest[1], rest[2:]
        elif rest[0] == "--to" and len(rest) > 1 and rest[1] in ("train", "notice"):
            # notice: the train's one line to the person (fleet-train-next.py, #4913)
            to, rest = rest[1], rest[2:]
        elif rest[0] == "--summary" and len(rest) > 1:
            summ, rest = rest[1], rest[2:]
        else:
            die("post: unknown %s" % rest[0])
    if not hub:
        die("no hub — pass --hub <url> or set FLEET_HUB_URL", 3)
    body = open(path, "rb").read()
    tok = identity()
    if not tok:
        die("no identity: not a GitHub Actions run with id-token: write, and no FLEET_PUBLISH_TOKEN", 3)
    req = urllib.request.Request(hub.rstrip("/") + "/v1/fleet/release/" + to, data=body, method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": "Bearer " + tok})
    tok = ""
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            text = r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        sys.stderr.write("fleet-train-ledger: the hub answered %d: %s\n" % (e.code, e.read().decode("utf-8", "replace")[:500]))
        return 3 if e.code >= 500 else 1
    except urllib.error.URLError as e:
        sys.stderr.write("fleet-train-ledger: %s cannot be reached: %s\n" % (hub, e))
        return 3
    print(text)
    try:
        ans = json.loads(text)
    except ValueError:
        return 0
    if summ and ans.get("status") == "recorded":
        with open(summ, "a") as f:
            f.write(summary_line(ans) + "\n")
    return 0


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        sys.stdout.write(__doc__ if __doc__ else open(__file__).read().split("\nimport ")[0])
        return 0 if len(argv) >= 2 else 2
    cmd, args = argv[1], argv[2:]
    if cmd == "build":
        return build(args)
    if cmd == "post":
        return post(args)
    if cmd == "line":   # the summary line off a saved answer (selftest seam)
        print(summary_line(json.load(open(args[0]))))
        return 0
    die("unknown command %s (build | post)" % cmd)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
