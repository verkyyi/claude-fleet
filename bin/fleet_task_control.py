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


def call(action, task, payload=None, timeout=15, stale=False):
    env = dict(os.environ, FLEET_HUB_TIMEOUT=str(max(1, min(10, int(timeout)))))
    if stale:
        env["FLEET_TASK_STALE_READ"] = "1"
    result = subprocess.run(["bash", str(BIN / "fleet-task-record.sh"), action, task],
                            input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True, timeout=timeout, env=env)
    if result.returncode:
        raise ValueError(result.stderr.strip() or "task authority unavailable/refused")
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
            try:
                from fleet_task_recovery import Journal
                cached = Journal().cached(task)
                print("stale: true\nobserved_at: %s" % cached["observed_at"])
            except (ValueError, OSError, subprocess.SubprocessError):
                pass
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
    result = deliver_report(r, receipt)
    if receipt.get("_recovery_event"):
        from fleet_task_recovery import Journal
        Journal().ack_report(r["task"], r, receipt.get("_delivery_file", ""))
    return result


def deliver_report(r, receipt):
    if receipt.get("_recovery_done"):
        print("COMMITTED\ntask: %s\nevent_id: %s" % (r["task"], r["event_id"]))
        return 0
    if receipt.get("_delivery_file"):
        from fleet_task_recovery import Journal
        if Journal().delivery_pending(receipt["_recovery_event"]):
            print("QUEUED\ntask: %s\nevent_id: %s" % (r["task"], r["event_id"]))
            return 3
    if receipt["disposition"] not in ("committed", "progress"):
        raise ValueError("report disposition %s; reconciliation required" % receipt["disposition"])
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
    payload = dict(task_report={k: v for k, v in r.items() if k != "_native"}, child=r["task"], state=(r["outcome"].upper() or "WAITING"), tier="quiet",
                   msg="[child-report] %s\nstate: %s · generation %s\nsummary: %s\nno reply needed" %
                   (r["task"], (r["outcome"].upper() or "WAITING"), r["generation"], r["summary"]))
    if receipt.get("_recovery_event"):
        payload.update(task_recovery=receipt["_recovery_event"], expires_at=receipt["_recovery_expires"])
    if receipt.get("_recovery_event"):
        from fleet_task_recovery import Journal
        receipt["_delivery_file"] = Journal().put_report(r, payload)
    else:
        command = '. "$1/fleet-lib.sh"; fleet_hub_put child_report "$2" "$3" "$4" "$(cat)"'
        sent = subprocess.run(["bash", "-c", command, "task-report", str(BIN), r["worker_id"],
                               r["parent_session"], suffix], input=json.dumps(payload), text=True,
                              capture_output=True, timeout=15)
        if sent.returncode:
            raise ValueError("result committed; delivery unavailable (retry the same event)")
    print("QUEUED\ntask: %s\nevent_id: %s\nparent: %s" % (r["task"], r["event_id"], r["parent_session"]))
    return 3


def report(pane, state, summary, pr, dry, socket="", outcome=""):
    c = context(pane, socket)
    observation = call("get", c["task"], stale=True)
    t = observation["task"]
    if observation.get("stale"):
        print("STALE task observation at %s; receipt requires reconciliation" % observation["observed_at"], file=sys.stderr)
    if any(t.get(k) != c[v] for k, v in (("owner", "owner"), ("generation", "generation"), ("execution_owner", "worker_id"))):
        raise ValueError("stale report owner/generation")
    if state != "merged" and not outcome:
        # A red CI gate or a completed turn is workflow progress, never a
        # terminal result. Still notify the exact parent with a fenced event.
        if t.get("outcome"):
            print("%s\ntask: %s" % (verdict(t), c["task"])); return 0
        r = report_input(c, t, "", summary, "workflow: " + state)
        r["status"] = state
        if dry:
            print(json.dumps(r)); return 0
        return publish_report(r)
    # Keep the existing code-landing gate. Work outcome and code landing can be
    # reported independently using `fleet-task-record.sh report` with a result.
    if state == "merged":
        if not pr or outcome not in ("", "succeeded"):
            raise ValueError("merged report requires a PR and a success outcome")
        gate = subprocess.run(["bash", str(BIN / "fleet-pr-verdict.sh"), pr], capture_output=True, text=True, timeout=20)
        if gate.stdout.strip() != "MERGED":
            raise ValueError("PR merge is unconfirmed; task result not recorded")
    outcome = outcome or "succeeded"
    if outcome not in ("succeeded", "failed") or not summary.strip():
        raise ValueError("explicit completion needs succeeded/failed and a summary")
    receipt = launch.check_receipt(c, json.loads(launch.option(pane, "@launch_receipt", socket)))
    evidence = json.dumps(dict(native_session=receipt["native_session"], provider=receipt["actual_provider"],
                               work_result=outcome, pr=pr,
                               pr_state="merged" if state == "merged" else "waiting" if pr else "none"), sort_keys=True)
    r = report_input(c, t, outcome, summary, evidence)
    r["status"] = state  # landing projection is separate from terminal work outcome
    if dry:
        print(json.dumps(r)); return 0
    return publish_report(r)


