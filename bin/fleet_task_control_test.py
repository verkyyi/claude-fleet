#!/usr/bin/env python3
"""Isolated fixtures. Every external command/network road is denied or recorded."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import fleet_task_control as control


class TaskControlTests(unittest.TestCase):
    def test_unknown_does_not_become_done(self):
        self.assertEqual(control.verdict(None), "UNKNOWN")
        self.assertEqual(control.verdict(dict(state="running", outcome="")), "WAITING")
        self.assertEqual(control.verdict(dict(state="succeeded", outcome="succeeded")), "SUCCEEDED")
        self.assertEqual(control.verdict(dict(state="done", outcome="")), "WAITING")

    def test_await_is_retired_without_reads(self):
        with patch.object(control, "call", side_effect=AssertionError("no network")), contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(control.wait_task("T7", 7200, 1), 2)
        self.assertIn("RETIRED", out.getvalue())

    def test_closed_is_one_read_never_a_wait(self):
        # issue #4897: the reapers' reader — terminal ⇒ 0, open ⇒ 1, unknown ⇒ 3.
        for outcome, rc, word in (("succeeded", 0, "SUCCEEDED"), ("failed", 0, "FAILED"),
                                  ("cancelled", 0, "CANCELLED"), ("", 1, "WAITING")):
            t = dict(id="T7", authority_version=1, generation=1, state="running", outcome=outcome)
            with patch.object(control, "call", return_value={"task": t}) as calls, \
                 contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(control.closed("T7"), rc)
            self.assertEqual(calls.call_count, 1)
            self.assertTrue(out.getvalue().startswith(word + "\n"), out.getvalue())
        for answer in (ValueError("offline"), {"task": dict(id="T7", state="open")}):
            kw = dict(side_effect=answer) if isinstance(answer, Exception) else dict(return_value=answer)
            with patch.object(control, "call", **kw), contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(control.closed("T7"), 3)
            self.assertTrue(out.getvalue().startswith("UNKNOWN\n"))

    def test_worktree_read_retains_controlled_bindings_without_erasing_outcomes(self):
        for binding in ({"execution_endpoint": "node-a", "execution_owner": "fleet/worker"},
                        {"execution_endpoint": "node-a", "execution_owner": ""},
                        {"execution_owner": "", "cancel_request": "stop"}):
            for outcome in ("succeeded", "failed", "cancelled", "refused"):
                task = dict(id="T7", short="K7W0", authority_version=1, generation=3,
                            operation_id="next-start", state="closed", outcome=outcome, **binding)
                with self.subTest(binding=binding, outcome=outcome), \
                     patch.object(control, "call", return_value={"task": task}) as calls, \
                     contextlib.redirect_stdout(io.StringIO()) as out:
                    self.assertEqual(control.closed("T7", worktree=True), 1)
                    self.assertEqual(calls.call_count, 1)
                    self.assertTrue(out.getvalue().startswith("WAITING\n"))
                    self.assertEqual(control.verdict(task), outcome.upper())
                    self.assertEqual(task["outcome"], outcome)
        for binding in ({"execution_owner": None}, {"execution_endpoint": 1}):
            with patch.object(control, "call", return_value={"task": dict(id="T7", short="K7W0", authority_version=1, outcome="succeeded", **binding)}), \
                 contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(control.closed("T7", worktree=True), 3)
                self.assertTrue(out.getvalue().startswith("UNKNOWN\n"))
        legacy = dict(id="T7", short="K7W0", authority_version=1, generation=1, outcome="succeeded", operation_id="legacy")
        with patch.object(control, "call", return_value={"task": legacy}), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(control.closed("T7", worktree=True), 0)
        with patch.object(control, "call", side_effect=ValueError("unavailable")), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(control.closed("T7", worktree=True), 3)

    def test_shell_await_and_children_retired(self):
        for script, args in (("fleet-await.sh", ["T7", "--timeout", "7200"]), ("fleet-children.sh", ["--json"])):
            result = subprocess.run(["bash", str(control.BIN/script), *args], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 2, result.stdout+result.stderr)
            self.assertIn("RETIRED", result.stdout)

    def test_receive_refuses_before_any_read_or_delivery(self):
        with patch.object(control, "call", side_effect=AssertionError("no network")), \
                patch.object(control.subprocess, "run", side_effect=AssertionError("no delivery")), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(control.receive("/does-not-exist"), 2)
        self.assertIn("RETIRED", out.getvalue())

    def test_progress_goes_on_the_window_id(self):
        # EPIC T497 C12 / C8: the tick is a `progress` event on the window's own
        # ID's ledger — the task record is neither read nor written.
        import fleet_id
        fid = "3fa85f64-5717-4562-b3fc-2c963f66afa6"
        with tempfile.TemporaryDirectory() as d, \
             patch.dict(os.environ, FLEET_ID_DIR=d, FLEET_ID_PUSH="0"), \
             patch.object(control, "call") as hub, patch.object(control, "option", return_value=fid), \
             contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(control.progress("@7", "tick 5 · report: pending", "waiting", "tick-5"), 0)
            self.assertEqual(control.progress("@7", "tick 5 again", "waiting", "tick-5"), 0)
            hub.assert_not_called()
            pg = fleet_id.fold(fleet_id.read(fid))["progress"]
            self.assertEqual((pg["summary"], pg["event"], pg["seq"]), ("tick 5 · report: pending", "tick-5", 1))
        self.assertIn("id: " + fid, out.getvalue())
        with patch.object(control, "option", return_value=""), self.assertRaises(ValueError):
            control.progress("@7", "tick 6", "waiting")

    def test_children_summary_counts_outcomes(self):
        kids = [dict(outcome="succeeded"), dict(outcome="failed"), dict(outcome=""), dict()]
        self.assertEqual(control.child_summary(dict(children=kids)),
                         dict(open=2, succeeded=1, failed=1, cancelled=0, refused=0))
        hub = dict(open=0, succeeded=2, failed=0, cancelled=0, refused=0)
        self.assertEqual(control.child_summary(dict(children=kids, summary=hub)), hub)

    def test_cancel_a_record_no_window_opened(self):
        # claude-fleet#4964 / EPIC T497 C13: a record no window ever opened is
        # cancelled by one transition; the hub answers for one an ID carries.
        t = dict(id="T361", authority_version=1, owner="alice", generation=1, state="accepted")
        with patch.object(control, "call", side_effect=[dict(task=t), t]) as calls, contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(control.cancel("T361", "residual-T361"), 2)
        m = calls.call_args.args[2]
        self.assertEqual((calls.call_args.args[0], m["kind"], m["state"], m["expected_worker"]), ("mutate", "transition", "cancelled", ""))
        self.assertTrue(m["evidence"])
        self.assertIn("CANCELLED", out.getvalue())
        done = dict(t, outcome="cancelled")
        with patch.object(control, "call", return_value=dict(task=done)) as calls, contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(control.cancel("T361", "ev"), 0)
        self.assertEqual(calls.call_count, 1)
        self.assertIn("CANCELLED", out.getvalue())

    def test_one_code_names_the_task(self):
        t = dict(id="T7", short="K7W0", authority_version=1, outcome="succeeded")
        with patch.object(control, "call", return_value={"task": t}), contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(control.closed("K7W0"), 0)
        self.assertIn("K7W0", out.getvalue())
        self.assertNotIn("T7", out.getvalue())


if __name__ == "__main__":
    unittest.main()
