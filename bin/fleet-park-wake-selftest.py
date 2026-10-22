#!/usr/bin/env python3
# selftest-entry
"""Drive fleet_loop_mark.py export, tmux-spinner.py / fleet_park_wake.py tick and the real
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
    def setup_timer(self, cron=False, agent='claude'):
        self.fake(agent)
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
        # The shared park fixture records every launch, including its initial
        # empty argv. Count only subsequent resumes; do not install a second logger.
        (self.root / 'launch-args').unlink()

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
        spinner_module = fixture.module('timer_spinner', 'tmux-spinner.py')
        with patch.dict(os.environ, self.env):
            spinner = spinner_module.Spinner()
            try:
                spinner.park_timers()
                self.assertIsNotNone(spinner.timer_child)
                spinner.timer_child.wait(timeout=15)
                self.assertEqual(spinner.timer_child.returncode, 0)
            finally:
                spinner.close()
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
        import fleet_loop_mark as mark
        with patch.dict(os.environ, self.env):
            self.assertEqual(mark.status(self.opt('@loop'))[0], 'active', 'restored cron lost its reap hold')
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

    def test_cron_continues_while_awake(self):
        self.setup_timer(cron=True)
        with patch.dict(os.environ, self.env):
            self.assertTrue(fixture.gate.park(self.fid).get('ok'))
        path = self.root / 'conf/wake' / (self.fid + '.json')
        self.tick(json.loads(path.read_text())['next'])
        self.wait(lambda: self.opt('@park_relay'))
        self.set('@mod_accept', 'idle.v2')
        self.set('@claude_state', 'looping')
        self.set('@agent_status', json.dumps(dict(state='idle')))
        accept = self.root / 'accept.py'
        accept.write_text('import sys,json\nr=json.load(sys.stdin)\n'
                          'open(' + repr(str(self.root / 'accepted')) + ',"a").write(r["text"]+"\\n")\n'
                          'print(json.dumps(dict(state="accepted",turn_id="turn-1")))\n')
        self.env['FLEET_GATE_ACCEPT_CMD'] = shlex.join([sys.executable, str(accept)])
        due = json.loads(path.read_text())['next']
        self.tick(due)
        self.tick(due)
        self.assertEqual((self.root / 'accepted').read_text().count(self.prompt), 1)

    def test_only_exact_native_exit_dialog_is_confirmed(self):
        import fleet_park_wake as wake
        self.setup_timer(cron=True)
        with patch.dict(os.environ, self.env):
            wake.export(self.fid)
            screen = ('Background work is running\nThe following will stop when you exit:\n'
                      'cron task · * * * * * · check\n❯ 1. Exit and stop tasks\n'
                      '2. Move to background and exit\n3. Stay\nEnter to confirm · Esc to cancel\n')
            self.assertTrue(wake.exit_confirmation(self.fid, screen))
            for altered in (screen.replace('❯ 1.', '1.'), screen.replace('cron task', 'background task'),
                            screen.replace('* * * * *', '*/5 * * * *'), screen + 'normal prompt\n'):
                self.assertFalse(wake.exit_confirmation(self.fid, altered))

    def test_existing_loop_ledger_keeps_one_dispatcher_and_owner_commands(self):
        self.check_existing_loop_ledger('claude')

    def test_codex_loop_wakes_same_thread_and_keeps_owner_commands(self):
        self.check_existing_loop_ledger('codex')

    def test_codex_park_resume_does_not_bootstrap_second_controller(self):
        # A transferred session's wrapper inherits these from launch.sh. The
        # first native fixture is already running; the original ledger exists.
        manifest = self.root / 'transfer/manifest.json'
        spec = manifest.parent / 'loop-spec.json'
        self.env.update(FLEET_HANDOFF_MANIFEST=str(manifest), FLEET_LOOP_SPEC=str(spec),
                        FLEET_LOOP_AGENT='codex')
        ledger = self.park_ledger('codex')
        source = subprocess.Popen(['sh', '-c', 'exit 0'])
        source.wait()
        manifest.write_text(json.dumps(dict(source=dict(pid=source.pid), loop_spec_path=str(spec),
            fleet=dict(session=self.label, window_id=self.win, pane_id=self.opt('pane_id')),
            workspace=dict(path=str(self.root)), target=dict(agent='codex'))))
        spec.write_text(json.dumps(dict(prompt=self.prompt, interval_seconds=60, next_run_at=self.due)))
        # The launcher's documented LOOP_SPEC branch runs the actual bridge,
        # whose duplicate-directory guard must never be hit on a parked resume.
        launch = self.root / 'launch'
        text = launch.read_text()
        probe = ('if [ -n "${FLEET_LOOP_SPEC:-}" ]; then\n'
                 '  touch ' + shlex.quote(str(self.root / 'rebootstrap')) + '\n'
                 '  exec ' + shlex.join([sys.executable, str(BIN / 'fleet-loop.py'), 'bridge', '--']) + ' "$@"\nfi\n')
        launch.write_text(text.replace('#!/bin/bash\n', '#!/bin/bash\n' + probe, 1))
        self.tick(self.due)
        self.assertFalse((self.root / 'rebootstrap').exists(),
                         'park resume attempted a second controller: ' + self.tm('capture-pane', '-p', '-t', self.win))
        self.wait(lambda: self.opt('@park_relay'))
        self.assertEqual(self.opt('@codex_session_id'), self.sid)
        self.assertEqual((self.root / 'launch-args').read_text().count(self.prompt), 1)
        self.assertEqual(json.loads(ledger.read_text())['deliveries'], 1)

    def park_ledger(self, agent, cron=False, same_due=False):
        self.setup_timer(agent=agent)
        self.set('@loop', '')
        manifest = self.root / 'transfer/manifest.json'
        ledger = manifest.parent / 'loop/state.json'
        ledger.parent.mkdir(parents=True)
        manifest.write_text('{}')
        self.set('@handoff_manifest', str(manifest))
        schedule = dict(prompt=self.prompt, interval_seconds=60, next_run_at=self.due)
        if cron:
            import fleet_cron
            self.due = (int(time.time()) // 60 + 1) * 60
            schedule = fleet_cron.plan(dict(jobs=[dict(id=ident, prompt=prompt, cron='* * * * *',
                timezone='UTC', expires_at=time.time()+3600, recurring=True, stop_when='', next_run_at=due)
                for ident, prompt, due in [('cancel-me', self.prompt, self.due),
                                          ('keep-me', 'Uncancelled sibling prompt', self.due if same_due else self.due+120)]]))
        record = dict(id='loop-1', status='active', thread_id=self.sid,
                      agent=agent, manifest=str(manifest), schedule=schedule)
        import fleet_park_wake as wake
        wake.loop_module().claim_owner(ledger, record, {})
        self.owner_evidence = {k: record[k] for k in ('owner_record', 'record_path', 'generation',
                                                     'active_record', 'active_generation')}
        ledger.write_text(json.dumps(record))
        with patch.dict(os.environ, self.env):
            self.assertTrue(fixture.gate.park(self.fid).get('ok'))
            # The old dispatcher sees its ownership moved and does no native I/O.
            wake.loop_module().dispatch(ledger, now=self.due)
        self.assertEqual(json.loads(ledger.read_text())['park_fid'], self.fid)
        return ledger

    def owner_command(self, ledger, *args):
        env = dict(self.env, FLEET_LOOP_RECORD=str(ledger), TMUX=self.opt('socket_path') + ',0,0',
                   TMUX_PANE=self.opt('pane_id'))
        p = subprocess.run([sys.executable, str(BIN / 'fleet-loop.py'), *args],
                           env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(p.returncode, 0, p.stderr)

    def check_existing_loop_ledger(self, agent):
        ledger = self.park_ledger(agent)
        self.tick(self.due - 1)
        self.assertTrue(self.opt('@parked'))
        self.tick(self.due)
        self.wait(lambda: self.opt('@park_relay'))
        self.assertEqual((self.root / 'launch-args').read_text().count(self.prompt), 1)
        self.assertEqual(self.opt('@codex_session_id' if agent == 'codex' else '@cc_session_id'), self.sid)
        self.assertEqual(self.opt('@fleet_id'), self.fid)
        record = json.loads(ledger.read_text())
        self.assertEqual({k: record[k] for k in self.owner_evidence}, self.owner_evidence)
        self.assertEqual(record['deliveries'], 1)
        self.assertEqual(record['schedule']['next_run_at'], self.due + 60)
        self.owner_command(ledger, 'defer', '--seconds', '120')
        self.owner_command(ledger, 'stop')
        self.tick(self.due + 600)
        self.assertEqual(json.loads(ledger.read_text())['status'], 'stopped')
        self.assertEqual(json.loads(ledger.read_text())['deliveries'], 1)
        import fleet_loop_mark as mark
        with patch.dict(os.environ, self.env):
            self.assertEqual(mark.status(self.opt('@loop'))[0], 'none')


    def block_timer_wake(self):
        # Another startup owns the gate. No second seed may launch beside it.
        self.set('@park_start', str(self.root / 'other-start.meta'))
        self.tick(self.due)
        contract = json.loads((self.root / 'conf/wake' / (self.fid + '.json')).read_text())
        self.assertIn('pending', contract)
        with patch.dict(os.environ, self.env):
            row = fixture.gate.find(fixture.gate.records(self.fid), contract['pending']['delivery'])
        self.assertEqual(row['state'], 'queued')
        return contract['pending']['delivery']

    def settle_after_cancel(self, tick_first=False, tick=True):
        self.set('@park_start', '')
        # The queue sweeper can run before the timer's next tick. Both roads
        # must observe stop/cancel, not only the @loop display's status.
        if tick and tick_first:
            self.tick(self.due)
        with patch.dict(os.environ, self.env):
            fixture.gate.settle(self.fid)
        if tick and not tick_first:
            self.tick(self.due)
        self.assertTrue(self.opt('@parked'), 'cancelled timer resumed the native engine')
        self.assertFalse((self.root / 'launch-args').exists(), 'cancelled prompt was launched')

    def test_codex_stopped_loop_never_rearms(self):
        ledger = self.park_ledger('codex')
        self.owner_command(ledger, 'stop')
        self.settle_after_cancel()
        self.assertEqual(json.loads(ledger.read_text())['status'], 'stopped')

    def test_codex_stopped_pending_loop_never_rearms(self):
        ledger = self.park_ledger('codex')
        self.block_timer_wake()
        self.owner_command(ledger, 'stop')
        self.settle_after_cancel(tick_first=True)
        self.assertEqual(json.loads(ledger.read_text())['status'], 'stopped')

    def test_codex_cancelled_pending_job_keeps_sibling(self):
        ledger = self.park_ledger('codex', cron=True)
        self.block_timer_wake()
        self.owner_command(ledger, 'stop', '--job', 'cancel-me')
        self.settle_after_cancel()
        self.assertEqual(json.loads(ledger.read_text())['status'], 'active')
        self.tick(self.due + 120)
        self.wait(lambda: self.opt('@park_relay'))
        args = (self.root / 'launch-args').read_text()
        self.assertNotIn(self.prompt, args)
        self.assertEqual(args.count('Uncancelled sibling prompt'), 1)
        self.assertEqual(self.opt('@codex_session_id'), self.sid)

    def test_codex_cancelled_pending_job_keeps_due_sibling(self):
        ledger = self.park_ledger('codex', cron=True, same_due=True)
        cancelled_delivery = self.block_timer_wake()
        self.owner_command(ledger, 'stop', '--job', 'cancel-me')
        self.settle_after_cancel(tick=False)
        self.tick(self.due)
        self.wait(lambda: self.opt('@park_relay'))
        args = (self.root / 'launch-args').read_text()
        self.assertNotIn(self.prompt, args)
        self.assertEqual(args.count('Uncancelled sibling prompt'), 1)
        self.tick(self.due)
        record = json.loads(ledger.read_text())
        self.assertEqual(record['deliveries'], 1)
        self.assertNotEqual(record['accepted_turn'], cancelled_delivery)
        self.assertEqual(self.opt('@codex_session_id'), self.sid)

    def test_cancelled_native_cron_pending_never_wakes(self):
        import fleet_park_wake as wake
        self.setup_timer(cron=True)
        with patch.dict(os.environ, self.env):
            self.assertTrue(fixture.gate.park(self.fid).get('ok'))
        self.due = json.loads((self.root / 'conf/wake' / (self.fid + '.json')).read_text())['next']
        self.block_timer_wake()
        with patch.dict(os.environ, self.env):
            wake.cancel(self.fid, dict(tool_name='CronDelete', tool_input=dict(id='job-1')))
        self.settle_after_cancel()


if __name__ == '__main__':
    names = sys.argv[1:] or [n for n in Timers.__dict__ if n.startswith('test_')]
    result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(Timers(n) for n in names))
    sys.exit(not result.wasSuccessful())
