#!/usr/bin/env python3
# selftest-entry
"""Read-only native-session exit proof: no admission or empty-registration guesses."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import fleet_task_execution as execution
import fleet_native_proc as native_proc
from fleet_task_execution import ExecutionFence, FenceRefused, prove_native_session_exit


class SessionExitTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="task-session-exit-")
        self.addCleanup(self.tmp.cleanup)
        self.conf = Path(self.tmp.name)
        self.fence = ExecutionFence(self.conf)
        fixture = Path(__file__).resolve().parents[1] / "tokenledger/hub/store/testdata/task_execution.json"
        self.grant = self.fence.bind(json.loads(fixture.read_text()), authorized=True)
        self.wrapper = execution._kernel_process(os.getpid())
        self.proofs = {name:dict(pid=90000000 + n, birth="Fri Oct 23 01:02:03 2026:" +
                                ("1700000000:" + str(n) if sys.platform == "darwin" else str(1000 + n)))
                       for n, name in enumerate(("supervisor", "child", "server", "client", "agent"), 1)}

    def register(self, provider="codex", *, components=None, child=True):
        if components is None:
            components = ("server", "client") if provider == "codex" else ("agent",)
        with self.fence.admission(self.grant) as permit:
            permit.reserve_launch("launch-current", self.proofs["supervisor"], wrapper=self.wrapper)
            if child:
                permit.register_child("launch-current", self.proofs["child"])
            for component in components:
                permit.register_native("launch-current", component, self.proofs[component])
        self.stop = self.fence.request_stop("T42", "stop-42", generation=2)

    def prove(self, provider="codex", expected=None):
        return prove_native_session_exit(expected or self.stop, provider, conf_dir=self.conf)

    def absent(self):
        return patch.object(execution.os, "kill", side_effect=ProcessLookupError)

    def test_complete_codex_proof_is_read_only_and_retains_live_wrapper(self):
        self.register()
        before = self.fence.store.path.read_bytes()
        files = sorted(p.relative_to(self.conf) for p in self.conf.rglob("*"))
        with self.absent() as probe, patch.object(execution, "_authority", side_effect=AssertionError("network")):
            result = self.prove()
        self.assertEqual(result["scope"], "native_session")
        self.assertEqual(result["snapshot"], self.stop)
        self.assertEqual(result["wrapper"], self.wrapper)
        self.assertEqual(result["launch_id"], "launch-current")
        self.assertEqual({r["component"] for r in result["launches"][0]["roots"]},
                         {"supervisor", "child", "server", "client"})
        self.assertEqual([call.args[1] for call in probe.call_args_list], [0] * 4)
        self.assertNotIn(self.wrapper["pid"], [call.args[0] for call in probe.call_args_list])
        self.assertEqual(self.fence.store.path.read_bytes(), before)
        self.assertEqual(sorted(p.relative_to(self.conf) for p in self.conf.rglob("*")), files)
        self.assertEqual(self.fence.read("T42"), self.stop)
        with self.assertRaises(FenceRefused):
            self.fence.assert_current(self.grant)

    def test_claude_requires_agent_and_codex_requires_both_native_roots(self):
        self.register("claude")
        with self.absent():
            self.assertEqual(self.prove("claude")["provider"], "claude")
            with self.assertRaises(FenceRefused):
                self.prove("codex")

    def test_empty_partial_and_missing_child_registrations_are_not_exit(self):
        for components, child in (((), True), (("server",), True), (("client",), True), (("server", "client"), False)):
            with self.subTest(components=components, child=child):
                with self.fence.store.connect() as db:
                    db.execute("DELETE FROM task_execution_native")
                    db.execute("DELETE FROM task_execution_launches")
                    db.execute("DELETE FROM task_execution_fences")
                self.fence.bind(self.grant, authorized=True)
                self.register(components=components, child=child)
                with self.absent(), self.assertRaises(FenceRefused):
                    self.prove()

    def test_stop_before_start_has_no_positive_proof(self):
        self.stop = self.fence.request_stop("T42", "stop-42", generation=2)
        with self.absent(), self.assertRaises(FenceRefused):
            self.prove()

    def test_each_registered_root_must_exit(self):
        self.register()
        for component in ("supervisor", "child", "server", "client"):
            proof = self.proofs[component]
            def exists(pid, sig):
                if pid != proof["pid"]:
                    raise ProcessLookupError
            with self.subTest(component=component), patch.object(execution.os, "kill", side_effect=exists), \
                    patch.object(native_proc, "kernel_identity", return_value=dict(pid=proof["pid"],
                                 birth_token=native_proc.birth_token(proof["birth"]), state="R")), self.assertRaises(FenceRefused):
                self.prove()

    def test_pid_reuse_is_exit_of_old_identity_and_never_signals_replacement(self):
        self.register()
        with patch.object(execution.os, "kill") as probe, \
                patch.object(native_proc, "kernel_identity", side_effect=lambda pid: dict(pid=pid, birth_token="99", state="R")):
            result = self.prove()
        self.assertTrue(all(r["evidence"] == "pid_reused" for r in result["launches"][0]["roots"]))
        self.assertTrue(all(call.args[1] == 0 for call in probe.call_args_list))

    def test_permission_or_unreadable_birth_is_unproven(self):
        self.register()
        with patch.object(execution.os, "kill", side_effect=PermissionError), self.assertRaises(FenceRefused):
            self.prove()
        for failure in (PermissionError(), ValueError("unreadable birth"), subprocess.TimeoutExpired("ps", 3)):
            with self.subTest(failure=type(failure).__name__), patch.object(execution.os, "kill"), \
                    patch.object(native_proc, "kernel_identity", side_effect=failure), self.assertRaises(FenceRefused):
                self.prove()

    def test_stop_snapshot_must_match_every_field(self):
        self.register()
        changes = dict(generation=3, cancel_request="other-stop", execution_endpoint="other-node",
                       operation_id="other-start", execution_owner="11111111-1111-4111-8111-111111111111/33333333-3333-4333-8333-333333333333",
                       task_fid="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", attempt_id="task:T42:g2", binding_generation=2)
        for key, value in changes.items():
            expected = dict(self.stop, **{key:value})
            with self.subTest(key=key), self.absent(), self.assertRaises(FenceRefused):
                self.prove(expected=expected)
        with self.absent(), self.assertRaises(FenceRefused):
            self.prove(expected=self.grant)

    def test_inflight_admission_returns_promptly_without_process_observation(self):
        self.register()
        with self.fence._admission_lock("T42"), patch.object(execution, "_exited_session_root") as probe:
            started = time.monotonic()
            with self.assertRaises(FenceRefused):
                self.prove()
            self.assertLess(time.monotonic() - started, .5)
            probe.assert_not_called()

    def test_process_reads_are_outside_lock_and_final_barrier_rechecks_stop(self):
        self.register()
        def observe(proof):
            # A separate open proves the first lock was released, rather than
            # relying on thread-local/reentrant behavior of the same fd.
            path = self.conf / "control/task-admission/T42.lock"
            with path.open() as lock:
                execution.fcntl.flock(lock.fileno(), execution.fcntl.LOCK_EX | execution.fcntl.LOCK_NB)
            self.fence.request_stop("T42", "stop-42", generation=3)
            return dict(proof, evidence="pid_absent")
        with patch.object(execution, "_exited_session_root", side_effect=observe), self.assertRaises(FenceRefused):
            self.prove()
        self.assertEqual(self.fence.read("T42")["generation"], 3)

    def test_final_barrier_rejects_registration_change(self):
        self.register()
        def observe(proof):
            with self.fence.store.connect() as db:
                db.execute("UPDATE task_execution_launches SET supervisor=?", (json.dumps(dict(pid=99, birth="changed")),))
            return dict(proof, evidence="pid_absent")
        with patch.object(execution, "_exited_session_root", side_effect=observe), self.assertRaises(FenceRefused):
            self.prove()

    def test_missing_lock_and_database_do_not_create_state(self):
        self.register()
        lock = self.conf / "control/task-admission/T42.lock"
        lock.unlink()
        with self.assertRaises(FenceRefused):
            self.prove()
        self.assertFalse(lock.exists())
        missing = self.conf / "missing"
        with self.assertRaises(FenceRefused):
            prove_native_session_exit(self.stop, "codex", conf_dir=missing)
        self.assertFalse(missing.exists())

    def test_corrupt_database_and_registration_are_unproven(self):
        self.register()
        with self.fence.store.connect() as db:
            db.execute("UPDATE task_execution_native SET process='not-json'")
        with self.absent(), self.assertRaises(FenceRefused):
            self.prove()
        self.fence.store.path.write_bytes(b"not sqlite")
        with self.absent(), self.assertRaises(FenceRefused):
            self.prove()

    def test_orphan_and_incomplete_historical_roots_are_unproven(self):
        self.register()
        with self.fence.store.connect() as db:
            db.execute("INSERT INTO task_execution_native VALUES (?,?,?,?)",
                       ("T42", "old-launch", "agent", json.dumps(self.proofs["agent"])))
        with self.absent(), self.assertRaises(FenceRefused):
            self.prove()
        old = self.fence.launch("T42")
        old.update(launch_id="old-launch", native=[dict(component="agent", process=self.proofs["agent"])])
        with self.fence.store.connect() as db:
            db.execute("INSERT INTO task_execution_launch_history VALUES (?,?,?)", ("T42", "old-launch", json.dumps(old)))
        with self.absent():
            self.assertEqual(len(self.prove()["launches"]), 2)
        old["native"] = []
        with self.fence.store.connect() as db:
            db.execute("UPDATE task_execution_launch_history SET registration=?", (json.dumps(old),))
        with self.absent(), self.assertRaises(FenceRefused):
            self.prove()

    def live_process(self):
        child = subprocess.Popen([sys.executable, "-c", "import sys; sys.stdin.buffer.read()"],
                                 stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        def cleanup():
            if child.poll() is None:
                child.stdin.close()
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=3)
        self.addCleanup(cleanup)
        return child

    def test_real_processes_alive_then_reaped_with_live_wrapper(self):
        children = {name:self.live_process() for name in ("supervisor", "child", "server", "client")}
        self.proofs.update({name:execution._kernel_process(proc.pid) for name, proc in children.items()})
        self.register()
        for name, proc in children.items():
            with self.subTest(still_alive=name), self.assertRaises(FenceRefused):
                self.prove()
            proc.stdin.close()
            self.assertEqual(proc.wait(timeout=3), 0)
        result = self.prove()
        self.assertTrue(all(r["evidence"] == "pid_absent" for r in result["launches"][0]["roots"]))
        self.assertEqual(execution._kernel_process(os.getpid()), self.wrapper)

    def test_real_live_pid_with_different_saved_birth_is_not_killed(self):
        child = self.live_process()
        live = execution._kernel_process(child.pid)
        prefix, suffix = live["birth"].rsplit(":", 1)
        old_birth = prefix + ":" + str((int(suffix) + 1) % 1000000 if sys.platform == "darwin" else int(suffix) + 1)
        self.proofs = {name:dict(live, birth=old_birth) for name in self.proofs}
        self.register("claude")
        result = self.prove("claude")
        self.assertTrue(all(r["evidence"] == "pid_reused" for r in result["launches"][0]["roots"]))
        self.assertIsNone(child.poll())
        self.assertEqual(execution._kernel_process(child.pid), live)

    def test_real_timezone_change_is_not_pid_reuse(self):
        child = self.live_process()
        with patch.dict(os.environ, TZ="UTC"):
            saved = execution._kernel_process(child.pid)
        with patch.dict(os.environ, TZ="Asia/Shanghai"):
            observed = execution._kernel_process(child.pid)
            self.assertNotEqual(saved["birth"], observed["birth"])
            self.assertFalse(execution._definitely_exited(saved))
            with self.assertRaises(FenceRefused):
                execution._exited_session_root(saved)
        self.assertIsNone(child.poll())

    def test_real_live_pid_with_missing_procfs_cannot_prove_exit(self):
        child = self.live_process()
        saved = execution._kernel_process(child.pid)
        # Exercise Linux's actual missing-/proc mapping with a real live PID;
        # the fixture birth is Linux-shaped even when the host is Darwin.
        linux_proof = dict(pid=child.pid, birth="Fri Oct 23 01:02:03 2026:12345")
        with patch.object(native_proc.sys, "platform", "linux"), \
                patch.object(Path, "read_text", side_effect=FileNotFoundError):
            for action in (execution._definitely_exited, execution._exited_session_root):
                with self.subTest(action=action.__name__), self.assertRaises(FenceRefused):
                    action(linux_proof)
        self.assertIsNone(child.poll())
        self.assertEqual(execution._kernel_process(child.pid), saved)

    def test_missing_kernel_record_requires_second_absence_probe(self):
        proof = self.proofs["agent"]
        for action in (execution._definitely_exited, execution._exited_session_root):
            for second in (None, PermissionError()):
                # A live/reused PID or an inaccessible PID is still unknown.
                with self.subTest(action=action.__name__, second=second), \
                        patch.object(execution.os, "kill", side_effect=[None, second]) as probe, \
                        patch.object(native_proc, "kernel_identity", side_effect=ProcessLookupError), \
                        self.assertRaises(FenceRefused):
                    action(proof)
                self.assertEqual(probe.call_count, 2)
            with patch.object(execution.os, "kill", side_effect=[None, ProcessLookupError()]) as probe, \
                    patch.object(native_proc, "kernel_identity", side_effect=ProcessLookupError):
                result = action(proof)
            self.assertEqual(probe.call_count, 2)
            if action is execution._definitely_exited:
                self.assertTrue(result)
            else:
                self.assertEqual(result["evidence"], "pid_absent")

    def test_real_zombie_birth_is_exit_without_executable_lookup(self):
        child = self.live_process()
        saved = execution._kernel_process(child.pid)
        child.stdin.close()
        # Keep our own child unreaped so this verifies an actual zombie.
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            state = subprocess.run(["ps", "-p", str(child.pid), "-o", "stat="],
                                   capture_output=True, text=True, check=True).stdout.strip()
            if state.startswith("Z"):
                break
            time.sleep(.02)
        self.assertTrue(state.startswith("Z"), state)
        with patch.object(execution, "_kernel_process", side_effect=AssertionError("exe lookup forbidden")):
            result = execution._exited_session_root(saved)
            self.assertEqual(result["evidence"], "kernel_zombie")
            self.assertTrue(execution._definitely_exited(saved))
        self.assertEqual(child.wait(timeout=3), 0)

    def test_legally_archived_partial_epoch_can_exit(self):
        with self.fence.admission(self.grant) as permit:
            permit.reserve_launch("old-empty", self.proofs["supervisor"], wrapper=self.wrapper)
            permit.register_child("old-empty", self.proofs["child"])
        # reserve_launch already permits this recovery: the old supervisor is
        # gone with its registered child before a native component started.
        with self.absent():
            self.register()
            result = self.prove()
        self.assertEqual([r["component"] for r in result["launches"][0]["roots"]], ["supervisor", "child"])

    def test_archived_one_native_component_still_must_exit(self):
        with self.fence.admission(self.grant) as permit:
            permit.reserve_launch("old-server", self.proofs["supervisor"], wrapper=self.wrapper)
            permit.register_child("old-server", self.proofs["child"])
            permit.register_native("old-server", "server", self.proofs["server"])
        with self.absent():
            self.register("claude")
            result = self.prove("claude")
        self.assertEqual({r["component"] for r in result["launches"][0]["roots"]}, {"supervisor", "child", "server"})
        def exists(pid, sig):
            if pid != self.proofs["server"]["pid"]:
                raise ProcessLookupError
        with patch.object(execution.os, "kill", side_effect=exists), patch.object(native_proc, "kernel_identity", return_value=dict(
                pid=self.proofs["server"]["pid"], birth_token=native_proc.birth_token(self.proofs["server"]["birth"]), state="R")), self.assertRaises(FenceRefused):
            self.prove("claude")

    def test_archived_missing_child_stays_unproven(self):
        with self.fence.admission(self.grant) as permit:
            permit.reserve_launch("old-missing-child", self.proofs["supervisor"], wrapper=self.wrapper)
        with self.absent():
            self.register()
            with self.assertRaises(FenceRefused):
                self.prove()

    def test_old_or_malformed_birth_is_never_reuse_or_exit(self):
        for birth in ("Fri Oct 23 01:02:03 2026", "old-format", "", "Fri Oct 23 01:02:03 2026:0:1000000"):
            with self.subTest(birth=birth), self.absent():
                for action in (execution._definitely_exited, execution._exited_session_root):
                    with self.assertRaises(FenceRefused):
                        action(dict(pid=90000001, birth=birth))

    def test_platform_kernel_tokens_and_linux_zombie_without_exe(self):
        self.assertEqual(native_proc.birth_token("Fri Oct 23 01:02:03 2026:1700000000:123", platform="darwin"), "1700000000:123")
        self.assertEqual(native_proc.birth_token("Fri Oct 23 01:02:03 2026:12345", platform="linux"), "12345")
        fields = ["Z", "42"] + ["0"] * 17 + ["12345"]
        with patch.object(native_proc.sys, "platform", "linux"), patch.object(Path, "read_text", return_value="123 (a ) name) " + " ".join(fields)), \
                patch.object(os, "readlink", side_effect=AssertionError("no exe read")):
            self.assertEqual(native_proc.kernel_identity(123), dict(pid=123, ppid=42, birth_token="12345", state="Z"))

    def test_linux_kernel_record_rejects_wrong_pid_ticks_and_missing_fields(self):
        fields = ["Z", "42"] + ["0"] * 17 + ["12345"]
        records = ["124 (wrong pid) " + " ".join(fields),
                   "123 (missing start tick) " + " ".join(fields[:-1]),
                   "123 (bad tick) " + " ".join(fields[:-1] + ["not-ticks"]),
                   "123 (zero tick) " + " ".join(fields[:-1] + ["0"]),
                   "123 (bad state) " + " ".join(["??"] + fields[1:])]
        for record in records:
            with self.subTest(record=record), patch.object(native_proc.sys, "platform", "linux"), \
                    patch.object(Path, "read_text", return_value=record), self.assertRaises(ValueError):
                native_proc.kernel_identity(123)

    def test_linux_kernel_absence_and_permission_failure_are_distinct(self):
        with patch.object(native_proc.sys, "platform", "linux"):
            with patch.object(Path, "read_text", side_effect=FileNotFoundError), self.assertRaises(ProcessLookupError):
                native_proc.kernel_identity(123)
            with patch.object(Path, "read_text", side_effect=PermissionError), self.assertRaises(PermissionError):
                native_proc.kernel_identity(123)
        self.register()
        with patch.object(execution.os, "kill"), patch.object(native_proc, "kernel_identity", side_effect=ProcessLookupError), self.assertRaises(FenceRefused):
            self.prove()
        with patch.object(execution.os, "kill"), patch.object(native_proc, "kernel_identity", side_effect=PermissionError), self.assertRaises(FenceRefused):
            self.prove()


if __name__ == "__main__":
    unittest.main()
