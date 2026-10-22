#!/usr/bin/env python3
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
"""T695 (回收 C): a spawn memory would refuse first folds what it can.

`fleet-cleanup-idle.sh --make-room <MB>` (fleet-cleanup-idle.py --plan-room /
--fold) folds the done sessions first, then the longest idle — history first and
resumable, the window closed, the worktree kept — and never a pinned one, an
orchestrator, `keep`, one working / asking / recent. A folded session comes back
from 已收起 with its own conversation (dash-restore-session.sh: Claude --resume,
Codex its identity). fleet_session_cap_ok makes room before a memory refusal and
asks again; fleet_cfg_restart_why leaves a window a reaper counts down alone.
Drives bin/fleet-cleanup-idle.sh, bin/fleet-cleanup-idle.py, bin/fleet-lib.sh
(fleet_admit_make_room, fleet_session_cap_ok, fleet_cfg_restart_why),
bin/dash-restore-session.sh on the Rig of fleet-cleanup-idle-selftest.py.
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

    def test_an_idle_session_is_folded_and_comes_back_with_its_conversation(self):
        out = self.room()
        self.assertIn("folded:" + self.win + " scratch-7", out)
        self.assertIn("1 folded", out)
        self.assertFalse(self.exists())
        self.assertTrue(self.wt.is_dir())                      # the worktree kept
        self.assertTrue(self.transcript.is_file())
        self.assertIn("Folded to make room", (self.root / "ledger.tsv").read_text())
        self.assertIn("--resume\n" + self.sid, self.restore())  # 已收起 ↵: the same conversation

    def test_a_codex_session_folds_and_resumes_its_own_identity(self):
        home = self.root / "codex-home"
        self.codexify()
        self.assertIn("folded:" + self.win, self.room())
        self.assertFalse(self.exists())
        args = self.restore()
        self.assertIn("--agent\ncodex\n--codex-home\n" + str(home), args)
        self.assertIn(self.sid, args)

    def test_pinned_orchestrator_keep_working_asking_and_recent_are_never_folded(self):
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
        self.assertIn("would-fold:" + self.win, self.room("1", "--dry-run"))
        self.assertTrue(self.exists())

    def test_done_ones_go_before_the_longest_idle_and_it_stops_at_enough(self):
        done, _ = self.second(idle=120)                         # recent, but its work is over
        self.tm("set-option", "-w", "-t", done, "@fleet_id", FID)
        self.call("python3", str(BIN / "fleet_id.py"), "result", FID, "--state", "merged", "--summary", "t695")
        out = self.room("1")
        self.assertIn("folded:" + done + " scratch-8", out)
        self.assertNotIn("folded:" + self.win, out)            # enough freed: the idle one stays
        self.assertFalse(self.alive(done))
        self.assertTrue(self.exists())
        self.assertIn("folded:" + self.win, self.room("1"))    # asked again: the idle one goes

    def test_a_memory_refusal_folds_first_then_admits(self):
        # the machine's reading is faked: tight until a fold is on the ledger
        script = ('. "$1/fleet-lib.sh"; fleet_machine_admit() { if ! grep -q "Folded to make room" '
                  '"$FLEET_HISTORY_LEDGER" 2>/dev/null; then echo "machine memory tight — 暂停开新：内存紧张 (test)"; '
                  'return 1; fi; return 0; }; fleet_admit_reserve() { :; }; '
                  'fleet_session_cap_ok "$2"; echo "|rc=$?"')
        env = dict(self.env, FLEET_ADMIT="1", FLEET_ADMIT_MAKE_ROOM_SETTLE="0")   # the gate pins FLEET_ADMIT=0
        p = subprocess.run(["bash", "-c", script, "t", str(self.ibin), self.label], env=env,
                           capture_output=True, text=True, timeout=120)
        self.assertIn("|rc=0", p.stdout, p.stdout + p.stderr)
        self.assertIn("making room: folded:" + self.win, p.stderr, p.stdout + p.stderr)
        self.assertFalse(self.exists())
        # nothing may be folded: refused, and said why
        self.second(n=9)
        always = script.replace('if ! grep -q "Folded to make room" "$FLEET_HISTORY_LEDGER" 2>/dev/null; then',
                                'if :; then')
        p = subprocess.run(["bash", "-c", always, "t", str(self.ibin), self.label],
                           env=dict(env, FLEET_ADMIT_MAKE_ROOM="0"), capture_output=True, text=True, timeout=60)
        self.assertIn("memory tight", p.stdout)
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
