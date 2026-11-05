#!/usr/bin/env python3
# selftest-entry
"""Open identities remain enterable across machines, logins and search."""
import os
from pathlib import Path
import sys
import tempfile
import unittest
import contextlib
import io
import threading
import subprocess
import time
from types import SimpleNamespace
from unittest.mock import patch

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
import fleet_view as view
import fleet_park_cold as cold
import fleet_control as control

FID = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
OTHER = '11111111-2222-4333-8444-555555555555'


class Entry(unittest.TestCase):
    def test_board_uses_identity_even_when_key_recycled(self):
        for machine, login in [('remote', 'alice'), ('home', 'other')]:
            board = {'rows': [dict(id=FID, worker_id=OTHER + '/scratch-65',
                                  machine=machine, login=login, group='queue', tag='parked', title='kept')]}
            stale = dict(kind='sess', fid=OTHER, target=OTHER + '/scratch-65', far=True)
            groups = {g: [stale] if g == 'queue' else [] for g in view.GROUPS}
            out, _ = view.board_apply(board, groups, [], [], 'home', 'alice')
            rows = [e for g in view.GROUPS for e in out[g] if e.get('board') == FID]
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]['fid'], FID)
            self.assertEqual(rows[0]['target'], OTHER + '/' + FID)
            self.assertFalse(rows[0].get('record_only'))
            self.assertFalse(rows[0].get('ledger'))

    def test_local_identity_target_warms_without_special_row(self):
        with patch.object(view, 'windows', side_effect=[{}, {'@9': (FID, 'worker', 0, '')}]), \
                patch.object(cold, 'read', return_value={'fid': FID}), \
                patch.object(cold, 'warm', return_value=True) as warm:
            self.assertEqual(view.resolve('phone', OTHER + '/' + FID, {'fuid': OTHER}, 'test'), ('@9', False))
            warm.assert_called_once_with(FID)

    def test_cold_inventory_accepts_chat_by_identity(self):
        with patch.object(cold, 'records', return_value=[dict(fid=FID, session='test', agent='claude')]):
            row = control.cold_workers(dict(name='test', fleet_id=OTHER, agent='claude', repos=[]))[0]
        self.assertTrue(row['can_talk'])
        self.assertEqual(row['worker_id'], OTHER + '/' + FID)

    def test_take_restores_titles_before_consuming(self):
        with tempfile.TemporaryDirectory() as root, patch.dict(os.environ, FLEET_GATE_DIR=root):
            cold.gate.fid_dir(FID).mkdir(parents=True, exist_ok=True)
            cold.write(FID, dict(name_manual='chosen', task_line='original'))
            with patch.object(cold.gate, 'window', return_value=dict(sock='test', win='@9', fid=FID)), \
                    patch.object(cold.gate, 'tmux', return_value='') as tm:
                self.assertTrue(cold.take(FID))
                args = [c.args for c in tm.call_args_list]
                self.assertTrue(any('@name_manual' in c and 'chosen' in c for c in args))
                self.assertTrue(any('@task_line' in c and 'original' in c for c in args))

    def test_concurrent_enter_and_send_reopen_once(self):
        with tempfile.TemporaryDirectory() as root, patch.dict(os.environ, FLEET_GATE_DIR=root):
            cold.gate.fid_dir(FID).mkdir(parents=True, exist_ok=True)
            cold.write(FID, dict(session='test'))
            window, launches, results = [], [], []
            def spawn(*args, **kwargs):
                launches.append(args)
                time.sleep(.1)
                window.append(dict(park_held='1'))
                return SimpleNamespace(returncode=0, stdout='', stderr='')
            with patch.object(cold.gate, 'window', side_effect=lambda f: window[0] if window else None), \
                    patch.object(cold.subprocess, 'run', side_effect=spawn), patch.object(cold, 'gate_log'):
                threads = [threading.Thread(target=lambda: results.append(cold.warm(FID, wait=1))) for _ in range(2)]
                for t in threads:
                    t.start()
                for t in threads:
                    t.join(3)
            self.assertEqual(results, [True, True])
            self.assertEqual(len(launches), 1)

    def test_doctor_names_orphans_and_missing_worktrees(self):
        import fleet_id
        records = {FID: dict(opened={'title': 'orphan'}, closed=None),
                   OTHER: dict(opened={'title': 'cold'}, closed=None)}
        out = io.StringIO()
        with patch.object(fleet_id, 'ledger_ids', return_value=list(records)), \
                patch.object(fleet_id, 'read', side_effect=lambda f: records[f]), \
                patch.object(fleet_id, 'fold', side_effect=lambda r: r), \
                patch.object(cold.subprocess, 'run', return_value=SimpleNamespace(stdout='', returncode=0)), \
                patch.object(cold, 'read', side_effect=lambda f: None if f == FID else dict(worktree='/nonexistent/cold-worktree')), \
                contextlib.redirect_stdout(out):
            cold.doctor()
        self.assertIn(FID, out.getvalue())
        self.assertIn('no window or cold record', out.getvalue())
        self.assertIn('cold worktree missing', out.getvalue())
        self.assertIn('--exec --rebuild', out.getvalue())

    def test_legacy_cold_title_uses_manual_ledger_before_launch(self):
        import fleet_id
        with patch.object(fleet_id, 'read', return_value=[]), \
                patch.object(fleet_id, 'fold', return_value={'opened': dict(title='chosen', title_source='manual')}), \
                patch.object(cold, 'read', return_value=dict(fid=FID)), patch.object(cold.gate, 'tmux') as tm:
            cold.restore_titles(FID, 'test', '@9')
        self.assertEqual([c.args[-2:] for c in tm.call_args_list], [('@name_manual', 'chosen'), ('@task_line', 'chosen')])

    def test_cold_record_protects_worktree_without_window(self):
        with tempfile.TemporaryDirectory() as root, patch.dict(os.environ, FLEET_GATE_DIR=root):
            cold.gate.fid_dir(FID).mkdir(parents=True, exist_ok=True)
            cold.write(FID, dict(worktree=root + '/scratch-65'))
            for path, want in [(root + '/scratch-65', 0), (root + '/scratch-66', 1)]:
                p = subprocess.run([sys.executable, str(BIN / 'fleet_park_cold.py'),
                                    'protect-worktree', '--worktree', path], capture_output=True)
                self.assertEqual(p.returncode, want, p.stderr)

    def test_remote_message_warms_then_resolves_again(self):
        # The control receiver runs on the destination login, for SSH or relay.
        node = control.Control.__new__(control.Control)
        with patch.object(node, 'find_workers', side_effect=[([], {}), ([{'identity': FID}], {})]), \
                patch.object(cold, 'read', return_value=dict(session='test')), \
                patch.object(cold, 'warm', return_value=True) as warm:
            matches, _ = node.target(dict(name='test'), FID, 'worker_message')
        self.assertEqual(matches, [{'identity': FID}])
        warm.assert_called_once_with(FID)


if __name__ == '__main__':
    unittest.main()
