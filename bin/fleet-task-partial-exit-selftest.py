#!/usr/bin/env python3
# selftest-entry
"""Positive admission protocols, authenticated provider, real partial roots."""
import copy
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

from fleet_control import Control
from fleet_task_execution import ExecutionFence, FenceRefused, _kernel_process, prove_native_session_exit
import fleet_task_execution as execution

BIN = Path(__file__).resolve().parent
GRANT = json.loads((BIN.parent/'tokenledger/hub/store/testdata/task_execution.json').read_text())
STOP = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'


class PartialExit(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='partial-exit-')
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.control=Control(self.root)
        self.fence=self.control.execution
        self.fence.bind(GRANT,authorized=True)
        self.wrapper=_kernel_process(os.getpid())
        self.children=[]
        self.addCleanup(self.cleanup)

    def cleanup(self):
        for child in self.children:
            if child.poll() is None: child.kill()
            child.wait(timeout=2)

    def register(self,components=(),protocol=1,child=True,live=False):
        process=subprocess.Popen([sys.executable,'-c','import time;time.sleep(20)'])
        self.children.append(process)
        proof=_kernel_process(process.pid)
        with self.fence.admission(GRANT) as permit:
            permit.reserve_launch('partial-launch',proof,wrapper=self.wrapper,admission_protocol=protocol)
            if child: permit.register_child('partial-launch',proof)
            for name in components: permit.register_native('partial-launch',name,proof)
        if not live:
            process.kill(); process.wait(timeout=2)
        self.stopped=dict(GRANT,generation=2,cancel_request=STOP)
        self.fence.apply_stop(self.stopped)
        return process

    def prove(self,provider='codex'):
        return prove_native_session_exit(self.stopped,provider,conf_dir=self.root)

    def test_new_protocol_all_actual_codex_subsets_and_claude_empty(self):
        for provider,native in [('codex',()),('codex',('server',)),('codex',('client',)),('claude',())]:
            with self.subTest(provider=provider,native=native):
                self.setUp()
                self.register(native)
                proof=self.prove(provider)
                self.assertEqual(proof['scope'],'native_session')
                self.assertEqual({r['component'] for r in proof['launches'][0]['roots']},{'supervisor','child',*native})

    def test_old_partial_missing_child_and_live_roots_remain_unknown(self):
        for protocol,child,live in [(0,True,False),(1,False,False),(1,True,True)]:
            with self.subTest(protocol=protocol,child=child,live=live):
                self.setUp()
                self.register(('client',),protocol,child,live)
                with self.assertRaises(FenceRefused): self.prove()

    def test_new_epoch_does_not_upgrade_old_partial_history(self):
        self.register(('client',))
        current=self.fence.launch('T42')
        old=copy.deepcopy(current);old['launch_id']='old-partial';old['admission_protocol']=0;old['native']=[]
        with self.fence.store.connect() as db:
            db.execute('INSERT INTO task_execution_launch_history VALUES (?,?,?)',('T42',old['launch_id'],json.dumps(old)))
        with self.assertRaises(FenceRefused): self.prove()

    def test_wrong_provider_unknown_birth_and_final_mutation_remain_unknown(self):
        self.register(('agent',))
        with self.assertRaises(FenceRefused): self.prove('codex')
        with patch('fleet_native_proc.kernel_identity',side_effect=PermissionError('unknown')), \
                patch('fleet_task_execution.os.kill',return_value=None), self.assertRaises(FenceRefused):
            self.prove('claude')
        original=execution._exited_session_root
        def mutate(proof):
            result=original(proof)
            with self.fence.store.connect() as db:
                db.execute('UPDATE task_execution_launches SET admission_protocol=0')
            return result
        with patch.object(execution,'_exited_session_root',side_effect=mutate),self.assertRaises(FenceRefused):
            self.prove('claude')

    def test_standard_launcher_qualification_is_explicit_and_pins_owned_path(self):
        launcher = str(BIN / 'fleet-claude.sh')
        qualify = execution.qualified_launch
        for argv, env, expected in [
                ([launcher, '--agent', 'claude'], {}, 1),
                ([launcher, '--agent=claude'], {'FLEET_AGENT': 'codex'}, 1),
                ([launcher], {'FLEET_AGENT': 'claude'}, 0),
                ([launcher, '--agent', 'codex'], {}, 0),
                ([str(BIN / 'fleet-codex.sh')], {}, 0),
                ([launcher, '--agent', 'claude'], {'FLEET_WRAP_LAUNCH': launcher}, 0),
                (['bash', launcher, '--agent', 'claude'], {}, 0),
                (['env', '-u', 'FLEET_TASK_EXECUTION', launcher, '--agent=claude'], {}, 0),
                ([launcher, '--agent=claude', '--agent=codex'], {}, 0),
                ([launcher, '--as', '--agent=claude'], {}, 0),
                ([launcher, '--agent=claude', '--as'], {}, 0)]:
            with self.subTest(argv=argv,env=env):
                actual, protocol = qualify(argv, env)
                self.assertEqual(protocol, expected)
        # The standard wrapper's complete env-removal prefix is accepted, but
        # an arbitrary env wrapper (especially a fence-token removal) is not.
        names = ('FLEET_LAUNCH FLEET_LAUNCH_CONTEXT FLEET_LAUNCH_SUPERVISOR '
                 'FLEET_LAUNCH_NATIVE FLEET_LAUNCH_WORKTREE FLEET_LAUNCH_CREATE '
                 'FLEET_LAUNCH_DELIVERY FLEET_AUTHORITY_CONTEXT FLEET_AUTHORITY_ADMISSION '
                 'FLEET_AUTHORITY_START FLEET_AUTHORITY_EXPECTED FLEET_AUTHORITY_RESUME_SID '
                 'FLEET_ID_DISPATCH').split()
        prefix = ['env'] + [word for name in names for word in ('-u', name)]
        pinned, protocol = qualify(prefix + [launcher, '--agent=claude'], {})
        self.assertEqual((pinned[0], protocol), ('/usr/bin/env', 1))
        alias = self.root / 'launcher'
        alias.symlink_to(launcher)
        actual, protocol = qualify([str(alias), '--agent=claude'], {})
        self.assertEqual((actual[0], protocol), (launcher, 1))

    def test_migration_defaults_old_epochs_to_zero_and_keeps_archive_bytes(self):
        self.register(('agent',), protocol=0)
        current = self.fence.launch('T42')
        old = dict(current, launch_id='legacy')
        old.pop('admission_protocol')
        old['native'] = []
        raw = json.dumps(old)
        with self.fence.store.connect() as db:
            db.execute('INSERT INTO task_execution_launch_history VALUES (?,?,?)', ('T42','legacy',raw))
            # Reconstruct the pre-migration table (also exercises old readers).
            db.execute('ALTER TABLE task_execution_launches RENAME TO migration_fixture')
            db.execute("CREATE TABLE task_execution_launches AS SELECT task_ref,launch_id,operation_id,supervisor,wrapper,child FROM migration_fixture")
            db.execute('DROP TABLE migration_fixture')
        restarted = ExecutionFence(self.root)
        self.assertEqual(restarted.launch('T42')['admission_protocol'], 0)
        with restarted.store.connect() as db:
            self.assertEqual(db.execute('SELECT registration FROM task_execution_launch_history').fetchone()[0],raw)
        with self.assertRaises(FenceRefused): self.prove('claude')

    def test_real_sigkill_windows_never_invent_missing_children(self):
        driver = r'''import json,os,pathlib,signal,subprocess,sys,time
from unittest.mock import patch
sys.path.insert(0,sys.argv[1])
import fleet_task_execution as e
root=pathlib.Path(sys.argv[2]); stage=sys.argv[3]; grant=json.loads(sys.argv[4])
e.refresh_session=lambda *a,**kw:grant
e.qualified_launch=lambda argv,env:(argv,1) # positive entry fixture, tested independently
original_reserve=e.Admission.reserve_launch
original_child=e.Admission.register_child
original_popen=subprocess.Popen
native_code="""import json,os,pathlib,signal,sys,time
sys.path.insert(0,sys.argv[1]); import fleet_task_execution as e
root=pathlib.Path(sys.argv[2]); stage=sys.argv[3]
e.refresh_session=lambda *a,**kw:None
if stage in ('pre-native-exec','after-native-exec'):
    original=e.Admission.register_native
    def registered(self,*a,**kw):
        result=original(self,*a,**kw)
        if stage=='pre-native-exec':
            (root/'native-ready').touch()
            os.kill(os.getpid(),signal.SIGKILL)
        return result
    e.Admission.register_native=registered
    e.native_exec([sys.executable,'-c',"import pathlib,sys,time;pathlib.Path(sys.argv[1]).touch();time.sleep(20)",str(root/'native-ready')],'agent')
else: time.sleep(20)
"""
def reserved(self,*a,**kw):
    result=original_reserve(self,*a,**kw)
    if stage=='pre-popen': os.kill(os.getpid(),signal.SIGKILL)
    return result
def opened(*a,**kw):
    child=original_popen(*a,**kw)
    if len(a[0]) < 3 or a[0][2] != native_code: return child
    (root/'owned-child').write_text(json.dumps(e._kernel_process(child.pid)))
    if stage=='post-popen': os.kill(os.getpid(),signal.SIGKILL)
    return child
def registered(self,*a,**kw):
    result=original_child(self,*a,**kw)
    if stage=='post-child': os.kill(os.getpid(),signal.SIGKILL)
    return result
e.Admission.reserve_launch=reserved
e.Admission.register_child=registered
e.subprocess.Popen=opened
e.supervise(grant,[sys.executable,'-c',native_code,sys.argv[1],str(root),stage])
'''
        for stage in ('pre-popen','post-popen','post-child','pre-native-exec','after-native-exec'):
            with self.subTest(stage=stage), tempfile.TemporaryDirectory(prefix='partial-crash-') as directory:
                root=Path(directory)
                fence=ExecutionFence(root)
                fence.bind(GRANT,authorized=True)
                env=dict(os.environ,FLEET_CONF_DIR=str(root))
                env.pop('FLEET_SESSION_WRAP',None)
                proc=subprocess.Popen([sys.executable,'-c',driver,str(BIN),str(root),stage,json.dumps(GRANT)],env=env,
                                      stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
                try:
                    if stage in ('pre-native-exec','after-native-exec'):
                        deadline=time.monotonic()+5
                        while not (root/'native-ready').exists():
                            self.assertIsNone(proc.poll(), 'supervisor exited before native stage')
                            self.assertLess(time.monotonic(),deadline)
                            time.sleep(.01)
                        if proc.poll() is None: proc.kill()
                    proc.wait(timeout=5)
                    stopped=dict(GRANT,generation=2,cancel_request=STOP)
                    fence.apply_stop(stopped)
                    if stage in ('post-child','after-native-exec'):
                        with self.assertRaises(FenceRefused):
                            prove_native_session_exit(stopped,'claude',conf_dir=root)
                finally:
                    if proc.poll() is None: proc.kill()
                    proc.wait(timeout=3)
                    proc.stderr.close()
                    if (root/'owned-child').exists():
                        child=json.loads((root/'owned-child').read_text())
                        if execution._same_birth(child): os.kill(child['pid'],signal.SIGKILL)
                        deadline=time.monotonic()+3
                        while not execution._definitely_exited(child):
                            self.assertLess(time.monotonic(),deadline)
                            time.sleep(.01)
                if stage in ('pre-popen','post-popen'):
                    with self.assertRaises(FenceRefused):
                        prove_native_session_exit(stopped,'claude',conf_dir=root)
                    self.assertIsNone(fence.launch('T42')['child'])
                else:
                    proof=prove_native_session_exit(stopped,'claude',conf_dir=root)
                    components={x['component'] for x in proof['launches'][0]['roots']}
                    self.assertEqual(components,{'supervisor','child'} | ({'agent'} if 'native-exec' in stage else set()))

    def test_actual_standard_claude_launch_records_protocol_before_initialization(self):
        import runpy
        import shutil
        fixture = runpy.run_path(str(BIN/'fleet-task-execution-native-selftest.py'))['NativeExecutionTests']()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        f = fixture
        shutil.copy2(BIN/'fleet-claude.sh', f.bin/'fleet-claude.sh')
        # Actual standard launcher, paused while sourcing configuration. No
        # model process has started; a registered child is still mandatory.
        os.mkfifo(f.root/'release.fifo')
        (f.bin/'fleet-launch-lib.sh').write_text('printf ready > "$TEST_ROOT/initializing"\nread -r ignored < "$TEST_ROOT/release.fifo"\nexit 0\n')
        env=dict(f.env)
        env.pop('FLEET_WRAP_LAUNCH')
        proc=subprocess.Popen([sys.executable,str(f.bin/'fleet_task_execution.py'),'run','--snapshot',json.dumps(f.snapshot),
                               '--',str(f.bin/'fleet-claude.sh'),'--agent','claude'],env=env,
                              stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,text=True)
        f.children.append(proc)
        f.wait_file('initializing',proc)
        # The shell can touch its marker before Popen returns to the
        # supervisor. Wait for the existing fork/registration barrier: this
        # case proves a registered partial launch, not the missing-child
        # crash window (which must still refuse exit proof).
        with f.fence.admission(f.snapshot):
            launch=f.fence.launch('T42')
            self.assertEqual(launch['child'],_kernel_process(launch['child']['pid']))
        self.assertEqual(launch['admission_protocol'],1)
        self.assertEqual(launch['native'],[])
        stopped=f.fence.request_stop('T42','stop-initializing',generation=2)
        self.assertNotEqual(proc.wait(timeout=8),0)
        proof=prove_native_session_exit(stopped,'claude',conf_dir=f.root/'conf')
        self.assertEqual({x['component'] for x in proof['launches'][0]['roots']},{'supervisor','child'})

    def test_actual_direct_codex_launcher_registers_client_and_stays_unqualified(self):
        import runpy
        import shutil
        case=runpy.run_path(str(BIN/'fleet-codex-no-daemon-fence-selftest.py'))['NoDaemonFenceTests']()
        case.setUp()
        self.addCleanup(case.doCleanups)
        f=case.fixture
        shutil.copy2(BIN/'fleet-codex.sh',f.bin/'fleet-codex.sh')
        # Stub configuration/services only; execute the real shell launcher and
        # real final admission boundary against the bounded fake Codex CLI.
        (f.bin/'fleet-launch-lib.sh').write_text('''FLEET_LAUNCH_DIR="$BIN"
FLEET_CODEX_VERSION_CHECK=0
fleet_launch_early() { :; }
fleet_launch_say() { :; }
fleet_launch_browser() { :; }
fleet_launch_mcp() { :; }
fleet_launch_cfg() { :; }
fleet_launch_trust_wait() { :; }
fleet_launch_settle() { :; }
fleet_launch_yield() { _fl_yield=(); }
fleet_timing_at() { :; }
fleet_launch_end() { :; }
''')
        f.launcher.write_text('#!/bin/bash\nexec "$TEST_ROOT/bin/fleet-codex.sh" "hello task"\n')
        proc=f.start(wrapper=False)
        f.wait_file('native.json',proc)
        actual=json.loads((f.root/'native.json').read_text())
        launch=f.fence.launch('T42')
        self.assertEqual(launch['admission_protocol'],0)
        self.assertEqual([x['component'] for x in launch['native']],['client'])
        self.assertFalse(actual['controlled'])
        self.assertFalse(actual['launch'])
        stopped=f.fence.request_stop('T42','stop-direct-codex',generation=2)
        self.assertNotEqual(proc.wait(timeout=8),0)
        for provider in ('codex','claude'):
            with self.assertRaises(FenceRefused):
                prove_native_session_exit(stopped,provider,conf_dir=f.root/'conf')

    def submit_stop(self):
        request=dict(operation_id=STOP,fleet_id=GRANT['execution_owner'].split('/')[0],
            action='worker_stop',actor='fixture',control_version=1,task_execution=self.stopped,
            params=dict(task='T42',worker_id=GRANT['execution_owner'],execution_endpoint=GRANT['execution_endpoint'],
                        start_operation_id=GRANT['operation_id'],generation=1,attempt_id=GRANT['attempt_id']))
        with patch('fleet_control.subprocess.Popen',return_value=Mock(wait=Mock(return_value=0))):
            self.control.submit(request)

    def authority(self,provider='codex'):
        return dict(control_version=1,task_execution=self.stopped,
                    start=dict(operation_id=GRANT['operation_id'],agent=provider,repo='',no_repo=True))

    def test_direct_codex_provider_comes_from_authenticated_start_not_component_agent(self):
        self.register(('agent',),protocol=0)
        self.submit_stop()
        self.control.read_native_exit_start=lambda snapshot, **kwargs: self.authority('codex')
        with self.assertRaises(FenceRefused): self.control.prepare_native_exit(STOP)

    def test_auth_outside_locks_and_ack_replay_uses_exact_saved_packet(self):
        self.register(('client',))
        self.submit_stop()
        def auth(snapshot, **kwargs):
            self.assertEqual(snapshot,self.stopped)
            with self.fence.store.connect() as db: db.execute('BEGIN IMMEDIATE')
            with self.fence._admission_lock('T42'): pass
            return self.authority()
        self.control.read_native_exit_start=auth
        first=self.control.prepare_native_exit(STOP)
        self.control.read_native_exit_start=lambda snapshot, **kwargs: (_ for _ in ()).throw(AssertionError('GET on retry'))
        self.assertEqual(self.control.prepare_native_exit(STOP),first)
        self.assertEqual(first['proof']['provider'],'codex')

    def test_auth_offline_or_any_snapshot_start_mismatch_refuses(self):
        self.register(('client',))
        self.submit_stop()
        self.control.read_native_exit_start=lambda snapshot, **kwargs: (_ for _ in ()).throw(OSError('offline'))
        with self.assertRaises(OSError): self.control.prepare_native_exit(STOP)
        for field,value in [('generation',3),('cancel_request','other'),('operation_id','other'),('execution_owner','')]:
            auth=copy.deepcopy(self.authority());auth['task_execution'][field]=value
            self.control.read_native_exit_start=lambda snapshot,auth=auth, **kwargs:auth
            with self.subTest(field=field),self.assertRaises(FenceRefused): self.control.prepare_native_exit(STOP)
        auth=self.authority();auth['start']['operation_id']='different-start'
        self.control.read_native_exit_start=lambda snapshot, **kwargs:auth
        with self.assertRaises(FenceRefused): self.control.prepare_native_exit(STOP)


if __name__=='__main__': unittest.main()
