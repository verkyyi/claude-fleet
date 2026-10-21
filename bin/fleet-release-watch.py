#!/usr/bin/env python3
"""fleet-release-watch.py — the 15 minutes after a release (issue #4915, EPIC #4810 S3).

Stable moves by itself now (the train, #4913), so a bad version must also go back
by itself. After a train moves stable to <sha>, release-watch.yml runs

    fleet-release-watch.py watch --sha <sha> --prev <last good> --hub <url>
                                 [--hub-live <hub commit before the train>] [--repo o/r]
                                 [--mins 15] [--every 30] [--run-id N] [--dry-run]

which reads the hub's GET /v1/fleet/release/health?sha=<sha> every --every seconds
for --mins minutes (the release CI's OIDC, as the ledger) and probes /healthz. The
version is BAD when any of:

  - the canary refused it (the hub's hold says `blocked`, fleet.release_canary);
  - a machine rolled it back (its updater's last result `rolled-back` naming the
    sha — a new doctor FAIL after the switch is exactly what rolls one back);
  - the hub answered 5xx past the threshold since the release: at least
    FLEET_RELEASE_WATCH_MAX_5XX (20) and FLEET_RELEASE_WATCH_5XX_PCT (5) % of its
    requests, on either replica;
  - /healthz failed 3 rounds in a row.

Bad ⇒ ONE whole-version rollback: `fleet-release-rollback.sh <stable> --since <prev>
[--hub-tag prod-<hub-live7>]` (one revert commit of <prev>..<stable> — a NEW commit
and a new release seq, so a machine's 「只向前」 rule holds), a release-train dispatch
for it, and one notice through the hub's alert channel (POST
/v1/fleet/release/notice, verdict rolledback | rollback-failed). A rollback PR for the
same version already opened within the hour ⇒ nothing twice. Clean for the whole
window ⇒ exit 0, one summary line, no notice.

    fleet-release-watch.py judge --health <file> [--healthz-fails N]

judges one health answer (exit 0 ok · 1 bad), printing {"bad": …, "reasons": […]}.

Seams (tests, the BREAK-IT drill): FLEET_RELEASE_WATCH_ROLLBACK (the rollback
command, words), FLEET_RELEASE_WATCH_GH (gh), FLEET_PUBLISH_TOKEN (the bearer when
not in Actions).
Exit: 0 clean (or superseded / already rolled back) · 1 rolled back · 2 usage ·
3 bad but the rollback failed (a person must act — the notice says so).
"""
import calendar
import importlib.util
import json
import os
import re
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def die(msg, code=2):
    sys.stderr.write("fleet-release-watch: %s\n" % msg)
    sys.exit(code)


def envint(name, default):
    try:
        return int(os.environ.get(name, "") or default)
    except ValueError:
        return default


def ledger():
    """bin/fleet-train-ledger.py — its OIDC identity and its notice post (one copy)."""
    spec = importlib.util.spec_from_file_location("fleet_train_ledger", os.path.join(HERE, "fleet-train-ledger.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# -- the verdict ----------------------------------------------------------------
def judge(h, healthz_fails=0):
    """Reasons the version is bad, from one health answer (and /healthz's run of
    failures). [] = clean."""
    reasons = []
    sha = str(h.get("sha") or "")
    hold = h.get("hold") or {}
    if hold.get("sha") == sha and hold.get("state") == "blocked":
        reasons.append("金丝雀 %s 拒了它：%s" % (hold.get("canary") or "?", hold.get("reason") or "体检后回滚"))
    rb = [m for m in (h.get("rolled_back") or []) if isinstance(m, dict)]
    if rb:
        reasons.append("%d 台机器把它回滚了：%s" % (len(rb), "，".join(
            "%s（%s）" % (m.get("machine") or "?", (m.get("reason") or "")[:80]) for m in rb[:3])))
    http = h.get("http") or {}
    total, errs = int(http.get("total") or 0), int(http.get("errors_5xx") or 0)
    mx, pct = envint("FLEET_RELEASE_WATCH_MAX_5XX", 20), envint("FLEET_RELEASE_WATCH_5XX_PCT", 5)
    if errs >= mx and total > 0 and errs * 100 >= pct * total:
        reasons.append("入口 5xx：%d / %d 个请求（≥ %d 且 ≥ %d%%）" % (errs, total, mx, pct))
    if healthz_fails >= 3:
        reasons.append("入口 /healthz 连续 %d 次失败" % healthz_fails)
    return reasons


# -- the hub --------------------------------------------------------------------
def health(hub, sha, since, tok):
    url = "%s/v1/fleet/release/health?sha=%s&since=%d" % (hub.rstrip("/"), sha, int(since))
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + tok} if tok else {})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            d = json.load(r)
            return d if isinstance(d, dict) else None, ""
    except urllib.error.HTTPError as e:
        return None, "health %d" % e.code
    except (urllib.error.URLError, ValueError, OSError) as e:
        return None, "health: %s" % e


