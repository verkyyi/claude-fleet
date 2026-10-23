#!/usr/bin/env python3
# selftest-entry
"""Durable native exit submission survives retries without replaying cleanup."""
import fcntl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

from fleet_control import Control
from fleet_hub_common import Fault, canonical
from fleet_task_execution import _kernel_process

BIN = Path(__file__).resolve().parent
GRANT = json.loads((BIN.parent / "tokenledger/hub/store/testdata/task_execution.json").read_text())
STOP = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"


def request():
    return dict(operation_id=STOP, fleet_id=GRANT["execution_owner"].split("/")[0],
                action="worker_stop", actor="fixture", control_version=1,
                task_execution=dict(GRANT, generation=2, cancel_request=STOP),
                params=dict(task="T42", worker_id=GRANT["execution_owner"],
                            execution_endpoint=GRANT["execution_endpoint"],
                            start_operation_id=GRANT["operation_id"], generation=1,
                            attempt_id=GRANT["attempt_id"]))


def ack():
    return dict(control_version=1, scope="native_session", execution_exit_confirmed=True,
                operation=dict(operation_id="bbbbbbbb-1111-4111-8111-aaaaaaaaaaaa",
                               action="task_session_exit", status="succeeded"))


class ExitSubmitTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="task-exit-submit-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.control = Control(self.root)

    def submit(self):
        with patch("fleet_control.subprocess.Popen", return_value=Mock(wait=Mock(return_value=0))):
            return self.control.submit(request())

    def register(self, components=("server", "client"), live=False):
        self.control.execution.bind(GRANT, authorized=True)
        proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        def cleanup():
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=5)
        self.addCleanup(cleanup)
        proof = _kernel_process(proc.pid)
        with self.control.execution.admission(GRANT) as permit:
            permit.reserve_launch("launch-one", proof, wrapper=_kernel_process(os.getpid()))
            permit.register_child("launch-one", proof)
            for component in components:
                permit.register_native("launch-one", component, proof)
        if not live:
            cleanup()
        self.submit()

    def private(self):
        with self.control.store.connect() as db:
            row = db.execute("SELECT result FROM operations WHERE id=?", (STOP,)).fetchone()
        return json.loads(row[0] or "{}")

    def test_crash_after_proof_and_lost_ack_replay_exact_original_payload(self):
        self.register()
        crashed = subprocess.run([sys.executable, "-c", "import os,sys; sys.path.insert(0,sys.argv[1]); "
                                  "from fleet_control import Control; Control(sys.argv[2]).prepare_native_exit(sys.argv[3]); os._exit(9)",
                                  str(BIN), str(self.root), STOP], timeout=5, capture_output=True)
        self.assertEqual(crashed.returncode, 9, crashed.stderr)
        payload = self.private()["native_exit_receipt"]["payload"]
        # Restart after the durable proof commit, before any send.
        restarted = Control(self.root)
        sent = []
        def transport(task, body, timeout):
            self.assertEqual(task, "T42")
            sent.append(canonical(body))
            if len(sent) == 1:
                raise Fault("TIMEOUT", "Hub accepted; response lost")
            return ack()
        with patch.object(restarted, "send_native_exit", side_effect=transport), \
                patch("fleet_task_execution.prove_native_session_exit", side_effect=AssertionError("proof regenerated")), \
                patch.object(restarted, "_execute_once", side_effect=AssertionError("cleanup replayed")):
            self.assertFalse(restarted.submit_native_exit(STOP))
            self.assertTrue(restarted.submit_native_exit(STOP))
        self.assertEqual(sent, [canonical(payload)] * 2)
        self.assertTrue(self.private()["native_exit_receipt"]["confirmed"])
        self.assertEqual(self.control.execution.read("T42"), request()["task_execution"])

    def test_stop_redelivery_finish_and_timing_preserve_private_packet(self):
        self.register()
        payload = self.control.prepare_native_exit(STOP)
        self.submit()
        self.control.finish(STOP, "failed", {"error": {"code": "NOT_FOUND"}})
        self.control.stamp_timing(STOP, t_ready=123)
        self.assertEqual(self.submit()["status"], "failed")
        self.assertEqual(self.private()["native_exit_receipt"]["payload"], payload)
        self.assertEqual(self.private()["timing"], {"t_ready": 123})

    def test_proof_after_interrupted_cleanup_keeps_existing_unknown_semantics(self):
        self.register()
        self.control.prepare_native_exit(STOP)
        # A scan may prove exit before a detached cleanup starts, or after it
        # dies while running. Existing operation_get ages those outcomes to
        # unknown; replay must not restart its clock or invent cleanup success.
        for state in ("accepted", "running"):
            with self.control.store.connect() as db:
                db.execute("UPDATE operations SET status=?,updated=? WHERE id=?", (state,time.time()-241,STOP))
            self.assertEqual(self.submit()["status"], "unknown")
            with patch.object(self.control, "_execute_once", side_effect=AssertionError("cleanup replayed")), \
                    patch.object(self.control, "send_native_exit", return_value=ack()):
                self.control.execute(STOP)
            self.assertEqual(self.control.get_operation(STOP)["status"], "unknown")
            self.assertEqual(self.control.get_operation(STOP)["result"]["execution_exit"], "confirmed")

    def test_missing_partial_and_live_registration_never_send(self):
        for components, live in (((), False), (("server",), False), (("server", "client"), True)):
            with self.subTest(components=components, live=live), tempfile.TemporaryDirectory() as root:
                self.root, self.control = Path(root), Control(root)
                self.register(components, live)
                with patch.object(self.control, "send_native_exit", side_effect=AssertionError("unproven sent")):
                    self.assertFalse(self.control.submit_native_exit(STOP))
                self.assertNotIn("payload", self.private().get("native_exit_receipt", {}))
                self.assertEqual(self.private()["execution_exit"], "unproven")

    def test_missing_launch_and_database_failure_never_send(self):
        self.submit()
        with patch.object(self.control, "send_native_exit", side_effect=AssertionError("unknown proof sent")):
            self.assertFalse(self.control.submit_native_exit(STOP))
            with patch.object(self.control.store, "connect", side_effect=sqlite3.OperationalError("fixture unavailable")):
                self.assertFalse(self.control.submit_native_exit(STOP))
        self.assertNotIn("payload", self.private()["native_exit_receipt"])

    def test_complete_claude_registration_selects_claude(self):
        self.register(("agent",))
        self.assertEqual(self.control.prepare_native_exit(STOP)["proof"]["provider"], "claude")

    def test_missing_window_does_not_skip_proof_and_network_is_outside_locks(self):
        self.register()
        def transport(task, body, timeout):
            with self.control.store.connect() as db:
                db.execute("BEGIN IMMEDIATE")
            with self.control.execution._admission_lock("T42"):
                pass
            with (self.root / "control/stop-execution" / (STOP+".lock")).open() as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return ack()
        with patch.object(self.control, "fleet", side_effect=Fault("NOT_FOUND", "window gone")), \
                patch("fleet_session_gate.revoke_task_work"), \
                patch.object(self.control, "send_native_exit", side_effect=transport):
            self.control.execute(STOP)
        self.assertEqual(self.control.get_operation(STOP)["status"], "failed")
        self.assertEqual(self.control.get_operation(STOP)["result"]["execution_exit"], "confirmed")

    def test_concurrent_proof_finish_timing_and_ack_preserve_original(self):
        self.register()
        from fleet_task_execution import prove_native_session_exit
        original = prove_native_session_exit(request()["task_execution"], "codex", conf_dir=self.root)
        barrier = threading.Barrier(2)
        def observe(*args, **kwargs):
            # Model two completed observations racing to persist. Concurrent
            # admission probes themselves may legitimately return busy.
            proof = dict(original, observed_at=time.time())
            barrier.wait(timeout=3)
            return proof
        packets, errors = [], []
        def prepare():
            try:
                packets.append(self.control.prepare_native_exit(STOP))
            except Exception as exc:
                errors.append(exc)
        with patch("fleet_task_execution.prove_native_session_exit", side_effect=observe):
            threads = [threading.Thread(target=prepare) for _ in range(2)]
            for thread in threads: thread.start()
            for thread in threads: thread.join(timeout=5)
        self.assertFalse(errors)
        self.assertEqual(len(packets), 2)
        self.assertEqual(packets[0], packets[1])
        barrier = threading.Barrier(3)
        def mutate(kind):
            try:
                barrier.wait(timeout=3)
                if kind == 0: self.control.finish(STOP, "failed", {"error": {"code": "NOT_FOUND"}})
                elif kind == 1: self.control.stamp_timing(STOP, t_ready=123)
                else: self.assertTrue(self.control.submit_native_exit(STOP))
            except Exception as exc: errors.append(exc)
        with patch.object(self.control, "send_native_exit", return_value=ack()):
            threads = [threading.Thread(target=mutate, args=(i,)) for i in range(3)]
            for thread in threads: thread.start()
            for thread in threads: thread.join(timeout=5)
        self.assertFalse(errors)
        result = self.private()
        self.assertEqual(result["native_exit_receipt"]["payload"], packets[0])
        self.assertTrue(result["native_exit_receipt"]["confirmed"])
        self.assertEqual(result["timing"], {"t_ready": 123})

    def test_new_binding_only_replays_old_packet_without_fence_or_cleanup(self):
        self.register()
        payload = self.control.prepare_native_exit(STOP)
        # Simulate a newer binding after the Hub accepted the old receipt but
        # the node lost its ACK. No resume API is added by this slice.
        with self.control.store.connect() as db:
            db.execute("UPDATE task_execution_fences SET generation=3,cancel_request='',operation_id='new-start' WHERE task_ref='T42'")
        newer = self.control.execution.read("T42")
        with patch.object(self.control.execution, "launch", side_effect=AssertionError("current binding read")), \
                patch.object(self.control.execution, "apply_stop", side_effect=AssertionError("old fence applied")), \
                patch.object(self.control, "_execute_once", side_effect=AssertionError("stop replayed")), \
                patch.object(self.control, "send_native_exit", return_value=ack()) as send:
            self.assertEqual(self.control.retry_native_exits(), 1)
        self.assertEqual(send.call_args.args[:2], ("T42", payload))
        self.assertEqual(self.control.execution.read("T42"), newer)

    def test_bad_ack_keeps_original_and_confirmed_replay_stays_confirmed(self):
        self.register()
        payload = self.control.prepare_native_exit(STOP)
        bad = ack()
        bad["scope"] = "all_descendants"
        with patch.object(self.control, "send_native_exit", return_value=bad):
            self.assertFalse(self.control.submit_native_exit(STOP))
        self.assertEqual(self.private()["native_exit_receipt"]["payload"], payload)
        with patch.object(self.control, "send_native_exit", return_value=ack()):
            self.assertTrue(self.control.submit_native_exit(STOP))
        self.submit()
        self.control.finish(STOP, "failed", {"error": {"code": "NOT_FOUND"}})
        with patch.object(self.control, "send_native_exit", side_effect=AssertionError("confirmed sent again")):
            self.assertTrue(self.control.submit_native_exit(STOP))
            self.assertEqual(self.control.retry_native_exits(), 0)
        self.assertEqual(self.control.get_operation(STOP)["result"]["execution_exit"], "confirmed")

    def test_retry_scan_has_bounded_count_and_no_legacy_mutation(self):
        with self.control.store.connect() as db:
            db.execute("INSERT INTO operations VALUES (?,?,?,?,?,?,?,?,NULL)",
                       (STOP, request()["fleet_id"], "worker_stop", canonical(dict(action="worker_stop", params={})),
                        "fixture", "failed", 1, 1))
        before = self.control.store.path.read_bytes()
        with patch.object(self.control, "send_native_exit", side_effect=AssertionError("legacy network")):
            self.assertEqual(self.control.retry_native_exits(), 0)
        self.assertEqual(self.control.store.path.read_bytes(), before)
        with self.control.store.connect() as db:
            db.execute("DELETE FROM operations")
        self.submit()
        with patch.object(self.control, "submit_native_exit", return_value=False) as send:
            self.assertEqual(self.control.retry_native_exits(limit=0), 0)
            self.assertEqual(self.control.retry_native_exits(budget=0), 0)
            send.assert_not_called()
            self.assertEqual(self.control.retry_native_exits(limit=1), 1)
            send.assert_called_once()

    def test_real_http_large_body_auth_pipe_and_lost_ack(self):
        self.register()
        payload = self.control.prepare_native_exit(STOP)
        current = payload["proof"]["launches"][0]
        payload["proof"]["launches"] = [dict(current, launch_id="history-%d" % i) for i in range(700)] + [current]
        raw = canonical(payload).encode()
        self.assertGreater(len(raw), 128<<10)
        self.assertLess(len(raw), 1<<20)
        with self.control.store.connect() as db:
            result = self.private()
            result["native_exit_receipt"]["payload"] = payload
            db.execute("UPDATE operations SET result=? WHERE id=?", (canonical(result), STOP))
        public = canonical(self.control.get_operation(STOP))
        self.assertLess(len(public), 2048)
        self.assertNotIn("launches", public)
        self.assertNotIn("native_exit_receipt", public)
        received = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                received.append((self.path, self.headers.get("Authorization"), body))
                if len(received) == 1:
                    self.close_connection = True  # accepted by fake Hub, ACK lost
                    return
                self.send_response(200)
                self.end_headers()
                self.wfile.write(canonical(ack()).encode())
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        (self.root / "node.env").write_text("CCQUOTA_HUB_URL=http://127.0.0.1:%d\nCCQUOTA_TOKEN=fixture-only-node\n" % server.server_port)
        env = self.control.environment()
        env.update(HOME=str(self.root), FLEET_CONF_DIR=str(self.root), CCQUOTA_NODE_KEY="off", CCQUOTA_HUB_SOCK="off")
        with patch.object(self.control, "environment", return_value=env), \
                patch("fleet_task_execution.prove_native_session_exit", side_effect=AssertionError("large packet regenerated")):
            self.assertFalse(self.control.submit_native_exit(STOP))
            self.assertTrue(self.control.submit_native_exit(STOP))
        self.assertEqual(received, [("/v1/node/tasks/T42/execution/exit", "Bearer fixture-only-node", raw)]*2)


if __name__ == "__main__":
    unittest.main()
