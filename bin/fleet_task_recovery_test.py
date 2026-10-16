#!/usr/bin/env python3
"""Bounded outage fixtures: no production hub, native session or credentials."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import fleet_task_recovery as recovery
VERIFY_STOPPED = recovery.verify_stopped


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        proof = patch.object(recovery, "verify_stopped")
        proof.start()
        self.addCleanup(proof.stop)
        self.task = dict(id="T7", authority_version=1, owner="alice", generation=2,
                         execution_owner="fleet/session", resolved_agent="codex", state="running",
                         parent_session="", outcome="", operation_id="accepted-op")
        self.calls = []
        self.offline = False
        self.commits = {}
        self.lose_ack = False
        self.j = recovery.Journal(self.temp.name, authority="https://fixture.invalid", transport=self.transport)
        self.j.get("T7")

    def transport(self, action, task, payload=None, timeout=15):
        self.calls.append((action, task, payload))
        if self.offline:
            raise ValueError("offline")
        if action == "get":
            return dict(task=dict(self.task))
        event = payload.get("event_id") or payload["idempotency_key"]
        if action == "report":
            self.commits.setdefault(event, dict(payload))
            self.task["outcome"] = payload["outcome"]
            result = dict(disposition="committed", task=dict(self.task, outcome=payload["outcome"]))
        else:
            self.commits.setdefault(event, dict(payload))
            if payload.get("kind") == "cancel_request":
                self.task["cancel_request"] = event
            result = dict(self.task)
        if self.lose_ack:
            self.lose_ack = False
            raise ValueError("ack lost")
        return result

    def report(self, event="result"):
        return dict(task="T7", owner="alice", generation=2, worker_id="fleet/session",
                    event_id=event, outcome="succeeded", evidence="native fixture", summary="done",
                    parent_session="", parent_task="", parent_generation=0, ticket_ref="")

    def test_outage_restart_replay_and_bounds(self):
        native = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        try:
            observed = self.j.get("T7")["observed_at"]
            self.offline = True
            with self.assertRaises(recovery.Pending):
                self.j.send("report", "T7", self.report())
            cached = self.j.get("T7", stale=True)
            self.assertTrue(cached["stale"])
            self.assertEqual(cached["observed_at"], observed)
            with self.assertRaises(ValueError):
                self.j.get("T7")  # authority checks cannot consume the cache
            restarted = recovery.Journal(self.temp.name, authority="https://fixture.invalid", transport=self.transport)
            self.offline = False
            self.lose_ack = True
            with self.assertRaises(recovery.Pending):
                restarted.send("report", "T7", self.report())
            receipt = restarted.send("report", "T7", self.report())
            self.assertEqual(receipt["disposition"], "committed")
            restarted.ack_report("T7", self.report())
            restarted.send("report", "T7", self.report())
            self.assertEqual(len(self.commits), 1)
            self.assertEqual(restarted.status()["pending"], 0)
            self.assertIsNone(native.poll())
            print("fixture outage: same process alive across adapter recreation; stable event commits=1; stale observed_at retained")
        finally:
            native.terminate()
            native.wait(timeout=5)

    def test_full_limit_preserves_every_pending_record(self):
        self.offline = True
        # Seed the real production limit without 1000 HTTP subprocesses.
        with self.j.store.connect() as db:
            for i in range(recovery.MAX_PENDING):
                r = self.report("event-%d" % i)
                eid = self.j.event("report", "T7", r)
                request = recovery.canonical(dict(scope=self.j.scope, action="report", task="T7", payload=r))
                db.execute("INSERT INTO operations VALUES (?,?,?,?,?,?,?,?,NULL)",
                           (eid, "fleet", recovery.ACTION, request, "alice", "pending", recovery.time.time(), recovery.time.time()))
            before = [tuple(r) for r in db.execute("SELECT * FROM operations ORDER BY id")]
        with self.assertRaisesRegex(recovery.Pending, "1000 pending"):
            self.j.send("report", "T7", self.report("overflow"))
        with self.j.store.connect() as db:
            self.assertEqual(before, [tuple(r) for r in db.execute("SELECT * FROM operations ORDER BY id")])
        status = self.j.status()
        self.assertEqual(status["pending"], 1000)
        self.assertIn("rejected", status["overflow"]["reason"])
        self.assertEqual(self.calls, [("get", "T7", None)])
        print("fixture overflow: 1000 pending unchanged; write 1001 rejected before HTTP; audit reason retained")

    def test_expiry_preserves_receipt_and_stale_timestamp(self):
        self.offline = True
        r = self.report()
        with self.assertRaises(recovery.Pending):
            self.j.send("report", "T7", r)
        eid = self.j.event("report", "T7", r)
        before = self.j.row(eid)["request"]
        observed = self.j.cached("T7")["observed_at"]
        self.offline = False
        with patch.object(recovery.time, "time", return_value=observed + recovery.RETENTION + 1):
            status = self.j.replay()
            self.assertEqual(status["unresolved"][0]["status"], "unknown")
            self.assertIn("expired", status["unresolved"][0]["reason"])
            with self.assertRaisesRegex(recovery.Pending, "expired"):
                self.j.send("report", "T7", r)
            with self.assertRaisesRegex(recovery.Pending, "expired"):
                self.j.cached("T7")
            self.assertEqual(self.j.row(eid)["request"], before)
        self.assertEqual(len(self.commits), 0)
        print("fixture expiry: >7 days retained unknown, no replay or ownership change")

    def test_event_conflict_and_foreign_hub_never_replay(self):
        self.offline = True
        with self.assertRaises(recovery.Pending):
            self.j.send("report", "T7", self.report())
        with self.assertRaisesRegex(ValueError, "payload conflict"):
            self.j.send("report", "T7", dict(self.report(), summary="changed"))
        other = recovery.Journal(self.temp.name, authority="https://other.invalid", transport=self.transport)
        self.offline = False
        other.replay()
        self.assertEqual(len(self.commits), 0)
        self.offline = True
        with self.assertRaises(ValueError):
            other.send("report", "T7", self.report())

    def test_only_accepted_lifecycle_events_can_queue(self):
        for kind in ("claim", "transfer", "retry", "transition"):
            with self.assertRaisesRegex(ValueError, "only lifecycle"):
                self.j.send("mutate", "T7", dict(kind=kind, idempotency_key="no"))
        for change in (dict(generation=3), dict(worker_id="other/session"), dict(owner="bob")):
            with self.assertRaises(ValueError):
                self.j.send("report", "T7", dict(self.report(), **change))
        self.assertEqual(self.j.status()["pending"], 0)

    def test_replay_twice_and_generation_fence(self):
        self.offline = True
        with self.assertRaises(recovery.Pending):
            self.j.send("report", "T7", self.report())
        self.offline = False
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.j.replay()["pending"], 0)
            self.assertEqual(self.j.replay()["pending"], 0)
        self.assertEqual(len(self.commits), 1)
        self.offline = True
        with self.assertRaises(recovery.Pending):
            self.j.send("report", "T7", self.report("old-generation"))
        self.offline = False
        with patch.object(self.j, "transport", return_value=dict(disposition="historical")):
            status = self.j.replay()
        self.assertEqual(status["unresolved"][0]["status"], "unknown")
        self.assertIn("historical", status["unresolved"][0]["reason"])

    def test_report_delivery_waits_for_positive_ack(self):
        r = self.report()
        self.j.send("report", "T7", r)
        file = Path(self.temp.name) / "relay.json"
        file.write_text("fixture")
        self.j.ack_report("T7", r, str(file))
        with patch("fleet_task_control.deliver_report") as deliver:
            self.assertEqual(self.j.replay()["pending"], 1)
            deliver.assert_not_called()
            # A lost file is not success.
            file.unlink()
            Path(str(file) + ".why").write_text("refused")
            self.assertEqual(self.j.replay()["unresolved"][0]["status"], "unknown")
            deliver.assert_not_called()
        r = self.report("positive-ack")
        self.j.send("report", "T7", r)
        file.write_text("fixture")
        Path(str(file) + ".why").unlink()
        self.j.ack_report("T7", r, str(file))
        Path(str(file) + ".acked").write_text(self.j.event("report", "T7", r))
        file.unlink()
        status = self.j.replay()
        self.assertEqual(status["pending"], 1)  # only the earlier missing relay
        self.assertFalse(Path(str(file) + ".acked").exists())

    def test_cancel_ack_loss_and_native_stop_during_partition(self):
        cancel = dict(kind="cancel_request", idempotency_key="cancel", generation=2,
                      expected_worker="fleet/session", evidence="explicit cancel")
        self.lose_ack = True
        with self.assertRaises(recovery.Pending):
            self.j.send("mutate", "T7", cancel)
        self.offline = True
        stop = dict(idempotency_key="stopped", generation=2, expected_worker="fleet/session",
                    execution_stopped=True, evidence=json.dumps(dict(pid=77, birth="one", executable="/native", native_session="sid")))
        with self.assertRaises(recovery.Pending):
            self.j.send("stopped", "T7", stop)
        self.assertEqual(self.j.cached("T7")["task"].get("cancel_request", ""), "")
        self.offline = False
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.j.replay()["pending"], 0)
            self.assertEqual(self.j.replay()["pending"], 0)
        self.assertEqual(self.task["outcome"], "cancelled")
        self.assertEqual(set(self.commits), {"cancel", "cancel.ack", "stopped"})
        print("fixture cancel: lost request ack + offline stop; one cancel event, one terminal commit, one stop ack")

    def test_completion_wins_cancel_race_and_retains_result(self):
        self.task.update(outcome="succeeded", cancel_request="late-cancel")
        stop = dict(idempotency_key="stopped", generation=2, expected_worker="fleet/session",
                    execution_stopped=True, evidence="native stopped")
        self.j.send("stopped", "T7", stop)
        self.j.send("stopped", "T7", stop)
        self.assertEqual(self.task["outcome"], "succeeded")
        self.assertEqual(set(self.commits), {"stopped"})

    def test_old_stop_after_native_resume_is_refused(self):
        self.task.update(outcome="succeeded")
        stop = dict(idempotency_key="old-native-stop", generation=2, expected_worker="fleet/session",
                    execution_stopped=True, evidence="P1 stopped; P2 later resumed the same generation")
        with patch.object(recovery, "verify_stopped", create=True, side_effect=recovery.Refused("native incarnation changed")):
            with self.assertRaises(recovery.Pending):
                self.j.send("stopped", "T7", stop)
        self.assertEqual(self.commits, {})
        self.assertIn("incarnation", self.j.status()["unresolved"][0]["reason"])

    def test_derived_cancel_receipt_rechecks_native_on_replay(self):
        self.task["cancel_request"] = "cancel"
        self.j.get("T7")
        stop = dict(idempotency_key="old-stop", generation=2, expected_worker="fleet/session",
                    execution_stopped=True, evidence="P1 stopped", _native={})
        def failed_report(action, task, payload=None, **kwargs):
            if action == "report":
                raise ValueError("hub lost before cancellation commit")
            return self.transport(action, task, payload, **kwargs)
        with patch.object(self.j,"transport",side_effect=failed_report):
            with self.assertRaises(recovery.Pending):
                self.j.send("stopped", "T7", stop)
        self.assertEqual(self.j.status()["pending"], 2)
        with patch.object(recovery,"verify_stopped",side_effect=recovery.Refused("P2 resumed")):
            status = self.j.replay()
        self.assertEqual({r["status"] for r in status["unresolved"]}, {"unknown"})
        self.assertEqual(self.commits, {})

    def test_cache_never_retains_command_input(self):
        self.task.update(title="private command", request_payload="private command", prompt="private command")
        self.j.get("T7")
        with self.j.store.connect() as db:
            raw = db.execute("SELECT value FROM metadata WHERE key=?", (self.j.cache_key("T7"),)).fetchone()[0]
        self.assertNotIn("private command", raw)
        self.j.send("mutate", "T7", dict(kind="cancel_request", idempotency_key="private-input",
                    generation=2, expected_worker="fleet/session", evidence="explicit cancel"))
        with self.j.store.connect() as db:
            results = str([r[0] for r in db.execute("SELECT result FROM operations")])
        self.assertNotIn("private command", results)

    def test_native_incarnation_and_resume_lock(self):
        import fleet_launch as launch
        op = "11111111-1111-4111-8111-111111111111"
        fid = "22222222-2222-4222-8222-222222222222"
        c = dict(version=1, operation_id=op, task="T7", owner="alice", generation=2,
                 worker_id=op+"/"+fid, provider="codex", attempt_id="task:T7:g2")
        proof = dict(pid=77, birth="P1", executable="/native", native_session=op)
        receipt = dict(c, **proof, actual_provider="codex")
        payload = dict(generation=2, expected_worker=c["worker_id"], evidence=json.dumps(proof),
                       _native=dict(launch=c, pane="@7", socket="/fixture/socket"))
        def option(pane, key, socket):
            return {"@launch":json.dumps(c), "@launch_receipt":json.dumps(receipt), "@fleet_id":fid}[key]
        with patch.object(launch,"option",side_effect=option), patch.object(recovery.os,"kill",side_effect=ProcessLookupError):
            VERIFY_STOPPED(payload, "T7")
            receipt.update(pid=88,birth="P2")
            with self.assertRaisesRegex(recovery.Refused,"incarnation"):
                VERIFY_STOPPED(payload, "T7")
        with recovery.native_guard(c,self.j.store.root):
            with self.assertRaises(recovery.Deferred):
                with recovery.native_guard(c,self.j.store.root):
                    self.fail("resume and stop both held native fence")

    def test_unresolved_stop_does_not_block_another_receipt(self):
        stop = dict(idempotency_key="orphan-stop", generation=2, expected_worker="fleet/session",
                    execution_stopped=True, evidence="native stopped without result")
        with self.assertRaises(recovery.Deferred):
            self.j.send("stopped", "T7", stop)
        self.offline = True
        with self.assertRaises(recovery.Pending):
            self.j.send("report", "T7", self.report())
        self.offline = False
        with contextlib.redirect_stdout(io.StringIO()):
            self.j.replay()
        self.assertEqual(self.task["outcome"], "succeeded")
        self.assertIn("result", self.commits)

    def test_first_online_receipt_and_unclaimed_cancel(self):
        with self.j.store.connect() as db:
            db.execute("DELETE FROM metadata")
        self.j.send("report", "T7", self.report())
        self.task.update(execution_owner="", state="accepted", outcome="")
        self.j.get("T7")
        self.j.send("mutate", "T7", dict(kind="cancel_request", idempotency_key="unclaimed",
                    generation=2, expected_worker="", evidence="explicit cancel"))
        self.assertIn("unclaimed", self.commits)

    def test_deterministic_outbox_survives_publish_crash(self):
        r = dict(self.report(), parent_session="parent/session")
        self.j.send("report", "T7", r)
        eid = self.j.event("report", "T7", r)
        payload = dict(task_report=r, task_recovery=eid, expires_at=recovery.time.time()+60)
        with patch.object(recovery.os, "replace", side_effect=OSError("publish interrupted")):
            with self.assertRaises(OSError):
                self.j.put_report(r, payload)
        # The path is durable before publication, but absent is never success.
        self.assertFalse(self.j.delivery_pending(eid))
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=4) as pool:
            paths = list(pool.map(lambda _: self.j.put_report(r, payload), range(4)))
        self.assertEqual(len(set(paths)), 1)
        self.assertEqual(len(list((self.j.store.root/"hub-outbox").glob("*.json"))), 1)
        path = Path(paths[0])
        path.unlink()
        Path(str(path)+".acked").write_text(eid)
        self.j.put_report(r, payload)
        self.assertFalse(path.exists())
        print("fixture outbox: concurrent/crash replay keeps one file; positive ack prevents recreation")


if __name__ == "__main__":
    unittest.main()
