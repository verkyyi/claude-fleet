#!/usr/bin/env python3
# selftest-entry
"""Drive fleet_wake_guard.py (the wrapper's launch gate) with ten fake engines.
Separate login dirs share machine slots; no real agent, fleet socket or memory load.
BREAK-IT adds bounded load through fleet-loadgen.sh, never a background burn loop.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

BIN = Path(__file__).resolve().parent


class Storm(unittest.TestCase):
    def test_ten_logins_share_three_slots(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake = root / 'engine.py'
            fake.write_text('import sys,time,json\nfrom pathlib import Path\n'
                            'p=Path(sys.argv[1]); out=Path(sys.argv[2])\n'
                            'with out.open("a") as f: f.write(json.dumps(["start",time.monotonic()])+"\\n")\n'
                            'time.sleep(.4)\n'
                            'with out.open("a") as f: f.write(json.dumps(["ready",time.monotonic()])+"\\n")\n'
                            'Path(str(p)+".launched").touch()\n'
                            'p.with_suffix(".meta").unlink(missing_ok=True)\n')
            children = []
            start = time.monotonic()
            try:
                for i in range(10):
                    home = root / str(i)
                    home.mkdir()
                    seed = home / 'wake.txt'
                    meta = Path(str(seed) + '.meta')
                    meta.write_text(json.dumps(dict(fid='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',
                                                   why='定时', seed=str(seed), started=time.time())))
                    env = dict(os.environ, FLEET_CONF_DIR=str(home), FLEET_WAKE_SLOT_DIR=str(root / 'slots'),
                               FLEET_WAKE_ADMIT_CMD='true', FLEET_SESSION_WAKE_SLOTS='3')
                    children.append(subprocess.Popen([sys.executable, str(BIN / 'fleet_wake_guard.py'),
                        'run', '--meta', str(meta), '--', sys.executable, str(fake), str(seed), str(root / 'events')],
                        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
                for child in children:
                    stdout, stderr = child.communicate(timeout=60)
                    self.assertEqual(child.returncode, 0, stdout + stderr)
            finally:
                for child in children:
                    if child.poll() is None:
                        child.kill()
                    child.wait()
            elapsed = time.monotonic() - start
            active = peak = ready = 0
            for event, _ in sorted((json.loads(s) for s in (root / 'events').read_text().splitlines()), key=lambda r: r[1]):
                active += 1 if event == 'start' else -1
                peak = max(peak, active)
                ready += event == 'ready'
            self.assertEqual(ready, 10)
            self.assertLessEqual(peak, 3)
            self.assertGreater(peak, 1)
            self.assertLessEqual(elapsed, 60)
            print('wake-storm: ready=%d peak=%d elapsed=%.2fs' % (ready, peak, elapsed))


if __name__ == '__main__':
    unittest.main()
