#!/usr/bin/env python3
"""Shared bounded stop opportunity; real isolated DB/processes, no model."""
import json
import signal
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from fleet_native_proc import process
from fleet_task_execution import ExecutionFence, check_session, FenceRefused, terminate_registered
import fleet_native_stop as stop


class StopOrder(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='native-stop-order-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.fence = ExecutionFence(self.root / 'conf')
        self.grant = json.loads((Path(__file__).parent.parent / 'tokenledger/hub/store/testdata/task_execution.json').read_text())
        self.launch = '33333333-3333-4333-8333-333333333333'
        self.fence.bind(self.grant, authorized=True)
        with self.fence.admission(self.grant) as permit:
            permit.reserve_launch(self.launch, process(os.getpid()))
            permit.register_child(self.launch, process(os.getpid()))
            permit.register_native(self.launch, 'agent', process(os.getpid()))

    def stopped(self):
        return self.fence.request_stop('T42', 'local-stop', generation=2)

    def record(self):
        with self.fence.store.connect() as db:
            row = db.execute('SELECT value FROM metadata WHERE key=?', (stop.key(self.grant),)).fetchone()
        return json.loads(row[0]) if row else None

    def test_local_without_operations_journal_fixes_deadline_before_any_wait(self):
        self.stopped()
        first = self.record()
        self.assertAlmostEqual(first['wall_deadline'] - first['wall_started'], 3)
        self.assertAlmostEqual(first['mono_deadline'] - first['mono_started'], 3)
        self.assertEqual(first['launch_id'], self.launch)
        with self.assertRaises(FenceRefused):
            check_session(self.grant['execution_owner'].split('/')[1], conf_dir=self.root/'conf')
        self.fence.request_stop('T42', 'different-stop', generation=3)
        self.assertEqual(self.record(), first)
        with self.fence.store.connect() as db:
            self.assertIsNone(db.execute("SELECT name FROM sqlite_master WHERE name='operations'").fetchone())

    def test_replay_claims_only_once_and_never_extends_budget(self):
        self.stopped()
        first = self.record()
        calls = []
        def dispatch(*args):
            calls.append(args)
            return {'state': 'observed_absent'}
        with patch.object(stop, 'dispatch_native', side_effect=dispatch):
            stop.before_signal(self.fence, 'T42', self.launch)
            stop.before_signal(self.fence, 'T42', self.launch)
        self.assertEqual(len(calls), 1)
        after = self.record()
        self.assertEqual(after['phase'], 'settled')
        self.assertEqual(after['wall_deadline'], first['wall_deadline'])
        self.assertEqual(after['mono_deadline'], first['mono_deadline'])

    def test_old_stopped_fence_without_metadata_never_gets_new_opportunity(self):
        self.stopped()
        with self.fence.store.connect() as db:
            db.execute('DELETE FROM metadata WHERE key=?', (stop.key(self.grant),))
        self.stopped()
        self.assertIsNone(self.record())
        with patch.object(stop, 'dispatch_native') as dispatch:
            self.assertIsNone(stop.before_signal(self.fence, 'T42', self.launch))
        dispatch.assert_not_called()

    def test_unknown_launch_or_external_abort_never_calls_native(self):
        self.stopped()
        with patch.object(stop, 'dispatch_native') as dispatch:
            stop.before_signal(self.fence, 'T42', '44444444-4444-4444-8444-444444444444')
            stop.before_signal(self.fence, 'T42', self.launch, abort=lambda: True)
        dispatch.assert_not_called()

    def test_wall_or_monotonic_expiry_and_clock_rollback_skip(self):
        self.stopped()
        row = self.record()
        for wall, mono in [(row['wall_deadline']+1,row['mono_started']),
                           (row['wall_started'],row['mono_deadline']+1),
                           (row['wall_started']-1,row['mono_started']),
                           (row['wall_started'],row['mono_started']-1)]:
            with self.subTest(wall=wall,mono=mono), patch.object(stop.time,'time',return_value=wall), \
                    patch.object(stop,'monotonic',return_value=mono), patch.object(stop,'dispatch_native') as dispatch:
                stop.before_signal(self.fence,'T42',self.launch)
                dispatch.assert_not_called()

    def test_changed_root_birth_and_corrupt_metadata_skip(self):
        self.stopped()
        with patch.object(stop,'kernel_identity',side_effect=OSError('unknown')), \
                patch.object(stop,'dispatch_native') as dispatch:
            stop.before_signal(self.fence,'T42',self.launch)
            dispatch.assert_not_called()
        with self.fence.store.connect() as db:
            db.execute('UPDATE metadata SET value=? WHERE key=?', ('not json',stop.key(self.grant)))
        with patch.object(stop,'dispatch_native') as dispatch:
            stop.before_signal(self.fence,'T42',self.launch)
            dispatch.assert_not_called()

    def test_concurrent_processes_share_one_claim(self):
        self.stopped()
        script = """import sys,time,os
from pathlib import Path
import fleet_native_stop as s
from fleet_task_execution import ExecutionFence
root=Path(sys.argv[1]); f=ExecutionFence(root/'conf')
def invoke(*args):
    with (root/'calls').open('a') as out: out.write('called\\n')
    time.sleep(.2)
    return {'state':'observed_absent'}
s.dispatch_native=invoke
s.before_signal(f,'T42',sys.argv[2])
"""
        env = dict(os.environ, PYTHONPATH=str(Path(__file__).parent))
        children = [subprocess.Popen([sys.executable,'-c',script,str(self.root),self.launch],env=env) for _ in range(2)]
        try:
            for child in children:
                self.assertEqual(child.wait(timeout=4),0)
        finally:
            for child in children:
                if child.poll() is None: child.kill()
                child.wait()
        self.assertEqual((self.root/'calls').read_text().count('called'),1)

    def test_dead_claimant_does_not_restart_the_three_second_clock(self):
        self.stopped()
        first = self.record()
        script = """import sys,os
import fleet_native_stop as s
from fleet_task_execution import ExecutionFence
s.dispatch_native=lambda *args: os._exit(17)
s.before_signal(ExecutionFence(sys.argv[1]),'T42',sys.argv[2])
"""
        result = subprocess.run([sys.executable,'-c',script,str(self.root/'conf'),self.launch],
            env=dict(os.environ,PYTHONPATH=str(Path(__file__).parent)),timeout=2)
        self.assertEqual(result.returncode,17)
        with patch.object(stop,'dispatch_native') as dispatch:
            stop.before_signal(self.fence,'T42',self.launch)
            dispatch.assert_not_called()
        self.assertLess(stop.monotonic()-first['mono_started'],3.25)
        self.assertEqual(self.record()['mono_deadline'],first['mono_deadline'])

    def test_locked_database_does_not_hold_exit(self):
        self.stopped()
        with self.fence.store.connect() as db:
            db.execute('BEGIN EXCLUSIVE')
            before=time.monotonic()
            with patch.object(stop.sqlite3, 'connect', wraps=stop.sqlite3.connect) as connect:
                self.assertIsNone(stop.before_signal(self.fence,'T42',self.launch))
            self.assertTrue(connect.called)
            self.assertTrue(all(call.kwargs.get('timeout') == .025 for call in connect.call_args_list))
            # Verify the actual 25ms database bound above; scheduler contention
            # is not SQLite waiting. Still reject the old 10s/default or 3s grace.
            self.assertLess(time.monotonic()-before,1)

    def test_real_root_observes_cancellation_before_term(self):
        script = """import signal,time,sys
from pathlib import Path
root=Path(sys.argv[1])
def ended(*args):
    (root/'term').write_text(str((root/'cancelled').exists()))
    raise SystemExit(0)
signal.signal(signal.SIGTERM,ended)
(root/'ready').touch()
time.sleep(15)
"""
        child=subprocess.Popen([sys.executable,'-c',script,str(self.root)])
        try:
            until=time.monotonic()+2
            while not (self.root/'ready').exists() and time.monotonic()<until: time.sleep(.01)
            self.assertTrue((self.root/'ready').exists())
            native=process(child.pid)
            proof=dict(pid=native['pid'],birth=native['birth'])
            with self.fence.store.connect() as db:
                db.execute('UPDATE task_execution_native SET process=? WHERE task_ref=?',(json.dumps(proof),'T42'))
                db.execute('UPDATE task_execution_launches SET child=? WHERE task_ref=?',(json.dumps(proof),'T42'))
            self.stopped()
            def cancel(*args):
                self.assertIsNone(child.poll())
                (self.root/'cancelled').touch()
                return {'state':'observed_absent'}
            with patch.object(stop,'dispatch_native',side_effect=cancel):
                terminate_registered(self.fence,'T42')
            child.wait(timeout=2)
            self.assertEqual((self.root/'term').read_text(),'True')
        finally:
            if child.poll() is None: child.kill()
            child.wait()

    def test_unanswered_cancel_cannot_add_term_grace_after_fixed_deadline(self):
        child=subprocess.Popen([sys.executable,'-c',
            'import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(15)'])
        try:
            native=process(child.pid)
            proof=dict(pid=native['pid'],birth=native['birth'])
            with self.fence.store.connect() as db:
                db.execute('UPDATE task_execution_native SET process=? WHERE task_ref=?',(json.dumps(proof),'T42'))
                db.execute('UPDATE task_execution_launches SET child=? WHERE task_ref=?',(json.dumps(proof),'T42'))
            self.stopped()
            first=self.record()
            def never_ack(fence,snapshot,launch,row,abort):
                while stop.remaining(row)>0: time.sleep(min(.01,stop.remaining(row)))
                return {'state':'deadline_unknown'}
            with patch.object(stop,'dispatch_native',side_effect=never_ack):
                terminate_registered(self.fence,'T42')
            self.assertEqual(child.wait(timeout=.3),-signal.SIGKILL)
            self.assertLess(stop.monotonic()-first['mono_started'],3.3)
        finally:
            if child.poll() is None: child.kill()
            child.wait()

    def test_missing_registry_or_malformed_native_tables_skip_without_tools(self):
        self.stopped()
        native=self.root/'claude'; registry=native/'sessions'; registry.mkdir(parents=True)
        identity=registry/(str(os.getpid())+'.json')
        project=self.root/'project'; (project/'.claude').mkdir(parents=True)
        table=project/'.claude/scheduled_tasks.json'
        with patch.dict(os.environ,{'CLAUDE_CONFIG_DIR':str(native),'FLEET_CC_SESSIONS_DIR':str(registry)}), \
                patch.object(stop,'run',side_effect=AssertionError('no native or lookup command')):
            found=stop.context(self.fence,'T42',self.launch)
            row=found[2]
            before=time.monotonic()
            with self.assertRaises(ValueError):
                stop.dispatch_native(self.fence,found[0],found[1],row,lambda:False)
            identity.write_text('[]')
            self.assertEqual(stop.dispatch_native(self.fence,found[0],found[1],row,lambda:False)['state'],'unsupported')
            identity.write_text(json.dumps({'sessionId':'22222222-2222-4222-8222-222222222222','cwd':str(project)}))
            table.write_text('[]')
            self.assertEqual(stop.dispatch_native(self.fence,found[0],found[1],row,lambda:False)['state'],'unsupported')
            self.assertLess(time.monotonic()-before,.2)

    def test_external_term_interrupts_real_supervisor_cancellation(self):
        # Separate real supervisor/native processes own this second fixture DB.
        root=self.root/'supervised'; root.mkdir()
        conf=root/'conf'
        fence=ExecutionFence(conf); fence.bind(self.grant,authorized=True)
        (root/'grant.json').write_text(json.dumps(self.grant))
        script=root/'launch.py'
        script.write_text("""import json,os,sys,time
from pathlib import Path
import fleet_task_execution as t
import fleet_native_stop as s
root=Path(sys.argv[1]); grant=json.loads((root/'grant.json').read_text())
t._authority=lambda cmd,*args,**kwargs: {'control_version':1,'task_executions':[grant]} if cmd=='execution-list' else grant
if sys.argv[2]=='supervisor':
    def pending(fence,snapshot,launch,row,abort):
        (root/'entered').touch()
        while not abort(): time.sleep(.01)
        return {'state':'unknown'}
    s.dispatch_native=pending
    sys.exit(t.supervise(grant,[sys.executable,__file__,str(root),'native']))
elif sys.argv[2]=='native':
    t.native_exec([sys.executable,__file__,str(root),'agent'],'agent')
else:
    (root/'running').touch()
    time.sleep(15)
""")
        env={k:v for k,v in os.environ.items() if not k.startswith('FLEET_') and k not in ('TMUX','TMUX_PANE')}
        env.update(FLEET_CONF_DIR=str(conf),PYTHONPATH=str(Path(__file__).parent))
        child=subprocess.Popen([sys.executable,str(script),str(root),'supervisor'],env=env)
        try:
            until=time.monotonic()+3
            while not (root/'running').exists() and time.monotonic()<until: time.sleep(.01)
            self.assertTrue((root/'running').exists())
            fence.request_stop('T42','external-test',generation=2)
            until=time.monotonic()+1
            while not (root/'entered').exists() and time.monotonic()<until: time.sleep(.01)
            self.assertTrue((root/'entered').exists())
            sent=time.monotonic(); child.send_signal(signal.SIGTERM)
            self.assertEqual(child.wait(timeout=1),128+signal.SIGTERM)
            self.assertLess(time.monotonic()-sent,.6)
        finally:
            if child.poll() is None: child.kill()
            child.wait()
            terminate_registered(fence,'T42',abort=lambda:True)


if __name__ == '__main__':
    unittest.main()
