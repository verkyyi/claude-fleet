#!/usr/bin/env python3
"""Recovery fixtures; never a live fleet, account, or provider acceptance."""
import copy
import base64
import io
import os
from pathlib import Path
import runpy
import tempfile
import subprocess
import json
import shutil
import socket
import threading
from types import SimpleNamespace
from unittest.mock import patch, Mock
import unittest

import fleet_native_observe as recovery


class Recovery(unittest.TestCase):
    def setUp(self):
        self.proof = dict(worker_id="fleet/worker", native_session="original-sid",
                          pid=42, birth="kernel-birth", executable="/fixture/codex")
        self.start = dict(reservation="original-reservation", repo="org/repo", owner="alice",
                          endpoint_id="node", worker_id="fleet/worker", phase="starting")

    def test_ack_requires_exact_original_execution(self):
        ack = dict(self.start, phase="observed", native_identity=self.proof)
        recovery.check_ack(self.start, self.proof, ack)
        for key in ("reservation", "repo", "owner", "endpoint_id", "worker_id", "phase"):
            bad = dict(ack, **{key: "other"})
            with self.subTest(key=key), self.assertRaises(ValueError):
                recovery.check_ack(self.start, self.proof, bad)

        for key in self.proof:
            bad = copy.deepcopy(ack)
            bad["native_identity"][key] = "other"
            with self.subTest(key=key), self.assertRaises(ValueError):
                recovery.check_ack(self.start, self.proof, bad)

    def test_fresh_comparison_rejects_every_changed_scope_before_write(self):
        plan = dict(version=1, hub=self.start, binding=dict(pane='%1', socket='isolated'),
                    processes=dict(native=self.proof), context=dict(repo='org/repo'), proof=self.proof,
                    identity=dict(session_id='original'), hooks=dict(state='missing'),
                    account=dict(kind='subscription', account='original'), phase=dict(status='active', turn='original'))
        for field in ('binding', 'processes', 'context', 'proof', 'identity', 'hooks', 'account', 'phase'):
            current = copy.deepcopy(plan)
            current[field]['changed'] = True
            with self.subTest(field=field), patch.object(recovery, 'inspect', return_value=current), patch.object(recovery.authority, 'start_call') as write:
                with self.assertRaises(ValueError): recovery.apply(plan)
                write.assert_not_called()

    def test_ack_loss_and_post_ack_failures_are_distinct(self):
        plan = dict(version=1, hub=self.start, binding=dict(pane='%1', socket='isolated'),
                    processes={}, context=dict(repo='org/repo', reservation='original', worker_id='fleet/worker'),
                    proof=self.proof, identity={}, hooks={}, account={}, phase={})
        ack = dict(self.start, phase='observed', native_identity=self.proof)
        with patch.object(recovery, 'inspect', return_value=plan), patch.object(recovery.authority, 'start_call', side_effect=OSError('private URL/token')):
            with self.assertRaisesRegex(recovery.RecoveryFailure, '^hub-unconfirmed/local-unchanged$'): recovery.apply(plan)
        with patch.object(recovery, 'inspect', side_effect=[plan, OSError('native gone')]), patch.object(recovery.authority, 'start_call', return_value=ack):
            with self.assertRaisesRegex(recovery.RecoveryFailure, '^hub-confirmed/local-pending$'): recovery.apply(plan)

    def test_kernel_peer_mismatch_sends_no_rpc(self):
        with tempfile.TemporaryDirectory(prefix='peer-', dir='/tmp') as directory:
            listener = socket.socket(socket.AF_UNIX)
            self.addCleanup(listener.close)
            listener.bind(directory + '/rpc')
            listener.listen(1)
            received = []
            def accept():
                connection, _ = listener.accept()
                with connection: received.append(connection.recv(128))
            thread = threading.Thread(target=accept)
            thread.start()
            with self.assertRaisesRegex(ValueError, 'peer PID changed'):
                recovery.runtime.RPC('unix://' + directory + '/rpc', peer_pid=os.getpid() + 100000)
            thread.join(3)
            self.assertEqual(received, [b''])


