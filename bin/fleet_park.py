#!/usr/bin/env python3
"""fleet_park.py — a stuck session gives its place back and comes back when what it
waits for arrives (issue #2671, EPIC #2668 C3). Run as bin/fleet-park.sh.

    fleet-park.sh park <key> --wait COND [--wait COND…] [--why T] [--now] [--session S]
    fleet-park.sh tick       [--judge] [--session S] [--now ISO]
    fleet-park.sh candidates [--session S] [--now ISO]
    fleet-park.sh wake <owner/name#N> [--session S]
    fleet-park.sh check COND [--since EPOCH]
    fleet-park.sh list [--json]

A COND is one of
    answer:<decision row id>        C1's row (fleet_decision.py) is no longer open
    pr:<owner/name#N>:merged        that PR merged
    issue:<owner/name#N>:closed     that issue closed
    time:<ISO>                      that moment passed
    reply:<owner/name#N>            a comment on that issue newer than the park
                                    (the park's own comment does not count)
Several --wait are ANY of them.

PARK, two steps, both written down in global/park.json so a killed tick loses
nothing (共同约定 4):
  1. request — the session is asked over the peer channel (fleet-peer-send.sh, no
     GitHub write) to write its handoff to the path fleet-handoff-file.sh names and
     end its turn. `--now` skips this.
  2. finalize — on the first tick the handoff is there and the session is not
     working, or FLEET_PARK_GRACE (300 s) after the request: the screen is kept
     (capture-pane → fleets/<sess>/park/<slug>-<N>.capture.txt), the branch pushed
     (`git push -u origin HEAD`; uncommitted files stay in the KEPT worktree), the
     parent told `blocked` (fleet-report-parent.sh --win), the window retired
     (fleet_win_retire — fleet-restore --auto never pulls it back) and stopped
     through fleet-worker-stop.sh (its /fleet-history row; the worktree stays), the
     hub lease released, the issue labelled `blocked` and given ONE comment
     「停放：等 …」 carrying `<!-- fleet:park wait=<cond> sid=<sid> -->`.
     There is no @park on a live window: parked = no window + `blocked` + the mark.
     A condition already met before step 2 cancels the park.

WAKE (tick): a parked issue whose condition holds loses `blocked` and is reopened by
dash-issue-session.sh --resume <the same sid> --seed-file <the first turn: read the
handoff, go on from where it was> --force — the same conversation, never from zero
(no transcript left, a Codex session ⇒ a plain /fleet-claim that reads the park
comment). A refusal (no room: rc 2) keeps it parked for the next tick.

JUDGE (`candidates`, `tick --judge`): a worker window (role worker, an @issue, no
@worker_lifecycle, no @pin, no @remote, reap policy not keep) that is
  - blocked (fleet_reap_state, #2540) for FLEET_PARK_BLOCKED_SECS (900), or
  - not working and has made no progress for FLEET_PARK_STALL_SECS (2700): its
    state stamp, its transcript and its branch head all older than that
— unless a /loop is pending or it holds a background job (fleet-cleanup-idle.py's
gate). Its condition: the open decision rows on its issue (answer:<id>), else
reply:<its issue>. At most FLEET_PARK_PER_TICK (3) requests a tick.

Every GitHub write is counted (2 a park, 1 a wake) and refused past --budget, so the
steward's beat keeps its FLEET_STEWARD_WRITES (共同约定 7). Events append to
logs/park.ndjson (ts · ev park|wake|cancel|request · ref · wait) — the stuck-time
metric's `park` end. global/park.idx (`<owner/name>#<N>` TAB fleet_id per parked
issue) is what fleet-restore.sh's fleet_parked reads.

Seams (selftest): FLEET_PARK_STATE_CMD (argv + wid → a reap word),
FLEET_PARK_BUSY_CMD (argv + wid; rc 0 = busy), FLEET_PARK_SEND_CMD (argv + wid, text
on stdin), FLEET_PARK_STOP_CMD (argv + session key), FLEET_PARK_SPAWN_CMD (argv +
dash-issue-session.sh's), FLEET_PARK_GH_CMD (argv + label|comment|state verb…),
FLEET_PARK_REPORT_CMD (argv + fleet-report-parent.sh's); comments come through
fleet_decision.py's FLEET_DECISION_COMMENTS_CMD.
"""
import argparse
import datetime as dt
import fcntl
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

import fleet_decision as fd
import fleet_iso

