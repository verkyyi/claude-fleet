#!/usr/bin/env python3
# selftest-entry
"""Controlled tasks safely park; legacy result/PR/retention cannot archive them."""
import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
spec = importlib.util.spec_from_file_location('reap_rig', BIN / 'fleet-cleanup-idle-selftest.py')
rig = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rig)
idle = rig.idle
import fleet_task_execution as execution
import fleet_session_gate as gate

GRANT = json.loads((BIN.parent / 'tokenledger/hub/store/testdata/task_execution.json').read_text())
FID = GRANT['execution_owner'].split('/')[1]


class RealControlledReap(rig.Rig):
    def test_old_result_and_unknown_marker_keep_real_window_and_history(self):
        answer = self.root / 'closed'
        answer.write_text('#!/bin/sh\necho SUCCEEDED\nexit 0\n')
        answer.chmod(0o755)
        self.env['FLEET_TASK_CLOSED_CMD'] = str(answer)
        for key, value in (('@task', 'T42'), ('@task_flow', '1'), ('@reap_policy', 'merged'),
                           ('@reap_origin', 'driver'), ('@task_execution', '{unknown'),
                           ('@claude_state', 'done')):
            self.set(key, value)
        before = (self.root / 'ledger.tsv').read_bytes() if (self.root / 'ledger.tsv').exists() else None
        self.clean('--grace', '0')
        if self.exists():
            self.set('@reap_due', '1')
            self.clean('--grace', '0')
        self.assertTrue(self.exists(), 'old Outcome/driver archived a controlled window')
        after = (self.root / 'ledger.tsv').read_bytes() if (self.root / 'ledger.tsv').exists() else None
        self.assertEqual(before, after, 'automatic retention wrote completion history')
        self.assertTrue(self.wt.is_dir())


class ControlledRetention(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='controlled-retention-')
        self.addCleanup(self.tmp.cleanup)
        self.env = patch.dict(os.environ, {'FLEET_CONF_DIR': self.tmp.name})
        self.env.start()
        self.addCleanup(self.env.stop)
        args = argparse.Namespace(socket_name='isolated', session='isolated', main='/missing', repo='o/r',
                                  base='master', window_repo=False, dry_run=False, skip_park=False, grace=0)
        self.c = idle.Cleaner(args)
        self.c.now, self.c._mem, self.c._park_watched = 1000000, (False, ''), set()
        with patch.object(self.c, 'tm', return_value=''):
            self.snap = self.c.snapshot('@9')
        self.snap.update({'@task_execution': json.dumps(GRANT), '@fleet_id': FID, '@task': GRANT['task_ref'],
                          '@raw': '1', '@task_flow': '1', '@repo': 'o/r', '@park_wrap_ver': '1',
                          '@claude_state': 'done', '@claude_state_ts': '100', '@worktree': '/tmp/task-scratch-7'})

    def test_every_old_policy_only_asks_existing_park_gate(self):
        for origin in ('person', 'dispatched', 'member', 'driver', 'orchestrator', 'web', 'probe'):
            for policy in ('merged', 'idle:2h', 'done:1m', 'loop-end', 'keep'):
                snap = dict(self.snap, **{'@reap_origin': origin, '@reap_policy': policy})
                with self.subTest(origin=origin, policy=policy), patch.object(self.c, 'work_over', return_value=True), \
                     patch.object(self.c, 'tm', return_value=''), patch.object(idle, 'run', return_value='{"ok":true}') as call, \
                     patch.object(self.c, 'close', side_effect=AssertionError('archived')), contextlib.redirect_stdout(io.StringIO()):
                    self.assertTrue(self.c.road('@9', snap))
                    self.assertEqual(call.call_count, 1)
                    self.assertEqual(call.call_args.args[-4:], ('--fid', FID, '--why', 'idle'))
                    self.assertNotIn('--force', call.call_args.args)

    def test_parked_expiry_missing_wrapper_and_refused_park_never_fall_through(self):
        for changes in ({'@parked': '100', '@park_held': '1', '@park_since': '100'}, {'@park_wrap_ver': ''}):
            snap = dict(self.snap, **changes, **{'@reap_origin': 'person', '@reap_policy': 'idle:2h'})
            with self.subTest(changes=changes), patch.object(self.c, 'close', side_effect=AssertionError('archived')), \
                 patch.object(idle, 'run') as call:
                self.assertFalse(self.c.road('@9', snap))
                call.assert_not_called()
        for reason in ('asking', 'bg', 'draft', 'watched', 'wake_contract', 'probe_failed'):
            with self.subTest(reason=reason), patch.object(self.c, 'tm', return_value=''), \
                 patch.object(idle, 'run', return_value=json.dumps({'ok': False, 'why': reason})), \
                 patch.object(self.c, 'close', side_effect=AssertionError('archived')):
                self.assertFalse(self.c.road('@9', self.snap))

    def test_final_close_and_norepo_recheck_after_selection(self):
        before = dict(self.snap, **{'@task_execution': '', '@task': ''})
        for entry in ('close', 'stop_norepo'):
            with self.subTest(entry=entry), tempfile.TemporaryDirectory(prefix='close-boundary-') as root, \
                 patch.dict(os.environ, {'FLEET_CONF_DIR': root}), patch.object(self.c, 'snapshot', return_value=before), \
                 patch.object(self.c, 'moved', return_value=False), patch.object(self.c, 'busy', return_value=False), \
                 patch.object(gate, 'lock', return_value=contextlib.nullcontext()), patch.object(gate, 'close_hold', return_value=''), \
                 patch.object(self.c, 'transition', return_value='lock'), patch.object(self.c, 'untransition'), \
                 patch.object(self.c, 'shared', return_value=''), patch.object(self.c, 'retire') as retired, \
                 patch.object(self.c, 'tm') as tm, patch.object(self.c, 'end_id') as ended, \
                 patch.object(idle.subprocess, 'run') as stopped:
                # Binding appears only after selection; the mark remains absent.
                def becomes_controlled(*_):
                    execution.ExecutionFence(root).bind(GRANT, authorized=True)
                    return True
                with patch.object(self.c, 'final_live', side_effect=becomes_controlled):
                    if entry == 'close':
                        self.assertFalse(self.c.close('@9', before, lambda: True))
                    else:
                        self.assertEqual(self.c.stop_norepo('@9', before), '')
                retired.assert_not_called()
                ended.assert_not_called()
                stopped.assert_not_called()
                self.assertFalse(any(call.args and call.args[0] == 'kill-window' for call in tm.call_args_list))

    def test_local_current_stopped_marker_and_unknown_all_retain(self):
        self.assertFalse(execution.automatic_close_held(FID, conf_dir=self.tmp.name))
        for marker in ('{}', '{unknown', 'null'):
            self.assertTrue(execution.automatic_close_held(FID, marker, conf_dir=self.tmp.name))
        fence = execution.ExecutionFence(self.tmp.name)
        fence.bind(GRANT, authorized=True)
        self.assertTrue(execution.automatic_close_held(FID, conf_dir=self.tmp.name))
        stopped = dict(GRANT, generation=GRANT['generation']+1, cancel_request='explicit-stop')
        fence.apply_stop(stopped)
        self.assertTrue(execution.automatic_close_held(FID, conf_dir=self.tmp.name))
        with patch.object(execution, 'read_session', side_effect=execution.FenceRefused('unavailable')):
            self.assertTrue(execution.automatic_close_held(FID, conf_dir=self.tmp.name))


if __name__ == '__main__':
    unittest.main()
