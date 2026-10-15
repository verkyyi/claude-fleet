#!/usr/bin/env python3
"""fleet-cn-probe-recover.py — the China probe's bounded RECOVERY verification
(issue #4304): after a fix is really deployed, walk the path again every few
minutes until it has passed N times in a row on one deployed version vector, or
the round's budget is spent — never an endless loop, never a second daemon. By default the runs go
back to back (the next starts on the first tick after one ends), never on the hour.

The patrol (bin/fleet-cn-probe-watch.sh, on the diskguard tick) asks `due` every
tick; a due round makes that tick a run of its own (the throttle does not apply),
`begin` books it, and `finish` judges it off the probe's ONE result
(runs/<run_id>/result.json, issue #4303 — no second parser of the probe's text).
When the round ends the patrol is back on its usual throttle.

    fleet-cn-probe-recover.py <state dir> start [--expect KEY=VALUE]… [--why TEXT]
            [--every S] [--need N] [--max-runs N] [--max-secs S]
        open a round (idempotent: an active round with the same expectation is
        left as it is; a different expectation restarts it, the old one recorded
        `superseded`); prints `round <id> …`
    … due          exit 0 + `due <round> <run n>` when a run should start now;
                   exit 1 + why not (no round / waiting until … / running …)
    … begin <run_id> <pid>   book the run (exit 3: another run of the round is live)
    … finish <run_id> <result.json | ->   judge it; prints `counted …` / `not
                   counted <reason> …`, then `done …` / `exhausted …` when it ends
    … status [--json]   one line (or the state)
    … stop [--why TEXT] end an active round by hand (`stopped`)

A run COUNTS only when its result.json says pass · class none, every required
stage passed (FLEET_CN_RECOVER_STAGES, default every route's connect / view /
codex: entry relay view:entry view:relay codex:entry codex:relay), its diagnosis
read the whole version vector (VECTOR below — none `unknown`), the vector holds
every --expect value, its times are sane (ended ≥ started, inside the round, the
clock not run backwards) and the run was begun in this round. A pass on another
vector than the streak's (a new release, a rebuilt pod) restarts the streak at 1;
anything else that does not count — a failure, env, probe, partial, unknown,
timeout, a run that died — resets it to 0. A run_id is judged once: a crashed
patrol finishing it again counts nothing twice.

Budget: --max-runs (FLEET_CN_RECOVER_MAX_RUNS, 6) runs or --max-secs
(FLEET_CN_RECOVER_MAX_SECS, 5400) from the start, whichever first ⇒ `exhausted`
with the reason. A booked run whose pid is gone or that overran
FLEET_CN_RECOVER_RUN_SECS (1800) is recorded `abandoned` (not counted, the streak
reset, one of the budget's runs) and the round goes on. Runs never overlap; a
next one starts FLEET_CN_RECOVER_EVERY (0: at once) s after the last one's start. `done` / `exhausted` write the
round's evidence to <state dir>/recover/<round>.json (0600): every attempt, and for
done the N counted runs with their run dirs — for the orchestrator to check before
it lifts a stable window. This script moves no ref, merges nothing, files nothing.

FLEET_CN_RECOVER_NOW (epoch seconds) is the fake clock's seam.
"""
import calendar
import fcntl
import json
import os
import sys
import time

VECTOR = ["version.hub", "version.hub_client", "version.client", "version.node_runtime",
          "image.digest", "target.pod_uid"]
ROUTES_DEFAULT = "entry relay view:entry view:relay codex:entry codex:relay"
ACTIVE = "active"


def env_num(name, dflt):
    try:
        v = int(os.environ.get(name, ""))
        return v if v >= 0 else dflt
    except ValueError:
        return dflt


def now():
    v = os.environ.get("FLEET_CN_RECOVER_NOW", "")
    try:
        return int(float(v)) if v else int(time.time())
    except ValueError:
        return int(time.time())


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(t)))


