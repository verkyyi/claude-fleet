#!/usr/bin/env python3
# selftest-entry
"""Fresh controlled continuation keeps the exact workspace and historical context."""
import copy
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import time
import unittest
from unittest.mock import Mock, patch
import fleet_task_continuation as continuation
import fleet_dispatch as dispatch
from fleet_hub_common import Fault, canonical, validate_write

BIN = Path(__file__).resolve().parent
base = runpy.run_path(str(BIN / 'fleet-task-local-continuation-selftest.py'))
GRANT, FLEET, EXIT = (base[k] for k in ('GRANT', 'FLEET', 'EXIT'))
OLD_FID = GRANT['execution_owner'].split('/')[1]
ENVELOPE = dict(version=1, request_id='new-start', requested_agent='codex', resolved_agent='codex',
                agent_source='explicit', task='T42', generation=3, attempt_id='task:T42:g3')
CONTINUATION = dict(version=1, exit_operation_id=EXIT)


class ContinuationStartTests(unittest.TestCase):
    def setUp(self):
        self.base = base['ContinuationTests']()
        self.base.setUp()
        self.addCleanup(self.base.doCleanups)
        self.root = self.base.root.resolve()
        self.node = self.base.control
        self.grant = dict(self.base.next, operation_id='55555555-1111-4111-8111-aaaaaaaaaaaa')
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.git('init', str(self.repo))
        self.git('-C', str(self.repo), '-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '--allow-empty', '-m', 'fixture')
        self.wt = self.root / 'repo-scratch-17'
        self.git('-C', str(self.repo), 'worktree', 'add', '-b', 'scratch-17', str(self.wt))
        self.gd = Path(self.git('-C', str(self.wt), 'rev-parse', '--absolute-git-dir'))
        (self.gd / 'fleet-id').write_text(OLD_FID + '\n')
        (self.gd / 'fleet-task').write_text('T42\n')
        (self.wt / 'existing.txt').write_text('unfinished user work\n')
        self.ledger = self.root / 'ids' / (OLD_FID + '.ndjson')
        self.ledger.parent.mkdir()
        self.opened = dict(ev='opened', id=OLD_FID, seq=1, task='T42', repo='owner/repo',
                           worktree=str(self.wt), agent='claude', title='original task')
        self.write_ledger()
        self.transcript = self.root / 'source.jsonl'
        self.transcript.write_text('last requirement and progress\n')
        self.past = dict(id=OLD_FID, agent='claude', readable=True, transcript=str(self.transcript))
        self.authority = dict(control_version=1, task_execution=self.grant,
            start=dict(operation_id=self.grant['operation_id'], agent='codex', repo='owner/repo',
                       no_repo=False, continuation=CONTINUATION),
            source_start=dict(operation_id=GRANT['operation_id'], agent='claude', repo='owner/repo', no_repo=False))

    def git(self, *args):
        return subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', *args], check=True,
                              text=True, capture_output=True).stdout.strip()

    def write_ledger(self):
        self.ledger.write_text(json.dumps(self.opened) + '\n')

    def plan(self, **kwargs):
        return continuation.continuation_plan(self.grant, CONTINUATION, self.authority,
            conf_dir=self.root, history=lambda *_: self.past, **kwargs)

    def test_protocol_requires_exact_continuation(self):
        for value in (None, {}, {'version': True, 'exit_operation_id': 'x'},
                      {'version': 1, 'exit_operation_id': 'x', 'path': '/tmp'}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                continuation.validate_continuation(value)
        validate_write('worker_start', dict(kind='scratch', task='T42', no_repo=True,
                       continuation=CONTINUATION), task_execution=self.grant)
        for changes in ({'path': '/tmp'}, {'continuation': dict(CONTINUATION, worktree='/tmp')}):
            with self.assertRaises(Fault):
                validate_write('worker_start', dict(kind='scratch', task='T42', no_repo=True,
                    continuation=CONTINUATION, **{k:v for k,v in changes.items() if k != 'continuation'})
                    if 'continuation' not in changes else dict(kind='scratch', task='T42', no_repo=True, **changes),
                    task_execution=self.grant)
        with self.assertRaises(Fault):
            validate_write('worker_start', dict(kind='scratch', no_repo=True, continuation=CONTINUATION))

    def test_local_first_start_needs_no_node_start_journal(self):
        with self.node.store.connect() as db:
            self.assertIsNone(db.execute('SELECT id FROM operations WHERE id=?', (GRANT['operation_id'],)).fetchone())
        plan = self.plan()
        self.assertEqual(plan['worktree'], str(self.wt))
        self.assertEqual(plan['source_fid'], OLD_FID)
        self.assertIn(str(self.transcript), plan['seed'])
        self.assertIn(str(self.ledger), plan['seed'])
        self.assertNotIn('original task', plan['seed'])
        self.assertEqual((self.wt / 'existing.txt').read_text(), 'unfinished user work\n')

    def test_provider_is_current_start_not_initial_task_provider(self):
        got = dispatch.check_current(ENVELOPE, execution=self.grant, continuation=CONTINUATION,
                                     read_start=lambda _: self.authority,
                                     read=lambda _: self.fail('read initial task provider'))
        self.assertEqual(got, self.authority)
        for mutate in (lambda a: a['start'].update(agent='claude'),
                       lambda a: a['start'].update(operation_id='old-start'),
                       lambda a: a['task_execution'].update(cancel_request='stop-new'),
                       lambda a: a['start'].update(continuation=dict(CONTINUATION, version=True)),
                       lambda a: a['start'].update(no_repo=0)):
            value = copy.deepcopy(self.authority); mutate(value)
            with self.assertRaises(ValueError):
                dispatch.check_current(ENVELOPE, execution=self.grant, continuation=CONTINUATION,
                                       read_start=lambda _: value)
        with self.assertRaises(ValueError):
            dispatch.check_current(ENVELOPE, execution=self.grant, continuation=None, read_start=lambda _: self.authority)

    def test_source_facts_and_ack_required(self):
        for key, wrong in (('operation_id', 'other'), ('agent', 'codex'), ('repo', 'other/repo'), ('no_repo', True)):
            saved = self.authority['source_start'][key]
            self.authority['source_start'][key] = wrong
            with self.assertRaises(ValueError): self.plan()
            self.authority['source_start'][key] = saved
        self.base.replace_receipt(lambda r: r.update(confirmed=False))
        with self.assertRaises(ValueError): self.plan()

    def test_workspace_and_ledger_mismatch_refuse_without_mutation(self):
        for key, wrong in (('task', 'T43'), ('repo', 'other/repo'), ('worktree', str(self.repo)),
                           ('worktree', str(self.wt / '..' / self.wt.name)), ('seq', 2), ('id', FLEET)):
            saved = self.opened[key]; self.opened[key] = wrong; self.write_ledger()
            with self.assertRaises((ValueError, OSError)): self.plan()
            self.opened[key] = saved; self.write_ledger()
        for marker, value in (('fleet-id', FLEET), ('fleet-task', 'T43')):
            path = self.gd / marker; saved = path.read_text(); path.write_text(value)
            with self.assertRaises(ValueError): self.plan()
            path.write_text(saved)
        self.assertEqual(self.base.fence.read('T42')['cancel_request'], base['STOP'])

    def test_no_repo_requires_explicit_source_and_local_home(self):
        for source in ('start', 'source_start'):
            self.authority[source].update(repo='', no_repo=True)
        self.opened.pop('repo'); self.opened.pop('worktree'); self.write_ledger()
        plan = self.plan(home=lambda: str(self.root))
        self.assertEqual(plan['cwd'], str(self.root)); self.assertEqual(plan['worktree'], '')
        self.authority['source_start']['no_repo'] = False
        with self.assertRaises(ValueError): self.plan(home=lambda: str(self.root))
        with patch.dict(os.environ, HOME=str(self.root)), self.assertRaises(ValueError):
            continuation.managed_home()

    def test_unknown_history_refuses_before_claim(self):
        self.past['readable'] = False
        with self.assertRaises(ValueError): self.plan()
        self.assertNotIn('continuation', self.base.journal()['native_exit_receipt'])

    def test_offline_current_authority_does_not_claim_or_start(self):
        request = dict(operation_id=self.grant['operation_id'],fleet_id=FLEET,action='worker_start',actor='fixture',
                       control_version=1,task_execution=self.grant,
                       params=dict(kind='scratch',task='T42',repo='owner/repo',agent='codex',
                                   dispatch=ENVELOPE,continuation=CONTINUATION))
        with self.node.store.connect() as db:
            db.execute('INSERT INTO operations VALUES (?,?,?,?,?,?,?,?,NULL)',
                (request['operation_id'],FLEET,'worker_start',canonical(request),'fixture','accepted',time.time(),time.time()))
        with patch('fleet_dispatch.read_execution_start',side_effect=OSError('offline')), \
             patch.object(self.node,'fleet',return_value=dict(name='fixture')), \
             patch.object(self.node,'adapter',side_effect=AssertionError('offline started')), \
             patch('fleet_task_execution.continue_execution',side_effect=AssertionError('offline claimed')):
            self.node._execute_once(request['operation_id'])
        result=self.node.get_operation(request['operation_id'])
        self.assertEqual(result['status'],'failed')
        self.assertEqual(result['result']['error']['code'],'TASK_START_REFUSED')
        self.assertNotIn('continuation',self.base.journal()['native_exit_receipt'])

    def test_wrapper_checks_current_start_provider_before_native_launch(self):
        native = runpy.run_path(str(BIN/'fleet-task-execution-native-selftest.py'))['NativeExecutionTests']()
        native.setUp(); self.addCleanup(native.doCleanups)
        for name in ('fleet_dispatch.py','fleet_task_continuation.py'):
            shutil.copy2(BIN/name,native.bin/name)
        envelope=dict(ENVELOPE,generation=native.snapshot['generation'],attempt_id=native.snapshot['attempt_id'])
        response=dict(control_version=1,task_execution=native.snapshot,
                      start=dict(operation_id=native.snapshot['operation_id'],agent='codex',repo='owner/repo',no_repo=False))
        metadata=native.root/'start.json'; metadata.write_text(json.dumps(response))
        reader=native.bin/'fleet-task-record.sh'
        original=reader.read_text()
        reader.write_text('if [ "$1" = execution-start ]; then cat "$START_FILE"; exit; fi\n'+original)
        env=dict(native.env,FLEET_START_DISPATCH=json.dumps(envelope),START_FILE=str(metadata))
        (native.root/'release').touch()
        child=native.start(env=env)
        native.wait_file('native.json',child)
        self.assertTrue((native.root/'native.json').is_file())

    def test_controller_continues_with_fresh_seed_same_workspace_and_new_fid(self):
        request = dict(operation_id=self.grant['operation_id'], fleet_id=FLEET, action='worker_start', actor='fixture',
                       control_version=1, task_execution=self.grant,
                       params=dict(kind='new', task='T42', repo='owner/repo', title='original task',
                                   body='DO NOT REPLAY THE FIRST SENTENCE', agent='codex',
                                   dispatch=ENVELOPE, continuation=CONTINUATION))
        with self.node.store.connect() as db:
            db.execute('INSERT INTO operations VALUES (?,?,?,?,?,?,?,?,NULL)',
                (request['operation_id'],FLEET,'worker_start',canonical(request),'fixture','accepted',time.time(),time.time()))
        calls = []
        def adapter(mode, *args, **kwargs):
            calls.append((mode,args,kwargs))
            fid = kwargs['execution']['execution_owner'].split('/')[1]
            return 0, ('@42\tscratch-17\t%s\t%s\n' % (self.wt,fid)).encode(), b''
        import fleet_task_execution as execution
        original_continue = execution.continue_execution
        def continue_actual(snapshot, fleet_id, exit_id, **kwargs):
            return original_continue(snapshot,fleet_id,exit_id,**kwargs,read=lambda _:self.grant,
                read_stops=lambda:dict(control_version=1,task_executions=[]),
                call=lambda _,body:dict(self.grant,execution_owner=body['worker_id']))
        def workers(*args):
            fid = self.base.fence.read('T42')['execution_owner'].split('/')[1]
            return dict(workers=[dict(identity=fid, window_id='@42', agent='codex')], observed_at=time.time())
        with patch('fleet_dispatch.read_execution_start', return_value=self.authority), \
             patch('fleet_task_continuation.local_history',return_value=self.past), \
             patch('fleet_task_execution.continue_execution',side_effect=continue_actual), \
             patch.object(self.node,'fleet',return_value=dict(name='fixture')), \
             patch.object(self.node,'adapter',side_effect=adapter), \
             patch.object(self.node,'workers',side_effect=workers), \
             patch.object(self.node,'watch_ready'):
            self.node._execute_once(request['operation_id'])
        self.assertEqual(len(calls),1, self.node.get_operation(request['operation_id']))
        _, args, kwargs = calls[0]
        self.assertNotEqual(kwargs['execution']['execution_owner'], GRANT['execution_owner'])
        self.assertEqual(kwargs['execution']['task_fid'], GRANT['task_fid'])
        self.assertEqual(kwargs['continuation'], CONTINUATION)
        self.assertIn(str(self.transcript).encode(), kwargs['payload'])
        self.assertNotIn(b'DO NOT REPLAY', kwargs['payload'])
        self.assertNotIn('--resume', args)
        self.assertEqual((self.wt / 'existing.txt').read_text(), 'unfinished user work\n')

    def test_adapter_passes_only_receipt_not_caller_paths(self):
        with patch('fleet_control.run',return_value=(0,b'',b'')) as run:
            self.node.adapter('start','fixture','new',execution=self.grant,continuation=CONTINUATION)
        env = run.call_args.kwargs['env']
        self.assertEqual(env['FLEET_TASK_CONTINUATION'],EXIT)
        self.assertNotIn(str(self.wt), json.dumps(env))

    def test_real_raw_spawner_keeps_workspace_history_and_only_deduplicates_new_fid(self):
        import fleet_task_execution as execution
        claimed = execution.continue_execution(self.grant,FLEET,EXIT,conf_dir=self.root,
            read=lambda _:self.grant,read_stops=lambda:dict(control_version=1,task_executions=[]),
            call=lambda _,body:dict(self.grant,execution_owner=body['worker_id']))
        new_fid = claimed['execution_owner'].split('/')[1]
        self.authority['task_execution'] = claimed
        self.git('-C', str(self.wt), 'branch', '-m', 'user-renamed-branch')
        native_id = 'cccccccc-4444-4444-8444-cccccccccccc'
        with self.ledger.open('a') as stream:
            stream.write(json.dumps(dict(ev='native',id=OLD_FID,seq=2,agent='claude',native=native_id,trigger='startup'))+'\n')
        projects = self.root / 'projects' / 'repo'; projects.mkdir(parents=True)
        (projects / (native_id + '.jsonl')).write_text(json.dumps(dict(sessionId=native_id,type='user',message={'content':'continue existing work'}))+'\n')
        before = self.ledger.read_bytes()
        fakebin = self.root / 'raw-bin'; fakebin.mkdir()
        for source in BIN.iterdir():
            if source.is_file():
                if source.suffix == '.py': shutil.copy2(source, fakebin/source.name)
                else: (fakebin / source.name).symlink_to(source)
        reader = fakebin / 'fleet-task-record.sh'; reader.unlink()
        reader.write_text('''#!/bin/bash
case "$1" in
 execution-start) cat "$FIXTURE_START" ;;
 execution-get) cat "$FIXTURE_GRANT" ;;
 execution-list) printf '{"control_version":1,"task_executions":[]}' ;;
 *) exit 3 ;;
esac
''')
        start_file=self.root/'start.json'; start_file.write_text(json.dumps(self.authority))
        grant_file=self.root/'grant.json'; grant_file.write_text(json.dumps(claimed))
        tools = self.root/'tools'; tools.mkdir()
        tmux = tools/'tmux'
        tmux.write_text('''#!/usr/bin/env python3
import json,os,pathlib,sys
a=sys.argv[1:]
with open(os.environ['FIXTURE_TMUX_LOG'],'a') as f: f.write(json.dumps(a)+'\\n')
if a and a[0] in ('-L','-S'): a=a[2:]
cmd=a[0] if a else ''
if cmd=='display-message':
 s=' '.join(a)
 if 'session_name' in s: print('fixture')
 elif 'window_name' in s and '@fleet_id' in s: print('@42\\ttask-T42\\t'+os.environ['FIXTURE_WORKTREE']+'\\t'+os.environ['FIXTURE_NEW_FID'])
 elif '@fleet_id' in s: print(os.environ['FIXTURE_NEW_FID'])
 elif 'pane_id' in s: print('%42')
 elif 'window_id' in s: print('@42')
elif cmd=='new-window': print('@42')
elif cmd=='show-options' and '@fleet_id' in a: print(os.environ['FIXTURE_NEW_FID'])
elif cmd=='list-sessions': print('fixture')
elif cmd=='list-windows':
 s=' '.join(a)
 if '@task' in s and '@fleet_id' in s:
  print('@41|T42|'+os.environ['FIXTURE_OLD_FID']+'|working')
  if pathlib.Path(os.environ['FIXTURE_DUP']).exists(): print('@42|T42|'+os.environ['FIXTURE_NEW_FID']+'|working')
''')
        tmux.chmod(0o700)
        fleetdir=self.root/'fleets'/'fixture'; (fleetdir/'repos').mkdir(parents=True)
        (fleetdir/'identity').write_text(FLEET+'\n')
        (fleetdir/'conf').write_text('FLEET_MAX_SESSIONS=0\nCCQUOTA_FLEET=0\n')
        (fleetdir/'repos'/'.order').write_text('owner-repo\n')
        (fleetdir/'repos'/'owner-repo.conf').write_text('FLEET_REPO="owner/repo"\nFLEET_MAIN='+json.dumps(str(self.repo))+'\nFLEET_BASE_BRANCH="'+self.git('-C',str(self.repo),'branch','--show-current')+'"\n')
        log=self.root/'tmux.log'; duplicate=self.root/'duplicate'
        env={k:v for k,v in os.environ.items() if not k.startswith(('FLEET_','CCQUOTA_'))
             and k not in ('TMUX','TMUX_PANE','CLAUDE_CONFIG_DIR','CLAUDE_PROJECTS_DIR')}
        env.update(HOME=str(self.root),PATH=str(tools)+os.pathsep+os.environ['PATH'],TMPDIR=str(self.root),
            FLEET_CONF_DIR=str(self.root), FLEET_SKIP_GLOBAL_CONF='1',FLEET_ORIGIN_GATE='0',
            FLEET_TASK_EXECUTION=json.dumps(claimed), FLEET_TASK_CONTINUATION=EXIT,
            FLEET_DISPATCH=json.dumps(ENVELOPE),FLEET_ID_PUSH='0',CCQUOTA_FLEET='0',
            FLEET_GLOBAL_MAX_SESSIONS='0',FLEET_MACHINE_MAX_SESSIONS='0',
            FLEET_ADMIT_MEM_READING='65536 65536', FLEET_ADMIT_CPU_READING='-',
            CLAUDE_PROJECTS_DIR=str(projects.parent),FIXTURE_START=str(start_file),FIXTURE_GRANT=str(grant_file),
            FIXTURE_TMUX_LOG=str(log),FIXTURE_OLD_FID=OLD_FID,FIXTURE_NEW_FID=new_fid,FIXTURE_DUP=str(duplicate),
            FIXTURE_WORKTREE=str(self.wt))
        args=['bash',str(fakebin/'dash-raw-session.sh'),'fixture','--repo','owner/repo','--task','T42',
              '--agent','codex','--origin','hub','--node','local','--print']
        result=subprocess.run(args,env=env,text=True,capture_output=True,timeout=35)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn(new_fid,result.stdout)
        self.assertIn(str(self.wt),result.stdout)
        new_ledger=self.root/'ids'/(new_fid+'.ndjson')
        events=[json.loads(line) for line in new_ledger.read_text().splitlines()]
        opening=next(e for e in events if e['ev']=='opened')
        self.assertEqual(opening['prev'],OLD_FID)
        self.assertEqual(opening['task'],'T42')
        self.assertEqual(opening['worktree'],str(self.wt))
        self.assertEqual(self.ledger.read_bytes(),before)
        self.assertEqual((self.gd/'fleet-id').read_text().strip(),new_fid)
        commands=[json.loads(line) for line in log.read_text().splitlines()]
        launches=[a for a in commands if 'new-window' in a]
        self.assertEqual(len(launches),1)
        self.assertNotIn('--resume',json.dumps(launches))
        self.assertIn(str(self.wt),json.dumps(launches))
        duplicate.touch()
        result=subprocess.run(args,env=env,text=True,capture_output=True,timeout=35)
        self.assertEqual(result.returncode,0,result.stderr)
        commands=[json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual(len([a for a in commands if 'new-window' in a]),1)


if __name__ == '__main__':
    unittest.main()
