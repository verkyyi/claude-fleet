#!/usr/bin/env python3
"""Native creation intent and accepted-launch fences with real temporary Git repositories."""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
from unittest import mock

import fleet_launch as launch
import fleet_repo_authority as authority



# The hub's own owner/endpoint for a reservation, and its independent reserved
# read before begin (#4536): the supervisor never takes these from an ACK.
HUB_SCOPE = dict(owner='fixture-owner', endpoint_id='fixture-node')


def reserved_read(method, path, body=None, query=None):
    assert (method, path) == ('GET', '/authority/start'), (method, path)
    return dict(HUB_SCOPE, repo=query['repo'], reservation=query['reservation'], phase='reserved')

class NativeCreation(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='fleet-native-create-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.main = self.root / 'repository'
        self.environment = dict(PATH=os.environ['PATH'], HOME=str(self.root),
            GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
            GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
            GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')
        self.command_run = subprocess.run
        self.git('init', '-q', '-b', 'master', str(self.main))
        self.git('-C', str(self.main), 'commit', '--allow-empty', '-qm', 'fixture')
        self.intent = launch.new_native_worktree(str(self.main), 'master')
        self.path = launch.native_worktree_path(self.intent)
        self.context = dict(version=1, operation_id='11111111-1111-4111-8111-111111111111',
                            task='T1', owner='alice', generation=1,
                            worker_id='22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333',
                            provider='claude', attempt_id='task:T1:g1')
        self.native = dict(actual_provider='claude', pid=42, birth='fixture-process-1', executable='/fixture/claude')
        self.payload = dict(hook_event_name='SessionStart', cwd=str(self.path),
                            session_id='44444444-4444-4444-8444-444444444444')
        self.options = {'@native_worktree': json.dumps(self.intent), '@launch': json.dumps(self.context),
                        '@fleet_id': self.context['worker_id'].split('/')[1], 'pane_pid': '11', 'window_id': '@7'}
        self.option_patch = mock.patch.object(launch, 'option', side_effect=lambda pane, key, *args: self.options.get(key, ''))
        self.option_patch.start()
        self.addCleanup(self.option_patch.stop)

    def git(self, *arguments):
        return self.command_run(['git', *arguments], env=self.environment, capture_output=True,
                        text=True, check=True, timeout=10).stdout.strip()

    def create(self):
        self.git('-C', str(self.main), 'worktree', 'add', '-qb', 'worktree-' + self.intent['name'],
                 str(self.path), self.intent['commit'])
        return launch.worktree_identity(str(self.path))

    def tmux(self, *arguments, **unused):
        if arguments[:2] == ('set-option', '-wu'):
            self.options.pop(arguments[4], None)
        elif arguments[0] == 'set-option':
            self.options[arguments[4]] = arguments[5]
        return ''

    def observe(self):
        environment = dict(TMUX_PANE='%1', FLEET_LAUNCH_CONTEXT=json.dumps(self.context),
                           FLEET_LAUNCH_SUPERVISOR='12', FLEET_LAUNCH_CREATE=json.dumps(self.intent))
        with mock.patch.dict(os.environ, environment), \
                mock.patch.object(launch, 'native_parent', return_value=self.native), \
                mock.patch.object(launch, 'root_native', return_value=True), \
                mock.patch.object(launch, 'tmux', side_effect=self.tmux):
            launch.hook(self.payload)

    def test_intent_does_not_create_a_directory_or_branch(self):
        self.assertFalse(self.path.exists())
        self.assertEqual(self.git('-C', str(self.main), 'branch', '--list'), '* master')
        self.assertEqual(launch.prepare_native_worktree('%1', 'claude', None), self.intent)
        self.assertEqual(self.intent['commit'], self.git('-C', str(self.main), 'rev-parse', 'HEAD'))

    def test_intent_validates_shape_and_stays_inside_the_repository(self):
        for field, value in (('name', '../escape'), ('name', 'scratch-0'), ('root', 'relative'),
                             ('commit', 'HEAD'), ('base', '--help'), ('common_dir', '/tmp\nelsewhere')):
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                launch.validate_native_worktree(dict(self.intent, **{field: value}))
        with self.assertRaises(ValueError):
            launch.validate_native_worktree(dict(self.intent, extra=True))
        (self.main / '.claude').symlink_to(self.root)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            launch.prepare_native_worktree('%1', 'claude', None)

    def test_provider_existing_path_branch_and_moved_base_refuse(self):
        with self.assertRaisesRegex(ValueError, 'Claude'):
            launch.prepare_native_worktree('%1', 'codex', None)
        self.path.mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, 'pre-existing'):
            launch.prepare_native_worktree('%1', 'claude', None)
        self.path.rmdir()
        self.git('-C', str(self.main), 'branch', 'worktree-' + self.intent['name'])
        with self.assertRaisesRegex(ValueError, 'pre-existing'):
            launch.prepare_native_worktree('%1', 'claude', None)
        self.git('-C', str(self.main), 'branch', '-D', 'worktree-' + self.intent['name'])
        self.git('-C', str(self.main), 'commit', '--allow-empty', '-qm', 'new base')
        with self.assertRaisesRegex(ValueError, 'base changed'):
            launch.prepare_native_worktree('%1', 'claude', None)

    def test_native_cwd_binding_refuses_wrong_tree_base_and_retargeted_window(self):
        binding = self.create()
        self.assertEqual(launch.observe_native_worktree('%1', self.payload, self.intent), binding)
        with self.assertRaises(ValueError):
            launch.observe_native_worktree('%1', dict(self.payload, cwd=str(self.main)), self.intent)
        self.options['@worktree'] = str(self.root)
        with self.assertRaisesRegex(ValueError, 'another worktree'):
            launch.observe_native_worktree('%1', self.payload, self.intent)
        del self.options['@worktree']
        self.git('-C', str(self.path), 'commit', '--allow-empty', '-qm', 'wrong base')
        with self.assertRaisesRegex(ValueError, 'base commit'):
            launch.observe_native_worktree('%1', self.payload, self.intent)

    def test_actual_worktree_is_stamped_only_after_matching_native_receipt(self):
        binding = self.create()
        self.payload['session_id'] = 'not-a-session'
        with self.assertRaises(ValueError):
            self.observe()
        self.assertNotIn('@worktree', self.options)
        self.assertNotIn('@launch_receipt', self.options)
        self.payload['session_id'] = '44444444-4444-4444-8444-444444444444'
        self.observe()
        receipt = json.loads(self.options['@launch_receipt'])
        self.assertEqual(receipt['worktree'], binding)
        self.assertEqual(receipt['native_worktree'], self.intent)
        self.assertEqual(self.options['@worktree'], str(self.path))
        self.git('-C', str(self.path), 'commit', '--allow-empty', '-qm', 'user work')
        self.observe()
        self.assertEqual(json.loads(self.options['@launch_receipt']), receipt)

    def test_recovery_keeps_exact_saved_identity_and_refuses_lost_intent(self):
        binding = self.create()
        self.observe()
        receipt = json.loads(self.options['@launch_receipt'])
        self.git('-C', str(self.path), 'commit', '--allow-empty', '-qm', 'user work')
        self.assertEqual(launch.prepare_native_worktree('%1', 'claude', binding, receipt), self.intent)
        altered = copy.deepcopy(receipt)
        altered['native_worktree']['name'] = 'scratch-9'
        with self.assertRaises(ValueError):
            launch.prepare_native_worktree('%1', 'claude', binding, altered)
        del self.options['@native_worktree']
        with self.assertRaisesRegex(ValueError, 'disappeared'):
            launch.prepare_native_worktree('%1', 'claude', binding, receipt)

    def test_supervisor_delegates_creation_without_leaking_seed(self):
        seed = self.root / 'seed'
        seed.write_text('held fixture input\n')
        self.options['@launch_seed'] = str(seed)
        child = mock.Mock(pid=12)
        child.poll.return_value = None
        started, deliveries = [], []

        def finish(*arguments, **options):
            child.poll.return_value = 0
            return 0

        child.wait.side_effect = finish

        def popen(arguments, **options):
            self.assertFalse(self.path.exists())
            started.append((arguments, options))
            self.create()
            self.observe()
            return child

        def run(arguments, **options):
            if str(launch.BIN / 'fleet_task_control.py') in arguments:
                return subprocess.CompletedProcess(arguments, 0, '', '')
            if 'launch' in arguments:
                deliveries.append(options['input'])
                return subprocess.CompletedProcess(arguments, 0, '', '')
            return self.command_run(arguments, **options)

        process_api = types.SimpleNamespace(**vars(subprocess))
        process_api.Popen = popen
        process_api.run = run
        with mock.patch.dict(os.environ, {'TMUX_PANE': '%1'}), \
                mock.patch.object(launch, 'tmux', side_effect=self.tmux), \
                mock.patch.object(launch, 'same_process', return_value=True), \
                mock.patch.object(launch, 'process', return_value=dict(self.native, pid=12)), \
                mock.patch.object(launch, 'descendant', return_value=True), \
                mock.patch.object(launch, 'current_task'), \
                mock.patch.object(launch, 'publish') as published, \
                mock.patch.object(launch, 'stop_created') as stopped, \
                mock.patch.object(launch, 'subprocess', process_api):
            self.assertEqual(launch.supervise(['launcher', '--agent', 'claude', 'held fixture input']), 0)
        self.assertEqual(started[0][0], ['launcher', '--agent', 'claude', '--worktree', self.intent['name'],
                                         '--name', self.intent['name']])
        self.assertEqual(started[0][1]['cwd'], str(self.main))
        self.assertEqual(deliveries, ['held fixture input'])
        self.assertEqual(published.call_count, 1)
        stopped.assert_not_called()

    def test_restore_reconstructs_intent_only_from_exact_saved_binding(self):
        binding = self.create()
        self.observe()
        receipt = json.loads(self.options['@launch_receipt'])
        arguments = [str(self.path), receipt['native_session'], 'claude', self.context['worker_id'].split('/')[1]]
        self.git('-C', str(self.path), 'commit', '--allow-empty', '-qm', 'retained user work')
        self.assertEqual(launch.restore_native_worktree(self.context, receipt, *arguments), self.intent)
        for index, replacement in enumerate((str(self.main), '55555555-5555-4555-8555-555555555555', 'codex', 'another-window')):
            altered = arguments.copy()
            altered[index] = replacement
            with self.subTest(index=index), self.assertRaises(ValueError):
                launch.restore_native_worktree(self.context, receipt, *altered)
        altered = copy.deepcopy(receipt)
        altered['worktree']['git_dir'] = binding['git_dir'] + '-replaced'
        with self.assertRaisesRegex(ValueError, 'Git binding'):
            launch.restore_native_worktree(self.context, altered, *arguments)
        altered = copy.deepcopy(self.context)
        altered['generation'] = 2
        altered['attempt_id'] = 'task:T1:g2'
        with self.assertRaises(ValueError):
            launch.restore_native_worktree(altered, receipt, *arguments)
        (self.path / '.git').unlink()
        with self.assertRaises(ValueError):
            launch.restore_native_worktree(self.context, receipt, *arguments)

    def test_restore_leaves_legacy_and_unverified_launches_on_existing_path(self):
        for receipt in (None, dict(self.context, **self.native)):
            self.assertIsNone(launch.restore_native_worktree(self.context, receipt, str(self.main), '-', 'claude', '-'))

    def test_unverified_transfer_refuses_before_mutating_task_ownership(self):
        self.create()
        self.observe()
        with mock.patch.object(launch, 'task_call') as authority:
            for provider in ('claude', 'codex'):
                with self.subTest(provider=provider), self.assertRaisesRegex(ValueError, 'native Claude worktree transfer'):
                    launch.transfer_commit('%1', '', provider, str(self.root / 'unused'))
            authority.assert_not_called()

    def local_context(self):
        return dict(repo='acme/widgets', worker_id=self.context['worker_id'],
                    reservation='66666666-6666-4666-8666-666666666666', supervisor=12,
                    native_worktree=self.intent)

    def observe_local(self, context, observe):
        # The begin acknowledgement the supervisor hands down; the hub answers
        # the observe with the exact same scope plus the native identity.
        admission = dict(HUB_SCOPE, repo=context['repo'], reservation=context['reservation'],
                         worker_id=context['worker_id'], phase='starting')
        def answer(repo, key, action, **fields):
            observe(repo, key, action, **fields)
            return dict(admission, phase='observed', native_identity=fields.get('native_identity'))
        with mock.patch.dict(os.environ, {'TMUX_PANE': '%1', 'FLEET_AUTHORITY_CONTEXT': json.dumps(context),
                                          'FLEET_AUTHORITY_ADMISSION': json.dumps(admission)}), \
                mock.patch.object(launch, 'native_parent', return_value=self.native), \
                mock.patch.object(launch, 'root_native', return_value=True), \
                mock.patch.object(launch, 'tmux', side_effect=self.tmux), \
                mock.patch.object(authority, 'start_call', side_effect=answer):
            authority.observe_native(self.payload)

    def test_local_native_hook_binds_only_after_authority_observation(self):
        binding = self.create()
        context = self.local_context()
        with self.assertRaisesRegex(ValueError, 'unavailable'):
            self.observe_local(context, mock.Mock(side_effect=ValueError('unavailable')))
        self.assertNotIn('@worktree', self.options)
        observe = mock.Mock()
        self.observe_local(context, observe)
        self.assertEqual(observe.call_args.args, ('acme/widgets', context['reservation'], 'observe'))
        receipt = json.loads(self.options['@authority_receipt'])
        self.assertEqual(receipt['worktree'], binding)
        self.assertEqual(receipt['native_worktree'], self.intent)
        self.git('-C', str(self.path), 'commit', '--allow-empty', '-qm', 'user work')
        self.observe_local(context, observe)
        changed = copy.deepcopy(context)
        changed['native_worktree']['commit'] = '0' * 40
        with self.assertRaisesRegex(ValueError, 'replace native creation intent'):
            self.observe_local(changed, observe)
        self.native['birth'] = 'replaced-process'
        with self.assertRaisesRegex(ValueError, 'late local hook'):
            self.observe_local(context, observe)
        self.assertEqual(json.loads(self.options['@authority_receipt']), receipt)

    def test_local_native_supervisor_admits_before_creation_and_requires_exact_resume(self):
        actions, started = [], []
        reservations = []
        child = mock.Mock()
        child.wait.return_value = 0
        worker = self.context['worker_id']
        def start(repo, reservation, action, **fields):
            self.assertEqual(repo, 'acme/widgets')
            if action == 'reserve':
                reservations.append(reservation)
            self.assertEqual(reservation, reservations[-1])
            actions.append(action)
            if action == 'begin':
                return dict(HUB_SCOPE, repo=repo, reservation=reservation,
                            worker_id=fields['worker_id'], phase='starting')
        def run(arguments, **options):
            if arguments[:2] == ['bash', '-c']:
                return subprocess.CompletedProcess(arguments, 0, 'acme/widgets\t' + worker, '')
            return self.command_run(arguments, **options)
        def popen(arguments, **options):
            self.assertEqual(actions[-1], 'begin')
            started.append(arguments)
            self.assertEqual(options['cwd'], str(self.main))
            self.assertNotIn('FLEET_AUTHORITY_START', options['env'])
            for variable in ('FLEET_LAUNCH_CREATE', 'FLEET_LAUNCH_WORKTREE', 'FLEET_LAUNCH_CONTEXT'):
                self.assertNotIn(variable, options['env'])
            if not self.path.exists():
                self.create()
            self.observe_local(json.loads(options['env']['FLEET_AUTHORITY_CONTEXT']), start)
            return child
        process_api = types.SimpleNamespace(**vars(subprocess))
        process_api.run, process_api.Popen = run, popen
        with mock.patch.dict(os.environ, {'TMUX_PANE': '%1', 'FLEET_AUTHORITY_START': '',
                'FLEET_LAUNCH_CREATE': 'inherited', 'FLEET_LAUNCH_WORKTREE': 'inherited',
                'FLEET_LAUNCH_CONTEXT': 'inherited'}), \
                mock.patch.object(authority, 'subprocess', process_api), \
                mock.patch.object(authority.signal, 'signal'), \
                mock.patch.object(authority, 'start_call', side_effect=start), \
                mock.patch.object(authority.hubrest, 'api', side_effect=reserved_read), \
                mock.patch.object(authority, 'prove_stopped', side_effect=lambda proof: proof), \
                mock.patch.object(launch, 'same_process', return_value=False):
            self.assertEqual(authority.supervise(['launcher', '--agent', 'claude']), 0)
            self.assertEqual(actions, ['reserve', 'begin', 'observe', 'stopped'])
            self.assertEqual(started[0], ['launcher', '--agent', 'claude', '--worktree', self.intent['name'], '--name', self.intent['name']])
            with mock.patch.object(launch, 'same_process', return_value=True), \
                    self.assertRaisesRegex(ValueError, 'reconnect instead'):
                authority.supervise(['launcher', '--resume', self.payload['session_id']])
            saved = self.options['@authority_receipt']
            wrong = json.loads(saved)
            wrong['worker_id'] = 'another-worker'
            self.options['@authority_receipt'] = json.dumps(wrong)
            with self.assertRaisesRegex(ValueError, 'another repository or worker'):
                authority.supervise(['launcher', '--resume', self.payload['session_id']])
            self.options['@authority_receipt'] = saved
            self.native['birth'] = 'new-incarnation'
            self.assertEqual(authority.supervise(['launcher', '--agent', 'claude', '--resume', self.payload['session_id']]), 0)
            self.assertEqual(actions, ['reserve', 'begin', 'observe', 'stopped'] * 2)
            before = len(started)
            for arguments in (['launcher', '--agent', 'claude'], ['launcher', '--agent', 'codex'],
                              ['launcher', '--resume', '55555555-5555-4555-8555-555555555555']):
                with self.assertRaises(ValueError):
                    authority.supervise(arguments)
            self.assertEqual(len(started), before)
            del self.options['@native_worktree']
            with self.assertRaisesRegex(ValueError, 'lost its creation intent'):
                authority.supervise(['launcher', '--resume', self.payload['session_id']])

    def test_local_native_supervisor_refuses_missing_authority_or_submitted_input(self):
        process_api = types.SimpleNamespace(**vars(subprocess))
        process_api.run = mock.Mock(return_value=subprocess.CompletedProcess([], 0, '', ''))
        process_api.Popen, process_api.execvpe = mock.Mock(), mock.Mock()
        with mock.patch.dict(os.environ, {'TMUX_PANE': '%1'}), \
                mock.patch.object(authority, 'subprocess', process_api), \
                mock.patch.object(authority.os, 'execvpe') as execute, \
                mock.patch.object(authority, 'start_call') as start:
            with self.assertRaisesRegex(ValueError, 'explicit repository admission'):
                authority.supervise(['launcher'])
            execute.assert_not_called()
            process_api.run.return_value.stdout = 'acme/widgets\t' + self.context['worker_id']
            with self.assertRaisesRegex(ValueError, 'seed'):
                authority.supervise(['launcher', 'submitted input'])
            process_api.Popen.assert_not_called()
            start.assert_not_called()

    def test_local_native_begin_refusal_never_starts_or_creates(self):
        reservation = self.local_context()['reservation']
        process_api = types.SimpleNamespace(**vars(subprocess))
        process_api.Popen = mock.Mock()
        def run(arguments, **options):
            if arguments[:2] == ['bash', '-c']:
                return subprocess.CompletedProcess(arguments, 0, 'acme/widgets\t' + self.context['worker_id'], '')
            return self.command_run(arguments, **options)
        process_api.run = run
        actions = []
        def start(repo, key, action, **fields):
            self.assertEqual(key, reservation)
            actions.append(action)
            if action == 'begin':
                raise ValueError('frozen fixture')
        with mock.patch.dict(os.environ, {'TMUX_PANE': '%1', 'FLEET_AUTHORITY_START': reservation}), \
                mock.patch.object(authority, 'subprocess', process_api), \
                mock.patch.object(authority, 'start_call', side_effect=start), \
                mock.patch.object(authority.hubrest, 'api', side_effect=reserved_read), \
                self.assertRaisesRegex(ValueError, 'frozen fixture'):
            authority.supervise(['launcher'])
        self.assertEqual(actions, ['begin', 'cancel'])
        self.assertFalse(self.path.exists())
        process_api.Popen.assert_not_called()

    def test_local_restore_requires_exact_saved_native_and_git_identity(self):
        self.create()
        self.observe_local(self.local_context(), mock.Mock())
        receipt = json.loads(self.options['@authority_receipt'])
        arguments = [str(self.path), self.payload['session_id'], 'claude',
                     self.context['worker_id'].split('/')[1], 'acme/widgets']
        self.git('-C', str(self.path), 'commit', '--allow-empty', '-qm', 'retained user commit')
        self.assertEqual(authority.restore_native_worktree(receipt, *arguments), self.intent)
        for index, replacement in enumerate((str(self.main), '55555555-5555-4555-8555-555555555555',
                                             'codex', 'another-window', 'another/repository')):
            altered = arguments.copy()
            altered[index] = replacement
            with self.subTest(index=index), self.assertRaises(ValueError):
                authority.restore_native_worktree(receipt, *altered)
        for key, value in (('native_identity', None), ('worker_id', []), ('reservation', 'invalid')):
            with self.subTest(key=key), self.assertRaises(ValueError):
                authority.restore_native_worktree(dict(receipt, **{key: value}), *arguments)
        altered = copy.deepcopy(receipt)
        altered['native_identity']['worker_id'] = 'another-worker'
        with self.assertRaises(ValueError):
            authority.restore_native_worktree(altered, *arguments)
        altered = copy.deepcopy(receipt)
        altered['worktree']['git_dir'] += '-replaced'
        with self.assertRaisesRegex(ValueError, 'Git binding'):
            authority.restore_native_worktree(altered, *arguments)
        with self.assertRaisesRegex(ValueError, 'no native creation intent'):
            authority.restore_native_worktree({}, *arguments)


if __name__ == '__main__':
    unittest.main()
