#!/usr/bin/env python3
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
"""fleet_transfer_source.py — the source checks a manual move keeps (T546).

Moved unchanged from the retired quota failover planner: `settled` (a looping
Codex between rounds, #786), the background inventory (#873) and
`terminate-background` (#871). Isolated: no live tmux or provider calls.
"""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m


src = module('transfer_source', 'fleet_transfer_source.py')


class QuotaSettled(unittest.TestCase):
    def test_native_failed_turn_requires_all_controller_proofs(self):
        with tempfile.TemporaryDirectory() as tmp:
            transcript = Path(tmp) / 'native.jsonl'
            record = dict(type='assistant', sessionId='exact', uuid='error-id', error='rate_limit',
                          isApiErrorMessage=True, apiErrorStatus=429, apiErrorIsTransient=False,
                          message={'content': [{'type': 'text', 'text': "API Error: Request rejected (429) · You've hit your weekly limit"}]})
            transcript.write_text(json.dumps(record) + '\n')
            source = dict(session='test', pane='%2', pid=42, session_id='exact', agent='claude',
                          state='exited', transcript=str(transcript))
            marks = ['exited', '7501', '{"state":"error"}', '', '', '', '']
            snapshot = unittest.mock.Mock(return_value=dict(state='empty', text=''))
            with patch.object(src, 'inspect', return_value=source) as inspect, \
                 patch.object(src, 'quota_marks', return_value=marks) as meta, \
                 patch.object(src, 'quota_schedules'), \
                 patch.object(src.runpy, 'run_path', return_value={'snapshot': snapshot}), \
                 patch.object(src, 'quiet_processes') as quiet:
                src.quota_settled('test', '%2', 'exact')
                quiet.assert_called_once_with(source)
                with self.assertRaisesRegex(ValueError, 'conversation changed'):
                    src.quota_settled('test', '%2', 'other')
                for state in ('unknown', 'draft'):
                    snapshot.return_value = dict(state=state)
                    with self.assertRaisesRegex(ValueError, 'prompt'):
                        src.quota_settled('test', '%2', 'exact')
                snapshot.return_value = dict(state='empty', text='')
                quiet.side_effect = ValueError('live tool')
                with self.assertRaisesRegex(ValueError, 'live tool'):
                    src.quota_settled('test', '%2', 'exact')
                quiet.side_effect = None
                meta.side_effect = [marks, marks + ['changed']]
                with self.assertRaisesRegex(ValueError, 'changed during'):
                    src.quota_settled('test', '%2', 'exact')
                meta.side_effect = None
                transcript.write_text(json.dumps(dict(record, error='authentication_failed')) + '\n')
                with self.assertRaisesRegex(ValueError, 'no exact native'):
                    src.quota_settled('test', '%2', 'exact')

    def test_metadata_holds_approvals_loops_and_native_work(self):
        fields = ['exited', '7501', '{"state":"error"}', '', '', '', '']
        for key, bad in ((0, 'working'), (1, 'classifier'), (2, '{"state":"working"}'),
                         (3, 'perm'), (4, 'tool'), (5, 'loop'), (6, '1')):
            value = list(fields); value[key] = bad
            with patch.object(src, 'run', return_value='\t'.join(value + ['END'])):
                with self.assertRaises(ValueError): src.quota_marks('test', '%2')
        with patch.object(src, 'run', return_value='\t'.join(fields + ['END'])):
            self.assertEqual(src.quota_marks('test', '%2'), fields)
        # A missing delimiter / truncated read cannot admit a quota boundary.
        for raw in ('exited7501END', '\t'.join(fields), '\t'.join(fields + ['extra', 'END'])):
            with patch.object(src, 'run', return_value=raw):
                with self.assertRaisesRegex(ValueError, 'metadata is incomplete'):
                    src.quota_marks('test', '%2')


