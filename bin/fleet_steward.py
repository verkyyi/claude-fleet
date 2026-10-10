#!/usr/bin/env python3
"""fleet_steward.py — the steward's beat, with no model (issue #2670, EPIC #2668
C2). Run as bin/fleet-steward-tick.sh; bin/fleet-steward.sh opens the window.

    fleet-steward-tick.sh beat   [--session S] [--force] [--now ISO]
    fleet-steward-tick.sh delta  [--session S] [--now ISO]
    fleet-steward-tick.sh answer --row ID --text T [--source URL] [--by steward|person] [--session S]
    fleet-steward-tick.sh sheet  [--session S] [--now ISO]
    fleet-steward-tick.sh card   [--session S]
    fleet-steward-tick.sh followups [--watch owner/name#N …] [--json]

`beat` is the diskguard tick's (home_watch, every minute): it returns at once
until the next beat is due — FLEET_STEWARD_EVERY (1200 s), 600 s after a beat
that changed something, FLEET_STEWARD_NIGHT_EVERY (3600 s) from 23:00 to 08:00 on
the person's clock (fleet_decision.zone). A due beat:

  1. flushes the writes the last beat deferred;
  2. reads, with no model and no GitHub write: the children ledgers of the
     orchestrator, of each of its children that has one (the batch drivers) and of
     every window wearing an @epic (fleet-children.sh --json --since <seq>), the
     epic marks (global/epic-running.d), and the asks (C1's fleet_decision.py
     parse, through fleet-gh.sh's cache) of every session waiting on a person,
     plus every row still open;
  3. answers each due row by its default (fleet_decision.apply_due) — within the
     beat's write budget;
  4. asks fleet-epic-backstop.sh about the open PRs of a batch whose driver is
     gone (its mark stale), so the model never merges under a busy worker;
  4b. watches the fleet's own health (bin/fleet_steward_health.py, issue #2674):
     a doctor row newly WARN / FAIL, or idle sessions nothing has slept or
     reaped for two hours, files ONE issue per fingerprint — within the budget;
  5. writes global/steward.delta.json + global/steward.state.json, stamps
     @orch_decide on the orchestrator's window (the open rows of the last sheet —
     fleet-control-read.sh carries it to the client's 「新任务」 row), and
  5b. gathers what finished batches leave for a person into ONE 「待你动手」 list
     and runs what it may (bin/fleet_followup.py, issue #2672 — its header is
     the spec): @orch_todo carries the open count to the client's list;
  5d. draws ONE member of each batch that finished (bin/fleet_sample.py, issue
     #2678 — its header is the spec) and, when it drew one, posts the sheet on
     this beat with the sample in its read-only area (no model turn);
  5c. moves the parks on (bin/fleet_park.py, issue #2671 C3): a stuck session is
     asked for its handoff, parked once it wrote one (or its grace ran out), and
     woken on the same conversation when what it waits for arrives — within the
     same write budget; @orch_park carries the count to the client's 「停放 N」.
     FLEET_STEWARD_PARK=0 leaves parking off. A pending park is advanced on every
     minute's call, due or not (its grace is 5 minutes, the beat 10-60);
  6. ONLY when there is something for the model — a new open question, a BLOCKED /
     FAILED report, a batch with no driver — hands the steward window one turn
     (`[steward] …`). A calm beat calls no model (共同约定 · 怎么算成功).

`answer` is the one road an answer takes: the steward's own (`--by steward`,
`--source` = where the batch's charter says so) and the person's from the
orchestrator (`--by person`) — fleet-comment.sh --to-worker on the row's issue
with `<!-- fleet:answer row=<id> by=<by> -->`, which C1's parser reads as answered.
`sheet` renders every row still open as C1's table (fleet_decision.render), keeps
it as `decision-YYYY-MM-DD.md` (C8's desk ticket when FLEET_STEWARD_DESK names one
and bin/fleet-ticket.sh exists), and sends the orchestrator ONE `[decision]`
message — only when the sheet has a row the last one did not.

Every GitHub write counts against FLEET_STEWARD_WRITES (20) per beat (共同约定 7);
one past it waits for the next beat, and the card says 「延后 N 条」.

Seams (selftest): FLEET_STEWARD_WINDOWS_CMD (prints `wid TAB role TAB state TAB
issue TAB repo TAB epic TAB key`), FLEET_STEWARD_CHILDREN_CMD (argv + key --json
--since N), FLEET_STEWARD_SEND_CMD (argv + target, text on stdin),
FLEET_STEWARD_BACKSTOP_CMD (argv + key --pr N --parent P), FLEET_STEWARD_STAMP_CMD
(argv + N: the decide count), and fleet_decision.py's own three.
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
import uuid
from pathlib import Path

import fleet_decision as fd
import fleet_followup as fu
import fleet_park
import fleet_sample as samp
import fleet_steward_health as health
import fleet_steward_page as page

BIN = Path(__file__).resolve().parent
V = 1
WAKE_STATES = ("BLOCKED", "FAILED")


def conf_dir():
    return Path(os.environ.get("FLEET_CONF_DIR") or (Path.home() / ".config" / "claude-fleet"))


def gdir():
    d = conf_dir() / "global"
    d.mkdir(parents=True, exist_ok=True)
    return d


def env_int(key, dflt):
    v = os.environ.get(key) or fd._conf_val(key) or ""
    return int(v) if v.isdigit() else dflt


# ---- strings: bin/fleet-ui-lang.sh (共同约定 11) ----------------------------------

_TEXT = None


def tr(key, *args):
    global _TEXT
    if _TEXT is None:
        try:
            out = subprocess.run(["sh", str(BIN / "fleet-ui-lang.sh"), "dump", "steward_"],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            out = b""
        parts = out.decode("utf-8", "replace").split("\0")
        _TEXT = dict(zip(parts[0::2], parts[1::2]))
    text = _TEXT.get(key, key)
    for arg in args:
        text = text.replace("\x01", str(arg), 1)
    return text.replace("\x01", "")


# ---- the fleet --------------------------------------------------------------------

def session(given=None):
    s = given or os.environ.get("FLEET_SESSION") or ""
    if s:
        return s
    if os.environ.get("TMUX"):
        r = subprocess.run(["tmux", "display-message", "-p", "#{?#{session_group},#{session_group},#{session_name}}"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True)
        if r.stdout.strip():
            return r.stdout.strip()
    confs = sorted((conf_dir() / "fleets").glob("*/repos"))
    return confs[0].parent.name if len(confs) == 1 else ""


def sh_lib(snippet, *args):
    r = subprocess.run(["bash", "-c", '. "$0/fleet-lib.sh" >/dev/null 2>&1; ' + snippet, str(BIN)] + list(args),
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True, timeout=30)
    return r.stdout.strip()


def socket(sess):
    return sh_lib('fleet_socket "$1"', sess) or sess


def mode(sess):
    r = subprocess.run(["bash", str(BIN / "fleet-steward.sh"), "mode", sess], stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, universal_newlines=True, timeout=30)
    return r.stdout.strip() or "off"


def _seam(name, argv, **kw):
    cmd = os.environ.get(name)
    if not cmd:
        return None
    return subprocess.run(cmd.split() + argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True, timeout=120, **kw)


def windows(sess):
    """[{wid, role, state, issue, repo, epic, key}] of this fleet's windows."""
    r = _seam("FLEET_STEWARD_WINDOWS_CMD", [sess])
    if r is None:
        fmt = "\t".join(("#{window_id}", "#{@fleet_role}",
                         "#{?@worker_lifecycle,#{@worker_lifecycle},#{@claude_state}}",
                         "#{@issue}", "#{@repo}", "#{@epic}"))
        r = subprocess.run(["tmux", "-L", socket(sess), "list-windows", "-t", "=" + sess, "-F", fmt],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True, timeout=30)
    out = []
    for line in (r.stdout or "").splitlines():
        p = (line.split("\t") + [""] * 7)[:7]
        w = dict(zip(("wid", "role", "state", "issue", "repo", "epic", "key"), p))
        if w["epic"] and not w["key"] and os.environ.get("FLEET_STEWARD_WINDOWS_CMD") is None:
            w["key"] = sh_lib('fleet_window_okey "$1" "$2"', sess, w["wid"])
        out.append(w)
    return out


