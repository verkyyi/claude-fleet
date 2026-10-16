#!/usr/bin/env python3
"""Isolated launch receipts: no live fleet or provider credentials."""
import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import fleet_launch as launch
from fleet_control import Control
from fleet_dispatch import resolve
from fleet_launch import check_receipt, validate_context


class Receipts(unittest.TestCase):
    def setUp(self):
        self.context = dict(version=1, operation_id="11111111-1111-4111-8111-111111111111",
                            task="T1", owner="alice", generation=1,
                            worker_id="22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333",
                            provider="codex", attempt_id="task:T1:g1")
        self.receipt = dict(self.context, native_session="44444444-4444-4444-8444-444444444444",
                            actual_provider="codex", pid=42, birth="fixture-process-1",
                            executable="/fixture/codex", observed_at=1, phase="verified")

    def test_receipt_binds_every_identity(self):
        validate_context(self.context)
        check_receipt(self.context, self.receipt)
        for field in ("operation_id", "task", "owner", "generation", "worker_id", "attempt_id"):
            old = copy.deepcopy(self.receipt)
            old[field] = "old"
            with self.assertRaises(ValueError, msg=field):
                check_receipt(self.context, old)

    def test_mismatch_and_missing_native_identity_refuse(self):
        for field, value in (("actual_provider", "claude"), ("native_session", ""),
                             ("pid", 0), ("executable", ""), ("birth", "")):
            bad = dict(self.receipt, **{field: value})
            with self.assertRaises(ValueError, msg=field):
                check_receipt(self.context, bad)


