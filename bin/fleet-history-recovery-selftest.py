#!/usr/bin/env python3
"""History resolution never depends on a live window or a preserved worktree."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import fleet_id
import fleet_history_read

FID = "11111111-1111-4111-8111-111111111111"
SID = "22222222-2222-4222-8222-222222222222"

class Recovery(unittest.TestCase):
    def test_migrated_codex_placement(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {"FLEET_CONF_DIR": tmp}):
            root = Path(tmp)
            home = root / "moves" / "codex" / SID
            files = home / "sessions" / "2000" / "01" / "01"
            files.mkdir(parents=True)
            wt = root / "preserved"
            wt.mkdir()
            (home / "move.json").write_text(json.dumps({"format": 1, "agent": "codex", "sid": SID, "metadata": {"@fleet_id": FID}}))
            (files / ("rollout-" + SID + ".jsonl")).write_text(json.dumps({"type": "session_meta", "payload": {"id": SID, "cwd": str(wt)}}) + "\n")
            events = [{"ev": "opened", "worktree": "/missing/source", "repo": "o/r"},
                      {"ev": "native", "agent": "codex", "native": SID}]
            with patch.object(fleet_id, "read", return_value=events):
                plan = fleet_id.continue_plan(FID)
                self.assertEqual(plan["worktree"], str(wt))
                self.assertEqual(plan["codex_home"], str(home))
                self.assertEqual(plan["native"], SID)
                self.assertTrue(fleet_history_read.history(FID)["resumable"])
                wt.rmdir()
                history = fleet_history_read.history(FID)
                self.assertEqual(history["history_status"], "readable")
                self.assertFalse(history["resumable"])
                self.assertEqual(history["codex_home"], str(home))
                # An import for another FID is never a landing receipt for this one.
                (home / "move.json").write_text(json.dumps({"format": 1, "agent": "codex", "sid": SID, "metadata": {"@fleet_id": SID}}))
                self.assertNotEqual(fleet_id.continue_plan(FID)["worktree"], str(wt))

if __name__ == "__main__":
    unittest.main()
