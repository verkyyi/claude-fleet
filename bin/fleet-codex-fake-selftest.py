#!/usr/bin/env python3
# The one fake Codex (fleet_codex_fake_appserver.py, T585) against the real one: every
# answer it gives has the shape recorded from `codex app-server` 0.162.1
# (fleet-codex-fake-samples.json), over its socket through fleet-codex-rpc.py's own
# Client, in process, on stdio and as the `codex` binary; and each scripted scenario
# (delay, drop, /clear, errors, exit codes) does what its header says.
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

BIN = Path(__file__).absolute().parent
sys.path.insert(0, str(BIN))
import fleet_codex_fake_appserver as fake  # noqa: E402

Client = runpy.run_path(str(BIN / 'fleet-codex-rpc.py'))['Client']
SAMPLES = json.loads((BIN / 'fleet-codex-fake-samples.json').read_text())
RELEASE = json.loads((BIN.parent / 'release.json').read_text())


def shape(value):
    """Keys, recursively (a list by its first item); leaves by JSON type."""
    if isinstance(value, dict):
        return {k: shape(v) for k, v in value.items()}
    if isinstance(value, list):
        return [shape(value[0])] if value else []
    return type(value).__name__ if value is not None else None


def same_shape(test, got, want, where):
    """Every key the real server sends is there, and nothing it does not send."""
    def walk(g, w, path):
        if isinstance(w, dict):
            test.assertIsInstance(g, dict, path)
            test.assertEqual(sorted(g), sorted(w), path)
            for k in w:
                walk(g[k], w[k], path + '.' + k)
        elif isinstance(w, list) and w and isinstance(g, list) and g:
            walk(g[0], w[0], path + '[0]')
    walk(shape(got), shape(want), where)


