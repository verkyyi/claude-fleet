#!/usr/bin/env python3
# selftest-entry
"""Task defaults and automatic retention do not depend on role or list pin."""
import argparse
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
import fleet_reap_policy as rp
spec = importlib.util.spec_from_file_location('reap_rig', BIN / 'fleet-cleanup-idle-selftest.py')
rig = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rig)
idle = rig.idle
ROLES = ('person', 'dispatched', 'member', 'driver', 'orchestrator', 'decide', 'web')


class TaskDefaults(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='task-defaults-')
        self.addCleanup(self.tmp.cleanup)
        env = patch.dict(os.environ, {'FLEET_CONF_DIR': self.tmp.name})
        env.start()
        self.addCleanup(env.stop)

    def test_all_normal_origins_and_kinds_share_default(self):
        for origin in ROLES:
            for kind in ('task', 'scratch', 'issue', 'loop'):
                with self.subTest(origin=origin, kind=kind):
                    self.assertEqual(rp.origin_default(origin, kind), 'idle:2h')
                    self.assertEqual(rp.origin_of('epic-driver', 'old-parent', 'remote/fid', stamp=origin), 'person')
        self.assertEqual(rp.origin_default('probe'), 'done:1m')
        self.assertEqual(rp.origin_of(test_identity='1'), 'probe')
        self.assertEqual(rp.origin_of(title='probe 可关'), 'person')

    def test_pin_and_agent_cannot_override_existing_policy(self):
        for policy in ('', 'merged', 'done:15m', 'loop-end', 'keep', 'idle:2h'):
            for agent in ('', 'orchestrator', 'fleet-epic:epic-driver'):
                for pin in ('', '1'):
                    self.assertEqual(rp.effective(policy, pin, agent, 'session', True), policy)
        snap = {'@park_wrap_ver':'1', '@parked':'100', '@park_held':'1', '@park_since':'100'}
        due = rp.parked_deadline(snap)
        for origin in ROLES:
            self.assertEqual(rp.parked_deadline(dict(snap, **{'@pin':'1', '@reap_origin':origin})), due)
        self.assertIsNone(rp.parked_deadline(dict(snap, **{'@reap_policy':'keep'})))

    def cleaner(self):
        c = idle.Cleaner(argparse.Namespace(socket_name='test', session='test', main='/tmp/base', repo='o/r',
                         base='master', window_repo=False, dry_run=False, skip_park=False, grace=0))
        c.now, c._mem = 10000, (False, '')
        with patch.object(c, 'tm', return_value=''):
            snap = c.snapshot('@9')
        snap.update({'@raw':'1', '@task_flow':'', '@task':'T42', '@fleet_id':'00000042-0000-4000-8000-000000000042',
                     '@claude_state':'done', '@claude_state_ts':'100', '@worktree':'/tmp/task-scratch-7', '@repo':'o/r',
                     '@reap_policy':'merged', '@reap_origin':'driver', '@agent_def':'epic-driver'})
        return c, snap

    def test_old_result_never_gives_driver_a_loop_or_bg_bypass(self):
        c, snap = self.cleaner()
        with patch.object(c, 'work_over', return_value=True), patch.object(c, 'busy', return_value=True), \
             patch.object(c, 'eligible', return_value=True), patch.object(c, 'reopens', return_value=True), \
             patch.object(c, 'close', return_value=True) as close, patch.object(c, 'tm', return_value=''), \
             patch.object(idle, 'run', return_value=''), patch.object(idle, 'notice', return_value=0), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertFalse(c.road('@9', snap))
            close.assert_not_called()

    def test_missing_result_never_marks_or_closes_unreported(self):
        c, snap = self.cleaner()
        snap['@reap_origin'] = 'dispatched'
        with patch.object(c, 'work_over', return_value=False), patch.object(c, 'waiting', return_value=None), \
             patch.object(c, 'task_closed', return_value=1), patch.object(c, 'busy', return_value=False), \
             patch.object(c, 'tm', return_value='') as tm, patch.object(c, 'close') as close, \
             contextlib.redirect_stdout(io.StringIO()):
            c.road('@9', snap)
            self.assertFalse(any('@reap_unreported' in call.args for call in tm.call_args_list))
            close.assert_not_called()

    def test_pressure_order_is_native_idle_age_not_result_pin_or_role(self):
        c, snap = self.cleaner()
        snap['@park_wrap_ver'] = '1'
        with patch.object(c, 'work_over', side_effect=AssertionError('history consulted')):
            for role in ROLES:
                for pin in ('', '1'):
                    got = c.room_tier('@9', dict(snap, **{'@reap_origin':role, '@pin':pin}), set(), '')
                    self.assertEqual(got, 1)
        self.assertIsNone(c.room_tier('@9', dict(snap, **{'@fleet_role':'panel'}), set(), ''))


class RealPinRetention(rig.Rig):
    def test_pin_never_writes_keep_or_migrates_old_policy(self):
        self.set('@pin', '1')
        self.set('@claude_state', 'working')
        self.clean()
        self.assertEqual(self.tm('show-option', '-wqv', '-t', self.win, '@reap_policy').strip(), '')
        self.assertFalse((self.root / 'conf/global/pin-keep.done').exists())
        self.set('@reap_policy', 'keep')
        self.set('@agent_def', 'orchestrator')
        self.clean()
        self.assertEqual(self.tm('show-option', '-wqv', '-t', self.win, '@reap_policy').strip(), 'keep')
        self.assertTrue(self.exists())


if __name__ == '__main__':
    unittest.main()