def repo_of_slug(sess):
    m = {}
    for f in (conf_dir() / "fleets" / sess / "repos").glob("*.conf"):
        try:
            hit = re.search(r'^FLEET_REPO="?([^"\s]+)"?', f.read_text(), re.M)
        except OSError:
            continue
        if hit:
            m[f.stem] = hit.group(1)
    return m


def children(sess, key, since):
    r = _seam("FLEET_STEWARD_CHILDREN_CMD", [key, "--json", "--since", str(since)])
    if r is None:
        r = subprocess.run(["bash", str(BIN / "fleet-children.sh"), key, "--json", "--since", str(since),
                            "-L", socket(sess)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           universal_newlines=True, timeout=120)
    try:
        return json.loads(r.stdout or "{}")
    except ValueError:
        return {}


def send(sess, target, text):
    r = _seam("FLEET_STEWARD_SEND_CMD", [target], input=text)
    if r is None:
        r = subprocess.run(["bash", str(BIN / "fleet-peer-send.sh"), "-L", socket(sess), target, "-"],
                           input=text, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, timeout=60)
    return r.returncode in (0, 3)        # 3 = queued: delivered when it can be


def stamp_decide(sess, n, wins, opt="@orch_decide"):
    if opt == "@orch_decide":
        r = _seam("FLEET_STEWARD_STAMP_CMD", [str(n)])
        if r is not None:
            return
    elif os.environ.get("FLEET_STEWARD_STAMP_CMD"):
        return
    for w in wins:
        if w["role"] == "orchestrator":
            args = ["tmux", "-L", socket(sess), "set-window-option", "-t", w["wid"]]
            subprocess.run(args + ([opt, str(n)] if n else ["-u", opt]),
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)


def park_on():
    return (os.environ.get("FLEET_STEWARD_PARK") or fd._conf_val("FLEET_STEWARD_PARK") or "1") != "0"


def park_step(sess, now_t, judge, budget):
    """bin/fleet_park.py's tick; None when parking is off or it failed."""
    if not park_on():
        return None
    try:
        return fleet_park.tick(sess, now_t.timestamp(), judge=judge, budget=budget)
    except Exception as e:  # a park bug never stops the beat
        sys.stderr.write("fleet-steward-tick: park: %s\n" % e)
        return None


def backstop(key, pr, parent):
    r = _seam("FLEET_STEWARD_BACKSTOP_CMD", [key, "--pr", str(pr), "--parent", parent])
    if r is None:
        r = subprocess.run(["bash", str(BIN / "fleet-epic-backstop.sh"), key, "--pr", str(pr), "--parent", parent],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=120)
    line = (r.stdout or "").strip().splitlines()
    return ("clear" if r.returncode == 0 else "busy"), (line[0] if line else "")


def epic_marks(now):
    """[{epic, repo, fresh}] from global/epic-running.d (fleet-epic-heartbeat.sh)."""
    out = []
    for f in sorted((gdir() / "epic-running.d").glob("*")):
        kv = {}
        try:
            for line in f.read_text().splitlines():
                k, _, v = line.partition(": ")
                kv[k.strip()] = v.strip()
        except OSError:
            continue
        ep, ttl = kv.get("epoch", ""), kv.get("ttl", "2700")
        if not ep.isdigit() or not kv.get("epic"):
            continue
        out.append({"epic": kv["epic"], "repo": kv.get("repo", "-"),
                    "fresh": int(ep) + (int(ttl) if ttl.isdigit() else 2700) >= now})
    return out


# ---- state -----------------------------------------------------------------------

def write_stamp():
    """global/steward.stamp, one line `<seq> <epoch_ms>`, after every save (issue #2835).

    The panels (mod/fleet/hooks/panels.ts) stat this one file every second and
    re-read the books only when it moved; a stamp that cannot be written costs
    them up to their 10 s full read, never the save."""
    p = gdir() / "steward.stamp"
    try:
        seq = int(p.read_text().split()[0]) + 1
    except (OSError, ValueError, IndexError):
        seq = 1
    try:
        tmp = p.with_suffix(".stamp.tmp")
        tmp.write_text("%d %d\n" % (seq, int(time.time() * 1000)))
        os.replace(str(tmp), str(p))
    except OSError:
        pass


class State:
    def __init__(self):
        self.path = gdir() / "steward.state.json"
        self.lockf = open(str(gdir() / "steward.lock"), "a")
        fcntl.flock(self.lockf, fcntl.LOCK_EX)
        try:
            self.d = json.loads(self.path.read_text())
        except (OSError, ValueError):
            self.d = {}
        self.d.setdefault("v", V)
        for k, dflt in (("seq", {}), ("rows", {}), ("drivers", {}), ("deferred", []), ("beat", {}),
                        ("sheet", {}), ("orphans", {}), ("sheets", {})):
            self.d.setdefault(k, dflt)

    def save(self):
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.d, ensure_ascii=False, indent=1, sort_keys=True))
        os.replace(str(tmp), str(self.path))
        write_stamp()

    # every GitHub write goes through here: the beat's budget (共同约定 7)
    def budget_left(self):
        return env_int("FLEET_STEWARD_WRITES", 20) - self.d["beat"].get("writes", 0)

    def spend(self, n=1):
        self.d["beat"]["writes"] = self.d["beat"].get("writes", 0) + n


