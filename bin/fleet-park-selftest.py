#!/usr/bin/env python3
# selftest-entry
"""Drive fleet_session_gate.py, fleet-cleanup-idle.sh / .py, fleet-session-wrap.sh and
fleet-status-7501.py on an isolated tmux socket: one window / fid / conversation,
real process exit, every origin, drafts / watched / jobs / legacy wrapper held.
The native prompt proof is replaced only for the fake assistant (no model).
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, BIN / file)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


import fleet_session_gate as gate
reap = module('park_reap', 'fleet-cleanup-idle.py')


@unittest.skipUnless(shutil.which('tmux'), 'tmux absent')
class Park(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='fleet-park-'))
        # kill-server returns before the old listener has fully gone away. Each
        # case needs its own socket so the next start cannot race that shutdown.
        self.label = 'park-' + str(os.getpid()) + '-' + self.root.name[-8:]
        self.env = dict(os.environ, FLEET_CONF_DIR=str(self.root / 'conf'),
                        FLEET_GATE_WAKE_SECS='3', FLEET_GATE_PARK_SECS='3',
                        FLEET_GATE_BG_CMD='false', FLEET_PARK_MEM_FREE='50')
        self.env.pop('TMUX', None)
        self.env.pop('TMUX_PANE', None)
        self.tm('new-session', '-d', '-s', 'test', 'sleep 120')
        self.addCleanup(self.cleanup)

    def cleanup(self):
        self.tm('kill-server', check=False)
        shutil.rmtree(self.root, ignore_errors=True)

    def tm(self, *args, check=True):
        return subprocess.run(['tmux', '-L', self.label, *args], env=self.env,
                              capture_output=True, text=True, timeout=10, check=check).stdout.strip()

    def set(self, key, value):
        self.tm('set-option', '-w', '-t', self.win, key, value)

    def opt(self, key):
        return self.tm('display-message', '-p', '-t', self.win, '#{' + key + '}')

    def fake(self):
        self.fid = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
        self.sid = '11111111-2222-4333-8444-555555555555'
        fake = self.root / 'fake.py'
        fake.write_text(r'''import os,sys,tty
print('fake ready\x1b]7501;state=idle:app=claude-code\x1b\\',flush=True)
tty.setraw(0)
b=b''
while True:
 c=os.read(0,4096)
 if not c: break
 b+=c
 if b'/exit\r' in b: break
''')
        launch = self.root / 'launch'
        launch.write_text('#!/bin/bash\n' +
                          'tmux set-option -w -t "$TMUX_PANE" @claude_state done\n' +
                          'tmux set-option -w -t "$TMUX_PANE" @cc_session_id ' + self.sid + '\n' +
                          'exec python3 ' + str(BIN / 'fleet-status-7501.py') + ' relay -- python3 ' + str(fake) + '\n')
        launch.chmod(0o755)
        self.env['FLEET_WRAP_LAUNCH'] = str(launch)
        # new-window inherits its server environment; pass only fixture settings.
        import shlex
        cmd = 'env ' + ' '.join(shlex.quote(k + '=' + v) for k, v in self.env.items()
                               if k.startswith('FLEET_') and 'CRED' not in k and 'ASSERT' not in k) + ' bash ' + shlex.quote(str(BIN / 'fleet-session-wrap.sh'))
        self.win = self.tm('new-window', '-d', '-P', '-F', '#{window_id}', '-t', 'test', cmd)
        self.set('@fleet_id', self.fid)
        self.set('@fleet_role', 'worker')
        loc = self.root / 'locate'
        loc.write_text('#!/bin/sh\nprintf "' + self.label + '\\t' + self.win + '\\n"\n')
        loc.chmod(0o755)
        self.env['FLEET_GATE_WIN_CMD'] = str(loc)
        probe = self.root / 'proof'
        probe.write_text('#!/bin/sh\necho \'{"ok":true}\'\n')
        probe.chmod(0o755)
        self.env['FLEET_GATE_PARK_PROBE_CMD'] = str(probe)
        self.wait(lambda: self.opt('@park_relay') and self.opt('@cc_session_id'))

    def wait(self, predicate):
        until = time.monotonic() + 6
        while time.monotonic() < until:
            if predicate(): return
            time.sleep(.05)
        self.fail('fixture never settled: ' + self.tm('capture-pane', '-p', '-t', self.win))

    def test_process_gone_identity_retained_and_same_conversation_wakes(self):
        self.fake()
        before = self.opt('pane_pid')
        with patch.dict(os.environ, self.env):
            processes = gate.relay_request(gate.window(self.fid), {'op':'status'})
            result = gate.park(self.fid)
        self.assertTrue(result.get('ok'), result)
        self.assertTrue(self.opt('@park_held'))
        self.assertEqual(self.opt('@park_since'), self.opt('@parked'))
        self.assertEqual(self.opt('@fleet_id'), self.fid)
        self.assertEqual(self.opt('@cc_session_id'), self.sid)
        self.assertEqual(self.opt('pane_pid'), before)
        self.assertFalse(self.opt('@park_relay'), 'the relay / assistant tree survived parking')
        for pid in (processes['relay_pid'], processes['agent_pid']):
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
        self.assertGreater(float(self.opt('@park_saved_mb')), 0)
        self.assertEqual(self.opt('@park_why'), 'idle')
        with patch.dict(os.environ, self.env):
            result = gate.wake(self.fid, why='消息')
        self.assertTrue(result.get('ok'), result)
        self.wait(lambda: self.opt('@park_relay'))
        self.assertFalse(self.opt('@park_since'), 'wake retained a stale parked timestamp')
        self.assertEqual(self.opt('@cc_session_id'), self.sid)
        rows = [json.loads(l) for l in (self.root / 'conf/logs/park.ndjson').read_text().splitlines()]
        self.assertEqual([r['act'] for r in rows], ['park', 'wake'])

    def test_draft_and_background_and_legacy_hold(self):
        self.fake()
        with patch.dict(os.environ, self.env):
            proof = Path(self.env['FLEET_GATE_PARK_PROBE_CMD'])
            proof.write_text('#!/bin/sh\necho \'{"ok":false,"why":"draft"}\'\n')
            self.assertEqual(gate.park(self.fid).get('why'), 'draft')
            proof.write_text('#!/bin/sh\necho \'{"ok":true}\'\n')
            with patch.dict(os.environ, FLEET_GATE_BG_CMD='true'):
                self.assertEqual(gate.park(self.fid).get('why'), 'bg')
            self.tm('set-option', '-wu', '-t', self.win, '@park_wrap_ver')
            self.assertEqual(gate.park(self.fid).get('why'), 'old_wrapper')
        self.assertFalse(self.opt('@parked'))
        self.assertTrue(self.opt('@park_relay'))

    def test_driver_parks_when_no_repo_is_hosted(self):
        self.fake()
        # Source is written before the timestamp in set-claude-state.sh. Wait
        # for the final stamp before aging it, or Linux can overwrite our clock.
        self.wait(lambda: self.opt('@claude_state_src') == '7501'
                  and self.opt('@claude_state_ts').isdigit())
        self.set('@claude_state_ts', str(int(time.time()) - 600))
        self.set('@norepo', '1')
        driver = self.root / 'driver'
        driver.mkdir()
        for file in BIN.iterdir():
            if file.is_file() and file.name != 'fleet-lib.sh':
                (driver / file.name).symlink_to(file)
        (driver / 'fleet-lib.sh').write_text(
            'fleet_load_conf() { :; }\n'
            'fleet_socket() { printf %s "' + self.label + '"; }\n'
            'fleet_repos() { :; }\n'
            'fleet_window_repo() { return 1; }\n')
        p = subprocess.run(['bash', str(driver / 'fleet-cleanup-idle.sh'), 'test'],
                           env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(self.opt('@park_held'), 'zero-repo fleet omitted parking: ' + p.stdout + p.stderr + ' state=' + self.opt('@claude_state') + ' ts=' + self.opt('@claude_state_ts') + ' why=' + self.opt('@reap_why'))

    def test_keyboard_bytes_after_proof_cancel_exit(self):
        self.fake()
        with patch.dict(os.environ, self.env):
            w = gate.window(self.fid)
            before = gate.relay_request(w, {'op':'status'})
            self.tm('send-keys', '-t', self.win, '-l', 'unsubmitted draft')
            self.wait(lambda: gate.relay_request(w, {'op':'status'}).get('generation') != before.get('generation'))
            result = gate.relay_request(w, {'op':'exit', 'generation':before['generation']})
        self.assertFalse(result['ok'], result)
        self.assertTrue(self.opt('@park_relay'), 'stale prompt proof stopped the assistant')
        self.assertFalse(self.opt('@parked'))

    def test_all_origins_and_memory_oldest_eligible(self):
        # The reaper's real decision, independent of its close / GitHub roads.
        from types import SimpleNamespace
        args = SimpleNamespace(socket_name=self.label, session='test', window_repo=False, repo='', dry_run=False)
        r = reap.Cleaner(args)
        r.now = 1000
        snap = {'@park_wrap_ver':'1', '@parked':'', '@wrap_gone':'', 'pane_dead':'',
                '@claude_state':'done', '@agent_status':'', '@claude_state_ts':'900',
                '@fleet_id':'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', '@loop':''}
        with patch.dict(os.environ, self.env | {'FLEET_SESSION_PARK_IDLE_UNATTENDED':'1m'}), \
                patch.object(r, 'busy', return_value=False), \
                patch.object(gate, 'presence', return_value=False), \
                patch.object(reap, 'run', return_value='{"ok":true}'):
            for origin in ('person','dispatched','member','driver','orchestrator','probe','web'):
                self.assertTrue(r.web_park('@1', snap | {'@session_origin':origin}), origin)


if __name__ == '__main__':
    unittest.main()
