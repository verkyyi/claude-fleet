#!/usr/bin/env python3
# selftest-entry
"""C6: fleet-report-parent.sh must persist reports before terminal reaping.

Real report/ID/queue scripts, sandbox config and a private tmux socket. No live
agent or hub: the sleeping parent's durable queue is the delivery contract.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import uuid

BIN = Path(__file__).resolve().parent


class DurableReport(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="c6-report-")
        self.root = Path(self.tmp.name)
        self.sock = "c6-report-" + uuid.uuid4().hex[:12]
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("FLEET_", "CCQUOTA_")) and k not in ("TMUX", "TMUX_PANE")}
        self.conf = self.root / "conf"
        self.fleet = self.conf / "fleets" / self.sock
        self.fleet.mkdir(parents=True)
        (self.fleet / "conf").write_text("FLEET_CHILD_REPORT=immediate\n")
        self.env.update(HOME=str(self.root), FLEET_CONF_DIR=str(self.conf), FLEET_SKIP_GLOBAL_CONF="1",
                        FLEET_REAP_NOW="0", FLEET_ID_LIVE="[]", FLEET_SESSION=self.sock)
        self.tm("-f", "/dev/null", "new-session", "-d", "-s", self.sock, "sleep 300")
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(lambda: self.tm("kill-server", check=False))
        self.parent = self.tm("new-window", "-d", "-P", "-F", "#{window_id}", "sleep 300").strip()
        self.tm("set-option", "-w", "-t", self.parent, "@worktree", str(self.root / "repo-scratch-1"))
        self.tm("set-option", "-w", "-t", self.parent, "@raw", "1")
        self.child = self.tm("new-window", "-d", "-P", "-F", "#{window_id}", "sleep 300").strip()
        self.fid = str(uuid.uuid4())
        for k, v in {"@origin": "scratch-1", "@fleet_id": self.fid, "@task": "T42",
                     "@raw": "1", "@claude_state": "done", "@worktree": str(self.root / "repo-scratch-2")}.items():
            self.tm("set-option", "-w", "-t", self.child, k, v)
        self.env["TMUX_PANE"] = self.tm("display-message", "-p", "-t", self.child, "#{pane_id}").strip()
        self.env["TMUX"] = self.tm("display-message", "-p", "#{socket_path},#{pid},0").strip()
        self.run_cmd("python3", str(BIN / "fleet_id.py"), "open", self.fid, "--window", self.child, "--socket", self.sock)

    def run_cmd(self, *args, check=True):
        p = subprocess.run(args, env=self.env, text=True, capture_output=True, timeout=25)
        if check:
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        return p

    def tm(self, *args, check=True):
        return self.run_cmd("tmux", "-L", self.sock, *args, check=check).stdout

    def report(self):
        return self.run_cmd("bash", str(BIN / "fleet-report-parent.sh"), "-L", self.sock,
                            "--state", "stopped", "--outcome", "succeeded", "--summary", "durable result", check=False)

    def terminal(self):
        p = self.run_cmd("python3", str(BIN / "fleet_id.py"), "status", self.fid)
        return json.loads(p.stdout)["state"] in ("done", "failed")

    def test_durable_queue_does_not_require_network_delivery(self):
        p = self.report()
        self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
        self.assertTrue(list((self.fleet / "peer-queue").glob("*.json")))
        self.assertTrue(self.terminal())

    def test_failed_queue_does_not_finalize(self):
        (self.fleet / "peer-queue").write_text("not a directory")
        p = self.report()
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertFalse(self.terminal(), "report persistence failed, but ID became terminal")
        import sys
        sys.path.insert(0, str(BIN))
        spec = importlib.util.spec_from_file_location("idle", BIN / "fleet-cleanup-idle.py")
        idle = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(idle)
        cleaner = idle.Cleaner.__new__(idle.Cleaner)
        cleaner.id_over = lambda fid: True  # an older terminal result must not bypass the failed report
        cleaner.task_closed = lambda task: 0
        with patch.dict(os.environ, self.env, clear=True):
            self.assertFalse(cleaner.work_over({"@fleet_id": self.fid, "@task": "T42"}))
            row = idle.fleet_reap_policy.explain({"@fleet_id": self.fid, "@parked": "1",
                                                "@park_held": "1", "@park_since": "1"})
            self.assertIn("next=after-report-saved why=report-pending", row)
            self.assertNotIn("next=reap@", row)


    def test_failed_batch_ledger_does_not_finalize(self):
        (self.fleet / "conf").write_text("FLEET_CHILD_REPORT=batch\n")
        (self.fleet / "children").write_text("not a directory")
        p = self.report()
        self.assertNotEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertFalse(self.terminal(), "batch delivery ledger failed, but ID became terminal")

    def test_failed_orphan_ledger_does_not_finalize(self):
        self.tm("set-option", "-w", "-t", self.child, "@origin", "scratch-999")
        path = self.conf / "global" / "orphan-reports.ndjson"
        path.mkdir(parents=True)
        p = self.report()
        self.assertNotEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertFalse(self.terminal(), "orphan report not saved, but ID became terminal")

    def test_hub_spawned_session_has_no_required_parent_delivery(self):
        self.tm("set-option", "-w", "-t", self.child, "@origin", "")
        p = self.report()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertTrue(self.terminal())


if __name__ == "__main__":
    unittest.main()
