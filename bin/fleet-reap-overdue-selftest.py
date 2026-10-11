#!/usr/bin/env python3
"""bin/fleet-reap-overdue.py (issue #3352): who should have been reaped and was
not, by how long, and why. Inputs patched — the windows, the prmap, the landed
ledger and the cleanup daemon's log — so each rule is pinned on its own."""

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
BIN = Path(sys.argv.pop(1))
spec = importlib.util.spec_from_file_location("overdue", BIN / "fleet-reap-overdue.py")
od = importlib.util.module_from_spec(spec)
spec.loader.exec_module(od)

NOW = 1_791_730_000


def win(wid, **kv):
    w = {f: "" for f in od.FIELDS}
    w.update({"window_id": wid, "window_name": "w" + wid[1:]}, **kv)
    return w


class Overdue(unittest.TestCase):
    def run_with(self, wins, prs=None, landed=None, log=""):
        od._LOG.clear()
        od._LOG["lines"] = log.splitlines()
        with patch.object(od, "windows", return_value=wins), \
             patch.object(od, "merged_prs", return_value=prs or {}), \
             patch.object(od, "landed_at", return_value=landed or {}):
            return od.collect(NOW, 1800, ("/c", [("fleet", "acme/app")]))

    def test_merged_worker_past_grace_with_the_daemons_word(self):
        rows = self.run_with(
            [win("@3783", **{"@issue": "3302", "@claude_state": "done", "@reap_skip": "skip:done-recent",
                             "@worktree": "/p/app-issue-3302"})],
            prs={"issue-3302": "3306"}, landed={"3302": NOW - 600 - 1900},
            log="07:11:37 fleet-cleanup: fleet: idle cleanup deferred (rc=124)")
        self.assertEqual(len(rows), 1)
        r = rows[0]
        self.assertEqual((r["key"], r["why_due"], r["stuck"]), ("issue-3302", "PR #3306 merged", True))
        # the merged road's reason is the PR pass's, never the idle pass's token
        self.assertEqual(r["reason"], "cleanup daemon: idle cleanup deferred (rc=124)")

    def test_within_grace_working_and_unlanded_are_not_overdue(self):
        rows = self.run_with(
            [win("@1", **{"@issue": "1", "@claude_state": "done"}),
             win("@2", **{"@issue": "2", "@claude_state": "working"}),
             win("@3", **{"@issue": "3", "@claude_state": "done"})],
            prs={"issue-1": "11", "issue-2": "12", "issue-3": "13"},
            landed={"1": NOW - 300, "2": NOW - 9000})
        self.assertEqual(rows, [])

    def test_scratch_done_default_fifteen_minutes_claude_and_codex(self):
        rows = self.run_with(
            [win("@5", **{"@raw": "1", "@reap_policy": "done", "@claude_state": "done",
                          "@claude_state_ts": str(NOW - 1000), "@reap_skip": "skip:no-resume scratch-5 REVIEW",
                          "@worktree": "/p/app-scratch-5"}),
             win("@6", **{"@raw": "1", "@reap_policy": "done:15m", "@claude_state": "exited", "@cc_agent": "codex",
                          "@claude_state_ts": str(NOW - 3000), "@worktree": "/p/app-scratch-6"}),
             win("@7", **{"@raw": "1", "@reap_policy": "done:15m", "@claude_state": "done",
                          "@claude_state_ts": str(NOW - 600)}),
             win("@8", **{"@raw": "1", "@reap_policy": "keep", "@claude_state": "done", "@claude_state_ts": "1"})])
        self.assertEqual([(r["window"], r["agent"], r["stuck"]) for r in rows],
                         [("@6", "codex", True), ("@5", "claude", False)])
        self.assertEqual(rows[1]["reason"], "skip:no-resume scratch-5 REVIEW")

    def test_panels_and_norepo_never_count(self):
        rows = self.run_with([win("@9", **{"@norepo": "1", "@reap_policy": "done", "@claude_state": "done",
                                           "@claude_state_ts": "1"}),
                              win("@10", **{"@fleet_role": "home", "@reap_policy": "done", "@claude_state": "done",
                                            "@claude_state_ts": "1"})])
        self.assertEqual(rows, [])

    def test_landed_ledger_is_read_as_utc(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "logs").mkdir()
            (root / "logs" / "landed_acme-app.tsv").write_text(
                "2026-10-11T14:05:53Z\t3321\tt\t3323\n2026-10-11T15:00:00Z\t3321\tt\t3323\n")
            with patch.object(od, "BIN", root / "bin"):
                self.assertEqual(od.landed_at("acme/app"), {"3321": 1791727553})

    def test_no_fleet_prints_nothing_with_if_fleet(self):
        with patch.object(od, "fleets", return_value=("", [])), \
             patch.object(sys, "argv", ["x", "--if-fleet"]), \
             patch("builtins.print") as out:
            self.assertEqual(od.main(), 0)
        out.assert_not_called()
        with patch.object(od, "fleets", return_value=("", [])), \
             patch.object(sys, "argv", ["x", "--json"]), \
             patch("builtins.print") as out:
            od.main()
        self.assertEqual(json.loads(out.call_args[0][0])["overdue"], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
