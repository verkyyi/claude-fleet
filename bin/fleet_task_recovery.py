#!/usr/bin/env python3
"""Bounded lifecycle receipts in the existing node operation journal (#4396).

Only already accepted task reports, cancellation requests and stop receipts are
replayed. No launch input, ownership grant, executor or task authority lives here.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import uuid

from fleet_control import SCHEMA
from fleet_hub_common import Database, canonical

BIN = Path(__file__).resolve().parent
RETENTION = 7 * 24 * 3600
MAX_PENDING = 1000
ACTION = "task_receipt"
# Observations contain identity/control state only, never a task's command input.
TASK_FIELDS = ("id", "authority_version", "owner", "generation", "execution_owner",
               "resolved_agent", "actual_agent", "attempt_id", "operation_id", "state", "outcome",
               "cancel_request", "ticket_ref", "repo", "task_blockers", "parent_task", "parent_session", "parent_generation")


class Pending(ValueError):
    pass


class Deferred(Pending):
    """One receipt needs reconciliation; other tasks may still replay."""


class Refused(ValueError):
    pass


@contextlib.contextmanager
def native_guard(context, root=None):
    """Serialize a native resume with reconciliation of its earlier stop."""
    directory = Path(root or Path(os.environ.get("FLEET_CONF_DIR", Path.home() / ".config/claude-fleet")))
    if root is None:
        directory /= "control"
    directory.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha256(canonical([context[k] for k in ("task", "generation", "worker_id")]).encode()).hexdigest()
    with (directory / ("native-" + key + ".lock")).open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise Deferred("native launch/stop reconciliation already in progress") from exc
        yield


def verify_stopped(payload, task):
    import fleet_launch as launch
    binding = payload.get("_native", {})
    try:
        c = launch.validate_context(binding["launch"])
        if (c["task"], c["generation"], c["worker_id"]) != (task, payload["generation"], payload["expected_worker"]):
            raise Refused("stop proof belongs to another task generation")
        pane, socket = binding["pane"], binding["socket"]
        if not pane or not socket or not os.path.isabs(socket):
            raise ValueError("missing native address")
        if json.loads(launch.option(pane, "@launch", socket)) != c:
            raise Refused("native launch binding changed")
        receipt = launch.check_receipt(c, json.loads(launch.option(pane, "@launch_receipt", socket)))
        if launch.option(pane, "@fleet_id", socket) != c["worker_id"].split("/")[1]:
            raise Refused("native session owner changed")
        proof = json.loads(payload["evidence"])
        if any(proof[k] != receipt[k] for k in ("pid", "birth", "executable", "native_session")):
            raise Refused("native incarnation changed; old stop proof retired")
        try:
            os.kill(proof["pid"], 0)
        except ProcessLookupError:
            return
        observed = launch.process(proof["pid"])
        if all(observed[k] == proof[k] for k in ("pid", "birth", "executable")):
            raise Refused("native execution is still alive")
    except Refused:
        raise
    except (KeyError, ValueError, OSError, subprocess.SubprocessError) as exc:
        raise Deferred("native stop binding unavailable; reconciliation required") from exc


def raw_call(action, task, payload=None, timeout=15, authority=""):
    env = dict(os.environ, FLEET_TASK_RECOVERY_RAW="1",
               FLEET_HUB_TIMEOUT=str(max(1, min(10, int(timeout)))))
    if authority:
        env["FLEET_TASK_RECOVERY_URL"] = authority
    r = subprocess.run(["bash", str(BIN / "fleet-task-record.sh"), action, task],
                       input=canonical(payload) if payload is not None else None,
                       text=True, capture_output=True, timeout=timeout, env=env)
    if r.returncode:
        code = re.search(r"HTTP (4[0-9][0-9])", r.stderr)
        if code and code[1] not in ("408", "429"):
            raise Refused("task authority refused HTTP " + code[1])
        raise ValueError("task authority unavailable/refused")
    return json.loads(r.stdout)


class Journal:
    def __init__(self, conf_dir=None, authority=None, transport=None):
        root = Path(conf_dir or os.environ.get("FLEET_CONF_DIR", Path.home() / ".config/claude-fleet"))
        self.store = Database(root / "control", SCHEMA)
        if authority is None:
            r = subprocess.run(["bash", str(BIN / "fleet-task-record.sh"), "authority"],
                               capture_output=True, text=True, timeout=10)
            if r.returncode or not r.stdout.strip():
                raise ValueError("task authority identity unavailable")
            authority = r.stdout.strip()
        self.scope = hashlib.sha256(authority.rstrip("/").encode()).hexdigest()
        self.transport = transport or (lambda *args, **kwargs: raw_call(*args, **kwargs, authority=authority))

    def cache_key(self, task):
        return "task-observation:" + self.scope + ":" + task

    def observe(self, task, data):
        t = data.get("task", data)
        if t.get("authority_version") != 1 or t.get("id") != task:
            return data
        observation = dict(task={k: t[k] for k in TASK_FIELDS if k in t}, observed_at=time.time(), stale=False)
        with self.store.connect() as db:
            db.execute("INSERT OR REPLACE INTO metadata VALUES (?,?)", (self.cache_key(task), canonical(observation)))
            # Cache is disposable; receipts are not. A missing observation can
            # only refuse an offline write, never grant permission.
            keys = db.execute("SELECT key, value FROM metadata WHERE key LIKE 'task-observation:%'").fetchall()
            for row in sorted(keys, key=lambda r: json.loads(r["value"])["observed_at"])[:-MAX_PENDING]:
                db.execute("DELETE FROM metadata WHERE key=?", (row["key"],))
        return dict(data, observed_at=observation["observed_at"], stale=False)

    def cached(self, task):
        with self.store.connect() as db:
            row = db.execute("SELECT value FROM metadata WHERE key=?", (self.cache_key(task),)).fetchone()
        if row is None:
            raise Pending("RECONCILIATION_REQUIRED: no accepted task observation")
        data = json.loads(row["value"])
        if time.time() - data["observed_at"] >= RETENTION:
            raise Pending("RECONCILIATION_REQUIRED: task observation expired; evidence retained")
        return dict(data, stale=True)

    def get(self, task, stale=False, timeout=15):
        try:
            return self.observe(task, self.transport("get", task, timeout=timeout))
        except (ValueError, OSError, subprocess.SubprocessError):
            if not stale:
                raise
            return self.cached(task)

    def expire(self, db):
        cutoff = time.time() - RETENTION
        db.execute("DELETE FROM operations WHERE action=? AND status='succeeded' AND updated<?", (ACTION, cutoff))
        for row in db.execute("SELECT id,result FROM operations WHERE action=? AND status IN ('pending','committed') AND created<=?", (ACTION, cutoff)).fetchall():
            result = json.loads(row["result"] or "{}")
            result["reason"] = "expired: reconciliation required; receipt retained"
            db.execute("UPDATE operations SET status='unknown',result=? WHERE id=?", (canonical(result), row["id"]))

    def event(self, action, task, payload):
        if action == "report":
            event = payload.get("event_id")
        elif action == "stopped" or (action == "mutate" and payload.get("kind") in ("stop_ack", "cancel_request", "blocker")):
            event = payload.get("idempotency_key")
        else:
            raise ValueError("only lifecycle receipts may be retained")
        if not isinstance(event, str) or not event or len(event) > 200:
            raise ValueError("lifecycle receipt needs a stable event ID")
        key = canonical([self.scope, action, task, event])
        return str(uuid.uuid5(uuid.NAMESPACE_URL, key))

    def enqueue(self, action, task, payload):
        eid = self.event(action, task, payload)
        request = canonical(dict(scope=self.scope, action=action, task=task, payload=payload))
        if len(request.encode()) > 65536:
            raise Pending("RECONCILIATION_REQUIRED: receipt exceeds 64 KiB; not accepted")
        old = self.row(eid)
        if old:
            if old["request"] != request:
                raise ValueError("lifecycle event ID payload conflict")
            return eid
        try:
            t = self.cached(task)["task"]
        except Pending:
            t = self.get(task)["task"]  # first online receipt needs no preparatory GET
        worker = payload.get("worker_id", payload.get("expected_worker"))
        if (payload.get("generation"), worker) != (t.get("generation"), t.get("execution_owner", "")):
            t = self.get(task)["task"]
        with self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            self.expire(db)
            old = db.execute("SELECT * FROM operations WHERE id=? AND action=?", (eid, ACTION)).fetchone()
            if old:
                if old["request"] != request:
                    raise ValueError("lifecycle event ID payload conflict")
                return eid
            empty_cancel = action == "mutate" and payload.get("kind") == "cancel_request"
            if (t.get("authority_version") != 1 or
                    (payload.get("generation"), worker) != (t.get("generation"), t.get("execution_owner", "")) or
                    (not worker and not empty_cancel)):
                raise ValueError("receipt differs from accepted owner/generation")
            if action == "report" and (payload.get("owner") != t.get("owner") or payload.get("task") != task):
                raise ValueError("receipt differs from accepted task/owner")
            count = db.execute("SELECT COUNT(*) FROM operations WHERE action=? AND status!='succeeded'", (ACTION,)).fetchone()[0]
            if count >= MAX_PENDING:
                # One bounded audit marker, no evicted receipts and no false ack.
                db.execute("INSERT OR REPLACE INTO metadata VALUES ('task-recovery-overflow',?)",
                           (canonical(dict(event_id=eid, task=task, observed_at=time.time(),
                                           reason="1000 pending receipts: reconciliation required; new write rejected")),))
                rejected = True
            else:
                rejected = False
                db.execute("INSERT INTO operations VALUES (?,?,?,?,?,?,?,?,NULL)",
                           (eid, worker.split("/")[0], ACTION, request, t["owner"], "pending", time.time(), time.time()))
        if rejected:
            raise Pending("RECONCILIATION_REQUIRED: 1000 pending receipts; new write not accepted")
        return eid

    def row(self, eid):
        with self.store.connect() as db:
            self.expire(db)
            row = db.execute("SELECT * FROM operations WHERE id=? AND action=?", (eid, ACTION)).fetchone()
        return row

    def send(self, action, task, payload, native_locked=False):
        eid = self.enqueue(action, task, payload)
        row = self.row(eid)
        if row["status"] == "unknown":
            raise Pending("RECONCILIATION_REQUIRED: " + json.loads(row["result"])["reason"])
        if row["status"] in ("committed", "succeeded"):
            saved = json.loads(row["result"])
            return dict(saved["receipt"], _recovery_event=eid, _recovery_done=row["status"] == "succeeded",
                        _delivery_file=saved.get("delivery_file", ""), _recovery_expires=row["created"] + RETENTION)
        try:
            outgoing = {k: v for k, v in payload.items() if k != "_native"}
            if action == "stopped":
                receipt = self.stopped(task, payload)
            elif action == "report" and payload.get("execution_stopped") and not native_locked:
                c = dict(task=task, generation=payload["generation"], worker_id=payload["worker_id"])
                with native_guard(c, self.store.root):
                    verify_stopped(dict(payload, expected_worker=payload["worker_id"]), task)
                    receipt = self.transport(action, task, outgoing)
            else:
                receipt = self.transport(action, task, outgoing)
        except (Deferred, Refused) as exc:
            with self.store.connect() as db:
                db.execute("UPDATE operations SET status=?,result=? WHERE id=? AND status='pending'",
                           ("unknown" if isinstance(exc, Refused) else "pending", canonical(dict(reason=str(exc))), eid))
            raise Deferred("RECONCILIATION_REQUIRED: " + str(exc)) from exc
        except (ValueError, OSError, subprocess.SubprocessError) as exc:
            with self.store.connect() as db:
                db.execute("UPDATE operations SET result=? WHERE id=? AND status='pending'",
                           (canonical(dict(reason="hub unavailable/refused; reconciliation pending")), eid))
            raise Pending("RECONCILIATION_PENDING: event %s retained; hub commit unconfirmed" % eid) from exc
        if action == "report" and receipt.get("disposition") not in ("committed", "progress"):
            with self.store.connect() as db:
                db.execute("UPDATE operations SET status='unknown', result=? WHERE id=? AND status='pending'",
                           (canonical(dict(reason="hub report disposition: " + str(receipt.get("disposition")))), eid))
            raise Deferred("RECONCILIATION_REQUIRED: historical/refused report; no delivery")
        # Minimize retained authority data; task input never enters the outbox.
        if "task" in receipt:
            receipt = dict(receipt, task={k: v for k, v in receipt["task"].items() if k in TASK_FIELDS})
        elif receipt.get("authority_version") == 1:
            receipt = {k: v for k, v in receipt.items() if k in TASK_FIELDS}
        with self.store.connect() as db:
            db.execute("UPDATE operations SET status=?, result=?, updated=? WHERE id=? AND status='pending'",
                       ("committed" if action == "report" else "succeeded", canonical(dict(receipt=receipt)), time.time(), eid))
        return dict(receipt, _recovery_event=eid, _recovery_expires=row["created"] + RETENTION)

    def stopped(self, task, payload):
        c = dict(task=task, generation=payload["generation"], worker_id=payload["expected_worker"])
        with native_guard(c, self.store.root):
            verify_stopped(payload, task)
            return self.commit_stopped(task, payload)

    def commit_stopped(self, task, payload):
        t = self.transport("get", task)["task"]
        if (t.get("generation"), t.get("execution_owner")) != (payload["generation"], payload["expected_worker"]):
            raise Refused("stop receipt generation retired")
        if not t.get("outcome"):
            if not t.get("cancel_request"):
                raise Deferred("native stopped without explicit work outcome; reconciliation required")
            from fleet_task_control import report_input, deliver_report
            c = dict(task=task, owner=t["owner"], generation=t["generation"], worker_id=t["execution_owner"])
            r = report_input(c, t, "cancelled", "Cancellation acknowledged after native stop", payload["evidence"],
                             stopped=True, event=t["cancel_request"] + ".ack")
            r["cancel_request"] = t["cancel_request"]
            r["_native"] = payload.get("_native", {})
            receipt = self.send("report", task, r, native_locked=True)
            with contextlib.redirect_stdout(sys.stderr):
                deliver_report(r, receipt)
            self.ack_report(task, r, receipt.get("_delivery_file", ""))
        return self.transport("mutate", task, dict({k: v for k, v in payload.items() if k != "_native"}, kind="stop_ack"))

    def ack_report(self, task, payload, delivery_file=""):
        eid = self.event("report", task, payload)
        with self.store.connect() as db:
            if delivery_file:
                row = db.execute("SELECT result FROM operations WHERE id=? AND status='committed'", (eid,)).fetchone()
                if row:
                    result = json.loads(row["result"])
                    result["delivery_file"] = delivery_file
                    db.execute("UPDATE operations SET result=? WHERE id=?", (canonical(result), eid))
            else:
                db.execute("UPDATE operations SET status='succeeded',updated=? WHERE id=? AND status='committed'",
                           (time.time(), eid))

    def put_report(self, report, payload):
        """Publish one deterministic file in the existing relay outbox.

        Book its path before publishing. A crash on either side reuses the same
        event/file; an acknowledged file is never recreated.
        """
        eid = self.event("report", report["task"], report)
        directory = self.store.root / "hub-outbox"
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        path = directory / ("task-" + eid + ".json")
        with (self.store.root / "task-delivery.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            row = self.row(eid)
            if row is None or row["status"] not in ("committed", "succeeded"):
                raise Deferred("receipt is unresolved; no parent delivery")
            self.ack_report(report["task"], report, str(path))
            if path.exists() or Path(str(path) + ".acked").exists() or row["status"] == "succeeded":
                return str(path)
            if (directory / "refused" / path.name).exists() or Path(str(path) + ".why").exists():
                raise Deferred("parent relay refused/expired; reconciliation required")
            suffix = hashlib.sha256((report["task"] + ":" + report["event_id"]).encode()).hexdigest()
            relay = dict(id=report["worker_id"] + "#" + suffix, kind="child_report",
                         **{"from": report["worker_id"]}, to=report["parent_session"], payload=payload)
            assertion = os.environ.get("FLEET_WORKER_ASSERT", "")
            if assertion:
                relay["worker"] = assertion  # existing outbox assertion, never the receipt journal
            fd, temp = tempfile.mkstemp(prefix=".task-", dir=str(directory))
            try:
                with os.fdopen(fd, "w") as stream:
                    stream.write(canonical(relay))
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temp, path)
                fd = os.open(directory, os.O_RDONLY)
                try:
                    os.fsync(fd)
                finally:
                    os.close(fd)
            finally:
                Path(temp).unlink(missing_ok=True)
        return str(path)

    def delivery_pending(self, eid):
        row = self.row(eid)
        result = json.loads(row["result"] or "{}")
        file = result.get("delivery_file")
        if not file:
            return False
        path = Path(file)
        ack = Path(file + ".acked")
        if ack.exists() and ack.read_text() == eid:
            with self.store.connect() as db:
                db.execute("UPDATE operations SET status='succeeded',updated=? WHERE id=? AND status='committed'", (time.time(), eid))
            ack.unlink(missing_ok=True)
        elif (path.parent / "refused" / path.name).exists() or Path(file + ".why").exists():
            with self.store.connect() as db:
                result["reason"] = "relay missing/refused without acknowledgement; reconciliation required"
                db.execute("UPDATE operations SET status='unknown',result=? WHERE id=?", (canonical(result), eid))
        elif not path.exists():
            return False  # crash before publish: recreate the SAME file/event, never infer success
        return True  # retained/acked/refused: never create another transport copy

    def status(self):
        with self.store.connect() as db:
            self.expire(db)
            rows = db.execute("SELECT id,status,created,result FROM operations WHERE action=? AND status!='succeeded' ORDER BY created", (ACTION,)).fetchall()
            overflow = db.execute("SELECT value FROM metadata WHERE key='task-recovery-overflow'").fetchone()
        return dict(pending=len(rows), unresolved=[dict(event_id=r["id"], status=r["status"], created_at=r["created"],
                    reason=json.loads(r["result"] or "{}").get("reason", "delivery pending")) for r in rows],
                    overflow=json.loads(overflow[0]) if overflow else None)

    def replay(self, budget=20):
        # One pass on reconnect/next command; concurrent invocations do no work.
        with (self.store.root / "task-replay.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return self.status()
            with self.store.connect() as db:
                self.expire(db)
                rows = db.execute("SELECT id,request FROM operations WHERE action=? AND status IN ('pending','committed') ORDER BY created", (ACTION,)).fetchall()
            deadline = time.monotonic() + budget
            for row in rows:
                if time.monotonic() >= deadline:
                    break
                r = json.loads(row["request"])
                if r["scope"] != self.scope:
                    continue  # another authority can never consume these IDs
                if self.delivery_pending(row["id"]):
                    continue
                try:
                    receipt = self.send(r["action"], r["task"], r["payload"])
                    if r["action"] == "report":
                        from fleet_task_control import deliver_report
                        with contextlib.redirect_stdout(sys.stderr):
                            deliver_report(r["payload"], receipt)
                        self.ack_report(r["task"], r["payload"], receipt.get("_delivery_file", ""))
                except Deferred:
                    continue  # an unresolved task never blocks another task's receipts
                except (ValueError, OSError, subprocess.SubprocessError):
                    break  # no retry loop; same event on next explicit occasion
        return self.status()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("action", choices=("get", "report", "mutate", "stopped", "replay", "status", "ack"))
    p.add_argument("task", nargs="?", default="")
    a = p.parse_args()
    try:
        j = Journal()
        if a.action in ("status", "replay"):
            data = j.replay() if a.action == "replay" else j.status()
            print(canonical(data))
            return 3 if data["pending"] else 0
        if a.action == "get":
            data = j.get(a.task, stale=os.environ.get("FLEET_TASK_STALE_READ") == "1")
        else:
            payload = json.load(sys.stdin)
            if a.action == "ack":
                j.ack_report(a.task, payload)
                return 0
            if a.action == "mutate" and payload.get("kind") not in ("cancel_request", "blocker"):
                data = j.transport(a.action, a.task, payload)  # never buffer ownership or launch input
            else:
                data = j.send(a.action, a.task, payload)
        print(canonical(data))
        return 0
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        print(str(exc), file=sys.stderr)
        # task-record's callers reserve 3 for "no hub configured". A configured
        # but unreachable authority must keep the original failure contract.
        return 3 if a.action in ("status", "replay") else 1


if __name__ == "__main__":
    sys.exit(main())