# ---- the writes ------------------------------------------------------------------

def answer_body(row, text, by, source):
    lines = [tr("steward_answer_fmt" if by == "steward" else "steward_answer_person_fmt", text), "",
             fd.tr("decision_answer_item_fmt", row.get("item", ""), row.get("url", ""))]
    if source:
        lines += ["", tr("steward_answer_source_fmt", source)]
    return "\n".join(lines + ["", "<!-- fleet:answer row=%s by=%s -->" % (row["id"], by)])


def do_answer(st, row, text, by, source):
    """One answer, within the budget: rc 0 posted, 3 deferred to the next beat."""
    if st.budget_left() < 1:
        st.d["deferred"].append({"kind": "answer", "row": row["id"], "text": text, "by": by, "source": source})
        return 3
    repo, n = fd.split_src(row["src"])
    # a followup row (fleet_followup.py) sits on a closed parent: a record, no worker
    fd.post(repo, n, answer_body(row, text, by, source), "note" if row.get("followup") else "to-worker")
    st.spend(1)
    row["state"] = "answered"
    row["by"] = by
    row["closed_at"] = fd.iso(fd.now_local())
    if row.get("followup"):
        fu.answered(st, row, text, by)
    tally(st, by)
    return 0


def tally(st, by):
    """Today's count of closes by who closed them — steward · person · default
    (the patrol panel's 自答 / 默认拍板, issue #2834)."""
    day = time.strftime("%Y-%m-%d")
    c = st.d.setdefault("counts", {}).setdefault(day, {})
    c[by] = c.get(by, 0) + 1


