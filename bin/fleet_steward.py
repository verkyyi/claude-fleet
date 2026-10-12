#!/usr/bin/env python3
"""fleet_steward.py — the steward's beat, with no model (issue #2670, EPIC #2668
C2). Run as bin/fleet-steward-tick.sh — since EPIC #3111 C4 (issue #3115) only
from the loop of the session that took the steward role (/fleet-steward, the
fleet-steward plugin's skill; take_role steward).

    fleet-steward-tick.sh beat --holder [--session S] [--force] [--now ISO]
    fleet-steward-tick.sh delta  [--session S] [--now ISO]
    fleet-steward-tick.sh answer --row ID --text T [--source URL] [--by steward|person] [--session S]
    fleet-steward-tick.sh sheet  [--session S] [--now ISO]
    fleet-steward-tick.sh card   [--session S]
    fleet-steward-tick.sh followups [--watch owner/name#N …] [--json]
    fleet-steward-tick.sh breakage [--session S]

NOBODY HOLDS THE ROLE ⇒ NOTHING RUNS (EPIC #3111 C4): no beat, no answer at a
deadline, no spawn, no merge, no park, no health issue, no sheet and no
[decision] — a question waits on its session's row and its ticket for the person.
`beat` without --holder refuses (rc 3) and so does `--holder` from a window that
is not the holder's (fleet_role_holder, bin/fleet-lib.sh — fleet_decision.
steward_holder is its Python door; seam FLEET_STEWARD_HOLDER_CMD).

`breakage` spawns the fixer of a red base branch a WORKER filed (issue #2960: a
worker files, never spawns): fleet-issue-file.sh queues it under the fleet's
state dir (`breakage-spawn/`) and drains at once; the holder's beat drains the
rest. Parent: the steward holder. No holder ⇒ the person is told once
(`fleet-alerts.sh event breakage`) and the issue stays queued, nobody spawned.

`beat --holder` is the holder's loop's (its skill runs it every round): it returns
at once (rc 4, 「还没到下一拍」) until the next beat is due — FLEET_STEWARD_EVERY
(1200 s), 600 s after a beat
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
     gone (its mark stale), so the model never merges under a busy worker; a
     stale mark whose driver window is still HERE (issue #2958) is a row too —
     `dialog-<fp>` while it waits on its person (the open choice dialog's
     question + options off its transcript, answered from the sheet through
     bin/fleet_dialog_answer.py, the option marked (Recommended) its default),
     `stalled-…` + the page's 「没在走」 line when it waits on no one a TTL past
     the stale mark; either closes by itself once its cause is gone;
  4b. watches the fleet's own health (bin/fleet_steward_health.py, issue #2674):
     a doctor row newly WARN / FAIL, or idle sessions nothing has slept or
     reaped for two hours, files ONE issue per fingerprint — within the budget;
  5. writes global/steward.delta.json + global/steward.state.json, stamps
     @orch_decide on the orchestrator's window (the open rows of the last sheet —
     fleet-control-read.sh carries it to the client's 「新任务」 row), and
  5b. gathers what finished batches leave for a person into ONE 「待你动手」 list
     and runs what it may (bin/fleet_followup.py, issue #2672 — its header is
     the spec): @orch_todo carries the open count to the client's list,
     @orch_todo_list the open items themselves (list_cell, issue #2913);
  5d. draws ONE member of each batch that finished (bin/fleet_sample.py, issue
     #2678 — its header is the spec) and, when it drew one, posts the sheet on
     this beat with the sample in its read-only area (no model turn);
  5c. moves the parks on (bin/fleet_park.py, issue #2671 C3): a stuck session is
     asked for its handoff, parked once it wrote one (or its grace ran out), and
     woken on the same conversation when what it waits for arrives — within the
     same write budget; @orch_park carries the count to the client's 「停放 N」,
     @orch_park_list who is parked and on what (list_cell, issue #2913).
     FLEET_STEWARD_PARK=0 leaves parking off. A pending park is advanced on every
     minute's call, due or not (its grace is 5 minutes, the beat 10-60);
  6. ONLY when there is something for the model — a new open question, a BLOCKED /
     FAILED report, a batch with no driver — ends its card with the `[steward] …`
     line, printed to the holder's own loop (never sent: it is already in turn).

`todo-done --id <id>` ticks one 「待你动手」 item as the person's (issue #2913: the
client's list, through the steward) — the next beat records it on its batches
and redraws the desk ticket with the box ticked, as a tick on the ticket does.

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
FLEET_STEWARD_BACKSTOP_CMD (argv + key --pr N --parent P), FLEET_STEWARD_DIALOG_CMD
(argv run instead of fleet_dialog_answer.py), FLEET_DIALOG_PROJECTS (the
transcripts' root), FLEET_STEWARD_STAMP_CMD
(argv + N: the decide count), FLEET_STEWARD_DEBUG_CMD (argv + feed --json: the
debug reports' feed, issue #2893; FLEET_STEWARD_DEBUG=0 skips it), and
fleet_decision.py's own three.
"""
import argparse
import base64
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path