class Supervisor(Receipts):
    def run_launch(self, wrong=False, absent=False):
        with tempfile.TemporaryDirectory() as directory:
            seed = Path(directory) / "seed"
            seed.write_text("private task input\n")
            opts = {"@launch": json.dumps(self.context), "@launch_seed": str(seed),
                    "@fleet_id": self.context["worker_id"].split("/")[1], "window_id": "@7"}
            started, sent = [], []
            child = mock.Mock(pid=12)
            child.poll.return_value = None
            child.wait.return_value = 0
            def popen(argv, **kw):
                started.append(argv)
                if absent:
                    child.poll.return_value = 127
                else:
                    r = dict(self.receipt, actual_provider="claude" if wrong else "codex")
                    opts["@launch_receipt"] = json.dumps(r)
                return child
            def tmux(*args, **kw):
                if args[0] == "set-option":
                    if args[1] == "-wu":
                        opts.pop(args[4], None)
                    else:
                        opts[args[4]] = args[5]
                return ""
            def deliver(argv, **kw):
                sent.append((argv, kw.get("input")))
                return mock.Mock(returncode=0)
            ticks = iter(range(1000))
            with mock.patch.dict(os.environ, {"TMUX_PANE": "%1"}), \
                 mock.patch.object(launch, "option", side_effect=lambda p,k,*a: opts.get(k,"")), \
                 mock.patch.object(launch, "tmux", side_effect=tmux), \
                 mock.patch.object(launch, "same_process", return_value=True), \
                 mock.patch.object(launch, "process", return_value=dict(self.receipt, pid=12)), \
                 mock.patch.object(launch, "descendant", return_value=True), \
                 mock.patch.object(launch, "current_task"), \
                 mock.patch.object(launch, "publish") as publish, \
                 mock.patch.object(launch, "stop_created") as stopped, \
                 mock.patch.object(launch.subprocess, "Popen", side_effect=popen), \
                 mock.patch.object(launch.subprocess, "run", side_effect=deliver), \
                 mock.patch.object(launch.time, "monotonic", side_effect=lambda: next(ticks)), \
                 mock.patch.object(launch.time, "sleep"):
                if wrong or absent:
                    with self.assertRaises(ValueError):
                        launch.supervise(["launcher", "--agent", "codex", "private task input"])
                    stopped.assert_called_once_with(child, dict(self.receipt, pid=12))
                    publish.assert_not_called()
                    self.assertEqual(sent, [])
                else:
                    self.assertEqual(launch.supervise(["launcher", "--agent", "codex", "private task input"]), 0)
                    publish.assert_called_once()
                    self.assertEqual(sent[0][1], "private task input")
                    self.assertEqual(json.loads(opts["@launch_receipt"])["phase"], "delivered")
                self.assertEqual(started, [["launcher", "--agent", "codex"]])

    def test_input_only_after_verified_identity(self):
        self.run_launch()

    def test_mismatched_process_never_sees_input(self):
        self.run_launch(wrong=True)

    def test_absent_cli_never_sees_input(self):
        self.run_launch(absent=True)

    def test_lost_native_identity_never_restarts(self):
        opts = {"@launch": json.dumps(self.context), "@launch_started": "1"}
        with mock.patch.dict(os.environ, {"TMUX_PANE": "%1"}), \
             mock.patch.object(launch, "option", side_effect=lambda p,k: opts.get(k,"")), \
             mock.patch.object(launch.subprocess, "Popen") as start:
            with self.assertRaisesRegex(ValueError, "no fresh rerun"):
                launch.supervise(["launcher", "--agent", "codex"])
            start.assert_not_called()

    def test_nested_native_hook_cannot_own_root(self):
        root = dict(pid=42, ppid=12, executable="/fixture/codex")
        nested = dict(pid=43, ppid=42, executable="/fixture/codex")
        with mock.patch.object(launch, "process", return_value=root):
            self.assertTrue(launch.root_native(root, 12))
            self.assertFalse(launch.root_native(nested, 12))

    def test_pid_reuse_is_not_surviving_execution(self):
        with mock.patch.object(launch, "process", return_value=dict(self.receipt, birth="new-birth")):
            self.assertFalse(launch.same_process(self.receipt))

    def test_recovery_keeps_option_values_and_strips_only_input(self):
        sid = self.receipt["native_session"]
        argv = ["launcher", "--agent=codex", "resume", sid, "legacy nudge", "-m", "model-name", "-c", "x=y"]
        got, provider, resume = launch.held_argv(argv, "old input", True, self.receipt)
        self.assertEqual(got, argv[:4] + argv[5:])
        self.assertEqual((provider, resume), ("codex", sid))
        got, _, _ = launch.held_argv(["launcher", "--agent", "codex", ""], "", True, None)
        self.assertEqual(got, ["launcher", "--agent", "codex"])
        got, _, _ = launch.held_argv(["launcher", "--agent", "codex", "--agent=claude"], "--agent=claude", True, None)
        self.assertEqual(got, ["launcher", "--agent", "codex"])
        for args in (["launcher", "resume", "55555555-5555-4555-8555-555555555555"],
                     ["launcher", "resume", sid, "one", "two"], ["launcher", "--continue"]):
            with self.assertRaises(ValueError):
                launch.held_argv(args, "", False, self.receipt)

    def test_changed_task_authority_prevents_native_start(self):
        opts = {"@launch": json.dumps(self.context)}
        with mock.patch.dict(os.environ, {"TMUX_PANE": "%1"}), \
             mock.patch.object(launch, "option", side_effect=lambda p,k: opts.get(k,"")), \
             mock.patch.object(launch, "current_task", side_effect=ValueError("fenced")), \
             mock.patch.object(launch.subprocess, "Popen") as start:
            with self.assertRaisesRegex(ValueError, "fenced"):
                launch.supervise(["launcher", "--agent", "codex"])
            start.assert_not_called()

    def test_late_hook_preserves_delivery_and_refuses_replacement(self):
        opts = {"@launch": json.dumps(self.context), "@launch_receipt": json.dumps(dict(self.receipt, phase="delivered"))}
        native = {k: self.receipt[k] for k in ("pid", "birth", "executable", "actual_provider")}
        with mock.patch.dict(os.environ, {"TMUX_PANE": "%1", "FLEET_LAUNCH_CONTEXT": json.dumps(self.context),
                                         "FLEET_LAUNCH_SUPERVISOR": "12"}), \
             mock.patch.object(launch, "option", side_effect=lambda p,k: opts.get(k,"")), \
             mock.patch.object(launch, "native_parent", return_value=native), \
             mock.patch.object(launch, "root_native", return_value=True), \
             mock.patch.object(launch, "stamp") as stamp:
            launch.hook(dict(hook_event_name="SessionStart", session_id=self.receipt["native_session"]))
            stamp.assert_not_called()
            with self.assertRaisesRegex(ValueError, "cannot replace"):
                launch.hook(dict(hook_event_name="SessionStart", session_id="55555555-5555-4555-8555-555555555555"))


