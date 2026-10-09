#!/usr/bin/env python3
"""fleet_steward_health.py — the steward's health watch (issue #2674, EPIC #2668
C6), one step of the beat (bin/fleet_steward.py). No model; two checks:

  doctor  every FLEET_STEWARD_HEALTH_EVERY (1200 s: each day beat) the beat runs
          `fleet-doctor.sh --json` and compares it with the last run kept in
          global/steward.state.json (`health`): a WARN / FAIL row whose key —
          <row>:<fp>, fp = the first line of its message, digits folded — the last
          run did not have is NEW. The first run ever is the baseline: what is
          already wrong is not news.
  idle    every beat, two silences judged apart (idle_findings): worker
          windows idle (done) for FLEET_STEWARD_IDLE_SECS (7200 s), not pinned —
          sleep not off, none @reap_policy keep, and in those same seconds the
          sleep scan (logs/sleep.log, fleet-sleep.py) accepted nothing (no
          `state` / `eligible` record) ⇒ idle-sleep:<session>, the body listing
          the scan's refusals (#2622: every one `wrong fleet`); and @reap_policy
          done[:<dur>] windows while the idle reaper (logs/cleanup.launchd.log:
          reaped-idle / cleaned:done-no-pr) closed none ⇒ idle-reap:<session>.

A NEW key files ONE issue in the fleet's own repo (FLEET_STEWARD_HEALTH_REPO, else
the hosted */claude-fleet; none ⇒ the card only) through fleet-issue-file.sh
--no-breakage (a red base is --breakage's, never ours — #2078), its body carrying
`<!-- fleet:health key=<key> -->`; an open issue already carrying the marker (this
machine's or another's) gets a 「又出现」 comment instead. A key still active next
beat writes nothing; one that went away and comes back is new again. Each write
spends one of the beat's FLEET_STEWARD_WRITES, and a beat files at most
FLEET_STEWARD_HEALTH_MAX (5); past either the key stays un-noted and is tried next
beat. A doctor row must be new on FLEET_STEWARD_HEALTH_CONFIRM (2) runs in a row
before it is noted — one run's hiccup (a load-average timeout) files nothing.

Seams (selftest): FLEET_STEWARD_DOCTOR_CMD (prints the --json object),
FLEET_STEWARD_IDLE_CMD (argv + session; prints `wid TAB role TAB state TAB
state_ts TAB policy TAB pin TAB name`), FLEET_STEWARD_SLEEP_LOG,
FLEET_STEWARD_CLEANUP_LOG, FLEET_STEWARD_HEALTH_FIND_CMD
(argv + repo marker → an issue number or nothing), FLEET_STEWARD_HEALTH_FILE_CMD
(argv + repo title, body on stdin → the URL); comments go through
fleet_decision.post (FLEET_DECISION_POST_CMD).
"""
import collections
import datetime as dt
import hashlib
import json
import os
import re
import socket
import subprocess
import time
from pathlib import Path

import fleet_decision as fd

BIN = Path(__file__).resolve().parent
PANELS = ("dash", "plan", "backlog", "home")
MARK = "<!-- fleet:health key=%s -->"


def _int(key, dflt):
    v = os.environ.get(key) or fd._conf_val(key) or ""
    return int(v) if v.isdigit() else dflt


def _seam(name, argv, **kw):
    cmd = os.environ.get(name)
    if not cmd:
        return None
    return subprocess.run(cmd.split() + argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True, timeout=120, **kw)


def fingerprint(msg):
    first = (msg or "").strip().splitlines()[0] if (msg or "").strip() else ""
    norm = re.sub(r"\s+", " ", re.sub(r"\d+", "#", first)).strip()[:60]
    return hashlib.sha1(norm.encode("utf-8")).hexdigest()[:8]


# ---- the doctor ------------------------------------------------------------------

def doctor_due(h, now):
    # a beat a little early still counts; confirmed on its 2nd run ⇒ an issue within the hour
    return now - h.get("doctor_at", 0) >= _int("FLEET_STEWARD_HEALTH_EVERY", 1200) - 120


