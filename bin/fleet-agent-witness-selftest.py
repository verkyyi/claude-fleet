#!/usr/bin/env python3
# 「起来了」 and /clear, one road for both agents (T629, EPIC T580 C5). A window's
# conversation reaches its ID ledger through ONE witness, fleet_id.hook (bin/fleet_id.py):
# Claude feeds it its SessionStart payload; Codex's runtime feeds it the private
# app-server's thread/started (bin/fleet-codex-session.py Follow — witness() / follow()),
# because Codex runs SessionStart only at a thread's first turn. The adapter table
# (bin/fleet_agent_adapter.py) says which: sid_source, clear_said. The same legs run once
# as Claude and once as Codex (the one fake app-server, bin/fleet_codex_fake_appserver.py):
#   start     the ID gets segment 1 (startup) — Codex's BEFORE its first turn, and the
#             first-turn hook then adds nothing
#   clear     /clear opens segment 2 (clear) at once
#   reopen    a relaunch after a version update comes back on the same conversation:
#             no new segment
# Plus the table: next_native asks clear_said, and the one conversation-id reader
# (session_id / fleet_agent_session_id) reads the same chain in Python and shell.
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

BIN = Path(__file__).absolute().parent
sys.path.insert(0, str(BIN))
import fleet_agent_adapter as adapter  # noqa: E402
import fleet_codex_fake_appserver as fake  # noqa: E402
import fleet_id  # noqa: E402
import importlib.util  # noqa: E402

spec = importlib.util.spec_from_file_location('codex_session', BIN / 'fleet-codex-session.py')
cx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cx)

TMUX = shutil.which('tmux')
ENV_KEYS = ('TMUX', 'TMUX_PANE', 'FLEET_CODEX_LAUNCHER_PID', 'FLEET_ID_DIR', 'FLEET_ID_PUSH',
            'FLEET_CONF_DIR', 'CLAUDE_CODE_ENTRYPOINT', 'CODEX_HOME', 'FLEET_ID_HOOK')


class TableTests(unittest.TestCase):
    def test_columns(self):
        self.assertEqual(adapter.get('claude', 'sid_source'), 'hook')
        self.assertEqual(adapter.get('codex', 'sid_source'), 'thread')
        self.assertEqual(adapter.get('claude', 'clear_said'), '1')
        self.assertEqual(adapter.get('codex', 'clear_said'), '0')

    def test_next_native_asks_the_table(self):
        # the same window, another id, no /clear said: an agent that says /clear
        # restarted on another id (resume); one that never says it opened a new one
        for agent, want in (('claude', 'resume'), ('codex', 'new')):
            evs = [{'ev': 'opened', 'id': 'x', 'seq': 1},
                   {'ev': 'native', 'agent': agent, 'native': 'a', 'trigger': 'startup', 'seq': 2}]
            got = fleet_id.next_native(evs, agent, 'b', 'startup', '')
            self.assertEqual(got['trigger'], want, agent)
            self.assertIsNone(fleet_id.next_native(evs, agent, 'a', 'startup', ''), agent)

    def test_one_session_id_reader(self):
        pend = json.dumps({'session_id': 'ab-1', 'owner': '1', 'home': '/h', 'pending': True}, separators=(',', ':'))
        cases = [
            ('claude', {'@cc_session_id': 'c-1'}, 'c-1', 'c-1', ''),
            ('claude', {}, '', '', ''),
            ('codex', {'@codex_session_id': 's-1', '@codex_pending': pend}, 's-1', 's-1', 'ab-1'),
            ('codex', {'@codex_pending': pend, '@codex_thread_id': 't-1'}, 'ab-1', '', 'ab-1'),
            ('codex', {'@codex_thread_id': 't-1'}, 't-1', '', 't-1'),
            ('nobody', {'@cc_session_id': 'c-2'}, 'c-2', 'c-2', ''),
        ]
        with tempfile.TemporaryDirectory() as d:
            for agent, opts, want_all, want_win, want_fb in cases:
                read = lambda o, opts=opts: opts.get(o, '')
                self.assertEqual(adapter.session_id(agent, read), want_all, (agent, opts))
                self.assertEqual(adapter.session_id(agent, read, 'window'), want_win, (agent, opts))
                self.assertEqual(adapter.session_id(agent, read, 'fallback'), want_fb, (agent, opts))
                f = Path(d) / 'opts.json'
                f.write_text(json.dumps(opts))
                script = ('. "$1"; rd() { python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],\'\'), end=\'\')" "$1" "$2"; }\n'
                          'r() { rd "$F" "$1"; }; F=$2\n'
                          'printf "%s|%s|%s" "$(fleet_agent_session_id "$3" r)" "$(fleet_agent_session_id "$3" r window)" '
                          '"$(fleet_agent_session_id "$3" r fallback)"')
                got = subprocess.run(['bash', '-c', script, 'x', str(BIN / 'fleet-agent-adapter.sh'), str(f), agent],
                                     capture_output=True, text=True)
                self.assertEqual(got.stdout, '%s|%s|%s' % (want_all, want_win, want_fb), (agent, opts, got.stderr))


