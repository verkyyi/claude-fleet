#!/usr/bin/env python3
"""Fake process snapshots plus a bounded agent on an isolated tmux socket."""

import importlib.util
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
BIN = Path(sys.argv.pop(1))
spec = importlib.util.spec_from_file_location("live", BIN / "fleet-reap-live.py")
live = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)


class LiveTests(unittest.TestCase):
    def probe(self, state="done", comm="claude", age="00:10", commands=None, roots="100\n", minimum=1800, lifecycle="", hold="",
              merged_at=None, waived=None, now=None, loop="\t"):
        outputs = iter([hold, loop, lifecycle, state, roots, f"100 1 01:00:00 zsh\n101 100 {age} {comm}\n102 1 00:01 codex\n",
                        commands if commands is not None else f"100 zsh\n101 {comm}\n102 codex\n"])
        with patch.object(live, "read", side_effect=lambda *args: next(outputs)):
            return live.live_reason("@1", minimum, None, merged_at, waived, now)

    def test_retained_workers_are_never_automatically_reaped(self):
        for phase in ('preparing','waking','failed'):
            self.assertEqual(self.probe(minimum=0,lifecycle=phase),'retained:'+phase)

    def test_sleepers_are_reapable_without_a_wake(self):
        # Issue #1244: the park page is no agent — no age gate applies.
        self.assertIsNone(self.probe(lifecycle="sleeping", comm="python3"))
        # ...but a looping sleeper has a scheduled wake pending: state still gates.
        self.assertEqual(self.probe(lifecycle="sleeping", comm="python3", state="looping"), "state:looping")
        # ...but ANY agent under a sleeper (a wake mid-flight) retains it, old or young.
        for age in ("00:10", "10:00:00"):
            self.assertEqual(self.probe(lifecycle="sleeping", age=age), "retained:sleeping:agent-claude")
        self.assertEqual(self.probe(lifecycle="sleeping", comm="node", commands=""), "unknown:agent-command")

    def test_hold_retains_any_worker(self):
        for lifecycle in ("", "sleeping"):
            self.assertEqual(self.probe(minimum=0, lifecycle=lifecycle, hold="1"), "retained:hold")

    def test_pending_loop_retains_ahead_of_age_and_state(self):
        # Issue #1331: a worker between /loop rounds is idle, not finished.
        now = int(time.time())
        wake = f"kind=wakeup next={now+1800} ttl=1800\t"
        for lifecycle, state in (("", "done"), ("", "looping"), ("sleeping", "done"), ("waking", "done")):
            self.assertEqual(self.probe(minimum=0, lifecycle=lifecycle, state=state, loop=wake), "retained:loop")
        self.assertEqual(self.probe(age="10:00:00", loop=f"kind=cron id=ab12@{now+600}\t"), "retained:loop")
        # a wakeup nobody renewed, past next + grace, no longer holds the window
        stale = f"kind=wakeup next={now-3600} ttl=1800\t"
        self.assertIsNone(self.probe(minimum=0, loop=stale))
        # a hold still answers first
        self.assertEqual(self.probe(hold="1", loop=wake), "retained:hold")
        # a fleet-loop.py ledger that will still deliver is a Loop too
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "loop").mkdir()
            for status, want in (("active", "retained:loop"), ("hibernating", "retained:loop"), ("stopped", None)):
                (Path(d) / "loop/state.json").write_text('{"status": "%s"}' % status)
                self.assertEqual(self.probe(minimum=0, loop="\t" + d + "/manifest.json"), want)

    def test_awake_young_agent_still_refused(self):
        self.assertTrue(self.probe(state="done").startswith("young-agent:claude:"))

    def test_merged_during_agent_life_waives_age_gate(self):
        # Issue #1329: agent 600s old (started at NOW-600).
        NOW = 1_000_000
        waived = []
        self.assertIsNone(self.probe(age="10:00", merged_at=NOW-300, now=NOW, waived=waived))
        self.assertEqual(waived, ["claude:600s<1800s"])
        # Spawned onto an already-merged branch: merge precedes the agent → protected (#565).
        self.assertEqual(self.probe(age="10:00", merged_at=NOW-900, now=NOW), "young-agent:claude:600s<1800s")
        self.assertEqual(self.probe(age="10:00", merged_at=NOW-600, now=NOW), "young-agent:claude:600s<1800s")
        # Unknown etime / future merge never waive.
        self.assertTrue(self.probe(age="bad", merged_at=NOW-1, now=NOW).startswith("young-agent:"))
        self.assertTrue(self.probe(age="10:00", merged_at=NOW+5, now=NOW).startswith("young-agent:"))
        # Empty state is not done: a fresh worker stays protected.
        self.assertTrue(self.probe(state="", age="10:00", merged_at=NOW-300, now=NOW).startswith("young-agent:"))
        # Every other gate still applies.
        self.assertEqual(self.probe(hold="1", age="10:00", merged_at=NOW-300, now=NOW), "retained:hold")
        self.assertEqual(self.probe(state="working", age="10:00", merged_at=NOW-300, now=NOW), "state:working")
        self.assertEqual(self.probe(comm="node", commands="", age="10:00", merged_at=NOW-300, now=NOW), "unknown:agent-command")
        # Without --merged-at: unchanged.
        self.assertEqual(self.probe(age="10:00"), "young-agent:claude:600s<1800s")

    def test_merged_at_cli_output(self):
        NOW = 1_000_000
        def run(*extra):
            replies = iter(["", "\t", "", "done", "100", "100 1 01:00:00 zsh\n101 100 10:00 claude", "100 zsh\n101 claude"])
            out = []
            with patch.object(sys, "argv", ["probe", "@1", *extra]), \
                 patch.object(live, "read", side_effect=lambda *a: next(replies)), \
                 patch.object(live.time, "time", return_value=NOW), \
                 patch("builtins.print", side_effect=lambda *a: out.append(" ".join(map(str, a)))):
                return live.main(), out
        self.assertEqual(run(), (1, ["young-agent:claude:600s<1800s"]))
        self.assertEqual(run("--merged-at", str(NOW-300)), (0, ["waived:young-agent:claude:600s<1800s"]))
        self.assertEqual(run("--merged-at", str(NOW-900)), (1, ["young-agent:claude:600s<1800s"]))
        for bad in ("0", "abc", "-5", ""):
            self.assertEqual(run("--merged-at", bad), (1, ["young-agent:claude:600s<1800s"]))

    def test_state_never_overridden_by_age_knob(self):
        for state in ("working", "looping", "busy", "waiting", "unknown"):
            self.assertEqual(self.probe(state=state, minimum=0), "state:"+state)

    def test_agents_must_age_in_all_panes(self):
        for comm in ("claude", "codex", "codex-real", "/opt/bin/codex"):
            self.assertTrue(self.probe(comm=comm).startswith("young-agent:"))
            self.assertIsNone(self.probe(comm=comm, age="30:00"))
            self.assertIsNone(self.probe(comm=comm, minimum=0))
        self.assertTrue(self.probe(state="").startswith("young-agent:"))
        self.assertTrue(self.probe(age="bad").startswith("young-agent:"))
        self.assertTrue(self.probe(roots="100\n102\n", age="01:00:00").startswith("young-agent:"))

    def test_node_clis_and_unrelated_shells(self):
        for cmd in ("node /x/claude-code/cli.js", "bun /x/claude", "node /x/@openai/codex/bin/codex.js"):
            self.assertTrue(self.probe(comm="node", commands="101 "+cmd).startswith("young-agent:"))
        self.assertIsNone(self.probe(comm="node", commands="101 node server.js"))
        self.assertIsNone(self.probe(comm="bash", commands="101 bash -c echo codex"))
        self.assertIsNone(self.probe(comm="sleep"))  # unrelated young codex pid102 is not a descendant
        self.assertEqual(self.probe(comm="node", commands=""), "unknown:agent-command")

    def test_unknown_panes_and_bsd_elapsed_time(self):
        self.assertEqual(self.probe(roots=""), "unknown:pane-pids")
        self.assertEqual(self.probe(roots="bad"), "unknown:pane-pids")
        self.assertEqual(self.probe(roots="999"), "unknown:pane-process")
        self.assertEqual(live.live_reason("fleet:3", 1800), "unknown:unstable-target")
        for text, seconds in (("01:23", 83), ("02:03:04", 7384), ("1-02:03:04", 93784), ("?", 0)):
            self.assertEqual(live.age_seconds(text), seconds)

    def test_probe_failure_is_closed(self):
        with patch.object(sys, "argv", ["probe", "@1"]), patch.object(live, "read", side_effect=OSError):
            self.assertEqual(live.main(), 1)
        with patch.object(sys, "argv", ["probe", "@1"]), patch.object(live, "read", side_effect=subprocess.TimeoutExpired("tmux", 5)):
            self.assertEqual(live.main(), 1)

    def test_explicit_socket_applies_to_every_tmux_probe(self):
        replies = iter(["", "\t", "", "done", "100", "100 1 01:00:00 zsh", "100 zsh"])
        with patch.object(live, "read", side_effect=lambda *args: next(replies)) as read:
            self.assertIsNone(live.live_reason("@1", 1800, "other-fleet"))
        calls = [call.args for call in read.call_args_list if call.args[0] == "tmux"]
        self.assertEqual(len(calls), 5)
        self.assertTrue(all(call[:3] == ("tmux", "-L", "other-fleet") for call in calls))

    @unittest.skipUnless(shutil.which("tmux") and shutil.which("perl"), "tmux/perl absent")
    def test_real_pane_descendant_on_isolated_socket(self):
        tmux = shutil.which("tmux")
        label = "reap-live-selftest-"+str(os.getpid())
        def tm(*args):
            return subprocess.check_output([tmux, "-L", label, *args], text=True, stderr=subprocess.DEVNULL).strip()
        with tempfile.TemporaryDirectory(prefix="reap-live-selftest-") as tmp:
            root = Path(tmp)
            (root / "codex").symlink_to(shutil.which("perl"))
            (root / "tmux").write_text(f"#!/bin/sh\nexec {shlex.quote(tmux)} -L {label} \"$@\"\n")
            (root / "tmux").chmod(0o755)
            env = dict(os.environ, PATH=str(root)+":"+os.environ["PATH"])
            try:
                # The child's alarm bounds its lifetime even if the test parent dies.
                cmd = shlex.quote(str(root / "codex"))+" -e 'alarm 45; sleep 60'"
                wid = tm("-f", "/dev/null", "new-session", "-d", "-P", "-F", "#{window_id}", "-s", "probe", cmd)
                tm("set-window-option", "-t", wid, "@claude_state", "done")
                deadline = time.monotonic()+5
                while True:
                    result = subprocess.run([sys.executable, str(BIN / "fleet-reap-live.py"), wid],
                                            env=env, text=True, capture_output=True)
                    if "young-agent:codex" in result.stdout or time.monotonic() >= deadline:
                        break
                    time.sleep(0.05)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("young-agent:codex", result.stdout)
                # The daemon has no TMUX or PATH shim; its explicit socket label
                # must find this same isolated window/process, never default.
                outside = dict(os.environ)
                outside.pop("TMUX", None)
                outside.pop("TMUX_PANE", None)
                result = subprocess.run([sys.executable, str(BIN / "fleet-reap-live.py"),
                                         wid, "--socket-name", label], env=outside,
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("young-agent:codex", result.stdout)
                env["FLEET_REAP_MIN_AGE"] = "0"
                result = subprocess.run([sys.executable, str(BIN / "fleet-reap-live.py"), wid], env=env)
                self.assertEqual(result.returncode, 0)
                tm("set-window-option", "-t", wid, "@claude_state", "working")
                result = subprocess.run([sys.executable, str(BIN / "fleet-reap-live.py"), wid], env=env, capture_output=True)
                self.assertEqual(result.returncode, 1)
                self.assertIn(b"state:working", result.stdout)
            finally:
                subprocess.run([tmux, "-L", label, "kill-server"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    unittest.main(verbosity=2)
