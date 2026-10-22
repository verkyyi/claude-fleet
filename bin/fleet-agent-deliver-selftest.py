#!/usr/bin/env python3
# The one delivery road, for both agents (T626, EPIC T580 C6). fleet_agent_deliver
# (bin/fleet-lib.sh) asks the adapter table's `deliver` column how a message goes into
# a live session; everything else — the held code, the peer queue, the replay — is one
# copy. The same four legs run once as Claude (a fake process under the pane, a peer
# inbox socket) and once as Codex (the one fake app-server, bin/fleet_codex_fake_appserver.py,
# and a `codex` on PATH that records `codex queue`), through bin/fleet-peer-send.sh and
# bin/fleet-peer-queue.sh drain:
#   idle      handed over at once: exit 0, «sent →», it lands
#   busy      mid-turn the agent's own queue takes it: still exit 0, never typed into the pane
#   clear     after /clear it reaches the NEW conversation: Claude's inbox is the process's,
#             so at once; a Codex window not yet on its new thread holds (exit 3, queued,
#             nothing into the old thread) and the replay lands in the new one
#   exited    nobody there to take it: exit 3 held — queued for the window's identity, never «sent»
# Plus the table: the deliver column and the one held code (its shell copy generated).
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

BIN = Path(__file__).absolute().parent
sys.path.insert(0, str(BIN))
import fleet_agent_adapter as adapter  # noqa: E402
import fleet_codex_fake_appserver as fake  # noqa: E402

TMUX = shutil.which('tmux')
MARK = 'FLEETFAKECLAUDE'


class Inbox:
    """A Claude session's peer inbox: auth + user frames, newline-delimited."""

    def __init__(self, path):
        self.path, self.got = path, []
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        self.sock.listen(8)
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                c, _ = self.sock.accept()
            except OSError:
                return
            c.settimeout(3)
            buf = b''
            try:
                while True:
                    d = c.recv(65536)
                    if not d:
                        break
                    buf += d
            except OSError:
                pass
            c.close()
            for line in buf.decode().splitlines():
                f = json.loads(line) if line.strip() else {}
                if f.get('type') == 'user':
                    self.got.append(f['message']['content'])

    def close(self):
        self.sock.close()
        try:
            os.unlink(self.path)
        except OSError:
            pass


