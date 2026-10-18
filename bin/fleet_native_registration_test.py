#!/usr/bin/env python3
"""Normal observation / prompt gate failures on an isolated real tmux socket."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import fleet_native_registration as registration
import fleet_repo_authority as authority


@unittest.skipUnless(shutil.which('tmux'), 'tmux required')
class Registration(unittest.TestCase):
    def tm(self, *args):
        return subprocess.check_output(['tmux', '-S', self.socket, *args], text=True).strip()

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='native-registration-', dir='/tmp')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.socket = str(self.root / 'tmux')
        self.addCleanup(lambda: subprocess.run(['tmux', '-S', self.socket, 'kill-server'], capture_output=True))
        self.pane = self.tm('-f', '/dev/null', 'new-session', '-d', '-P', '-F', '#{pane_id}', 'sleep 90')
        self.context = dict(repo='fixture/repo', reservation='new-reservation',
                            worker_id='fleet/11111111-1111-4111-8111-111111111111', supervisor=40)
        self.admission = dict(repo=self.context['repo'], reservation=self.context['reservation'],
                              worker_id=self.context['worker_id'], owner='owner', endpoint_id='node', phase='starting')
        self.payload = dict(hook_event_name='SessionStart', session_id='22222222-2222-4222-8222-222222222222',
                            cwd=str(self.root))
        self.identity = dict(owner='41', session_id=self.payload['session_id'], home=str(self.root / 'codex'),
                             remote='unix:///fixture', cwd=str(self.root))
        env = dict(PATH=os.environ['PATH'], TMUX=self.socket+','+self.tm('display-message', '-p', '#{pid}')+',0', TMUX_PANE=self.pane,
                   FLEET_AUTHORITY_CONTEXT=json.dumps(self.context), FLEET_AUTHORITY_ADMISSION=json.dumps(self.admission),
                   FLEET_CODEX_LAUNCHER_PID='41', FLEET_CONF_DIR=str(self.root / 'conf'),
                   CODEX_HOME=self.identity['home'], FLEET_CODEX_REMOTE=self.identity['remote'])
        for key, value in {'@cc_agent':'codex', '@cc_launcher_pid':'41', '@repo':'fixture/repo',
                           '@fleet_id':self.context['worker_id'].split('/')[-1], '@worktree':str(self.root)}.items():
            self.tm('set-option', '-w', '-t', self.pane, key, value)
        self.native = dict(pid=42, ppid=41, birth='native-birth', executable='/bin/codex', actual_provider='codex')
        def process(pid):
            return dict(pid=int(pid), ppid=40 if int(pid)==41 else 41,
                        birth='native-birth' if int(pid)==42 else 'birth-'+str(pid), executable='/bin/codex')
        for context in (patch.dict(os.environ, env, clear=True),
                        patch.object(registration.launch, 'native_parent', return_value=self.native),
                        patch.object(registration.launch, 'process', side_effect=process),
                        patch.object(registration.launch, 'descendant', return_value=True),
                        patch.object(registration.launch, 'root_native', return_value=True)):
            context.start(); self.addCleanup(context.stop)

    def local(self):
        return registration.read_options(self.pane, self.socket, registration.LOCAL)

    def ack(self, repo, key, action, **kw):
        self.assertEqual((repo, key, action), ('fixture/repo', 'new-reservation', 'observe'))
        return dict(self.admission, phase='observed', native_identity=kw['native_identity'])

    def journal(self):
        return registration.read(next((self.root/'conf/native-registrations').glob('*.json')))

    def test_good_ack_atomically_binds_three_fields_and_later_prompt_only_reads(self):
        with patch.object(authority, 'start_call', side_effect=self.ack) as post:
            result = registration.observe(self.payload, self.identity)
            before = self.local()
            self.assertTrue(all(before.values()))
            path = next((self.root/'conf/native-registrations').glob('*.json'))
            original = path.read_bytes()
            for _ in range(2):
                registration.verify_registered(dict(self.payload, hook_event_name='UserPromptSubmit'))
                self.assertEqual(registration.observe(self.payload, self.identity), result)
            self.assertEqual(post.call_count, 1)
            self.assertEqual(self.local(), before)
            self.assertEqual(path.read_bytes(), original)

    def linked_worktree(self):
        common = self.root / 'repo'
        subprocess.run(['git', 'init', '-q', str(common)], check=True)
        subprocess.run(['git', '-C', str(common), '-c', 'user.name=t', '-c', 'user.email=t@t',
                        'commit', '-q', '--allow-empty', '-m', 'init'], check=True)
        tree = self.root / 'repo-issue-1'
        subprocess.run(['git', '-C', str(common), 'worktree', 'add', '-q', str(tree)], check=True)
        binding = registration.launch.worktree_identity(str(tree))
        self.tm('set-option', '-w', '-t', self.pane, '@worktree', binding['root'])
        self.payload['cwd'] = self.identity['cwd'] = binding['root']
        return binding

    def test_linked_worktree_context_registers_and_later_prompt_reads(self):
        # #4780: since #4573 a linked-worktree window's context carries `worktree`.
        context = dict(self.context, worktree=self.linked_worktree())
        with patch.dict(os.environ, FLEET_AUTHORITY_CONTEXT=json.dumps(context)), \
                patch.object(authority, 'start_call', side_effect=self.ack) as post:
            registration.observe(self.payload, self.identity)
            registration.verify_registered(dict(self.payload, hook_event_name='UserPromptSubmit'))
            self.assertEqual(post.call_count, 1)
        self.assertTrue(all(self.local().values()))

    def test_worktree_context_that_differs_or_carries_more_keys_refuses(self):
        binding = self.linked_worktree()
        cases = dict(other=dict(self.context, worktree=dict(binding, root=str(self.root))),
                     malformed=dict(self.context, worktree=dict(binding, extra='/x')),
                     native=dict(self.context, worktree=binding, native_worktree={'name': 'x'}),
                     unknown=dict(self.context, unknown=1))
        for name, context in cases.items():
            with self.subTest(case=name), patch.dict(os.environ, FLEET_AUTHORITY_CONTEXT=json.dumps(context)), \
                    patch.object(authority, 'start_call') as post:
                with self.assertRaises(ValueError):
                    registration.observe(self.payload, self.identity)
                post.assert_not_called()
        self.assertEqual(self.local(), dict.fromkeys(registration.LOCAL, ''))

    def test_unknown_later_prompt_never_creates_journal_or_posts(self):
        with patch.object(authority, 'start_call') as post:
            with self.assertRaises((ValueError, OSError)):
                registration.verify_registered(dict(self.payload, hook_event_name='UserPromptSubmit'))
            post.assert_not_called()
        self.assertFalse((self.root/'conf/native-registrations').exists())

    def test_lost_ack_never_registers_or_reposts_and_later_prompt_refuses(self):
        before = self.local()
        with patch.object(authority, 'start_call', side_effect=TimeoutError('lost ack')) as post:
            for _ in range(2):
                with self.assertRaises(ValueError):
                    registration.observe(self.payload, self.identity)
            with self.assertRaises(ValueError):
                registration.verify_registered(dict(self.payload, hook_event_name='UserPromptSubmit'))
            self.assertEqual(post.call_count, 1)
        self.assertEqual(self.local(), before)
        self.assertEqual(self.journal()['state'], 'hub-unconfirmed/local-unchanged')

    def test_wrong_ack_fields_leave_all_local_fields_unchanged(self):
        for field in (*authority.START_KEYS, 'phase', 'native_identity', 'unknown'):
            with self.subTest(field=field):
                # Independent reservation/lifetime fixture per fault.
                self.context['reservation'] = 'reservation-' + field
                self.admission['reservation'] = self.context['reservation']
                os.environ['FLEET_AUTHORITY_CONTEXT'] = json.dumps(self.context)
                os.environ['FLEET_AUTHORITY_ADMISSION'] = json.dumps(self.admission)
                def bad(repo, key, action, **kw):
                    ack = dict(self.admission, phase='observed', native_identity=kw['native_identity'])
                    ack[field] = 'wrong'
                    return ack
                before = self.local()
                with patch.object(authority, 'start_call', side_effect=bad):
                    with self.assertRaisesRegex(ValueError, 'hub-unconfirmed/local-unchanged'):
                        registration.observe(self.payload, self.identity)
                self.assertEqual(self.local(), before)

    def test_missing_independent_scope_refuses_before_post(self):
        for missing in ('owner', 'endpoint_id'):
            with self.subTest(missing=missing):
                unknown = dict(self.admission); del unknown[missing]
                with patch.dict(os.environ, FLEET_AUTHORITY_ADMISSION=json.dumps(unknown)), \
                        patch.object(authority, 'start_call') as post:
                    with self.assertRaises(ValueError):
                        registration.observe(self.payload, self.identity)
                    post.assert_not_called()

    def test_original_resume_sid_cannot_change_before_observation(self):
        with patch.dict(os.environ, FLEET_AUTHORITY_RESUME_SID='33333333-3333-4333-8333-333333333333'), \
                patch.object(authority, 'start_call') as post:
            with self.assertRaisesRegex(ValueError, 'resume changed original native SID'):
                registration.observe(self.payload, self.identity)
            post.assert_not_called()

    def test_old_hook_good_ack_after_rebinding_cannot_overwrite_successor(self):
        def delayed(*args, **kwargs):
            ack = self.ack(*args, **kwargs)
            self.tm('set-option', '-w', '-t', self.pane, '@cc_launcher_pid', '99')
            for key in registration.LOCAL:
                self.tm('set-option', '-w', '-t', self.pane, key, 'successor')
            return ack
        with patch.object(authority, 'start_call', side_effect=delayed) as post:
            with self.assertRaisesRegex(ValueError, 'hub-confirmed/local-pending'):
                registration.observe(self.payload, self.identity)
            self.assertEqual(post.call_count, 1)
        self.assertEqual(set(self.local().values()), {'successor'})
        self.assertEqual(self.journal()['state'], 'hub-confirmed/local-pending')

    def test_cas_snapshots_all_three_fields_and_routing_in_same_tmux_queue(self):
        original = registration.launch.tmux
        def race(*args, **kwargs):
            if args[0] == 'if-shell':
                self.tm('set-option', '-w', '-t', self.pane, '@codex_session_id', 'raced')
            return original(*args, **kwargs)
        with patch.object(authority, 'start_call', side_effect=self.ack), \
                patch.object(registration.launch, 'tmux', side_effect=race):
            with self.assertRaisesRegex(ValueError, 'hub-confirmed/local-pending'):
                registration.observe(self.payload, self.identity)
        self.assertEqual(self.local(), {'@authority_receipt':'', '@codex_identity':'', '@codex_session_id':'raced'})
        with patch.object(authority, 'start_call') as post:
            with self.assertRaises(ValueError):
                registration.observe(self.payload, self.identity)
            post.assert_not_called()


if __name__ == '__main__':
    unittest.main()