def healthz(hub):
    try:
        with urllib.request.urlopen(hub.rstrip("/") + "/healthz", timeout=15) as r:
            return 200 <= r.status < 300
    except (urllib.error.URLError, OSError, ValueError):
        return False


# -- the rollback ---------------------------------------------------------------
def gh():
    return shlex.split(os.environ.get("FLEET_RELEASE_WATCH_GH", "gh"))


def already_rolled_back(repo, shas):
    """A 「回退版本 <sha7>」 PR opened within the hour for one of shas."""
    if not repo:
        return ""
    try:
        out = subprocess.run(gh() + ["pr", "list", "--repo", repo, "--state", "all", "--limit", "20",
                                     "--search", "回退版本 in:title", "--json", "title,url,createdAt"],
                             capture_output=True, text=True, timeout=60).stdout
        prs = json.loads(out or "[]")
    except (OSError, ValueError, subprocess.SubprocessError):
        return ""
    now = time.time()
    for p in prs if isinstance(prs, list) else []:
        t = str(p.get("title") or "")
        at = str(p.get("createdAt") or "")
        try:
            age = now - calendar.timegm(time.strptime(at[:19], "%Y-%m-%dT%H:%M:%S"))
        except ValueError:
            age = 0
        if age <= 3600 and any(("回退版本 " + s[:7]) in t for s in shas if s):
            return str(p.get("url") or t)
    return ""


def rollback(target, prev, repo, hub_live, dry):
    cmd = shlex.split(os.environ.get("FLEET_RELEASE_WATCH_ROLLBACK", "")) or ["bash", os.path.join(HERE, "fleet-release-rollback.sh")]
    cmd += [target, "--since", prev]
    if repo:
        cmd += ["--repo", repo]
    if hub_live and SHA_RE.match(hub_live):
        cmd += ["--hub-tag", "prod-" + hub_live[:7]]
    if dry:
        cmd += ["--dry-run"]
    print("watch: " + " ".join(shlex.quote(c) for c in cmd))
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    except (OSError, subprocess.SubprocessError) as e:
        return 1, str(e)
    sys.stdout.write(p.stdout)
    sys.stderr.write(p.stderr)
    lines = (p.stdout + p.stderr).strip().splitlines()
    return p.returncode, lines[-1] if lines else ""


def dispatch_train(repo):
    if not repo:
        return
    subprocess.run(gh() + ["workflow", "run", "release-train.yml", "--repo", repo, "--ref", "master"],
                   capture_output=True, text=True, timeout=60)


def run_url():
    """This run's page on GitHub, "" outside Actions."""
    srv, repo, rid = (os.environ.get(k, "") for k in ("GITHUB_SERVER_URL", "GITHUB_REPOSITORY", "GITHUB_RUN_ID"))
    return "%s/%s/actions/runs/%s" % (srv, repo, rid) if srv and repo and rid else ""


def notice(hub, run_id, sha, verdict, text, dry, to="", url=""):
    print("watch: notice %s: %s" % (verdict, text))
    if dry or not hub:
        return
    path = os.path.join(os.environ.get("RUNNER_TEMP") or "/tmp", "release-watch-notice-%d.json" % os.getpid())
    with open(path, "w") as f:
        body = {"run_id": str(run_id or "local"), "sha": sha, "verdict": verdict, "text": text}
        if to:
            body["to"] = to  # the hub words it 「已回滚 · <sha> → <to>」 (T893)
        if url:
            body["url"] = url
        json.dump(body, f, ensure_ascii=False)
    try:
        rc = ledger().post([path, "--to", "notice", "--hub", hub])
        if rc:
            sys.stderr.write("fleet-release-watch: the hub did not take the notice (%s)\n" % rc)
    except SystemExit as e:
        sys.stderr.write("fleet-release-watch: notice not sent (%s)\n" % e.code)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