@unittest.skipUnless(TMUX, 'tmux unavailable')
class WitnessTests(unittest.TestCase):
    def setUp(self):
        self.saved = {k: os.environ.get(k) for k in ENV_KEYS}
        self.tmp = Path(tempfile.mkdtemp(prefix='fw-', dir='/tmp'))
        self.label = 'witness%d' % os.getpid()
        self.tm = ['tmux', '-L', self.label]
        self.call('new-session', '-d', '-s', self.label, '-n', 'w', 'sleep 120')
        self.pane = self.call('display-message', '-p', '#{pane_id}')
        sock = self.call('display-message', '-p', '#{socket_path}')
        self.fid = 'abcdef01-2345-4678-9abc-def012345678'
        self.call('set-option', '-w', '-t', self.pane, '@fleet_id', self.fid)
        for k in ENV_KEYS:
            os.environ.pop(k, None)
        os.environ.update(TMUX=sock + ',1,0', TMUX_PANE=self.pane, FLEET_ID_DIR=str(self.tmp / 'ids'),
                          FLEET_ID_PUSH='0', FLEET_CONF_DIR=str(self.tmp / 'conf'), CODEX_HOME=str(self.tmp / 'codex'))
        self.servers = []

    def tearDown(self):
        for s in self.servers:
            s.close()
        subprocess.run(self.tm + ['kill-server'], capture_output=True)
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.tmp, ignore_errors=True)

    def call(self, *args):
        return subprocess.check_output(self.tm + list(args), text=True).strip()

    def segments(self):
        return [(s['native'], s['trigger']) for s in fleet_id.fold(fleet_id.read(self.fid))['segments']]

    # -- Claude: its SessionStart hook is the witness ---------------------------------
    def claude_start(self, sid, source):
        fleet_id.hook(json.dumps(fake.session_started('claude', sid, source=source)))

    # -- Codex: its runtime's follower is the witness ----------------------------------
    def codex_launch(self, owner, threads, pending=''):
        for name, value in (('@cc_agent', 'codex'), ('@cc_launcher_pid', owner)):
            self.call('set-option', '-w', '-t', self.pane, name, value)
        for name in ('@codex_identity', '@codex_session_id'):   # fleet-codex.sh clears them at launch
            self.call('set-option', '-wu', '-t', self.pane, name)
        if pending:
            self.call('set-option', '-w', '-t', self.pane, '@codex_pending', json.dumps(
                {'session_id': pending, 'owner': owner, 'home': str(self.tmp), 'pending': True}, separators=(',', ':')))
        os.environ['FLEET_CODEX_LAUNCHER_PID'] = owner
        server = fake.FakeAppServer(str(self.tmp / ('s%d.sock' % len(self.servers))))
        self.servers.append(server)
        for t in threads:
            server.add(fake.tui_thread(t))
        follower = cx.Follow(dict(TMUX_PANE=self.pane, FLEET_CODEX_LAUNCHER_PID=owner,
                                  FLEET_CODEX_REMOTE=server.remote, CODEX_HOME=str(self.tmp / 'codex')))
        return server, follower

    def tick_until(self, follower, want):
        got = ''
        for _ in range(30):
            got = follower.tick() or got
            if got == want:
                return got
            time.sleep(0.1)
        return got

    def test_claude(self):
        a, b = '11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222'
        self.claude_start(a, 'startup')
        self.assertEqual(self.segments(), [(a, 'startup')], 'start')
        self.claude_start(b, 'clear')
        self.assertEqual(self.segments(), [(a, 'startup'), (b, 'clear')], 'clear')
        self.claude_start(b, 'resume')   # reopened after an update, on the same conversation
        self.assertEqual(self.segments(), [(a, 'startup'), (b, 'clear')], 'reopen')

    def test_codex(self):
        now = int(time.time() * 1000)
        a = fake.uuid7(now - 5000)
        server, follower = self.codex_launch('1234', [a])
        # start: nobody spoke yet — the runtime witnesses the TUI's thread
        self.assertEqual(self.tick_until(follower, a), a)
        self.assertEqual(self.segments(), [(a, 'startup')], 'start before the first turn')
        self.assertEqual(self.call('show-options', '-wv', '-t', self.pane, '@codex_session_id'), a)
        ident = json.loads(self.call('show-options', '-wv', '-t', self.pane, '@codex_identity'))
        self.assertEqual((ident['session_id'], ident['owner'], ident['remote']), (a, '1234', server.remote))
        # the first turn's own SessionStart finds the same thread: nothing added
        fleet_id.hook(json.dumps({'hook_event_name': 'SessionStart', 'session_id': a, 'source': 'startup'}))
        self.assertEqual(self.segments(), [(a, 'startup')], 'first-turn hook')
        # clear: the TUI's new thread, followed at once
        b = server.clear()['id']
        self.assertEqual(self.tick_until(follower, b), b)
        self.assertEqual(self.segments(), [(a, 'startup'), (b, 'clear')], 'clear')
        follower.close()
        # reopen: a relaunch (a version update) resumes b on a new server — same conversation
        _, follower = self.codex_launch('5678', [b], pending=b)
        self.assertEqual(self.tick_until(follower, b), b)
        self.assertEqual(self.segments(), [(a, 'startup'), (b, 'clear')], 'reopen')
        follower.close()

    def test_codex_witness_never_takes_a_named_window(self):
        now = int(time.time() * 1000)
        a, mine = fake.uuid7(now - 5000), fake.uuid7(now - 9000)
        _, follower = self.codex_launch('1234', [a])
        self.call('set-option', '-w', '-t', self.pane, '@codex_session_id', mine)   # its hook already named one
        for _ in range(5):
            follower.tick()
            time.sleep(0.05)
        self.assertEqual(self.call('show-options', '-wv', '-t', self.pane, '@codex_session_id'), mine)
        self.assertEqual(self.segments(), [])
        # another launcher's window is never stamped
        self.assertEqual(cx.witness(self.pane, '9999', fake.tui_thread(a), str(self.tmp)), '')
        # FLEET_CODEX_FOLLOW=0: no witness either — the first-turn hook says it
        self.assertTrue(cx.Follow(dict(TMUX_PANE=self.pane, FLEET_CODEX_LAUNCHER_PID='1234',
                                       FLEET_CODEX_REMOTE='unix:///x', FLEET_CODEX_FOLLOW='0')).off)
        follower.close()


if __name__ == '__main__':
    unittest.main(verbosity=2)