def parse_iso(s):
    try:
        return calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))
    except (TypeError, ValueError):
        return None


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except PermissionError:
        return True
    except (OSError, ValueError):
        return False


def write_private(path, data):
    tmp = "%s.%d.tmp" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=1, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


class Book:
    """recover.json under an flock: every command is one read-modify-write."""

    def __init__(self, sd):
        self.sd = sd
        os.makedirs(sd, exist_ok=True)
        self.path = os.path.join(sd, "recover.json")
        self.lf = open(os.path.join(sd, "recover.lock"), "a")
        fcntl.flock(self.lf, fcntl.LOCK_EX)
        try:
            with open(self.path) as f:
                self.st = json.load(f)
        except (OSError, ValueError):
            self.st = {}
        self.t = now()
        # the clock's high-water mark: a reading earlier than it is not a time we trust
        self.skew = self.t < int(self.st.get("clock_hwm") or 0) - 60
        self.st["clock_hwm"] = max(self.t, int(self.st.get("clock_hwm") or 0))

    def save(self):
        write_private(self.path, self.st)

    def rnd(self):
        r = self.st.get("round")
        return r if isinstance(r, dict) else None


def evidence(book, r):
    d = os.path.join(book.sd, "recover")
    os.makedirs(d, exist_ok=True)
    os.chmod(d, 0o700)
    p = os.path.join(d, "%s.json" % r["id"])
    ev = {k: r.get(k) for k in ("id", "state", "why", "expect", "need", "every", "max_runs", "max_secs",
                                 "started", "ended", "end_reason", "attempts", "streak", "vector")}
    ev["elapsed_secs"] = (r.get("ended_ts") or book.t) - r["started_ts"]
    ev["counted_runs"] = [a for a in r["attempts"] if a["run_id"] in r["streak"]]
    ev["note"] = ("%d independent complete runs passed on one deployed vector" % len(r["streak"])
                  if r["state"] == "done" else "the round ended without %d passes in a row" % r["need"])
    write_private(p, ev)
    r["evidence"] = p
    return p


def end(book, r, state, reason):
    r["state"], r["end_reason"] = state, reason
    r["ended_ts"], r["ended"] = book.t, iso(book.t)
    r["next_at"] = None
    p = evidence(book, r)
    book.st.setdefault("past", []).append({"id": r["id"], "state": state, "end_reason": reason,
                                           "ended": r["ended"], "evidence": p})
    book.st["past"] = book.st["past"][-20:]
    return "%s %s — %s · evidence %s" % (state, r["id"], reason, p)


