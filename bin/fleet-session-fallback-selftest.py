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

    def controller_run(self):
        fallback.run(gate, FID, SID, fallback.receipt(gate, FID)['request_id'])

    def test_preflight_refusal_recovers_once_with_exact_receipt(self):
        with patch.object(fallback.subprocess, 'Popen'):
            self.start()
        with patch.object(gate, 'window', return_value=self.w), patch.object(fallback.subprocess, 'run', return_value=subprocess_result(1)) as controller:
            self.controller_run()
        self.assertEqual(controller.call_count, 1)
        self.assertIn('--dry-run', controller.call_args.args[0])
        old = fallback.receipt(gate, FID)
        self.assertEqual(old['why'], 'preflight_refused')
        self.assertIs(old['controller_attempted'], False)
        with patch.object(gate, 'window', return_value=self.w), patch.object(fallback.subprocess, 'Popen') as spawn:
            got = fallback.recover(gate, FID, SID, old['request_id'])
            self.assertTrue(got['ok'])
            self.assertFalse(fallback.recover(gate, FID, SID, old['request_id'])['ok'])
            self.assertEqual(spawn.call_count, 1)
        new = fallback.receipt(gate, FID)
        self.assertNotEqual(old['request_id'], new['request_id'])
        self.assertEqual(json.loads(Path(new['previous_receipt']).read_text()), old)
        # A delayed old worker must not consume the replacement starting receipt.
        with patch.object(gate, 'window', return_value=self.w), patch.object(fallback.subprocess, 'run') as controller:
            fallback.run(gate, FID, SID, old['request_id'])
            controller.assert_not_called()

    def test_recovery_refuses_unknown_attempts_identity_error_and_delivery_changes(self):
        base = dict(fid=FID, source_session=SID, request_id='exact-request', state='blocked',
                    why='preflight_refused', phase='preflight', controller_attempted=False,
                    error_id='error-1', at=1000)
        path = gate.fid_dir(FID) / 'quota-continuation.json'
        for change in (dict(controller_attempted=True), dict(controller_attempted=None),
                       dict(phase='controller'), dict(state='transferring'), dict(target_session='bound'),
                       dict(error_id='old-error'), dict(source_session='other-source')):
            with self.subTest(change=change):
                gate.write_json(path, dict(base, **change))
                with patch.object(gate, 'window', return_value=self.w), patch.object(fallback.subprocess, 'Popen') as spawn:
                    self.assertFalse(fallback.recover(gate, FID, SID, 'exact-request')['ok'])
                    spawn.assert_not_called()
        gate.write_json(path, base)
        for w, rows in ((dict(self.w, sid='changed'), []), (dict(self.w, agent='codex'), []),
                        (self.w, [dict(state='native')])):
            with patch.object(gate, 'window', return_value=w), patch.object(gate, 'records', return_value=rows):
                self.assertFalse(fallback.recover(gate, FID, SID, 'exact-request')['ok'])

    def test_preflight_cas_fences_late_worker_and_unknown_controller_completion(self):
        with patch.object(fallback.subprocess, 'Popen'):
            self.start()
        def supersede(argv, **kw):
            self.assertIn('--dry-run', argv)
            r = fallback.receipt(gate, FID)
            r.update(request_id='replacement', state='starting')
            gate.write_json(gate.fid_dir(FID) / 'quota-continuation.json', r)
            return subprocess_result(0)
        with patch.object(gate, 'window', return_value=self.w), patch.object(fallback.subprocess, 'run', side_effect=supersede) as controller:
            self.controller_run()
            self.assertEqual(controller.call_count, 1)
        self.assertEqual(fallback.receipt(gate, FID)['request_id'], 'replacement')

    def test_actual_attempt_failure_and_crash_are_never_recoverable(self):
        for crash in (False, True):
            (gate.fid_dir(FID) / 'quota-continuation.json').unlink(missing_ok=True)
            with patch.object(fallback.subprocess, 'Popen'):
                self.start()
            def attempt(argv, **kw):
                r = fallback.receipt(gate, FID)
                if '--dry-run' in argv:
                    self.assertIs(r['controller_attempted'], False)
                    return subprocess_result(0)
                self.assertIs(r['controller_attempted'], True)
                if crash:
                    raise RuntimeError('process died after write-ahead')
                return subprocess_result(1)
            with patch.object(gate, 'window', return_value=self.w), patch.object(fallback.subprocess, 'run', side_effect=attempt) as controller:
                if crash:
                    with self.assertRaises(RuntimeError):
                        self.controller_run()
                else:
                    self.controller_run()
                self.assertEqual(controller.call_count, 2)
                r = fallback.receipt(gate, FID)
                self.assertFalse(fallback.recover(gate, FID, SID, r['request_id'])['ok'])
                self.controller_run()
                self.assertEqual(controller.call_count, 2)

    def test_readonly_preflight_timeout_is_explicitly_recoverable(self):
        with patch.object(fallback.subprocess, 'Popen'):
            self.start()
        with patch.object(gate, 'window', return_value=self.w), patch.object(fallback.subprocess, 'run', side_effect=fallback.subprocess.TimeoutExpired('preview', 90)):
            self.controller_run()
        r = fallback.receipt(gate, FID)
        self.assertEqual(r['why'], 'preflight_timeout')
        with patch.object(gate, 'window', return_value=self.w), patch.object(fallback.subprocess, 'Popen'):
            self.assertTrue(fallback.recover(gate, FID, SID, r['request_id'])['ok'])

    def test_superseded_live_preview_cannot_launch_or_finish_over_recovery(self):
        with patch.object(fallback.subprocess, 'Popen'):
            self.start()
        old = fallback.receipt(gate, FID)
        def recover_during_preview(argv, **kw):
            self.assertIn('--dry-run', argv)
            self.assertEqual(fallback.receipt(gate, FID)['state'], 'checking')
            with patch.object(fallback.subprocess, 'Popen'):
                self.assertTrue(fallback.recover(gate, FID, SID, old['request_id'])['ok'])
            return subprocess_result(0)
        with patch.object(gate, 'window', return_value=self.w), patch.object(fallback.subprocess, 'run', side_effect=recover_during_preview) as controller:
            self.controller_run()
            self.assertEqual(controller.call_count, 1)
        replacement = fallback.receipt(gate, FID)
        self.assertNotEqual(replacement['request_id'], old['request_id'])
        self.assertEqual(replacement['state'], 'starting')
        fallback.finish(gate, gate.fid_dir(FID)/'quota-continuation.json', dict(old, state='blocked'), expected='checking')
        self.assertEqual(fallback.receipt(gate, FID), replacement)

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
            self.controller_run()
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
            if "--dry-run" not in argv:
                self.w.update(agent="codex", sid="target-exact")
            return subprocess_result(0)
        with patch.object(gate, "window", side_effect=lambda _: dict(self.w)), patch.object(fallback.subprocess, "run", side_effect=controller):
            self.controller_run()
        self.assertIn("--dry-run", calls[0][0])
        argv, kw = calls[1]
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
            self.controller_run()
            self.controller_run()
            self.assertEqual(run.call_count, 1)
        self.assertEqual(fallback.receipt(gate, FID)["state"], "blocked")
        other = dict(self.w, fid="99999999-2222-4333-8444-555555555555")
        self.assertIsNone(fallback.view(gate, other))
        self.assertIsNone(fallback.view(gate, dict(self.w, sid="replacement")))

    def test_failed_controller_with_bound_target_keeps_one_writer_in_recovery(self):
        with patch.object(fallback.subprocess, "Popen"):
            self.start()
        def incomplete(argv, **kw):
            if "--dry-run" in argv:
                return subprocess_result(0)
            self.w.update(agent="codex", sid="partially-started-target")
            return subprocess_result(1)
        with patch.object(gate, "window", side_effect=lambda _: dict(self.w)), patch.object(fallback.subprocess, "run", side_effect=incomplete) as controller:
            self.controller_run()
            self.controller_run()
        self.assertEqual(controller.call_count, 2)
        self.assertEqual(fallback.view(gate, self.w)["state"], "recovery")
        self.assertFalse(gate.can_talk(self.w)[0])
        with patch.object(fallback.subprocess, "Popen") as spawn:
            self.start()
            spawn.assert_not_called()

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
            self.controller_run()
            run.assert_not_called()
        self.assertEqual(fallback.receipt(gate, FID)["why"], "source_changed")

    def test_native_quota_error_boundary_delegates_to_controller_without_restamping(self):
        self.w.update(state="exited", word="error")
        with patch.object(fallback.subprocess, "Popen") as spawn:
            self.start()
            self.assertEqual(spawn.call_count, 1)
        self.assertEqual(self.w["state"], "exited")
        self.assertEqual(fallback.receipt(gate, FID)["state"], "starting")


    def test_quota_menu_is_only_a_controller_candidate_and_still_once(self):
        self.w.update(state='needs', word='blocked', agent_status=json.dumps(
            dict(state='blocked', app='claude-code', kind='', msg='dialog open')))
        with patch.object(fallback.subprocess, 'Popen') as spawn:
            self.start(); self.start()
            self.assertEqual(spawn.call_count, 1)
        self.assertEqual(self.w['state'], 'needs')
        for key, value in (('needs','perm'), ('agent_status','{}'), ('parked','1')):
            (gate.fid_dir(FID) / 'quota-continuation.json').unlink()
            old = self.w.get(key); self.w[key] = value
            with patch.object(fallback.subprocess, 'Popen') as spawn:
                self.start(); spawn.assert_not_called()
            self.w[key] = old


    def test_old_boundary_refusal_can_use_new_menu_proof_but_controller_never_retries(self):
        self.w.update(state='needs', word='blocked', agent_status=json.dumps(
            dict(state='blocked', app='claude-code', kind='', msg='dialog open')))
        path = gate.fid_dir(FID) / 'quota-continuation.json'
        old = dict(source_session=SID, state='blocked', why='boundary', at=100, request_id='unattempted')
        gate.write_json(path, old)
        with patch.object(fallback.subprocess, 'Popen') as spawn:
            self.start(); self.start()
            self.assertEqual(spawn.call_count, 1)
        current = fallback.receipt(gate, FID)
        self.assertNotEqual(current['request_id'], old['request_id'])
        self.assertEqual(current['at'], 1000)
        for why in ('transfer_refused', 'controller_unavailable'):
            gate.write_json(path, dict(old, why=why))
            with patch.object(fallback.subprocess, 'Popen') as spawn:
                self.start(); spawn.assert_not_called()

    def test_unattempted_refusal_rechecks_when_native_cancel_or_delivery_settles(self):
        path = gate.fid_dir(FID) / 'quota-continuation.json'
        for why in ('boundary', 'delivery_unsettled'):
            with self.subTest(why=why):
                old = dict(source_session=SID, state='blocked', why=why, at=100, request_id='unattempted')
                gate.write_json(path, old)
                self.w.update(state='working', word='working')
                with patch.object(fallback.subprocess, 'Popen') as spawn:
                    self.start()
                    spawn.assert_not_called()
                    self.w.update(state='exited', word='error')
                    self.start([dict(state='native')])
                    spawn.assert_not_called()
                    self.start()
                    self.start()
                    self.assertEqual(spawn.call_count, 1)
                self.assertEqual(fallback.receipt(gate, FID)['state'], 'starting')
                self.assertEqual(self.w['state'], 'exited')


def subprocess_result(rc):
    from types import SimpleNamespace
    return SimpleNamespace(returncode=rc)


if __name__ == "__main__":
    unittest.main()
