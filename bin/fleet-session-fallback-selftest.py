#!/usr/bin/env python3
# selftest-entry
"""Hard quota continuation at the unified session boundary; no live services."""
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

BIN = Path(__file__).absolute().parent
sys.path.insert(0, str(BIN))
import fleet_session_fallback as fallback

spec = importlib.util.spec_from_file_location("tested_gate", BIN / "fleet_session_gate.py")
gate = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = gate
spec.loader.exec_module(gate)
FID = "11111111-2222-4333-8444-555555555555"
SID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"


class Continuation(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="quota-gate-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = patch.dict(os.environ, FLEET_GATE_DIR=str(self.root / "gate"), FLEET_GATE_NOW="1000")
        self.env.start()
        self.addCleanup(self.env.stop)
        self.transcript = self.root / "source.jsonl"
        self.w = dict(fid=FID, sid=SID, agent="claude", sock="test-fleet", win="@1", pane="%1",
                      state="done", word="", parked="", needs="")
        self.patch_transcript = patch.object(gate, "claude_transcript", return_value=self.transcript)
        self.patch_transcript.start()
        self.addCleanup(self.patch_transcript.stop)
        self.error()

    def error(self, **kw):
        r = dict(type="assistant", sessionId=SID, uuid="error-1", isApiErrorMessage=True, error="rate_limit",
                 message={"content": [{"type": "text", "text": "You've hit your limit · resets tomorrow"}]})
        r.update(kw)
        self.transcript.write_text(json.dumps(r) + "\n")

    def start(self, rows=None):
        with gate.lock(FID):
            fallback.maybe_start(gate, self.w, rows or [])

    def test_normal_auth_network_cancel_and_other_person_never_switch(self):
        cases = [dict(isApiErrorMessage=False), dict(error="authentication_failed"), dict(error="unknown"),
                 dict(type="user"), dict(sessionId="another-session"), dict(isSidechain=True),
                 dict(message={"content": [{"type": "text", "text": "per-minute rate limit: too many requests"}]}),
                 dict(message={"content": [{"type": "text", "text": "user cancelled"}]}),
                 dict(message={"content": [{"type": "text", "text": "person_budget_exceeded"}]})]
        for kw in cases:
            with self.subTest(kw=kw), patch.object(fallback.subprocess, "Popen") as spawn:
                self.error(**kw)
                self.start()
                spawn.assert_not_called()
                self.assertIsNone(fallback.receipt(gate, FID))

    def test_quota_once_even_when_status_repeats_and_after_crash(self):
        with patch.object(fallback.subprocess, "Popen") as spawn:
            for _ in range(5):
                self.start()
            self.assertEqual(spawn.call_count, 1)
        r = fallback.receipt(gate, FID)
        self.assertEqual(r["transcript"], str(self.transcript))
        self.assertEqual(r["source_session"], SID)
        self.assertFalse(gate.can_talk(self.w)[0])
        with patch.object(gate, "window", return_value=self.w), patch.object(fallback.subprocess, "run", side_effect=OSError):
            fallback.run(gate, FID, SID)
        self.assertEqual(fallback.receipt(gate, FID)["state"], "blocked")
        with patch.object(fallback.subprocess, "Popen") as spawn:
            self.start()
            spawn.assert_not_called()

    def test_wait_for_clean_boundary_bounded_and_permission_never_exited(self):
        self.w["state"] = "working"
        with patch.object(fallback.subprocess, "Popen") as spawn:
            self.start()
            spawn.assert_not_called()
            self.assertEqual(fallback.receipt(gate, FID)["state"], "waiting")
            self.w["state"] = "done"
            self.start()
            self.assertEqual(spawn.call_count, 1)
        for state in ("needs", "looping", "working"):
            (gate.fid_dir(FID) / "quota-continuation.json").unlink()
            self.w["state"] = state
            with patch.object(fallback.subprocess, "Popen") as spawn:
                self.start()
                with patch.dict(os.environ, FLEET_GATE_NOW="1031"):
                    self.start()
                    self.assertEqual(fallback.receipt(gate, FID)["state"], "blocked")
                spawn.assert_not_called()

    def test_unsettled_delivery_blocks_but_sent_tools_and_words_not_replayed(self):
        with patch.object(fallback.subprocess, "Popen") as spawn:
            self.start([dict(state="trying")])
            spawn.assert_not_called()
        self.assertEqual(fallback.receipt(gate, FID)["why"], "delivery_unsettled")
        (gate.fid_dir(FID) / "quota-continuation.json").unlink()
        sent = dict(state="sent", text="already executed a tool", delivery="sent-id")
        queued = dict(state="queued", text="unsent words", fid=FID, at=900, delivery="queue-id")
        with patch.object(fallback.subprocess, "Popen"):
            self.start([sent, queued])
        self.assertEqual(sent["state"], "sent")
        self.assertEqual(queued["state"], "returned")
        calls = []
        def controller(argv, **kw):
            calls.append((argv, kw))
            self.w.update(agent="codex", sid="target-exact")
            return subprocess_result(0)
        with patch.object(gate, "window", side_effect=lambda _: dict(self.w)), patch.object(fallback.subprocess, "run", side_effect=controller):
            fallback.run(gate, FID, SID)
        argv, kw = calls[0]
        self.assertIn("fleet-transfer.sh", " ".join(argv))
        self.assertEqual(argv[-2:], ["--expected-session-id", SID])
        self.assertFalse(any(x in argv for x in ("--force", "--durable-takeover", "--handoff", "--draft-file")))
        self.assertEqual(kw["env"]["FLEET_TRANSFER_RETRYING"], "1")
        self.assertNotIn("input", kw)
        self.assertEqual(fallback.view(gate, self.w)["state"], "continued")
        self.assertEqual(fallback.receipt(gate, FID)["target_session"], "target-exact")
        with patch.object(fallback.subprocess, "Popen") as spawn:
            self.start()
            spawn.assert_not_called()  # Codex cannot fall back to Claude

    def test_controller_refusal_and_duplicate_worker_never_retry(self):
        with patch.object(fallback.subprocess, "Popen"):
            self.start()
        with patch.object(gate, "window", return_value=self.w), patch.object(fallback.subprocess, "run", return_value=subprocess_result(1)) as run:
            fallback.run(gate, FID, SID)
            fallback.run(gate, FID, SID)
            self.assertEqual(run.call_count, 1)
        self.assertEqual(fallback.receipt(gate, FID)["state"], "blocked")
        other = dict(self.w, fid="99999999-2222-4333-8444-555555555555")
        self.assertIsNone(fallback.view(gate, other))
        self.assertIsNone(fallback.view(gate, dict(self.w, sid="replacement")))

    def test_capacity_signal_and_generation_timeout_are_isolated(self):
        self.error(message={"content": [{"type": "text", "text": "Claude subscription pool unavailable (claude_pool_unavailable)"}]})
        self.w["state"] = "working"
        with patch.object(fallback.subprocess, "Popen") as spawn:
            self.start()
            with patch.dict(os.environ, FLEET_GATE_NOW="1031"):
                self.assertEqual(fallback.view(gate, self.w)["state"], "recovery")
                # An unrelated source's old waiting time cannot block this one.
                new_sid = "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee"
                self.w["sid"] = new_sid
                self.error(sessionId=new_sid)
                self.start()
                r = fallback.receipt(gate, FID)
                self.assertEqual(r["state"], "waiting")
                self.assertEqual(r["at"], 1031)
            spawn.assert_not_called()
        r["state"] = "transferring"
        gate.write_json(gate.fid_dir(FID) / "quota-continuation.json", r)
        late = dict(r, request_id="old-request", state="continued")
        fallback.finish(gate, gate.fid_dir(FID) / "quota-continuation.json", late)
        self.assertEqual(fallback.receipt(gate, FID), r)

    def test_clean_native_continuation_clears_blocked_notice(self):
        self.w["parked"] = "1"
        self.start()
        self.assertEqual(fallback.view(gate, self.w)["state"], "blocked")
        self.error(isApiErrorMessage=False)
        self.assertIsNone(fallback.view(gate, self.w))

    def test_source_changed_before_controller_leaves_it_alone(self):
        with patch.object(fallback.subprocess, "Popen"):
            self.start()
        with patch.object(gate, "window", return_value=dict(self.w, sid="replacement")), patch.object(fallback.subprocess, "run") as run:
            fallback.run(gate, FID, SID)
            run.assert_not_called()
        self.assertEqual(fallback.receipt(gate, FID)["why"], "source_changed")


def subprocess_result(rc):
    from types import SimpleNamespace
    return SimpleNamespace(returncode=rc)


if __name__ == "__main__":
    unittest.main()