def flush_deferred(st):
    items, st.d["deferred"] = st.d["deferred"], []
    done = 0
    for item in items:
        row = st.d["rows"].get(item.get("row", ""))
        if not row or row.get("state") != "open":
            continue
        # past the budget do_answer defers it again, in order
        if do_answer(st, row, item["text"], item["by"], item.get("source")) == 0:
            done += 1
    return done


# ---- collect ---------------------------------------------------------------------

KEY_RE = re.compile(r"^(?:([A-Za-z0-9._-]+):)?issue-([0-9]+)$")


def issue_of_key(key, slugs):
    m = KEY_RE.match(key or "")
    if not m:
        return None
    repo = slugs.get(m.group(1) or "") or (list(slugs.values())[0] if len(slugs) == 1 and not m.group(1) else None)
    return (repo, m.group(2)) if repo else None


def collect(sess, st, now_t, apply=True):
    delta = {"v": V, "session": sess, "at": fd.iso(now_t), "events": [], "new_asks": [], "closed": [],
             "defaulted": [], "orphans": [], "deferred": 0, "followups": {"new": [], "done": [], "refused": []},
             "samples": []}
    wins = windows(sess)
    slugs = repo_of_slug(sess)
    # 1. the ledgers: the orchestrator, its children that keep one, every driver
    cdir = conf_dir() / "fleets" / sess / "children"
    keys = ["orchestrator"]
    for w in wins:
        if w["epic"] and w["key"]:
            st.d["drivers"][w["epic"]] = w["key"]
            keys.append(w["key"])
    waiting = set()
    seen = set()
    while keys:
        key = keys.pop(0)
        if key in seen:
            continue
        seen.add(key)
        if key != "orchestrator" and not (cdir / (key + ".ndjson")).exists() \
                and os.environ.get("FLEET_STEWARD_CHILDREN_CMD") is None:
            continue
        first = key not in st.d["seq"]
        got = children(sess, key, st.d["seq"].get(key, 0))
        if isinstance(got.get("seq"), int):
            st.d["seq"][key] = got["seq"]
        if not first:
            for e in got.get("events") or []:
                delta["events"].append({"parent": key, "child": e.get("child", ""), "state": e.get("state", ""),
                                        "pr": e.get("pr", ""), "summary": (e.get("summary") or "")[:240]})
        for c in got.get("children") or []:
            if key == "orchestrator" and len(seen) < 40:
                keys.append(c.get("child", ""))
            if c.get("state") == "needs" or c.get("remote_state") == "needs":
                ref = issue_of_key(c.get("child"), slugs)
                if ref:
                    waiting.add(ref)
    # 2. the sessions waiting on a person here, and every row still open
    for w in wins:
        if (w["role"] in ("", "worker")) and w["state"] == "needs" and w["issue"].isdigit() and w["repo"]:
            waiting.add((w["repo"], w["issue"]))
    for row in st.d["rows"].values():
        if row.get("state") == "open" and not row.get("followup"):
            try:
                waiting.add(fd.split_src(row["src"]))
            except ValueError:
                pass
    for repo, n in sorted(waiting):
        try:
            rows = fd.parse_comments(fd.fetch_comments(repo, n), repo, n)
        except (RuntimeError, ValueError, OSError):
            continue
        for row in rows:
            old = st.d["rows"].get(row["id"])
            if old is None:
                if row["state"] == "open":
                    delta["new_asks"].append(row)
                st.d["rows"][row["id"]] = row
            elif old.get("state") == "open" and row["state"] != "open":
                delta["closed"].append({"id": row["id"], "src": row["src"], "state": row["state"]})
                old.update(row)
    # 3. due rows answered by their default, within the budget
    for row in list(st.d["rows"].values()):
        if not apply or not fd.is_due(row, now_t):
            continue
        if st.budget_left() < 2:
            delta["deferred"] += 1
            continue
        try:
            res = fd.apply_due(row)
        except (RuntimeError, ValueError, OSError):
            continue
        if res.get("answered"):
            st.spend(2 if res.get("recorded") else 1)
            row["state"] = "defaulted"
            row["by"] = "default"
            row["closed_at"] = fd.iso(now_t)
            tally(st, "default")
            delta["defaulted"].append({"id": row["id"], "src": row["src"], "default": row.get("default", "")})
        elif res.get("skipped") in ("answered", "defaulted", "gone"):
            row["state"] = res["skipped"] if res["skipped"] != "gone" else "answered"
    # 4. batches whose driver is gone: what the backstop says about their open PRs
    orphans = {}
    marks = epic_marks(int(now_t.timestamp()))
    for m in marks:
        ref = "%s#%s" % (m["repo"], m["epic"])
        if m["fresh"] or any(w["epic"] in (ref, "#" + m["epic"]) for w in wins):
            continue
        drv = st.d["drivers"].get(ref) or st.d["drivers"].get("#" + m["epic"]) or ""
        members = []
        if drv:
            for c in (children(sess, drv, 0).get("children") or []):
                if c.get("pr") and c.get("pr_state") == "OPEN":
                    verdict, why = backstop(c["child"], c["pr"], drv)
                    members.append({"child": c["child"], "pr": c["pr"], "backstop": verdict, "why": why})
        orphans[ref] = {"epic": ref, "driver": drv, "members": members}
    if orphans != st.d["orphans"]:
        delta["orphans"] = list(orphans.values())
    st.d["orphans"] = orphans
    # 5b. what the finished batches leave for a person (issue #2672)
    if apply:
        try:
            fu.beat(sys.modules[__name__], sess, st, int(now_t.timestamp()), delta, wins, marks)
        except Exception as e:      # never the rest of the beat's work
            sys.stderr.write("fleet-steward-tick: followups: %s: %s\n" % (type(e).__name__, e))
        # 5d. one member of each batch that finished, for the sheet (issue #2678)
        try:
            samp.beat(sys.modules[__name__], sess, st, fd.iso(now_t), now_t.strftime("%Y-%m-%d"), delta)
        except Exception as e:      # never the rest of the beat's work
            sys.stderr.write("fleet-steward-tick: samples: %s: %s\n" % (type(e).__name__, e))
    delta["deferred"] += len(st.d["deferred"])
    return delta, wins


