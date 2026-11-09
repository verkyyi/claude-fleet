#!/usr/bin/env python3
# selftest-entry
"""Bounded, sleeping fixtures: seven login namespaces, slow ps, 1200 rows.
No CPU burners, real fleet sockets, schedulers or user homes are touched.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))


class Periodic(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fleet-periodic-", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = dict(os.environ, FLEET_PS_CACHE_DIR=str(self.root / 'machine'),
                        FLEET_JOB_LOCK_DIR=str(self.root / 'locks'))
        self.procs = []
        self.addCleanup(self.stop)

    def stop(self):
        for p in self.procs:
            if p.poll() is None: p.kill()
            p.communicate(timeout=10)

    def start(self, *args, env=None):
        p = subprocess.Popen([sys.executable, *map(str, args)], env=env or self.env,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.procs.append(p)
        return p

    def fake_ps(self):
        fake = self.root / 'ps'
        # Header offsets exercise comm/command containing spaces, on both OSes.
        fake.write_text('#!' + sys.executable + '\nimport time\n'
                        f'with open({str(self.root / "scans")!r}, "a") as f: f.write("scan\\n")\n'
                        'time.sleep(0.6)\n'
                        'print("PID PPID UID PGID STAT RSS %CPU ELAPSED TIME STARTED TTY".ljust(90) + "COMM".ljust(20) + "COMMAND")\n'
                        'for i in range(1200):\n'
                        ' prefix = f"{i+1} 1 501 1 S 100 0.0 00:01 0:00.00 Mon Nov  9 00:00:00 2026 ?? "\n'
                        ' # Real ps aligns every row to the header, including numeric widths.\n'
                        ' print(prefix.ljust(90) + "/app/my process".ljust(20) + "worker --name hello world")\n')
        fake.chmod(0o755)
        self.env['FLEET_PS_COMMAND'] = str(fake)

    def test_seven_logins_slow_scan(self):
        self.fake_ps()
        # One admitted run per login; duplicate ticks must exit before the slow job.
        body = ('import os,time,sys; sys.path.insert(0,sys.argv[1]); '
                'from fleet_ps import rows; '
                'open(sys.argv[2],"a").write("start\\n"); '
                '\ntry: rows("pid,uid,command")\nexcept OSError: pass\n'
                'time.sleep(1.0)')
        for login in range(7):
            env = dict(self.env, FLEET_JOB_LOCK_DIR=str(self.root / str(login)))
            for _ in range(3):
                self.start(BIN / 'fleet_tick_lock.py', 'run', 'cleanup', sys.executable,
                           '-c', body, BIN, self.root / f'run-{login}', env=env)
        results = [p.communicate(timeout=15) for p in self.procs]
        self.assertTrue(all(p.returncode == 0 for p in self.procs), results)
        self.assertEqual(sum('skip: busy cleanup' in err for _, err in results), 14)
        for login in range(7):
            self.assertEqual((self.root / f'run-{login}').read_text(), 'start\n')
        self.assertEqual((self.root / 'scans').read_text().splitlines(), ['scan'])
        p = self.start(BIN / 'fleet_ps.py', 'pid,uid,command')
        out, err = p.communicate(timeout=5)
        self.assertEqual(p.returncode, 0, err)
        self.assertEqual(len(out.splitlines()), 1200)
        self.assertIn('501 worker --name hello world', out)
        self.assertEqual((self.root / 'scans').read_text().splitlines(), ['scan'])

    def test_fresh_sample_survives_slow_publisher_refresh(self):
        self.fake_ps()
        first = self.start(BIN / 'fleet_ps.py', 'pid')
        first.communicate(timeout=5)
        self.assertEqual(first.returncode, 0)
        publisher = self.start(BIN / 'fleet_ps.py', '--publish')
        deadline = time.monotonic() + 3
        while len((self.root / 'scans').read_text().splitlines()) < 2 and time.monotonic() < deadline:
            time.sleep(0.01)
        reader = self.start(BIN / 'fleet_ps.py', 'pid')
        out, err = reader.communicate(timeout=5)
        self.assertEqual(reader.returncode, 0, err)
        self.assertEqual(len(out.splitlines()), 1200)
        publisher.communicate(timeout=5)
        self.assertEqual(publisher.returncode, 0)
        self.assertEqual(len((self.root / 'scans').read_text().splitlines()), 2)

    def test_expiry_and_failed_refresh(self):
        self.fake_ps()
        def read():
            p = self.start(BIN / 'fleet_ps.py', 'pid,comm')
            return p, p.communicate(timeout=5)
        p, _ = read()
        self.assertEqual(p.returncode, 0)
        cache = next((self.root / 'machine').glob('*.json'))
        import json
        value = json.loads(cache.read_text()); value['at'] -= 6
        cache.write_text(json.dumps(value))
        p, (out, _) = read()
        self.assertEqual(p.returncode, 0)
        self.assertIn('/app/my process', out)
        self.assertEqual(len((self.root / 'scans').read_text().splitlines()), 2)
        value = json.loads(cache.read_text()); value['at'] -= 6
        cache.write_text(json.dumps(value))
        (self.root / 'ps').write_text('#!/bin/sh\nexit 1\n')
        p, _ = read()
        self.assertNotEqual(p.returncode, 0)
        # A failed producer is rate-limited too, even if ps immediately recovers.
        self.fake_ps()
        p, _ = read()
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(len((self.root / 'scans').read_text().splitlines()), 2)

    def test_killed_owner_releases_lock(self):
        marker = self.root / 'started'
        p = self.start(BIN / 'fleet_tick_lock.py', 'run', 'job', sys.executable, '-c',
                       'import pathlib,time,sys; pathlib.Path(sys.argv[1]).touch(); time.sleep(8)', marker)
        deadline = time.monotonic() + 5
        while not marker.exists() and time.monotonic() < deadline: time.sleep(0.01)
        self.assertTrue(marker.exists())
        p.kill(); p.communicate(timeout=5)
        next_run = self.start(BIN / 'fleet_tick_lock.py', 'run', 'job', sys.executable, '-c', 'print("ran")')
        out, err = next_run.communicate(timeout=5)
        self.assertEqual((next_run.returncode, out), (0, 'ran\n'), err)

    def test_real_format(self):
        # Actual OS format, signed Darwin nobody UID, long comm, lstart spacing.
        p = self.start(BIN / 'fleet_ps.py', 'pid,uid,lstart,comm')
        out, err = p.communicate(timeout=15)
        self.assertEqual(p.returncode, 0, err)
        self.assertTrue(any(line.startswith(str(os.getpid()) + ' ') for line in out.splitlines()))

    def test_seven_real_uids_read_one_root_snapshot(self):
        import shutil
        if os.geteuid() != 0:
            sudo = shutil.which('sudo')
            if not sudo or subprocess.run([sudo, '-n', 'true'], capture_output=True).returncode:
                self.skipTest('cross-UID publisher requires noninteractive sudo (CI runs it)')
            p = subprocess.run([sudo, '-n', sys.executable, __file__,
                                'Periodic.test_seven_real_uids_read_one_root_snapshot'],
                               capture_output=True, text=True, timeout=20)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            return
        self.root.chmod(0o755)
        self.fake_ps()
        code = self.root / 'bin'; code.mkdir()
        for name in ('fleet_ps.py', 'fleet_tick_lock.py'):
            shutil.copyfile(BIN / name, code / name)
        p = self.start(code / 'fleet_ps.py', '--publish')
        _, err = p.communicate(timeout=5)
        self.assertEqual(p.returncode, 0, err)
        readers = []
        for uid in range(90001, 90008):
            def demote(uid=uid):
                os.setgroups([]); os.setgid(uid); os.setuid(uid)
            p = subprocess.Popen([sys.executable, str(code / 'fleet_ps.py'), 'pid,uid'],
                                 env=self.env, preexec_fn=demote, text=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.procs.append(p); readers.append(p)
        for p in readers:
            out, err = p.communicate(timeout=5)
            self.assertEqual(p.returncode, 0, err)
            self.assertEqual(len(out.splitlines()), 1200)
        self.assertEqual((self.root / 'scans').read_text().splitlines(), ['scan'])
        # With the root sample stale, tenant readers must NOT start fallback ps.
        import json
        sample = self.root / 'machine/0.json'
        data = json.loads(sample.read_text()); data['at'] = 0
        sample.write_text(json.dumps(data))
        p = subprocess.Popen([sys.executable, str(code / 'fleet_ps.py'), 'pid'], env=self.env,
                             preexec_fn=demote, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.procs.append(p); p.communicate(timeout=5)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual((self.root / 'scans').read_text().splitlines(), ['scan'])

    def test_privileged_trial_action_rechecks_current_uid(self):
        from unittest.mock import patch
        import fleet_trial
        with patch.dict(os.environ, FLEET_TRIAL_PS_CMD=''), \
                patch.object(fleet_trial.subprocess, 'check_output', return_value='456 9002\n'), \
                patch.object(fleet_trial.os, 'kill') as signal:
            result = fleet_trial.act(9001, 'pause', [(456, 9001, 99, 100, 'worker', 'worker')])
            self.assertEqual(result['done'], 0)
            signal.assert_not_called()
        with patch.dict(os.environ, FLEET_TRIAL_PS_CMD='fixture'), \
                patch.object(fleet_trial, 'ps_rows', return_value=[(456, 9001, 99, 100, 'worker', 'worker')]), \
                patch.object(fleet_trial.os, 'kill') as signal:
            result = fleet_trial.act(9001, 'pause', [(456, 9001, 99, 100, 'worker', 'worker')])
            self.assertEqual(result['done'], 1)
            signal.assert_called_once()

    def test_entrypoints(self):
        scripts = ['fleet-control-read.sh', 'fleet-cleanup-daemon.sh', 'fleet-reconcile-tick.sh', 'fleet-diskguard.sh',
                   'fleet-memguard.sh', 'tmux-dash-collect.sh', 'fleet-base-sync.sh',
                   'fleet-install-sync.sh', 'fleet-ledger-watch.sh', 'worktree-autoclean.sh']
        for script in scripts:
            self.assertIn('fleet_job_guard', (BIN / script).read_text(), script)


if __name__ == '__main__': unittest.main()
