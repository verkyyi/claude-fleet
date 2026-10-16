#!/usr/bin/env python3
"""Read-only blocker projection: native attention stays independent (fixtures)."""
import copy
import contextlib
import io
import json
import tempfile
import unittest
from unittest.mock import patch
import fleet_task_control as control
import fleet_task_recovery as recovery


class BlockerProjectionTests(unittest.TestCase):
    def test_unknown_and_attention_never_clear_blockers(self):
        task = dict(id="T7", authority_version=1, owner="alice", generation=2,
                    execution_owner="fleet/session", repo="repo/a", ticket_ref="github:repo/a#7",
                    task_blockers=dict(version=1, generation=2, items=[dict(
                        blocker_id="one", state="active", scope=dict(task="T7", owner="alice", generation=2,
                        worker_id="fleet/session", repo="repo/a", ticket_ref="github:repo/a#7"))]))
        original = copy.deepcopy(task)
        for attention in ("ask", "approval", "unknown", "idle"):
            task["runtime"] = dict(state=attention, expires_at=0)
            result = control.blocker_projection(task)
            self.assertEqual(result["state"], "blocked")
            self.assertEqual(result["active_ids"], ["one"])
            self.assertFalse(result["actionable"])
            self.assertEqual(task["runtime"]["state"], attention)
            self.assertEqual(task["task_blockers"], original["task_blockers"])
        for changed in ({}, dict(task, _stale=True), dict(task, generation=3), dict(task, owner="bob")):
            self.assertEqual(control.blocker_projection(changed)["state"], "unknown")

    def test_report_entry_keeps_scope_and_native_attention_separate(self):
        c = dict(task="T7", owner="alice", generation=2, worker_id="fleet/session")
        task = dict(c, id="T7", execution_owner=c["worker_id"], asked="approval pending", outcome="")
        command = dict(version=1, action="create", blocker_id="one", reason="dependency", evidence="explicit grant")
        with patch.object(control, "context", return_value=c), patch.object(control, "call", return_value=dict(task=task)), patch.object(control, "publish_report", return_value=0) as publish:
            self.assertEqual(control.blocker("%fixture", command, "stable-event"), 0)
            r = publish.call_args.args[0]
            self.assertEqual(r["event_id"], "stable-event")
            self.assertEqual(r["blocker"], command)
            self.assertEqual(r["outcome"], "")
            self.assertFalse(r["execution_stopped"])
            self.assertEqual(task["asked"], "approval pending")
            task["generation"] = 3
            with self.assertRaises(ValueError): control.blocker("%fixture", command, "late")

    def test_existing_journal_lost_ack_and_expiry(self):
        task = dict(id="T7", authority_version=1, owner="alice", generation=2, execution_owner="fleet/session",
                    repo="repo/a", task_blockers=dict(version=1, generation=2, items=[]))
        commands, lose_ack = {}, [True]
        def transport(action, ref, payload=None, **kw):
            if action == "get": return dict(task=copy.deepcopy(task))
            commands.setdefault(payload["idempotency_key"], copy.deepcopy(payload))
            if lose_ack.pop() if lose_ack else False: raise ValueError("ack lost")
            return copy.deepcopy(task)
        with tempfile.TemporaryDirectory() as directory:
            j = recovery.Journal(directory, authority="https://fixture.invalid", transport=transport)
            j.get("T7")
            payload = dict(kind="blocker", generation=2, expected_worker="fleet/session", idempotency_key="create-one",
                           blocker=dict(version=1, action="create", blocker_id="one", evidence="fixture"))
            with self.assertRaises(recovery.Pending): j.send("mutate", "T7", payload)
            j = recovery.Journal(directory, authority="https://fixture.invalid", transport=transport)
            got = j.send("mutate", "T7", payload)
            self.assertEqual(got["task_blockers"], task["task_blockers"])
            self.assertEqual(len(commands), 1)
            changed = copy.deepcopy(payload); changed["blocker"]["evidence"] = "changed"
            with self.assertRaises(ValueError): j.send("mutate", "T7", changed)
            cached = j.cached("T7")
            self.assertTrue(cached["stale"])
            self.assertEqual(control.blocker_projection(cached["task"], stale=cached["stale"])["state"], "unknown")
            with patch.object(recovery.time, "time", return_value=cached["observed_at"]+recovery.RETENTION+1):
                with self.assertRaises(recovery.Pending): j.cached("T7")

    def test_closed_blocker_is_not_task_success_or_action_permission(self):
        task = dict(id="T1", owner="alice", authority_version=1, generation=1, execution_owner="f/s", outcome="")
        scope = dict(task="T1", owner="alice", generation=1, worker_id="f/s", repo="", ticket_ref="")
        for state, want in (("active", "blocked"), ("resolved", "clear"), ("revoked", "revoked")):
            task["task_blockers"] = dict(version=1, generation=1, items=[dict(blocker_id="one", scope=scope, state=state)])
            got = control.blocker_projection(task)
            self.assertEqual(got["state"], want)
            self.assertFalse(got["actionable"])
            self.assertEqual(control.verdict(task), "WAITING")


if __name__ == "__main__":
    unittest.main()