class LocalRegistration(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='obs-', dir='/tmp')
        self.socket = self.directory.name + '/tmux'
        self.tmux = lambda *a: recovery.launch.tmux(*a, socket=self.socket)
        self.tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'isolated', 'sleep 120')
        self.pane = self.tmux('display-message', '-p', '#{pane_id}')
        self.row = {k: '' for k in recovery.WINDOW_KEYS}
        self.row.update({'@fleet_id': 'original', '@cc_agent': 'codex', '@cc_launcher_pid': '42', '@repo': 'org/repo',
                         '@worktree': '/tmp/dirty,work#tree'})
        for k, v in self.row.items():
            self.tmux('set-option', '-w', '-t', self.pane, k, v)
        self.row.update(pane=self.pane, socket=self.socket)
        proof = dict(worker_id='fleet/worker', native_session='sid', pid=42, birth='b', executable='/bin/codex')
        context = dict(repo='org/repo', worker_id='fleet/worker', reservation='original', supervisor=40)
        hub = dict(context, owner='alice', endpoint_id='node', phase='observed', native_identity=proof)
        hub.pop('supervisor')  # the Hub does not persist a local supervisor PID
        self.plan = dict(binding=self.row, proof=proof, context=context, processes={}, hub=hub,
                         identity=dict(session_id='sid', owner='42', cwd='/tmp/dirty,work#tree'))

    def tearDown(self):
        # This socket was created by this test and contains no fleet sessions.
        self.tmux('kill-server')
        self.directory.cleanup()

    def test_repeat_and_partial_preserve_extra_identity(self):
        with patch.object(recovery, 'binding', return_value=self.row):
            existing = dict(self.plan['identity'], transcript='/private/path,#{}', model='model')
            self.tmux('set-option', '-w', '-t', self.pane, '@codex_identity', json.dumps(existing))
            recovery.register(self.plan, self.plan['hub'])
            before = self.tmux('show-options', '-w', '-t', self.pane)
            recovery.register(self.plan, self.plan['hub'])
            self.assertEqual(before, self.tmux('show-options', '-w', '-t', self.pane))
            self.assertEqual(existing, json.loads(recovery.launch.option(self.pane, '@codex_identity', self.socket)))

    def test_late_replacement_is_not_overwritten(self):
        original_tmux = recovery.launch.tmux
        original_matches = recovery.local_matches
        for changed in ('@authority_receipt', '@codex_identity', '@codex_session_id'):
            for point in ('after-validation', 'before-submit'):
                with self.subTest(changed=changed, point=point):
                    for key in ('@authority_receipt', '@codex_identity', '@codex_session_id'):
                        self.tmux('set-option', '-wu', '-t', self.pane, key)
                    def replace():
                        original_tmux('set-option', '-w', '-t', self.pane, changed, 'replacement', socket=self.socket)
                    def matching(*args):
                        snapshot = original_matches(*args)
                        if point == 'after-validation': replace()
                        return snapshot
                    def racing(*args, **kwargs):
                        if args[0] == 'if-shell' and point == 'before-submit': replace()
                        return original_tmux(*args, **kwargs)
                    with patch.object(recovery, 'binding', return_value=self.row), patch.object(recovery, 'local_matches', side_effect=matching), patch.object(recovery.launch, 'tmux', side_effect=racing):
                        with self.assertRaises(ValueError): recovery.register(self.plan, self.plan['hub'])
                    for key in ('@authority_receipt', '@codex_identity', '@codex_session_id'):
                        self.assertEqual('replacement' if key == changed else '', recovery.launch.option(self.pane, key, self.socket))

    def test_each_partial_prefix_recovers(self):
        with patch.object(recovery, 'binding', return_value=self.row):
            recovery.register(self.plan, self.plan['hub'])
            keys = ('@authority_receipt', '@codex_identity', '@codex_session_id')
            expected = {key: recovery.launch.option(self.pane, key, self.socket) for key in keys}
            for prefix in range(3):
                for key in keys[prefix:]: self.tmux('set-option', '-wu', '-t', self.pane, key)
                recovery.register(self.plan, self.plan['hub'])
                self.assertEqual(expected, {key: recovery.launch.option(self.pane, key, self.socket) for key in keys})


