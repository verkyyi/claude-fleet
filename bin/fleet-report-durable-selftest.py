#!/usr/bin/env python3
# selftest-entry
"""Own result history is durable; retired Parent delivery cannot block it.

Real result/ID scripts on a private tmux socket, without a live agent or Hub.
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

    def report(self, *extra, bindir=BIN):
        return self.run_cmd("bash", str(bindir / "fleet-report-parent.sh"), "-L", self.sock,
                            "--state", "stopped", "--outcome", "succeeded", "--summary", "durable result", *extra, check=False)

    def terminal(self):
        p = self.run_cmd("python3", str(BIN / "fleet_id.py"), "status", self.fid)
        return json.loads(p.stdout)["state"] in ("done", "failed")

    def test_result_saved_without_parent_delivery(self):
        p = self.report()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("RETIRED", p.stdout)
        self.assertIn("RECORDED", p.stdout)
        self.assertTrue(self.terminal())
        self.assertFalse((self.fleet / "peer-queue").exists())
        self.assertFalse((self.fleet / "children").exists())
        self.assertFalse((self.conf / "global" / "orphan-reports.ndjson").exists())

    def test_broken_old_delivery_stores_do_not_block_own_history(self):
        (self.fleet / "peer-queue").write_text("not a directory")
        (self.fleet / "children").write_text("not a directory")
        self.tm("set-option", "-w", "-t", self.child, "@origin", "scratch-999")
        (self.conf / "global" / "orphan-reports.ndjson").mkdir(parents=True)
        p = self.report()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertTrue(self.terminal())

    def test_failed_self_evidence_does_not_finalize(self):
        gate = self.conf / "session-gate" / self.fid
        gate.mkdir(parents=True, exist_ok=True)
        (gate / "report.json").mkdir()
        p = self.report()
        self.assertNotEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertFalse(self.terminal())
        self.assertEqual(self.tm("display-message", "-p", "-t", self.child,
                                 "#{@reap_report_pending}").strip(), "1")

    def test_hook_retired_without_result_or_parent_mutation(self):
        before = (self.conf / "ids" / (self.fid + ".ndjson")).read_bytes()
        p = self.run_cmd("bash", str(BIN / "fleet-report-parent.sh"), "-L", self.sock,
                         "--win", self.child, "--state", "stopped", "--only-once")
        self.assertIn("RETIRED", p.stdout)
        self.assertEqual((self.conf / "ids" / (self.fid + ".ndjson")).read_bytes(), before)
        self.assertFalse((self.fleet / "children").exists())

    def shadow(self):
        shadow = self.root / "bin"
        shadow.mkdir()
        for f in BIN.iterdir():
            (shadow/f.name).symlink_to(f)
        return shadow

    def test_merged_result_retains_real_merge_gate(self):
        shadow = self.shadow()
        (shadow/"fleet-lib.sh").unlink()
        (shadow/"fleet-lib.sh").write_text('. "'+str(BIN/'fleet-lib.sh')+'"\n'
            'fleet_window_repo() { printf "acme/widgets\\n"; }\n'
            'fleet_pr_merge_state() { printf "%s\\n" "$D2_PR_STATE"; }\n')
        for state, expected in (("merged", "merged"), ("armed", "waiting"), ("open", "waiting"),
                                ("closed", "failed"), ("unknown", "idle")):
            with self.subTest(state=state):
                self.env["D2_PR_STATE"] = state
                p = self.report("--state", "merged", "--pr", "77", bindir=shadow)
                self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
                rows = [json.loads(l) for l in (self.conf/"ids"/(self.fid+".ndjson")).read_text().splitlines()]
                self.assertEqual([r for r in rows if r.get("ev") == "result"][-1]["state"], expected)
        self.assertFalse((self.fleet/"peer-queue").exists())

    def test_failed_finish_keeps_pending_until_own_result_saved(self):
        shadow = self.shadow()
        (shadow/"fleet_reap_policy.py").unlink()
        (shadow/"fleet_reap_policy.py").write_text('import runpy,sys\n'
            'if sys.argv[1] == "report-finish": sys.exit(1)\n'
            'runpy.run_path('+repr(str(BIN/'fleet_reap_policy.py'))+', run_name="__main__")\n')
        p = self.report(bindir=shadow)
        self.assertNotEqual(p.returncode, 0, p.stdout+p.stderr)
        proof = self.conf/"session-gate"/self.fid/"report.json"
        self.assertEqual(json.loads(proof.read_text())["phase"], "pending")
        self.assertFalse(self.terminal())
        p = self.report()
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        self.assertEqual(json.loads(proof.read_text())["phase"], "complete")
        self.assertTrue(self.terminal())


if __name__ == "__main__":
    unittest.main()