BIN = Path(__file__).resolve().parent
V = 1
FID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
REF_RE = re.compile(r"^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$")


def conf_dir():
    return Path(os.environ.get("FLEET_CONF_DIR") or (Path.home() / ".config" / "claude-fleet"))


def gdir():
    d = conf_dir() / "global"
    d.mkdir(parents=True, exist_ok=True)
    return d


def env_int(key, dflt):
    v = os.environ.get(key) or fd._conf_val(key) or ""
    return int(v) if v.isdigit() else dflt


_TEXT = None


def tr(key, *args):
    global _TEXT
    if _TEXT is None:
        try:
            out = subprocess.run(["sh", str(BIN / "fleet-ui-lang.sh"), "dump", "park_"],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            out = b""
        parts = out.decode("utf-8", "replace").split("\0")
        _TEXT = dict(zip(parts[0::2], parts[1::2]))
    text = _TEXT.get(key, key)
    for arg in args:
        text = text.replace("\x01", str(arg), 1)
    return text.replace("\x01", "")


def run(argv, **kw):
    kw.setdefault("timeout", 120)
    try:
        return subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, **kw)
    except (OSError, subprocess.SubprocessError) as e:
        return subprocess.CompletedProcess(argv, 127, "", str(e))


def seam(name, argv, **kw):
    cmd = os.environ.get(name)
    return run(cmd.split() + argv, **kw) if cmd else None


def sh_lib(snippet, *args):
    r = run(["bash", "-c", '. "$0/fleet-lib.sh" >/dev/null 2>&1; ' + snippet, str(BIN)] + list(args), timeout=60)
    return r.stdout.strip(), r.returncode


def session(given=None):
    s = given or os.environ.get("FLEET_SESSION") or ""
    if s:
        return s
    confs = sorted((conf_dir() / "fleets").glob("*/repos"))
    return confs[0].parent.name if len(confs) == 1 else ""


def socket(sess):
    return sh_lib('fleet_socket "$1"', sess)[0] or sess


def tm(sess, *args):
    return run(["tmux", "-L", socket(sess)] + list(args), timeout=30)


def iso(epoch):
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).isoformat(timespec="seconds")


def parse_ref(ref):
    m = REF_RE.match(ref or "")
    if not m:
        raise ValueError("not owner/name#N: %r" % ref)
    return m.group(1), m.group(2)


# ---- the book ---------------------------------------------------------------------

class Book:
    def __init__(self):
        self.path = gdir() / "park.json"
        self.lockf = open(str(gdir() / "park.lock"), "a")
        fcntl.flock(self.lockf, fcntl.LOCK_EX)
        try:
            self.d = json.loads(self.path.read_text())
        except (OSError, ValueError):
            self.d = {}
        self.d.setdefault("v", V)
        for k in ("pending", "parked"):
            self.d.setdefault(k, {})
        self.d.setdefault("woken", [])

    def save(self):
        self.d["woken"] = self.d["woken"][-50:]
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.d, ensure_ascii=False, indent=1, sort_keys=True))
        os.replace(str(tmp), str(self.path))
        idx = gdir() / "park.idx"
        tmp = idx.with_suffix(".tmp")
        tmp.write_text("".join("%s\t%s\n" % (ref, p.get("fid", "")) for ref, p in sorted(self.d["parked"].items())))
        os.replace(str(tmp), str(idx))


def event(ev, ref, **kw):
    d = conf_dir() / "logs"
    d.mkdir(parents=True, exist_ok=True)
    row = dict(ts=int(time.time()), ev=ev, ref=ref, **kw)
    with open(str(d / "park.ndjson"), "a", encoding="utf-8") as fh:
        fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def peek():
    """The book read without its lock — for the steward's every-minute fast path."""
    try:
        return json.loads((gdir() / "park.json").read_text())
    except (OSError, ValueError):
        return {}


# ---- windows ----------------------------------------------------------------------

WIN_FIELDS = ("wid", "role", "issue", "repo", "wt", "fid", "sid", "agent", "state", "state_ts", "lifecycle",
              "pin", "remote", "reap", "origin", "loop", "manifest", "name")