import fleet_decision as fd
import fleet_ticket
import fleet_needs_detail as nd
import fleet_followup as fu
import fleet_park
import fleet_sample as samp
import fleet_steward_health as health
import fleet_steward_say as page

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
            out = subprocess.run(["sh", str(BIN / "fleet-ui-lang.sh"), "dump", "steward_", "panel_sheet_"],
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


def holder(sess):
    """The window holding the steward role — '' when nobody does (EPIC #3111 C4):
    then nothing is answered, spawned, merged, parked, filed or written."""
    return fd.steward_holder(socket(sess))


def own_window():
    """The window this process runs in ('' outside a pane)."""
    pane = os.environ.get("TMUX_PANE") or ""
    if not pane or not os.environ.get("TMUX"):
        return ""
    r = subprocess.run(["tmux", "display-message", "-p", "-t", pane, "#{window_id}"], stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, universal_newlines=True, timeout=10)
    return r.stdout.strip()


def _seam(name, argv, **kw):
    cmd = os.environ.get(name)
    if not cmd:
        return None
    return subprocess.run(cmd.split() + argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True, timeout=120, **kw)


def windows(sess):
    """[{wid, role, state, issue, repo, epic, key, sheet, needs, sid, name}] of this
    fleet's windows (`sheet`: the window's @sheet_pane — 1 while the mod's decision
    sheet is up; `needs` / `sid` / `name`: what a driver waits on, its conversation
    and its name, for a batch whose heartbeat stopped — issue #2958)."""
    r = _seam("FLEET_STEWARD_WINDOWS_CMD", [sess])
    if r is None:
        fmt = "\t".join(("#{window_id}", "#{@fleet_role}",
                         "#{?@worker_lifecycle,#{@worker_lifecycle},#{@claude_state}}",
                         "#{@issue}", "#{@repo}", "#{@epic}", "", "#{@sheet_pane}",
                         "#{@claude_needs}", "#{@cc_session_id}", "#{window_name}", "#{@fleet_role_def}"))
        r = subprocess.run(["tmux", "-L", socket(sess), "list-windows", "-t", "=" + sess, "-F", fmt],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True, timeout=30)
    out = []
    for line in (r.stdout or "").splitlines():
        p = (line.split("\t") + [""] * 12)[:12]
        w = dict(zip(("wid", "role", "state", "issue", "repo", "epic", "key", "sheet", "needs", "sid", "name"), p))
        if p[11] in ("orchestrator", "steward"):
            w["role"] = p[11]          # a role taken with take_role (issue #3114) is the window's role here
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


# The parked / 待你动手 lists (issue #2913): what is parked, on what, since when,
# and the open 待你动手 items — at most LIST_MAX, each string clipped, as compact
# JSON in base64url without padding (one [-A-Za-z0-9_] token in a tmux option).
# No reader past the window since the inventory's columns 31-37 went (issue #3118).
LIST_MAX = 12


def list_cell(payload):
    if not payload or not payload.get("i"):
        return ""
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    return base64.urlsafe_b64encode(raw.encode("utf-8")).decode("ascii").rstrip("=")


def park_cell(lst):
    """park_step's list → the @orch_park_list cell: ref, key, wait, since."""
    return list_cell({"i": [{"r": e.get("ref", "")[:80], "k": (e.get("key") or "")[:40],
                             "w": " ".join(e.get("wait") or [])[:80], "a": int(e.get("at") or 0)}
                            for e in (lst or [])[:LIST_MAX]]})


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


def tell_person(text, sess=None):
    """One reminder to the person (the alerts' one exit, `fleet-alerts.sh event
    breakage`). Seam: FLEET_STEWARD_ALERT_CMD (argv + kind + text)."""
    cmd = os.environ.get("FLEET_STEWARD_ALERT_CMD")
    argv = cmd.split() if cmd else ["bash", str(BIN / "fleet-alerts.sh")]
    sock = socket(sess) if sess and not cmd else ""
    try:
        subprocess.run(argv + ["event"] + (["-L", sock] if sock else []) + ["breakage", text],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    except (OSError, subprocess.SubprocessError):
        pass


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
        ttl = int(ttl) if ttl.isdigit() else 2700
        out.append({"epic": kv["epic"], "repo": kv.get("repo", "-"), "epoch": int(ep), "ttl": ttl,
                    "fresh": int(ep) + ttl >= now})
    return out


# ---- state -----------------------------------------------------------------------

def write_stamp():
    """global/steward.stamp, one line `<seq> <epoch_ms>`, after every save (issue #2835).

    The panels (plugins/fleet-steward/hooks/panels.ts) stat this one file every second and
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


def panel_groups(d, now_t=None):
    """What the decision sheet's panel draws (issue #2832): the rows asked today
    and the rows of the last sheet, through fleet_decision.group — the panel never
    merges on its own. The person's todo rows (followups) are the batches panel's."""
    day = (now_t or fd.now_local()).date()
    on_sheet = set(d.get("sheet", {}).get("rows") or [])
    rows = []
    for rid, r in d.get("rows", {}).items():
        if r.get("followup"):
            continue
        try:
            today = fd.parse_time(r.get("asked") or "").date() == day
        except (TypeError, ValueError):
            today = False
        if rid in on_sheet or today or r.get("state") == "open":
            rows.append(r)
    return fd.group(rows)


def reap_overdue():
    """Sessions past their reap policy and still open (issue #3352), off the one
    reader bin/fleet-reap-overdue.py: {n, stuck, top} — top is the longest-stuck
    one's line. A reader that cannot run leaves {} (the panel says nothing)."""
    try:
        out = subprocess.run(["python3", str(Path(__file__).resolve().parent / "fleet-reap-overdue.py"), "--json"],
                             capture_output=True, text=True, timeout=60).stdout
        d = json.loads(out)
    except (OSError, ValueError, subprocess.SubprocessError):
        return {}
    rows = d.get("rows") or []
    top = ""
    if rows:
        r = rows[0]
        top = "%s · %s · %dm · %s" % (r.get("key") or r.get("window"), r.get("why_due", ""),
                                       int(r.get("over", 0)) // 60, r.get("reason", ""))
    return {"n": int(d.get("overdue", 0)), "stuck": int(d.get("stuck", 0)), "top": top}


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
        self.d["groups"] = panel_groups(self.d)
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
    row["answer"] = text
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


# ---- a driver that is here but not moving (issue #2958) --------------------------

def dialog_of(w):
    """The open choice dialog in a window's conversation (fleet_needs_detail's
    read, the one the answer channel checks against), or None."""
    root = os.environ.get("FLEET_DIALOG_PROJECTS") or str(Path.home() / ".claude" / "projects")
    if not w.get("sid"):
        return None
    for f in sorted(Path(root).glob("*/%s.jsonl" % w["sid"])):
        d = nd.pending_dialog(str(f))
        if d is not None:
            d["fp"] = nd.dialog_fp(d)
        return d
    return None


RECOMMENDED_RE = re.compile(r"[(（]\s*(?:recommended|推荐|建议)\s*[)）]", re.I)


def stuck_driver_row(m, ref, w, now_t):
    """The decision row for a batch whose heartbeat is stale while its driver's
    window is still here: it waits on its person (a choice dialog: the question,
    its options, where to answer — the option marked (Recommended) is the
    suggestion and, past the usual deadline, the default) — or, a TTL past the
    stale mark, it is simply not moving. None while neither."""
    epic = "#" + m["epic"]
    where = w.get("name") or w["wid"]
    asked = fd.iso(now_t)
    base = {"asked": asked, "src": fleet_ticket.tid(*ref.rsplit("#", 1)) if "#" in ref else "gh:" + ref,
            "url": "", "state": "open", "epic": ref, "wid": w["wid"], "window": where, "v": str(fd.V)}
    if w["state"] == "needs":
        d = dialog_of(w) if w.get("needs") == "ask" else None
        if d is not None:
            qs = d["questions"]
            q = " / ".join(x["question"] for x in qs)
            opts = " / ".join("、".join(x["options"]) for x in qs)
            rec = [o for o in qs[0]["options"] if RECOMMENDED_RE.search(o)] if len(qs) == 1 else []
            row = dict(base, id="dialog-" + d["fp"], local="dialog", kind=fd.classify(None, q),
                       item=tr("steward_dialog_item_fmt", epic, q, opts, where),
                       say=tr("steward_dialog_say_fmt", epic, q), suggest=rec[0] if rec else "",
                       default=rec[0] if rec else "", due=fd.iso(fd.due_at(now_t)) if rec else "",
                       fp=d["fp"], question=q, options=[x["options"] for x in qs],
                       multi=[x["multiSelect"] for x in qs])
            return row
        # waiting on something that is no choice dialog (a permission, a declared
        # blocker): the person goes to the window; nothing to answer from here
        q = w.get("needs") or "needs"
        return dict(base, id="dialog-" + hashlib.sha1(("%s|%s|%s" % (ref, w["wid"], q)).encode()).hexdigest()[:16],
                    local="dialog", kind="normal", item=tr("steward_dialog_item_fmt", epic, q, "—", where),
                    say=tr("steward_dialog_say_fmt", epic, q), suggest="", default="", due="")
    late = int(now_t.timestamp()) - (m["epoch"] + m["ttl"])
    if late <= m["ttl"]:
        return None
    mins = (int(now_t.timestamp()) - m["epoch"]) // 60
    return dict(base, id="stalled-" + hashlib.sha1(("%s|%s" % (ref, m["epoch"])).encode()).hexdigest()[:16],
                local="stalled", kind="normal", mins=mins, item=tr("steward_stalled_item_fmt", epic, mins, where),
                say=tr("steward_stalled_item_fmt", epic, mins, where), suggest="", default="", due="")


def close_local(st, row, state, by, answer, now_t, delta):
    row["state"] = state
    row["by"] = by
    row["answer"] = answer
    row["closed_at"] = fd.iso(now_t)
    delta["closed"].append({"id": row["id"], "src": row["src"], "state": state})


def dialog_answer(sess, row, picks, by, basis):
    """Press `picks` (labels) into the dialog the row names, through the one
    guarded road (bin/fleet_dialog_answer.py) → (rc, its words)."""
    argv = (os.environ["FLEET_STEWARD_DIALOG_CMD"].split() if os.environ.get("FLEET_STEWARD_DIALOG_CMD")
            else ["python3", str(BIN / "fleet_dialog_answer.py")])
    argv += [row["wid"], "--fp", row["fp"], "--by", by, "--basis", basis, "--session", sess]
    if row.get("epic"):
        argv += ["--issue", row["epic"]]
    for p in picks:
        argv += ["--pick", p]
    r = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=180)
    return r.returncode, (r.stdout.strip() or r.stderr.strip())


def dialog_picks(row, text):
    """The person's / the steward's answer text → one `[N=]label` per pick: the
    questions split on ` | `, a multiSelect's labels on ` + `."""
    parts = [p.strip() for p in text.split(" | ")] if len(row.get("options") or []) > 1 else [text.strip()]
    multi, picks = row.get("multi") or [], []
    for qi, part in enumerate(parts, 1):
        labels = [x.strip() for x in part.split(" + ")] if qi <= len(multi) and multi[qi - 1] else [part]
        picks += [label if len(parts) == 1 else "%d=%s" % (qi, label) for label in labels]
    return picks


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
        if row.get("state") == "open" and not row.get("followup") and not row.get("local"):
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
        if row.get("local"):
            if row.get("local") == "dialog" and st.budget_left() >= 1:
                rc, _ = dialog_answer(sess, row, [fd.row_default(row)], "default", tr("steward_dialog_basis_default"))
                st.spend(1)
                if rc == 0:
                    close_local(st, row, "defaulted", "default", fd.row_default(row), now_t, delta)
                    tally(st, "default")
                    delta["defaulted"].append({"id": row["id"], "src": row["src"], "default": row.get("default", "")})
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
    live = set()
    for m in marks:
        ref = "%s#%s" % (m["repo"], m["epic"])
        if m["fresh"]:
            continue
        drv_w = [w for w in wins if w["epic"] in (ref, "#" + m["epic"])]
        if drv_w:
            # the driver's window is here but its heartbeat stopped (issue #2958):
            # it waits on its person, or it is not moving — either way a row
            row = stuck_driver_row(m, ref, drv_w[0], now_t)
            if row is not None:
                live.add(row["id"])
                if row["id"] not in st.d["rows"]:
                    st.d["rows"][row["id"]] = row
                    delta["new_asks"].append(row)
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
    # a stuck-driver row whose cause went away (answered, moving again, gone) closes
    for row in list(st.d["rows"].values()):
        if row.get("local") and row.get("state") == "open" and row["id"] not in live:
            close_local(st, row, "answered" if row["local"] == "dialog" else "gone", "", "", now_t, delta)
    st.d["stalled"] = {r["src"]: {"epic": r["epic"], "mins": r["mins"], "window": r["window"], "wid": r["wid"]}
                       for r in st.d["rows"].values()
                       if r.get("local") == "stalled" and r.get("state") == "open"}
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

def debug_step(sess, now_s):
    """The hub's debug reports (issue #2893, EPIC #2889 C4): what changed since
    the last read, one line each, to the orchestrator — 「〔诊断〕谁 · 是什么问题 ·
    短链接」, and what the debugger asks us to change, for the person to nod at.
    Every minute at most; a login the hub has no feed for (it answers only
    CCQUOTA_FLEET_DEBUG_NOTIFY's) or no hub at all asks again in an hour. No
    orchestrator window here ⇒ nothing is read, so nothing is lost."""
    stp = gdir() / "debug-feed.step"
    try:
        if now_s < int(stp.read_text().strip() or 0):
            return 0
    except (OSError, ValueError):
        pass
    if not any(w["role"] == "orchestrator" for w in windows(sess)):
        return 0
    r = _seam("FLEET_STEWARD_DEBUG_CMD", ["feed", "--json"])
    if r is None:
        r = subprocess.run([sys.executable, str(BIN / "fleet-debug-desk.py"), "feed", "--json"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True, timeout=60)
    wait = {0: 60, 1: 300}.get(r.returncode, 3600)
    try:
        stp.parent.mkdir(parents=True, exist_ok=True)
        stp.write_text("%d\n" % (now_s + wait))
    except OSError:
        pass
    if r.returncode != 0:
        return 0
    try:
        lines = json.loads(r.stdout or "{}").get("lines") or []
    except ValueError:
        return 0
    for ln in lines:
        send(sess, "orchestrator", ln)
    return len(lines)


def breakage_dir(sess):
    return conf_dir() / "fleets" / sess / "breakage-spawn"


def cmd_breakage(a):
    sess = session(a.session)
    if not sess:
        sys.stderr.write("fleet-steward-tick: no fleet session\n")
        return 2
    return drain_breakage(sess)


def drain_breakage(sess, quiet=False):
    """A red base branch a WORKER filed (issue #2960): a worker files, never spawns,
    so its fixer is spawned here — one level deep, parented to the steward holder.
    fleet-issue-file.sh queues `<slug>-<N>` (repo · number · title · agent) under the
    fleet's state dir and drains at once; the holder's beat drains the rest. NOBODY
    holds the steward role (EPIC #3111 C4) ⇒ nothing is spawned: the issue is filed,
    the person is told once (`fleet-alerts.sh event breakage`), and it stays
    queued for whoever takes the role. Spawned or already claimed ⇒ off the queue;
    no room ⇒ the next beat; a day old ⇒ dropped (logged)."""
    q = breakage_dir(sess)
    items = sorted(f for f in q.glob("*") if not f.name.startswith(".")) if q.is_dir() else []
    if not items:
        return 0
    lk = open(q / ".lock", "a")
    try:
        fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0                     # another drain holds it
    log = gdir() / "breakage-spawn.log"
    if not holder(sess):
        for f in items:
            if (q / (".told-" + f.name)).exists():
                continue
            try:
                repo, n = (f.read_text().rstrip("\n").split("\t") + [""] * 2)[:2]
            except OSError:
                continue
            tell_person(tr("steward_breakage_unheld_fmt", "%s#%s" % (repo, n)), sess)
            (q / (".told-" + f.name)).write_text(fd.iso(fd.now_local(None)) + "\n")
            line = "%s\t%s\t%s#%s\tno-holder\ttold" % (fd.iso(fd.now_local(None)), sess, repo, n)
            if not quiet:
                print(line)
            try:
                with open(log, "a") as fh:
                    fh.write(line + "\n")
            except OSError:
                pass
        return 0
    origin = "steward"
    env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE")}
    for f in items:
        try:
            repo, n, title, agent = (f.read_text().rstrip("\n").split("\t") + [""] * 4)[:4]
        except OSError:
            continue
        if not n.isdigit() or "/" not in repo:
            f.unlink()
            continue
        o = origin                  # rc 4 = the holder went meanwhile: kept for the next one
        argv = [n, sess, "--repo", repo, "--origin", o] + (["--title", title] if title else []) \
            + (["--agent", agent] if agent in ("claude", "codex") else [])
        r = _seam("FLEET_STEWARD_SPAWN_CMD", argv, env=env)
        if r is None:
            r = subprocess.run(["bash", str(BIN / "dash-issue-session.sh")] + argv, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, universal_newlines=True, timeout=300, env=env)
        rc = r.returncode
        old = time.time() - f.stat().st_mtime > 86400
        if rc in (0, 3) or old:
            f.unlink()
            try:
                (q / (".told-" + f.name)).unlink()
            except OSError:
                pass
        line = "%s\t%s\t%s#%s\torigin=%s\trc=%d%s" % (fd.iso(fd.now_local(None)), sess, repo, n, o, rc,
                                                     "\tdropped" if old and rc not in (0, 3) else "")
        if not quiet:
            print(line)
        try:
            with open(log, "a") as fh:
                fh.write(line + "\n")
        except OSError:
            pass
    return 0


def holder_gate(sess, quiet=False):
    """(holder window, rc): rc 0 = go; 3 = nobody holds the steward role, or this
    pane is not the one that does (a beat runs only in the holder's own loop)."""
    hw = holder(sess)
    if not hw:
        if not quiet:
            sys.stderr.write("fleet-steward-tick: nobody holds the steward role (/fleet-steward takes it) — nothing runs\n")
        return "", 3
    me = "" if os.environ.get("FLEET_STEWARD_HOLDER_CMD") is not None else own_window()
    if me and me != hw:
        if not quiet:
            sys.stderr.write("fleet-steward-tick: the steward role is %s's, not this window's (%s)\n" % (hw, me))
        return hw, 3
    return hw, 0


def cmd_beat(a):
    sess = session(a.session)
    if not sess:
        sys.stderr.write("fleet-steward-tick: no fleet session\n")
        return 2
    if not a.holder:
        # EPIC #3111 C4: the beat is the steward holder's loop's, never a daemon's
        sys.stderr.write("fleet-steward-tick: the beat runs only in the steward holder's loop "
                         "(`beat --holder`, /fleet-steward) — nothing ran\n")
        return 3
    hw, rc = holder_gate(sess)
    if rc:
        return rc
    now_t = fd.now_local(a.now)
    # a red base a worker filed waits for a holder (issue #2960): its fixer is spawned here
    try:
        drain_breakage(sess, quiet=True)
    except Exception as e:  # a spawn never stops the beat
        sys.stderr.write("fleet-steward-tick: breakage: %s\n" % e)
    if os.environ.get("FLEET_STEWARD_DEBUG", "1") != "0":
        try:
            debug_step(sess, int(now_t.timestamp()))
        except Exception as e:  # the feed never stops the beat
            sys.stderr.write("fleet-steward-tick: debug feed: %s\n" % e)
    if not a.force:
        # the every-minute caller's fast path: not due ⇒ no lock, no fork — but a
        # park asked for its handoff is moved on every minute (its grace is 5)
        try:
            nxt0 = json.loads((gdir() / "steward.state.json").read_text()).get("next_at", 0)
            if now_t.timestamp() < nxt0:
                if fleet_park.peek().get("pending"):
                    park_step(sess, now_t, False, env_int("FLEET_STEWARD_WRITES", 20))
                print(tr("steward_beat_not_due_fmt", fd.show_time(dt.datetime.fromtimestamp(nxt0, now_t.tzinfo))))
                return 4
        except (OSError, ValueError):
            pass
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
        stamp_decide(sess, park_cell(st.d["parked"]), wins, "@orch_park_list")
    hf, ha, hd, delta["health"] = health.check(st, sess, socket(sess), repo_of_slug(sess), now_t, doctor_rows, tr)
    st.d["reap_overdue"] = reap_overdue()
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
    st.d["card"] = card_lines(st, delta, now_t, nxt)
    if delta.get("samples"):
        # a finished batch's sample reaches the person on this beat, no model turn
        post_sheet(sess, st, now_t)
    calls = st.d.setdefault("model_calls", 0)
    wake = ""
    if wants_model(delta):
        parts = tr("steward_wake_parts_fmt", len(delta["new_asks"]),
                   sum(1 for e in delta["events"] if e["state"] in WAKE_STATES), len(delta["orphans"]))
        # the holder's own loop runs this beat: the turn is printed to it, never sent
        wake = tr("steward_wake_fmt", st.d["beat"]["n"], parts, str(path))
        st.d["model_calls"] = calls + 1
    st.save()
    print("\n".join(st.d["card"] + ([""] + [wake] if wake else [])))
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
    if row.get("local") == "stalled" or (row.get("local") == "dialog" and not row.get("fp")):
        sys.stderr.write("fleet-steward-tick: %s is answered in its window (%s), not from here\n"
                         % (a.row, row.get("window")))
        return 1
    if row.get("local") == "dialog":
        # a choice dialog in the driver's own window (issue #2958): pressed in
        # through the one guarded road, which leaves the trail itself
        basis = a.source or (tr("steward_dialog_basis_person") if a.by == "person" else "")
        rc, words = dialog_answer(session(a.session), row, dialog_picks(row, a.text), a.by, basis)
        if rc != 0:
            sys.stderr.write("fleet-steward-tick: %s\n" % words)
            st.save()
            return rc
        close_local(st, row, "answered", a.by, a.text, fd.now_local(), {"closed": []})
        tally(st, a.by)
        wins = windows(session(a.session))
        st.d["decide"] = len(sheet_open(st))
        stamp_decide(session(a.session), st.d["decide"], wins)
        st.save()
        print("answered %s" % a.row)
        return 0
    rc = do_answer(st, row, a.text, a.by, a.source)
    if rc == 0:
        log_answer(session(a.session), st, row, a.text, a.by, fd.now_local(getattr(a, "now", None)))
        st.d["decide"] = len(sheet_open(st))
        wins = windows(session(a.session))
        stamp_decide(session(a.session), st.d["decide"], wins)
    st.save()
    print("answered %s" % a.row if rc == 0 else tr("steward_card_deferred_fmt", 1))
    return rc


def log_answer(sess, st, row, text, by, now_t):
    """One line in today's decision-<day>.md for an answer (issue #2832): which
    thing on the last sheet, as suggested or overturned, by whom. A merged group
    is answered id by id: its line is written once, with the answer that closes
    its last open row."""
    sheet = [st.d["rows"][i] for i in (st.d["sheet"].get("rows") or []) if i in st.d["rows"]]
    groups = fd.group([dict(r, state="open") for r in sheet])
    n, mates = next(((k, g["ids"]) for k, g in enumerate(groups, 1) if row["id"] in g["ids"]), ("?", []))
    if any(st.d["rows"].get(i, {}).get("state") == "open" for i in mates if i != row["id"]):
        return
    hm = now_t.strftime("%H:%M")
    line = "- " + (tr("steward_answer_log_take_fmt", hm, n, by) if text.strip() == (row.get("suggest") or "").strip()
            else tr("steward_answer_log_turn_fmt", hm, n, " ".join(text.split()), by))
    f = conf_dir() / "fleets" / sess / "steward" / ("decision-%s.md" % now_t.strftime("%Y-%m-%d"))
    try:
        f.parent.mkdir(parents=True, exist_ok=True)
        with open(str(f), "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError as e:  # the record never stops the answer
        sys.stderr.write("fleet-steward-tick: decision log: %s\n" % e)


def cmd_say(a):
    """The steward session's plain line for a row — what the orchestrator's
    lines say instead of the worker's own words (issue #2735)."""
    st = State()
    row = st.d["rows"].get(a.row)
    if not row:
        sys.stderr.write("fleet-steward-tick: no row %s (run a beat first)\n" % a.row)
        return 1
    row["say"] = " ".join(a.text.split())[:120]
    st.save()
    print(page.say_of(row))
    return 0


def cmd_sheet(a):
    sess = session(a.session)
    if not holder(sess):
        # EPIC #3111 C4: nobody holds the role ⇒ no sheet written, no [decision] sent
        print(tr("steward_unheld"))
        return 3
    st = State()
    rc, msg = post_sheet(sess, st, fd.now_local(a.now), a.force)
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
    lines = page.brief([r for r in rows if not r.get("followup")], now_t)
    todo_rows = [r for r in rows if r.get("followup")]
    body = ["%s　〔row %s〕" % (text, ",".join(ids)) for text, ids in lines]
    body += ["%s　〔row %s〕" % (page.tr("steward_page_todo_h") + " · " + page.say_of(r), r["id"]) for r in todo_rows]
    if samples:
        body += [""] + fd.render_samples(samples)
    # the decision sheet is on the steward holder's screen (@sheet_pane 1, issue
    # #2832; the fleet-steward plugin's panel since #3115): one sentence to the
    # orchestrator, never the table; else the whole sheet as before
    pane_up = any(w["role"] == "steward" and w.get("sheet") == "1" for w in windows(sess))
    msg = "\n".join([tr("steward_decision_head_fmt", len(rows), where),
                     ""] + body + ["", tr("steward_decision_how"), "", "<!-- fleet:decision v=%s id=%s -->" % (fd.V, sid)])
    if pane_up:
        prev = set(st.d["sheet"].get("rows") or [])
        groups = fd.group(rows)
        new = sum(1 for g in groups if set(g["ids"]) - prev) or len(groups)
        msg = "\n".join([tr("panel_sheet_ping_fmt", new, where),
                         "<!-- fleet:decision v=%s id=%s -->" % (fd.V, sid)])
    sent = send(sess, "orchestrator", msg)
    if sent and not pane_up:
        st.d.setdefault("sheets_full", {})[day] = st.d.setdefault("sheets_full", {}).get(day, 0) + 1
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


def cmd_todo_done(a):
    """One 「待你动手」 item ticked by the person (issue #2913) — the client's list
    sends it through the steward; the next beat writes it back and redraws the
    desk ticket. rc 0 ticked (or already closed), 1 no such item."""
    st = State()
    t = fu.todo(st)
    item = t["items"].get(a.id)
    if not item:
        sys.stderr.write("fleet-steward-tick: no todo item %s\n" % a.id)
        return 1
    if item["state"] in fu.CLOSED:
        print("already %s" % item["state"])
        return 0
    fu.finish(st, item, "person", int(time.time()), {"followups": {"done": []}})
    sess = session(a.session)
    fu.stamp(sys.modules[__name__], sess, st, windows(sess))
    st.save()
    print("ticked %s" % a.id)
    return 0


def cmd_card(a):
    st = State()
    print("\n".join(st.d.get("card") or [tr("steward_card_none")]))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="fleet-steward-tick.sh")
    sub = ap.add_subparsers(dest="cmd")
    for name in ("beat", "delta", "sheet", "card"):
        p = sub.add_parser(name)
        p.add_argument("--session")
        p.add_argument("--now")
        p.add_argument("--force", action="store_true")
        if name == "beat":
            p.add_argument("--holder", action="store_true")
    p = sub.add_parser("breakage")
    p.add_argument("--session")
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
    p = sub.add_parser("todo-done")
    p.add_argument("--id", required=True)
    p.add_argument("--session")
    p = sub.add_parser("followups")
    p.add_argument("--watch", action="append")
    p.add_argument("--json", action="store_true")
    p.add_argument("--session")
    a = ap.parse_args(argv)
    fn = {"beat": cmd_beat, "delta": cmd_delta, "answer": cmd_answer, "sheet": cmd_sheet, "card": cmd_card,
          "followups": cmd_followups, "say": cmd_say,
          "todo-done": cmd_todo_done, "breakage": cmd_breakage}.get(a.cmd)
    if not fn:
        ap.print_help(sys.stderr)
        return 2
    return fn(a)


if __name__ == "__main__":
    sys.exit(main())
