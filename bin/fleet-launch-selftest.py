#!/usr/bin/env python3
"""Isolated launch receipts: no live fleet or provider credentials."""
import copy
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
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
                    "@fleet_id": self.context["worker_id"].split("/")[1], "window_id": "@7", "pane_pid": "11"}
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

    def test_copied_receipt_cannot_claim_another_panes_process(self):
        opts = {"@launch": json.dumps(self.context), "@launch_receipt": json.dumps(self.receipt),
                "@fleet_id": self.context["worker_id"].split("/")[1], "pane_pid": "99"}
        with mock.patch.object(launch, "option", side_effect=lambda p,k,*a: opts.get(k,"")), \
             mock.patch.object(launch, "same_process", return_value=True), \
             mock.patch.object(launch, "descendant", return_value=False):
            with self.assertRaisesRegex(ValueError, "no longer belongs"):
                launch.inspect(self.context, "%1")

    def test_recovery_keeps_option_values_and_strips_only_input(self):
        sid = self.receipt["native_session"]
        argv = ["launcher", "--agent=codex", "resume", sid, "legacy nudge", "-m", "model-name", "-c", "x=y"]
        got, provider, resume = launch.held_argv(argv, "old input", True, self.receipt)
        self.assertEqual(got, argv[:4] + argv[5:])
        self.assertEqual((provider, resume), ("codex", sid))
        got, _, _ = launch.held_argv(["launcher", "--agent", "codex", ""], "", True, None)
        self.assertEqual(got, ["launcher", "--agent", "codex"])
        got, provider, native = launch.held_argv(["launcher", "--session-id", sid, "input"], "input", True, None)
        self.assertEqual((got, provider, native), (["launcher", "--session-id", sid], "claude", sid))
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

    def test_resume_verifies_same_session_without_resending_seed(self):
        opts = {"@launch": json.dumps(self.context), "@launch_receipt": json.dumps(self.receipt),
                "@launch_seed": "/already-removed-seed", "@launch_started": "1"}
        child = mock.Mock(pid=12)
        child.poll.return_value = None
        child.wait.return_value = 0
        observed = dict(self.receipt, pid=43, birth="resumed-process")
        argv = ["launcher", "--agent", "codex", "resume", self.receipt["native_session"], "automatic nudge"]
        with mock.patch.dict(os.environ, {"TMUX_PANE": "%1"}), \
             mock.patch.object(launch, "option", side_effect=lambda p,k,*args: opts.get(k,"")), \
             mock.patch.object(launch, "same_process", return_value=False), \
             mock.patch.object(launch, "current_task"), \
             mock.patch.object(launch, "tmux"), \
             mock.patch.object(launch, "process", return_value=dict(observed, pid=12)), \
             mock.patch.object(launch, "inspect", return_value=observed), \
             mock.patch.object(launch, "descendant", return_value=True), \
             mock.patch.object(launch, "publish") as published, \
             mock.patch.object(launch, "stamp") as stamped, \
             mock.patch.object(launch, "stop_created"), \
             mock.patch.object(launch.subprocess, "Popen", return_value=child) as started, \
             mock.patch.object(launch.subprocess, "run") as delivered:
            self.assertEqual(launch.supervise(argv), 0)
            self.assertEqual(started.call_args.args[0], argv[:-1])
            self.assertEqual(started.call_args.kwargs["env"]["FLEET_LAUNCH_NATIVE"], self.receipt["native_session"])
            delivered.assert_called_once()
            self.assertEqual(delivered.call_args.args[0][2:], ["finalize", "--pane", "%1"])
            self.assertNotIn("input", delivered.call_args.kwargs)
            published.assert_called_once()
            self.assertEqual(stamped.call_args.args[2]["phase"], "resumed")

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


