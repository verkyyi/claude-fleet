#!/usr/bin/env python3
"""Real isolated tmux panes + a fake Claude registry: the native-truth reconcile (#806)."""
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
from unittest.mock import patch

BIN = Path(sys.argv.pop(1)).absolute()
MOD = runpy.run_path(str(BIN / 'fleet-state-reconcile.py'))
LIVE = MOD['reconcile'].__globals__   # run_path returns a copy; patch the functions' real globals


class ReconcileTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='fleet-reconcile-test-')
        cls.root = Path(cls.tmp.name).resolve()
        cls.socket = 'reconcile-test-' + str(os.getpid())
        cls.bin = cls.root / 'bin'; cls.bin.mkdir()
        shutil.copyfile(BIN / 'fleet-state-reconcile.py', cls.bin / 'fleet-state-reconcile.py')
        shutil.copyfile(BIN / 'fleet-input.py', cls.bin / 'fleet-input.py')
        fake = cls.bin / 'classify-sessions.sh'
        fake.write_text('#!/bin/bash\nprintf "%s %s\\n" "${CLASSIFY_SOCK:-}" "$*" >> ' + str(cls.root / 'classify.log') + '\n')
        fake.chmod(0o755)
        # A process whose comm is an agent name, so "an agent is under the pane" is testable.
        # A symlink, not a copy: macOS refuses to run a copied platform binary, and
        # ps reports the symlink's own name as comm on both platforms.
        for name in ('claude', 'codex'):
            os.symlink(shutil.which('sleep'), cls.root / name)
        cls.registry = cls.root / 'sessions'; cls.registry.mkdir()
        cls.cache = cls.root / 'cache'; cls.log = cls.root / 'reconcile.log'
        cls.tm('-f', '/dev/null', 'new-session', '-d', '-s', cls.socket, '-x', '80', '-y', '24', 'sleep 300')

    @classmethod
    def tearDownClass(cls):
        subprocess.run(['tmux', '-L', cls.socket, 'kill-server'], stderr=subprocess.DEVNULL)
        cls.tmp.cleanup()

    @classmethod
    def tm(cls, *args):
        return subprocess.check_output(['tmux', '-L', cls.socket, *args], text=True, stderr=subprocess.PIPE).strip()

    def setUp(self):
        for f in self.registry.glob('*'): f.unlink()
        for f in (self.root / 'classify.log', self.log): f.unlink(missing_ok=True)
        shutil.rmtree(self.cache, ignore_errors=True)
        self.windows = []

    def tearDown(self):
        for wid in self.windows: self.tm('kill-window', '-t', wid)

    def argv(self, *extra):
        return ['--cache-dir', str(self.cache), '--registry', str(self.registry), '--log', str(self.log),
                '--idle-secs', '5', '--exited-secs', '60', *extra, '--', self.socket]

    def run_cli(self, *extra):
        p = subprocess.run(['python3', str(self.bin / 'fleet-state-reconcile.py'), *self.argv(*extra)],
                           text=True, capture_output=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p

    def window(self, state='working', age=300, command='sleep 300', raw='1', **opts):
        wid = self.tm('new-window', '-d', '-P', '-F', '#{window_id}', '-t', self.socket, '-c', str(self.root), 'exec ' + command)
        self.windows.append(wid)
        options = {'@claude_state': state, '@claude_state_ts': str(int(time.time() - age)), '@cc_agent': 'claude'}
        if raw: options['@raw'] = raw
        options.update(opts)
        for key, value in options.items(): self.tm('set-option', '-w', '-t', wid, key, value)
        pane = self.tm('display-message', '-p', '-t', wid, '#{pane_id}')
        return wid, pane

    def record(self, wid, pane, status='idle', since=None, pid=None, started=None):
        # Claude records startedAt (ms) and procStart (UTC text); ps prints lstart in
        # local time, so the fixture writes what the TUI would, from this process's ps row.
        pid = pid or os.getpid()
        if started is None:
            lstart = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart='], text=True, capture_output=True).stdout
            started = time.mktime(time.strptime(' '.join(lstart.split()), MOD['LSTART'])) if lstart.strip() else time.time()
        data = {'pid': str(pid), 'sessionId': 'aaaaaaaa-0000-4000-8000-000000000000',
                'startedAt': str(int(started * 1000)), 'procStart': time.strftime(MOD['LSTART'], time.gmtime(started)),
                'tmux': '%s:%s.%s' % (self.socket, wid, pane), 'status': status,
                'statusUpdatedAt': str(int((since if since is not None else time.time() - 10) * 1000))}
        (self.registry / ('%s.json' % pid)).write_text(json.dumps(data))

    def state(self, wid):
        return self.tm('display-message', '-p', '-t', wid, '#{@claude_state}|#{@claude_needs}|#{@claude_state_ts}').split('|')

    def heartbeat(self):
        return dict(line.split('=', 1) for line in (self.cache / 'reconcile.heartbeat').read_text().splitlines() if '=' in line)

    def test_native_idle_after_the_stamp_demotes_and_reclassifies(self):
        wid, pane = self.window(**{'@claude_needs': 'ask'})
        self.record(wid, pane, status='idle', since=time.time() - 10)
        before = int(time.time()); self.run_cli()
        state, needs, ts = self.state(wid)
        self.assertEqual((state, needs), ('done', ''))
        self.assertGreaterEqual(int(ts), before)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not (self.root / 'classify.log').exists(): time.sleep(.05)
        self.assertEqual((self.root / 'classify.log').read_text().split(), [self.socket, '--window', wid])
        self.assertIn('native idle', self.log.read_text())
        self.assertEqual((self.heartbeat()['working'], self.heartbeat()['demoted']), ('1', '1'))

    def test_busy_fresh_or_shell_records_and_fresh_stamps_are_left_alone(self):
        cases = [dict(status='busy'), dict(status='idle', since=time.time() - 1), dict(status='shell'),
                 dict(status='idle', since=time.time() - 600, age=2)]   # a turn the TUI has not marked yet
        for kw in cases:
            with self.subTest(**kw):
                self.setUp()
                wid, pane = self.window(age=kw.pop('age', 300))
                self.record(wid, pane, **kw)
                self.run_cli()
                self.assertEqual(self.state(wid)[0], 'working')
                self.assertEqual(self.heartbeat()['demoted'], '0')
                self.tearDown(); self.windows = []

    def test_idle_before_an_old_working_stamp_is_a_misread_promotion(self):
        # The classifier flipped done -> working from a screen after Claude had
        # already stopped: the TUI is idle since BEFORE the stamp, and stays so.
        wid, pane = self.window(age=120)
        self.record(wid, pane, status='idle', since=time.time() - 600)
        self.run_cli()
        self.assertEqual(self.state(wid)[0], 'done')
        self.assertIn('native idle', self.log.read_text())

    def test_dead_or_reused_pid_falls_back_to_the_exited_rule(self):
        wid, pane = self.window(age=300)
        self.record(wid, pane, status='idle', pid=999999, started=978307200)
        self.run_cli()
        self.assertEqual(self.state(wid)[0], 'done'); self.assertIn('exited', self.log.read_text())
        wid, pane = self.window(age=300)
        self.record(wid, pane, status='idle', started=978307200)   # our pid, a start from 2001
        self.run_cli()
        self.assertEqual(self.state(wid)[0], 'done')
        wid, pane = self.window(age=10)                                            # too fresh to call exited
        self.run_cli()
        self.assertEqual(self.state(wid)[0], 'working')

    def test_no_record_live_process_demotes_only_on_a_provably_empty_prompt(self):
        # A3: a live Claude process (comm 'claude') with no registry record falls
        # back to the screen. An empty prompt past the grace is demoted; the
        # blank-screen counterpart (test_an_agent_process_without_a_record...) is
        # snapshot 'unknown' and stays working, so the fallback can never guess.
        drawn = "sh -c 'printf \"\\033[2J\\033[H> \"; exec %s 300'" % (self.root / 'claude')
        wid, pane = self.window(age=300, command=drawn)
        until = time.time() + 5
        while time.time() < until and MOD['INPUT']['snapshot'](self.socket, pane, agent='claude').get('state') != 'empty':
            time.sleep(0.1)
        self.assertEqual(MOD['INPUT']['snapshot'](self.socket, pane, agent='claude').get('state'), 'empty')
        self.run_cli()
        self.assertEqual(self.state(wid)[0], 'done')
        self.assertIn('prompt idle', self.log.read_text())

    def test_an_agent_process_without_a_record_is_not_exited(self):
        wid, _ = self.window(age=3000, command=str(self.root / 'claude') + ' 300')
        self.run_cli()
        self.assertEqual(self.state(wid)[0], 'working')
        wid, _ = self.window(age=3000, command=str(self.root / 'codex') + ' 300', **{'@cc_agent': 'codex'})
        self.run_cli()
        self.assertEqual(self.state(wid)[0], 'working')   # legacy Codex: no identity, still running

    def test_panels_transitions_and_other_states_are_untouched(self):
        for opts in ({'@hub': '1'}, {'@worker_lifecycle': 'sleeping'}, {'state': 'done'}, {'raw': ''}):
            with self.subTest(**opts):
                state = opts.pop('state', 'working'); raw = opts.pop('raw', '1')
                wid, pane = self.window(state=state, raw=raw, **opts)
                self.record(wid, pane, status='idle', since=time.time() - 10)
                self.run_cli()
                self.assertEqual(self.state(wid)[0], state)
        self.assertFalse(self.log.exists())

    def test_dry_run_reports_without_writing(self):
        wid, pane = self.window()
        self.record(wid, pane, status='idle', since=time.time() - 10)
        p = self.run_cli('--dry-run')
        self.assertIn('would demote', p.stdout)
        self.assertEqual(self.state(wid)[0], 'working')
        self.assertFalse((self.cache / 'reconcile.heartbeat').exists()); self.assertFalse(self.log.exists())

    def test_bound_codex_thread_idle_demotes_in_process(self):
        identity = json.dumps({'remote': 'unix:///nowhere/worker.sock', 'session_id': 'thread-1'})
        wid, _ = self.window(age=300, command=str(self.root / 'codex') + ' 300', **{'@cc_agent': 'codex', '@codex_identity': identity})
        seen = []
        def fake(identity, state_ts):
            seen.append((identity['session_id'], state_ts)); return (True, time.time() - 10)
        with patch.dict(LIVE, codex_idle=fake), patch.object(sys, 'argv', ['x', *self.argv()]):
            self.assertEqual(MOD['main'](), 0)
        self.assertEqual(self.state(wid)[0], 'done'); self.assertIn('codex thread idle', self.log.read_text())
        self.assertEqual(seen[0][0], 'thread-1')
        wid, _ = self.window(age=300, command=str(self.root / 'codex') + ' 300', **{'@cc_agent': 'codex', '@codex_identity': identity})
        with patch.dict(LIVE, codex_idle=lambda i, ts: (False, 0)), patch.object(sys, 'argv', ['x', *self.argv()]):
            self.assertEqual(MOD['main'](), 0)
        self.assertEqual(self.state(wid)[0], 'working')

    def rung_lines(self):
        return [l for l in self.log.read_text().splitlines() if ' rung_health ' in l] if self.log.exists() else []

    def test_three_contradictions_each_log_one_event_and_the_higher_rung_wins(self):
        # #1270: hook says working (stamp past its 15s trust), tmux has seen the
        # pane silent > 1s, and the registry disagrees three ways. Ages are picked
        # so the pre-#1270 rules would NOT decide: idle is inside the 5s grace,
        # gone is inside the 60s exited grace.
        idle_w, pane = self.window(age=30)     # its own live pid: a record file is named by pid
        self.record(idle_w, pane, status='idle', since=time.time() - 1,
                    pid=int(self.tm('display-message', '-p', '-t', idle_w, '#{pane_pid}')))
        gone_w, pane = self.window(age=30); self.record(gone_w, pane, status='idle', pid=999999, started=978307200)
        busy_w, pane = self.window(age=30); self.record(busy_w, pane, status='busy')
        time.sleep(2.2)
        self.run_cli('--tmux-idle-secs', '1')
        self.assertEqual([self.state(w)[0] for w in (idle_w, gone_w, busy_w)], ['done', 'done', 'working'])
        lines = self.rung_lines()
        self.assertEqual(len(lines), 3, lines)
        for wid, says, verdict in ((idle_w, 'idle', 'done'), (gone_w, 'gone', 'done'), (busy_w, 'busy', 'working')):
            [line] = [l for l in lines if ' window=%s ' % wid in l]
            self.assertRegex(line, r' rung_health window=%s hook=working tmux_idle=\d+s registry=%s .*-> %s$' % (wid, says, verdict))
        hb = self.heartbeat()
        self.assertEqual((hb['contested'], hb['rung_health'], hb['demoted']), ('3', '3', '2'))
        # The busy contradiction persists: counted live, logged once.
        self.run_cli('--tmux-idle-secs', '1')
        self.assertEqual(len(self.rung_lines()), 3)
        self.assertEqual((self.heartbeat()['contested'], self.heartbeat()['rung_health']), ('1', '0'))
        self.assertEqual(self.state(busy_w)[0], 'working')

    def test_no_contradiction_decides_exactly_as_before(self):
        # A pane tmux saw active, or a hook stamp still inside its trust window,
        # is not a contradiction: no event, and the pre-#1270 verdicts stand.
        fresh_idle, pane = self.window(age=30); self.record(fresh_idle, pane, status='idle', since=time.time() - 1)
        settled, pane = self.window(age=300); self.record(settled, pane, status='idle', since=time.time() - 10)
        self.run_cli()                                    # default 10s tmux bar: both panes just drew
        self.assertEqual((self.state(fresh_idle)[0], self.state(settled)[0]), ('working', 'done'))
        self.assertIn('native idle', self.log.read_text())
        self.assertEqual(self.rung_lines(), [])
        self.assertEqual(self.heartbeat()['contested'], '0')
        self.setUp()
        trusted, pane = self.window(age=3); self.record(trusted, pane, status='idle', since=time.time() - 1)
        time.sleep(2.2)
        self.run_cli('--tmux-idle-secs', '1')             # silent pane, but the stamp is ~5s old: trusted
        self.assertEqual(self.state(trusted)[0], 'working')
        self.assertEqual(self.rung_lines(), [])

    def test_disabled_threshold_is_a_no_op(self):
        wid, pane = self.window()
        self.record(wid, pane, status='idle', since=time.time() - 10)
        self.run_cli('--idle-secs', '0')
        self.assertEqual(self.state(wid)[0], 'working')


if __name__ == '__main__': unittest.main(verbosity=2)