class Shapes(unittest.TestCase):
    """Over the socket, with the fleet's real RPC client: the recorded 0.162.1 shapes."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='fake-codex-', dir='/tmp')
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.server = fake.FakeAppServer(self.tmp + '/s.sock')
        self.addCleanup(self.server.close)
        self.client = Client(self.server.remote, timeout=3)
        self.addCleanup(self.client.close)

    def test_pinned_version_is_the_release_one(self):
        self.assertEqual(fake.VERSION, RELEASE['components']['codex']['version'])
        self.assertEqual(SAMPLES['version'], fake.VERSION)
        self.assertIn('/%s ' % fake.VERSION, self.client.initialized['userAgent'])
        same_shape(self, self.client.initialized, SAMPLES['initialize'], 'initialize')

    def test_threads_and_their_announcement(self):
        started = self.client.call('thread/start', {'cwd': '/fixture'})
        same_shape(self, started, SAMPLES['thread/start'], 'thread/start')
        note = [e for e in self.client.events if e.get('method') == 'thread/started']
        self.assertEqual(len(note), 1, 'thread/started goes out before the answer')
        same_shape(self, note[0], SAMPLES['thread/started'], 'thread/started')
        tid = started['thread']['id']
        same_shape(self, self.client.call('thread/loaded/list', {}), SAMPLES['thread/loaded/list'], 'loaded/list')
        same_shape(self, self.client.call('thread/read', {'threadId': tid}), SAMPLES['thread/read'], 'thread/read')
        same_shape(self, self.client.call('thread/resume', {'threadId': tid}), SAMPLES['thread/resume'], 'resume')
        fork = self.client.call('thread/fork', {'threadId': tid})
        same_shape(self, fork, SAMPLES['thread/fork'], 'thread/fork')
        self.assertEqual(fork['thread']['forkedFromId'], tid)
        same_shape(self, self.client.call('account/read', {}), SAMPLES['account/read, no account'], 'account/read')

    def test_young_thread_errors_say_what_the_real_one_says(self):
        tid = self.client.call('thread/start', {'cwd': '/fixture'})['thread']['id']
        with self.assertRaisesRegex(ValueError, '^%s$' % SAMPLES['thread/read includeTurns, no turn yet']['message']):
            self.client.call('thread/read', {'threadId': tid, 'includeTurns': True})
        want = SAMPLES['thread/turns/list, no turn yet']['message'].replace('00000000-0000-7000-8000-b7c5d26db2ab', tid)
        with self.assertRaises(ValueError) as e:
            self.client.call('thread/turns/list', {'threadId': tid, 'limit': 5})
        self.assertEqual(str(e.exception), want)
        with self.assertRaisesRegex(ValueError, SAMPLES['account/rateLimits/read, no account']['message']):
            self.client.call('account/rateLimits/read', {})

    def test_queue_and_turns(self):
        tid = self.client.call('thread/start', {'cwd': '/fixture'})['thread']['id']
        same_shape(self, self.client.call('thread/queue/list', {'threadId': tid}), SAMPLES['thread/queue/list'], 'q/list')
        added = self.client.call('thread/queue/add', {'threadId': tid, 'clientUserMessageId': 'x1',
                                                      'input': [{'type': 'text', 'text': 'hi'}]})
        same_shape(self, added, SAMPLES['thread/queue/add'], 'thread/queue/add')
        turn = [e for e in self.client.events if e.get('method') == 'turn/started']
        same_shape(self, turn[0], SAMPLES['turn/started'], 'turn/started')
        self.assertEqual(self.server.delivered, ['x1'])
        rows = self.client.call('thread/turns/list', {'threadId': tid, 'limit': 5})['data']
        self.assertEqual(rows[0]['items'][0]['clientId'], 'x1')

    def test_one_originator_per_process(self):
        other = Client(self.server.remote, timeout=3)
        self.addCleanup(other.close)
        other.call('thread/start', {'cwd': '/fixture'})
        self.server.clear()  # the TUI's /clear: announced the same way, no word of /clear
        for c in (self.client, other):
            c.call('thread/loaded/list', {})
        for e in self.client.events:
            if e.get('method') == 'thread/started':
                self.assertEqual(e['params']['thread']['originator'], 'claude_fleet')
        self.assertEqual(len(self.server.loaded), 2)


class Scenario(unittest.TestCase):
    """The scripted parts, in process and over the socket."""

    def socket(self, script):
        tmp = tempfile.mkdtemp(prefix='fake-codex-', dir='/tmp')
        self.addCleanup(shutil.rmtree, tmp, True)
        server = fake.FakeAppServer(tmp + '/s.sock', script)
        self.addCleanup(server.close)
        return server, Client(server.remote, timeout=2)

    def test_delay_errors_and_fixed_answers(self):
        codex = fake.Codex(delay={'account/read': .3}, errors={'thread/loaded/list': 'fixture says no'},
                           answers={'account/rateLimits/read': {'rateLimits': {'primary': {'usedPercent': 7}}}})
        c = codex.client()
        before = time.monotonic()
        c.call('account/read', {})
        self.assertGreaterEqual(time.monotonic() - before, .3)
        with self.assertRaisesRegex(ValueError, 'fixture says no'):
            c.call('thread/loaded/list', {})
        self.assertEqual(c.call('account/rateLimits/read', {})['rateLimits']['primary']['usedPercent'], 7)

    def test_drop_closes_the_connection(self):
        server, client = self.socket({'drop': ['thread/loaded/list']})
        with self.assertRaises(EOFError):
            client.call('thread/loaded/list', {})
        client.close()

    def test_clear_after_a_turn_is_a_new_thread_without_its_source(self):
        server, client = self.socket({'threads': [{'id': 'T-old', 'cwd': '/w'}], 'clear_after': 1,
                                      'turn_ids': ['first-turn']})
        r = client.call('turn/start', {'threadId': 'T-old', 'input': [{'type': 'text', 'text': 'go'}]})
        self.assertEqual(r['turn']['id'], 'first-turn')
        client.call('thread/loaded/list', {})
        started = [e['params']['thread'] for e in client.events if e.get('method') == 'thread/started']
        self.assertEqual(len(started), 1)
        self.assertNotEqual(started[0]['id'], 'T-old')
        self.assertEqual(server.thread, started[0]['id'])
        self.assertNotIn('clear', json.dumps(started[0]))
        client.close()

    def test_user_turn_holds_the_queue_until_finish(self):
        codex = fake.Codex(threads=[{'id': 'T1'}])
        c = codex.client()
        codex.user_turn()
        c.call('thread/queue/add', {'threadId': 'T1', 'clientUserMessageId': 'm1', 'input': []})
        self.assertEqual((len(codex.queue), codex.delivered), (1, []))
        with self.assertRaisesRegex(ValueError, 'active or pending turn'):
            c.call('turn/start', {'threadId': 'T1', 'input': []})
        codex.finish()
        self.assertEqual((codex.queue, codex.delivered, codex.active), ([], ['m1'], None))

    def test_server_request_replays_on_resume_and_send_resolves(self):
        codex = fake.Codex(threads=[{'id': 'T1'}])
        ask = {'id': 's1', 'method': 'item/tool/requestUserInput', 'params': {'threadId': 'T1'}}
        for replay, where in (('before', 'events'), ('after', 'inbox')):
            codex.server_request(dict(ask), replay=replay)
            c = codex.client()
            c.call('thread/resume', {'threadId': 'T1'})
            self.assertEqual(getattr(c, where)[-1]['id'], 's1')
            if replay == 'after':
                self.assertEqual(c.receive()['id'], 's1')
            c.send({'id': 's1', 'result': {}})
            self.assertEqual(c.receive()['method'], 'serverRequest/resolved')
            self.assertEqual(codex.pending, [])


class Binary(unittest.TestCase):
    """As `codex` on PATH: app-server on a socket or stdio, the TUI client, exit codes."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='fake-codex-', dir='/tmp'))
        self.addCleanup(shutil.rmtree, str(self.root), True)
        self.codex = self.root / 'codex'
        shutil.copyfile(BIN / 'fleet_codex_fake_appserver.py', self.codex)
        self.codex.chmod(0o755)

    def script(self, **s):
        path = self.root / 'scenario.json'
        path.write_text(json.dumps(s))
        return dict(os.environ, FLEET_FAKE_CODEX_SCRIPT=str(path), FAKE_ROOT=str(self.root))

    def test_stdio_app_server(self):
        env = self.script(record='{env:FAKE_ROOT}')
        lines = [{'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name': 'probe'}}},
                 {'id': 2, 'method': 'thread/start', 'params': {'cwd': '/w'}},
                 {'id': 3, 'method': 'account/rateLimits/read', 'params': {}}]
        p = subprocess.run([str(self.codex), 'app-server'], input=''.join(json.dumps(l) + '\n' for l in lines),
                           env=env, capture_output=True, text=True, timeout=10)
        out = [json.loads(l) for l in p.stdout.splitlines()]
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(out[0]['result']['userAgent'].startswith('probe/'))
        started = [m for m in out if m.get('method') == 'thread/started'][0]
        self.assertEqual(started['params']['thread']['originator'], 'probe')
        self.assertLess(out.index(started), out.index([m for m in out if m.get('id') == 2][0]))
        self.assertIn('error', [m for m in out if m.get('id') == 3][0])
        self.assertEqual(json.loads((self.root / 'server.json').read_text())['argv'], ['app-server'])

    def test_socket_server_records_and_dies_with_its_lifetime(self):
        sock = '/tmp/fake-codex-%d.sock' % os.getpid()
        self.addCleanup(lambda: os.path.exists(sock) and os.unlink(sock))
        env = self.script(record='{env:FAKE_ROOT}', server={'lifetime': 3},
                          threads=[{'id': 'T1', 'cwd': '/w'}], turn_ids=['native-turn'])
        env['FLEET_CODEX_REMOTE'] = 'unix://' + sock
        p = subprocess.Popen([str(self.codex), 'app-server', '--listen', 'unix://' + sock], env=env)
        self.addCleanup(lambda: p.poll() is None and p.kill())
        end = time.monotonic() + 5
        while not os.path.exists(sock) and time.monotonic() < end:
            time.sleep(.05)
        c = Client('unix://' + sock, timeout=3)
        self.assertEqual(c.call('turn/start', {'threadId': 'T1', 'input': []})['turn']['id'], 'native-turn')
        c.close()
        self.assertEqual(json.loads((self.root / 'delivered.json').read_text())['threadId'], 'T1')
        self.assertEqual(p.wait(timeout=10), 0)
        self.assertEqual(json.loads((self.root / 'server.json').read_text())['pid'], p.pid)

    def test_server_exit_and_mismatched_endpoint(self):
        env = self.script(server={'exit': 9})
        self.assertEqual(subprocess.run([str(self.codex), 'app-server'], env=env).returncode, 9)
        env = self.script()
        env['FLEET_CODEX_REMOTE'] = 'unix:///elsewhere'
        p = subprocess.run([str(self.codex), 'app-server', '--listen', 'unix:///tmp/x'], env=env,
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 2)

    def test_client_runs_waits_holds_and_exits(self):
        mark = self.root / 'ran'
        env = self.script(record='{env:FAKE_ROOT}', threads=[{'id': 'T9'}], inside='{env:FAKE_ROOT}/..',
                          client={'run': [['sh', '-c', 'echo "$CODEX_THREAD_ID {pid}" > ' + str(mark)]],
                                  'ready': 'Codex ready\n', 'exit': '{env:RC:0}',
                                  'hold': {'flag': '--hold', 'while': '{env:FAKE_ROOT}/hold', 'secs': 5}})
        env['RC'] = '42'
        (self.root / 'hold').mkdir()
        p = subprocess.Popen([str(self.codex), '--hold'], env=env, stdout=subprocess.PIPE, text=True)
        time.sleep(.5)
        self.assertIsNone(p.poll(), 'held while the path stands')
        (self.root / 'hold').rmdir()
        out, _ = p.communicate(timeout=10)
        self.assertEqual((p.returncode, out), (42, 'Codex ready\n'))
        self.assertEqual(mark.read_text().split(), ['T9', str(p.pid)])
        self.assertEqual(json.loads((self.root / 'client.json').read_text())['argv'], ['--hold'])
        env = self.script(record='{env:FAKE_ROOT}', inside='/nowhere')
        self.assertEqual(subprocess.run([str(self.codex)], env=env, capture_output=True).returncode, 2)


class TwoAgents(unittest.TestCase):
    """The leg C4–C8 run twice: one session start, as each agent reports it."""

    def started(self, agent, sid):
        msg = fake.session_started(agent, sid, cwd='/w')
        if agent == 'codex':  # what the follower reads off the app-server
            return msg['params']['thread']['id'], msg['params']['thread']['cwd']
        return msg['session_id'], msg['cwd']  # what the SessionStart hook hands over

    def test_same_session_either_agent(self):
        for agent in fake.AGENTS:
            with self.subTest(agent=agent):
                self.assertEqual(self.started(agent, 'S1'), ('S1', '/w'))
        with self.assertRaises(ValueError):
            fake.session_started('gemini', 'S1')


if __name__ == '__main__':
    unittest.main(verbosity=2)