WIN_FMT = "\t".join(("#{window_id}", "#{@fleet_role}", "#{@issue}", "#{@repo}", "#{@worktree}", "#{@fleet_id}",
                     "#{@cc_session_id}", "#{@cc_agent}", "#{@claude_state}", "#{@claude_state_ts}",
                     "#{@worker_lifecycle}", "#{@pin}", "#{@remote}", "#{@reap_policy}", "#{@origin}",
                     "#{@loop}", "#{@handoff_manifest}", "#{window_name}"))


def windows(sess):
    r = tm(sess, "list-windows", "-t", "=" + sess, "-F", WIN_FMT)
    out = []
    for line in (r.stdout or "").splitlines():
        p = (line.split("\t") + [""] * len(WIN_FIELDS))[:len(WIN_FIELDS)]
        out.append(dict(zip(WIN_FIELDS, p)))
    return out


def win_for_key(sess, key):
    wid, rc = sh_lib('fleet_win_for_key "$1" "$2"', key, socket(sess))
    if rc != 0 or not wid:
        return None
    for w in windows(sess):
        if w["wid"] == wid:
            return w
    return None


def key_of(sess, w):
    """The window's address: `<slug>:issue-N` when the fleet hosts 2+ repos."""
    n_repos = len(list((conf_dir() / "fleets" / sess / "repos").glob("*.conf")))
    slug = sh_lib('fleet_slug "$1"', w["repo"])[0] if n_repos > 1 else ""
    return ("%s:" % slug if slug else "") + "issue-" + w["issue"]


def reap_word(sess, w):
    r = seam("FLEET_PARK_STATE_CMD", [w["wid"]])
    if r is None:
        r = run(["python3", str(BIN / "fleet-reap-live.py"), w["wid"], "--state", "--socket-name", socket(sess)],
                timeout=30)
    return (r.stdout or "").strip() or w["state"]


def busy(sess, w):
    """A pending /loop or a background job: its turn is over, its work is not. Or a
    person mid-step on what it put up (issue #2869: a `report waiting` page, its
    Playwright browser) — parking stops the process and the browser with it."""
    r = seam("FLEET_PARK_BUSY_CMD", [w["wid"]])
    if r is not None:
        return r.returncode == 0
    if w["loop"]:
        args = ["python3", str(BIN / "fleet_loop_mark.py"), "status", "--value", w["loop"]]
        if w["manifest"]:
            args += ["--manifest", w["manifest"]]
        if run(args, timeout=15).returncode == 0:
            return True
    if sh_lib('fleet_window_bg_busy "$1" "$2" 1', sess, w["wid"])[1] == 0:
        return True
    return sh_lib('h=$(fleet_window_human "$1" "$2") && fleet_human_hold_note "$1" "$2" park "$h"',
                  sess, w["wid"])[1] == 0


def transcript(w):
    if not (w["sid"] and w["wt"]):
        return None
    d, _ = sh_lib('fleet_transcript_dir "$1"', w["wt"])
    p = Path(d) / (w["sid"] + ".jsonl")
    return p if p.is_file() else None


def last_progress(w):
    """The newest of: the state stamp, the transcript's last write, the branch head."""
    t = [int(w["state_ts"]) if w["state_ts"].isdigit() else 0]
    tp = transcript(w)
    if tp:
        t.append(int(tp.stat().st_mtime))
    if w["wt"] and os.path.isdir(w["wt"]):
        r = run(["git", "-C", w["wt"], "log", "-1", "--format=%ct"], timeout=20)
        if r.stdout.strip().isdigit():
            t.append(int(r.stdout.strip()))
    return max(t)


# ---- conditions -------------------------------------------------------------------

def steward_rows():
    try:
        return json.loads((gdir() / "steward.state.json").read_text()).get("rows") or {}
    except (OSError, ValueError):
        return {}


def gh_state(kind, ref):
    repo, n = parse_ref(ref)
    r = seam("FLEET_PARK_GH_CMD", ["read", kind, repo, n])
    if r is None:
        r = run(["bash", str(BIN / "fleet-gh.sh"), kind, "view", n, "--repo", repo, "--json", "state",
                 "--max-age", "120"], timeout=60)
    try:
        return (json.loads(r.stdout or "{}").get("state") or "").upper()
    except ValueError:
        return ""


def comment_epoch(c):
    return fleet_iso.epoch(c.get("createdAt") or c.get("created_at") or "", utc=True)


