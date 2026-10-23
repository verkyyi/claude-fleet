#!/usr/bin/env python3
# selftest-entry
"""Controlled stop acceptance commits before locks or process cleanup."""
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

from fleet_control import Control
from fleet_hub_common import Fault
from fleet_task_execution import ExecutionFence, FenceRefused, claim_execution, validate_request

BIN = Path(__file__).resolve().parent
FIXTURE = json.loads((BIN.parent / "tokenledger/hub/store/testdata/task_execution.json").read_text())
FLEET = FIXTURE["execution_owner"].split("/")[0]
STOP_ID = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"


def stop_request():
    snapshot = dict(FIXTURE, generation=2, cancel_request=STOP_ID)
    return dict(operation_id=STOP_ID, fleet_id=FLEET, action="worker_stop", actor="fixture-owner",
                control_version=1, task_execution=snapshot,
                params=dict(task="T42", worker_id=FIXTURE["execution_owner"],
                            execution_endpoint=FIXTURE["execution_endpoint"],
                            start_operation_id=FIXTURE["operation_id"], generation=1,
                            attempt_id=FIXTURE["attempt_id"]))


class ControlExecutionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="task-control-")
        self.addCleanup(self.tmp.cleanup)
        self.control = Control(self.tmp.name)
        self.fence = ExecutionFence(self.tmp.name)

    def submit_without_executor(self, request):
        with patch("fleet_control.subprocess.Popen", return_value=Mock(wait=Mock(return_value=0))), \
                patch.object(self.control, "fleet", side_effect=AssertionError("stop waited for inventory")):
            return self.control.submit(request)

    def test_stop_receipt_and_fence_commit_before_admission_and_inventory(self):
        self.fence.bind(FIXTURE, authorized=True)
        done = threading.Event()
        results = []
        def submit():
            try:
                results.append(self.submit_without_executor(stop_request()))
            except Exception as exc:
                results.append(exc)
            finally:
                done.set()
        with self.assertRaises(FenceRefused), self.fence.admission(FIXTURE):
            thread = threading.Thread(target=submit)
            thread.start()
            self.assertTrue(done.wait(3), "stop blocked on launch admission or a nested DB transaction")
            thread.join(1)
            self.assertIsInstance(results[0], dict, results)
            self.assertEqual(results[0]["status"], "accepted")
            self.assertEqual(self.fence.read("T42")["cancel_request"], STOP_ID)
            with self.control.store.connect() as db:
                self.assertEqual(db.execute("SELECT status FROM operations WHERE id=?", (STOP_ID,)).fetchone()[0], "accepted")
        self.assertEqual(self.submit_without_executor(stop_request())["operation_id"], STOP_ID)

    def test_stop_before_any_binding_is_a_durable_unknown_tombstone(self):
        self.submit_without_executor(stop_request())
        row = ExecutionFence(self.tmp.name).read("T42")
        self.assertEqual(row["cancel_request"], STOP_ID)
        self.assertEqual(row["generation"], 2)
        self.assertEqual(row["binding_generation"], 1)
        self.assertEqual(row["execution_owner"], FIXTURE["execution_owner"])
        with self.assertRaises(FenceRefused):
            self.fence.bind(FIXTURE, authorized=True)

    def test_inconsistent_stop_envelope_has_no_side_effect(self):
        request = stop_request()
        request["task_execution"]["cancel_request"] = "another-stop"
        with self.assertRaises(Fault):
            self.submit_without_executor(request)
        self.assertIsNone(self.fence.read("T42"))
        with self.control.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM operations").fetchone()[0], 0)

    def test_stop_for_conflicting_binding_does_not_commit_receipt_or_fence(self):
        self.fence.bind(FIXTURE, authorized=True)
        changes = (
            ("operation_id", "other-start", "start_operation_id"),
            ("execution_endpoint", "other-node", "execution_endpoint"),
            ("execution_owner", FLEET + "/33333333-3333-4333-8333-333333333333", "worker_id"),
            ("attempt_id", "task:T42:g2", "attempt_id"),
        )
        for field, value, parameter in changes:
            with self.subTest(field=field):
                request = stop_request()
                request["task_execution"][field] = value
                request["params"][parameter] = value
                if field == "attempt_id":
                    request["task_execution"].update(generation=3, binding_generation=2)
                    request["params"]["generation"] = 2
                with self.assertRaises(FenceRefused):
                    self.submit_without_executor(request)
                self.assertEqual(self.fence.read("T42"), FIXTURE)
                with self.control.store.connect() as db:
                    self.assertEqual(db.execute("SELECT COUNT(*) FROM operations").fetchone()[0], 0)

    def test_authenticated_claim_uses_persistently_allocated_session_identity(self):
        reservation = dict(FIXTURE, execution_owner="")
        calls = []
        def call(task, body):
            calls.append((task, body))
            return dict(reservation, execution_owner=body["worker_id"])
        claimed = claim_execution(reservation, FLEET, conf_dir=self.tmp.name, call=call)
        self.assertNotEqual(claimed["execution_owner"].split("/")[1], claimed["task_fid"])
        self.assertEqual(claim_execution(reservation, FLEET, conf_dir=self.tmp.name, call=call), claimed)
        self.assertEqual(calls[0], calls[1])
        self.assertNotIn("execution_endpoint", calls[0][1])
        self.assertEqual(calls[0][1]["control_version"], 1)

    def test_stop_while_claim_is_in_flight_refuses_late_binding(self):
        reservation = dict(FIXTURE, execution_owner="")
        def call(task, body):
            self.fence.request_stop(task, STOP_ID, generation=2)
            return dict(reservation, execution_owner=body["worker_id"])
        with self.assertRaises(FenceRefused):
            claim_execution(reservation, FLEET, conf_dir=self.tmp.name, call=call)
        self.assertEqual(self.fence.read("T42")["cancel_request"], STOP_ID)

    def test_controlled_start_never_adopts_or_closes_a_wrong_receipt(self):
        for receipt in (b'@42\tscratch-1\t/work\n',
                        b'@42\tscratch-1\t/work\t33333333-3333-4333-8333-333333333333\n'):
            request = dict(operation_id=STOP_ID, fleet_id=FLEET, action='worker_start', actor='fixture',
                           params=dict(kind='scratch', task='T42', no_repo=True))
            with self.control.store.connect() as db:
                db.execute('INSERT OR REPLACE INTO operations VALUES (?,?,?,?,?,?,?,?,NULL)',
                           (STOP_ID,FLEET,'worker_start',json.dumps(request),'fixture','accepted',time.time(),time.time()))
            with patch('fleet_task_execution.validate_request',return_value=FIXTURE), \
                    patch('fleet_task_execution.claim_execution',return_value=FIXTURE), \
                    patch('fleet_dispatch.check_current'), \
                    patch.object(self.control,'fleet',return_value=dict(name='fixture')), \
                    patch.object(self.control,'adapter',return_value=(0,receipt,b'')) as adapter, \
                    patch.object(self.control,'workers',side_effect=AssertionError('receipt adopted a worker')):
                self.control.execute(STOP_ID)
            result=self.control.get_operation(STOP_ID)
            self.assertEqual(result['status'],'unknown')
            self.assertIn('authorized execution owner',str(result))
            self.assertEqual(adapter.call_count,1)
            self.assertEqual(adapter.call_args.args[0],'start')

    def test_legacy_operation_does_not_enroll_from_dispatch(self):
        self.assertIsNone(validate_request(dict(action="worker_start", params=dict(dispatch={"task": "T42"}))))

    def stop_executor_fixture(self):
        """Real detached executor, with only the final window adapter replaced."""
        directory = Path(self.tmp.name) / "fake-bin"
        directory.mkdir()
        (directory / "fleet-control.py").write_text('''import os,sys,time
from pathlib import Path
sys.path.insert(0, %r)
from fleet_control import Control, Fault
import fleet_session_gate
fleet_session_gate.revoke_task_work = lambda fid: None
class FixtureControl(Control):
    def fleet(self, fleet_id): return {"name": "fixture"}
    def execute_worker(self, fleet, action, params, actor=""):
        root = self.conf_dir / "control"
        with (root / "cleanup.calls").open("a") as out: out.write(str(os.getpid()) + "\\n")
        while (root / "cleanup.block").exists(): time.sleep(.02)
        if (root / "cleanup.fail").exists():
            (root / "cleanup.fail").unlink()
            raise Fault("UNKNOWN_OUTCOME", "fixture close failed")
        return {"fixture_cleanup": True}
FixtureControl(sys.argv[2]).execute(sys.argv[4])
''' % str(BIN))
        self.control.bin = directory
        return Path(self.tmp.name) / "control"

    def wait_stop(self, predicate, message):
        deadline = time.monotonic() + 8
        while not predicate():
            self.assertLess(time.monotonic(), deadline, message)
            time.sleep(.02)

    def test_canonical_stop_redelivery_retries_failed_and_successful_cleanup(self):
        root = self.stop_executor_fixture()
        (root / "cleanup.fail").touch()
        request = stop_request()
        self.control.submit(request)
        self.wait_stop(lambda: self.control.get_operation(STOP_ID)["status"] == "unknown", "first cleanup did not fail")
        self.assertEqual(self.fence.read("T42")["cancel_request"], STOP_ID)
        for count in (2, 3):
            self.control.submit(request)
            self.wait_stop(lambda: self.control.get_operation(STOP_ID)["status"] == "succeeded", "canonical stop did not retry")
            self.assertEqual(len((root / "cleanup.calls").read_text().splitlines()), count)
            result = self.control.get_operation(STOP_ID)["result"]
            self.assertEqual(result["execution_exit"], "unproven")
        with self.control.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM operations").fetchone()[0], 1)

    def test_stop_survives_executor_launch_failure_and_retries(self):
        self.stop_executor_fixture()
        with patch("fleet_control.subprocess.Popen", side_effect=OSError("fixture cannot launch")):
            receipt = self.control.submit(stop_request())
        self.assertEqual(receipt["status"], "accepted")
        self.assertEqual(self.fence.read("T42")["cancel_request"], STOP_ID)
        self.control.submit(stop_request())
        self.wait_stop(lambda: self.control.get_operation(STOP_ID)["status"] == "succeeded", "accepted stop did not retry")

    def test_stop_replay_does_not_run_parallel_cleanup_and_recovers_executor_death(self):
        root = self.stop_executor_fixture()
        (root / "cleanup.block").touch()
        spawned = []
        real_popen = subprocess.Popen
        def launch(*args, **kwargs):
            child = real_popen(*args, **kwargs)
            spawned.append(child)
            return child
        def cleanup():
            for child in spawned:
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=3)
        self.addCleanup(cleanup)
        with patch("fleet_control.subprocess.Popen", side_effect=launch):
            self.control.submit(stop_request())
            self.wait_stop(lambda: (root / "cleanup.calls").exists(), "first executor did not enter cleanup")
            self.control.submit(stop_request())
            spawned[1].wait(timeout=5)
            self.assertIsNone(spawned[0].poll())
            self.assertEqual(len((root / "cleanup.calls").read_text().splitlines()), 1)
            spawned[0].kill()
            spawned[0].wait(timeout=5)
            (root / "cleanup.block").unlink()
            self.control.submit(stop_request())
            self.wait_stop(lambda: self.control.get_operation(STOP_ID)["status"] == "succeeded", "replay did not recover crashed executor")
            self.assertEqual(len((root / "cleanup.calls").read_text().splitlines()), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
