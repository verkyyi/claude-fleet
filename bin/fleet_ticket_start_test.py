#!/usr/bin/env python3
"""Real wrapper/rollback recipe, isolated tmux and HTTP authority; fake native."""
import http.server
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse

BIN = Path(__file__).resolve().parent


@unittest.skipUnless(shutil.which('tmux'), 'tmux is required')
class CredentialStartTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='credential-start-', dir='/tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.socket = self.root / 'fixture'
        self.conf = self.root / 'conf'
        fleet = self.conf / 'fleets/fixture'
        fleet.mkdir(parents=True)
        (fleet / 'identity').write_text('11111111-1111-4111-8111-111111111111\n')
        (fleet / 'conf').write_text('FLEET_REPO="org/a"\n')
        self.install = self.root / 'bin'
        self.install.mkdir()
        for name in ('fleet-session-wrap.sh', 'fleet-lib.sh', 'usage-lib.sh', 'fleet-lang.sh',
                     'fleet_repo_authority.py', 'fleet_ticket.py', 'fleet_launch.py'):
            shutil.copy2(BIN / name, self.install / name)
        self.requests = []
        self.reads = []
        self.order = []
        self.reservation = None
        self.status = 200
        owner = self

        class Authority(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
                owner.reads.append((self.path, self.headers.get('Authorization'), query))
                owner.order.append('read')
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps(dict(repo='org/a', reservation=owner.reservation,
                    owner='fixture-owner', endpoint_id='fixture-node', phase='reserved')).encode())

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                owner.requests.append((self.path, self.headers.get('Authorization'), body))
                owner.order.append(body['action'])
                if body['action'] == 'reserve':
                    owner.reservation = body['reservation']
                self.send_response(owner.status)
                self.end_headers()
                response = dict(repo='org/a', reservation=owner.reservation,
                    owner='fixture-owner', endpoint_id='fixture-node',
                    phase=dict(begin='starting', unobserved='abandoned').get(body['action'], 'reserved'))
                if body['action'] in ('begin', 'unobserved'):
                    response['worker_id'] = body['worker_id']
                self.wfile.write(json.dumps(response if owner.status == 200 else
                                           {'error': 'fixture refusal'}).encode())

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Authority)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.endpoint = 'http://127.0.0.1:' + str(self.server.server_port)
        (self.conf / 'node.env').write_text('CCQUOTA_HUB_URL=' + self.endpoint + '\nCCQUOTA_TOKEN=fixture-node\n')
        self.env = dict(HOME=str(self.root), PATH=os.environ['PATH'], TMPDIR=str(self.root),
                        FLEET_CONF_DIR=str(self.conf), FLEET_SKIP_GLOBAL_CONF='1', CCQUOTA_FLEET='1',
                        FLEET_WRAP_FAST_FAIL='30', CCQUOTA_HUB_URL='http://127.0.0.1:1/wrong-entry')
        self.native_record = self.root / 'native.json'
        native = self.root / 'fixture-native'
        native.write_text('#!' + sys.executable + '\n' + '''import json, os, pathlib, sys
pathlib.Path(os.environ['NATIVE_RECORD']).write_text(json.dumps(dict(
    argv=sys.argv[1:], cwd=os.getcwd(), pid=os.getpid(), executable=sys.executable,
    context=json.loads(os.environ['FLEET_AUTHORITY_CONTEXT']))))
sys.exit(37)
''')
        native.chmod(0o755)
        self.env.update(FLEET_WRAP_LAUNCH=str(native), NATIVE_RECORD=str(self.native_record))
        self.addCleanup(lambda: subprocess.run(['tmux', '-S', str(self.socket), 'kill-server'],
                                              env=self.env, capture_output=True))
        self.pane = self.tm('-f', '/dev/null', 'new-session', '-d', '-P', '-F', '#{pane_id}',
                            '-s', 'fixture', 'sleep 60')
        for key, value in (('@repo', 'org/a'), ('@fleet_id', 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'),
                           ('remain-on-exit', 'on')):
            self.tm('set-option', '-w', '-t', self.pane, key, value)
        self.main = self.root / 'repo'
        self.worktree = self.root / 'issue-1'
        self.run_command('git', 'init', '-q', str(self.main))
        self.run_command('git', '-C', str(self.main), '-c', 'user.name=Fixture', '-c', 'user.email=f@example.invalid',
                         '-c', 'commit.gpgsign=false', 'commit', '-q', '--allow-empty', '-m', 'fixture')
        self.run_command('git', '-C', str(self.main), 'worktree', 'add', '-qb', 'issue-1', str(self.worktree))
        (self.worktree / 'uncommitted').write_text('preserved work\n')

    def run_command(self, *args):
        result = subprocess.run(args, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def tm(self, *args):
        return self.run_command('tmux', '-S', str(self.socket), *args)

    def launch(self, argv, directory=None):
        # respawn inherits the isolated tmux server's URL-only environment, as
        # the real same-pane recovery does; no parent-shell env-unset shortcut.
        self.tm('respawn-pane', '-k', '-t', self.pane, '-c', str(directory or self.worktree), shlex.join(argv))
        end = time.monotonic() + 12
        while time.monotonic() < end:
            if self.tm('display-message', '-p', '-t', self.pane, '#{pane_dead}') == '1':
                return
            time.sleep(.05)
        self.fail('wrapper did not finish: ' + self.tm('capture-pane', '-p', '-t', self.pane))

    def assert_admitted(self, expected):
        self.assertTrue(self.native_record.exists(), self.tm('capture-pane', '-p', '-S', '-', '-t', self.pane))
        record = json.loads(self.native_record.read_text())
        self.assertEqual(record['argv'], expected)
        self.assertEqual(record['cwd'], str(self.worktree))
        self.assertEqual(record['context']['worker_id'],
                         '11111111-1111-4111-8111-111111111111/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee')
        # The fixture native exits with no receipt: the start is closed on the
        # hub as never observed (issue #4792), same reservation, same worker.
        self.assertEqual([r[2]['action'] for r in self.requests], ['reserve', 'begin', 'unobserved'])
        self.assertEqual(self.requests[2][2]['reservation'], self.requests[1][2]['reservation'])
        self.assertEqual(self.requests[2][2]['worker_id'], self.requests[1][2]['worker_id'])
        self.assertEqual(self.order, ['reserve', 'read', 'begin', 'unobserved'])
        self.assertEqual(len(self.reads), 1)
        self.assertEqual(self.reads[0][1:], ('Bearer fixture-node',
                         {'repo': ['org/a'], 'reservation': [self.reservation]}))
        self.assertEqual(self.requests[0][2]['reservation'], self.requests[1][2]['reservation'])
        self.assertTrue(all(r[0].startswith('/v1/fleet/tickets/authority/start?repo=org%2Fa') and
                            r[1] == 'Bearer fixture-node' for r in self.requests))
        # A fake native has no hook receipt: admission may succeed, but uncertainty
        # must NOT turn into a fabricated stopped/observe report.
        self.assertIn('execution retained', self.tm('capture-pane', '-p', '-S', '-', '-t', self.pane))
        self.assertEqual((self.worktree / 'uncommitted').read_text(), 'preserved work\n')

    def test_legacy_wrapper_start_from_url_only_tmux(self):
        args = ['--agent', 'codex', 'fixture task']
        self.launch([str(self.install / 'fleet-session-wrap.sh'), *args])
        self.assert_admitted(args)

    def test_bound_resume_launches_from_saved_worktree_not_wrapper_cwd(self):
        self.tm('set-option', '-w', '-t', self.pane, '@worktree', str(self.worktree))
        args = ['--agent', 'codex', 'resume', 'fixture-session']
        self.launch([str(self.install / 'fleet-session-wrap.sh'), *args], directory=self.main)
        self.assert_admitted(args)
        binding = json.loads(self.native_record.read_text())['context']['worktree']
        self.assertEqual(binding['root'], str(self.worktree))
        self.assertEqual(binding['common_dir'], str(self.main / '.git'))

    def test_bound_main_checkout_refuses_without_admission_or_native(self):
        self.tm('set-option', '-w', '-t', self.pane, '@worktree', str(self.main))
        self.launch([str(self.install / 'fleet-session-wrap.sh'), '--agent', 'codex'])
        self.assertFalse(self.native_record.exists())
        self.assertEqual(self.requests, [])

    def test_same_session_source_rollback_from_url_only_tmux(self):
        transcript = self.root / 'source.jsonl'
        transcript.write_text(json.dumps(dict(type='session_meta', payload={'id': 'source'})) + '\n' +
                              json.dumps(dict(type='response_item', payload=dict(type='message', role='user',
                                                                               content='original task'))) + '\n')
        packet = Path(self.run_command(sys.executable, str(BIN / '.fleet-transfer.py'), 'package',
            '--main', str(self.main), '--worktree', str(self.worktree), '--output', str(self.root / 'packets'),
            '--sid', 'source', '--pid', str(os.getpid()), '--transcript', str(transcript), '--registry', '',
            '--session', 'fixture', '--window', '@0', '--pane', self.pane,
            '--launcher', str(self.install / 'fleet-session-wrap.sh'), '--handle', 'a1', '--issue', '1',
            '--origin', 'scratch-1', '--repo', 'org/a', '--source-agent', 'codex'))
        self.launch(['bash', str(packet / 'resume-source.sh'), '--run-source'])
        self.assert_admitted(['--agent', 'codex', '--codex-home', '', 'resume', 'source'])
        self.assertEqual((packet / 'source.jsonl').read_bytes(), transcript.read_bytes())
        self.assertEqual(json.loads((packet / 'manifest.json').read_text())['source']['session_id'], 'source')

    def test_explicit_invalid_pair_refuses_before_native(self):
        self.status = 401
        self.tm('set-environment', '-g', 'CCQUOTA_HUB_URL', self.endpoint)
        self.tm('set-environment', '-g', 'CCQUOTA_TOKEN', 'fixture-invalid')
        self.launch([str(self.install / 'fleet-session-wrap.sh'), '--agent', 'codex'])
        self.assertFalse(self.native_record.exists())
        self.assertEqual(len(self.requests), 1)
        self.assertEqual(self.requests[0][1], 'Bearer fixture-invalid')
        self.assertEqual(self.requests[0][2]['action'], 'reserve')


if __name__ == '__main__':
    unittest.main()
