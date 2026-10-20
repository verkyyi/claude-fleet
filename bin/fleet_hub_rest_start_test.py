#!/usr/bin/env python3
"""Real wrapper/rollback recipe, isolated tmux and HTTP authority; fake native.

EPIC T497 C8: a window's start is admitted by its ID — the wrapper asks the hub
nothing, and a window stamped by the retired launch proof (or a pre-C8 wrapper
still calling fleet_launch.py supervise) reopens as itself."""
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
        for name in ('fleet-session-wrap.sh', 'fleet-lib.sh', 'fleet-client-core.sh', 'usage-lib.sh', 'fleet-lang.sh',
                     'fleet_repo_authority.py', 'fleet_hub_rest.py', 'fleet_launch.py', 'fleet_native_proc.py'):
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
    env={k: v for k, v in os.environ.items() if k.startswith(('FLEET_LAUNCH', 'FLEET_AUTHORITY'))})))
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

    def assert_started(self, expected):
        self.assertTrue(self.native_record.exists(), self.tm('capture-pane', '-p', '-S', '-', '-t', self.pane))
        record = json.loads(self.native_record.read_text())
        self.assertEqual(record['argv'], expected)
        self.assertEqual(record['cwd'], str(self.worktree))
        # No reservation, no claim, no observation: the hub is not asked, and no
        # retired layer's environment reaches the agent.
        self.assertEqual((self.requests, self.reads), ([], []))
        self.assertEqual(record['env'], {})
        self.assertEqual(self.tm('display-message', '-p', '-t', self.pane, '#{@fleet_id}'),
                         'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee')
        self.assertEqual((self.worktree / 'uncommitted').read_text(), 'preserved work\n')

    def stamp_pre_c8_launch(self):
        # A window a launch proof stamped before C8 (T505's @1156, the T497
        # driver's @1052): @launch and its receipt, its task.
        launch = dict(version=1, task='T505', worker_id='11111111-1111-4111-8111-111111111111/'
                      'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', provider='codex')
        for key, value in (('@launch', json.dumps(launch)), ('@launch_receipt', json.dumps(dict(launch, pid=1))),
                           ('@launch_started', '1'), ('@launch_error', 'old'), ('@task', 'T505')):
            self.tm('set-option', '-w', '-t', self.pane, key, value)

    def assert_launch_retired(self):
        for key in ('@launch', '@launch_receipt', '@launch_started', '@launch_error'):
            self.assertEqual(self.tm('display-message', '-p', '-t', self.pane, '#{%s}' % key), '', key)
        self.assertEqual(self.tm('display-message', '-p', '-t', self.pane, '#{@task}'), 'T505')

    def test_wrapper_start_asks_the_hub_nothing(self):
        args = ['--agent', 'codex', 'fixture task']
        self.launch([str(self.install / 'fleet-session-wrap.sh'), *args])
        self.assert_started(args)

    def test_pre_c8_launch_window_reopens_as_itself(self):
        # A version-stale reopen of a window an old launch supervisor ran: the
        # same window, the same ID, its conversation resumed — not refused, not new.
        self.stamp_pre_c8_launch()
        args = ['--agent', 'codex', 'resume', 'fixture-session']
        self.launch(['env', 'FLEET_LAUNCH_CONTEXT={"version":1}', 'FLEET_LAUNCH_SUPERVISOR=1',
                     'FLEET_AUTHORITY_CONTEXT={}', str(self.install / 'fleet-session-wrap.sh'), *args])
        self.assert_started(args)
        self.assert_launch_retired()

    def test_an_older_wrapper_through_the_retired_supervisor(self):
        # A session still running a pre-C8 fleet-session-wrap.sh calls
        # `fleet_launch.py supervise -- <launcher> …` for its @launch window.
        self.stamp_pre_c8_launch()
        args = ['--agent', 'codex', 'resume', 'fixture-session']
        self.launch([sys.executable, str(self.install / 'fleet_launch.py'), 'supervise', '--',
                     str(self.root / 'fixture-native'), *args])
        self.assert_started(args)
        self.assert_launch_retired()

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
        self.assert_started(['--agent', 'codex', '--codex-home', '', 'resume', 'source'])
        self.assertEqual((packet / 'source.jsonl').read_bytes(), transcript.read_bytes())
        self.assertEqual(json.loads((packet / 'manifest.json').read_text())['source']['session_id'], 'source')


if __name__ == '__main__':
    unittest.main()
