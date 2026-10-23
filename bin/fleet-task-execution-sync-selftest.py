#!/usr/bin/env python3
# selftest-entry
"""Reconnect imports stops before controlled side effects; legacy stays offline."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import fleet_task_execution as execution
from fleet_task_execution import ExecutionFence, FenceRefused, claim_execution, refresh_session, sync_stops

BIN = Path(__file__).resolve().parent
FIXTURE = json.loads((BIN.parent / "tokenledger/hub/store/testdata/task_execution.json").read_text())
FLEET, FID = FIXTURE["execution_owner"].split("/")


def listed(*rows):
    return dict(control_version=1, task_executions=list(rows))


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="task-execution-sync-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.conf = self.root / "conf"
        self.fence = ExecutionFence(self.conf)
        self.stop = dict(FIXTURE, generation=2, cancel_request="canonical-stop")

    def assert_network_unlocked(self):
        # A distinct DB connection and lock fd must both acquire immediately.
        with sqlite3.connect(self.fence.store.path, timeout=.01) as db:
            db.execute("BEGIN IMMEDIATE")
            db.rollback()
        path = self.conf / "control/task-admission/T42.lock"
        with path.open("a+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)

    def no_allocations(self):
        with self.fence.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM task_execution_sessions").fetchone()[0], 0)

    def test_claim_imports_stop_before_allocation_or_remote_claim(self):
        original = ExecutionFence.allocate_worker
        def allocate_after_sync(fence, snapshot, fleet):
            self.assertEqual(fence.read("T42"), self.stop)
            return original(fence, snapshot, fleet)
        with patch.object(ExecutionFence, "allocate_worker", autospec=True, side_effect=allocate_after_sync) as allocate:
            with self.assertRaises(FenceRefused):
                claim_execution(dict(FIXTURE, execution_owner=""), FLEET, conf_dir=self.conf,
                                read_stops=lambda: listed(self.stop), call=lambda *_: self.fail("remote claim"))
            allocate.assert_called_once()
        self.assertEqual(self.fence.read("T42"), self.stop)
        self.no_allocations()

    def test_claim_sync_transport_failure_precedes_local_allocation(self):
        def offline():
            self.assert_network_unlocked()
            raise FenceRefused("offline")
        with self.assertRaises(FenceRefused):
            claim_execution(dict(FIXTURE, execution_owner=""), FLEET, conf_dir=self.conf,
                            read_stops=offline, call=lambda *_: self.fail("remote claim"))
        self.no_allocations()
        self.assertIsNone(self.fence.read("T42"))

    def test_claim_validation_precedes_sync_and_default_transport_is_not_bypassed(self):
        with patch.object(execution, "_authority", side_effect=FenceRefused("offline")) as read:
            with self.assertRaises(FenceRefused):
                claim_execution(self.stop, FLEET, conf_dir=self.conf)
            read.assert_not_called()
            with self.assertRaises(FenceRefused):
                claim_execution(dict(FIXTURE, execution_owner=""), FLEET, conf_dir=self.conf,
                                call=lambda *_: self.fail("claim callback cannot bypass sync"))
            self.assertEqual(read.call_args.args, ("execution-list",))
        self.no_allocations()

    def test_claim_transport_callbacks_hold_no_db_or_admission_lock(self):
        order = []
        reservation = dict(FIXTURE, execution_owner="")
        def read():
            self.assert_network_unlocked()
            self.no_allocations()
            order.append("sync")
            return listed(reservation)
        def claim(task, body):
            self.assert_network_unlocked()
            order.append("claim")
            return dict(reservation, execution_owner=body["worker_id"])
        result = claim_execution(reservation, FLEET, conf_dir=self.conf, read_stops=read, call=claim)
        self.assertEqual(order, ["sync", "claim"])
        self.assertEqual(self.fence.read("T42"), result)

    def test_legacy_refresh_never_networks_or_creates_state(self):
        missing = self.root / "legacy"
        with patch.object(execution, "_authority", side_effect=AssertionError("legacy network")):
            self.assertIsNone(refresh_session(FID, conf_dir=missing))
        self.assertFalse(missing.exists())

    def test_controlled_refresh_rechecks_imported_stop_before_task_get(self):
        self.fence.bind(FIXTURE, authorized=True)
        with self.assertRaises(FenceRefused):
            refresh_session(FID, conf_dir=self.conf, expected=FIXTURE, read_stops=lambda: listed(self.stop),
                            read=lambda _: self.fail("active GET cannot override imported stop"))
        self.assertEqual(self.fence.read("T42"), self.stop)

    def test_refresh_default_transport_syncs_then_gets_without_locks(self):
        self.fence.bind(FIXTURE, authorized=True)
        other_stop = dict(self.stop, task_ref="T43", task_fid="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                          attempt_id="task:T43:g1", execution_owner=FLEET + "/33333333-3333-4333-8333-333333333333")
        order = []
        def transport(command, *args, **kwargs):
            self.assert_network_unlocked()
            order.append(command)
            if command == "execution-list":
                return listed(FIXTURE, other_stop)
            self.assertEqual(args, ("T42",))
            self.assertEqual(self.fence.read("T43"), other_stop)
            return FIXTURE
        with patch.object(execution, "_authority", side_effect=transport):
            self.assertEqual(refresh_session(FID, conf_dir=self.conf, expected=FIXTURE), FIXTURE)
        self.assertEqual(order, ["execution-list", "execution-get"])

    def test_refresh_sync_failure_never_reaches_single_task_get(self):
        self.fence.bind(FIXTURE, authorized=True)
        with patch.object(execution, "_authority", side_effect=FenceRefused("offline")) as network:
            with self.assertRaises(FenceRefused):
                refresh_session(FID, conf_dir=self.conf, read=lambda _: self.fail("GET after failed sync"))
            network.assert_called_once_with("execution-list", conf_dir=self.conf)
        self.assertEqual(self.fence.read("T42"), FIXTURE)

    def test_sync_imports_only_stops_and_never_clears_tombstone(self):
        self.fence.apply_stop(self.stop)
        other = dict(FIXTURE, task_ref="T43", attempt_id="task:T43:g1")
        self.assertEqual(sync_stops(conf_dir=self.conf, read=lambda: listed(FIXTURE, other)), [])
        self.assertEqual(self.fence.read("T42"), self.stop)
        self.assertIsNone(self.fence.read("T43"))
        with self.assertRaises(FenceRefused):
            refresh_session(FID, conf_dir=self.conf, read_stops=lambda: self.fail("known stop need not network"))

    def test_malformed_sync_response_is_not_success(self):
        for response in ({}, listed(dict(self.stop, generation=0)), dict(control_version=True, task_executions=[])):
            with self.subTest(response=response), self.assertRaises(FenceRefused):
                sync_stops(conf_dir=self.conf, read=lambda: response)
        self.assertEqual(self.fence.snapshot(), [])

    def test_unreadable_sync_store_refuses_before_any_start(self):
        for kind in ("corrupt", "directory"):
            with self.subTest(kind=kind):
                conf = self.root / kind
                control = conf / "control"
                control.mkdir(parents=True)
                db = control / "state.sqlite3"
                if kind == "corrupt":
                    db.write_bytes(b"not a sqlite database")
                else:
                    db.mkdir()
                with self.assertRaises(FenceRefused):
                    claim_execution(dict(FIXTURE, execution_owner=""), FLEET, conf_dir=conf,
                                    read_stops=lambda: listed(self.stop),
                                    call=lambda *_: self.fail("claim after unavailable local stop store"))

    def test_default_transport_timeout_refuses_instead_of_bypassing(self):
        with patch.object(execution.subprocess, "run", side_effect=subprocess.TimeoutExpired("transport", 15)):
            with self.assertRaises(FenceRefused):
                claim_execution(dict(FIXTURE, execution_owner=""), FLEET, conf_dir=self.conf)
        self.no_allocations()

    def test_shell_reconnect_command_uses_same_sync_and_only_declares_sync(self):
        scripts = self.root / "bin"
        scripts.mkdir()
        for name in ("fleet-hub-node.sh", "fleet_task_execution.py", "fleet_hub_common.py"):
            shutil.copy2(BIN / name, scripts / name)
        (scripts / "fleet-lib.sh").write_text("""fleet_hub_outbox() { printf '/fixture/outbox'; }