class QuotaDialog(unittest.TestCase):
    SCREEN = """You've hit your weekly limit · resets tomorrow
▔▔▔▔▔▔▔▔▔▔
   What do you want to do?

   ❯ 1. Stop and wait for limit to reset
     2. Wait here, then continue automatically at Oct 23 at 5pm
     3. Upgrade your plan

   Enter to confirm · Esc to cancel
"""

    def test_exact_native_quota_dialog_and_fingerprint(self):
        fp = src.quota_dialog(self.SCREEN)
        self.assertTrue(fp)
        for bad in (self.SCREEN.replace('Stop and wait for limit to reset', 'Allow Bash'),
                    self.SCREEN.replace('What do you want to do?', 'Approve tool?'),
                    self.SCREEN + '❯ unsent draft', self.SCREEN.replace('Esc to cancel', 'Enter to continue'),
                    self.SCREEN.replace('3. Upgrade your plan', '3. Other / Type something')):
            with self.subTest(screen=bad), self.assertRaises(ValueError):
                src.quota_dialog(bad)
        self.assertNotEqual(fp, src.quota_dialog(self.SCREEN.replace('Oct 23', 'Oct 24')))


    def test_native_menu_requires_exact_state_source_tools_and_scheduler(self):
        source = dict(agent='claude', state='needs', session_id='exact', transcript='/native',
                      pid=42, window='@2', pane='%2', session='test')
        marks = ['needs', '7501', '{"state":"blocked","app":"claude-code","msg":"dialog open"}', '', '', '', '']
        signal = dict(source_session='exact', error_id='error-id', transcript='/native')
        def run(argv, **kw):
            return '' if 'list-clients' in argv else self.SCREEN
        with patch.object(src, 'inspect', return_value=source) as inspect, \
             patch.object(src, 'source_marks', return_value=marks) as metadata, \
             patch.object(src.fallback, 'quota_error', return_value=signal) as quota, \
             patch.object(src, 'run', side_effect=run) as tm, \
             patch.object(src, 'quiet_processes') as tools, \
             patch.object(src.runpy, 'run_path', return_value={'schedule_readiness': unittest.mock.Mock()}) as modules:
            evidence = src.quota_dialog_check('test', '%2', 'exact')
            self.assertEqual(evidence['fingerprint'], src.quota_dialog(self.SCREEN))
            schedule = modules.return_value['schedule_readiness']
            schedule.assert_called_with('test', '%2', '/native', 42, 'exact', '', 'claude')
            for key, bad in ((0, 'working'), (1, 'classifier'), (2, '{"state":"blocked","kind":"permission"}'),
                             (3, 'ask'), (4, 'tool'), (5, 'loop'), (6, '1')):
                altered = list(marks); altered[key] = bad; metadata.return_value = altered
                with self.assertRaises(ValueError): src.quota_dialog_check('test', '%2', 'exact')
            metadata.return_value = marks
            for key in ('agent', 'state', 'session_id'):
                inspect.return_value = dict(source, **{key:'changed'})
                with self.assertRaises(ValueError): src.quota_dialog_check('test', '%2', 'exact')
            inspect.return_value = source
            quota.return_value = None
            with self.assertRaisesRegex(ValueError, 'hard-quota'): src.quota_dialog_check('test', '%2', 'exact')
            quota.return_value = signal
            tools.side_effect = ValueError('live tool')
            with self.assertRaisesRegex(ValueError, 'live tool'): src.quota_dialog_check('test', '%2', 'exact')
            tools.side_effect = None
            schedule.side_effect = ValueError('native scheduling unknown')
            with self.assertRaisesRegex(ValueError, 'scheduling'): src.quota_dialog_check('test', '%2', 'exact')
            schedule.side_effect = None
            tm.side_effect = lambda argv, **kw: str(int(src.time.time())) + ' @2' if 'list-clients' in argv else self.SCREEN
            with self.assertRaisesRegex(ValueError, 'person'): src.quota_dialog_check('test', '%2', 'exact')

    def test_cancellation_is_write_ahead_once_and_never_restamps_or_replays(self):
        source = dict(agent='claude', state='needs', session_id='exact', pid=42)
        evidence = dict(source=source, fingerprint='fp', screen=self.SCREEN)
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, FLEET_CONF_DIR=tmp), \
             patch.object(src, 'quota_dialog_check', side_effect=lambda *a: dict(evidence)) as check, \
             patch.object(src, 'inspect', return_value=dict(source, state='exited')), \
             patch.object(src, 'quota_settled') as settled, patch.object(src, 'run', return_value='screen') as tm:
            src.quota_dialog_stop('test', '%2', 'exact')
            sends = [c.args[0] for c in tm.call_args_list if 'send-keys' in c.args[0]]
            self.assertEqual(sends, [['tmux', '-L', 'test', 'send-keys', '-t', '%2', 'Escape']])
            settled.assert_called_once_with('test', '%2', 'exact')
            record = json.loads(next(Path(tmp).glob('quota-dialog-stop/*.json')).read_text())
            self.assertEqual(record['state'], 'settled')
            self.assertEqual(record['source']['state'], 'needs')
            with self.assertRaisesRegex(ValueError, 'already attempted'):
                src.quota_dialog_stop('test', '%2', 'exact')
            self.assertEqual(len([c for c in tm.call_args_list if 'send-keys' in c.args[0]]), 1)

    def test_uncertain_stop_changed_identity_draft_or_tool_remains_recoverable(self):
        source = dict(agent='claude', state='needs', session_id='exact', pid=42)
        evidence = dict(source=source, fingerprint='fp', screen=self.SCREEN)
        for failure in ('draft', 'live tool', 'identity', 'timeout', 'dialog changed', 'send failed'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp, \
                 patch.dict(os.environ, FLEET_CONF_DIR=tmp), \
                 patch.object(src, 'quota_dialog_check', side_effect=[dict(evidence), dict(evidence, fingerprint='new') if failure == 'dialog changed' else dict(evidence)]), \
                 patch.object(src, 'inspect', return_value=dict(source, state='needs' if failure == 'timeout' else 'exited', pid=43 if failure == 'identity' else 42)), \
                 patch.object(src.time, 'monotonic', side_effect=[0, 6]), \
                 patch.object(src, 'quota_settled', side_effect=ValueError(failure) if failure in ('draft', 'live tool') else None), \
                 patch.object(src, 'run', side_effect=OSError('send failed') if failure == 'send failed' else None) as tm:
                with self.assertRaises((ValueError, OSError)):
                    src.quota_dialog_stop('test', '%2', 'exact')
                record = json.loads(next(Path(tmp).glob('quota-dialog-stop/*.json')).read_text())
                self.assertEqual(record['state'], 'recovery')
                self.assertLessEqual(tm.call_count, 1)
                self.assertFalse(any('set-option' in str(c) or '/exit' in str(c) for c in tm.call_args_list))


class Settled(unittest.TestCase):
    def test_a_pooled_codex_thread_is_a_fleet_thread(self):
        # T630: a Codex on the pool's credential proxy reads modelProvider "fleet";
        # refusing it left every pooled looping Codex unswitchable.
        source = dict(session_id='t1', worktree='/tmp', codex_identity={'remote': ''})
        for provider, ok in (('openai', True), ('fleet', True), ('azure', False), (None, False)):
            thread = dict(id='t1', modelProvider=provider, cwd='/tmp')
            with patch.object(src, 'RPC'), patch.dict(src.ATTENTION, thread_read=lambda *a, **k: thread):
                if ok:
                    self.assertEqual(src.native_thread(source), thread)
                else:
                    with self.assertRaisesRegex(ValueError, 'provider changed'):
                        src.native_thread(source)

    def test_manual_transfer_accepts_only_a_settled_looping_codex_round(self):
        source = dict(session='test', window='@2', pane='%2', pid=42, session_id='source', agent='codex', state='looping')
        idle = lambda last, items=(dict(status='completed'),), kind='idle': dict(
            status={'type': kind}, turns=[dict(status=last, items=list(items))])
        with patch.object(src, 'inspect', return_value=source), patch.object(src, 'native_thread') as thread:
            thread.return_value = idle('completed'); src.settled('test', '%2')
            for bad, why in ((idle('interrupted'), 'between rounds'), (idle('completed', kind='active'), 'still active'),
                             (idle('completed', [dict(status='inProgress')]), 'tool is still active')):
                thread.return_value = bad
                with self.assertRaisesRegex(ValueError, why): src.settled('test', '%2')
            thread.return_value = idle('completed')
            for other in (dict(source, state='working'), dict(source, agent='claude')):
                src.inspect.return_value = other
                with self.assertRaisesRegex(ValueError, 'between rounds'): src.settled('test', '%2')


class Background(unittest.TestCase):
    def setUp(self):
        self.source = dict(session='test', window='@2', pane='%2', pid=42, session_id='s', agent='claude',
                           worktree='/w', transcript='/t', state='working')
        self.sleep = module('sleep_bg', 'fleet_worker_life.py')
        # A `next dev` shell: zsh (43) → node (44), neither an MCP server.
        rows = {43: (42, 'zsh'), 44: (43, 'node')}
        self.argv = {42: ['claude'], 43: ['/bin/zsh', '-c', 'next dev -p 3117'], 44: ['node', 'next', 'dev']}
        mods = {'fleet_worker_life.py': vars(self.sleep), 'fleet_agent_argv.py': {'process_argv': lambda pid: self.argv[pid]}}
        for p in (patch.dict(self.sleep.TRANSFER, process_rows=lambda: rows),
                  patch.dict(self.sleep.MCP, claude_inventory=lambda *a: {}, classify=lambda *a: set()),
                  patch.dict(self.sleep.ARGV, process_argv=lambda pid: self.argv[pid],
                             process_executable=lambda pid: Path(self.argv[pid][0])),
                  patch.object(src.runpy, 'run_path', side_effect=lambda f: mods[Path(f).name]),
                  patch.object(src, 'process_start', return_value=('S', 'Mon Sep 20 10:00:00 2026')),
                  patch.object(src, 'process_cwd', return_value='/w/web')):
            p.start(); self.addCleanup(p.stop)

    def test_the_inventory_collects_what_hibernation_would_veto(self):
        with self.assertRaisesRegex(ValueError, 'pid=43'): self.sleep.quiet_processes(self.source)
        bg = src.background_inventory(self.source)
        self.assertEqual([(e['pid'], e['argv'], e['cwd']) for e in bg],
                         [(43, self.argv[43], '/w/web'), (44, self.argv[44], '/w/web')])
        note = src.background_note(bg)
        self.assertIn('Background commands terminated by migration', note)
        self.assertIn("/bin/zsh -c 'next dev -p 3117'", note)

    def test_claude_background_collects_a_named_pids_children(self):
        with patch.object(src, 'background_inventory', side_effect=lambda s: [s]):
            s = src.claude_background('42', '/w', 'fleet-x')[0]
        self.assertEqual((s['pid'], s['agent'], s['worktree'], s['session']), (42, 'claude', '/w', 'fleet-x'))


class TerminateBackground(unittest.TestCase):
    def test_only_the_recorded_live_process_is_stopped_and_named(self):
        with tempfile.TemporaryDirectory() as tmp:
            req = Path(tmp) / 'req'; bundle = Path(tmp) / 'bundle'; req.mkdir(); bundle.mkdir()
            (bundle / 'pickup.md').write_text('pickup\n'); (bundle / 'handoff.md').write_text('handoff\n')
            job = subprocess.Popen(['sleep', '60']); self.addCleanup(lambda p=job: (p.kill(), p.wait()))
            reused = subprocess.Popen(['sleep', '60']); self.addCleanup(lambda p=reused: (p.kill(), p.wait()))
            start = src.process_start(job.pid)[1]
            src.save(req / 'background.json', [
                dict(pid=job.pid, argv=['sleep', '60'], cwd=tmp, start=start),
                # a recorded pid now held by a DIFFERENT process must survive
                dict(pid=reused.pid, argv=['old'], cwd=tmp, start='Thu Jan  1 00:00:00 1970')])
            src.terminate_background(req, bundle)
            self.assertEqual(job.wait(timeout=5), -15)
            self.assertIsNone(reused.poll())
            self.assertEqual([e['stopped'] for e in src.read(req / 'background.json')], ['SIGTERM', 'exited'])
            for name in ('pickup.md', 'handoff.md'):
                text = (bundle / name).read_text()
                self.assertIn('Background commands terminated by migration', text)
                self.assertIn('`sleep 60` (cwd `%s`)' % tmp, text)

    def test_forced_migrate_prints_its_own_note_and_touches_no_bundle(self):
        # fleet-migrate.sh --force-bg (#873): the note comes back on stdout.
        with tempfile.TemporaryDirectory() as tmp:
            req = Path(tmp) / 'req'; req.mkdir()
            job = subprocess.Popen(['sleep', '61']); self.addCleanup(lambda p=job: (p.kill(), p.wait()))
            src.save(req / 'background.json', [dict(pid=job.pid, argv=['sleep', '61'], cwd=tmp,
                                                    start=src.process_start(job.pid)[1])])
            out = io.StringIO()
            with contextlib.redirect_stdout(out): src.terminate_background(req, None, 'The operator forced this move')
            self.assertEqual(job.wait(timeout=5), -15)
            self.assertIn('The operator forced this move, so these background commands', out.getvalue())
            self.assertEqual(list(Path(tmp).iterdir()), [req])


class Cli(unittest.TestCase):
    def test_the_retired_planner_and_its_entry_points_are_gone(self):
        bin_ = Path(__file__).parent
        self.assertFalse((bin_ / '.fleet-failover.py').exists())
        for args, word in ((['bash', str(bin_ / 'fleet-account.sh'), 'reconcile', '--session', 'x'], '已不用'),
                           (['bash', str(bin_ / 'fleet-account.sh'), 'failover-status'], '已不用')):
            r = subprocess.run(args, capture_output=True, text=True, timeout=30,
                               env=dict(os.environ, FLEET_SKIP_GLOBAL_CONF='1'))
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn(word, r.stderr)
        r = subprocess.run(['bash', str(bin_ / 'fleet-migrate.sh'), '--limited', '--session', 'x'],
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 2); self.assertIn('已不用', r.stderr)


if __name__ == '__main__':
    unittest.main()