def sheet_open(st):
    ids = st.d["sheet"].get("rows") or []
    return [i for i in ids if st.d["rows"].get(i, {}).get("state") == "open"]


def wants_model(delta):
    return bool(delta["new_asks"] or delta["orphans"]
                or any(e["state"] in WAKE_STATES for e in delta["events"]))


def park_moved(delta):
    pk = delta.get("park") or {}
    return bool(pk.get("requested") or pk.get("parked") or pk.get("woken"))


def empty(delta):
    f = delta.get("followups") or {}
    return not (delta["events"] or delta["new_asks"] or delta["closed"] or delta["defaulted"]
                or delta["orphans"] or delta["deferred"] or f.get("new") or f.get("done") or f.get("refused")
                or park_moved(delta)
                or delta.get("health") or delta.get("samples"))


# ---- the card --------------------------------------------------------------------

def card_lines(st, delta, now_t, nxt):
    b = st.d["beat"]
    calm = empty(delta)
    lines = [tr("steward_card_head_fmt", b.get("n", 0), fd.show_time(now_t)[-5:],
                tr("steward_card_calm") if calm else tr("steward_card_changed"))]
    if not calm:
        lines.append(tr("steward_card_asks_fmt", len(delta["new_asks"]), len(delta["closed"]),
                        len(delta["defaulted"])) + " · " + tr("steward_card_sheet_fmt", len(sheet_open(st))))
        if delta["events"]:
            lines.append(tr("steward_card_reports_fmt", len(delta["events"]),
                            sum(1 for e in delta["events"] if e["state"] == "MERGED"),
                            sum(1 for e in delta["events"] if e["state"] in WAKE_STATES)))
        for o in delta["orphans"]:
            lines.append(tr("steward_card_orphan_fmt", o["epic"], len(o["members"])))
        hs = delta.get("health") or []
        if hs or delta.get("health_deferred"):
            lines.append(tr("steward_card_health_fmt", sum(1 for x in hs if x["action"] == "filed"),
                            sum(1 for x in hs if x["action"] == "again"),
                            delta.get("health_deferred", 0)))
            lines += ["  %s  %s" % (x.get("url") or x["action"], x["what"][:120]) for x in hs]
    if delta.get("samples"):
        lines.append(tr("steward_card_samples_fmt", len(delta["samples"])))
    todo_line = fu.card(sys.modules[__name__], st)
    if todo_line:
        lines.append(todo_line)
    pk = delta.get("park")
    if pk and (park_moved(delta) or pk.get("n_parked")):
        lines.append(tr("steward_card_park_fmt", pk.get("n_parked", 0), len(pk.get("parked") or []),
                        len(pk.get("woken") or []), len(pk.get("requested") or [])))
    if delta["deferred"]:
        lines.append(tr("steward_card_deferred_fmt", delta["deferred"]))
    if (st.d.get("page") or {}).get("url"):
        lines.append(page.tr("steward_page_card_fmt", st.d["page"]["url"]))
    lines.append(tr("steward_card_next_fmt", fd.show_time(nxt)[-5:]))
    return lines


