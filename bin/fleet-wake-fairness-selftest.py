#!/usr/bin/env python3
# selftest-entry
"""Drive fleet_wake_guard.py's queue ordering with locked tickets, no load/storm.
Two login directories share the existing flock queue. A frozen older waiter
must not be overtaken by its own class; a human may overtake a recent timer.
"""
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
import fleet_wake_guard as guard

class Fairness(unittest.TestCase):
    def test_same_class_keeps_arrival_order(self):
        for kind, why in (('human', '键盘'), ('timer', '定时')):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                ticket = root / (kind + '-older')
                with guard.shared_file(ticket) as older:
                    fcntl.flock(older, fcntl.LOCK_EX)
                    env = dict(os.environ, FLEET_WAKE_SLOT_DIR=tmp, FLEET_SESSION_WAKE_SLOTS='1',
                               FLEET_WAKE_ADMIT_CMD='true', PYTHONPATH=str(BIN))
                    code = ('import sys; from pathlib import Path; import fleet_wake_guard as g; '
                            'p=Path(sys.argv[1]); f=g.acquire(p,dict(fid="test",why=sys.argv[2],seed=str(p))); '
                            'p.write_text("acquired"); f.close()')
                    child = subprocess.Popen([sys.executable, '-c', code, str(root / 'younger'), why], env=env)
                    try:
                        time.sleep(.5)
                        self.assertFalse((root / 'younger').exists(), 'younger waiter overtook the locked older ticket')
                        older.close()
                        child.wait(timeout=5)
                        self.assertEqual(child.returncode, 0)
                        self.assertEqual((root / 'younger').read_text(), 'acquired')
                    finally:
                        if child.poll() is None:
                            child.terminate()
                        child.wait(timeout=5)

    def test_human_priority_is_bounded_and_dead_tickets_do_not_block(self):
        for age, should_wait in ((0, False), (90, True)):
            with self.subTest(timer_age=age), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                ticket = root / 'timer-older'
                with guard.shared_file(ticket) as older:
                    fcntl.flock(older, fcntl.LOCK_EX)
                    os.utime(ticket, (time.time() - age, time.time() - age))
                    env = dict(os.environ, FLEET_WAKE_SLOT_DIR=tmp, FLEET_SESSION_WAKE_SLOTS='1',
                               FLEET_WAKE_ADMIT_CMD='true', PYTHONPATH=str(BIN))
                    code = ('import sys; from pathlib import Path; import fleet_wake_guard as g; '
                            'p=Path(sys.argv[1]); f=g.acquire(p,dict(fid="test",why="键盘",seed=str(p))); '
                            'p.write_text("acquired"); f.close()')
                    child = subprocess.Popen([sys.executable, '-c', code, str(root / 'human')], env=env)
                    try:
                        time.sleep(.5)
                        self.assertEqual((root / 'human').exists(), not should_wait)
                        older.close()  # dead ticket remains on disk, never a permanent blocker
                        child.wait(timeout=5)
                        self.assertEqual(child.returncode, 0)
                    finally:
                        if child.poll() is None:
                            child.terminate()
                        child.wait(timeout=5)

    def test_deferred_delivery_preserves_queue_age(self):
        from unittest.mock import patch
        import fleet_session_gate as gate
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, FLEET_CONF_DIR=tmp):
            fid = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
            row = dict(fid=fid, delivery='timer', state='waking', text='original', images=[], tries=1)
            seed = gate.wake_path(fid, 'timer')
            gate.write_json(str(seed) + '.deferred', dict(retry_at=time.time() + 30,
                            deferred='memory', queued_at=12345))
            self.assertEqual(gate.wake_try(row, {})[0], 'queued')
            row.update(state='queued', wake_retry_at=time.time() - 1)
            w = dict(fid=fid, parked='1', wrap_ver='3', sock='fake', win='@1')
            with patch.object(gate, 'tmux', return_value=''), patch.object(gate, 'save'), \
                    patch.dict(os.environ, FLEET_GATE_WAKE_WAIT='0'):
                gate.wake_try(row, w)
            self.assertEqual(gate.read_json(str(seed) + '.meta')['queued_at'], 12345)

if __name__ == '__main__':
    unittest.main()
