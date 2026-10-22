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
                human = subprocess.run([sys.executable, '-c', code, str(directory / 'human'), '⌘P'],
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
    def fixture(self, memory=False, preflight=False, agent="claude"):
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
        if preflight:
            version = f.root / 'version'
            version.write_text('#!/bin/sh\necho 3.0.0\n')
            version.chmod(0o755)
            f.env['FLEET_PARK_VERSION_CMD'] = str(version)
            f.env['FLEET_CC_PROJECTS_DIR'] = str(f.root / 'projects')
        f.fake(agent)
        return f, module.gate

    def test_codex_timer_launcher_failure_needs_this_launch_receipt(self):
        import fleet_park_wake as wake
        f, gate = self.fixture(agent='codex')
        launch = f.root / 'launch'
        launch.write_text(launch.read_text().replace('echo resume-failed; exit 1;',
            'echo "loop bridge already exists"; '
            'while [ ! -f "' + str(f.root / 'release') + '" ]; do sleep .05; done; exit 1;'))
        with patch.dict(os.environ, dict(f.env, FLEET_GATE_WAKE_WAIT='0')):
            self.assertTrue(gate.park(f.fid)['ok'])
            (f.root / 'fail').touch()
            wake.save(wake.path_for(f.fid), dict(v=1, fid=f.fid, sid=f.sid, agent='codex',
                phase='active', parked=True, jobs=[dict(id='timer', kind='wakeup',
                prompt='keep failed loop words', next=123, recurring=False)]))
            wake.tick(f.fid)
            f.wait(lambda: 'loop bridge already exists' in f.tm('capture-pane', '-p', '-t', f.win))
            self.assertFalse(f.opt('@parked'))
            self.assertEqual(f.opt('@codex_session_id'), f.sid)
            self.assertFalse(f.opt('@codex_identity'))
            # The native identity disappears during startup. Only this wake's
            # receipt can settle it, never availability of the old conversation.
            native = Path(f.env['FLEET_GATE_CODEX'])
            native.write_text(native.read_text().replace("return dict(session_id=", "return None # dict(session_id="))
            gate.settle(f.fid)
            self.assertEqual(gate.records(f.fid)[0]['state'], 'waking')
            (f.root / 'release').touch()
            f.wait(lambda: '接回失败' in f.tm('capture-pane', '-p', '-t', f.win))
            wake.tick(f.fid)
            row = gate.records(f.fid)[0]
            self.assertEqual((row['state'], row['why']), ('returned', 'launch_failed'))
            self.assertEqual(row['text'], 'keep failed loop words')
            contract = gate.read_json(wake.path_for(f.fid))
            self.assertEqual(contract['pending']['delivery'], row['delivery'])
            self.assertEqual(contract['jobs'][0]['next'], 123)
            self.assertEqual(contract['attention'], 'launch_failed')
            self.assertFalse(Path(str(gate.wake_path(f.fid, row['delivery'])) + '.launched').exists())
        self.assertIn('keep failed loop words', f.tm('capture-pane', '-p', '-t', f.win))
        acts = [json.loads(line)['act'] for line in (f.root / 'conf/logs/park.ndjson').read_text().splitlines()]
        self.assertEqual(acts.count('fail'), 1)
        self.assertNotIn('wake', acts)

    def test_recovery_page_with_stale_sid_is_not_a_wake_receipt(self):
        f, gate = self.fixture(agent='codex')
        with patch.dict(os.environ, f.env):
            self.assertTrue(gate.park(f.fid)['ok'])
            # Persisted shape of C5's failed old wrapper: ordinary recovery,
            # old SID present, parked/identity/start absent, no native receipt.
            f.set('@parked', '')
            f.set('@claude_state', 'exited')
            row = dict(v=1, fid=f.fid, delivery='dddddddd-bbbb-4ccc-8ddd-eeeeeeeeeeee',
                       sid=f.sid, agent='codex', text='unaccepted words', images=[],
                       at=time.time(), state='waking', wake_at=time.time() - 100, tries=1)
            gate.save(row)
            seed = gate.wake_path(f.fid, row['delivery'])
            Path(str(seed) + '.taken').write_text(row['text'])
            gate.settle(f.fid)
            result = gate.records(f.fid)[0]
            self.assertEqual((result['state'], result['why']), ('returned', 'wake_timeout'))
            self.assertEqual(result['text'], row['text'])
            self.assertFalse(gate.wake(f.fid)['ok'], 'cleared parked and stale SID are not ready')
            gate.settle(f.fid)
            acts = [json.loads(line)['act'] for line in (f.root / 'conf/logs/park.ndjson').read_text().splitlines()]
            self.assertEqual(acts.count('fail'), 1)
            self.assertNotIn('wake', acts)

    def test_failed_peer_wake_retry_does_not_report_already_awake(self):
        import hashlib
        f, gate = self.fixture(agent='codex')
        delivery = 'failed-peer-delivery'
        with patch.dict(os.environ, f.env):
            seed = gate.wake_path(f.fid, 'peer-' + hashlib.sha256(delivery.encode()).hexdigest())
            gate.write_json(str(seed) + '.meta.failed', dict(failure='launch_failed'))
            f.set('@claude_state', 'exited')
            result = gate.wake(f.fid, delivery=delivery)
            self.assertFalse(result['ok'], result)
            self.assertEqual(result['why'], 'launch_failed')

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
        doctor = subprocess.run(['bash', str(BIN / 'fleet-doctor.sh'), '--park'],
                                env=f.env, capture_output=True, text=True, timeout=20)
        self.assertRegex(doctor.stdout, r'WARN\s+park-wake')
        self.assertIn(f.fid, doctor.stdout)
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

    def test_major_version_preflight_starts_fresh_and_keeps_words(self):
        import fleet_park_wake as wake
        f, gate = self.fixture(preflight=True)
        project = f.root / 'projects/project'
        project.mkdir(parents=True)
        transcript = project / (f.sid + '.jsonl')
        transcript.write_text(json.dumps(dict(version='3.0.0')) + '\n' +
                              json.dumps(dict(version='2.9.0')) + '\n')
        with patch.dict(os.environ, f.env):
            self.assertTrue(gate.park(f.fid)['ok'])
        new_sid = '22222222-2222-4333-8444-555555555555'
        launch = f.root / 'launch'
        launch.write_text(launch.read_text().replace(f.sid, new_sid))
        with patch.dict(os.environ, f.env):
            wake.save(wake.path_for(f.fid), dict(v=1, fid=f.fid, sid=f.sid, agent='claude',
                phase='active', parked=True, jobs=[dict(id='timer', kind='wakeup',
                prompt='original after upgrade', next=123, recurring=False)]))
            wake.tick(f.fid)
            f.wait(lambda: f.opt('@park_relay') and not f.opt('@park_held'))
            gate.settle(f.fid)
            wake.tick(f.fid)
            record = json.loads(wake.path_for(f.fid).read_text())
            self.assertEqual(record['sid'], new_sid)
            self.assertNotIn('pending', record)
            self.assertIsNone(record['jobs'][0]['next'])
            self.assertEqual(gate.records(f.fid)[0]['state'], 'sent')
            wake.tick(f.fid)
        args = json.loads((f.root / 'argv').read_text().splitlines()[-1])
        self.assertNotIn('--resume', args)
        self.assertEqual(args[-1], 'original after upgrade')
        self.assertEqual(len((f.root / 'argv').read_text().splitlines()), 2)
        self.assertEqual(f.opt('@fleet_id'), f.fid)
        f.wait(lambda: any(json.loads(line)['act'] == 'fresh' for line in
                           (f.root / 'conf/logs/park.ndjson').read_text().splitlines()))
        self.assertIn('2.9.0', f.opt('@park_fresh_reason'))
        self.assertIn('3.0.0', f.opt('@park_fresh_reason'))

    def test_memguard_rule_c_parks_idle_through_the_existing_gate(self):
        f, gate = self.fixture()
        f.tm('rename-session', '-t', 'test', f.label)
        config = f.root / ('conf/fleets/' + f.label)
        config.mkdir(parents=True)
        (config / 'conf').touch()
        pid = f.opt('pane_pid')
        ps = f.root / 'ps'
        ps.write_text('#!/bin/sh\necho "' + pid + ' 1 ' + str(os.getuid()) +
                      ' 5242880 01:00:00 claude"\n')
        ps.chmod(0o755)
        env = dict(f.env, FLEET_MEM_PS_CMD=str(ps), FLEET_MEM_TOTAL_MB='65536',
                   FLEET_MEM_PROBE_CMD='echo 1 60 5 0', FLEET_NOTIFY_CMD='true')
        f.wait(lambda: f.opt('@claude_state_src') == '7501')
        f.set('@claude_needs', 'ask')
        f.set('@claude_state', 'needs')
        result = subprocess.run(['bash', str(BIN / 'fleet-memguard.sh'), '--once'],
                                env=env, capture_output=True, text=True, timeout=20)
        self.assertFalse(f.opt('@park_held'), 'memory rule must not stop a question: ' +
                         result.stdout + result.stderr + f.opt('@claude_state') + f.opt('@claude_needs'))
        f.set('@claude_needs', '')
        f.set('@claude_state', 'done')
        result = subprocess.run(['bash', str(BIN / 'fleet-memguard.sh'), '--once'],
                                env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(f.opt('@park_held'), result.stdout + result.stderr)
        self.assertEqual(f.opt('@park_why'), 'memory')
        self.assertEqual(f.opt('@cc_session_id'), f.sid)

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