def check(cond, since=0, now=None):
    """(met, why) for one condition."""
    now = now or time.time()
    kind, _, arg = cond.partition(":")
    if kind == "answer":
        row = steward_rows().get(arg)
        st = (row or {}).get("state", "")
        return (bool(row) and st != "open"), st or "unknown"
    if kind == "pr" and arg.endswith(":merged"):
        st = gh_state("pr", arg[:-len(":merged")])
        return st == "MERGED", st.lower() or "unknown"
    if kind == "issue" and arg.endswith(":closed"):
        st = gh_state("issue", arg[:-len(":closed")])
        return st == "CLOSED", st.lower() or "unknown"
    if kind == "time":
        at = fleet_iso.epoch(arg, default=None, utc=True)
        if at is None:
            return False, "bad time"
        return now >= at, arg
    if kind == "reply":
        repo, n = parse_ref(arg)
        try:
            comments = fd.fetch_comments(repo, n)
        except (RuntimeError, ValueError, OSError):
            return False, "unreadable"
        new = [c for c in comments if comment_epoch(c) > since and "fleet:park" not in (c.get("body") or "")]
        return bool(new), "%d new" % len(new)
    return False, "unknown condition"


def check_any(conds, since=0, now=None):
    for c in conds:
        met, why = check(c, since, now)
        if met:
            return c, why
    return None, ""


def valid_cond(cond):
    kind, _, arg = cond.partition(":")
    if kind == "answer":
        return bool(arg)
    if kind in ("pr", "issue"):
        want = ":merged" if kind == "pr" else ":closed"
        return arg.endswith(want) and bool(REF_RE.match(arg[:-len(want)]))
    if kind == "reply":
        return bool(REF_RE.match(arg))
    if kind == "time":
        return check(cond, now=0)[1] != "bad time"
    return False


def say_cond(cond):
    kind, _, arg = cond.partition(":")
    if kind == "answer":
        row = steward_rows().get(arg) or {}
        return tr("park_wait_answer_fmt", row.get("item") or arg)
    if kind == "pr":
        return tr("park_wait_pr_fmt", arg.rsplit(":", 1)[0])
    if kind == "issue":
        return tr("park_wait_issue_fmt", arg.rsplit(":", 1)[0])
    if kind == "time":
        return tr("park_wait_time_fmt", arg)
    if kind == "reply":
        return tr("park_wait_reply_fmt", arg)
    return cond


# ---- GitHub writes (counted) --------------------------------------------------------

def gh(verb, repo, n, *rest, body=None):
    r = seam("FLEET_PARK_GH_CMD", [verb, repo, n] + list(rest), input=body)
    if r is not None:
        return r.returncode == 0
    if verb == "label":
        op = "--add-label" if rest[0] == "add" else "--remove-label"
        r = run(["bash", "-c", '. "$0/fleet-lib.sh" >/dev/null 2>&1; . "$0/fleet-gh-lib.sh"; '
                 'fleet_gh_write gh issue edit "$1" --repo "$2" "$3" blocked', str(BIN), n, repo, op], timeout=90)
        return r.returncode == 0
    if verb == "comment":
        r = run(["bash", str(BIN / "fleet-ticket.sh"), "comment", "gh:%s#%s" % (repo, n), "--note",
                 "--body-file", "-"], input=body, timeout=90)
        return r.returncode == 0
    return False


# ---- park -------------------------------------------------------------------------

def park_dir(sess):
    d = conf_dir() / "fleets" / sess / "park"
    d.mkdir(parents=True, exist_ok=True)
    return d


def handoff_path(sess, w):
    out, rc = sh_lib('"$0/fleet-handoff-file.sh" path --session "$1" --repo "$2" --slug "$3"',
                     sess, w["repo"], "park-" + w["issue"])
    if rc == 0 and out:
        return out.splitlines()[-1]
    return str(park_dir(sess) / ("%s-%s.handoff.md" % (sh_lib('fleet_slug "$1"', w["repo"])[0] or "repo", w["issue"])))


def request(sess, book, w, waits, why, now):
    ref = "%s#%s" % (w["repo"], w["issue"])
    hp = handoff_path(sess, w)
    text = tr("park_request_fmt", why or tr("park_why_stuck"), " / ".join(say_cond(c) for c in waits), hp)
    r = seam("FLEET_PARK_SEND_CMD", [w["wid"]], input=text)
    if r is None:
        r = run(["bash", str(BIN / "fleet-peer-send.sh"), "-L", socket(sess), "--repo", w["repo"],
                 "--expect-issue", w["issue"], w["wid"], "-"], input=text, timeout=60)
    book.d["pending"][ref] = {"ref": ref, "key": key_of(sess, w), "wid": w["wid"], "fid": w["fid"],
                              "wait": waits, "why": why, "at": int(now), "handoff": hp,
                              "sent": r.returncode in (0, 3)}
    event("request", ref, wait=waits)
    return ref