class Rig:
    """One isolated tmux server, one recipient window of `agent`."""

    def __init__(self, test, agent):
        self.test, self.agent = test, agent
        self.root = Path(tempfile.mkdtemp(prefix='fad-', dir='/tmp'))
        self.label = 'fad%s%d' % (agent[:2], os.getpid())
        self.conf = self.root / 'conf'
        fleet = self.conf / 'fleets' / self.label
        fleet.mkdir(parents=True)
        (fleet / 'conf').write_text('')
        self.qlog = self.root / 'queue.ndjson'
        fakebin = self.root / 'fakebin'
        fakebin.mkdir()
        (fakebin / 'codex').write_text('#!%s\nimport sys,os,json\nopen(os.environ["QUEUE_LOG"],"a").write(json.dumps(sys.argv[1:])+"\\n")\n'
                                       % sys.executable)
        (fakebin / 'codex').chmod(0o755)
        # never the fleet's own tmux guard: this server is the test's (a bare test socket)
        path = ':'.join(p for p in os.environ.get('PATH', '').split(':') if not p.endswith('/tmux-shim'))
        self.env = dict(os.environ, PATH=str(fakebin) + ':' + path, QUEUE_LOG=str(self.qlog),
                        FLEET_CONF_DIR=str(self.conf), FLEET_CC_SESSIONS_DIR=str(self.root / 'sessions'),
                        FLEET_CLAUDE_COMM=MARK, FLEET_ID_PUSH='0', FLEET_ID_DIR=str(self.root / 'ids'))
        for k in ('TMUX', 'TMUX_PANE', 'CCQUOTA_FLEET'):
            self.env.pop(k, None)
        (self.root / 'sessions').mkdir()
        self.server = self.inbox = None
        self.tm('-f', '/dev/null', 'new-session', '-d', '-s', self.label, '-n', 'home', 'sleep 300')
        self.win = self.tm('new-window', '-d', '-P', '-F', '#{window_id}', '-n', 'issue-42',
                           "bash -c ': %s; while :; do sleep 300; done'" % MARK)
        self.pane = self.tm('display-message', '-p', '-t', self.win, '#{pane_id}')
        self.opt('@issue', '42')
        getattr(self, 'start_' + agent)()

    def tm(self, *args):
        return subprocess.check_output([TMUX, '-L', self.label, *args], text=True, env=self.env).strip()

    def opt(self, name, value):
        self.tm('set-option', '-w', '-t', self.win, name, value)

    # --- Claude: a fake process under the pane, its registry record and inbox
    def start_claude(self):
        pid = ''
        for _ in range(30):
            pid = subprocess.run(['bash', '-c', '. "$1/fleet-lib.sh"; fleet_pane_claude_pid "$2" "$3"', '-',
                                  str(BIN), self.win, self.label], text=True, capture_output=True, env=self.env).stdout.strip()
            if pid:
                break
            time.sleep(0.1)
        self.test.assertTrue(pid, 'rig: no fake Claude under the pane')
        self.pid = pid
        sock = str(self.root / 'inbox.sock')
        (self.root / 'sessions' / (pid + '.json')).write_text(json.dumps(
            dict(pid=int(pid), sessionId='0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b', cwd='/fixture',
                 messagingSocketPath=sock, name='w42')))
        (self.root / 'sessions' / (pid + '.k.key')).write_text(json.dumps(dict(peerToken='tok-42')))
        self.inbox = Inbox(sock)
        self.opt('@cc_session_id', '0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b')

    # --- Codex: the window names its thread on the one fake app-server
    def start_codex(self):
        self.sockdir = tempfile.mkdtemp(prefix='fadx-', dir='/tmp')
        self.server = fake.FakeAppServer(self.sockdir + '/worker.sock')
        now = int(time.time() * 1000)
        self.old_t, self.new_t = fake.uuid7(now - 60000), fake.uuid7(now)
        self.server.add(fake.tui_thread(self.old_t))
        self.name_thread(self.old_t)
        self.opt('@cc_agent', 'codex')
        self.opt('@cc_launcher_pid', '1234')

    def name_thread(self, tid):
        """What the follower stamps once the window is on `tid` (T540)."""
        self.opt('@codex_identity', json.dumps(dict(session_id=tid, owner='1234', home=str(self.root),
                                                    remote=self.server.remote)))
        self.opt('@codex_session_id', tid)

    def queued(self):
        return [json.loads(l) for l in self.qlog.read_text().splitlines()] if self.qlog.exists() else []

    def landed(self, text, thread=None):
        """Where `text` went: True once it reached the live conversation."""
        for _ in range(30):
            if self.agent == 'claude':
                if any(text in m for m in self.inbox.got):
                    return True
            elif any(q[-1] == text and (thread is None or q[4] == thread) for q in self.queued()):
                return True
            time.sleep(0.1)
        return False

    def peer(self, text):
        return subprocess.run(['bash', str(BIN / 'fleet-peer-send.sh'), '-L', self.label, self.win, text],
                              env=self.env, capture_output=True, text=True)

    def drain(self):
        return subprocess.run(['bash', str(BIN / 'fleet-peer-queue.sh'), 'drain', '-L', self.label],
                              env=self.env, capture_output=True, text=True)

    def deliver(self, text):
        p = subprocess.run(['bash', '-c', '. "$1/fleet-lib.sh"; fleet_agent_deliver "$2" "$3" "$4"; rc=$?; '
                            'printf "%s" "$FLEET_DELIVER_NOTE"; exit "$rc"', '-', str(BIN), self.win, self.label, text],
                           env=self.env, capture_output=True, text=True)
        return p.returncode, p.stdout

    def close(self):
        subprocess.run([TMUX, '-L', self.label, 'kill-server'], capture_output=True, env=self.env)
        if self.inbox:
            self.inbox.close()
        if self.server:
            self.server.close()
            shutil.rmtree(self.sockdir, ignore_errors=True)
        shutil.rmtree(self.root, ignore_errors=True)


