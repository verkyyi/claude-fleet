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

    def test_disabled_threshold_is_a_no_op(self):
        wid, pane = self.window()
        self.record(wid, pane, status='idle', since=time.time() - 10)
        self.run_cli('--idle-secs', '0')
        self.assertEqual(self.state(wid)[0], 'working')


if __name__ == '__main__': unittest.main(verbosity=2)