class ProxyProof(unittest.TestCase):
    def test_central_inspection_uses_held_pass_without_renewing_or_saving(self):
        proxy = runpy.run_path(str(Path(__file__).with_name('fleet-cred-proxy.py')))
        claims = base64.urlsafe_b64encode(json.dumps({'id': 'original', 'exp': 1}).encode()).decode().rstrip('=')
        original = 'fcp-h1.' + claims + '.fixture-signature'
        effective = original + '-renewed'
        with tempfile.TemporaryDirectory() as directory:
            passes = proxy['HubPasses'](directory)
            passes.held['original'] = effective
            passes.save()
            passes.best = passes.renew = passes.save = Mock(side_effect=AssertionError('inspection must be read-only'))
            tenant = SimpleNamespace(cfg=SimpleNamespace(bound_port=12345), passes=passes)
            req = dict(version=1, provider='codex', cred=original,
                       expected=dict(hub_id='original', worker_id='fleet/worker'))
            scope = dict(id='original', principal='alice', worker_id='fleet/worker', machine='fixture',
                         endpoint_id='original-node', provider='codex', binding=None, secret='must-not-return')
            def open_request(request, **kwargs):
                self.assertEqual(request.full_url, 'http://127.0.0.1:1234/v1/fleet/session-cred/inspect')
                self.assertEqual(request.get_header('Authorization'), 'Bearer fixture-node')
                self.assertEqual(json.loads(request.data), dict(original=original, effective=effective,
                                                               worker_id='fleet/worker', provider='codex'))
                return io.BytesIO(json.dumps(scope).encode())
            before = {p.name: p.read_bytes() for p in Path(directory).iterdir()}
            fn = proxy['credential_inspect']
            with patch.dict(os.environ, FLEET_HUB_URL='http://foreign.invalid'), patch.dict(fn.__globals__,
                    node_env=lambda _: dict(CCQUOTA_HUB_URL='http://127.0.0.1:1234', CCQUOTA_TOKEN='fixture-node')):
                with patch.object(fn.__globals__['urllib'].request, 'urlopen', side_effect=open_request):
                    result = fn(req, tenant)
                    self.assertTrue(result.get('ok'), result)
                    self.assertNotIn('secret', result['scope'])
                    self.assertNotIn(original, str(result))
                with patch.dict(fn.__globals__, node_env=lambda _: dict(CCQUOTA_TOKEN='fixture-node')):
                    self.assertFalse(fn(req, tenant).get('ok'))
            passes.best.assert_not_called()
            self.assertEqual(before, {p.name: p.read_bytes() for p in Path(directory).iterdir()})
            self.assertEqual(passes.held, {'original': effective})

    def test_provider_overrides_fail_closed_before_credential_inspection(self):
        base = ['codex', '-c', 'model_provider="fleet"', '-c',
                'model_providers.fleet={name="fixture",base_url="http://127.0.0.1:12345/codex",'
                'env_key="FLEET_CODEX_SESSION_CRED",wire_api="responses"}']
        for override in ('model_providers.fleet.base_url="http://127.0.0.1:54321/codex"',
                         'model_providers.fleet.env_key="OTHER_KEY"',
                         'model_providers={fleet={env_key="OTHER_KEY"}}',
                         'model_providers."fleet".env_key="OTHER_KEY"',
                         '"model_providers".fleet.env_key="OTHER_KEY"',
                         'model_providers . fleet . env_key = "OTHER_KEY"'):
            for flag in (['-c', override], ['--config=' + override], ['-c' + override]):
                with self.subTest(flag=flag), patch.object(recovery, 'process_scope') as scope:
                    with self.assertRaisesRegex(recovery.Refusal, 'unsupported native override'):
                        recovery.proxy_account({}, 42, {}, base + flag + ['app-server', '--listen', 'unix:///fixture'],
                                               {'modelProvider': 'fleet'})
                    scope.assert_not_called()

    def test_original_credential_scope_no_writes(self):
        proxy = runpy.run_path(str(Path(__file__).with_name('fleet-cred-proxy.py')))
        with tempfile.TemporaryDirectory() as directory:
            keys = proxy['Keys'](directory)
            token = keys.mint('original', 'session', 3600, lg='alice')
            write = proxy['write_json']
            write(directory + '/workers.json', {'session': 'fleet/worker'})
            write(directory + '/live.json', {'session': os.getpid()})
            tenant = SimpleNamespace(cfg=SimpleNamespace(state=directory, bound_port=12345), name='alice', keys=keys)
            req = dict(op='credential-inspect', version=1, provider='codex', cred=token,
                       expected=dict(sid='session', worker_id='fleet/worker', wrap_pid=os.getpid(), account='original'))
            before = {p.name: p.read_bytes() for p in Path(directory).iterdir()}
            fn = proxy['ctl_handle']
            with patch.dict(fn.__globals__, codex_target_auth=lambda *args: dict(verdict='ok')):
                out = fn(req, tenant)
                self.assertTrue(out.get('ok'), out)
                self.assertEqual(out['scope']['worker_id'], 'fleet/worker')
                self.assertNotIn(token, str(out))
                for key in req['expected']:
                    bad = copy.deepcopy(req)
                    bad['expected'][key] = 'foreign'
                    self.assertFalse(fn(bad, tenant).get('ok'), key)
                self.assertFalse(fn(dict(req, cred=token + 'bad'), tenant).get('ok'))
                write(directory + '/bind.json', {'session': 'replacement'})
                self.assertFalse(fn(req, tenant).get('ok'))
                Path(directory + '/bind.json').unlink()
            self.assertEqual(before, {p.name: p.read_bytes() for p in Path(directory).iterdir()})


if __name__ == "__main__":
    unittest.main()