def next_beat(now_t, changed):
    if fd._night(now_t):
        gap = env_int("FLEET_STEWARD_NIGHT_EVERY", 3600)
    elif changed:
        gap = env_int("FLEET_STEWARD_AGAIN", 600)
    else:
        gap = env_int("FLEET_STEWARD_EVERY", 1200)
    return now_t + dt.timedelta(seconds=gap)


def write_delta(delta):
    p = gdir() / "steward.delta.json"
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(delta, ensure_ascii=False, indent=1))
    os.replace(str(tmp), str(p))
    return p


# ---- commands --------------------------------------------------------------------

def cmd_beat(a):
    sess = session(a.session)
    if not sess:
        sys.stderr.write("fleet-steward-tick: no fleet session\n")
        return 2
    now_t = fd.now_local(a.now)
    if not a.force:
        # the every-minute caller's fast path: not due ⇒ no lock, no fork — but a
        # park asked for its handoff is moved on every minute (its grace is 5)
        try:
            if now_t.timestamp() < json.loads((gdir() / "steward.state.json").read_text()).get("next_at", 0):
                if fleet_park.peek().get("pending"):
                    park_step(sess, now_t, False, env_int("FLEET_STEWARD_WRITES", 20))
                return 4
        except (OSError, ValueError):
            pass
        m = mode(sess)
        if m != "on":
            # `count`: nothing parked, but the stuck segments are measured (the
            # 卡住占位时长 baseline, EPIC #2668 读数口径), at most every 10 minutes
            if m == "count" and park_on():
                try:
                    fleet_park.observe_only(sess, now_t.timestamp())
                except Exception as e:  # a metric never stops the beat
                    sys.stderr.write("fleet-steward-tick: park observe: %s\n" % e)
            return 3
    # the doctor runs before the lock: an `answer` never waits out its ~20 s
    try:
        peek = json.loads((gdir() / "steward.state.json").read_text()).get("health") or {}
    except (OSError, ValueError):
        peek = {}
    doctor_rows = health.run_doctor() if health.doctor_due(peek, int(now_t.timestamp())) else None
    st = State()
    due = st.d.get("next_at", 0)
    if not a.force and now_t.timestamp() < due:
        return 4
    st.d["beat"] = {"n": st.d["beat"].get("n", 0) + 1, "at": fd.iso(now_t), "writes": 0}
    flushed = flush_deferred(st)
    delta, wins = collect(sess, st, now_t)
    delta["flushed"] = flushed
    pk = park_step(sess, now_t, True, st.budget_left())
    if pk is not None:
        st.spend(pk["writes"])
        st.d["parked"] = pk.pop("list")
        delta["park"] = pk
        stamp_decide(sess, pk["n_parked"], wins, "@orch_park")
    hf, ha, hd, delta["health"] = health.check(st, sess, socket(sess), repo_of_slug(sess), now_t, doctor_rows, tr)
    delta["deferred"] += hd
    delta["health_deferred"] = hd
    path = write_delta(delta)
    changed = not empty(delta)
    nxt = next_beat(now_t, changed)
    st.d["next_at"] = int(nxt.timestamp())
    st.d["beat"]["changed"] = changed
    n_open = len(sheet_open(st))
    st.d["decide"] = n_open
    stamp_decide(sess, n_open, wins)
    page_step(sess, st, now_t, wins)
    st.d["card"] = card_lines(st, delta, now_t, nxt)
    if delta.get("samples"):
        # a finished batch's sample reaches the person on this beat, no model turn
        post_sheet(sess, st, now_t)
    calls = st.d.setdefault("model_calls", 0)
    if wants_model(delta):
        parts = tr("steward_wake_parts_fmt", len(delta["new_asks"]),
                   sum(1 for e in delta["events"] if e["state"] in WAKE_STATES), len(delta["orphans"]))
        text = tr("steward_wake_fmt", st.d["beat"]["n"], parts, str(path))
        if send(sess, "steward", text):
            st.d["model_calls"] = calls + 1
    st.save()
    print("\n".join(st.d["card"]))
    return 0 if changed else 1