@unittest.skipUnless(TMUX, 'tmux unavailable')
class OneRoad(unittest.TestCase):
    """Each leg once per agent: the same assertions, only the fake differs."""

    def each(self, leg):
        for agent in ('claude', 'codex'):
            with self.subTest(agent=agent):
                rig = Rig(self, agent)
                try:
                    leg(rig)
                finally:
                    rig.close()

    def test_idle(self):
        def leg(r):
            p = r.peer('hello idle')
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertTrue(p.stdout.startswith('sent → '), p.stdout)
            self.assertEqual(len(p.stdout.strip().splitlines()), 1, 'one outcome line')
            self.assertTrue(r.landed('hello idle'), 'it reached the session')
            rc, note = r.deliver('direct')
            self.assertEqual(rc, 0, note)
            self.assertEqual(note.split()[0], 'pid' if r.agent == 'claude' else 'codex', note)
        self.each(leg)

    def test_busy_is_queued_by_the_agent(self):
        def leg(r):
            if r.agent == 'claude':
                r.opt('@claude_state', 'working')
            else:
                r.server.threads[r.old_t]['status'] = {'type': 'active', 'activeFlags': []}
            before = r.tm('capture-pane', '-p', '-t', r.pane)
            p = r.peer('while busy')
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertTrue(r.landed('while busy'), "the agent's own queue took it")
            self.assertEqual(r.tm('capture-pane', '-p', '-t', r.pane), before, 'never typed into the pane')
        self.each(leg)

    def test_clear_reaches_the_new_conversation(self):
        def leg(r):
            if r.agent == 'claude':
                # /clear: same process, same inbox, a new conversation behind it
                r.opt('@cc_session_id', '1f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5c')
                p = r.peer('after clear')
                self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
                self.assertTrue(r.landed('after clear'))
                return
            r.server.add(fake.tui_thread(r.new_t))      # /clear: the TUI's new thread, not followed yet
            p = r.peer('after clear')
            self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
            self.assertTrue(p.stdout.startswith('queued → '), p.stdout)
            self.assertIn(r.new_t, p.stdout, 'the hold names the thread the window moved to')
            self.assertEqual(r.queued(), [], 'nothing went into the old thread')
            rc, note = r.deliver('direct')
            self.assertEqual(rc, adapter.HELD, note)
            r.name_thread(r.new_t)                      # the follower stamps the new thread
            d = r.drain()
            self.assertEqual(d.returncode, 0, d.stderr)
            self.assertTrue(r.landed('after clear', r.new_t), 'the replay lands in the new thread')
        self.each(leg)

    def test_exited_is_held(self):
        def leg(r):
            if r.agent == 'claude':
                r.tm('respawn-pane', '-k', '-t', r.pane, 'sleep 300')   # the agent is gone, the window stays
            else:
                r.server.close()
            rc, note = r.deliver('nobody home')
            self.assertEqual(rc, adapter.HELD, note)
            p = r.peer('nobody home')
            self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
            self.assertTrue(p.stdout.startswith('queued → '), p.stdout)
            self.assertNotIn('sent', p.stdout)
            book = r.conf / 'fleets' / r.label / 'delivery.ndjson'
            rows = [json.loads(l) for l in book.read_text().splitlines()] if book.exists() else []
            self.assertNotIn('DELIVERED', [x.get('state') for x in rows], 'held is never DELIVERED')
            self.assertEqual(r.drain().returncode, 0)
            self.assertFalse(r.landed('nobody home'), 'still nobody to take it')
        self.each(leg)


class Table(unittest.TestCase):
    def test_columns(self):
        self.assertEqual({a: adapter.get(a, 'deliver') for a in adapter.ADAPTERS}, {'claude': 'inbox', 'codex': 'queue'})
        self.assertEqual(adapter.HELD, 3)
        self.assertIn('FLEET_DELIVER_HELD=3', adapter.emit_sh())
        self.assertEqual((BIN / 'fleet-agent-adapter.sh').read_text(), adapter.emit_sh(), 'the shell copy is generated')

    def test_one_road_no_name_branch(self):
        # the callers ask the table, never the agent's name, to pick a deliverer
        for f in ('fleet-peer-send.sh', 'fleet-children-lib.sh', 'fleet-report-parent.sh',
                  'fleet_worker_life.py', 'fleet_task_control.py'):
            text = (BIN / f).read_text()
            self.assertNotIn('fleet-codex-session.py" send', text, f)
            self.assertNotIn("fleet-codex-session.py','send'", text, f)
            self.assertNotIn('fleet-codex-session.py"), "send"', text, f)


if __name__ == '__main__':
    unittest.main()
