#!/usr/bin/env python3
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

    def test_interactive_compose_keeps_localized_display_strings(self):
        with patch.object(compose, "load_text", return_value={"compose_empty": "localized"}) as load, \
                patch.object(compose.curses, "wrapper") as wrapper:
            self.assertEqual(compose.main([]), 0)
        load.assert_called_once_with()
        wrapper.assert_called_once_with(compose.ui, "")
        self.assertEqual(compose.TEXT["compose_empty"], "localized")

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
        for focus_status in (0, 2, 3, 4):
            with self.subTest(focus_status=focus_status), tempfile.TemporaryDirectory() as directory, \
                    patch.dict(os.environ, {"FLEET_DISPATCH_GO_CMD": "", "FLEET_DISPATCH_SEND_CMD": ""}), \
                    patch.object(dispatch.compose, "send_path", return_value=Path(directory) / "send.json"), \
                    patch.object(dispatch.subprocess, "run", return_value=SimpleNamespace(
                        returncode=0, stdout="opened", stderr="window: @42\n")) as run, \
                    patch.object(fleet_view, "main", return_value=focus_status) as focus:
                self.assertTrue(dispatch.send({"title": "draft"}, "test-view", "test-client")[0])
            self.assertEqual(run.call_count, 1)
            focus.assert_called_once_with(
                ["go", "test-view", "@42", "--how", "dispatch", "--client", "test-client"], dispatch.quick)

    def test_dispatch_does_not_focus_without_a_successful_window_receipt(self):
        for status, receipt in ((0, ""), (0, "window: worker42\n"), (1, "window: @42\n")):
            with self.subTest(status=status, receipt=receipt), tempfile.TemporaryDirectory() as directory, \
                    patch.object(dispatch.compose, "send_path", return_value=Path(directory) / "send.json"), \
                    patch.object(dispatch.compose, "keep_failed"), patch.object(dispatch, "failed"), \
                    patch.object(dispatch.subprocess, "run", return_value=SimpleNamespace(
                        returncode=status, stdout="result", stderr=receipt)), \
                    patch.object(fleet_view, "main") as focus:
                self.assertEqual(dispatch.send({"title": "draft"}, "test-view")[0], status == 0)
            focus.assert_not_called()

    def test_explicit_codex_draft_tries_warm_then_cold(self):
        responses = [SimpleNamespace(returncode=3, stdout="", stderr=""),
                     SimpleNamespace(returncode=0, stdout="@42\n", stderr="")]
        with patch.dict(os.environ, {"FLEET_START_WARM": "1"}), \
                patch.object(fleet_view, "view_fleet", return_value="test-fleet"), \
                patch.object(fleet_view.fleet_timing, "Clock"), \
                patch.object(fleet_view, "new_agent", side_effect=AssertionError("agent already selected")), \
                patch.object(fleet_view.subprocess, "run", side_effect=responses) as run, \
                patch.object(fleet_view, "go", return_value=0):
            self.assertEqual(fleet_view.go_new(None, "test-view", agent="codex", draft="literal #42"), 0)
        self.assertEqual(run.call_count, 2)
        self.assertIn("--warm-only", run.call_args_list[0].args[0])
        self.assertNotIn("--warm-only", run.call_args_list[1].args[0])
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
