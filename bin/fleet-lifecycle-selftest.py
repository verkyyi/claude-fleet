#!/usr/bin/env python3
# selftest-entry
"""C6: fleet-cleanup-idle.py / fleet_session_gate.py completion and admission.

The real identity ledger, gate receipts and policy, with controlled native
admission and close boundaries. No production socket or sleep-based races.
"""
import argparse
from contextlib import contextmanager, redirect_stdout
import importlib.util
import io
import json
import os
import subprocess
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import uuid

BIN = Path(__file__).absolute().parent
sys.path.insert(0, str(BIN))
import fleet_id
import fleet_reap_policy as policy
import fleet_session_gate as gate
spec = importlib.util.spec_from_file_location("idle", BIN / "fleet-cleanup-idle.py")
idle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(idle)
spec = importlib.util.spec_from_file_location("reap_live", BIN / "fleet-reap-live.py")
reap_live = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reap_live)
FID = "44444444-4444-4444-8444-444444444444"


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="c6-life-")
        self.addCleanup(self.tmp.cleanup)
        env = {k: v for k, v in os.environ.items() if not k.startswith(("FLEET_", "CCQUOTA_")) and k not in ("TMUX", "TMUX_PANE")}
        env.update(FLEET_CONF_DIR=self.tmp.name, FLEET_ID_LIVE="[]")
        p = patch.dict(os.environ, env, clear=True)
        p.start()
        self.addCleanup(p.stop)
        fleet_id.append(FID, dict(ev="opened", task="T42"))
        fleet_id.append(FID, dict(ev="result", state="merged", task="T42"))
        self.cleaner = idle.Cleaner.__new__(idle.Cleaner)
        self.cleaner.task_closed = lambda task: 0
        self.snap = {"@fleet_id": FID, "@task": "T42", "@migrating": "", "@worktree": "",
                     "@parked": "", "@park_held": "", "pane_pid": "1"}
        self.window = dict(fid=FID, sid="same-native-session", agent="claude", win="@1", pane="%1",
                           sock="isolated-fixture", task="T42")
        p = patch.object(gate, "window", return_value=self.window)
        p.start()
        self.addCleanup(p.stop)
        p = patch.object(fleet_id, "push_later")
        p.start()
        self.addCleanup(p.stop)

    def say(self):
        args = argparse.Namespace(fid=FID, text="new work", image=[], delivery=str(uuid.uuid4()))
        stream = io.StringIO()
        with patch.object(gate, "window", return_value=self.window), \
             patch.object(gate, "can_talk", return_value=(True, "")), \
             patch.object(gate, "settle", return_value=None), \
             patch.object(gate, "tmux"), redirect_stdout(stream):
            gate.say(args)
        return json.loads(stream.getvalue())

    def test_new_message_invalidates_old_terminal_and_closed_task(self):
        self.assertEqual(self.say()["state"], "queued")
        self.assertFalse(self.cleaner.work_over(self.snap))
        self.assertEqual(len(gate.records(FID)), 1)

    def test_new_task_does_not_inherit_previous_report(self):
        token = policy.report_begin(FID, "T42")
        self.assertTrue(policy.report_finish(FID, token, "merged", "old task", "claude", "123"))
        self.snap["@task"] = "T43"
        self.assertFalse(self.cleaner.work_over(self.snap))

    def test_message_during_report_prevents_stale_terminal_commit(self):
        token = policy.report_begin(FID, "T42")
        self.say()
        self.assertFalse(policy.report_finish(FID, token, "merged", "old task", "claude", "123"))
        self.assertFalse(self.cleaner.work_over(self.snap))

    def test_new_task_or_attempt_during_report_refuses_commit(self):
        token = policy.report_begin(FID, "T42")
        self.window["task"] = "T43"
        self.assertFalse(policy.report_finish(FID, token, "merged", "old", "claude", "123"))
        token = policy.report_begin(FID, "T43")
        fleet_id.append(FID, dict(ev="reopened", attempt=2))
        self.assertFalse(policy.report_finish(FID, token, "merged", "old", "claude", "123"))

    def test_fresh_report_restores_completion_for_current_work(self):
        self.say()
        self.assertFalse(self.cleaner.work_over(self.snap))
        token = policy.report_begin(FID, "T42")
        self.assertTrue(policy.report_finish(FID, token, "merged", "new result", "claude", "124"))
        self.assertTrue(self.cleaner.work_over(self.snap))
        self.assertEqual(fleet_id.status(FID, [FID])["result"]["summary"], "new result")

    def test_delivered_message_restarts_idle_clock_before_native_hook(self):
        self.say()
        work = policy.current_work(FID)
        snap = dict(self.snap, work_at=str(work["at"]), **{"@claude_state_ts": "1"})
        self.assertEqual(self.cleaner.deadline(snap, ("idle", 60)), work["at"] + 60)

    def test_wake_seed_invalidates_old_completion_under_same_gate(self):
        seed = gate.fid_dir(FID) / "next-seed"
        seed.write_text("new work while parked")
        with gate.lock(FID), patch.object(gate, "tmux"):
            self.assertTrue(gate.wake_request(self.window, seed, "消息")["ok"])
        self.assertFalse(self.cleaner.work_over(self.snap))

    def test_prompt_invalidates_but_tool_and_lifecycle_exit_do_not(self):
        with patch.dict(os.environ, TMUX="fixture", TMUX_PANE="%1"), \
             patch.object(gate, "tmux", return_value=FID):
            gate.prompt_input(dict(hook_event_name="PostToolUse", prompt="UserPromptSubmit"))
            gate.prompt_input(dict(hook_event_name="UserPromptSubmit", prompt="/exit"))
            self.assertEqual(policy.current_work(FID), {})
            gate.prompt_input(dict(hook_event_name="UserPromptSubmit", prompt="another task"))
        self.assertFalse(self.cleaner.work_over(self.snap))
        self.assertIsNone(fleet_id.status(FID, [FID])["result"])

    def test_legacy_admission_invalidates_and_rechecks_closed_window(self):
        args = argparse.Namespace(fid=FID, delivery=str(uuid.uuid4()), sender="fleet")
        with patch.object(sys, "stdin", io.StringIO("new words")), redirect_stdout(io.StringIO()), \
             patch.object(gate.subprocess, "run", return_value=argparse.Namespace(returncode=0, stdout="sent")) as send:
            self.assertEqual(gate.legacy_deliver(args), 0)
        send.assert_called_once()
        self.assertFalse(self.cleaner.work_over(self.snap))
        with patch.object(gate, "window", return_value=None), patch.object(sys, "stdin", io.StringIO("late")), \
             redirect_stdout(io.StringIO()), patch.object(gate.subprocess, "run") as send:
            self.assertEqual(gate.legacy_deliver(args), 3)
            send.assert_not_called()

    def test_live_legacy_report_directory_does_not_require_wake_api(self):
        policy.report_begin(FID, "T42")  # even an old native adapter can report
        script = '''. "$1/fleet-lib.sh"
_fad_tm() { case "${!#}" in '#{@fleet_id}') printf '%s' "$TEST_FID";; esac; }
fleet_park_wake() { printf 'unexpected wake API' >&2; return 3; }
python3() { if [ "${2:-}" = legacy-deliver ]; then echo legacy-admitted; else command python3 "$@"; fi; }
fleet_agent_deliver @1 fixture 'next work' fleet
'''
        p = subprocess.run(["bash", "-c", script, "legacy-test", str(BIN)],
                           env=dict(os.environ, TEST_FID=FID), capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def test_shell_descriptor_holds_the_same_identity_lock(self):
        path = gate.fid_dir(FID) / ".lock"
        # The child which acquired flock has exited; the shell still holds it.
        # A second open description must fail immediately, without sleep races.
        contender = "import fcntl,sys; f=open(sys.argv[1], 'a'); fcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB)"
        script = 'exec 9>>"$1"; "$2" "$3" lock-fd --fid "$4" --fd 9 || exit; "$2" -c "$5" "$1" 2>/dev/null; test "$?" != 0'
        p = subprocess.run(["bash", "-c", script, "lock-test", str(path), sys.executable,
                            str(BIN / "fleet_session_gate.py"), FID, contender], capture_output=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        with gate.lock(FID):
            pass  # the closing shell released it on exit

    def test_final_native_guard_preserves_question_draft_and_unknown(self):
        self.window.update(state="done", word="done", needs="", wrap_ver="3")
        def read(*args):
            fmt = args[-1]
            if fmt == "#{@reap_hold}\t#{@reap_report_pending}\t#{@fleet_id}":
                return "\t\t" + FID
            if fmt == reap_live.STATE_FMT:
                return "done\t\t"
            if fmt == "#{pane_pid}":
                return "4242"
            if fmt == "#{client_control_mode}\t#{window_id}":
                return ""
            return ""
        with patch.object(reap_live, "read", side_effect=read), patch.object(reap_live, "waiting", return_value=""), \
             patch.object(reap_live, "process_table", return_value=({"4242": (600, "claude")}, {}, {"4242": "claude"})), \
             patch.object(reap_live, "agent_under", return_value=True), patch.object(gate, "park_dialog", return_value=False), \
             patch.object(gate, "park_proof", return_value={"ok": True}) as proof:
            self.assertIsNone(reap_live.live_reason("@1", 0, "fixture", automatic=True))
            for why in ("draft", "unknown_input", "not_idle"):
                proof.return_value = dict(ok=False, why=why)
                self.assertEqual(reap_live.live_reason("@1", 0, "fixture", automatic=True), "retained:native-input")
            with patch.object(gate, "park_dialog", return_value=True):
                self.assertEqual(reap_live.live_reason("@1", 0, "fixture", automatic=True), "retained:asking")

    def test_close_rechecks_admitted_message_under_identity_lock(self):
        gate.save(dict(fid=FID, delivery=str(uuid.uuid4()), at=1, state="queued", text="next task"))
        c = self.cleaner
        c.snapshot = lambda window: dict(self.snap)
        c.moved = lambda *args: False
        c.transition = lambda wt: ""
        c.untransition = lambda lock: None
        c.shared = lambda *args: ""
        c.retire = Mock()
        c.end_id = Mock()
        c.tm = Mock()
        for parked in (False, True):
            with self.subTest(parked=parked):
                self.snap.update({"@parked": "1" if parked else "", "@park_held": "1" if parked else ""})
                with patch.object(gate, "lock", wraps=gate.lock) as taken:
                    self.assertFalse(c.close("@1", self.snap, lambda: True))
                    taken.assert_called_with(FID)
                c.retire.assert_not_called()
                c.tm.assert_not_called()

    def test_norepo_close_roads_recheck_the_same_pending_message(self):
        args = argparse.Namespace(socket_name="fixture", session="fixture", dry_run=False)
        c = idle.Cleaner(args)
        c.tm = Mock(return_value="")
        snap = c.snapshot("@1")
        snap.update(self.snap)
        snap.update({"@norepo": "1", "@reap_policy": "done:1m", "@claude_state": "done",
                     "@claude_state_ts": "1", "@born": "1", "@origin_fid": FID,
                     "@fleet_role": "worker", "@wrap_gone": "1"})
        c.moved = lambda *args: False
        c.busy = lambda *args: False
        c.retire = Mock()
        gate.save(dict(fid=FID, delivery=str(uuid.uuid4()), at=1, state="queued", text="next task"))
        for road in ("test_session", "norepo", "empty"):
            with self.subTest(road=road), patch.object(idle, "notice", return_value=0), \
                 patch.object(idle.subprocess, "run", return_value=argparse.Namespace(stdout="stopped: fixture")) as stop:
                self.assertFalse(getattr(c, road)("@1", snap))
                stop.assert_not_called()
                c.retire.assert_not_called()

    def test_explicit_probe_needs_a_completed_result_not_only_native_idle(self):
        c = idle.Cleaner(argparse.Namespace(socket_name="fixture", session="fixture", dry_run=False))
        c.tm = Mock(return_value="")
        snap = c.snapshot("@1")
        snap.update({"@fleet_id": FID, "@task": "T42", "@norepo": "1", "@reap_origin": "probe",
                     "@reap_policy": "done:1m", "@claude_state": "done", "@claude_state_ts": "1",
                     "@fleet_role": "worker", "@wrap_gone": "1"})
        c.id_over = lambda fid: False
        c.task_closed = lambda task: 1
        c.moved = lambda *args: False
        c.busy = lambda *args: False
        c.retire = Mock()
        with patch.object(idle, "notice", return_value=0), \
             patch.object(idle.subprocess, "run", return_value=argparse.Namespace(stdout="stopped: fixture")) as stop:
            self.assertFalse(c.norepo("@1", snap))
            stop.assert_not_called()
            c.retire.assert_not_called()

    def test_retired_window_is_rechecked_at_message_admission(self):
        alive = [self.window]
        n = [0]
        original = gate.lock
        @contextmanager
        def boundary(fid):
            with original(fid) as held:
                n[0] += 1
                if n[0] == 2:
                    alive[0] = None  # close won the lock after the preliminary read
                yield held
        args = argparse.Namespace(fid=FID, text="new work", image=[], delivery=str(uuid.uuid4()))
        stream = io.StringIO()
        with patch.object(gate, "window", side_effect=lambda fid: alive[0]), \
             patch.object(gate, "can_talk", side_effect=lambda w: (bool(w), "" if w else "no_session")), \
             patch.object(gate, "lock", boundary), patch.object(gate, "settle", return_value=None), \
             patch.object(gate, "tmux"), redirect_stdout(stream):
            gate.say(args)
        self.assertEqual(json.loads(stream.getvalue())["state"], "refused")
        self.assertEqual(gate.records(FID), [])


if __name__ == "__main__":
    unittest.main()