class Transfer(Receipts):
    def attempt(self, directory, alive=False, lost_response=False):
        opts = {"@launch": json.dumps(self.context), "@launch_receipt": json.dumps(self.receipt)}
        mutations, stamps = [], []
        controller = Control(directory)
        def mutate(c, m):
            mutations.append(m)
            if lost_response:
                raise ValueError("authority response lost")
            return dict(generation=2, attempt_id="task:T1:g2", state="accepted")
        with mock.patch.object(launch, "option", side_effect=lambda p,k,*a: opts.get(k,"")), \
             mock.patch.object(launch, "same_process", return_value=alive), \
             mock.patch.object(launch, "current_task"), \
             mock.patch.object(launch, "task_call", side_effect=mutate), \
             mock.patch.object(launch, "tmux", side_effect=lambda *a,**kw: stamps.append(a)), \
             mock.patch("fleet_control.Control", return_value=controller):
            if alive or lost_response:
                with self.assertRaises(ValueError):
                    launch.transfer_commit("%1", "isolated", "claude", directory)
                self.assertEqual(stamps, [])
                self.assertEqual(len(mutations), 0 if alive else 1)
            else:
                launch.transfer_commit("%1", "isolated", "claude", directory)
                self.assertEqual([m["kind"] for m in mutations], ["transfer", "claim"])
                new = json.loads((Path(directory)/"task-launch.json").read_text())["launch"]
                self.assertEqual((new["generation"], new["provider"], new["worker_id"]), (2, "claude", self.context["worker_id"]))
                with controller.store.connect() as db:
                    self.assertEqual(db.execute("SELECT count(*) FROM operations").fetchone()[0], 1)
            if not alive:
                mutations.clear()
                with self.assertRaisesRegex(ValueError, "already attempted"):
                    launch.transfer_commit("%1", "isolated", "claude", directory)
                self.assertEqual(mutations, [])

    def test_explicit_transfer_advances_generation_once(self):
        with tempfile.TemporaryDirectory() as directory:
            self.attempt(directory)

    def test_live_source_refuses_generation_change(self):
        with tempfile.TemporaryDirectory() as directory:
            self.attempt(directory, alive=True)

    def test_lost_transfer_response_never_retries_or_replaces(self):
        with tempfile.TemporaryDirectory() as directory:
            self.attempt(directory, lost_response=True)


class Journal(Receipts):
    def test_duplicate_lost_ack_and_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            control = Control(directory)
            control.fleet = lambda fid: dict(name="fixture")
            control.attached_body = lambda params: params.get("body", "")
            count = []
            live = []
            def adapter(mode, *args, **kw):
                if mode == "start":
                    count.append(1)
                    live.append(dict(self.receipt, phase="delivered", window_id="@7"))
                    return 0, b"", b""  # window receipt lost after native start
                if mode == "launch-inspect" and live:
                    return 0, json.dumps(live[0]).encode(), b""
                return 1, b"", b""
            control.adapter = adapter
            d = dict(resolve(["codex"], request_id="fixture-start"), task="T1", generation=1, attempt_id="task:T1:g1")
            req = dict(operation_id=self.context["operation_id"], fleet_id=self.context["worker_id"].split("/")[0],
                       action="worker_start", actor="alice", params=dict(kind="scratch", no_repo=True,
                       agent="codex", task="T1", dispatch=d, launch=self.context, body="input"))
            with mock.patch("fleet_control.subprocess.Popen") as executor:
                control.submit(req)
                control.submit(req)
                self.assertEqual(executor.call_count, 1)
            control.execute(req["operation_id"])
            control.execute(req["operation_id"])
            got = control.get_operation(req["operation_id"])
            self.assertEqual(got["status"], "succeeded")
            self.assertEqual(got["result"]["window_id"], "@7")
            self.assertEqual(got["result"]["launch_receipt"]["generation"], 1)
            self.assertEqual(len(count), 1)
            restarted = Control(directory)
            restarted.fleet, restarted.adapter = control.fleet, control.adapter
            self.assertEqual(restarted.get_operation(req["operation_id"])["status"], "succeeded")
            live.clear()  # node/process restart lost native identity
            self.assertEqual(restarted.get_operation(req["operation_id"])["status"], "unknown")
            with mock.patch("fleet_control.subprocess.Popen") as executor:
                self.assertEqual(restarted.submit(req)["status"], "unknown")
                executor.assert_not_called()
            restarted.execute(req["operation_id"])
            self.assertEqual(len(count), 1)


if __name__ == "__main__":
    unittest.main()

# Fixtures execute the real operation journal and real supervisor logic. Native
# processes/remote delivery are fakes; they are not live provider acceptance.
