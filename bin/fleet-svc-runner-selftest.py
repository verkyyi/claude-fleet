#!/usr/bin/env python3
"""Codex runner contract, using a fake CLI and no model requests."""
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('runner', pathlib.Path(__file__).with_name('fleet-svc-runner.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('codex'), 'native Codex sandbox requires macOS and Codex')
    def test_native_read_boundary(self):
        with tempfile.TemporaryDirectory() as root:
            for directory in ('work', 'out', 'home', 'tmp'):
                os.mkdir(root + '/' + directory)
            pathlib.Path(root + '/sibling').write_text('private sibling')
            pathlib.Path(root + '/work/allowed').write_text('allowed')
            codex = shutil.which('codex')
            with patch.dict(os.environ, {'TMPDIR': root + '/tmp'}):
                prefix = runner.codex_boundary(codex, [codex], {'work': root + '/work', 'out': root + '/out'}, root + '/home')[:-1]
            env = runner.session_env()
            env.update(CODEX_HOME=root + '/home', HOME=root + '/home')
            for path, expected in ((root + '/sibling', 1), (root + '/work/allowed', 0)):
                result = subprocess.run(prefix + ['/bin/cat', path], env=env, capture_output=True, timeout=15)
                self.assertEqual(result.returncode, expected, result.stderr.decode())

    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('codex'), 'native Codex sandbox requires macOS and Codex')
    def test_native_search_and_file_tools(self):
        """Real CLI + OS sandbox, fake loopback provider; no subscription call.

        Catches absent search tools AND macOS nested sandbox_apply failures.
        Outside reads/writes and shell credential inheritance must stay denied.
        """
        import http.server
        import threading
        requests, tool_results = [], []
        command = ('printf "# fixture" > ../out/report.md; '
                   'printf \'{"title":"fixture","summary":"ok"}\' > ../out/meta.json; '
                   'if cat ../sibling; then exit 21; fi; '
                   'if echo forbidden > ../escape; then exit 22; fi; '
                   'test -z "${FLEET_CODEX_SESSION_CRED:-}" && echo BOUNDARY_OK')
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                requests.append((self.path, body))
                if self.path.endswith('/alpha/search'):
                    self.send_response(400); self.end_headers()
                    self.wfile.write(b'offline search fixture reached'); return
                for item in body.get('input', []):
                    if item.get('type') == 'custom_tool_call_output': tool_results.append(item)
                n = sum(path.endswith('/responses') for path, _ in requests)
                if n <= 2:
                    code = ('text(await tools.web__run({search_query:[{q:"fixture news"}],response_length:"short"}));'
                            if n == 1 else 'text(await tools.exec_command({cmd:' + json.dumps(command) + ',login:false}));')
                    items = [dict(type='custom_tool_call', id='ct_fixture'+str(n), call_id='call_fixture'+str(n), name='exec', input=code)]
                else:
                    items = [dict(type='message', id='msg_fixture', role='assistant', status='completed', phase='final_answer',
                                  content=[dict(type='output_text', text='Fixture complete', annotations=[])])]
                response = dict(id='resp_fixture'+str(n), object='response', status='completed', output=items,
                                usage=dict(input_tokens=10, output_tokens=2, total_tokens=12))
                events = [dict(type='response.created', response=dict(id=response['id'], object='response', status='in_progress', output=[]))]
                for i, item in enumerate(items):
                    events.extend([dict(type='response.output_item.added', output_index=i, item=item),
                                   dict(type='response.output_item.done', output_index=i, item=item)])
                events.append(dict(type='response.completed', response=response))
                data = ''.join('event: '+e['type']+'\ndata: '+json.dumps(e)+'\n\n' for e in events).encode()
                self.send_response(200); self.send_header('Content-Type','text/event-stream')
                self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever); thread.start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                for name in ('home','work','out','tmp'): (root/name).mkdir()
                (root/'sibling').write_text('PRIVATE_FIXTURE')
                (root/'work/agent.md').write_text('Offline native tool fixture only.')
                env = dict(HOME=str(root/'home'), TMPDIR=str(root/'tmp'), PATH=os.environ['PATH'],
                           FLEET_SVC_CODEX=shutil.which('codex'), FLEET_SVC_CENTRAL='http://127.0.0.1:%d'%server.server_port)
                with patch.dict(os.environ, env, clear=True), patch.object(runner,'hand_in',return_value=True), patch.object(runner,'RUN_SPEC',{}):
                    code = runner.run_codex(dict(work=str(root/'work'),out=str(root/'out'),agent=str(root/'work/agent.md')),
                                            dict(request='offline fixture'),'fake-fixture-pass',75,runner.time.time())
                self.assertEqual(code, runner.OK, json.dumps(tool_results))
                self.assertFalse((root/'escape').exists())
                self.assertEqual((root/'out/report.md').read_text(), '# fixture')
                results = json.dumps(tool_results)
                self.assertIn('BOUNDARY_OK', results)
                self.assertNotIn('PRIVATE_FIXTURE', results)
                self.assertNotIn('fake-fixture-pass', results)
                search = [body for path,body in requests if path.endswith('/alpha/search')]
                self.assertEqual(len(search), 1)
                self.assertTrue(search[0]['settings']['external_web_access'])
                self.assertEqual(search[0]['commands']['search_query'], [dict(q='fixture news')])
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=3)

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
                self.assertEqual(cmd[:4], ['/fake/codex', 'sandbox', '-P', 'service'])
                inner = cmd[cmd.index('--') + 1:]
                self.assertEqual(inner[:7], ['/fake/codex', '--search', 'exec', '--json', '--ephemeral', '-s', 'danger-full-access'])
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