def check_budget(book, r):
    if r["state"] != ACTIVE or r.get("running"):
        return None
    if len(r["attempts"]) >= r["max_runs"]:
        return end(book, r, "exhausted", "budget: %d runs, %d in a row of %d" % (r["max_runs"], len(r["streak"]), r["need"]))
    if book.t >= r["deadline_ts"]:
        return end(book, r, "exhausted", "budget: %d min, %d in a row of %d" % (r["max_secs"] // 60, len(r["streak"]), r["need"]))
    return None


def abandon_stale(book, r, out):
    """A booked run whose patrol died (pid gone) or overran: recorded, never counted."""
    run = r.get("running")
    if not run:
        return
    why = None
    if not pid_alive(run.get("pid")):
        why = "abandoned: run pid %s is gone without a finish" % run.get("pid")
    elif book.t - int(run.get("began_ts") or book.t) > env_num("FLEET_CN_RECOVER_RUN_SECS", 1800):
        why = "abandoned: run overran %ds" % env_num("FLEET_CN_RECOVER_RUN_SECS", 1800)
    if why:
        r["attempts"].append({"run_id": run["run_id"], "counted": False, "reason": "abandoned", "why": why,
                              "began": run.get("began"), "judged": iso(book.t)})
        r["streak"], r["vector"] = [], None
        r["running"] = None
        r["next_at_ts"] = book.t
        r["next_at"] = iso(book.t)
        out.append("not counted abandoned %s — %s" % (run["run_id"], why))


def parse_expect(items):
    exp = {}
    for it in items:
        if "=" not in it:
            raise SystemExit("fleet-cn-probe-recover: --expect is KEY=VALUE (%r)" % it)
        k, v = it.split("=", 1)
        k = k.strip()
        if "." not in k:
            k = {"stable": "version.hub_client", "hub": "version.hub", "client": "version.client",
                 "runtime": "version.node_runtime", "image": "image.digest", "pod": "target.pod_uid"}.get(k, k)
        if not v.strip():
            raise SystemExit("fleet-cn-probe-recover: --expect %s has no value" % k)
        exp[k] = v.strip()
    return exp


def cmd_start(book, args):
    exp_items, why = [], ""
    every = env_num("FLEET_CN_RECOVER_EVERY", 0)
    need = env_num("FLEET_CN_RECOVER_NEED", 3)
    max_runs = env_num("FLEET_CN_RECOVER_MAX_RUNS", 6)
    max_secs = env_num("FLEET_CN_RECOVER_MAX_SECS", 5400)
    i = 0
    while i < len(args):
        a = args[i]
        v = args[i + 1] if i + 1 < len(args) else None
        if a in ("--expect", "--why", "--every", "--need", "--max-runs", "--max-secs") and v is None:
            raise SystemExit("fleet-cn-probe-recover: %s needs a value" % a)
        if a == "--expect":
            exp_items.append(v)
        elif a == "--why":
            why = v
        elif a in ("--every", "--need", "--max-runs", "--max-secs"):
            try:
                n = int(v)
            except ValueError:
                raise SystemExit("fleet-cn-probe-recover: %s is a number" % a)
            if a == "--every":
                every = n
            elif a == "--need":
                need = n
            elif a == "--max-runs":
                max_runs = n
            else:
                max_secs = n
        else:
            raise SystemExit("fleet-cn-probe-recover: unknown argument %s" % a)
        i += 2
    if need < 1 or max_runs < need:
        raise SystemExit("fleet-cn-probe-recover: --need ≥ 1 and --max-runs ≥ --need")
    exp = parse_expect(exp_items)
    r = book.rnd()
    out = []
    if r and r["state"] == ACTIVE:
        if r.get("expect") == exp:
            print("round %s already active — run %d of %d, %d in a row (nothing new started)"
                  % (r["id"], len(r["attempts"]) + 1, r["max_runs"], len(r["streak"])))
            return 0
        if r.get("running"):
            print("round %s has a run in flight (%s) — start again after it finishes" % (r["id"], r["running"]["run_id"]))
            return 3
        out.append(end(book, r, "superseded", "a new expectation: %s" % json.dumps(exp, sort_keys=True)))
    rid = "R%s-%s" % (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(book.t)), os.urandom(2).hex())
    book.st["round"] = {
        "id": rid, "state": ACTIVE, "why": why, "expect": exp, "need": need, "every": every,
        "max_runs": max_runs, "max_secs": max_secs, "started_ts": book.t, "started": iso(book.t),
        "deadline_ts": book.t + max_secs, "deadline": iso(book.t + max_secs),
        "next_at_ts": book.t, "next_at": iso(book.t), "running": None, "attempts": [], "streak": [],
        "vector": None, "last_completed": None,
    }
    book.save()
    for line in out:
        print(line)
    print("round %s started — %d in a row needed, every %ds, at most %d runs / %d min%s"
          % (rid, need, every, max_runs, max_secs // 60, (" · expect " + json.dumps(exp, sort_keys=True)) if exp else ""))
    return 0


def cmd_due(book, _args):
    r = book.rnd()
    if not r or r["state"] != ACTIVE:
        print("no active round")
        return 1
    out = []
    abandon_stale(book, r, out)
    ended = check_budget(book, r)
    book.save()
    for line in out:
        print(line)
    if ended:
        print(ended)
        return 1
    if r.get("running"):
        print("running %s (pid %s)" % (r["running"]["run_id"], r["running"]["pid"]))
        return 1
    if book.t < r["next_at_ts"]:
        print("waiting until %s" % r["next_at"])
        return 1
    print("due %s %d" % (r["id"], len(r["attempts"]) + 1))
    return 0


def cmd_begin(book, args):
    if len(args) != 2:
        raise SystemExit("fleet-cn-probe-recover: begin <run_id> <pid>")
    run_id, pid = args
    r = book.rnd()
    if not r or r["state"] != ACTIVE:
        print("no active round")
        return 1
    out = []
    abandon_stale(book, r, out)
    if r.get("running"):
        book.save()
        print("running %s (pid %s) — not begun" % (r["running"]["run_id"], r["running"]["pid"]))
        return 3
    if any(a["run_id"] == run_id for a in r["attempts"]):
        book.save()
        print("%s was already judged in %s" % (run_id, r["id"]))
        return 3
    r["running"] = {"run_id": run_id, "pid": int(pid), "began_ts": book.t, "began": iso(book.t)}
    book.save()
    for line in out:
        print(line)
    print("begun %s run %d of %d" % (run_id, len(r["attempts"]) + 1, r["max_runs"]))
    return 0


def judge(book, r, run, res):
    """-> (counted, reason, vector, why)."""
    if book.skew:
        return False, "clock_skew", None, "the clock read %s, before %s already seen" % (iso(book.t), iso(book.st["clock_hwm"]))
    if not isinstance(res, dict):
        return False, "no_result", None, "the run left no readable result.json"
    if res.get("run_id") not in (None, run["run_id"]):
        return False, "wrong_result", None, "result.json is run %s's" % res.get("run_id")
    vec = {}
    rd = ((res.get("diag") or {}).get("readings") or {})
    for k in VECTOR:
        v = str(rd.get(k) or "unknown")
        vec[k] = v
    t0, t1 = parse_iso(res.get("started")), parse_iso(res.get("ended"))
    if t0 is None or t1 is None or t1 < t0 or t0 < r["started_ts"] - 60 or t0 < run["began_ts"] - 60 or t1 > book.t + 60:
        return False, "clock_skew", vec, "the run's times %s..%s are not inside its booking (%s..%s)" % (
            res.get("started"), res.get("ended"), run.get("began"), iso(book.t))
    if res.get("verdict") != "pass" or res.get("class") != "none":
        cls = res.get("class") or "probe"
        return False, "%s:%s" % (cls, res.get("reason_code") or "unknown"), vec, "stuck at %s — %s" % (
            res.get("stuck"), (res.get("detail") or "")[:200])
    passed = set(s.get("layer") for s in (res.get("stages") or []) if s.get("result") == "pass")
    missing = [s for s in (os.environ.get("FLEET_CN_RECOVER_STAGES") or ROUTES_DEFAULT).split() if s not in passed]
    if missing:
        return False, "partial", vec, "stages not walked: %s" % " ".join(missing)
    unknown = [k for k, v in vec.items() if v in ("", "unknown")]
    if unknown:
        return False, "env:version_unknown", vec, "the diagnosis did not read %s" % " ".join(unknown)
    for k, want in sorted((r.get("expect") or {}).items()):
        got = str(rd.get(k) or "unknown")
        if want not in got:
            return False, "version_mismatch", vec, "%s reads %r, expected %r" % (k, got, want)
    return True, "ok", vec, ""


def cmd_finish(book, args):
    if len(args) != 2:
        raise SystemExit("fleet-cn-probe-recover: finish <run_id> <result.json|->")
    run_id, rpath = args
    r = book.rnd()
    if not r:
        print("no round")
        return 1
    if any(a["run_id"] == run_id for a in r["attempts"]):
        print("%s was already judged — nothing counted twice" % run_id)
        return 0
    run = r.get("running")
    if r["state"] != ACTIVE or not run or run.get("run_id") != run_id:
        print("%s was not begun in round %s — not counted" % (run_id, r["id"]))
        return 1
    res = None
    if rpath != "-":
        try:
            with open(rpath) as f:
                res = json.load(f)
        except (OSError, ValueError):
            res = None
    counted, reason, vec, why = judge(book, r, run, res)
    att = {"run_id": run_id, "counted": counted, "reason": reason, "why": why, "vector": vec,
           "began": run.get("began"), "judged": iso(book.t), "result": None if rpath == "-" else rpath,
           "started": (res or {}).get("started") if isinstance(res, dict) else None,
           "ended": (res or {}).get("ended") if isinstance(res, dict) else None,
           "oks": (res or {}).get("oks") if isinstance(res, dict) else None}
    if counted:
        if r["streak"] and r.get("vector") != vec:
            att["why"] = "a pass on another vector — the streak starts again"
            r["streak"] = []
        r["streak"].append(run_id)
        r["vector"] = vec
    else:
        r["streak"], r["vector"] = [], None
    r["attempts"].append(att)
    r["running"] = None
    r["last_completed"] = {"run_id": run_id, "counted": counted, "reason": reason, "judged": att["judged"]}
    nxt = max(run["began_ts"] + r["every"], book.t)
    r["next_at_ts"], r["next_at"] = nxt, iso(nxt)
    lines = ["%s %s — %d in a row of %d (run %d of %d)%s" % (
        "counted" if counted else "not counted " + reason, run_id, len(r["streak"]), r["need"],
        len(r["attempts"]), r["max_runs"], (" · " + att["why"]) if att["why"] else "")]
    if len(r["streak"]) >= r["need"]:
        lines.append(end(book, r, "done", "%d complete passes in a row on one vector" % len(r["streak"])))
    else:
        e = check_budget(book, r)
        if e:
            lines.append(e)
    book.save()
    print("\n".join(lines))
    return 0


def cmd_status(book, args):
    r = book.rnd()
    if "--json" in args:
        print(json.dumps(book.st, ensure_ascii=False, indent=1, sort_keys=True))
        return 0
    if not r:
        print("no round")
        return 0
    if r["state"] == ACTIVE:
        print("round %s active — %d in a row of %d · run %d of %d · %s · deadline %s%s"
              % (r["id"], len(r["streak"]), r["need"], len(r["attempts"]), r["max_runs"],
                 ("running " + r["running"]["run_id"]) if r.get("running") else "next " + r["next_at"],
                 r["deadline"], (" · last " + r["last_completed"]["reason"]) if r.get("last_completed") else ""))
    else:
        print("round %s %s — %s · evidence %s" % (r["id"], r["state"], r.get("end_reason"), r.get("evidence")))
    return 0


def cmd_stop(book, args):
    r = book.rnd()
    why = args[1] if len(args) == 2 and args[0] == "--why" else "stopped by hand"
    if not r or r["state"] != ACTIVE:
        print("no active round")
        return 1
    if r.get("running"):
        r["attempts"].append({"run_id": r["running"]["run_id"], "counted": False, "reason": "stopped",
                              "why": why, "began": r["running"].get("began"), "judged": iso(book.t)})
        r["running"] = None
    line = end(book, r, "stopped", why)
    book.save()
    print(line)
    return 0


def main(argv):
    if len(argv) < 3 or argv[1] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if len(argv) > 1 and argv[1] in ("-h", "--help") else 2
    sd, cmd, args = argv[1], argv[2], argv[3:]
    fn = {"start": cmd_start, "due": cmd_due, "begin": cmd_begin, "finish": cmd_finish,
          "status": cmd_status, "stop": cmd_stop}.get(cmd)
    if fn is None:
        print("fleet-cn-probe-recover: unknown command %s" % cmd, file=sys.stderr)
        return 2
    book = Book(sd)
    return fn(book, args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