def run_doctor():
    """The doctor's rows, or None when it could not be read (never "all good")."""
    r = _seam("FLEET_STEWARD_DOCTOR_CMD", [])
    if r is None:
        try:
            r = subprocess.run(["sh", str(BIN / "fleet-doctor.sh"), "--json"], stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, universal_newlines=True,
                               timeout=_int("FLEET_STEWARD_DOCTOR_TIMEOUT", 300))
        except (OSError, subprocess.SubprocessError):
            return None
    try:
        d = json.loads((r.stdout or "").strip().splitlines()[-1])
    except (ValueError, IndexError):
        return None
    return d.get("rows") if isinstance(d.get("rows"), list) else None


def doctor_findings(rows):
    out = {}
    for r in rows or []:
        if r.get("level") not in ("WARN", "FAIL") or not r.get("row"):
            continue
        key = "%s:%s" % (r["row"], fingerprint(r.get("msg")))
        out.setdefault(key, {"kind": "doctor", "row": r["row"], "level": r["level"],
                             "msg": (r.get("msg") or "")[:600]})
    return out


# ---- the idle sessions -------------------------------------------------------------

def idle_windows(sess, sock):
    r = _seam("FLEET_STEWARD_IDLE_CMD", [sess])
    if r is None:
        fmt = "\t".join(("#{window_id}", "#{@fleet_role}", "#{?@worker_lifecycle,#{@worker_lifecycle},#{@claude_state}}",
                         "#{@claude_state_ts}", "#{@reap_policy}", "#{@pin}", "#{window_name}"))
        try:
            r = subprocess.run(["tmux", "-L", sock, "list-windows", "-t", "=" + sess, "-F", fmt],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True,
                               timeout=30)
        except (OSError, subprocess.SubprocessError):
            return []
    out = []
    for line in (r.stdout or "").splitlines():
        p = (line.split("\t") + [""] * 7)[:7]
        out.append(dict(zip(("wid", "role", "state", "ts", "policy", "pin", "name"), p)))
    return out


def sleep_mode(sess):
    v = os.environ.get("FLEET_SLEEP")
    if v is None:
        try:
            v = subprocess.run(["bash", "-c", '. "$0/fleet-lib.sh" >/dev/null 2>&1; fleet_load_conf "$1" >/dev/null 2>&1;'
                                ' printf %s "${FLEET_SLEEP:-observe}"', str(BIN), sess],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True,
                               timeout=30).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            v = ""
    return v or "observe"


def sleep_log():
    return Path(os.environ.get("FLEET_STEWARD_SLEEP_LOG") or (BIN.parent / "logs" / "sleep.log"))


