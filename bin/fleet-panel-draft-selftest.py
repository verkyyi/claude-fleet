#!/usr/bin/env -S python3 -B
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
"""Panel drafts stay unsubmitted across placement and the node boundary."""

import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

BIN = Path(__file__).absolute().parent
sys.path.insert(0, str(BIN))
import fleet_control
from fleet_hub_common import Fault, validate_write
import fleet_view
import fleet_panel


def module(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), BIN / (name + ".py"))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


compose = module("fleet-compose")
dispatch = module("fleet-quick-dispatch")


class PanelDraftTests(unittest.TestCase):
    def test_headless_compose_does_not_load_unused_display_strings(self):
        with patch.object(compose, "load_text", side_effect=AssertionError("headless send has no display strings")), \
                patch.object(compose, "send", return_value=4) as send:
            self.assertEqual(compose.main(["--send", "draft.json", "--repo", "acme/web", "--agent", "codex"]), 4)
        send.assert_called_once_with("draft.json", "acme/web", "", "", "", "codex")

    def test_compose_payload_keeps_localized_display_strings(self):
        with patch.object(compose, "load_text", return_value={"compose_empty": "localized"}) as load, \
                patch.object(compose.Path, "read_text", return_value="draft"), \
                patch.object(compose, "payload", return_value={}), patch("builtins.print"):
            self.assertEqual(compose.main(["payload", "draft.txt"]), 0)
        load.assert_called_once_with()
        self.assertEqual(compose.TEXT["compose_empty"], "localized")

    def test_panel_wait_preserves_bracketed_paste_input(self):
        for completed in (None, []):
            with self.subTest(launch_pending=completed is not None):
                screen = unittest.mock.Mock()
                inputs = fleet_panel.Input()
                screen.get_wch.side_effect = list("\x1b[200~line one\nline two\x1b[201~")
                received = []
                while inputs.paste is not None or not received:
                    value = fleet_view.panel_key(screen, 200, completed, inputs)
                    if value is not None:
                        received.append(value)
                self.assertEqual(received, [("paste", "line one\nline two")])

    def test_idle_panel_keeps_its_existing_input_wait(self):
        screen = unittest.mock.Mock()
        screen.get_wch.return_value = "x"
        self.assertEqual(fleet_view.panel_key(screen, 1000), "x")
        screen.timeout.assert_called_once_with(1000)
        screen.get_wch.assert_called_once_with()

    def test_pending_launch_checks_completion_without_redrawing(self):
        now, completed, waits = [0.0], [], []
        screen = unittest.mock.Mock()
        screen.timeout.side_effect = waits.append

        def read():
            now[0] += waits[-1] / 1000
            completed.append((0, "opened"))
            raise fleet_view.curses.error()

        screen.get_wch.side_effect = read
        with patch.object(fleet_view.time, "monotonic", side_effect=lambda: now[0]):
            with self.assertRaises(fleet_view.curses.error):
                fleet_view.panel_key(screen, 200, completed)
        self.assertEqual(waits, [50])
        self.assertEqual(completed, [(0, "opened")])
        screen.refresh.assert_not_called()

    def test_pending_launch_preserves_redraw_deadline_and_keys(self):
        now, waits = [0.0], []
        screen = unittest.mock.Mock()
        screen.timeout.side_effect = waits.append

        def read():
            now[0] += waits[-1] / 1000
            raise fleet_view.curses.error()

        screen.get_wch.side_effect = read
        with patch.object(fleet_view.time, "monotonic", side_effect=lambda: now[0]):
            with self.assertRaises(fleet_view.curses.error):
                fleet_view.panel_key(screen, 200, [])
        self.assertGreaterEqual(now[0], 0.2)
        self.assertLessEqual(now[0], 0.201)
        self.assertTrue(all(0 < wait <= 50 for wait in waits))
        for key in ("\x1b", "x", fleet_view.curses.KEY_RESIZE):
            screen.get_wch.side_effect = None
            screen.get_wch.return_value = key
            self.assertEqual(fleet_view.panel_key(screen, 200, []), key)

    def test_completed_launch_does_not_wait_or_consume_input(self):
        screen = unittest.mock.Mock()
        for result in ((0, "opened"), (4, "refused")):
            with self.assertRaises(fleet_view.curses.error):
                fleet_view.panel_key(screen, 200, [result])
        screen.timeout.assert_not_called()
        screen.get_wch.assert_not_called()

    def test_dispatch_reuses_canonical_focus_with_receipt_and_client(self):
        original_stdout, original_stderr = sys.stdout, sys.stderr

        def send(path, *, stdout, stderr):
            self.assertIs(sys.stdout, original_stdout)
            self.assertIs(sys.stderr, original_stderr)
            self.assertEqual(json.loads(path.read_text()), {"title": "draft"})
            stdout.write("opened")
            stderr.write("window: @42\n")
            return 0

        for focus_status in (0, 2, 3, 4):
            with self.subTest(focus_status=focus_status), tempfile.TemporaryDirectory() as directory, \
                    patch.dict(os.environ, {"FLEET_DISPATCH_GO_CMD": "", "FLEET_DISPATCH_SEND_CMD": ""}), \
                    patch.object(dispatch.compose, "send_path", return_value=Path(directory) / "send.json"), \
                    patch.object(dispatch.compose, "send", side_effect=send) as sender, \
                    patch.object(dispatch.subprocess, "run") as run, \
                    patch.object(fleet_view, "main", return_value=focus_status) as focus:
                self.assertTrue(dispatch.send({"title": "draft"}, "test-view", "test-client")[0])
            sender.assert_called_once()
            run.assert_not_called()
            focus.assert_called_once_with(
                ["go", "test-view", "@42", "--how", "dispatch", "--client", "test-client"], dispatch.quick)

    def test_dispatch_does_not_focus_without_a_successful_window_receipt(self):
        for status, receipt in ((0, ""), (0, "window: worker42\n"), (1, "window: @42\n")):
            with self.subTest(status=status, receipt=receipt), tempfile.TemporaryDirectory() as directory, \
                    patch.dict(os.environ, {"FLEET_DISPATCH_SEND_CMD": "test-sender"}), \
                    patch.object(dispatch.compose, "send_path", return_value=Path(directory) / "send.json"), \
                    patch.object(dispatch.compose, "keep_failed"), patch.object(dispatch, "failed"), \
                    patch.object(dispatch.subprocess, "run", return_value=SimpleNamespace(
                        returncode=status, stdout="result", stderr=receipt)), \
                    patch.object(fleet_view, "main") as focus:
                self.assertEqual(dispatch.send({"title": "draft"}, "test-view")[0], status == 0)
            focus.assert_not_called()

    def test_dispatch_calls_canonical_placement_without_another_python(self):
        for status in (0, 5):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "send.json"
                data = dict(title="draft", draft="literal #42", repo="acme/web", agent="codex")

                def place(argv, **options):
                    self.assertEqual(argv[:4], ["bash", str(BIN / "fleet-client-place.sh"), "acme/web", "scratch"])
                    self.assertIn("--draft-file", argv)
                    self.assertNotIn("--body-file", argv)
                    self.assertNotIn("--task", argv)
                    staged = Path(argv[argv.index("--draft-file") + 1])
                    self.assertEqual(staged.read_text(), data["draft"])
                    os.write(options["stderr"].fileno(), b"placement diagnostic\n")
                    Path(options["env"]["FLEET_PLACE_RESULT"]).write_text(json.dumps({
                        "window_id": "@42", "machine": dispatch.socket.gethostname().split(".")[0]}))
                    return SimpleNamespace(returncode=status, stdout="LOCAL mini\n" if status == 0 else "")

                with patch.dict(os.environ, {"FLEET_DISPATCH_SEND_CMD": "", "FLEET_DISPATCH_GO_CMD": ""}), \
                        patch.object(dispatch.compose, "send_path", return_value=path), \
                        patch.object(dispatch.compose, "state_path", return_value=Path(directory) / "state.json"), \
                        patch.object(dispatch.compose, "compose_log"), \
                        patch.object(dispatch, "authority", return_value="legacy"), \
                        patch.object(dispatch.subprocess, "run", side_effect=place) as run, \
                        patch.object(dispatch, "failed") as failed, patch.object(fleet_view, "main") as focus:
                    self.assertEqual(dispatch.send(data, "test-view")[0], status == 0)
                self.assertEqual(run.call_count, 1)
                if status == 0:
                    focus.assert_called_once()
                    failed.assert_not_called()
                else:
                    focus.assert_not_called()
                    failed.assert_called_once()
                    self.assertEqual(failed.call_args.args[2], "placement diagnostic")
                self.assertEqual(list(Path(directory).glob("fleet-compose-*")), [])

    def test_inprocess_sender_failure_keeps_draft_and_reports_error(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(os.environ, {"FLEET_DISPATCH_SEND_CMD": ""}), \
                patch.object(dispatch.compose, "send_path", return_value=Path(directory) / "send.json"), \
                patch.object(dispatch.compose, "send", side_effect=RuntimeError("placement failed")), \
                patch.object(dispatch.compose, "keep_failed") as keep, \
                patch.object(dispatch, "failed") as failed, patch.object(fleet_view, "main") as focus:
            data = {"title": "draft"}
            self.assertFalse(dispatch.send(data, "test-view")[0])
            keep.assert_called_once_with(Path(directory) / "send.json")
        failed.assert_called_once_with(data, "test-view", "RuntimeError: placement failed")
        focus.assert_not_called()

    def test_explicit_codex_draft_opens_once_cold(self):
        responses = [SimpleNamespace(returncode=0, stdout="@42\n", stderr="")]
        with patch.object(fleet_view, "view_fleet", return_value="test-fleet"), \
                patch.object(fleet_view.fleet_timing, "Clock"), \
                patch.object(fleet_view, "new_agent", side_effect=AssertionError("agent already selected")), \
                patch.object(fleet_view.subprocess, "run", side_effect=responses) as run, \
                patch.object(fleet_view, "go", return_value=0):
            self.assertEqual(fleet_view.go_new(None, "test-view", agent="codex", draft="literal #42"), 0)
        self.assertEqual(run.call_count, 1)
        for call in run.call_args_list:
            arguments = call.args[0]
            self.assertEqual(arguments[arguments.index("--agent") + 1], "codex")
            self.assertEqual(arguments[arguments.index("--draft") + 1], "literal #42")
            self.assertNotIn("--prompt", arguments)

    def test_panel_routes_draft_not_seed(self):
        quick = SimpleNamespace(__file__="quickopen.py")
        for repo in ("acme/web", ""):
            with self.subTest(repo=repo), patch.object(fleet_view, "bolt_repo", return_value=repo), \
                    patch.object(fleet_view, "bolt_agent", return_value="codex"), \
                    patch.object(fleet_view, "bolt_dflt", return_value="codex"):
                argv, title, where = fleet_view.bolt_argv(quick, "v1", "", {}, "检查 #42")
            self.assertIn("--draft", argv)
            self.assertEqual(argv[argv.index("--agent") + 1], "codex")
            self.assertNotIn("--prompt", argv)
            self.assertEqual(title, "检查 #42")

    def test_panel_preserves_resolved_agent_for_blank_and_typed_tasks(self):
        quick = SimpleNamespace(__file__="quickopen.py")
        for agent in fleet_view.AGENTS:
            for repo in ("acme/web", ""):
                for query in ("", "literal draft"):
                    with self.subTest(agent=agent, repo=repo, query=query), \
                            patch.object(fleet_view, "bolt_repo", return_value=repo), \
                            patch.object(fleet_view, "bolt_agent", return_value=agent), \
                            patch.object(fleet_view, "bolt_dflt", return_value=agent):
                        argv, _, _ = fleet_view.bolt_argv(quick, "v1", "", {}, query)
                    self.assertEqual(argv[argv.index("--agent") + 1], agent)

    def test_dispatch_preserves_long_literal_draft(self):
        draft = '检查 #42 "$(not-a-command)" ' + "完整文字" * 100
        with patch.object(dispatch, "send", return_value=(True, "opened")) as send:
            self.assertEqual(dispatch.main(["send", "--repo", "acme/web", "--title", draft, "--draft"]), 0)
        payload = send.call_args.args[0]
        self.assertEqual(payload["draft"], draft)
        self.assertEqual(payload["body"], "")
        self.assertEqual(payload["attachments"], [])
        self.assertFalse(payload["issue"])

    def test_compose_preserves_draft_without_issue_or_task(self):
        draft = "完整文字 #42 " * 40
        for repo in ("acme/web", None):
            with self.subTest(repo=repo), tempfile.TemporaryDirectory() as directory:
                payload = Path(directory) / "payload.json"
                payload.write_text(json.dumps(dict(title="short label", draft=draft, repo=repo, via="dispatch")))
                staged = []

                def place(argv, **kwargs):
                    self.assertEqual(argv[3], "scratch")
                    self.assertNotIn("--body-file", argv)
                    self.assertNotIn("--task", argv)
                    filename = Path(argv[argv.index("--draft-file") + 1])
                    self.assertEqual(filename.read_text(), draft)
                    staged.append(filename)
                    return SimpleNamespace(returncode=0, stdout="")

                with patch.object(compose.subprocess, "run", side_effect=place), \
                        patch.object(compose, "compose_log"):
                    self.assertEqual(compose.send(payload), 0)
                self.assertEqual(len(staged), 1)
                self.assertFalse(staged[0].exists())

    def test_node_rejects_ambiguous_or_oversize_drafts(self):
        valid = dict(kind="scratch", repo="acme/web", draft="检查 #42")
        validate_write("worker_start", valid)
        for extra in (dict(body="seed"), dict(task="T1"), dict(attachments=[]), dict(debug="abcdefgh"),
                      dict(kind="new", title="task"), dict(draft=""), dict(draft="x" * 4001)):
            with self.subTest(extra=extra), self.assertRaises(Fault):
                validate_write("worker_start", dict(valid, **extra))

    def test_adapter_mode_does_not_leak(self):
        controller = SimpleNamespace(environment=lambda: {"FLEET_CONTROL_DRAFT": "1"}, bin=BIN)
        with patch.object(fleet_control, "run", return_value=(0, "", "")) as run:
            fleet_control.Control.adapter(controller, "start", draft=True, payload=b"literal")
            self.assertEqual(run.call_args.kwargs["env"]["FLEET_CONTROL_DRAFT"], "1")
            fleet_control.Control.adapter(controller, "start", payload=b"seed")
            self.assertNotIn("FLEET_CONTROL_DRAFT", run.call_args.kwargs["env"])


if __name__ == "__main__":
    unittest.main()