class Worktrees(Receipts):
    def setUp(self):
        super().setUp()
        temporary = tempfile.TemporaryDirectory(prefix="fleet-bound-worktree-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.main = self.root / "repository"
        self.worktree = self.main / ".claude/worktrees/opaque"
        self.other = self.root / "other"
        self.environment = dict(PATH=os.environ["PATH"], HOME=str(self.root),
            GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
            GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
            GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")
        self.git("init", "-q", str(self.main))
        self.git("-C", str(self.main), "commit", "--allow-empty", "-qm", "fixture")
        for directory in (self.worktree, self.other):
            self.git("-C", str(self.main), "worktree", "add", "--detach", "-q", str(directory))
        self.binding = launch.worktree_identity(str(self.worktree))

    def git(self, *arguments):
        return subprocess.run(["git", *arguments], env=self.environment, capture_output=True,
                              text=True, check=True, timeout=10).stdout.strip()

    def test_real_registered_identity_and_subdirectory(self):
        subdirectory = self.worktree / "source"
        subdirectory.mkdir()
        self.assertEqual(launch.worktree_identity(str(subdirectory)), self.binding)
        self.assertEqual(self.binding["common_dir"], str(self.main / ".git"))
        self.assertEqual(launch.worktree_identity(str(self.other))["root"], str(self.other))
        with self.assertRaises(ValueError):
            launch.worktree_identity(str(self.main))

    def test_identity_ignores_git_environment_redirection(self):
        with mock.patch.dict(os.environ, {"GIT_DIR": str(self.main / ".git"),
                "GIT_WORK_TREE": str(self.main), "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_KEY_0": "core.worktree", "GIT_CONFIG_VALUE_0": str(self.other)}):
            self.assertEqual(launch.worktree_identity(str(self.worktree)), self.binding)

    def test_backlink_and_symlink_marker_are_not_identity(self):
        backlink = Path(self.binding["git_dir"]) / "gitdir"
        original = backlink.read_text()
        backlink.write_text(str(self.other / ".git") + "\n")
        with self.assertRaises(ValueError):
            launch.worktree_identity(str(self.worktree))
        backlink.write_text(original)
        marker = self.worktree / ".git"
        marker.unlink()
        marker.symlink_to(self.other / ".git")
        with self.assertRaises(ValueError):
            launch.worktree_identity(str(self.worktree))

    def test_saved_binding_rejects_missing_changed_and_nonroot_window(self):
        previous = dict(self.receipt, worktree=self.binding)
        for path in ("", str(self.other), str(self.main)):
            with self.subTest(path=path), mock.patch.object(launch, "option", return_value=path):
                with self.assertRaises(ValueError):
                    launch.prepare_worktree("%1", previous)
        with mock.patch.object(launch, "option", return_value=str(self.worktree)):
            self.assertEqual(launch.prepare_worktree("%1", previous), self.binding)
            changed = dict(previous, worktree=dict(self.binding, common_dir=str(self.other)))
            with self.assertRaises(ValueError):
                launch.prepare_worktree("%1", changed)
        subdirectory = self.worktree / "source"
        subdirectory.mkdir()
        with mock.patch.object(launch, "option", return_value=str(subdirectory)):
            with self.assertRaises(ValueError):
                launch.prepare_worktree("%1")

    def test_malformed_binding_and_missing_git_fail_closed(self):
        for binding in (None, {}, dict(self.binding, root="relative"), dict(self.binding, owner="guess")):
            with self.subTest(binding=binding), self.assertRaises(ValueError):
                launch.check_receipt(self.context, dict(self.receipt, worktree=binding))
        for failure in (FileNotFoundError(), subprocess.TimeoutExpired("git", 2)):
            with mock.patch.object(launch.subprocess, "run", side_effect=failure):
                with self.assertRaises(type(failure)):
                    launch.worktree_identity(str(self.worktree))

    def test_native_hook_binds_only_expected_registered_worktree(self):
        opts = {"@launch": json.dumps(self.context), "@worktree": str(self.worktree)}
        native = {key: self.receipt[key] for key in ("pid", "birth", "executable", "actual_provider")}
        with mock.patch.dict(os.environ, {"TMUX_PANE": "%1", "FLEET_LAUNCH_CONTEXT": json.dumps(self.context),
                "FLEET_LAUNCH_SUPERVISOR": "12", "FLEET_LAUNCH_WORKTREE": json.dumps(self.binding)}), \
                mock.patch.object(launch, "option", side_effect=lambda pane,key,*args: opts.get(key,"")), \
                mock.patch.object(launch, "native_parent", return_value=native), \
                mock.patch.object(launch, "root_native", return_value=True), \
                mock.patch.object(launch, "stamp") as stamped:
            payload = dict(hook_event_name="SessionStart", session_id=self.receipt["native_session"])
            for cwd in (str(self.main), str(self.other), None):
                with self.subTest(cwd=cwd), self.assertRaises(ValueError):
                    launch.hook(dict(payload, cwd=cwd))
            stamped.assert_not_called()
            launch.hook(dict(payload, cwd=str(self.worktree)))
            self.assertEqual(stamped.call_args.args[2]["worktree"], self.binding)
            stamped.reset_mock()
            opts["@worktree"] = str(self.other)
            with self.assertRaises(ValueError):
                launch.hook(dict(payload, cwd=str(self.worktree)))
            stamped.assert_not_called()

    def test_resume_passes_saved_root_and_requires_hook_proof(self):
        previous = dict(self.receipt, worktree=self.binding)
        observed = dict(previous, pid=43, birth="new")
        opts = {"@launch_receipt": json.dumps(previous), "@launch_started": "1"}
        child = mock.Mock(pid=12)
        child.poll.return_value = None
        child.wait.return_value = 0
        for prove in (True, False):
            receipt = dict(observed)
            if not prove:
                receipt.pop("worktree")
            ticks = iter(range(1000))
            with self.subTest(prove=prove), \
                    mock.patch.object(launch, "option", side_effect=lambda pane,key,*args: opts.get(key,"")), \
                    mock.patch.object(launch, "same_process", return_value=False), \
                    mock.patch.object(launch, "prepare_worktree", return_value=self.binding), \
                    mock.patch.object(launch, "current_task"), mock.patch.object(launch, "tmux"), \
                    mock.patch.object(launch, "process", return_value=dict(observed, pid=12)), \
                    mock.patch.object(launch, "inspect", return_value=receipt), \
                    mock.patch.object(launch, "descendant", return_value=True), \
                    mock.patch.object(launch, "publish") as published, mock.patch.object(launch, "stamp"), \
                    mock.patch.object(launch, "stop_created"), \
                    mock.patch.object(launch.subprocess, "Popen", return_value=child) as started, \
                    mock.patch.object(launch.subprocess, "run") as finalized, \
                    mock.patch.object(launch.time, "monotonic", side_effect=lambda: next(ticks)), \
                    mock.patch.object(launch.time, "sleep"):
                command = ["launcher", "--agent", "codex", "resume", previous["native_session"]]
                with contextlib.ExitStack() as guard:
                    if prove:
                        self.assertEqual(launch.supervise_guarded(command, "%1", self.context, guard), 0)
                        published.assert_called_once()
                        finalized.assert_called_once()
                    else:
                        with self.assertRaisesRegex(ValueError, "no matching"):
                            launch.supervise_guarded(command, "%1", self.context, guard)
                        published.assert_not_called()
                        finalized.assert_not_called()
                self.assertEqual(started.call_args.kwargs["cwd"], str(self.worktree))
                self.assertEqual(json.loads(started.call_args.kwargs["env"]["FLEET_LAUNCH_WORKTREE"]), self.binding)

    def test_local_authority_refuses_before_observe_and_keeps_local_binding(self):
        import fleet_repo_authority as authority
        context = dict(repo="org/a", worker_id=self.context["worker_id"], reservation="fixture",
                       supervisor=12, worktree=self.binding)
        native = {key: self.receipt[key] for key in ("pid", "birth", "executable")}
        payload = dict(hook_event_name="SessionStart", session_id=self.receipt["native_session"])
        # The begin acknowledgement the supervisor hands down, and the exact
        # observe acknowledgement the hook checks against it (#4536).
        admission = dict(repo="org/a", reservation="fixture", owner="fixture-owner",
                         endpoint_id="fixture-node", worker_id=context["worker_id"], phase="starting")
        proof = dict(native, worker_id=context["worker_id"], native_session=payload["session_id"])
        ack = dict(admission, phase="observed", native_identity=proof)
        with mock.patch.dict(os.environ, {"TMUX_PANE": "%1", "FLEET_AUTHORITY_CONTEXT": json.dumps(context),
                                          "FLEET_AUTHORITY_ADMISSION": json.dumps(admission)}), \
                mock.patch.object(launch, "native_parent", return_value=native), \
                mock.patch.object(launch, "root_native", return_value=True), \
                mock.patch.object(launch, "option", return_value=str(self.worktree)), \
                mock.patch.object(authority, "start_call", return_value=ack) as observed, \
                mock.patch.object(launch, "stamp") as stamped:
            for invalid in ({}, None):
                with mock.patch.dict(os.environ, {"FLEET_AUTHORITY_CONTEXT": json.dumps(dict(context, worktree=invalid))}), \
                        self.assertRaisesRegex(ValueError, "invalid worktree binding"):
                    authority.observe_native(dict(payload, cwd=str(self.worktree)))
            for cwd in (str(self.main), str(self.other)):
                with self.subTest(cwd=cwd), self.assertRaises(ValueError):
                    authority.observe_native(dict(payload, cwd=cwd))
            observed.assert_not_called()
            stamped.assert_not_called()
            authority.observe_native(dict(payload, cwd=str(self.worktree)))
            observed.assert_called_once()
            self.assertEqual(observed.call_args.args[2], "observe")
            self.assertEqual(stamped.call_args.args[2]["worktree"], self.binding)

    def test_bad_directory_refuses_before_reservation_or_start(self):
        import fleet_repo_authority as authority
        with mock.patch.dict(os.environ, {"TMUX_PANE": "%1"}), \
                mock.patch.object(launch, "option", return_value=""), \
                mock.patch.object(authority.subprocess, "run",
                    return_value=subprocess.CompletedProcess([], 0, "org/a\tfleet/session", "")), \
                mock.patch.object(launch, "prepare_worktree", side_effect=ValueError("changed")), \
                mock.patch.object(authority, "start_call") as admission, \
                mock.patch.object(authority.subprocess, "Popen") as started:
            with self.assertRaisesRegex(ValueError, "changed"):
                authority.supervise(["launcher"])
            admission.assert_not_called()
            started.assert_not_called()

    def test_inspection_rechecks_window_and_git_binding(self):
        receipt = dict(self.receipt, worktree=self.binding)
        opts = {"@launch": json.dumps(self.context), "@launch_receipt": json.dumps(receipt),
                "@fleet_id": self.context["worker_id"].split("/")[1], "pane_pid": "11",
                "@worktree": str(self.worktree), "window_id": "@1"}
        with mock.patch.object(launch, "option", side_effect=lambda pane,key,*args: opts.get(key,"")), \
                mock.patch.object(launch, "same_process", return_value=True), \
                mock.patch.object(launch, "descendant", return_value=True):
            self.assertEqual(launch.inspect(self.context, "%1")["worktree"], self.binding)
            opts["@worktree"] = str(self.other)
            with self.assertRaises(ValueError):
                launch.inspect(self.context, "%1")
            opts["@worktree"] = str(self.worktree)
            (Path(self.binding["git_dir"]) / "gitdir").write_text(str(self.other / ".git") + "\n")
            with self.assertRaises(ValueError):
                launch.inspect(self.context, "%1")

    def test_late_hook_cannot_erase_bound_worktree(self):
        opts = {"@launch": json.dumps(self.context),
                "@launch_receipt": json.dumps(dict(self.receipt, worktree=self.binding))}
        native = {key: self.receipt[key] for key in ("pid", "birth", "executable", "actual_provider")}
        with mock.patch.dict(os.environ, {"TMUX_PANE": "%1", "FLEET_LAUNCH_CONTEXT": json.dumps(self.context),
                "FLEET_LAUNCH_SUPERVISOR": "12", "FLEET_LAUNCH_WORKTREE": ""}), \
                mock.patch.object(launch, "option", side_effect=lambda pane,key,*args: opts.get(key,"")), \
                mock.patch.object(launch, "native_parent", return_value=native), \
                mock.patch.object(launch, "root_native", return_value=True), \
                mock.patch.object(launch, "stamp") as stamped:
            with self.assertRaisesRegex(ValueError, "worktree identity"):
                launch.hook(dict(hook_event_name="SessionStart", session_id=self.receipt["native_session"]))
            stamped.assert_not_called()


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


class NativeInbox(Receipts):
    def test_input_uses_verified_executable_endpoint_and_thread(self):
        spec = importlib.util.spec_from_file_location("codex_session_fixture", Path(__file__).with_name("fleet-codex-session.py"))
        codex = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(codex)
        receipt = dict(self.receipt, native_remote="unix:///fixture/native.sock", native_home="/fixture/home")
        env = dict(FLEET_LAUNCH_DELIVERY=json.dumps(receipt), FLEET_LAUNCH_CONTEXT=json.dumps(self.context))
        with mock.patch.dict(os.environ, env), mock.patch.object(launch, "inspect", return_value=receipt), \
             mock.patch.object(codex, "identity", side_effect=AssertionError("pane label must not route first input")), \
             mock.patch.object(sys, "stdin", io.StringIO("held input")), \
             mock.patch.object(codex.subprocess, "run", return_value=mock.Mock(returncode=0)) as queue, \
             contextlib.redirect_stdout(io.StringIO()):
            codex.send(mock.Mock(pane="%1", socket="isolated"))
            self.assertEqual(queue.call_args.args[0], ["/fixture/codex", "queue", "--remote", "unix:///fixture/native.sock",
                             "--thread", self.receipt["native_session"], "--message", "held input"])
            self.assertEqual(queue.call_args.kwargs["env"]["CODEX_HOME"], "/fixture/home")
        with mock.patch.dict(os.environ, env), \
             mock.patch.object(launch, "inspect", return_value=dict(receipt, native_session="changed")), \
             mock.patch.object(codex.subprocess, "run") as queue:
            with self.assertRaisesRegex(ValueError, "changed before delivery"):
                codex.send(mock.Mock(pane="%1", socket="isolated"))
            queue.assert_not_called()


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