def scan_since(sess, since):
    """(accepted, refusals Counter) of the sleep scan's records for `sess` since."""
    accepted, skips = 0, collections.Counter()
    try:
        with open(str(sleep_log()), "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 4 * 1024 * 1024))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return 0, skips
    for line in lines:
        try:
            rec = json.loads(line)
            at = time.mktime(time.strptime(rec.get("at", ""), "%Y-%m-%dT%H:%M:%S"))
        except (ValueError, TypeError, OverflowError):
            continue
        if rec.get("session") != sess or at < since:
            continue
        if "state" in rec or rec.get("eligible"):
            accepted += 1
        elif rec.get("skip"):
            skips[str(rec["skip"])[:120]] += 1
    return accepted, skips


REAP_RE = re.compile(r"^(\d\d):(\d\d):(\d\d) fleet-cleanup: (\S+): "
                     r"(?:reaped-idle:|reaped-test:|cleaned:done-no-pr )")


def reaps_since(sess, since):
    """The cleanup daemon's closes for `sess` since (its log stamps HH:MM:SS
    only: dates are walked back from the file's mtime, a later clock = a day
    earlier)."""
    p = Path(os.environ.get("FLEET_STEWARD_CLEANUP_LOG") or (BIN.parent / "logs" / "cleanup.launchd.log"))
    try:
        mtime = p.stat().st_mtime
        with open(str(p), "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 4 * 1024 * 1024))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return 0
    day = dt.datetime.fromtimestamp(mtime).replace(hour=0, minute=0, second=0, microsecond=0)
    last, n = None, 0
    for line in reversed(lines):
        m = re.match(r"^(\d\d):(\d\d):(\d\d) ", line)
        if not m:
            continue
        secs = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
        if last is not None and secs > last:
            day -= dt.timedelta(days=1)
        last = secs
        at = time.mktime(day.timetuple()) + secs
        if at < since:
            break
        r = REAP_RE.match(line)
        n += bool(r and r.group(4) == sess)
    return n


def _finding(kind, sess, mode, secs, wins, skips):
    return {"kind": kind, "session": sess, "mode": mode, "hours": "%g" % round(secs / 3600.0, 1), "n": len(wins),
            "windows": [{"name": w["name"], "wid": w["wid"], "policy": (w["policy"] or "").strip(),
                         "since": fd.show_time(dt.datetime.fromtimestamp(int(w["ts"]), fd.zone()))}
                        for w in wins[:20]],
            "skips": skips.most_common(8)}


def idle_findings(sess, sock, now):
    """Two silences, judged apart — a merged PR's cleanup says nothing about the
    sleep scan (#2622 refused every sleep while merged reaps ran on):
      idle-sleep:<s>  sleep not off, sessions idle past the window, the scan
                      accepted none of anything in it;
      idle-reap:<s>   sessions whose @reap_policy is done[:<dur>] idle past the
                      window, and the idle reaper closed none in it."""
    secs = _int("FLEET_STEWARD_IDLE_SECS", 7200)
    mode = sleep_mode(sess)
    idle = []
    for w in idle_windows(sess, sock):
        if w["role"] not in ("", "worker") or w["name"] in PANELS or w["state"] not in ("done", "idle"):
            continue
        if not w["ts"].isdigit() or now - int(w["ts"]) < secs or w["pin"] == "1":
            continue
        idle.append(w)
    out = {}
    sleepers = [w for w in idle if (w["policy"] or "").strip() != "keep"]
    if mode != "off" and sleepers:
        accepted, skips = scan_since(sess, now - secs)
        if not accepted:
            out["idle-sleep:%s" % sess] = _finding("sleep", sess, mode, secs, sleepers, skips)
    reapable = [w for w in idle if re.match(r"^done(:|$)", (w["policy"] or "").strip())]
    if reapable and not reaps_since(sess, now - secs):
        out["idle-reap:%s" % sess] = _finding("reap", sess, mode, secs, reapable, collections.Counter())
    return out


# ---- the issues ------------------------------------------------------------------

def health_repo(slugs):
    r = os.environ.get("FLEET_STEWARD_HEALTH_REPO") or fd._conf_val("FLEET_STEWARD_HEALTH_REPO") or ""
    if r:
        return r
    hits = sorted(v for v in slugs.values() if v.split("/")[-1] == "claude-fleet")
    return hits[0] if hits else ""


def find_open(repo, key):
    mk = MARK % key
    r = _seam("FLEET_STEWARD_HEALTH_FIND_CMD", [repo, mk])
    if r is not None:
        n = (r.stdout or "").strip()
        return n if n.isdigit() else ""
    try:
        out = subprocess.run(["gh", "api", "repos/%s/issues?state=open&per_page=100&sort=created&direction=desc" % repo,
                              "--jq", '.[] | select(.pull_request == null) | "\\(.number)\\t\\(.body // "" | gsub("[\\r\\n]"; " "))"'],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True,
                             timeout=60).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    for line in out.splitlines():
        n, _, body = line.partition("\t")
        if mk in body and n.isdigit():
            return n
    return ""


def file_issue(repo, title, body):
    r = _seam("FLEET_STEWARD_HEALTH_FILE_CMD", [repo, title], input=body)
    if r is None:
        r = subprocess.run(["bash", str(BIN / "fleet-issue-file.sh"), "--repo", repo, "--title", title,
                            "--body", body, "--label", "bug", "--no-breakage"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=120)
    url = (r.stdout or "").strip().splitlines()
    if r.returncode != 0 or not url:
        raise RuntimeError("cannot file the health issue: %s" % (r.stderr or "").strip()[-300:])
    return url[-1]


def what(f, tr):
    if f["kind"] == "doctor":
        return "%s %s — %s" % (f["level"], f["row"], f["msg"].splitlines()[0][:200] if f["msg"] else "")
    return tr("steward_health_%s_title_fmt" % ("idle" if f["kind"] == "sleep" else "reap"), f["n"], f["hours"],
              f["session"])


def render(key, f, tr, now_t, sess):
    seen = tr("steward_health_seen_fmt", socket.gethostname().split(".")[0], sess, fd.show_time(now_t))
    if f["kind"] == "doctor":
        title = tr("steward_health_doctor_title_fmt", f["row"], f["level"])
        lines = [tr("steward_health_doctor_body_fmt", seen, f["level"], f["row"]), "", "```", f["msg"], "```"]
    else:
        title = what(f, tr)
        lines = [tr("steward_health_idle_body_fmt", f["n"], f["hours"], f["mode"]) if f["kind"] == "sleep"
                 else tr("steward_health_reap_body_fmt", f["n"], f["hours"]), "", seen, "",
                 tr("steward_health_windows_head")]
        lines += ["- `%s` %s · %s%s" % (w["wid"], w["name"], w["since"], " · " + w["policy"] if w["policy"] else "")
                  for w in f["windows"]]
        if f["skips"]:
            lines += ["", tr("steward_health_skips_head")]
            lines += ["- %s × %d" % (why, n) for why, n in f["skips"]]
    return title, "\n".join(lines + ["", tr("steward_health_foot"), "", MARK % key])


def check(st, sess, sock, slugs, now_t, doctor_rows, tr):
    """The beat's health step. doctor_rows: the rows this beat read (None = not
    run or unreadable — the doctor half of the last run stands). Returns the
    card's (filed, again, deferred)."""
    h = st.d.setdefault("health", {})
    h.setdefault("active", {})
    h.setdefault("issues", {})
    now = int(now_t.timestamp())
    prev = h["active"]
    cur = {k: v for k, v in prev.items() if v.get("kind") == "doctor"}
    baseline = False
    young = set()             # new, not yet seen on FLEET_STEWARD_HEALTH_CONFIRM runs
    if doctor_rows is not None:
        baseline = "doctor_at" not in h
        h["doctor_at"] = now
        cur = doctor_findings(doctor_rows)
        seen = h.get("pending") or {}
        h["pending"] = {}
        for key in cur:
            if key not in prev and not baseline:
                h["pending"][key] = seen.get(key, 0) + 1
                if h["pending"][key] < _int("FLEET_STEWARD_HEALTH_CONFIRM", 2):
                    young.add(key)
    cur.update(idle_findings(sess, sock, now))
    repo = health_repo(slugs)
    filed = again = deferred = 0
    notes = []
    for key in sorted(cur):
        f = cur[key]
        if key in prev or (baseline and f["kind"] == "doctor"):
            continue
        if key in young:
            cur.pop(key)             # not noted ⇒ the next run counts it again
            continue
        if not repo:
            notes.append({"key": key, "what": what(f, tr), "action": "no-repo"})
            continue
        if st.budget_left() < 1 or filed + again >= _int("FLEET_STEWARD_HEALTH_MAX", 5):
            deferred += 1
            cur.pop(key)             # not noted ⇒ still new next beat
            continue
        try:
            n = find_open(repo, key)
            if n:
                fd.post(repo, n, "%s\n\n%s" % (tr("steward_health_again_fmt", fd.show_time(now_t),
                                                  st.d["beat"].get("n", 0), what(f, tr)), MARK % key))
                url, act = "https://github.com/%s/issues/%s" % (repo, n), "again"
                again += 1
            else:
                title, body = render(key, f, tr, now_t, sess)
                url, act = file_issue(repo, title, body), "filed"
                filed += 1
        except (RuntimeError, OSError, subprocess.SubprocessError) as exc:
            notes.append({"key": key, "what": what(f, tr), "action": "error", "why": str(exc)[:300]})
            cur.pop(key)
            continue
        st.spend(1)
        h.setdefault("pending", {}).pop(key, None)
        h["issues"][key] = {"url": url, "at": fd.iso(now_t)}
        notes.append({"key": key, "what": what(f, tr), "action": act, "url": url})
    h["active"] = cur
    return filed, again, deferred, notes
