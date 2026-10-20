#!/usr/bin/env python3
"""A hub task record, read from a machine — and a child report routed to its parent.

The record is the ticket (issue #4897); the session is its window's ID (EPIC T497
C8): nothing here claims a record, holds it, fences a report on a generation or
proves a native process. A session's report is a result of its ID
(fleet-report-parent.sh, fleet_id.py); this reads whether a record is over, waits
on it, lists its children, writes an EPIC driver's progress word on its ID, cancels
a record no window ever opened, and delivers a child report a relay carried here.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

BIN = Path(__file__).resolve().parent
TERMINAL = ("succeeded", "failed", "cancelled", "refused")


def call(action, task, payload=None, timeout=15):
    env = dict(os.environ, FLEET_HUB_TIMEOUT=str(max(1, min(10, int(timeout)))))
    result = subprocess.run(["bash", str(BIN / "fleet-task-record.sh"), action, task],
                            input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True, timeout=timeout, env=env)
    if result.returncode:
        raise ValueError(result.stderr.strip() or "task record unavailable/refused")
    return json.loads(result.stdout)


def verdict(task):
    if task is None:
        return "UNKNOWN"
    outcome = task.get("outcome")
    return outcome.upper() if outcome in TERMINAL else "WAITING"


def record(task, timeout=15):
    t = call("get", task, timeout=timeout).get("task")
    if not isinstance(t, dict) or t.get("authority_version") != 1:
        raise ValueError("task record is not authoritative")
    return t


def wait_task(task, timeout, interval):
    end = time.monotonic() + timeout
    while True:
        left = end - time.monotonic()
        try:
            t = record(task, timeout=max(0.1, min(15, left)))
        except (ValueError, OSError, subprocess.SubprocessError):
            print("UNKNOWN\ntask: %s\nnote: task record unavailable" % task)
            return 3
        state = verdict(t)
        if state != "WAITING" or time.monotonic() >= end:
            print("%s\ntask: %s" % (state, task))
            return {"SUCCEEDED": 0, "FAILED": 1, "CANCELLED": 2, "REFUSED": 2}.get(state, 3)
        time.sleep(min(interval, max(0, end - time.monotonic())))


def closed(task):
    """Is the task record closed (收口, issue #4897)? ONE read, never a wait:
    SUCCEEDED / FAILED / CANCELLED / REFUSED → exit 0; WAITING (still open) →
    exit 1; the hub unreadable or the record not authoritative → UNKNOWN, exit 3. The reapers
    (fleet-cleanup-idle.py, fleet-cleanup.sh, worktree-autoclean.sh) read a task
    session's end here — never its PR or an issue."""
    try:
        t = record(task, timeout=10)
    except (ValueError, OSError, subprocess.SubprocessError):
        print("UNKNOWN\ntask: %s" % task)
        return 3
    state = verdict(t)
    print("%s\ntask: %s" % (state, task))
    return 1 if state == "WAITING" else 0


def child_summary(data):
    """One count per outcome (issue #4957): the hub's `summary` when it sends one,
    else counted here off the children — "open" while a child has no outcome."""
    s = data.get("summary")
    if isinstance(s, dict):
        return s
    s = dict(open=0, succeeded=0, failed=0, cancelled=0, refused=0)
    for child in data.get("children") or []:
        o = child.get("outcome") or ""
        s[o if o in s and o else "open"] += 1
    return s


def children(task, as_json):
    data = call("children", task)
    data["summary"] = child_summary(data)
    if as_json:
        print(json.dumps(data, ensure_ascii=False))
        return 0
    print("children of %s" % task)
    for child in data.get("children") or []:
        print("%s %s %s %s" % (child["id"], verdict(child), child.get("ticket_ref", ""), child.get("title", "")))
    sm = data["summary"]
    print("%d children · open %d · succeeded %d · failed %d · cancelled %d · refused %d" % (
        len(data.get("children") or []), sm.get("open", 0), sm.get("succeeded", 0), sm.get("failed", 0),
        sm.get("cancelled", 0), sm.get("refused", 0)))
    return 0


def option(pane, key, socket=""):
    sock = ["-S" if os.path.isabs(socket) else "-L", socket] if socket else []
    return subprocess.run(["tmux", *sock, "display-message", "-p", "-t", pane, "#{" + key + "}"],
                          capture_output=True, text=True, timeout=5).stdout.strip()


def progress(pane, summary, state, event="", socket=""):
    """The session's own progress word (issue #4957): an EPIC driver's tick. It is
    the window's ID's (EPIC T497 C12): one `progress` event on its ledger, pushed
    to the hub mirror — `fleet-epic-tick.py status` reads its last_tick there.
    Never relayed: a tick is not a child report."""
    if not summary.strip():
        raise ValueError("progress needs a --summary")
    import fleet_id
    fid = option(pane, "@fleet_id", socket) if pane else ""
    if not fleet_id.is_fid(fid):
        raise ValueError("this pane carries no ID (@fleet_id)")
    ev = fleet_id.record_progress(fid, summary.strip(), state, event)
    if ev:
        fleet_id.push_later(fid)
    print("RECORDED\nid: %s\nevent_id: %s" % (fid, event or (ev or {}).get("seq", "-")))
    return 0


def cancel(task, event):
    """A person's cancel of a record no window ever opened (EPIC T497 C13): the
    one change the hub still takes on a record. A record an ID carries is that
    window's — the hub answers so, and the session is closed there."""
    t = record(task)
    if t.get("outcome"):
        print("%s\ntask: %s" % (verdict(t), task))
        return 0
    call("mutate", task, dict(kind="transition", idempotency_key=event, generation=t.get("generation", 1),
                              expected_worker="", state="cancelled",
                              evidence="explicit cancel request; no window ever opened it"))
    print("CANCELLED\ntask: %s\nnote: no window opened it; nothing to stop" % task)
    return 2


def orphan(r, why):
    root = Path(os.environ.get("FLEET_CONF_DIR", str(Path.home() / ".config/claude-fleet")))
    path = root / "global/orphan-reports.ndjson"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.seek(0)
        rows = [json.loads(line) for line in stream if line.strip()]
        if not any(row.get("event_id") == r["event_id"] and row.get("task") == r["task"] for row in rows):
            row = dict(ts=int(time.time()), child_key=r["task"], task=r["task"],
                       event_id=r["event_id"], state=(r["outcome"].upper() or "WAITING"), summary=r["summary"],
                       parent=r["parent_session"], reason=why)
            stream.write(json.dumps(row) + "\n")
    print("orphaned → task %s event %s: %s" % (r["task"], r["event_id"], why))


def child_label(r):
    """A child named by its ID first (EPIC T497 C11): `#K3F9 (别名 T486)` — the worker_id's
    second half is its ID; the record's T<n> only an alias note (one version). No ID ⇒ T<n>."""
    fid = str(r.get("worker_id") or "").rpartition("/")[2]
    try:
        sys.path.insert(0, str(BIN))
        import fleet_id
        if fleet_id.is_fid(fid):
            short = fleet_id.fold(fleet_id.read(fid))["opened"].get("short") \
                or fleet_id.short_for(fid, fleet_id.known_ids([fid]))
            return "#%s (别名 %s)" % (short, r["task"]) if r.get("task") else "#" + short
    except Exception:
        pass
    finally:
        sys.path.pop(0)
    return r["task"]


def receive(file):
    """A child report a relay carried here (a session that reported before EPIC
    T497 C8 still has one queued on the hub). The parent by its ID (design §4.3):
    the window carrying it, whatever native session it runs now; one that has
    closed hands the report to its successor (down the prev chain), else up its
    parent (fleet_id_take); nobody ⇒ the person's reminder."""
    envelope = json.loads(Path(file).read_text())
    r = envelope["payload"]["task_report"]
    if envelope["from"] != r["worker_id"] or envelope["to"] != r["parent_session"]:
        raise ValueError("relay task identity mismatch")
    r.setdefault("outcome", "")
    r.setdefault("summary", "")
    cmd = r''' . "$1/fleet-lib.sh"; . "$1/fleet-children-lib.sh"
task_home=$(fleet_wid_home "wid:$2") || exit 75
sock=$(fleet_socket "$task_home")
tmux -L "$sock" has-session -t "=$task_home" 2>/dev/null || exit 75
win=$(fleet_win_for_fid "${2#*/}" "$sock"); task_rc=$?
how=self
if [ "$task_rc" = 1 ]; then
  take=$(fleet_id_take "${2#*/}"); trc=$?
  [ "$trc" = 2 ] && exit 76
  [ "$trc" = 0 ] || exit 77
  IFS=$'\t' read -r _id how sock win <<< "$take"
  task_rc=0
fi
[ "$task_rc" = 0 ] || exit 75
dir=$(children_dir "$task_home") || exit 75
printf "%s\n%s\n%s\n%s\n" "$sock" "$win" "$dir" "$how"
'''
    located = subprocess.run(["bash", "-c", cmd, "task-receive", str(BIN), r["parent_session"]],
                             capture_output=True, text=True, timeout=20)
    if located.returncode == 76:
        orphan(r, "parent session retired on its known fleet"); return 0
    if located.returncode == 77:
        orphan(r, "parent ID closed, with no successor or parent open"); return 0
    if located.returncode:
        return 75
    socket, pane, directory, how = located.stdout.strip().splitlines()
    # The child ledger directory; the parent task (else its ID) names the file,
    # as the report's producer named it.
    path = Path(directory) / ((r.get("parent_task") or r["parent_session"].split("/")[1])
                              + "-g%d.ndjson" % int(r.get("parent_generation") or 0))
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        entries = []
        if path.exists():
            entries = [json.loads(line) for line in path.read_text().splitlines() if line]
        if not any(e.get("event_id") == r["event_id"] and e.get("task") == r["task"] for e in entries):
            with path.open("a") as stream:
                stream.write(json.dumps(dict(r, rid=envelope["id"])) + "\n")
        sentfile = Path(directory) / ".relay-sent"
        sent_key = "task-report:" + hashlib.sha256((r["task"] + ":" + r["event_id"]).encode()).hexdigest()
        if sentfile.exists() and sent_key in sentfile.read_text().splitlines():
            print("already delivered"); return 0
        msg = "[child-report] %s\nstate: %s%s\nsummary: %s\nno reply needed" % (
            child_label(r), (r["outcome"].upper() or "WAITING"),
            "" if how == "self" else " · 原 parent 已关闭，代收 (%s)" % how, r["summary"])
        argv = ["bash", "-c", '. "$1/fleet-lib.sh"; . "$1/fleet-children-lib.sh"; children_send "" "$2" "$3" "$(cat)"',
                "task", str(BIN), socket, pane]
        delivered = subprocess.run(argv, input=msg, capture_output=True, text=True, timeout=20)
        if delivered.returncode:
            return 75
        with sentfile.open("a") as stream:
            stream.write(sent_key + "\n")
    print("reported task %s event %s" % (r["task"], r["event_id"]))
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__)
    # report / finalize: compat-1v: 下一批删 — an older caller (a pre-C8 launch
    # supervisor finalizing on exit, an older fleet-report-parent.sh).
    p.add_argument("action", choices=("children", "await", "closed", "progress", "cancel", "receive",
                                      "report", "finalize"))
    p.add_argument("--task", default="")
    p.add_argument("--file", default="")
    p.add_argument("--pane", default=os.environ.get("TMUX_PANE", ""))
    p.add_argument("--socket", default="")
    p.add_argument("--json", action="store_true")
    p.add_argument("--timeout", type=int, default=60)
    p.add_argument("--interval", type=int, default=5)
    p.add_argument("--state", default="waiting")
    p.add_argument("--summary", default="")
    p.add_argument("--outcome", choices=("succeeded", "failed"), default="")
    p.add_argument("--pr", default="")
    p.add_argument("--event", default="")
    p.add_argument("--dry", action="store_true")
    args = p.parse_args()
    try:
        if args.action == "closed": return closed(args.task)
        if args.action == "children": return children(args.task, args.json)
        if args.action == "await": return wait_task(args.task, max(1, args.timeout), max(1, args.interval))
        if args.action == "progress": return progress(args.pane, args.summary, args.state, args.event, args.socket)
        if args.action == "receive": return receive(args.file)
        if args.action == "finalize": return 0
        if args.action == "report":
            print("ID_SWITCH\nnote: a report is a result of the window's ID (fleet-report-parent.sh)")
            return 5
        if args.action == "cancel":
            if not args.event: raise ValueError("cancel needs a stable --event")
            return cancel(args.task, args.event)
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as e:
        print("UNKNOWN\nnote: %s" % e)
        return 75 if args.action == "receive" else 3


if __name__ == "__main__":
    sys.exit(main())