def cmd_delta(a):
    sess = session(a.session)
    st = State()
    delta, _ = collect(sess, st, fd.now_local(a.now), apply=False)
    print(json.dumps(delta, ensure_ascii=False, indent=1))
    return 0


def cmd_answer(a):
    st = State()
    row = st.d["rows"].get(a.row)
    if not row:
        sys.stderr.write("fleet-steward-tick: no row %s (run a beat first)\n" % a.row)
        return 1
    if row.get("state") != "open":
        print("already %s" % row.get("state"))
        return 0
    if a.by == "steward" and row.get("followup"):
        sys.stderr.write("fleet-steward-tick: %s is a followup row — only a person answers it\n" % a.row)
        return 1
    if a.by == "steward" and fd.never(row):
        sys.stderr.write("fleet-steward-tick: %s is never-default (%s) — it goes on the sheet\n"
                         % (a.row, row.get("kind")))
        return 1
    rc = do_answer(st, row, a.text, a.by, a.source)
    if rc == 0:
        st.d["decide"] = len(sheet_open(st))
        wins = windows(session(a.session))
        stamp_decide(session(a.session), st.d["decide"], wins)
        page_step(session(a.session), st, fd.now_local(), wins)
    st.save()
    print("answered %s" % a.row if rc == 0 else tr("steward_card_deferred_fmt", 1))
    return rc


def cmd_say(a):
    """The steward session's plain line for a row — what the page and the
    orchestrator's lines say instead of the worker's own words (issue #2735)."""
    st = State()
    row = st.d["rows"].get(a.row)
    if not row:
        sys.stderr.write("fleet-steward-tick: no row %s (run a beat first)\n" % a.row)
        return 1
    row["say"] = " ".join(a.text.split())[:120]
    url = page_step(session(a.session), st, fd.now_local(a.now), windows(session(a.session)))
    st.save()
    print(page.tr("steward_page_card_fmt", url or "—"))
    return 0


def cmd_page(a):
    """Today's steward page: render + host it now (--print: the HTML on stdout,
    --demo: the fixed sample rows, nothing kept)."""
    now_t = fd.now_local(a.now)
    if a.demo:
        print(page.render(page.demo_state(now_t), session(a.session), now_t))
        return 0
    st = State()
    if a.print:
        print(page.render(st, session(a.session), now_t))
        return 0
    url = page_step(session(a.session), st, now_t, windows(session(a.session)), force=a.force)
    st.save()
    print(url or str(conf_dir() / "fleets" / session(a.session) / "steward" / "page.html"))
    return 0


def page_step(sess, st, now_t, wins, force=False):
    """Render + host today's steward page (bin/fleet_steward_page.py) and stamp its
    link as @orch_page on the orchestrator when it changed → the URL ("" none)."""
    try:
        url = page.refresh(sess, st, now_t, force)
    except Exception as e:  # the page never stops a beat or an answer
        sys.stderr.write("fleet-steward-tick: page: %s\n" % e)
        return ""
    if url and url != st.d["page"].get("stamped"):
        stamp_decide(sess, url, wins, "@orch_page")
        st.d["page"]["stamped"] = url
    return url


def cmd_sheet(a):
    st = State()
    rc, msg = post_sheet(session(a.session), st, fd.now_local(a.now), a.force)
    st.save()
    print(msg)
    return rc