def finalize(sess, book, p, w, now, budget):
    """Step 2. Returns the GitHub writes spent, or None when it must wait."""
    ref = p["ref"]
    repo, n = parse_ref(ref)
    if budget < 2:
        return None
    pdir = park_dir(sess)
    base = "%s-%s" % (sh_lib('fleet_slug "$1"', repo)[0] or "repo", n)
    cap = pdir / (base + ".capture.txt")
    r = tm(sess, "capture-pane", "-p", "-J", "-S", "-3000", "-t", w["wid"])
    cap.write_text(r.stdout or "")
    pushed, branch, dirty = "", "", 0
    if w["wt"] and os.path.isdir(w["wt"]):
        branch = run(["git", "-C", w["wt"], "rev-parse", "--abbrev-ref", "HEAD"], timeout=20).stdout.strip()
        dirty = len([x for x in run(["git", "-C", w["wt"], "status", "--porcelain"], timeout=30).stdout.splitlines() if x])
        pr = run(["git", "-C", w["wt"], "push", "-q", "-u", "origin", "HEAD"], timeout=120)
        pushed = "ok" if pr.returncode == 0 else (pr.stderr.strip().splitlines() or ["failed"])[-1][:200]
    hp = p.get("handoff") or ""
    has_handoff = bool(hp) and os.path.isfile(hp) and os.path.getmtime(hp) >= p.get("at", 0) - 5
    summary = tr("park_report_fmt", " / ".join(say_cond(c) for c in p["wait"]))
    rr = seam("FLEET_PARK_REPORT_CMD", ["--state", "blocked", "--win", w["wid"], "--summary", summary])
    if rr is None:
        run(["bash", str(BIN / "fleet-report-parent.sh"), "-L", socket(sess), "--state", "blocked",
             "--win", w["wid"], "--summary", summary], timeout=60)
    sh_lib('fleet_win_retire "$1" "$2"', w["wid"], socket(sess))
    # The stop below is an /exit: session-end-hook.sh reads @parking and keeps the
    # issue OPEN and the worktree in place — a parked issue comes back (#2949).
    tm(sess, "set-option", "-w", "-t", w["wid"], "@parking", ref)
    sr = seam("FLEET_PARK_STOP_CMD", [sess, p["key"]])
    if sr is None:
        sr = run(["bash", str(BIN / "fleet-worker-stop.sh"), sess, p["key"]], timeout=180)
    if sr.returncode != 0:
        p["error"] = "stop: " + (sr.stdout.strip() or sr.stderr.strip())[:200]
        return None
    sh_lib('fleet_hub_lease release "$1" "$2" "$3"', sess, repo, n)
    wait = ",".join(p["wait"])
    body = "\n".join([
        tr("park_comment_head_fmt", " / ".join(say_cond(c) for c in p["wait"])), "",
        tr("park_comment_handoff_fmt", hp) if has_handoff else tr("park_comment_nohandoff_fmt", str(cap)),
        tr("park_comment_branch_fmt", branch or "-", tr("park_pushed") if pushed == "ok" else
           tr("park_push_failed_fmt", pushed or "-"), dirty, w["wt"] or "-"),
        tr("park_comment_back_fmt", w["sid"] or "-"), "",
        "<!-- fleet:park wait=%s sid=%s -->" % (wait, w["sid"] or "-")])
    spent = 0
    if gh("label", repo, n, "add"):
        spent += 1
    if gh("comment", repo, n, body=body):
        spent += 1
    book.d["parked"][ref] = {"ref": ref, "key": p["key"], "wait": p["wait"], "why": p.get("why", ""),
                             "at": int(now), "sid": w["sid"], "agent": w["agent"], "fid": w["fid"],
                             "wt": w["wt"], "branch": branch, "pushed": pushed, "dirty": dirty,
                             "handoff": hp if has_handoff else "", "capture": str(cap),
                             "origin": w["origin"], "session": sess}
    book.d["pending"].pop(ref, None)
    event("park", ref, wait=p["wait"], sid=w["sid"], pushed=pushed, handoff=bool(has_handoff))
    since = book.d.setdefault("stuck", {}).pop(ref, None)
    if since is not None:            # its stuck stretch ends here: the place is given back
        event("stuck", ref, since=int(since), end=int(now), held=int(now - since), how="parked")
    return spent


