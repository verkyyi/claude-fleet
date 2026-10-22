#!/usr/bin/env python3
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
"""Memory pressure cannot archive a wrapper without the safe park protocol.

Drive the old-wrapper compatibility boundary and admission refusal through
fleet-cleanup-idle.sh/.py and fleet-lib.sh. The real new-wrapper park path and
capacity release are driven by fleet-lifecycle-capacity-selftest.py.
"""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import unittest

sys.dont_write_bytecode = True
BIN = (Path(sys.argv.pop(1)) if len(sys.argv) > 1 and os.path.isdir(sys.argv[1]) else Path(__file__).absolute().parent)
sys.path.insert(0, str(BIN))
os.environ.pop("SELFTEST_PART", None)          # the Rig's one-budget mode is part 4/4's alone
_spec = importlib.util.spec_from_file_location("idle_rig", BIN / "fleet-cleanup-idle-selftest.py")
_rig = importlib.util.module_from_spec(_spec)
_argv, sys.argv = sys.argv, sys.argv[:1]
_spec.loader.exec_module(_rig)
sys.argv = _argv
Rig = _rig.Rig

FID = "7a1c5f0e-2b3d-4e5f-8a9b-0c1d2e3f4a5b"


@unittest.skipUnless(shutil.which("tmux"), "tmux absent")
class MakeRoom(Rig):

    def room(self, mb="1", *extra):
        return self.call("bash", str(self.ibin / "fleet-cleanup-idle.sh"), "--make-room", mb, *extra)

    def second(self, n=8, idle=4000):
        """Another finished scratch session in its own worktree."""
        wt = self.root / ("repo-scratch-%d" % n)
        self.call("git", "-C", str(self.main), "worktree", "add", "-qb", "scratch-%d" % n, str(wt))
        win = self.tm("new-window", "-d", "-P", "-F", "#{window_id}", "-t", self.label,
                      "-c", str(wt), "sleep 90").strip()
        for k, v in {"@raw": "1", "@worktree": str(wt), "@claude_state": "done",
                     "@claude_state_ts": str(int(time.time()) - idle), "@cc_agent": "claude"}.items():
            self.tm("set-option", "-w", "-t", win, k, v)
        tdir = self.root / "projects" / __import__("re").sub(r"[^A-Za-z0-9]", "-", str(wt))
        tdir.mkdir(parents=True)
        (tdir / "22222222-2222-4222-8222-222222222222.jsonl").write_text(
            '{"type":"user","message":{"role":"user","content":"other"}}\n')
        return win, wt

    def alive(self, win):
        return win in self.tm("list-windows", "-t", self.label, "-F", "#{window_id}").split()

    def restore(self):
        self.call("bash", str(self.ibin / "dash-restore-session.sh"), "landed:scratch:scratch-7", self.label)
        until = time.monotonic() + 5
        while not (self.root / "resume-args").exists() and time.monotonic() < until:
            time.sleep(0.05)
        return (self.root / "resume-args").read_text()

    def test_memory_pressure_never_archives_unwrapped_sessions(self):
        out = self.room()
        self.assertTrue(self.exists(), out)
        self.assertNotIn('folded:' + self.win, out)
        self.assertFalse((self.root / 'ledger.tsv').exists())
        self.assertTrue(self.transcript.is_file())

    def test_unwrapped_codex_keeps_its_identity_and_history(self):
        self.codexify()
        out = self.room()
        self.assertNotIn("folded:" + self.win, out)
        self.assertTrue(self.exists())
        self.assertFalse((self.root / "ledger.tsv").exists())
        self.assertTrue(self.wt.is_dir())

    def test_protected_and_unwrapped_sessions_are_never_folded(self):
        for key, value in (("@pin", "1"), ("@agent_def", "orchestrator"), ("@agent_def", "epic-driver"),
                           ("@reap_policy", "keep"), ("@claude_state", "working"),
                           ("@claude_state", "needs"), ("@claude_state", "looping"),
                           ("@claude_state_ts", str(int(time.time()) - 30)), ("@norepo", "1")):
            with self.subTest(key=key, value=value):
                old = self.tm("display-message", "-p", "-t", self.win, "#{" + key + "}").strip()
                self.set(key, value)
                out = self.room("100000")
                self.assertIn("0 folded", out)
                self.assertTrue(self.exists())
                if old:
                    self.set(key, old)
                else:
                    self.tm("set-option", "-wu", "-t", self.win, key)
        self.assertFalse((self.root / "ledger.tsv").exists())
        self.assertNotIn("would-fold:", self.room("1", "--dry-run"))
        self.assertTrue(self.exists())

    def test_completed_unwrapped_windows_wait_for_normal_reaper(self):
        done, _ = self.second(idle=120)
        self.tm("set-option", "-w", "-t", done, "@fleet_id", FID)
        self.call("python3", str(BIN / "fleet_id.py"), "result", FID, "--state", "merged", "--summary", "t695")
        out = self.room("1")
        self.assertNotIn("folded:", out)
        self.assertTrue(self.alive(done))
        self.assertTrue(self.exists())
        self.assertFalse((self.root / "ledger.tsv").exists())

    def test_memory_refusal_without_safe_parks_still_refuses(self):
        script = ('. "$1/fleet-lib.sh"; fleet_machine_admit() { '
                  'echo "machine memory tight — 暂停开新：内存紧张 (test)"; return 1; }; '
                  'fleet_admit_reserve() { :; }; fleet_session_cap_ok "$2"; echo "|rc=$?"')
        env = dict(self.env, FLEET_ADMIT="1", FLEET_ADMIT_MAKE_ROOM_SETTLE="0")
        p = subprocess.run(["bash", "-c", script, "t", str(self.ibin), self.label], env=env,
                           capture_output=True, text=True, timeout=120)
        self.assertIn("|rc=1", p.stdout, p.stdout + p.stderr)
        self.assertIn("memory tight", p.stdout)
        self.assertTrue(self.exists())
        self.assertFalse((self.root / "ledger.tsv").exists())
        p = subprocess.run(["bash", "-c", script, "t", str(self.ibin), self.label],
                           env=dict(env, FLEET_ADMIT_MAKE_ROOM="0"), capture_output=True, text=True, timeout=60)
        self.assertIn("|rc=1", p.stdout)
        self.assertNotIn("making room", p.stderr)

    def test_a_reopen_leaves_a_window_a_reaper_counts_down(self):
        now = int(time.time())
        script = ('. "$1/fleet-lib.sh"; fleet_cfg_expected_load() { FCFG_EXP_CLAUDE=new; FCFG_EXP_VER=v; }; '
                  'fleet_cfg_restart_why "$2" "$3" 0; echo "|rc=$?"')
        self.set("@agent_cfg", "old")
        def why():
            return subprocess.run(["bash", "-c", script, "t", str(self.ibin), self.label, self.win], env=self.env,
                                  capture_output=True, text=True, timeout=60).stdout.split("|")[0].strip()
        self.set("@reap_due", str(now + 600))
        self.set("@reap_seen", str(now))
        self.assertEqual(why(), "reap")
        self.set("@reap_seen", str(now - 3600))               # nobody counts it down any more
        self.assertNotEqual(why(), "reap")
        self.set("@reap_due", "hold")
        self.set("@reap_seen", str(now))
        self.assertNotEqual(why(), "reap")


if __name__ == "__main__":
    unittest.main(verbosity=2)