# -- the commands ---------------------------------------------------------------
def opts(argv, flags, bools=()):
    o = {k: "" for k in flags}
    o.update({k: False for k in bools})
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in bools:
            o[a] = True
            i += 1
        elif a in flags and i + 1 < len(argv):
            o[a] = argv[i + 1]
            i += 2
        else:
            die("unknown or incomplete %s" % a)
    return o


def cmd_judge(argv):
    o = opts(argv, ("--health", "--healthz-fails"))
    if not o["--health"]:
        die("judge needs --health <file>")
    try:
        h = json.load(open(o["--health"]))
    except (OSError, ValueError) as e:
        die("unreadable health %s: %s" % (o["--health"], e))
    r = judge(h, int(o["--healthz-fails"] or 0))
    print(json.dumps({"bad": bool(r), "reasons": r}, ensure_ascii=False))
    return 1 if r else 0


def cmd_watch(argv):
    o = opts(argv, ("--sha", "--prev", "--hub", "--hub-live", "--repo", "--mins", "--every", "--run-id"), ("--dry-run",))
    sha, prev, hub = o["--sha"], o["--prev"], o["--hub"] or os.environ.get("FLEET_HUB_URL", "")
    if not SHA_RE.match(sha) or not SHA_RE.match(prev):
        die("watch needs --sha and --prev, 40 hex each")
    if not hub:
        die("no hub — pass --hub <url> or set FLEET_HUB_URL")
    mins = float(o["--mins"] or 15)
    every = float(o["--every"] if o["--every"] != "" else 30)
    dry = o["--dry-run"]
    start = time.time()
    deadline = start + mins * 60
    tok = ""
    try:
        tok = ledger().identity()
    except SystemExit:
        tok = ""
    fails, seen, last = 0, None, ""
    max5 = {}
    while True:
        h, err = health(hub, sha, start, tok)
        fails = 0 if healthz(hub) else fails + 1
        if h is None:
            last = err
            h = {"sha": sha}
        else:
            seen = h
            # one replica answers each read: keep the worst 5xx count seen
            ht = h.get("http") or {}
            rep = str(ht.get("replica") or "")
            max5[rep] = ht
            worst = max(max5.values(), key=lambda x: int(x.get("errors_5xx") or 0))
            h = dict(h, http=worst)
        reasons = judge(h, fails)
        if reasons:
            break
        if time.time() >= deadline:
            print("watch: %s clean for %g minutes%s" % (sha[:7], mins, (" (last read: %s)" % last) if seen is None and last else ""))
            return 0
        time.sleep(max(every, 0.05))
    stable = str((seen or {}).get("stable") or "")
    target = stable if SHA_RE.match(stable) else sha
    why = "；".join(reasons)
    print("watch: BAD %s — %s" % (sha[:7], why))
    done = already_rolled_back(o["--repo"], [target, sha])
    if done:
        print("watch: already rolled back: %s" % done)
        return 0
    rc, tail = rollback(target, prev, o["--repo"], o["--hub-live"], dry)
    if rc == 0:
        if not dry:
            dispatch_train(o["--repo"])
        notice(hub, o["--run-id"], sha, "rolledback",
               "已自动回退 %s → %s：%s%s" % (target[:7], prev[:7], why,
                                         "（入口回到 prod-%s）" % o["--hub-live"][:7] if SHA_RE.match(o["--hub-live"] or "") else ""), dry, to=prev, url=run_url())
        return 1
    notice(hub, o["--run-id"], sha, "rollback-failed",
           "%s 出问题了但自动回退失败，请手动：%s · %s" % (target[:7], why, tail[:120]), dry, url=run_url())
    return 3


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0 if argv else 2
    if argv[0] == "judge":
        return cmd_judge(argv[1:])
    if argv[0] == "watch":
        return cmd_watch(argv[1:])
    die("unknown command %s (judge | watch)" % argv[0])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
