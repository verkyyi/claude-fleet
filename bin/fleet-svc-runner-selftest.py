#!/usr/bin/env python3
"""Codex runner contract, using a fake CLI and no model requests."""
import importlib.util
import json
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('runner', pathlib.Path(__file__).with_name('fleet-svc-runner.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def test_launcher_credentials_not_inherited(self):
        with patch.dict(os.environ, {'CCQUOTA_TOKEN': 'private', 'FLEET_WORKER_CRED': 'private',
                                     'SERVICE_API_KEY': 'private', 'PATH': '/usr/bin'}, clear=True):
            self.assertEqual(runner.session_env(), {'PATH': '/usr/bin'})

    def test_codex_success_and_credential_boundary(self):
        with tempfile.TemporaryDirectory() as root:
            work, out = root + '/work', root + '/out'
            os.makedirs(work)
            os.makedirs(out)
            agent = work + '/agent.md'
            pathlib.Path(agent).write_text('Write a report')
            pathlib.Path(out + '/report.md').write_text('# report')
            pathlib.Path(out + '/meta.json').write_text('{"title":"report","summary":"ok"}')
            env = {'HOME': root, 'FLEET_SVC_CODEX': '/fake/codex',
                   'FLEET_SVC_CENTRAL': 'https://example.com', 'FLEET_WORKER_CRED': 'private-worker',
                   'OPENAI_API_KEY': 'private-account', 'GITHUB_TOKEN': 'private-github'}
            def execute(cmd, cwd, child_env, timeout):
                self.assertEqual(cmd[:6], ['/fake/codex', '--search', 'exec', '--json', '-s', 'workspace-write'])
                self.assertNotIn('test-session-pass', ' '.join(cmd))
                self.assertEqual(child_env['FLEET_CODEX_SESSION_CRED'], 'test-session-pass')
                self.assertNotIn('FLEET_WORKER_CRED', child_env)
                self.assertNotIn('OPENAI_API_KEY', child_env)
                self.assertNotIn('GITHUB_TOKEN', child_env)
                self.assertFalse(os.path.exists(child_env['CODEX_HOME'] + '/auth.json'))
                self.assertLessEqual(timeout, 400)
                return subprocess.CompletedProcess(cmd, 0, '{"type":"turn.completed","usage":{"input_tokens":4,"output_tokens":5}}', '')
            with patch.dict(os.environ, env, clear=True), patch.object(runner, 'session_run', execute), \
                    patch.object(runner, 'hand_in', return_value=True) as hand, \
                    patch.object(runner, 'RUN_SPEC', {'attempt_timeout_s': 400}):
                result = runner.run_codex({'work':work,'out':out,'agent':agent}, {}, 'test-session-pass', 900, runner.time.time())
            self.assertEqual(result, 0)
            usage = hand.call_args.args[3]
            self.assertEqual(usage['engine'], 'codex')
            self.assertEqual(usage['output_tokens'], 5)
            for path in pathlib.Path(root).rglob('*'):
                if path.is_file(): self.assertNotIn(b'test-session-pass', path.read_bytes())

    def test_redaction(self):
        text = runner.redact('fcp-h2.secret fsj_aaaa fcs_bbbb known-token', 'known-token')
        for secret in ('secret', 'aaaa', 'bbbb', 'known-token'):
            self.assertNotIn(secret, text)

    def test_memory_output_bounded(self):
        cp = runner.session_run(['/usr/bin/python3', '-c', 'print("x" * 3000000)'], '/', {}, 10)
        self.assertEqual(cp.returncode, 0)
        self.assertLessEqual(len(cp.stdout), 2 * runner.REPORT_MAX)

    def test_fetch_keeps_pass_in_memory(self):
        with tempfile.TemporaryDirectory() as root:
            with patch.dict(os.environ, {'FLEET_SVC_WORK':root, 'FLEET_SVC_PASS_DIR':root + '/pass'}, clear=True), \
                    patch.object(runner, 'hub', return_value=(200, {'agent_md':'template','pass':'test-session-pass'})), \
                    patch.object(runner, 'RUN_SPEC', {}):
                self.assertEqual(runner.fetch(memory=True), 0)
                self.assertEqual(runner.RUN_SPEC['pass'], 'test-session-pass')
                self.assertFalse(pathlib.Path(root + '/pass').exists())

    def test_legacy_split_entry_preserves_engine(self):
        with tempfile.TemporaryDirectory() as root:
            with patch.dict(os.environ, {'FLEET_SVC_WORK': root, 'FLEET_SVC_PASS_DIR': root + '/pass'}, clear=True), \
                    patch.object(runner, 'hub', return_value=(200, {'agent_md': 'template', 'pass': 'test-session-pass',
                                                                  'engine': 'codex', 'attempt_timeout_s': 300})), \
                    patch.object(runner, 'RUN_SPEC', {}), patch.object(runner, 'run_codex', return_value=0) as codex:
                self.assertEqual(runner.fetch(), 0)
                metadata = pathlib.Path(root + '/.fleet-svc-spec.json').read_text()
                self.assertNotIn('test-session-pass', metadata)
                self.assertEqual(runner.run(), 0)
                self.assertTrue(codex.called)
                self.assertEqual(runner.RUN_SPEC['attempt_timeout_s'], 300)


if __name__ == '__main__':
    unittest.main()