fleet_hub_cache() { printf '/fixture/workers'; }
fleet_hub_movein() { printf '/fixture/movein'; }
fleet_hub_attach() { printf '/fixture/attach'; }
""")
        authority = self.root / "authority.json"
        authority.write_text(json.dumps(listed(self.stop)))
        (scripts / "fleet-task-record.sh").write_text('''[ "$1" = execution-list ] || exit 41
[ "${SYNC_OFFLINE:-0}" = 0 ] || exit 42
cat "$SYNC_RESPONSE"
''')
        env = dict(os.environ, HOME=str(self.root), FLEET_CONF_DIR=str(self.conf), SYNC_RESPONSE=str(authority))
        command = ["bash", str(scripts / "fleet-hub-node.sh")]
        paths = subprocess.run(command + ["paths"], env=env, capture_output=True, text=True, check=True).stdout
        self.assertIn("execution_sync\t1\n", paths)
        self.assertNotIn("task_execution_v1", paths)
        result = subprocess.run(command + ["execution-sync"], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [self.stop])
        self.assertEqual(self.fence.read("T42"), self.stop)
        failed = subprocess.run(command + ["execution-sync"], env=dict(env, SYNC_OFFLINE="1"), capture_output=True, text=True)
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(self.fence.read("T42"), self.stop)
        bad_args = subprocess.run(command + ["execution-sync", "unexpected"], env=env, capture_output=True, text=True)
        self.assertEqual(bad_args.returncode, 2)


if __name__ == "__main__":
    unittest.main()
