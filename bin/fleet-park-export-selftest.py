#!/usr/bin/env python3
# selftest-entry
"""Refuse a park after real timer export; keep the original dispatcher live.

Only native I/O is faked. Export, abort, ownership, gate, spinner/tick, and loop
dispatch/acknowledgement run their real implementations on isolated sockets.
"""
from contextlib import ExitStack
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from importlib.util import spec_from_file_location, module_from_spec
BIN = Path(__file__).resolve().parent
spec = spec_from_file_location('export_timer_fixture', BIN / 'fleet-park-wake-selftest.py')
timers = module_from_spec(spec)
spec.loader.exec_module(timers)
gate = timers.fixture.gate
import fleet_park_wake as wake


class ExportRefusal(timers.Timers):
    def ledger_fixture(self, agent):
        self.setup_timer(agent=agent)
        self.wait(lambda: self.opt('@claude_state_src') == '7501')
        self.tm('rename-session', '-t', 'test', self.label)
        self.set('@loop', '')
        self.set('@worktree', str(self.root))
        manifest = self.root / 'transfer/manifest.json'
        path = manifest.parent / 'loop/state.json'
        path.parent.mkdir(parents=True)
        manifest.write_text('{}')
        self.set('@handoff_manifest', str(manifest))
        self.set('@codex_identity', json.dumps(dict(session_id=self.sid)))
        self.due = time.time() + 6
        source = dict(id='original-loop', status='active', agent=agent,
                      manifest=str(manifest), worktree=str(self.root),
                      thread_id=self.sid, socket='/fake-native.sock',
                      fleet=dict(session=self.label, window_id=self.win, pane_id=self.opt('pane_id')),
                      pane_pid=int(self.opt('pane_pid')), deliveries=0,
                      schedule=dict(prompt=self.prompt, interval_seconds=60, next_run_at=self.due))
        self.loop = wake.loop_module()
        self.loop.claim_owner(path, source, {})
        self.loop.save(path, source)
        return path, source

    def spinner_pass(self):
        spinner_module = timers.fixture.module('export_refusal_spinner', 'tmux-spinner.py')
        with patch.dict(os.environ, self.env):
            spinner = spinner_module.Spinner()
            try:
                spinner.park_timers()
                child = spinner.timer_child
                if child is not None:
                    child.wait(timeout=15)
                    self.assertEqual(child.returncode, 0)
                return child is not None
            finally:
                spinner.close()

    def dispatch_original_once(self, ledger, source):
        """Real dispatcher/current/hold/ack; replace only fake engine transport."""
        received = []
        outer = self

        class Native:
            def __init__(self, sock):
                outer.assertEqual(sock, source['socket'])

            def __enter__(self):
                return self

            def __exit__(self, *_):
                pass

            def call(self, method, params):
                if method == 'thread/read':
                    return dict(thread=dict(id=outer.sid, cwd=str(outer.root), status=dict(type='idle')))
                outer.assertEqual(method, 'turn/start')
                outer.assertEqual(params['threadId'], outer.sid)
                received.append(params['input'][0]['text'])
                return dict(turn=dict(id='original-native-turn'))

        real_run = subprocess.run

        def native_inbox(argv, *args, **kwargs):
            if len(argv) > 1 and Path(argv[1]).name == 'fleet-peer-send.sh':
                received.append(kwargs['input'])
                with self.transcript.open('a') as stream:
                    stream.write(json.dumps(dict(type='user', uuid='original-native-turn',
                                                 message=dict(content=kwargs['input']))) + '\n')
                return subprocess.CompletedProcess(argv, 0)
            return real_run(argv, *args, **kwargs)

        with patch.dict(os.environ, self.env), \
                patch.object(self.loop, 'Rpc', Native), \
                patch.object(self.loop, 'claude_identity', return_value=dict(session_id=self.sid)), \
                patch.object(self.loop, 'wait_reasons', return_value=[]), \
                patch.object(subprocess, 'run', side_effect=native_inbox):
            self.loop.dispatch(ledger, now=self.due - 1)
            self.assertEqual(received, [])
            time.sleep(max(0, self.due - time.time()))
            self.loop.dispatch(ledger)
            self.loop.dispatch(ledger)  # Claude's real transcript acknowledgement.
            self.loop.dispatch(ledger)
        self.assertEqual(len(received), 1, received)
        self.assertEqual(received[0].count(self.prompt), 1)
        final = json.loads(ledger.read_text())
        self.assertEqual(final['deliveries'], 1)
        self.assertEqual(final['status'], 'active')
        for key in ('thread_id', 'owner_record', 'record_path', 'generation',
                    'active_record', 'active_generation'):
            self.assertEqual(final[key], source[key])
        self.assertEqual(final['schedule']['next_run_at'], final['last_delivered_at'] + 60)
        self.assertFalse((self.root / 'launch-args').exists(), 'refused park relaunched the engine')

    def check_refusal(self, agent, reason):
        ledger, source = self.ledger_fixture(agent)
        path = self.root / 'conf/wake' / (self.fid + '.json')
        original_export = wake.export
        relay = gate.relay_request
        exports, exits, questions = [], [], []

        def export_then_change(fid):
            answer = original_export(fid)
            prepared = json.loads(path.read_text())
            self.assertEqual(prepared['phase'], 'prepared')
            self.assertEqual(json.loads(ledger.read_text())['park_fid'], fid)
            exports.append(prepared)
            if reason == 'question':
                question = self.dialog_transcript()
                questions.append(question.read_bytes())
                if agent == 'claude':
                    self.transcript.write_bytes(questions[0])
                else:
                    self.set('@claude_needs', 'ask')
            elif reason == 'changed':
                self.set('@claude_state', 'working')
            return answer

        def record_relay(w, request):
            if request['op'] in ('exit', 'confirm-exit'):
                exits.append(request)
            return relay(w, request)

        with patch.dict(os.environ, self.env), \
                patch.object(wake, 'export', side_effect=export_then_change), \
                patch.object(gate, 'relay_request', side_effect=record_relay), ExitStack() as stack:
            if reason == 'watched':
                stack.enter_context(patch.object(gate, 'watched', side_effect=lambda w: bool(exports)))
            result = gate.park(self.fid)
        self.assertFalse(result['ok'], result)
        self.assertEqual(result['why'], 'asking' if reason == 'question' else 'changed')
        self.assertEqual(len(exports), 1)
        self.assertEqual(exits, [], 'refusal sent /exit into the question or active pane')
        self.assertFalse(self.opt('@parked'))
        self.assertTrue(self.opt('@park_relay'))
        if questions:
            self.assertEqual((self.root / 'question.jsonl').read_bytes(), questions[0])
            if agent == 'claude':
                self.assertEqual(self.transcript.read_bytes(), questions[0])
        # A real pre-deadline spinner pass cannot compensate: it only visits due
        # contracts. The gate must already have returned ownership on refusal.
        self.assertFalse(self.spinner_pass())
        self.assertFalse(path.exists(), 'refused park left a prepared timer contract until its deadline')
        self.assertEqual(json.loads(ledger.read_text()), source,
                         'refused park kept park_fid instead of returning the original dispatcher')
        self.set('@claude_state', 'done')
        self.set('@claude_needs', '')
        # The person resolves the injected question; never submit /exit to it.
        if questions and agent == 'claude':
            self.transcript.write_text('')
        self.dispatch_original_once(ledger, source)
        self.assertFalse(self.spinner_pass(), 'a second timer survived the abort')
        self.tick()
        self.assertEqual(json.loads(ledger.read_text())['deliveries'], 1)

    def test_codex_export_question_refusal_returns_owner(self):
        self.check_refusal('codex', 'question')

    def test_codex_export_watched_refusal_returns_owner(self):
        self.check_refusal('codex', 'watched')

    def test_codex_export_changed_refusal_returns_owner(self):
        self.check_refusal('codex', 'changed')

    def test_claude_export_question_refusal_returns_owner(self):
        self.check_refusal('claude', 'question')

    def test_claude_export_watched_refusal_returns_owner(self):
        self.check_refusal('claude', 'watched')

    def test_claude_export_changed_refusal_returns_owner(self):
        self.check_refusal('claude', 'changed')

    def test_prepared_crash_compensation_waits_until_deadline(self):
        ledger, source = self.ledger_fixture('codex')
        path = self.root / 'conf/wake' / (self.fid + '.json')
        with patch.dict(os.environ, self.env), gate.lock(self.fid):
            wake.export(self.fid)  # Simulate a parker dying after export.
        self.assertFalse(self.spinner_pass())
        self.assertEqual(json.loads(path.read_text())['phase'], 'prepared')
        time.sleep(max(0, self.due - time.time()))
        self.assertTrue(self.spinner_pass())  # Real subprocess tick calls abort.
        self.assertFalse(path.exists())
        self.assertEqual(json.loads(ledger.read_text()), source)
        self.dispatch_original_once(ledger, source)

    def test_claude_question_refusal_restores_previous_contract(self):
        self.setup_timer()
        original_export = wake.export
        with patch.dict(os.environ, self.env):
            jobs, _ = wake.native_jobs(gate.window(self.fid), time.time())
            path = wake.path_for(self.fid)
            previous = dict(v=1, fid=self.fid, sid=self.sid, agent='claude', jobs=jobs,
                            phase='active', parked=False, next=jobs[0]['next'])
            wake.save(path, previous)  # Existing contract from an earlier resume.
            def export_then_question(fid):
                result = original_export(fid)
                self.assertEqual(json.loads(path.read_text())['previous'], previous)
                self.transcript.write_bytes(self.dialog_transcript().read_bytes())
                return result
            with patch.object(wake, 'export', side_effect=export_then_question):
                result = gate.park(self.fid)
        self.assertEqual(result.get('why'), 'asking', result)
        self.assertFalse(result['ok'])
        self.assertEqual(json.loads(path.read_text()), previous,
                         'refused park did not restore the previous active contract')
        self.assertFalse(self.opt('@parked'))
        self.assertTrue(self.opt('@park_relay'))
        self.assertEqual(self.transcript.read_bytes(), (self.root / 'question.jsonl').read_bytes())


if __name__ == '__main__':
    names = sys.argv[1:] or [n for n in ExportRefusal.__dict__ if n.startswith('test_')]
    result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(ExportRefusal(n) for n in names))
    sys.exit(not result.wasSuccessful())
