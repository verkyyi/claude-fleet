#!/usr/bin/env python3
# selftest-entry
"""Drive fleet-lib.sh runtime counts and fleet-cleanup-idle.sh/.py make-room.
Uses the existing isolated fleet-session-wrap.sh fixture; no production agents.
Does not repeat the ten-session wake storm.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest
from unittest.mock import patch

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))

def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, BIN / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

park = module('capacity_park', 'fleet-park-selftest.py')
idle = module('capacity_idle', 'fleet-cleanup-idle.py')

class Lifecycle(unittest.TestCase):
    def fixture(self):
        f = park.Park('runTest')
        f.setUp()
        self.addCleanup(f.doCleanups)
        home = f.tm('list-windows', '-t', 'test', '-F', '#{window_id}')
        f.tm('set-option', '-w', '-t', home, '@fleet_role', 'home')
        f.fake()
        f.wait(lambda: f.opt('@claude_state_src') == '7501')
        f.tm('rename-session', '-t', 'test', f.label)
        config = f.root / 'conf/fleets' / f.label
        config.mkdir(parents=True)
        (config / 'conf').touch()
        f.set('@norepo', '1')
        f.set('@claude_state_ts', str(int(time.time()) - 900))
        return f

    def counts(self, f):
        code = ('. "$1/fleet-lib.sh"; fleet_sockets() { printf "%s\\n" "$2"; }; '
                'fleet_session_count_for "$2"; '
                # override captures no positional arguments from the function
                'fleet_list_windows_all() { fleet_lw "$1" tmux -L "$CAP_SOCKET"; }; '
                'fleet_session_count; fleet_session_slot_holders "$2"')
        p = subprocess.run(['bash', '-c', code, 'capacity', str(BIN), f.label],
                           env=dict(f.env, CAP_SOCKET=f.label), capture_output=True, text=True, timeout=15)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout.splitlines()

    def test_retained_park_releases_runtime_capacity_only_after_ack(self):
        f = self.fixture()
        self.assertEqual(self.counts(f)[:2], ['1', '1'])
        f.set('@pin', '1')
        f.set('@reap_policy', 'keep')
        f.set('@parked', '123')       # exit requested, agent still running
        self.assertEqual(self.counts(f)[:2], ['1', '1'])
        f.set('@parked', '')
        with patch.dict(os.environ, f.env, clear=True):
            self.assertTrue(park.gate.park(f.fid)['ok'])
            self.assertEqual(self.counts(f), ['0', '0'])
            f.set('@park_wrap_ver', 'unknown')
            self.assertEqual(self.counts(f)[:2], ['1', '1'])
            f.set('@park_wrap_ver', '3')
            f.set('@park_start', '/pending.meta')
            self.assertEqual(self.counts(f)[:2], ['1', '1'])
            f.set('@park_start', '')
            self.assertTrue(park.gate.wake(f.fid)['ok'])
        self.assertEqual(self.counts(f)[:2], ['1', '1'])
        self.assertEqual(f.opt('@pin'), '1')
        self.assertEqual(f.opt('@reap_policy'), 'keep')
        self.assertEqual(f.opt('@cc_session_id'), f.sid)
        self.assertEqual(f.opt('@fleet_id'), f.fid)

    def cleaner(self, f):
        args = argparse.Namespace(socket_name=f.label, session=f.label, repo='', main='', base='master',
                                  window_repo=False, dry_run=False, skip_park=False, grace=None)
        return idle.Cleaner(args)

    def test_memory_parks_retained_waiters_without_archiving(self):
        for options in ({'@pin': '1'}, {'@reap_policy': 'keep', '@reap_keep_by': 'person'},
                        {'@agent_def': 'orchestrator'}):
            with self.subTest(options=options):
                f = self.fixture()
                for key, value in options.items():
                    f.set(key, value)
                with patch.dict(os.environ, f.env, clear=True):
                    c = self.cleaner(f)
                    self.assertEqual(c.room_tier(f.win, c.snapshot(f.win), set(), ''), 1)
                    with patch.object(c, 'id_status', return_value=dict(state='open', result=dict(state='waiting'))):
                        self.assertTrue(c.fold(f.win))
                    self.assertEqual(f.opt('@park_waiting'), '1')
                    self.assertTrue(f.opt('@park_held'))
                    self.assertIsNone(idle.fleet_reap_policy.parked_deadline(c.snapshot(f.win)))
                for key, value in options.items():
                    self.assertEqual(f.opt(key), value)
                self.assertEqual(f.opt('@fleet_id'), f.fid)
                self.assertEqual(f.opt('@cc_session_id'), f.sid)
                self.assertFalse((f.root / 'conf/retired' / f.fid).exists())

    def test_make_room_reaches_no_repo_park_and_honours_question(self):
        f = self.fixture()
        f.set('@pin', '1')
        f.set('@claude_needs', 'ask')
        cmd = ['bash', str(BIN / 'fleet-cleanup-idle.sh'), '--make-room', '1']
        p = subprocess.run(cmd, env=f.env, capture_output=True, text=True, timeout=30)
        self.assertFalse(f.opt('@park_held'), p.stdout + p.stderr)
        f.set('@claude_needs', '')
        p = subprocess.run(cmd, env=f.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn('parked-room:' + f.win, p.stdout)
        self.assertTrue(f.opt('@park_held'), p.stdout + p.stderr)
        self.assertEqual(f.opt('@pin'), '1')

    def test_memory_path_keeps_the_existing_safety_holds(self):
        f = self.fixture()
        f.set('@pin', '1')
        with patch.dict(os.environ, f.env, clear=True):
            c = self.cleaner(f)
            for state in ('working', 'needs', 'unknown'):
                f.set('@claude_state', state)
                f.set('@agent_status', '')
                self.assertFalse(c.fold(f.win))
                self.assertFalse(f.opt('@parked'))
            f.set('@claude_state', 'done')
            with patch.dict(os.environ, FLEET_GATE_BG_CMD='true'):
                self.assertFalse(c.fold(f.win))
                self.assertFalse(f.opt('@parked'))
            proof = Path(f.env['FLEET_GATE_PARK_PROBE_CMD'])
            for reason in ('draft', 'unknown_input', 'asking'):
                proof.write_text("#!/bin/sh\necho '" + json.dumps(dict(ok=False, why=reason)) + "'\n")
                self.assertFalse(c.fold(f.win))
                self.assertFalse(f.opt('@parked'))
            self.assertEqual(f.opt('@pin'), '1')
            self.assertEqual(f.opt('@fleet_id'), f.fid)

    def test_terminal_recheck_precedes_park_and_missing_rss_stays_unknown(self):
        import contextlib
        import io
        f = self.fixture()
        with patch.dict(os.environ, f.env, clear=True):
            c = self.cleaner(f)
            c.args.repo = 'o/r'
            def new_question(window):
                f.set('@claude_needs', 'ask')
                return False
            with patch.object(c, 'work_over', return_value=True), \
                    patch.object(c, 'candidate', side_effect=new_question) as reaper:
                self.assertFalse(c.fold(f.win))
                reaper.assert_called_once_with(f.win)
                self.assertFalse(f.opt('@park_held'))
            f.set('@claude_needs', '')
            f.set('@pin', '1')
            c.args.repo = ''
            out = io.StringIO()
            with patch.object(c, 'tree_rss', return_value={}), contextlib.redirect_stdout(out):
                self.assertTrue(c.fold(f.win))
            self.assertIn('mb=unknown', out.getvalue())

if __name__ == '__main__':
    unittest.main()
