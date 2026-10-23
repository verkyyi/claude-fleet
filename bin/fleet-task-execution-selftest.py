#!/usr/bin/env python3
# selftest-entry
"""Local Task execution fences persist before runtime admission can finish."""
import json
import multiprocessing
from pathlib import Path
import tempfile
import unittest

from fleet_hub_common import Database
from fleet_task_execution import ExecutionFence, FenceRefused


FID = "22222222-2222-4222-8222-222222222222"
FLEET = "11111111-1111-4111-8111-111111111111"
TASK_FID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"


def grant(task="T42", generation=1, **changes):
    value = dict(task_ref=task, task_fid=TASK_FID, generation=generation,
                 attempt_id=f"task:{task}:g{generation}", operation_id=f"start-{task}-{generation}",
                 execution_endpoint="node-a", execution_owner=FLEET + "/" + FID, cancel_request="")
    value.update(changes)
    return value


def hold_admission(conf, expected, ready, release, result):
    try:
        with ExecutionFence(conf).admission(expected) as permit:
            ready.set()
            if not release.wait(15):
                raise RuntimeError("test did not release admission")
            permit.assert_current()
        result.put("allowed")
    except FenceRefused:
        result.put("refused")
    except Exception as exc:
        result.put(repr(exc))


def stop_while_held(conf, ready, done, result):
    try:
        if not ready.wait(15):
            raise RuntimeError("admission did not enter")
        row = ExecutionFence(conf).request_stop("T42", "stop-42", generation=2)
        result.put(row["cancel_request"])
    except Exception as exc:
        result.put(repr(exc))
    finally:
        done.set()


def admit_sibling(conf, ready, done, result):
    try:
        if not ready.wait(15):
            raise RuntimeError("admission did not enter")
        ExecutionFence(conf).assert_current(grant("T43"))
        result.put("sibling allowed")
    except Exception as exc:
        result.put(repr(exc))
    finally:
        done.set()


class ExecutionFenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="task-execution-")
        self.addCleanup(self.tmp.cleanup)
        self.conf = Path(self.tmp.name)
        self.fence = ExecutionFence(self.conf)

    def test_same_control_database_and_restart(self):
        control = Database(self.conf / "control", "CREATE TABLE IF NOT EXISTS operations (id TEXT PRIMARY KEY);")
        with control.connect() as db:
            db.execute("INSERT INTO operations VALUES ('existing-control-operation')")
        expected = self.fence.bind(grant(), authorized=True)
        self.assertEqual(self.fence.bind(grant(), authorized=True), expected)
        restarted = ExecutionFence(self.conf)
        self.assertEqual(restarted.read("T42"), expected)
        self.assertEqual(restarted.snapshot(), [expected])
        self.assertEqual(restarted.store.path, control.path)
        with control.connect() as db:
            self.assertEqual(db.execute("SELECT id FROM operations").fetchone()[0], "existing-control-operation")
        self.assertEqual(list(self.conf.rglob("*.sqlite3")), [control.path])

    def test_hub_export_contract_is_consumed_without_field_mapping(self):
        fixture = Path(__file__).resolve().parents[1] / "tokenledger/hub/store/testdata/task_execution.json"
        exported = json.loads(fixture.read_text())
        self.assertEqual(self.fence.bind(exported, authorized=True), exported)
        with self.fence.admission(exported) as permit:
            self.assertEqual(permit.assert_current(), exported)
        stopped_export = dict(exported, generation=exported["generation"] + 1,
                              cancel_request="stop-fixture")
        self.assertEqual(self.fence.observe(stopped_export), stopped_export)
        restarted = ExecutionFence(self.conf)
        self.assertEqual(restarted.read(exported["task_ref"]), stopped_export)
        self.assertEqual(restarted.snapshot(), [stopped_export])
        self.assertEqual(restarted.request_stop(exported["task_ref"], "stop-fixture",
                                                generation=stopped_export["generation"]), stopped_export)
        with self.assertRaises(FenceRefused):
            restarted.assert_current(exported)
        with self.assertRaises(FenceRefused):
            restarted.bind(exported, authorized=True)

    def test_task_identity_is_not_the_native_session_identity(self):
        row = self.fence.bind(grant(), authorized=True)
        self.assertNotEqual(row["task_fid"], row["execution_owner"].split("/")[1])
        self.assertEqual(row["task_fid"], TASK_FID)
        self.fence.assert_current(grant())

    def test_unknown_and_unapproved_never_adopt_legacy(self):
        self.assertIsNone(self.fence.read("T42"))
        for action in (lambda: self.fence.bind(grant()), lambda: self.fence.observe(grant()),
                       lambda: self.fence.assert_current(grant())):
            with self.assertRaises(FenceRefused):
                action()
        self.assertIsNone(self.fence.read("T42"))

    def test_stop_is_durable_idempotent_and_keeps_execution_target(self):
        original = self.fence.bind(grant(), authorized=True)
        stopped = self.fence.request_stop("T42", "stop-42", generation=2)
        self.assertEqual(stopped["generation"], 2)
        self.assertEqual(stopped["binding_generation"], 1)
        for field in ("task_fid", "attempt_id", "operation_id", "execution_endpoint", "execution_owner"):
            self.assertEqual(stopped[field], original[field])
        self.assertEqual(self.fence.request_stop("T42", "another-stop", generation=2), stopped)
        self.assertEqual(ExecutionFence(self.conf).read("T42"), stopped)
        with self.assertRaises(FenceRefused):
            self.fence.assert_current(grant())

    def test_stop_before_binding_persists_tombstone_and_refuses_delayed_start(self):
        stopped = self.fence.request_stop("T42", "stop-before-start", generation=2)
        self.assertEqual(stopped["generation"], 2)
        self.assertEqual(stopped["binding_generation"], 0)
        self.assertEqual(stopped["execution_owner"], "")
        restarted = ExecutionFence(self.conf)
        self.assertEqual(restarted.read("T42"), stopped)
        self.assertEqual(restarted.request_stop("T42", "repeat"), stopped)
        for older in (grant(), grant(generation=2), grant(generation=3)):
            with self.assertRaises(FenceRefused):
                restarted.observe(older)
        for older in (grant(), grant(generation=2)):
            with self.assertRaises(FenceRefused):
                restarted.bind(older, authorized=True)
        with self.assertRaises(FenceRefused):
            restarted.bind(grant(generation=3))
        restarted.bind(grant(generation=3), authorized=True)
        restarted.assert_current(grant(generation=3))

    def test_unknown_stop_requires_authoritative_generation(self):
        with self.assertRaises(FenceRefused):
            self.fence.request_stop("T42", "stop-before-start")
        self.assertIsNone(self.fence.read("T42"))

    def test_late_snapshot_cannot_clear_stop_or_replace_binding(self):
        self.fence.bind(grant(), authorized=True)
        stopped = self.fence.request_stop("T42", "stop-42", generation=2)
        for value in (grant(), grant(generation=2), grant(generation=2, execution_endpoint="node-b")):
            for action in (self.fence.observe, lambda v: self.fence.bind(v, authorized=True)):
                with self.assertRaises(FenceRefused):
                    action(value)
                self.assertEqual(self.fence.read("T42"), stopped)

    def test_new_grant_cannot_replace_known_execution_without_exit_proof(self):
        self.fence.bind(grant(), authorized=True)
        before_stop = self.fence.read("T42")
        with self.assertRaises(FenceRefused):
            self.fence.bind(grant(generation=2), authorized=True)
        self.assertEqual(self.fence.read("T42"), before_stop)
        stopped = self.fence.request_stop("T42", "stop-42", generation=2)
        for changes in ({}, dict(execution_endpoint="node-b"),
                        dict(execution_owner=FLEET + "/33333333-3333-4333-8333-333333333333")):
            newer = grant(generation=3, **changes)
            for action in (self.fence.observe, self.fence.bind,
                           lambda value: self.fence.bind(value, authorized=True)):
                with self.assertRaises(FenceRefused):
                    action(newer)
                self.assertEqual(self.fence.read("T42"), stopped)

    def test_observed_stop_preserves_known_binding(self):
        self.fence.bind(grant(), authorized=True)
        stopped_snapshot = grant(generation=2, cancel_request="hub-stop", task_fid="",
                                 attempt_id="", operation_id="", execution_endpoint="", execution_owner="")
        row = self.fence.observe(stopped_snapshot)
        self.assertEqual(row["cancel_request"], "hub-stop")
        self.assertEqual(row["attempt_id"], "task:T42:g1")
        self.assertEqual(row["execution_endpoint"], "node-a")
        self.assertEqual(row["execution_owner"], FLEET + "/" + FID)
        self.assertEqual(self.fence.observe(stopped_snapshot), row)

    def test_conflicting_binding_is_refused_even_with_authorized_flag(self):
        original = self.fence.bind(grant(), authorized=True)
        for changes in (dict(execution_endpoint="node-b"), dict(operation_id="competing-start"),
                        dict(task_fid="33333333-3333-4333-8333-333333333333",
                             execution_owner=FLEET + "/33333333-3333-4333-8333-333333333333")):
            with self.subTest(changes=changes):
                for action in (self.fence.observe, lambda v: self.fence.bind(v, authorized=True),
                               self.fence.assert_current):
                    with self.assertRaises(FenceRefused):
                        action(grant(**changes))
                self.assertEqual(self.fence.read("T42"), original)

    def test_invalid_authority_shape_never_writes(self):
        for changes in (dict(task_ref="../escape"), dict(generation=True), dict(generation=0),
                        dict(attempt_id="task:T42:g2"), dict(execution_owner="other"),
                        dict(task_fid="not-an-id"), dict(operation_id=""), dict(execution_endpoint="")):
            with self.subTest(changes=changes), self.assertRaises(FenceRefused):
                self.fence.bind(grant(**changes), authorized=True)
        self.assertEqual(self.fence.snapshot(), [])

    def test_stop_commit_and_sibling_admission_do_not_wait_for_task_admission(self):
        self.fence.bind(grant(), authorized=True)
        self.fence.bind(grant("T43"), authorized=True)
        ctx = multiprocessing.get_context("spawn")
        ready, release, stopped, sibling = (ctx.Event() for _ in range(4))
        held_result, stop_result, sibling_result = (ctx.Queue() for _ in range(3))
        children = [
            ctx.Process(target=hold_admission, args=(str(self.conf), grant(), ready, release, held_result)),
            ctx.Process(target=stop_while_held, args=(str(self.conf), ready, stopped, stop_result)),
            ctx.Process(target=admit_sibling, args=(str(self.conf), ready, sibling, sibling_result)),
        ]
        try:
            children[0].start()
            self.assertTrue(ready.wait(10), "admission did not enter")
            for child in children[1:]:
                child.start()
            self.assertTrue(stopped.wait(10), "stop blocked behind admission before DB commit")
            self.assertTrue(sibling.wait(10), "sibling task shared admission lock")
            self.assertEqual(stop_result.get(timeout=2), "stop-42")
            self.assertEqual(sibling_result.get(timeout=2), "sibling allowed")
            self.assertEqual(self.fence.read("T42")["cancel_request"], "stop-42")
            release.set()
            self.assertEqual(held_result.get(timeout=5), "refused")
        finally:
            release.set()
            for child in children:
                if child.pid is None:
                    continue
                child.join(5)
                if child.is_alive():
                    child.terminate()
                    child.join(5)
            for queue in (held_result, stop_result, sibling_result):
                queue.close()
        for child in children:
            self.assertEqual(child.exitcode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
