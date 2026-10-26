#!/usr/bin/env python3
# selftest-entry
"""Exercise real processes: stale locks, timeout descendants, and cache retention."""
import fcntl
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
import fleet_view as v

class Gone(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name) / 'gone'
        self.env = patch.dict(os.environ, FLEET_VIEW_GONE_TIMEOUT='1',
                              FLEET_VIEW_GONE_RETRY_SECS='60')
        self.env.start()
        self.path = patch.object(v, 'gone_file', return_value=self.out)
        self.path.start()
    def tearDown(self):
        self.path.stop()
        self.env.stop()
        self.tmp.cleanup()
    def wait_unlocked(self):
        for _ in range(100):
            if not Path(str(self.out)+'.lock').exists():
                return
            time.sleep(.05)
        self.fail('worker did not release lock')
    def test_timeout_kills_descendants_and_keeps_cache(self):
        self.out.write_text('previous')
        pidfile = Path(self.tmp.name) / 'pid'
        os.environ['FLEET_VIEW_LANDED_CMD'] = f'sleep 100 & echo $! > {pidfile}; wait'
        try:
            self.assertTrue(v.gone_read('f', wait=False))
            for _ in range(100):
                if pidfile.exists(): break
                time.sleep(.01)
            self.assertTrue(pidfile.exists())
            lock = Path(str(self.out)+'.lock')
            os.utime(lock, (time.time()-700,)*2)
            self.assertFalse(v.gone_read('f', wait=False), 'live stale lock stolen')
            self.wait_unlocked()
            self.assertEqual(self.out.read_text(), 'previous')
            state = subprocess.run(['ps', '-p', pidfile.read_text().strip(), '-o', 'stat='],
                                   capture_output=True, text=True).stdout.strip()
            self.assertTrue(not state or state.startswith('Z'), state)
            self.assertFalse(v.gone_read('f'), 'failed refresh did not back off')
            self.assertFalse(list(self.out.parent.glob('gone.[0-9]*')))
        finally:
            os.environ.pop('FLEET_VIEW_LANDED_CMD', None)
    def test_success_and_dead_lock_recovery(self):
        lock=Path(str(self.out)+'.lock'); lock.mkdir()
        os.utime(lock, (time.time()-700,)*2)
        with patch.dict(os.environ, FLEET_VIEW_LANDED_CMD='printf fresh'):
            self.assertTrue(v.gone_read('f'))
            self.assertEqual(self.out.read_text(), 'fresh')
            self.assertTrue(v.gone_read('f'), 'success should not impose failure backoff')
        with patch.dict(os.environ, FLEET_VIEW_LANDED_CMD='printf partial; exit 1'):
            self.assertTrue(v.gone_read('f'))
            self.assertEqual(self.out.read_text(), 'fresh')

if __name__ == '__main__': unittest.main()
