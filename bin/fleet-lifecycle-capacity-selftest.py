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
        f.tm('set-option', '-w', '-t', 'test:0', '@fleet_role', 'home')
        f.fake()
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
        with patch.dict(os.environ, f.env):
            self.assertTrue(park.gate.park(f.fid)['ok'])
            self.assertEqual(self.counts(f), ['0', '0'])
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
                with patch.dict(os.environ, f.env):
                    c = self.cleaner(f)
                    self.assertEqual(c.room_tier(f.win, c.snapshot(f.win), set(), ''), 1)
                    self.assertTrue(c.fold(f.win))
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

if __name__ == '__main__':
    unittest.main()
