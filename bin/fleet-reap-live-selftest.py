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
              merged_at=None, waived=None, now=None, loop="\t", wait="", status=""):
        outputs = iter([hold, loop, lifecycle, state + ("\t" + status if status else ""), roots, f"100 1 01:00:00 zsh\n101 100 {age} {comm}\n102 1 00:01 codex\n",
                        commands if commands is not None else f"100 zsh\n101 {comm}\n102 codex\n"])
        with patch.object(live, "read", side_effect=lambda *args: next(outputs)), \
             patch.object(live, "waiting", return_value=wait):
            return live.live_reason("@1", minimum, None, merged_at, waived, now)

    def test_waiting_parent_or_bg_job_retains(self):
        # Issue #1370: an unfinished sub-task / a Bash-tool job still running keeps a
        # `done`-stamped window — after a hold and a Loop, ahead of age and state.
        # Issue #1880: so does a fleet tool call still in flight (`tool`).
        for wait in ("children", "bg", "tool"):
            for lifecycle, state in (("", "done"), ("", "looping"), ("sleeping", "done")):
                self.assertEqual(self.probe(minimum=0, lifecycle=lifecycle, state=state, wait=wait), "retained:" + wait)
        self.assertEqual(self.probe(hold="1", wait="children"), "retained:hold")
        now = int(time.time())
        self.assertEqual(self.probe(wait="bg", loop=f"kind=wakeup next={now+600} ttl=600\t"), "retained:loop")
        self.assertIsNone(self.probe(minimum=0, wait=""))

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

    def test_agent_self_report_decides(self):
        # Issue #2540 (EPIC #2535 C5): the agent's own OSC 7501 word first.
        def st(word):
            return '{"state":"%s","kind":"","msg":"","app":"claude","ts":1}' % word
        # done / error / exited: reapable whatever the hook stamped, young or not.
        for word in ("done", "error", "exited"):
            for stamped in ("", "done", "working", "needs", "looping"):
                self.assertIsNone(self.probe(state=stamped, status=st(word)), (word, stamped))
        # idle is done, but it does not waive the young-agent gate (a fresh agent says it).
        self.assertTrue(self.probe(state="working", status=st("idle")).startswith("young-agent:claude:"))
        self.assertIsNone(self.probe(state="working", status=st("idle"), age="2:00:00"))
        # working / blocked: kept while an agent runs — even stamped done, even old.
        for word in ("working", "blocked"):
            self.assertEqual(self.probe(state="done", status=st(word), age="2:00:00"), "agent:" + word)
            # ...and with no agent left under the pane, the relay died with it: exited.
            self.assertIsNone(self.probe(state="working", status=st(word), comm="zsh"))
            self.assertEqual(self.probe(state="done", status=st(word), comm="node", commands=""), "unknown:agent-command")
        # Every gate ahead of the state still applies.
        self.assertEqual(self.probe(hold="1", status=st("done")), "retained:hold")
        self.assertEqual(self.probe(wait="bg", status=st("done")), "retained:bg")
        self.assertEqual(self.probe(lifecycle="waking", status=st("done")), "retained:waking")
        # No word, or one that is no state (clear, garbage): the stamp decides, as before.
        for raw in ("", '{"state":"clear"}', "not json"):
            self.assertEqual(self.probe(state="working", status=raw, age="2:00:00"), "state:working")

    def test_reap_state_cli(self):
        # `--state`: the one answer dash-reap's no-repo branch, fleet-cleanup and
        # the EPIC backstop judge a window by (issue #2540).
        def run(stamped, status, ps="100 1 01:00:00 zsh\n101 100 10:00 claude", cmds="100 zsh\n101 claude"):
            replies = iter([stamped + "\t" + status, "100", ps, cmds])
            out = []
            with patch.object(sys, "argv", ["probe", "@1", "--state"]), \
                 patch.object(live, "read", side_effect=lambda *args: next(replies)), \
                 patch("builtins.print", side_effect=lambda *a, **k: out.append(" ".join(map(str, a)))):
                rc = live.main()
            return rc, out[0] if out else ""
        js = '{"state":"%s"}'
        self.assertEqual(run("working", js % "done"), (0, "done"))
        self.assertEqual(run("", js % "idle"), (0, "done"))
        self.assertEqual(run("done", js % "error"), (0, "exited"))
        self.assertEqual(run("done", js % "blocked"), (0, "blocked"))
        self.assertEqual(run("done", js % "working"), (0, "working"))
        self.assertEqual(run("done", js % "working", ps="100 1 01:00:00 zsh", cmds="100 zsh"), (0, "exited"))
        # No 7501 word: the stamp; none either and no agent process → exited (#2404).
        self.assertEqual(run("needs", ""), (0, "needs"))
        self.assertEqual(run("", ""), (0, ""))
        self.assertEqual(run("", "", ps="100 1 01:00:00 zsh", cmds="100 zsh"), (0, "exited"))
        with patch.object(sys, "argv", ["probe", "pane", "--state"]):
            self.assertEqual(live.main(), 2)

    def test_merged_looping_worker_is_reapable(self):
        # Issue #1356 (R4 of EPIC #1529): a worker whose own PR merged during its
        # life, still stamped `looping` waiting on that merge, is done.
        NOW = 1_000_000
        waived = []
        self.assertIsNone(self.probe(state="looping", age="10:00", merged_at=NOW-300, now=NOW, waived=waived))
        self.assertEqual(waived, ["claude:600s<1800s", "looping"])
        self.assertIsNone(self.probe(state="looping", age="2:00:00", merged_at=NOW-300, now=NOW))
        # No merge time, or a merge before this agent started: still live.
        self.assertEqual(self.probe(state="looping", age="2:00:00"), "state:looping")
        self.assertEqual(self.probe(state="looping", age="10:00", merged_at=NOW-900, now=NOW), "state:looping")
        # No agent under the pane: nothing shipped, the stamp stands.
        self.assertEqual(self.probe(state="looping", comm="zsh", merged_at=NOW-300, now=NOW), "state:looping")
        # An ACTIVE Loop, a running child or bg job still retain it (#1331, #1370).
        wake = f"kind=wakeup next={int(time.time())+1800} ttl=1800\t"
        self.assertEqual(self.probe(state="looping", age="10:00", merged_at=NOW-300, now=NOW, loop=wake), "retained:loop")
        self.assertEqual(self.probe(state="looping", age="10:00", merged_at=NOW-300, now=NOW, wait="children"), "retained:children")
        # Only `looping` is waived — a working agent never is.
        self.assertEqual(self.probe(state="working", age="2:00:00", merged_at=NOW-300, now=NOW), "state:working")

    def test_merged_at_cli_output(self):
        NOW = 1_000_000
        def run(*extra):
            replies = iter(["", "\t", "", "done", "100", "100 1 01:00:00 zsh\n101 100 10:00 claude", "100 zsh\n101 claude"])
            out = []
            with patch.object(sys, "argv", ["probe", "@1", *extra]), \
                 patch.object(live, "read", side_effect=lambda *a: next(replies)), \
                 patch.object(live, "waiting", return_value=""), \
                 patch.object(live.time, "time", return_value=NOW), \
                 patch("builtins.print", side_effect=lambda *a: out.append(" ".join(map(str, a)))):
                return live.main(), out
        with patch.dict(os.environ, {"FLEET_REAP_MIN_AGE": "1800"}):
            self.assertEqual(run(), (1, ["young-agent:claude:600s<1800s"]))
            self.assertEqual(run("--merged-at", str(NOW-300)), (0, ["waived:young-agent:claude:600s<1800s"]))
            self.assertEqual(run("--merged-at", str(NOW-900)), (1, ["young-agent:claude:600s<1800s"]))
            for bad in ("0", "abc", "-5", ""):
                self.assertEqual(run("--merged-at", bad), (1, ["young-agent:claude:600s<1800s"]))

    def test_default_min_age_is_five_minutes(self):
        # Issue #2453: unset FLEET_REAP_MIN_AGE → 300s; 6 minutes passes, 4 refuses.
        def run(age):
            replies = iter(["", "\t", "", "done", "100", f"100 1 01:00:00 zsh\n101 100 {age} claude", "100 zsh\n101 claude"])
            out = []
            env = {k: v for k, v in os.environ.items() if k != "FLEET_REAP_MIN_AGE"}
            with patch.dict(os.environ, env, clear=True), \
                 patch.object(sys, "argv", ["probe", "@1"]), \
                 patch.object(live, "read", side_effect=lambda *a: next(replies)), \
                 patch.object(live, "waiting", return_value=""), \
                 patch("builtins.print", side_effect=lambda *a: out.append(" ".join(map(str, a)))):
                return live.main(), out
        self.assertEqual(live.DEFAULT_MIN_AGE, 300)
        self.assertEqual(run("06:00")[0], 0)
        self.assertEqual(run("04:00"), (1, ["young-agent:claude:240s<300s"]))

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
        with patch.object(live, "read", side_effect=lambda *args: next(replies)) as read, \
             patch.object(live, "waiting", return_value="") as wait:
            self.assertIsNone(live.live_reason("@1", 1800, "other-fleet"))
        wait.assert_called_once_with("@1", "other-fleet")
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
                # Issue #2540: the agent's own word outranks the stamp, both ways.
                tm("set-window-option", "-t", wid, "@agent_status", '{"state":"done"}')
                env.pop("FLEET_REAP_MIN_AGE")
                result = subprocess.run([sys.executable, str(BIN / "fleet-reap-live.py"), wid], env=env, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout)
                tm("set-window-option", "-t", wid, "@agent_status", '{"state":"blocked"}')
                tm("set-window-option", "-t", wid, "@claude_state", "done")
                result = subprocess.run([sys.executable, str(BIN / "fleet-reap-live.py"), wid], env=env, capture_output=True)
                self.assertEqual((result.returncode, result.stdout), (1, b"agent:blocked\n"))
                result = subprocess.run([sys.executable, str(BIN / "fleet-reap-live.py"), wid, "--state"],
                                        env=env, capture_output=True)
                self.assertEqual(result.stdout, b"blocked\n")
            finally:
                subprocess.run([tmux, "-L", label, "kill-server"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    unittest.main(verbosity=2)
