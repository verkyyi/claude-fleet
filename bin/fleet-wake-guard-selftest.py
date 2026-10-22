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
from unittest.mock import patch
import importlib.util
import shutil

sys.path.insert(0, str(Path(__file__).resolve().parent))

BIN = Path(__file__).resolve().parent


class Storm(unittest.TestCase):
    def test_ten_logins_share_three_slots(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake = root / 'engine.py'
            fake.write_text('import sys,time,json\nfrom pathlib import Path\n'
                            'p=Path(sys.argv[1]); out=Path(sys.argv[2])\n'
                            'with out.open("a") as f: f.write(json.dumps(["start",time.time()])+"\\n")\n'
                            'time.sleep(.4)\n'
                            'with out.open("a") as f: f.write(json.dumps(["ready",time.time()])+"\\n")\n'
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


    def test_human_jumps_waiting_timer_and_dead_ticket_does_not_block(self):
        import fcntl
        import fleet_wake_guard as guard
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            env = dict(os.environ, FLEET_WAKE_SLOT_DIR=tmp, FLEET_SESSION_WAKE_SLOTS='1',
                       FLEET_WAKE_ADMIT_CMD='true')
            ticket = guard.shared_file(directory / 'human-test')
            fcntl.flock(ticket, fcntl.LOCK_EX)
            code = ('import sys,time; from pathlib import Path; import fleet_wake_guard as g; '
                    'p=Path(sys.argv[1]); m=dict(fid="aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",why=sys.argv[2]); '
                    'f=g.acquire(p,m); p.write_text("acquired"); time.sleep(.1); f.close()')
            env['PYTHONPATH'] = str(BIN)
            timer = subprocess.Popen([sys.executable, '-c', code, str(directory / 'timer'), '定时'], env=env)
            try:
                time.sleep(.3)
                self.assertFalse((directory / 'timer').exists())
                human = subprocess.run([sys.executable, '-c', code, str(directory / 'human'), '键盘'],
                                       env=env, timeout=5)
                self.assertEqual(human.returncode, 0)
                self.assertTrue((directory / 'human').exists())
                self.assertFalse((directory / 'timer').exists())
                ticket.close()  # Simulate a dead waiter: stale filename, no lock.
                timer.wait(timeout=5)
                self.assertEqual(timer.returncode, 0)
                self.assertTrue((directory / 'timer').exists())
            finally:
                ticket.close()
                if timer.poll() is None:
                    timer.kill()
                timer.wait()


class Recovery(unittest.TestCase):
    def fixture(self, memory=False):
        if not shutil.which('tmux'):
            self.skipTest('tmux absent')
        spec = importlib.util.spec_from_file_location('guard_fixture', BIN / 'fleet-park-selftest.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        f = module.Park('runTest')
        f.setUp()
        self.addCleanup(f.doCleanups)
        if memory:
            admit = f.root / 'admit'
            admit.write_text('#!/bin/sh\nexit 1\n')
            admit.chmod(0o755)
            f.env['FLEET_WAKE_ADMIT_CMD'] = str(admit)
        f.fake()
        return f, module.gate

    def test_two_failed_resumes_keep_words_and_disable_reparking(self):
        f, gate = self.fixture()
        with patch.dict(os.environ, f.env):
            self.assertTrue(gate.park(f.fid)['ok'])
        (f.root / 'fail').touch()
        f.tm('send-keys', '-t', f.win, '-l', 'keep this sentence')
        f.tm('send-keys', '-t', f.win, 'Enter')
        health = f.root / 'conf/session-gate' / f.fid / 'park-health.json'
        f.wait(lambda: health.exists() and json.loads(health.read_text()).get('failures') == 1)
        f.wait(lambda: '接回失败' in f.tm('capture-pane', '-p', '-t', f.win))
        f.tm('send-keys', '-t', f.win, 'Enter')
        f.wait(lambda: json.loads(health.read_text()).get('disabled'))
        f.wait(lambda: '接回失败' in f.tm('capture-pane', '-p', '-t', f.win))
        (f.root / 'fail').unlink()
        f.tm('send-keys', '-t', f.win, 'Enter')
        f.wait(lambda: f.opt('@park_relay') and not f.opt('@park_held'))
        f.wait(lambda: json.loads(health.read_text()).get('failures') == 0)
        with patch.dict(os.environ, f.env):
            self.assertEqual(gate.park(f.fid).get('why'), 'wake_failures')
        args = json.loads((f.root / 'argv').read_text().splitlines()[-1])
        self.assertEqual(args[-1], 'keep this sentence')
        self.assertIn(f.sid, args)

    def test_version_rejection_offers_new_chat_with_reason_and_words(self):
        f, gate = self.fixture()
        launch = f.root / 'launch'
        launch.write_text(launch.read_text().replace('echo resume-failed', 'echo "unsupported session version"'))
        with patch.dict(os.environ, f.env):
            self.assertTrue(gate.park(f.fid)['ok'])
        (f.root / 'fail').touch()
        f.tm('send-keys', '-t', f.win, '-l', 'saved version question')
        f.tm('send-keys', '-t', f.win, 'Enter')
        f.wait(lambda: '版本不兼容' in f.tm('capture-pane', '-p', '-t', f.win))
        (f.root / 'fail').unlink()
        f.tm('send-keys', '-t', f.win, 'n')
        f.wait(lambda: f.opt('@park_relay') and not f.opt('@park_held'))
        args = json.loads((f.root / 'argv').read_text().splitlines()[-1])
        self.assertNotIn('--resume', args)
        self.assertEqual(args[-1], 'saved version question')
        self.assertEqual(f.opt('@fleet_id'), f.fid)

    def test_hung_start_is_stopped_before_retry_and_words_survive(self):
        f, gate = self.fixture()
        with patch.dict(os.environ, f.env):
            self.assertTrue(gate.park(f.fid)['ok'])
        fake = f.root / 'fake.py'
        source = fake.read_text()
        self.assertIn('state=idle:app=', source, 'fixture no longer exposes its initial ready report')
        fake.write_text(source.replace('state=idle:app=', 'state=starting:app='))
        f.tm('send-keys', '-t', f.win, '-l', 'keep hung prompt')
        f.tm('send-keys', '-t', f.win, 'Enter')
        f.wait(lambda: f.opt('@park_error') == 'wake_timeout')
        f.wait(lambda: '接回失败' in f.tm('capture-pane', '-p', '-t', f.win))
        self.assertFalse(f.opt('@park_relay'))
        self.assertIn('keep hung prompt', f.tm('capture-pane', '-p', '-t', f.win))

    def test_timer_defers_without_losing_delivery_or_counting_failure(self):
        import fleet_park_wake as wake
        f, gate = self.fixture(memory=True)
        admit = f.root / 'admit'
        with patch.dict(os.environ, f.env):
            self.assertTrue(gate.park(f.fid)['ok'])
            wake.save(wake.path_for(f.fid), dict(v=1, fid=f.fid, sid=f.sid, agent='claude',
                phase='active', parked=True, jobs=[dict(id='timer', kind='wakeup', prompt='timer original',
                                                     next=123, recurring=False)]))
            wake.tick(f.fid)
            f.wait(lambda: f.opt('@park_held'))
            record = gate.records(f.fid)[0]
            gate.settle(f.fid, record['delivery'])
            record = gate.records(f.fid)[0]
            self.assertEqual(record['state'], 'queued')
            self.assertEqual(record['text'], 'timer original')
            self.assertEqual(record['wake_next'], 123)
            self.assertEqual(record['why'], 'memory')
            self.assertFalse((gate.fid_dir(f.fid) / 'park-health.json').exists())
            # Memory pressure can outlast the web-message TTL. The timer's
            # original prompt still belongs to this delivery when it recovers.
            record['at'] = time.time() - 3600
            with gate.lock(f.fid):
                gate.save(record)
            gate.settle(f.fid, record['delivery'])
            self.assertEqual(gate.records(f.fid)[0]['state'], 'queued')
            admit.write_text('#!/bin/sh\nexit 0\n')
            with gate.lock(f.fid):
                record['wake_retry_at'] = time.time() - 1
                gate.save(record)
            gate.settle(f.fid, record['delivery'])
            f.wait(lambda: f.opt('@park_relay') and not f.opt('@park_held'))
            gate.settle(f.fid, record['delivery'])
            self.assertEqual(gate.records(f.fid)[0]['state'], 'sent', gate.records(f.fid)[0])
            wake.tick(f.fid)
            contract = json.loads(wake.path_for(f.fid).read_text())
            self.assertNotIn('pending', contract)
            self.assertIsNone(contract['jobs'][0]['next'])


if __name__ == '__main__':
    unittest.main()
