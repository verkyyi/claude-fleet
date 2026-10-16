#!/usr/bin/env python3
"""Task-authoritative collaboration over the existing task API and relay outbox.

A source result, delivery and native process observation remain separate. No
GitHub reader, background poller, replacement launch or local task store.
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

import fleet_launch as launch

BIN = Path(__file__).resolve().parent


def call(action, task, payload=None, timeout=15):
    env = dict(os.environ, FLEET_HUB_TIMEOUT=str(max(1, min(10, int(timeout)))))
    result = subprocess.run(["bash", str(BIN / "fleet-task-record.sh"), action, task],
                            input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True, timeout=timeout, env=env)
    if result.returncode:
        raise ValueError("task authority unavailable/refused")
    return json.loads(result.stdout)


def verdict(task):
    if task is None:
        return "UNKNOWN"
    outcome = task.get("outcome")
    return outcome.upper() if outcome in ("succeeded", "failed", "cancelled", "refused") else "WAITING"


def wait_task(task, timeout, interval):
    end = time.monotonic() + timeout
    while True:
        left = end - time.monotonic()
        try:
            record = call("get", task, timeout=max(0.1, min(15, left))).get("task")
            if not record or record.get("authority_version") != 1:
                raise ValueError("task is not authoritative")
        except (ValueError, OSError, subprocess.SubprocessError):
            print("UNKNOWN\ntask: %s\nnote: task authority unavailable; no replacement authorized" % task)
            return 3
        state = verdict(record)
        if state != "WAITING" or time.monotonic() >= end:
            print("%s\ntask: %s\ngeneration: %s\nworker_id: %s" %
                  (state, task, record["generation"], record.get("execution_owner", "")))
            return {"SUCCEEDED": 0, "FAILED": 1, "CANCELLED": 2, "REFUSED": 2}.get(state, 3)
        time.sleep(min(interval, max(0, end - time.monotonic())))


def children(task, as_json):
    record = call("get", task)["task"]
    if record.get("authority_version") != 1:
        return 4  # explicit compatibility result; never an unavailable fallback
    data = call("children", task)
    if as_json:
        print(json.dumps(data, ensure_ascii=False))
    else:
        print("children of %s · generation %s" % (task, data["parent_generation"]))
        for child in data["children"]:
            print("%s g%s %s %s %s" % (child["id"], child["generation"], verdict(child),
                  child.get("ticket_ref", ""), child.get("execution_owner", "")))
        print("%d children" % len(data["children"]))
    return 0


def context(pane, socket=""):
    c = launch.validate_context(json.loads(launch.option(pane, "@launch", socket)))
    if launch.option(pane, "@fleet_id", socket) != c["worker_id"].split("/")[1]:
        raise ValueError("launch binding does not belong to this session")
    return c


def report_input(c, t, outcome, summary, evidence, stopped=False, event=""):
    r = dict(task=c["task"], owner=c["owner"], generation=c["generation"], worker_id=c["worker_id"],
             ticket_ref=t.get("ticket_ref", ""), parent_task=t.get("parent_task", ""),
             parent_session=t.get("parent_session", ""), parent_generation=t.get("parent_generation", 0),
             outcome=outcome, summary=summary, evidence=evidence, execution_stopped=stopped)
    r["event_id"] = event or hashlib.sha256(json.dumps(r, sort_keys=True).encode()).hexdigest()
    return r


def publish_report(r):
    receipt = call("report", r["task"], r)
    if receipt["disposition"] != "committed":
        print("%s\ntask: %s\nevent_id: %s" % (receipt["disposition"].upper(), r["task"], r["event_id"]))
        return 3
    if not r["parent_session"]:
        print("COMMITTED\ntask: %s\nevent_id: %s" % (r["task"], r["event_id"]))
        return 0
    if r["parent_task"]:
        parent = call("get", r["parent_task"])["task"]
        if not parent_matches(r, parent):
            orphan(r, "parent generation retired; result remains on task")
            return 0
    # Existing outbox, including same-machine parents: one durable address and
    # one event ID across reconnects, never a timestamp allocated on each retry.
    suffix = hashlib.sha256((r["task"] + ":" + r["event_id"]).encode()).hexdigest()
    payload = dict(task_report=r, child=r["task"], state=r["outcome"].upper(), tier="quiet",
                   msg="[child-report] %s\nstate: %s · generation %s\nsummary: %s\nno reply needed" %
                   (r["task"], r["outcome"].upper(), r["generation"], r["summary"]))
    command = '. "$1/fleet-lib.sh"; fleet_hub_put child_report "$2" "$3" "$4" "$(cat)"'
    sent = subprocess.run(["bash", "-c", command, "task-report", str(BIN), r["worker_id"],
                           r["parent_session"], suffix], input=json.dumps(payload), text=True,
                          capture_output=True, timeout=15)
    if sent.returncode:
        raise ValueError("result committed; delivery unavailable (retry the same event)")
    print("QUEUED\ntask: %s\nevent_id: %s\nparent: %s" % (r["task"], r["event_id"], r["parent_session"]))
    return 3


def report(pane, state, summary, pr, dry, socket=""):
    c = context(pane, socket)
    t = call("get", c["task"])["task"]
    if any(t.get(k) != c[v] for k, v in (("owner", "owner"), ("generation", "generation"), ("execution_owner", "worker_id"))):
        raise ValueError("stale report owner/generation")
    if state != "merged":
        # failed may describe a red CI gate while work continues. A Stop means
        # one native turn ended. Neither is an explicit terminal task result.
        print("%s\ntask: %s\nnote: workflow %s; task outcome is %s" %
              (verdict(t), c["task"], state, t.get("outcome") or "not committed"))
        return 3 if not t.get("outcome") else 0
    # Keep the existing code-landing gate. Work outcome and code landing can be
    # reported independently using `fleet-task-record.sh report` with a result.
    if pr:
        gate = subprocess.run(["bash", str(BIN / "fleet-pr-verdict.sh"), pr], capture_output=True, text=True, timeout=20)
        if gate.stdout.strip() != "MERGED":
            raise ValueError("PR merge is unconfirmed; task result not recorded")
    receipt = launch.check_receipt(c, json.loads(launch.option(pane, "@launch_receipt", socket)))
    evidence = json.dumps(dict(native_session=receipt["native_session"], provider=receipt["actual_provider"],
                               work_result="succeeded", pr=pr), sort_keys=True)
    r = report_input(c, t, "succeeded", summary, evidence)
    if dry:
        print(json.dumps(r)); return 0
    saved = call("report", c["task"], r)
    if saved["disposition"] == "historical":
        print("HISTORICAL\ntask: %s" % c["task"]); return 0
    # Intent survives a resumed native conversation in this same window. It is
    # not a task DB or retry queue; the hub journal already owns the result.
    launch.tmux("set-option", "-w", "-t", pane, "@task_report", json.dumps(r), socket=socket)
    print("PENDING\ntask: %s\nevent_id: %s\nnote: work reported; awaiting confirmed native stop" % (c["task"], r["event_id"]))
    return 3


def finalize(pane):
    c = context(pane)
    t = call("get", c["task"])["task"]
    if any(t.get(k) != c[v] for k, v in (("owner", "owner"), ("generation", "generation"), ("execution_owner", "worker_id"))):
        raise ValueError("stale finalization generation")
    raw = launch.option(pane, "@task_report")
    pending = json.loads(raw) if raw else call("pending-report", c["task"]).get("report")
    if not pending and not t.get("cancel_request"):
        return 0  # Exit alone never invents a result.
    proof = launch.check_receipt(c, json.loads(launch.option(pane, "@launch_receipt")))
    # A failed process probe is unknown. Only ESRCH or a positively observed
    # different birth/executable proves the witnessed native is gone.
    try:
        os.kill(proof["pid"], 0)
    except ProcessLookupError:
        pass
    else:
        observed = launch.process(proof["pid"])
        if all(observed[k] == proof[k] for k in ("pid", "birth", "executable")):
            raise ValueError("native execution is still alive")
    if not pending:
        result = call("mutate", c["task"], dict(kind="cancel_ack", idempotency_key=t["cancel_request"] + ".ack",
                      generation=c["generation"], expected_worker=c["worker_id"], cancel_request=t["cancel_request"],
                      execution_stopped=True, evidence=json.dumps({k: proof[k] for k in ("pid", "birth", "executable", "native_session")})))
        print("%s\ntask: %s" % (verdict(result), c["task"]))
        return 0
    r = pending
    if any(r.get(k) != c[v] for k, v in (("task", "task"), ("owner", "owner"), ("generation", "generation"), ("worker_id", "worker_id"))):
        raise ValueError("pending result belongs to an old generation")
    r["event_id"] += ".stopped"
    r["execution_stopped"] = True
    r["evidence"] = json.dumps(dict(work=r["evidence"], stopped_native={k: proof[k] for k in
                                 ("pid", "birth", "executable", "native_session")}), sort_keys=True)
    return publish_report(r)


def cancel(task, event):
    t = call("get", task)["task"]
    result = call("mutate", task, dict(kind="cancel_request", idempotency_key=event,
                  generation=t["generation"], expected_worker=t["execution_owner"], evidence="explicit cancel request"))
    print("CANCEL_REQUESTED\ntask: %s\nevent_id: %s\nnote: owner retained until stopped acknowledgement" % (task, result["cancel_request"]))
    return 3


def parent_matches(report, parent):
    return (parent.get("id") == report["parent_task"] and parent.get("owner") == report["owner"]
            and parent.get("generation") == report["parent_generation"]
            and parent.get("execution_owner") == report["parent_session"] and not parent.get("outcome"))


def orphan(r, why):
    root = Path(os.environ.get("FLEET_CONF_DIR", str(Path.home() / ".config/claude-fleet")))
    path = root / "global/orphan-reports.ndjson"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.seek(0)
        rows = [json.loads(line) for line in stream if line.strip()]
        if not any(row.get("event_id") == r["event_id"] and row.get("task") == r["task"] for row in rows):
            row = dict(ts=int(time.time()), child_key=r["task"] + ":g" + str(r["generation"]), task=r["task"],
                       event_id=r["event_id"], state=r["outcome"].upper(), summary=r["summary"],
                       parent=r["parent_session"], reason=why)
            stream.write(json.dumps(row) + "\n")
    print("orphaned → task %s event %s: %s" % (r["task"], r["event_id"], why))


def receive(file):
    envelope = json.loads(Path(file).read_text())
    r = envelope["payload"]["task_report"]
    if envelope["from"] != r["worker_id"] or envelope["to"] != r["parent_session"]:
        raise ValueError("relay task identity mismatch")
    t = call("get", r["task"])["task"]
    if (t["owner"], t["generation"], t["execution_owner"], t.get("outcome")) != (r["owner"], r["generation"], r["worker_id"], r["outcome"]):
        print("historical child generation; no delivery"); return 0
    if r["parent_task"]:
        parent = call("get", r["parent_task"])["task"]
        if not parent_matches(r, parent):
            orphan(r, "parent generation retired"); return 0
    # The one resolver, and only the stable worker ID. No issue/name fallback.
    cmd = '. "$1/fleet-lib.sh"; home=$(fleet_wid_home "wid:$2") || exit 75; sock=$(fleet_socket "$home"); win=$(fleet_win_for_fid "${2#*/}" "$sock") || exit 75; dir=$(children_dir "$home"); printf "%s\n%s\n%s\n" "$sock" "$win" "$dir"'
    cmd = cmd.replace('home=$(fleet_wid_home', 'task_home=$(fleet_wid_home').replace('"$home"', '"$task_home"')
    cmd = cmd.replace('. "$1/fleet-lib.sh";', '. "$1/fleet-lib.sh"; . "$1/fleet-children-lib.sh";')
    located = subprocess.run(["bash", "-c", cmd, "task-receive", str(BIN), r["parent_session"]],
                             capture_output=True, text=True, timeout=10)
    if located.returncode:
        return 75
    socket, pane, directory = located.stdout.strip().splitlines()
    if r["parent_generation"]:
        c = context(pane, socket)
        if (c["task"], c["generation"], c["worker_id"]) != (r["parent_task"], r["parent_generation"], r["parent_session"]):
            orphan(r, "parent window belongs to another generation"); return 0
        native = launch.inspect(c, pane, socket)
    else:
        native = None
    # Existing child ledger directory; task + generation is the file's identity.
    path = Path(directory) / ((r["parent_task"] or r["parent_session"].split("/")[1]) + "-g%d.ndjson" % r["parent_generation"])
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
        if sentfile.exists() and envelope["id"] in sentfile.read_text().splitlines():
            print("already delivered"); return 0
        msg = "[child-report] %s\nstate: %s · generation %s\nsummary: %s\nno reply needed" % (r["task"], r["outcome"].upper(), r["generation"], r["summary"])
        if native:
            # No sleeper/peer queue can outlive this generation check. An
            # unavailable inbox leaves the same relay pending on the hub.
            if native["actual_provider"] == "codex":
                argv = [sys.executable, str(BIN / "fleet-codex-session.py"), "send", "--pane", pane, "--socket", socket]
            else:
                argv = ["bash", "-c", '. "$1/fleet-lib.sh"; fleet_peer_send "$2" "$(cat)" fleet-report', "task", str(BIN), str(native["pid"])]
        else:
            argv = ["bash", "-c", '. "$1/fleet-lib.sh"; . "$1/fleet-children-lib.sh"; children_send "" "$2" "$3" "$(cat)"', "task", str(BIN), socket, pane]
        delivered = subprocess.run(argv, input=msg, capture_output=True, text=True, timeout=20)
        if delivered.returncode:
            return 75
        with sentfile.open("a") as stream:
            stream.write(envelope["id"] + "\n")
    print("reported task %s event %s" % (r["task"], r["event_id"]))
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("action", choices=("children", "await", "report", "finalize", "cancel", "receive"))
    p.add_argument("--task", default="")
    p.add_argument("--file", default="")
    p.add_argument("--pane", default=os.environ.get("TMUX_PANE", ""))
    p.add_argument("--socket", default="")
    p.add_argument("--json", action="store_true")
    p.add_argument("--timeout", type=int, default=60)
    p.add_argument("--interval", type=int, default=5)
    p.add_argument("--state", default="waiting")
    p.add_argument("--summary", default="")
    p.add_argument("--pr", default="")
    p.add_argument("--event", default="")
    p.add_argument("--dry", action="store_true")
    args = p.parse_args()
    try:
        if args.action == "children": return children(args.task, args.json)
        if args.action == "await": return wait_task(args.task, max(1, args.timeout), max(1, args.interval))
        if args.action == "report": return report(args.pane, args.state, args.summary, args.pr, args.dry, args.socket)
        if args.action == "finalize": return finalize(args.pane)
        if args.action == "receive": return receive(args.file)
        if args.action == "cancel":
            if not args.event: raise ValueError("cancel needs a stable --event")
            return cancel(args.task, args.event)
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as e:
        print("UNKNOWN\nnote: %s" % e)
        return 75 if args.action == "receive" else 3


if __name__ == "__main__":
    sys.exit(main())
