#!/usr/bin/env python3
# selftest-entry
"""Persistent names: isolated ledger, no service or production windows."""
import concurrent.futures
import os
import json
import subprocess
import shutil
import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import fleet_id as ids

A = "11111111-1111-4111-8111-111111111111"
B = "22222222-2222-4222-8222-222222222222"

class Titles(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        env = patch.dict(os.environ, FLEET_ID_DIR=self.tmp.name, FLEET_CONF_DIR=self.tmp.name, FLEET_ID_PUSH="0")
        env.start()
        self.addCleanup(env.stop)

    def test_creation_without_title(self):
        ids.open_id(A, {"agent": "claude"})
        self.assertEqual(ids.fold(ids.read(A))["opened"]["title"], "会话 " + ids.short_for(A, [A]))

    def test_hook_open_race_uses_named_not_another_opened_title(self):
        ids.open_id(A, {"lazy": True})
        ids.open_id(A, {"title": "spawn title"})
        evs = ids.read(A)
        self.assertEqual(ids.fold(evs)["opened"]["title"], "spawn title")
        self.assertEqual(evs[-1]["ev"], "named")
        self.assertNotEqual(evs[0]["title"], "spawn title")
        ids.record_title(A, "manual", "manual")
        ids.open_id(A, {"title": "reopen"})
        self.assertEqual(ids.fold(ids.read(A))["opened"]["title"], "manual")

    def test_name_close_reopen_and_manual_priority(self):
        ids.open_id(A, {"title": "initial"})
        ids.record_title(A, "automatic", "auto")
        ids.record_title(A, "My chosen name", "manual")
        ids.record_title(A, "stale automatic", "auto")
        ids.append(A, {"ev": "closed", "reason": "reaped"})
        rec = ids.fold(ids.read(A))
        self.assertEqual(rec["opened"]["title"], "My chosen name")
        self.assertIsNotNone(rec["closed"])
        ids.append(A, {"ev": "reopened"})
        ids.open_id(A, {"title": "restored placeholder"})
        self.assertEqual(ids.fold(ids.read(A))["opened"]["title"], "My chosen name")
        self.assertIsNone(ids.fold(ids.read(A))["closed"])

    def test_concurrent_names_and_dedup(self):
        ids.open_id(A, {})
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda n: ids.record_title(A, "chosen" if n == 5 else "auto", "manual" if n == 5 else "auto"), range(24)))
        before = ids.read(A)
        ids.record_title(A, "chosen", "manual")
        self.assertEqual(ids.read(A), before)
        self.assertEqual(ids.fold(before)["opened"]["title"], "chosen")
        self.assertEqual([e["seq"] for e in before], list(range(1, len(before)+1)))
        ids.open_id(B, {})
        self.assertNotEqual(ids.fold(ids.read(B))["opened"]["title"], "chosen")

    @unittest.skipUnless(shutil.which("tmux"), "tmux unavailable")
    def test_real_gate_and_terminal_rename_then_close(self):
        import fleet_session_gate as gate
        socket = "title-test-" + Path(self.tmp.name).name
        def tm(*args):
            return subprocess.check_output(["tmux", "-L", socket, *args], text=True).strip()
        tm("-f", "/dev/null", "new-session", "-d", "-s", "title-test", "sleep 90")
        self.addCleanup(lambda: subprocess.run(["tmux", "-L", socket, "kill-server"], capture_output=True))
        win = tm("display-message", "-p", "#{window_id}")
        tm("set-option", "-w", "-t", win, "@fleet_id", A)
        ids.open_id(A, {"window": win})
        with patch.object(gate, "locate", return_value=(socket, win)), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(gate.main(["name", "--fid", A, "--name", "web chosen"]), 0)
        self.assertEqual(ids.fold(ids.read(A))["opened"]["title"], "web chosen")
        env = dict(os.environ, TMUX=tm("display-message", "-p", "#{socket_path}")+",0,0")
        subprocess.run(["bash", str(Path(__file__).parent / "dash-rename.sh"), "--wid", win, "terminal chosen"], env=env, check=True)
        with self.assertRaises(ValueError):
            ids.name_window(win, "late auto", "auto", socket, A)
        self.assertEqual(tm("display-message", "-p", "-t", win, "#{window_name}"), "terminal chosen")
        ids.main(["close", A, "--reason", "reaped"])
        self.assertEqual(ids.fold(ids.read(A))["opened"]["title"], "terminal chosen")
        self.assertIsNotNone(ids.fold(ids.read(A))["closed"])
        with self.assertRaises(ValueError):
            ids.name_window(win, "wrong FID", socket=socket, fid=B)

    def test_audit_is_read_only_and_exact_identity(self):
        root = Path(self.tmp.name)
        board, proof = root / "board.json", root / "me.json"
        board.write_text(json.dumps({"board": {"rows": [{"id": A, "code": "BEXV", "group": "gone", "title": ""}]}}))
        proof.write_text(json.dumps({"read_only": True, "person": {"id": "owner"}}))
        ids.append(A, {"ev": "opened", "title": "original"})
        ids.append(A, {"ev": "closed"})
        raw = Path(ids.ledger_path(A)).read_bytes()
        audit = ids.title_audit(str(board), str(proof), [str(root)])
        self.assertEqual(audit["rows"][0]["candidate"], "original")
        self.assertEqual(audit["writes"], 0)
        self.assertEqual(Path(ids.ledger_path(A)).read_bytes(), raw)
        Path(ids.ledger_path(A)).write_bytes(raw.replace(A.encode(), B.encode()))
        audit = ids.title_audit(str(board), str(proof), [str(root)])
        self.assertEqual(audit["rows"][0]["source"], "invalid-ledger-review")
        self.assertEqual(audit["rows"][0]["candidate"], "")

    def test_old_hub_holds_named_suffix_then_retries(self):
        ids.open_id(A, {})
        ids.record_title(A, "chosen", "manual")
        ids.append(A, {"ev": "closed"})
        ack, supported = [0], [False]
        def call(method, path, body):
            if method == "GET":
                return (200, {"named": True}) if supported[0] else (400, {})
            for e in body["events"]:
                self.assertTrue(supported[0] or e["ev"] != "named")
                ack[0] = max(ack[0], e["seq"])
            return 200, {"seq": ack[0]}
        self.assertEqual(ids.push_one(A, call), 75)
        self.assertEqual(ack[0], 1)
        supported[0] = True
        self.assertEqual(ids.push_one(A, call), 0)
        self.assertEqual(ack[0], 3)

    def test_bounded_single_line_and_invalid(self):
        ids.open_id(A, {"title": "x" * 300 + "\nprivate second line"})
        title = ids.fold(ids.read(A))["opened"]["title"]
        self.assertLessEqual(len(title), 80)
        self.assertNotIn("private", title)
        ids.record_title(A, " \n ", "manual")
        self.assertEqual(ids.fold(ids.read(A))["opened"]["title"], title)

if __name__ == "__main__":
    unittest.main()