def finalize(pane):
    c = context(pane)
    t = call("get", c["task"], stale=True)["task"]
    if any(t.get(k) != c[v] for k, v in (("owner", "owner"), ("generation", "generation"), ("execution_owner", "worker_id"))):
        raise ValueError("stale finalization generation")
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
    evidence = json.dumps({k: proof[k] for k in ("pid", "birth", "executable", "native_session")}, sort_keys=True)
    # Record the stopped native even if a cancel request/result was accepted
    # while this node was offline. Replay reads the current fenced task before
    # acknowledging cancellation; exit alone never invents a work outcome.
    event = "stop:" + hashlib.sha256(evidence.encode()).hexdigest()
    call("stopped", c["task"], dict(idempotency_key=event,
         generation=c["generation"], expected_worker=c["worker_id"], execution_stopped=True, evidence=evidence,
         _native=dict(launch=c, pane=pane, socket=launch.option(pane, "socket_path"))))
    return 0


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
                       event_id=r["event_id"], state=(r["outcome"].upper() or "WAITING"), summary=r["summary"],
                       parent=r["parent_session"], reason=why)
            stream.write(json.dumps(row) + "\n")
    print("orphaned → task %s event %s: %s" % (r["task"], r["event_id"], why))


def receive(file):
    envelope = json.loads(Path(file).read_text())
    r = envelope["payload"]["task_report"]
    if envelope["from"] != r["worker_id"] or envelope["to"] != r["parent_session"]:
        raise ValueError("relay task identity mismatch")
    t = call("get", r["task"])["task"]
    if (t["owner"], t["generation"], t["execution_owner"], t.get("outcome", "")) != (r["owner"], r["generation"], r["worker_id"], r["outcome"]):
        print("historical child generation; no delivery"); return 0
    if any(t.get(k, "" if k != "parent_generation" else 0) != r[k] for k in ("ticket_ref", "parent_task", "parent_session", "parent_generation")):
        raise ValueError("relay differs from accepted parent/ticket binding")
    if r["parent_task"]:
        parent = call("get", r["parent_task"])["task"]
        if not parent_matches(r, parent):
            orphan(r, "parent generation retired"); return 0
    # The one resolver, and only the stable worker ID. No issue/name fallback.
    cmd = r''' . "$1/fleet-lib.sh"; . "$1/fleet-children-lib.sh"
task_home=$(fleet_wid_home "wid:$2") || exit 75
sock=$(fleet_socket "$task_home")
tmux -L "$sock" has-session -t "=$task_home" 2>/dev/null || exit 75
win=$(fleet_win_for_fid "${2#*/}" "$sock"); task_rc=$?
[ "$task_rc" = 1 ] && exit 76
[ "$task_rc" = 0 ] || exit 75
dir=$(children_dir "$task_home") || exit 75
printf "%s\n%s\n%s\n" "$sock" "$win" "$dir"
'''
    located = subprocess.run(["bash", "-c", cmd, "task-receive", str(BIN), r["parent_session"]],
                             capture_output=True, text=True, timeout=10)
    if located.returncode == 76:
        orphan(r, "parent session retired on its known fleet"); return 0
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
        sent_key = "task-report:" + hashlib.sha256((r["task"] + ":" + r["event_id"]).encode()).hexdigest()
        if sentfile.exists() and sent_key in sentfile.read_text().splitlines():
            print("already delivered"); return 0
        msg = "[child-report] %s\nstate: %s · generation %s\nsummary: %s\nno reply needed" % (r["task"], (r["outcome"].upper() or "WAITING"), r["generation"], r["summary"])
        delivery_env = dict(os.environ)
        if native:
            # No sleeper/peer queue can outlive this generation check. An
            # unavailable inbox leaves the same relay pending on the hub.
            if native["actual_provider"] == "codex":
                # Keep the exact generation/native endpoint through the final
                # send. Re-reading a pane identity alone could target a transfer.
                delivery_env.update(FLEET_LAUNCH_CONTEXT=json.dumps(c),
                                    FLEET_LAUNCH_DELIVERY=json.dumps(native))
                argv = [sys.executable, str(BIN / "fleet-codex-session.py"), "send", "--pane", pane, "--socket", socket]
            else:
                argv = ["bash", "-c", '. "$1/fleet-lib.sh"; fleet_peer_send "$2" "$(cat)" fleet-report', "task", str(BIN), str(native["pid"])]
        else:
            argv = ["bash", "-c", '. "$1/fleet-lib.sh"; . "$1/fleet-children-lib.sh"; children_send "" "$2" "$3" "$(cat)"', "task", str(BIN), socket, pane]
        delivered = subprocess.run(argv, input=msg, capture_output=True, text=True, timeout=20, env=delivery_env)
        if delivered.returncode:
            return 75
        with sentfile.open("a") as stream:
            stream.write(sent_key + "\n")
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
    p.add_argument("--outcome", choices=("succeeded", "failed"), default="")
    p.add_argument("--pr", default="")
    p.add_argument("--event", default="")
    p.add_argument("--dry", action="store_true")
    args = p.parse_args()
    try:
        if args.action not in ("receive",) and not args.dry:
            # Explicit next command, never a resident loop. Failed replay does
            # not stop a native process or authorize a replacement.
            from fleet_task_recovery import Journal
            try:
                recovery = Journal().replay(budget=5)
                if recovery["pending"]:
                    print("RECONCILIATION_PENDING: %d retained receipts" % recovery["pending"], file=sys.stderr)
            except (ValueError, OSError, subprocess.SubprocessError):
                pass  # the requested operation below still fails closed
        if args.action == "children": return children(args.task, args.json)
        if args.action == "await": return wait_task(args.task, max(1, args.timeout), max(1, args.interval))
        if args.action == "report": return report(args.pane, args.state, args.summary, args.pr, args.dry, args.socket, args.outcome)
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
