#!/usr/bin/env python3
# selftest-entry
"""Parent retirement preserves ID history and explicit conversation continuation."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

BIN = Path(__file__).resolve().parent


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, BIN / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


fid = module("fleet_id", "fleet_id.py")
mcp = module("fleet_mcp_retirement", "fleet-mcp.py")
transfer = module("fleet_transfer_retirement", ".fleet-transfer.py")
OLD = "11111111-1111-4111-8111-111111111111"
PARENT = "22222222-2222-4222-8222-222222222222"
NEXT = "33333333-3333-4333-8333-333333333333"


class ParentRetirement(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        env = patch.dict(os.environ, {"FLEET_ID_DIR": self.tmp.name, "FLEET_ID_PUSH": "0"})
        env.start()
        self.addCleanup(env.stop)

    def history(self):
        fid.append(OLD, {"ev": "opened", "parent": PARENT, "task": "T77", "agent": "claude"})
        fid.append(OLD, {"ev": "native", "native": "native-old", "agent": "claude", "seg": 1})
        fid.append(OLD, {"ev": "closed", "reason": "exited"})
        fid.open_id(PARENT, {"agent": "claude"})
        return Path(fid.ledger_path(OLD)).read_bytes()

    def test_new_id_ignores_legacy_parent_fields(self):
        fid.open_id(NEXT, {"parent": PARENT, "origin": "issue-7", "origin_fid": PARENT,
                           "origin_wid": "fleet/" + PARENT, "origin_gen": "7", "origin_retired": "scratch-7#3",
                           "prev": OLD, "task": "T77", "agent": "codex"})
        opened = fid.fold(fid.read(NEXT))["opened"]
        for key in ("parent", "origin", "origin_fid", "origin_wid", "origin_gen", "origin_retired"):
            self.assertNotIn(key, opened)
        self.assertEqual((opened["prev"], opened["task"], opened["agent"]), (OLD, "T77", "codex"))

    def test_no_parent_route_and_history_unchanged(self):
        before = self.history()
        self.assertEqual(fid.route(OLD, [PARENT]), ("", ""))
        self.assertEqual(fid.fold(fid.read(OLD))["opened"]["parent"], PARENT)
        self.assertEqual(Path(fid.ledger_path(OLD)).read_bytes(), before)

    def test_prev_successor_still_receives(self):
        before = self.history()
        fid.open_id(NEXT, {"prev": OLD, "agent": "claude"})
        self.assertEqual(fid.route(OLD, [PARENT, NEXT]), (NEXT, "successor"))
        self.assertEqual(fid.route(NEXT, [NEXT]), (NEXT, "self"))
        self.assertEqual(Path(fid.ledger_path(OLD)).read_bytes(), before)

    def test_continue_retains_native_and_task_without_parent(self):
        before = self.history()
        plan = fid.continue_plan(OLD)
        self.assertEqual((plan["id"], plan["task"], plan["native"]), (OLD, "T77", "native-old"))
        self.assertFalse(plan.get("parent"))
        self.assertEqual(Path(fid.ledger_path(OLD)).read_bytes(), before)

    def test_parent_apply_refuses_without_reading_hub_or_writing(self):
        before = self.history()
        with patch.object(fid, "_task_parent", side_effect=AssertionError("must not read hub")), \
                contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(fid.parents_cmd(True), 2)
        self.assertIn("PARENT_RETIRED", err.getvalue())
        self.assertEqual(Path(fid.ledger_path(OLD)).read_bytes(), before)

    def test_send_parent_refuses_before_resolver_or_delivery(self):
        with patch.object(mcp, "parent_window", side_effect=AssertionError("must not resolve parent")), \
                patch.object(mcp, "run", side_effect=AssertionError("must not send")):
            with self.assertRaisesRegex(mcp.Refused, "PARENT_RETIRED"):
                mcp.send_message("parent", "legacy message")

    def test_transfer_checks_identity_without_reviving_historical_parent(self):
        bundle = Path(self.tmp.name) / "bundle"
        bundle.mkdir()
        manifest = bundle / "manifest.json"
        identity = {"fleet_id": OLD, "task": "T77", "fleet_role": "worker", "origin": "scratch-7"}
        body = {"target": {"agent": "claude"}, "workspace": {"kind": "norepo", "path": str(Path(self.tmp.name).resolve())},
                "fleet": {"identity": identity}}
        registry = bundle / "native.json"
        registry.write_text(json.dumps({"cwd": self.tmp.name, "sessionId": "native-old"}))

        def run(*args):
            if args[0] == "bash":
                return "123\n" + str(registry)
            return {"#{@cc_agent}": "claude", "#{@handoff_manifest}": str(manifest)}[args[-1]]

        current = dict(identity, origin="", origin_gen="")
        with patch.object(transfer, "run", side_effect=run), \
                patch.object(transfer.runpy, "run_path", return_value={"identity": lambda *args: current}), \
                contextlib.redirect_stdout(io.StringIO()):
            # Legacy manifest is readable after runtime Parent fields are cleared.
            manifest.write_text(json.dumps(body))
            transfer.target_ready(bundle, "fixture", "%1")
            self.assertEqual(json.loads(manifest.read_text())["target"]["session_id"], "native-old")
            for key, changed in (("fleet_id", NEXT), ("task", "T78"), ("fleet_role", "panel")):
                with self.subTest(key=key):
                    current[key] = changed
                    manifest.write_text(json.dumps(body))
                    with self.assertRaisesRegex(ValueError, "lifelong identity"):
                        transfer.target_ready(bundle, "fixture", "%1")
                    current[key] = identity[key]

    @unittest.skipUnless(shutil.which("tmux"), "tmux unavailable")
    def test_broken_out_pane_keeps_identity_without_parent_options(self):
        socket = str(Path(self.tmp.name) / "tmux.sock")
        env = dict(os.environ, TMUX=socket + ",1,0")

        def tmux(*args):
            return subprocess.check_output(["tmux", "-S", socket, *args], text=True, env=env).strip()

        subprocess.check_call(["tmux", "-S", socket, "-f", "/dev/null", "new-session",
                               "-d", "-s", "fixture", "-n", "task", "sleep 60"], env=env)
        self.addCleanup(lambda: subprocess.run(["tmux", "-S", socket, "kill-server"],
                                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        pane = tmux("display-message", "-p", "#{pane_id}")
        oldwin = tmux("display-message", "-p", "#{window_id}")
        tmux("set-option", "-p", "-t", pane, "@wrap_win", oldwin)
        identity = {"@fleet_id": OLD, "@cc_session_id": "native-old", "@task": "T77", "@fleet_role": "worker"}
        ancestry = {"@origin": "issue-7", "@origin_fid": PARENT, "@origin_wid": "fleet/" + PARENT,
                    "@origin_gen": "3", "@origin_retired": "scratch-7#2"}
        for key, value in {**identity, **ancestry}.items():
            tmux("set-option", "-w", "-t", oldwin, key, value)
        before = self.history()
        tmux("split-window", "-d", "-t", oldwin, "sleep 60")
        tmux("break-pane", "-d", "-s", pane)
        newwin = tmux("display-message", "-p", "-t", pane, "#{window_id}")
        self.assertNotEqual(oldwin, newwin)
        subprocess.check_call(["bash", str(BIN / "fleet-window-carry.sh"), newwin], env=env)
        for key, value in identity.items():
            self.assertEqual(tmux("show-options", "-wqv", "-t", newwin, key), value)
        for key in ancestry:
            self.assertEqual(tmux("show-options", "-wqv", "-t", newwin, key), "", key)
        self.assertEqual(Path(fid.ledger_path(OLD)).read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
