#!/usr/bin/env python3
"""Submission boundaries: no draft overwrite, separate Enter, honest receipt."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("submit", Path(__file__).with_name("fleet-pane-submit.py"))
submit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(submit)


class Submission(unittest.TestCase):
    def run_submit(self, state="00 idle", occupied=False, error="", confirm=True):
        self.calls = []
        self.clock = 1000
        self.enters = 0

        def tm(argv, **kwargs):
            args = argv[3:]
            self.calls.append(args)
            if args[0] == error:
                raise subprocess.CalledProcessError(1, argv)
            if args[0] == "display-message":
                return "%7\n" if args[-1] == "#{pane_id}" else state + "\n"
            if args[0] == "send-keys":
                self.enters += 1
            return ""

        def snapshot(*args):
            # Empty before paste; a submitted turn empties only if confirmed.
            pasted = any(c[0] == "paste-buffer" for c in self.calls)
            return {"busy": occupied or (pasted and not (self.enters and confirm))}

        def sleep(secs):
            self.clock += round(secs * 1000)
            self.calls.append(["sleep", secs])

        output = io.StringIO()
        with patch.dict(os.environ, {"FLEET_SUBMIT_WAIT_SECS": "0", "FLEET_SUBMIT_CONFIRM_SECS": "3"}), \
                patch.object(submit.subprocess, "check_output", side_effect=tm), \
                patch.object(submit.prompt, "snapshot", side_effect=snapshot), \
                patch.object(submit.time, "sleep", side_effect=sleep), \
                patch.object(submit, "now_ms", side_effect=lambda: self.clock), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            rc = submit.submit("isolated", "@3", "首句\n$(); second line")
        return rc, output.getvalue()

    def test_one_paste_separate_enter_and_actual_timestamps(self):
        rc, out = self.run_submit()
        self.assertEqual((rc, out), (0, "1000\t1150\n"))
        writes = [c for c in self.calls if c[0] in ("set-buffer", "paste-buffer", "send-keys")]
        self.assertEqual([c[0] for c in writes], ["set-buffer", "paste-buffer", "send-keys"])
        self.assertEqual(writes[0][-1], "首句\n$(); second line")
        self.assertEqual(writes[-1][-1], "Enter")
        self.assertIn(["sleep", 0.15], self.calls)

    def test_draft_and_non_idle_panes_receive_nothing(self):
        for st, occupied in (("00 idle", True), ("10 idle", False), ("01 idle", False),
                             ("00 working", False), ("00 needs-input", False),
                             ("00 looping", False), ("00 waking", False)):
            with self.subTest(state=st):
                self.assertEqual(self.run_submit(st, occupied), (3, ""))
                self.assertFalse(any(c[0] in ("set-buffer", "paste-buffer", "send-keys") for c in self.calls))

    def test_unconfirmed_turn_retries_only_enter_and_has_no_success_receipt(self):
        self.assertEqual(self.run_submit(confirm=False), (4, ""))
        self.assertEqual(self.enters, 4)
        self.assertEqual(sum(c[0] == "paste-buffer" for c in self.calls), 1)

    def test_failed_paste_never_sends_enter(self):
        self.assertEqual(self.run_submit(error="paste-buffer"), (1, ""))
        self.assertEqual(self.enters, 0)
        self.assertTrue(any(c[0] == "delete-buffer" for c in self.calls))

    def test_failed_enter_never_claims_submission(self):
        self.assertEqual(self.run_submit(error="send-keys"), (1, ""))


if __name__ == "__main__":
    unittest.main()