def advance(sess, book, now, budget):
    """Every pending park one step on. Returns (parked refs, writes)."""
    done, spent = [], 0
    wins = {w["wid"]: w for w in windows(sess)}
    for ref, p in list(book.d["pending"].items()):
        w = wins.get(p["wid"])
        if not w or w["fid"] != p["fid"]:
            book.d["pending"].pop(ref, None)          # gone some other way: nothing to park
            event("cancel", ref, why="window gone")
            continue
        met, _ = check_any(p["wait"], since=p["at"], now=now)
        if met:
            book.d["pending"].pop(ref, None)
            event("cancel", ref, why="met:" + met)
            continue
        hp = p.get("handoff") or ""
        written = bool(hp) and os.path.isfile(hp) and os.path.getmtime(hp) >= p["at"] - 5
        late = now - p["at"] >= env_int("FLEET_PARK_GRACE", 300)
        if not late and not (written and reap_word(sess, w) != "working"):
            continue
        got = finalize(sess, book, p, w, now, budget - spent)
        if got is not None:
            spent += got
            done.append(ref)
    return done, spent


# ---- judge ------------------------------------------------------------------------

def survey(sess, now, held=()):
    """(candidates, stuck): the windows to park now, and every worker stuck right
    now as {ref: since} — blocked (from its state stamp), or stalled (from the
    moment FLEET_PARK_STALL_SECS without progress ran out). A pending /loop or a
    background job is never stuck. The stuck map is the metric's (EPIC #2668
    读数口径「卡住占位时长」): observe() turns its changes into segments."""
    rows = steward_rows()
    out, stuck = [], {}
    blocked_after = env_int("FLEET_PARK_BLOCKED_SECS", 900)
    stall = env_int("FLEET_PARK_STALL_SECS", 2700)
    for w in windows(sess):
        if w["role"] not in ("", "worker") or not w["issue"].isdigit() or not w["repo"]:
            continue
        if w["lifecycle"] or w["pin"] or w["remote"] or w["reap"] == "keep":
            continue
        ref = "%s#%s" % (w["repo"], w["issue"])
        if ref in held:
            continue
        word = reap_word(sess, w)
        if word in ("exited", ""):
            continue
        ts = int(w["state_ts"]) if w["state_ts"].isdigit() else 0
        if word == "blocked":
            since, due = ts, now - ts >= blocked_after
            why = tr("park_why_blocked_fmt", int(now - ts) // 60)
        else:
            last = last_progress(w)
            if now - last < stall or (word == "working" and transcript(w) is None):
                continue        # moving, or working with nothing to judge progress by
            since, due = last + stall, True
            why = tr("park_why_stall_fmt", int(now - last) // 60)
        if busy(sess, w):
            continue
        stuck[ref] = since
        if not due:
            continue
        src = "gh:%s#%s" % (w["repo"], w["issue"])
        waits = ["answer:" + r["id"] for r in rows.values() if r.get("src") == src and r.get("state") == "open"]
        out.append({"w": w, "ref": ref, "why": why, "wait": waits or ["reply:" + ref], "since": since})
    return out, stuck


def candidates(sess, now, book=None):
    held = set(book.d["pending"]) | set(book.d["parked"]) if book is not None else set()
    return survey(sess, now, held)[0]


def observe(book, stuck, now):
    """Close every stuck segment that ended since the last look: parked (its ref
    is in the book now), or back to work / gone. One `stuck` event each."""
    prev = book.d.setdefault("stuck", {})
    for ref, since in list(prev.items()):
        if ref in stuck:
            continue
        p = book.d["parked"].get(ref) or book.d["pending"].get(ref)
        if p is not None and ref in book.d["pending"]:
            stuck[ref] = since          # asked for its handoff: still holding its place
            continue
        how = "parked" if ref in book.d["parked"] else "ended"
        end = book.d["parked"][ref].get("at", now) if how == "parked" else now
        event("stuck", ref, since=int(since), end=int(end), held=int(end - since), how=how)
    book.d["stuck"] = {r: int(t) for r, t in stuck.items()}


def observe_only(sess, now=None):
    """The steward's `count` mode: the stuck segments measured, nothing parked —
    at most once every FLEET_STEWARD_AGAIN (600 s)."""
    now = now or time.time()
    if now - peek().get("observed_at", 0) < env_int("FLEET_STEWARD_AGAIN", 600):
        return False
    book = Book()
    observe(book, survey(sess, now, set(book.d["parked"]))[1], now)
    book.d["observed_at"] = int(now)
    book.save()
    return True


# ---- wake -------------------------------------------------------------------------

def wake(sess, book, ref, met, now, budget):
    p = book.d["parked"][ref]
    repo, n = parse_ref(ref)
    if budget < 1:
        return None
    seedf = park_dir(sess) / ("%s-%s.seed" % (sh_lib('fleet_slug "$1"', repo)[0] or "repo", n))
    seedf.write_text(tr("park_seed_fmt", say_cond(met), p.get("handoff") or tr("park_seed_nohandoff"),
                        p.get("capture") or "-", "#" + n))
    gh("label", repo, n, "remove")
    args = [n, sess, "--repo", repo, "--force", "--seed-file", str(seedf)]
    if p.get("sid") and p.get("agent", "claude") in ("", "claude"):
        args += ["--resume", p["sid"]]
    origins = [p["origin"], "hub"] if p.get("origin") else ["hub"]
    rc = 1
    for o in origins:
        r = seam("FLEET_PARK_SPAWN_CMD", args + ["--origin", o])
        if r is None:
            r = run(["bash", str(BIN / "dash-issue-session.sh")] + args + ["--origin", o], timeout=300)
        rc = r.returncode
        if rc != 4:            # 4 = that parent is gone: the hub takes it
            break
    if rc != 0:
        # no room (2) or a refusal: it stays parked, `blocked` back on, next tick again
        p["error"] = "spawn rc %d" % rc
        p["tries"] = p.get("tries", 0) + 1
        gh("label", repo, n, "add")
        return 2
    book.d["parked"].pop(ref, None)
    book.d["woken"].append({"ref": ref, "at": int(now), "met": met, "sid": p.get("sid", ""),
                            "parked_at": p.get("at", 0)})
    event("wake", ref, met=met, sid=p.get("sid", ""), held=int(now) - p.get("at", int(now)))
    return 1


def wake_due(sess, book, now, budget):
    woken, spent = [], 0
    for ref, p in list(book.d["parked"].items()):
        if p.get("session", sess) != sess:
            continue
        met, _ = check_any(p["wait"], since=p.get("at", 0), now=now)
        if not met:
            continue
        got = wake(sess, book, ref, met, now, budget - spent)
        if got == 1:
            woken.append(ref)
            spent += 1
        elif got == 2:
            spent += 2
    return woken, spent


# ---- the tick (the steward's beat calls this) ---------------------------------------

def tick(sess, now=None, judge=False, budget=None):
    """One step for everything: pending parks advance, parked ones whose condition
    holds wake, and (judge) new stuck sessions are asked to write their handoff.
    Returns {requested, parked, woken, writes, n_parked, n_pending}."""
    now = now or time.time()
    budget = env_int("FLEET_STEWARD_WRITES", 20) if budget is None else budget
    book = Book()
    parked, spent = advance(sess, book, now, budget)
    woken, s2 = wake_due(sess, book, now, budget - spent)
    spent += s2
    requested = []
    if judge:
        cands, stuck = survey(sess, now, set(book.d["pending"]) | set(book.d["parked"]))
        for c in cands[:env_int("FLEET_PARK_PER_TICK", 3)]:
            requested.append(request(sess, book, c["w"], c["wait"], c["why"], now))
            stuck[c["ref"]] = c["since"]
        observe(book, stuck, now)
        book.d["observed_at"] = int(now)
    book.save()
    return {"requested": requested, "parked": parked, "woken": woken, "writes": spent,
            "n_parked": len(book.d["parked"]), "n_pending": len(book.d["pending"]),
            "list": [{"ref": r, "wait": p["wait"], "at": p.get("at", 0), "key": p.get("key", "")}
                     for r, p in sorted(book.d["parked"].items())]}


# ---- commands ---------------------------------------------------------------------

def cmd_park(a):
    sess = session(a.session)
    if not sess:
        sys.stderr.write("fleet-park: no fleet session\n")
        return 2
    bad = [c for c in a.wait if not valid_cond(c)]
    if bad:
        sys.stderr.write("fleet-park: not a condition: %s\n" % ", ".join(bad))
        return 2
    w = win_for_key(sess, a.key)
    if not w or not w["issue"].isdigit() or not w["repo"]:
        sys.stderr.write("fleet-park: no worker window answers %s\n" % a.key)
        return 1
    now = time.time()
    book = Book()
    ref = "%s#%s" % (w["repo"], w["issue"])
    if ref in book.d["parked"]:
        print("already parked %s" % ref)
        return 0
    if ref not in book.d["pending"]:
        if a.now:       # no request: the screen and the branch are the record
            book.d["pending"][ref] = {"ref": ref, "key": key_of(sess, w), "wid": w["wid"], "fid": w["fid"],
                                      "wait": a.wait, "why": a.why or "", "at": int(now), "handoff": ""}
        else:
            request(sess, book, w, a.wait, a.why or "", now)
    if a.now:
        got = finalize(sess, book, book.d["pending"][ref], w, now, env_int("FLEET_STEWARD_WRITES", 20))
        book.save()
        if got is None:
            sys.stderr.write("fleet-park: %s not parked: %s\n" % (ref, book.d["pending"].get(ref, {}).get("error", "?")))
            return 1
        print("parked %s" % ref)
        return 0
    book.save()
    print("requested %s" % ref)
    return 0


def cmd_tick(a):
    sess = session(a.session)
    if not sess:
        sys.stderr.write("fleet-park: no fleet session\n")
        return 2
    now = fd.now_local(a.now).timestamp() if a.now else time.time()
    out = tick(sess, now, judge=a.judge)
    out.pop("list")
    print(json.dumps(out, ensure_ascii=False))
    return 0


def cmd_candidates(a):
    sess = session(a.session)
    now = fd.now_local(a.now).timestamp() if a.now else time.time()
    for c in candidates(sess, now):
        print("%s\t%s\t%s\t%s" % (c["ref"], c["w"]["wid"], ",".join(c["wait"]), c["why"]))
    return 0


def cmd_wake(a):
    sess = session(a.session)
    book = Book()
    if a.ref not in book.d["parked"]:
        sys.stderr.write("fleet-park: %s is not parked\n" % a.ref)
        return 1
    got = wake(sess, book, a.ref, "manual", time.time(), env_int("FLEET_STEWARD_WRITES", 20))
    book.save()
    print("woken %s" % a.ref if got == 1 else "not woken %s: %s" % (a.ref, book.d["parked"].get(a.ref, {}).get("error")))
    return 0 if got == 1 else 1


def cmd_check(a):
    met, why = check(a.cond, since=a.since)
    print("%s %s" % ("met" if met else "waiting", why))
    return 0 if met else 1


def cmd_list(a):
    d = peek()
    if a.json:
        print(json.dumps({"parked": d.get("parked", {}), "pending": d.get("pending", {})}, ensure_ascii=False, indent=1))
        return 0
    for ref, p in sorted((d.get("parked") or {}).items()):
        print("parked\t%s\t%s\t%s" % (ref, ",".join(p["wait"]), iso(p.get("at", 0))))
    for ref, p in sorted((d.get("pending") or {}).items()):
        print("pending\t%s\t%s\t%s" % (ref, ",".join(p["wait"]), iso(p.get("at", 0))))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="fleet-park.sh")
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("park")
    p.add_argument("key")
    p.add_argument("--wait", action="append", required=True)
    p.add_argument("--why")
    p.add_argument("--now", action="store_true")
    p.add_argument("--session")
    p = sub.add_parser("tick")
    p.add_argument("--judge", action="store_true")
    p.add_argument("--session")
    p.add_argument("--now")
    p = sub.add_parser("candidates")
    p.add_argument("--session")
    p.add_argument("--now")
    p = sub.add_parser("wake")
    p.add_argument("ref")
    p.add_argument("--session")
    p = sub.add_parser("check")
    p.add_argument("cond")
    p.add_argument("--since", type=int, default=0)
    p = sub.add_parser("list")
    p.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    fn = {"park": cmd_park, "tick": cmd_tick, "candidates": cmd_candidates, "wake": cmd_wake,
          "check": cmd_check, "list": cmd_list}.get(a.cmd)
    if not fn:
        ap.print_help(sys.stderr)
        return 2
    return fn(a)


if __name__ == "__main__":
    sys.exit(main())