def post_sheet(sess, st, now_t, force=False):
    """Render, keep and hand over the sheet → (rc, what to print). The caller
    holds the state lock and saves. A sample not shown yet (issue #2678) is new
    content like a new row; the day's samples ride every sheet of that day."""
    rows = [r for r in st.d["rows"].values() if r.get("state") == "open"]
    rows.sort(key=lambda r: (not fd.never(r), r.get("due") or "9", r.get("asked") or ""))
    ids = [r["id"] for r in rows]
    day = now_t.strftime("%Y-%m-%d")
    samples = samp.for_sheet(st, day) if st.d.get("samples") else []
    if not ids and not samples:
        st.d["sheet"] = {"rows": [], "at": fd.iso(now_t)}
        st.d["decide"] = 0
        stamp_decide(sess, 0, windows(sess))
        return 1, tr("steward_sheet_empty")
    if set(ids) <= set(st.d["sheet"].get("rows") or []) and not force \
            and not any(not x.get("shown") for x in samples):
        return 0, tr("steward_sheet_same_fmt", len(sheet_open(st)))
    sid = str(uuid.uuid4())
    table = fd.render(rows, sid, samples)
    title = tr("steward_sheet_title_fmt", day)
    path = conf_dir() / "fleets" / sess / "steward"
    path.mkdir(parents=True, exist_ok=True)
    f = path / ("decision-%s.md" % day)
    with open(str(f), "a", encoding="utf-8") as fh:
        fh.write("## %s · %s\n\n%s\n\n" % (title, fd.show_time(now_t), table))
    where = str(f)
    desk = os.environ.get("FLEET_STEWARD_DESK") or fd._conf_val("FLEET_STEWARD_DESK") or ""
    if desk and (BIN / "fleet-ticket.sh").exists():
        if st.budget_left() >= 1:
            r = subprocess.run(["bash", str(BIN / "fleet-ticket.sh"), "comment", desk, "--body-file", "-"],
                               input="## %s\n\n%s" % (title, table), stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, universal_newlines=True, timeout=60)
            st.spend(1)
            if r.returncode == 0:
                where = desk
        else:
            st.d["deferred_sheet"] = True
    url = page_step(sess, st, now_t, windows(sess))
    lines = page.brief([r for r in rows if not r.get("followup")], now_t)
    todo_rows = [r for r in rows if r.get("followup")]
    body = ["%s　〔row %s〕" % (text, ",".join(ids)) for text, ids in lines]
    body += ["%s　〔row %s〕" % (page.tr("steward_page_todo_h") + " · " + page.say_of(r), r["id"]) for r in todo_rows]
    if samples:
        body += [""] + fd.render_samples(samples)
    msg = "\n".join([tr("steward_decision_head_fmt", len(rows), where),
                     page.tr("steward_page_card_fmt", url or str(conf_dir() / "fleets" / sess / "steward" / "page.html")),
                     ""] + body + ["", tr("steward_decision_how"), "", "<!-- fleet:decision v=%s id=%s -->" % (fd.V, sid)])
    sent = send(sess, "orchestrator", msg)
    st.d["sheet"] = {"id": sid, "rows": ids, "at": fd.iso(now_t), "where": where, "sent": sent}
    st.d["sheets"][day] = st.d["sheets"].get(day, 0) + 1
    st.d["decide"] = len(ids)
    if sent:
        samp.shown(st, samples, sid)
    stamp_decide(sess, len(ids), windows(sess))
    if any(fd.never(r) for r in rows) and os.environ.get("FLEET_NOTIFY_CMD"):
        subprocess.run([os.environ["FLEET_NOTIFY_CMD"], tr("steward_notify_never_fmt", len(rows))],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    return 0, (tr("steward_sheet_sent_fmt", len(ids), where) if sent else msg)


def cmd_followups(a):
    """The 「待你动手」 list; --watch adds an EPIC the steward never met (a batch
    that ended before it ran) — its followups are read on the next beat."""
    st = State()
    now = int(time.time())
    for ref in a.watch or []:
        r = fu.ref_of(ref)
        if not r:
            sys.stderr.write("fleet-steward-tick: %s is not owner/name#N\n" % ref)
            st.save()
            return 2
        fu.watch(st, r, now)
    if a.watch:
        st.save()
    t = st.d.get("todo") or {}
    if a.json:
        print(json.dumps(t, ensure_ascii=False, indent=1))
    elif t.get("items"):
        print(fu.render(sys.modules[__name__], t))
    else:
        print(tr("steward_todo_none"))
    return 0


def cmd_card(a):
    st = State()
    print("\n".join(st.d.get("card") or [tr("steward_card_none")]))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="fleet-steward-tick.sh")
    sub = ap.add_subparsers(dest="cmd")
    for name in ("beat", "delta", "sheet", "card", "page"):
        p = sub.add_parser(name)
        p.add_argument("--session")
        p.add_argument("--now")
        p.add_argument("--force", action="store_true")
        if name == "page":
            p.add_argument("--print", action="store_true")
            p.add_argument("--demo", action="store_true")
    p = sub.add_parser("say")
    p.add_argument("--row", required=True)
    p.add_argument("--text", required=True)
    p.add_argument("--session")
    p.add_argument("--now")
    p = sub.add_parser("answer")
    p.add_argument("--row", required=True)
    p.add_argument("--text", required=True)
    p.add_argument("--source")
    p.add_argument("--by", choices=("steward", "person"), default="steward")
    p.add_argument("--session")
    p = sub.add_parser("followups")
    p.add_argument("--watch", action="append")
    p.add_argument("--json", action="store_true")
    p.add_argument("--session")
    a = ap.parse_args(argv)
    fn = {"beat": cmd_beat, "delta": cmd_delta, "answer": cmd_answer, "sheet": cmd_sheet, "card": cmd_card,
          "followups": cmd_followups, "page": cmd_page, "say": cmd_say}.get(a.cmd)
    if not fn:
        ap.print_help(sys.stderr)
        return 2
    return fn(a)


if __name__ == "__main__":
    sys.exit(main())
