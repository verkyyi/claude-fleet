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
    def probe(self, state="done", comm="claude", age="00:10", commands=None, roots="100\n", minimum=1800, lifecycle=""):
        outputs = iter([lifecycle, state, roots, f"100 1 01:00:00 zsh\n101 100 {age} {comm}\n102 1 00:01 codex\n",
                        commands if commands is not None else f"100 zsh\n101 {comm}\n102 codex\n"])
        with patch.object(live, "read", side_effect=lambda *args: next(outputs)):
            return live.live_reason("@1", minimum)

    def test_retained_workers_are_never_automatically_reaped(self):
        for phase in ('preparing','sleeping','waking','failed'):
            self.assertEqual(self.probe(minimum=0,lifecycle=phase),'retained:'+phase)

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
        replies = iter(["", "done", "100", "100 1 01:00:00 zsh", "100 zsh"])
        with patch.object(live, "read", side_effect=lambda *args: next(replies)) as read:
            self.assertIsNone(live.live_reason("@1", 1800, "other-fleet"))
        calls = [call.args for call in read.call_args_list if call.args[0] == "tmux"]
        self.assertEqual(len(calls), 3)
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
