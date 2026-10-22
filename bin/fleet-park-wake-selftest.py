#!/usr/bin/env python3
# selftest-entry
"""Drive fleet_loop_mark.py export, fleet_park_wake.py tick and the real
fleet_session_gate.py / fleet-session-wrap.sh on Park's isolated tmux socket.
No model or live login is used. The launch fixture records the first prompt.
"""
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import shlex
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from importlib.util import spec_from_file_location, module_from_spec
BIN = Path(__file__).resolve().parent
spec = spec_from_file_location('park_fixture', BIN / 'fleet-park-selftest.py')
fixture = module_from_spec(spec)
spec.loader.exec_module(fixture)


class Timers(fixture.Park):
    def setup_timer(self, cron=False):
        self.fake()
        self.env['FLEET_WAKE_NATIVE_HOME'] = str(self.root)
        self.prompt = 'Check the batch; preserve "quotes" and\nthis second line.'
        self.env['FLEET_CC_PROJECTS_DIR'] = str(self.root / 'projects')
        project = self.root / 'projects/example'
        project.mkdir(parents=True)
        self.transcript = project / (self.sid + '.jsonl')
        self.due = int(time.time()) + 3
        at = self.due - 60
        name = 'CronCreate' if cron else 'ScheduleWakeup'
        inp = dict(cron='* * * * *', prompt=self.prompt) if cron else dict(delaySeconds=60, prompt=self.prompt)
        stamp = datetime.datetime.fromtimestamp(at, datetime.timezone.utc).isoformat()
        self.transcript.write_text('\n'.join(json.dumps(r) for r in [
            dict(timestamp=stamp, message=dict(content=[dict(type='tool_use', id='u', name=name, input=inp)])),
            dict(timestamp=stamp, toolUseResult=dict(id='job-1'),
                 message=dict(content=[dict(type='tool_result', tool_use_id='u', content='ok')]))]) + '\n')
        import fleet_loop_mark as mark
        self.set('@loop', mark.apply('', dict(tool_name=name, tool_input=inp, tool_response=dict(id='job-1')), at))
        launch = self.root / 'launch'
        text = launch.read_text()
        text = text.replace('exec python3 ', 'printf "%s\\n" "$@" >> ' + str(self.root / 'launch-args') + '\nexec python3 ', 1)
        launch.write_text(text)

    def tick(self, now=None):
        args = [sys.executable, str(BIN / 'fleet_park_wake.py'), 'tick', '--fid', self.fid]
        if now is not None:
            args += ['--now', str(now)]
        p = subprocess.run(args, env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def test_wakeup(self):
        self.setup_timer()
        with patch.dict(os.environ, self.env):
            result = fixture.gate.park(self.fid)
        self.assertTrue(result.get('ok'), result)
        self.assertFalse(self.opt('@park_relay'))
        self.tick(self.due - 1)
        self.assertTrue(self.opt('@parked'))
        time.sleep(max(0, self.due - time.time()))
        self.tick()
        self.wait(lambda: not self.opt('@parked') and self.opt('@park_relay'))
        self.assertIn(self.prompt, (self.root / 'launch-args').read_text())
        self.assertEqual(self.opt('@cc_session_id'), self.sid)
        self.tick()
        rows = [json.loads(x) for x in (self.root / 'conf/logs/park.ndjson').read_text().splitlines()]
        wakes = [r for r in rows if r['act'] == 'wake']
        self.assertEqual(len(wakes), 1)
        self.assertEqual(wakes[0]['next'], self.due)
        self.assertGreaterEqual(wakes[0]['ts'], self.due)
        self.assertLessEqual(wakes[0]['ts'], self.due + 15)

    def test_cron_three_rounds(self):
        self.setup_timer(cron=True)
        for _ in range(3):
            with patch.dict(os.environ, self.env):
                result = fixture.gate.park(self.fid)
            self.assertTrue(result.get('ok'), result)
            contract = json.loads((self.root / 'conf/wake' / (self.fid + '.json')).read_text())
            due = contract['next']
            self.tick(due)
            self.wait(lambda: not self.opt('@parked') and self.opt('@park_relay'))
            self.tick(due)
        args = (self.root / 'launch-args').read_text()
        self.assertEqual(args.count(self.prompt), 3, args)

    def test_wrapper_restore_keeps_contract(self):
        self.setup_timer(cron=True)
        with patch.dict(os.environ, self.env):
            self.assertTrue(fixture.gate.park(self.fid).get('ok'))
        contract = json.loads((self.root / 'conf/wake' / (self.fid + '.json')).read_text())
        # The same command fleet-restore.sh emits after restoring the original
        # fid from its map. Kill only this fixture's wrapper/window process tree.
        cmd = 'env ' + ' '.join(shlex.quote(k + '=' + v) for k, v in self.env.items()
                               if k.startswith('FLEET_') and 'CRED' not in k and 'ASSERT' not in k)
        cmd += ' FLEET_PARK_RESTORE_FID=' + self.fid + ' bash ' + shlex.quote(str(BIN / 'fleet-session-wrap.sh'))
        cmd += ' --resume ' + self.sid
        self.tm('respawn-window', '-k', '-t', self.win, cmd)
        self.wait(lambda: self.opt('@park_held') and self.opt('@park_wrap_ver'))
        self.assertFalse((self.root / 'launch-args').exists(), 'restore started the native engine early')
        self.tick(contract['next'])
        self.wait(lambda: not self.opt('@parked') and self.opt('@park_relay'))
        self.assertEqual(self.opt('@fleet_id'), self.fid)
        self.assertEqual(self.opt('@cc_session_id'), self.sid)
        self.assertIn(self.prompt, (self.root / 'launch-args').read_text())

    def test_durable_has_one_owner(self):
        import fleet_transfer_durable as durable
        self.setup_timer()
        self.set('@loop', '')
        self.transcript.write_text(json.dumps(dict(version='2.1.295')) + '\n')
        with patch.dict(os.environ, self.env):
            source = fixture.gate.relay_request(fixture.gate.window(self.fid), dict(op='status'))
        when = time.localtime(time.time() + 600)
        minute = when.tm_min if when.tm_min not in (0, 30) else when.tm_min + 1
        native = dict(id='durable-1', prompt=self.prompt, cron=f'{minute} {when.tm_hour} {when.tm_mday} {when.tm_mon} *',
                      recurring=False, createdAt=int(time.time()*1000), createdBySessionId=self.sid,
                      createdInProject=str(self.root.resolve()), createdByPid=source['agent_pid'],
                      createdByProcStart=durable.proc_start(source['agent_pid']))
        store = self.root / '.claude/scheduled_tasks.json'
        store.parent.mkdir()
        store.write_text(json.dumps(dict(tasks=[native])))
        with patch.dict(os.environ, self.env), patch.object(durable, 'claude_processes', return_value=[]):
            result = fixture.gate.park(self.fid)
        self.assertTrue(result.get('ok'), result)
        self.assertEqual(json.loads(store.read_text())['tasks'], [])
        contract = json.loads((self.root / 'conf/wake' / (self.fid + '.json')).read_text())
        self.tick(contract['next'])
        self.wait(lambda: not self.opt('@parked') and self.opt('@park_relay'))
        self.tick(contract['next'])
        self.assertEqual((self.root / 'launch-args').read_text().count(self.prompt), 1)

    def test_refused_exit_keeps_native_schedule(self):
        self.setup_timer()
        with patch.dict(os.environ, dict(self.env, FLEET_GATE_EXIT_CMD='false')):
            result = fixture.gate.park(self.fid)
        self.assertFalse(result.get('ok'))
        self.assertTrue(self.opt('@park_relay'))
        self.assertFalse((self.root / 'conf/wake' / (self.fid + '.json')).exists())


if __name__ == '__main__':
    names = sys.argv[1:] or [n for n in Timers.__dict__ if n.startswith('test_')]
    result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(Timers(n) for n in names))
    sys.exit(not result.wasSuccessful())
