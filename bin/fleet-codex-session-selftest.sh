#!/bin/bash
# Exact Codex identity/telemetry and queue routing; private tmux, fixture rollouts,
# fake codex only. No model requests, operator files or live fleet sockets.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
python3 - "$BIN" <<'PY'
import importlib.util, json, os, pathlib, shutil, subprocess, sys, tempfile, unittest

BIN = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('codex_session', BIN / 'fleet-codex-session.py')
cx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cx)
SID = '11111111-1111-4111-8111-111111111111'
OTHER = '22222222-2222-4222-8222-222222222222'

class SessionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fleet-codex-session-')
        self.root = pathlib.Path(self.tmp.name)
        self.home = self.root / 'a home'
        self.path = self.home / 'sessions/2026/09/17' / ('rollout-' + SID + '.jsonl')
        self.path.parent.mkdir(parents=True)
        self.data = dict(session_id=SID, home=str(self.home), owner='1234', model='fixture-model')
        self.records = [dict(type='session_meta', payload=dict(id=SID, cwd=str(self.root))),
                        dict(type='turn_context', payload=dict(model='gpt-fixture')),
                        dict(type='event_msg', payload=dict(type='token_count', info=dict(
                            model_context_window=300000,
                            last_token_usage=dict(input_tokens=100000, cached_input_tokens=90000, output_tokens=20000, total_tokens=120000),
                            total_token_usage=dict(output_tokens=40000))))]
        self.write()

    def tearDown(self):
        self.tmp.cleanup()

    def write(self):
        self.path.write_text(''.join(json.dumps(r) + '\n' for r in self.records))

    def test_exact_id_and_cache_tokens(self):
        wrong = self.path.with_name('rollout-' + OTHER + '.jsonl')
        wrong.write_text(json.dumps(dict(type='session_meta', payload=dict(id=OTHER))) + '\n')
        got = cx.telemetry(self.data)
        self.assertEqual((got['pct'], got['live_tokens'], got['limit']), (40, 120000, 300000))
        self.assertEqual(got['model'], 'gpt-fixture')
        self.assertEqual(got['output_tokens'], 40000)
        self.assertEqual(got['transcript'], str(self.path))

    def test_wrong_hint_does_not_override_identity(self):
        wrong = self.root / 'wrong.jsonl'
        wrong.write_text(json.dumps(dict(type='session_meta', payload=dict(id=OTHER))) + '\n')
        self.data['transcript'] = str(wrong)
        self.assertEqual(cx.telemetry(self.data)['transcript'], str(self.path))
        self.data['session_id'] = OTHER
        self.data['transcript'] = str(self.path)
        self.assertEqual(cx.telemetry(self.data)['pct'], -1)

    def test_missing_and_malformed_are_unknown(self):
        self.data['home'] = str(self.root / 'another-account')
        self.assertEqual(cx.telemetry(self.data)['pct'], -1)
        self.data['session_id'] = '../*'
        self.assertEqual(cx.telemetry(self.data)['pct'], -1)
        self.assertEqual(cx.telemetry({})['pct'], -1)
        self.records[-1]['payload']['info']['model_context_window'] = None
        self.write()
        self.assertEqual(cx.telemetry(dict(session_id=SID, home=str(self.home)))['pct'], -1)

    def test_compaction_and_torn_append(self):
        newer = json.loads(json.dumps(self.records[-1]))
        newer['payload']['info']['last_token_usage']['total_tokens'] = 15000
        self.records.append(newer)
        self.write()
        with self.path.open('a') as f: f.write('{"type":')
        self.assertEqual(cx.telemetry(self.data)['pct'], 5)

    def test_context_cli_provider_never_reads_claude(self):
        env = dict(os.environ, CODEX_HOME=str(self.home))
        env.pop('TMUX', None); env.pop('TMUX_PANE', None)
        p = subprocess.run(['bash', str(BIN / 'fleet-context.sh'), '--agent', 'codex', '--session', SID, '--json'], env=env, capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout)['pct'], 40)
        p = subprocess.run(['bash', str(BIN / 'fleet-context.sh'), '--agent', 'codex', '--session', OTHER, '--json'], env=env, capture_output=True, text=True)
        self.assertEqual(p.returncode, 1, p.stderr)
        self.assertEqual(json.loads(p.stdout)['verdict'], 'UNKNOWN')

    @unittest.skipUnless(shutil.which('tmux'), 'tmux unavailable')
    def test_hooks_cache_queue_and_parent_end_to_end(self):
        label = 'codex-session-test-' + str(os.getpid())
        tm = ['tmux', '-L', label]
        def call(*args):
            return subprocess.check_output(tm + list(args), text=True).strip()
        try:
            call('new-session', '-d', '-s', 'fixture', '-n', 'parent', 'sleep 60')
            pane = call('display-message', '-p', '#{pane_id}')
            win = call('display-message', '-p', '#{window_id}')
            socket = call('display-message', '-p', '#{socket_path}')
            env = dict(os.environ, TMUX=socket + ',1,0', TMUX_PANE=pane, CODEX_HOME=str(self.home),
                       FLEET_CODEX_LAUNCHER_PID='1234', FLEET_CODEX_REMOTE='unix:///private/worker.sock')
            for name, value in (('@cc_agent', 'codex'), ('@cc_launcher_pid', '1234'), ('@issue', '42')):
                call('set-option', '-w', '-t', pane, name, value)
            def hook(sid=SID, owner='1234', event='SessionStart'):
                p = subprocess.run([sys.executable, str(BIN / 'fleet-codex-session.py'), 'hook'],
                    env=dict(env, FLEET_CODEX_LAUNCHER_PID=owner), input=json.dumps(dict(session_id=sid,
                    hook_event_name=event, transcript_path=str(self.path), cwd=str(self.root))), text=True, capture_output=True)
                self.assertEqual(p.returncode, 0, p.stderr)
            hook()
            data = json.loads(call('show-options', '-wv', '-t', pane, '@codex_identity'))
            self.assertEqual(data['session_id'], SID)
            self.assertEqual(data['home'], str(self.home.resolve()))
            self.assertEqual(call('show-options', '-wv', '-t', pane, '@ctx_pct'), '40')
            hook(OTHER, owner='999')
            hook(OTHER, event='Stop')
            self.assertEqual(json.loads(call('show-options', '-wv', '-t', pane, '@codex_identity'))['session_id'], SID)
            cache = self.root / '.claude-dash/global'; cache.mkdir(parents=True)
            row = '|'.join(['fixture', win, 'codex', '1234', json.dumps(data)]) + '\n'
            p = subprocess.run([sys.executable, str(BIN / 'fleet-codex-session.py'), 'collect', '--cache', str(cache)], input=row, text=True)
            self.assertEqual(p.returncode, 0)
            self.assertEqual(next(cache.glob('ctx_*')).read_text().strip(), 'gpt-fixture\t120000\t300000')
            # The real row producer must use Codex's 300k denominator, and stop
            # reading this cache the instant the pane switches root sessions.
            rows_env = dict(env, TMPDIR=str(self.root), FLEET_SESSION='fixture')
            def rows():
                return subprocess.check_output(['bash', str(BIN / 'tmux-dashboard-rows.sh')], env=rows_env, text=True)
            self.assertIn('40%', rows())
            call('set-option', '-w', '-t', pane, '@codex_session_id', OTHER)
            self.assertNotIn('40%', rows())
            call('set-option', '-w', '-t', pane, '@codex_session_id', SID)
            fakebin = self.root / 'bin'; fakebin.mkdir()
            fake = fakebin / 'codex'
            fake.write_text('#!' + sys.executable + '\nimport sys,os,json\njson.dump([sys.argv[1:],os.environ["CODEX_HOME"]],open(os.environ["QUEUE_LOG"],"w"))\nsys.exit(int(os.environ.get("QUEUE_FAIL","0")))\n')
            fake.chmod(0o755)
            env.update(PATH=str(fakebin) + ':' + os.environ['PATH'], QUEUE_LOG=str(self.root / 'queue.json'))
            def send():
                return subprocess.run(['bash', str(BIN / 'fleet-peer-send.sh'), '-L', label, pane, 'hello\npeer'], env=env, capture_output=True, text=True)
            p = send(); self.assertEqual(p.returncode, 0, p.stderr)
            argv, home = json.loads((self.root / 'queue.json').read_text())
            self.assertEqual(argv, ['queue', '--remote', 'unix:///private/worker.sock', '--thread', SID, '--message', 'hello\npeer'])
            self.assertEqual(home, str(self.home.resolve()))
            child = call('new-window', '-d', '-P', '-F', '#{window_id}', '-n', 'child', 'sleep 60')
            call('set-option', '-w', '-t', child, '@origin', 'issue-42')
            p = subprocess.run(['bash', str(BIN / 'fleet-report-parent.sh'), '-L', label, '--win', child, '--state', 'merged', '--key', 'issue-43', '--summary', 'done'], env=env, capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(call('show-options', '-wv', '-t', child, '@reported'), '1')
            self.assertIn('[child-report]', json.loads((self.root / 'queue.json').read_text())[0][-1])
            env['QUEUE_FAIL'] = '1'
            self.assertNotEqual(send().returncode, 0)
            env.pop('QUEUE_FAIL')
            data['remote'] = ''
            call('set-option', '-w', '-t', pane, '@codex_identity', json.dumps(data))
            self.assertNotEqual(send().returncode, 0, 'embedded server must not report a false delivery')
            call('set-option', '-w', '-t', pane, '@cc_launcher_pid', '5678')
            self.assertNotEqual(send().returncode, 0, 'stale identity must not deliver')
        finally:
            subprocess.run(tm + ['kill-server'], capture_output=True)

unittest.main(argv=['codex-session'], verbosity=2)
PY
