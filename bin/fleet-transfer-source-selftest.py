#!/usr/bin/env python3
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
"""fleet_transfer_source.py — the source checks a manual move keeps (T546).

Moved unchanged from the retired quota failover planner: `settled` (a looping
Codex between rounds, #786), the background inventory (#873) and
`terminate-background` (#871). Isolated: no live tmux or provider calls.
"""
import contextlib
import concurrent.futures
import importlib.util
import io
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m


src = module('transfer_source', 'fleet_transfer_source.py')



class BrokenHookMaintenance(unittest.TestCase):
    def test_missing_hook_is_verified_from_native_argv(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            command = 'python3 ' + repr(str(root/'old/bin/fleet-codex-session.py')) + ' hook'
            flags = ['hooks.Stop=[{hooks=[{type="command",command=' + json.dumps(command) + '}]}]']
            self.assertEqual(src.missing_hook_paths(flags), [str(root/'old/bin/fleet-codex-session.py')])
            (root/'old/bin').mkdir(parents=True)
            (root/'old/bin/fleet-codex-session.py').write_text('# exists')
            self.assertEqual(src.missing_hook_paths(flags), [])
            self.assertEqual(src.missing_hook_paths(['--prompt', command]), [])

    def test_paused_loop_repair_cannot_resend_unknown_attempt(self):
        value = dict(id='original-loop', status='paused', thread_id='sid', home='/home/exact',
            worktree='/work', schedule=dict(interval_seconds=1200, next_run_at=100, prompt='original'),
            detail="[Errno 2] No such file or directory: '/gone/bin/fleet-input.py'",
            last_attempt=dict(state='accepted'), controller_pid=123)
        source = dict(session_id='sid', home='/home/exact', worktree='/work')
        src.repairable_loop(value, source)
        for state in ('delivering', 'unknown', 'failed'):
            bad = dict(value, last_attempt=dict(state=state))
            with self.assertRaisesRegex(ValueError, 'delivery'):
                src.repairable_loop(bad, source)
        for change in (dict(status='stopped'), dict(thread_id='other'),
                       dict(detail='RPC timeout'), dict(pending_delivery={'text':'unknown'})):
            with self.assertRaises(ValueError): src.repairable_loop(dict(value, **change), source)
        self.assertEqual(value['schedule']['next_run_at'], 100)

    def test_original_timer_rebind_retains_id_and_rejects_changed_delivery(self):
        from contextlib import contextmanager
        import copy
        value = dict(id='original-loop', status='stopped', thread_id='sid', home='/old-home',
            fleet=dict(session='test', window_id='@2', pane_id='%2'), generation=0,
            schedule=dict(interval_seconds=1200, next_run_at=100, prompt='original'),
            last_attempt=dict(state='accepted'), controller_pid=123, deliveries=7)
        before = copy.deepcopy(value); before['status']='paused'
        source = dict(session='test', window='@2', pane='%2', home='/new-mirror',
                      codex_identity=dict(remote='unix:///new.sock'))
        @contextmanager
        def locked(path): yield value
        saved=[]
        module=dict(locked=locked, current=lambda v:None, save=lambda p,v:saved.append(v))
        with patch.object(src.runpy,'run_path',return_value=module), \
             patch.object(src.os,'kill',side_effect=ProcessLookupError), \
             patch.object(src,'run',return_value='42'), patch.object(src.time,'time',return_value=5000):
            result=src.repair_loop_restore(dict(path='/private/state.json',before=before),source)
            self.assertEqual(result['id'],'original-loop')
            self.assertEqual(result['schedule']['next_run_at'],6200)
            self.assertEqual(result['schedule']['prompt'],'original')
            self.assertEqual(saved[0]['deliveries'],7)
            self.assertEqual(saved[0]['driver'],'quotawatch')
            value['last_attempt']={'state':'delivering'}
            with self.assertRaisesRegex(ValueError,'delivery changed'):
                src.repair_loop_restore(dict(path='/private/state.json',before=before),source)
            self.assertEqual(len(saved),1)

    def test_live_proof_keeps_old_marks_but_never_ignores_input_queue_or_tools(self):
        from contextlib import ExitStack
        import fleet_session_gate as gate
        import fleet_native_proc
        with tempfile.TemporaryDirectory() as tmp, ExitStack() as stack:
            store=Path(tmp); current=store/('b'*40)/'bin';current.mkdir(parents=True)
            (current/'fleet-codex-session.py').write_text('# current hook')
            missing=store/('a'*40)/'bin/fleet-codex-session.py'
            flags=['hooks.Stop=[{hooks=[{type="command",command='+json.dumps('python3 '+str(missing))+'}]}]']
            source=dict(agent='codex',session_id='sid',pid=12,pane='%2',window='@2',state='working',
                        worktree='/work',home='/home',codex_identity={'remote':'unix:///exact.sock'})
            view={'state':'empty','busy':False,'text':''}; queue={'data':[],'nextCursor':None}
            class Rpc:
                initialized={'codexHome':'/home'}
                def __init__(self,*a,**kw):pass
                def call(self,*a):return queue
                def close(self):pass
            stack.enter_context(patch.object(src,'BIN',current))
            stack.enter_context(patch.object(src,'inspect',return_value=source))
            stack.enter_context(patch.object(src,'run',side_effect=lambda a,**k:{
                '#{@fleet_id}':'fid','#{window_panes}':'1',
                '#{@parked}#{@park_start}#{@agent_transfer_request}':'',
                '#{@handoff_armed}':'','#{@agent_transfer_until}':''}[a[-1]]))
            stack.enter_context(patch.dict(src.TRANSFER,process_rows=lambda:{12:(1,'bash')}))
            stack.enter_context(patch.object(src.runpy,'run_path',side_effect=lambda p:{
                'fleet_worker_life.py':{'ARGV':{'process_argv':lambda pid:flags}},
                'fleet-input.py':{'snapshot':lambda *a,**k:view}}[Path(p).name]))
            stack.enter_context(patch.object(src,'native_thread',return_value={
                'status':{'type':'idle'},'turns':[{'id':'finished','status':'completed','items':[]}]}))
            quiet=stack.enter_context(patch.object(src,'quiet_processes'))
            stack.enter_context(patch.object(src,'RPC',Rpc))
            pending=stack.enter_context(patch.object(gate,'records',return_value=[]))
            stack.enter_context(patch.object(fleet_native_proc,'process',return_value={'birth':'exact'}))
            result=src.repair_check('test','%2','fid','sid')
            self.assertEqual(result['source']['state'],'working')
            quiet.assert_called_once_with(source,rpc_timeout=30)
            with self.assertRaisesRegex(ValueError,'FID/SID'):
                src.repair_check('test','%2','other','sid')
            view.update(state='unknown',busy=True)
            with self.assertRaisesRegex(ValueError,'input.*empty'):
                src.repair_check('test','%2','fid','sid')
            view.update(state='empty',busy=False);queue['data']=[{'id':'pending'}]
            with self.assertRaisesRegex(ValueError,'queued input'):
                src.repair_check('test','%2','fid','sid')
            queue['data']=[];pending.return_value=[{'state':'native'}]
            with self.assertRaisesRegex(ValueError,'admitted input'):
                src.repair_check('test','%2','fid','sid')
            pending.return_value=[];quiet.side_effect=ValueError('active tool')
            with self.assertRaisesRegex(ValueError,'active tool'):
                src.repair_check('test','%2','fid','sid')

    @unittest.skipUnless(__import__('shutil').which('tmux'), 'tmux unavailable')
    def test_public_migrate_entry_fences_the_exact_window_and_forwards_one_plan(self):
        import shutil,sys,uuid
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve(); work=root/'work';work.mkdir(); stub=root/'bin';stub.mkdir()
            label='repair-test-'+uuid.uuid4().hex[:12];fid=str(uuid.uuid4());sid=str(uuid.uuid4())
            conf=root/'conf';(conf/'fleets'/label).mkdir(parents=True)
            (conf/'fleets'/label/'conf').write_text('FLEET_SESSION='+label+'\n')
            log=root/'helper.json'
            (stub/'python3').write_text('#!'+sys.executable+'\nimport os,sys,json\n'
                +'if len(sys.argv)>2 and sys.argv[1].endswith("/fleet_transfer_source.py") and sys.argv[2]=="repair-hooks":\n'
                +' open('+repr(str(log))+',"w").write(json.dumps(sys.argv[2:]))\n print("ready")\n'
                +'else: os.execv('+repr(sys.executable)+', ['+repr(sys.executable)+']+sys.argv[1:])\n')
            (stub/'python3').chmod(0o755)
            env={k:v for k,v in os.environ.items() if not k.startswith('FLEET_') and k not in ('TMUX','TMUX_PANE')}
            env.update(HOME=str(root),FLEET_CONF_DIR=str(conf),FLEET_SKIP_GLOBAL_CONF='1',PATH=str(stub)+os.pathsep+os.environ['PATH'])
            tm=lambda *a:subprocess.check_output(['tmux','-L',label,*a],text=True,env=env).strip()
            try:
                win=tm('new-session','-d','-s',label,'-c',str(work),'-P','-F','#{window_id}')
                tm('set-option','-w','-t',win,'@fleet_id',fid)
                tm('set-option','-w','-t',win,'@worktree',str(work))
                args=['bash',str(Path(__file__).with_name('fleet-migrate.sh')),'--session',label,
                      '--repair-hooks','--expected-fid',fid,'--expected-session-id',sid,'--dry-run',win]
                result=subprocess.run(args,text=True,capture_output=True,env=env,timeout=20)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                forwarded=json.loads(log.read_text());self.assertIn('--dry-run',forwarded)
                self.assertEqual(forwarded[forwarded.index('--fid')+1],fid)
                self.assertEqual(forwarded[forwarded.index('--sid')+1],sid)
                log.unlink();args[args.index('--expected-fid')+1]=str(uuid.uuid4())
                result=subprocess.run(args,text=True,capture_output=True,env=env,timeout=20)
                self.assertNotEqual(result.returncode,0);self.assertFalse(log.exists())
                self.assertEqual(tm('display-message','-p','-t',win,'#{@fleet_id}'),fid)
            finally:
                subprocess.run(['tmux','-L',label,'kill-server'],capture_output=True,env=env)

    def test_exact_maintenance_success_and_unknown_completion_never_relaunch(self):
        from contextlib import ExitStack
        import fleet_session_gate as gate
        with tempfile.TemporaryDirectory() as tmp, ExitStack() as stack:
            root=Path(tmp); (root/'handoffs').mkdir(); work=root/'work';work.mkdir()
            transcript=root/'rollout.jsonl';transcript.write_text('{}\n')
            source=dict(agent='codex',pid=12,session='test',window='@2',pane='%2',
                worktree=str(work),home='/real-home',transcript=str(transcript),session_id='sid',
                codex_identity=dict(remote='unix:///old.sock'))
            proof=dict(source=source,fid='fid',birth={'pid':12},input={'state':'empty'},
                       missing_hooks=['/gone/hook.py'],loop=None,last_turn='completed-turn')
            successor=dict(source,pid=22,codex_identity=dict(remote='unix:///new.sock'))
            checks=stack.enter_context(patch.object(src,'repair_check',return_value=proof))
            stack.enter_context(patch.dict(os.environ,FLEET_CONF_DIR=str(root),FLEET_GATE_DIR=str(root/'gate')))
            stack.enter_context(patch.object(src,'repair_target_home',return_value='/real-home'))
            stack.enter_context(patch.object(src,'inspect',return_value=successor))
            stack.enter_context(patch.object(src,'process_start',return_value=('','')))
            stack.enter_context(patch.object(src.time,'sleep'))
            class Rpc:
                initialized={'userAgent':'claude_fleet/0.162.1'}
                def __init__(self,*a,**kw):pass
                def call(self,*a):return {'thread':{'id':'sid','cwd':str(work)}}
                def close(self):pass
            stack.enter_context(patch.object(src,'RPC',Rpc))
            stack.enter_context(patch.object(src,'native_hook_flags',return_value=(
                ['hooks.Stop=fleet-codex-session.py bash-guard.py base-readonly-guard.py'],[22])))
            calls=[]; fail=[False]
            def run(argv,**kw):
                calls.append(list(map(str,argv)))
                if 'respawn-pane' in argv and fail[0]: raise ValueError('unknown spawn result')
                if argv[-1]=='#{pane_pid}':return '42'
                if argv[-1]=='#{@fleet_id}':return 'fid'
                return ''
            stack.enter_context(patch.object(src,'run',side_effect=run))
            with contextlib.redirect_stdout(io.StringIO()):src.repair_hooks('test','%2','fid','sid')
            receipts=list((root/'handoffs').glob('hook-repair-*/receipt.json'))
            self.assertEqual(len(receipts),1)
            result=json.loads(receipts[0].read_text());self.assertEqual(result['state'],'resumed')
            self.assertEqual(result['target']['session_id'],'sid')
            launch=next(c[-1] for c in calls if 'respawn-pane' in c)
            self.assertIn('--resume sid',launch);self.assertNotIn('||',launch)
            self.assertEqual(sum('respawn-pane' in c for c in calls),1)
            checks.side_effect=[proof,dict(proof,last_turn='new-turn')]
            with self.assertRaisesRegex(ValueError,'source changed'):
                src.repair_hooks('test','%2','fid','sid')
            self.assertEqual(sum('respawn-pane' in c for c in calls),1)
            checks.side_effect=None
            fail[0]=True
            with self.assertRaisesRegex(ValueError,'unknown spawn'):
                src.repair_hooks('test','%2','fid','sid')
            count=checks.call_count
            with self.assertRaisesRegex(ValueError,'completion is unknown'):
                src.repair_hooks('test','%2','fid','sid')
            self.assertEqual(checks.call_count,count)
            self.assertEqual(sum('respawn-pane' in c for c in calls),2)

class CurrentSchedulerEvidence(unittest.TestCase):
    def test_old_wakeup_is_not_a_current_loop_or_a_live_export(self):
        import fleet_transfer_cron as cron
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'source.jsonl'
            rows = [
                dict(timestamp='1970-01-01T00:16:40Z', message={'content':[
                    dict(type='tool_use', id='old', name='ScheduleWakeup', input={'seconds':60})]}),
                dict(timestamp='1970-01-01T00:16:41Z', message={'content':[
                    dict(type='tool_result', tool_use_id='old', content='scheduled')]}),
            ]
            path.write_text(''.join(json.dumps(r)+'\n' for r in rows))
            with patch.object(cron, 'process_start', return_value=2000):
                self.assertFalse(cron.has_native_activity(path, 42))
                with self.assertRaisesRegex(ValueError, 'fresh CronList'):
                    cron.live_list(path, 42, 2100)
            # Even a wakeup from this lifetime is no export of current jobs.
            with patch.object(cron, 'process_start', return_value=900):
                self.assertTrue(cron.has_native_activity(path, 42))
                with self.assertRaisesRegex(ValueError, 'fresh CronList'):
                    cron.live_list(path, 42, 1100)


class ExternalQuotaLoop(unittest.TestCase):
    def test_exact_user_authorization_and_process_not_historical_export(self):
        import fleet_transfer_cron as cron
        import fleet_transfer_durable as durable
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'source.jsonl'
            row = dict(type='user', uuid='user-loop', sessionId='sid',
                       message={'content':[dict(type='text', text='/loop 30m check task')]})
            path.write_text(json.dumps(row)+'\n')
            source = dict(session='test', pane='%2', pid=42, session_id='sid', transcript=str(path))
            raw = dict(prompt='check task', interval_seconds=1800, quota_replacement=dict(
                version=1, fid='fid', session_id='sid', pid=42, proc_start='exact-start',
                user_message_uuid='user-loop', invocation='/loop 30m check task'))
            plan = Path(tmp)/'replacement.json'; plan.write_text(json.dumps(raw))
            def run(argv, **kw):
                return 'fid' if argv[-1] == '#{@fleet_id}' else ''
            with patch.dict(os.environ, FLEET_QUOTA_LOOP_REPLACEMENT=str(plan)), \
                 patch.object(src, 'run', side_effect=run), \
                 patch.object(durable, 'proc_start', return_value='exact-start'), \
                 patch.object(cron, 'check_durable_store', return_value=None):
                proof = src.quota_loop_replacement(source, 'kind=wakeup next=100 ttl=60')
                self.assertEqual(proof['mode'], 'authorized-replacement')
                self.assertEqual(proof['authorization']['user_message_uuid'], 'user-loop')
                self.assertNotIn('native_source', proof)
                for key, value in (('pid', 43), ('session_id','other'), ('fid','other'),
                                   ('proc_start','reused-pid'), ('invocation','/loop 30m other')):
                    bad = dict(raw, quota_replacement=dict(raw['quota_replacement'], **{key:value}))
                    plan.write_text(json.dumps(bad))
                    with self.subTest(key=key), self.assertRaises(ValueError):
                        src.quota_loop_replacement(source, '')
                plan.write_text(json.dumps(dict(raw, prompt='different task')))
                with self.assertRaises(ValueError): src.quota_loop_replacement(source, '')
                plan.write_text(json.dumps(raw))
                with patch.object(cron, 'check_durable_store', return_value={'state':'claimed'}):
                    with self.assertRaisesRegex(ValueError, 'durable journal'):
                        src.quota_loop_replacement(source, '')
                previous = Path(tmp)/'previous'; (previous/'loop').mkdir(parents=True)
                (previous/'loop/state.json').write_text('{"status":"active"}')
                with patch.object(src, 'run', side_effect=lambda argv, **kw:
                                  'fid' if argv[-1]=='#{@fleet_id}' else str(previous/'manifest.json')):
                    with self.assertRaisesRegex(ValueError, 'own controller'):
                        src.quota_loop_replacement(source, '')
                for mark in ('kind=cron id=abc@9999999999', 'kind=wakeup unknown=1', 'legacy-loop'):
                    with self.subTest(mark=mark), self.assertRaises(ValueError):
                        src.quota_loop_replacement(source, mark)
                cancel = dict(type='assistant',message={'content':[dict(type='tool_use',id='stop',
                    name='ScheduleWakeup',input={'stop':True})]})
                path.write_text(json.dumps(row)+'\n'+json.dumps(cancel)+'\n')
                with self.assertRaisesRegex(ValueError, 'cancellation'):
                    src.quota_loop_replacement(source, '')
                path.write_text(json.dumps(dict(row, type='assistant'))+'\n')
                with self.assertRaises(ValueError): src.quota_loop_replacement(source, '')

    def test_historical_spec_retains_user_command_without_claiming_live_membership(self):
        import fleet_transfer_cron as cron
        import fleet_transfer_durable as durable
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'source.jsonl'; plan=Path(tmp)/'replacement.json'
            text='<command-message>example:run</command-message>\n<command-name>/example:run</command-name>'
            inp=dict(delaySeconds=1200, noop=True, prompt='/example:run', reason='waiting for checks')
            rows=[dict(type='user',uuid='original',message={'content':text}),
                  dict(type='assistant',uuid='rearm',timestamp='2000-01-01T00:00:00Z',message={'content':[
                      dict(type='tool_use',id='wake',name='ScheduleWakeup',input=inp)]}),
                  dict(type='user',timestamp='2000-01-01T00:00:01Z',toolUseResult=dict(
                      scheduledFor=946685000000,clampedDelaySeconds=1200,wasClamped=False),message={'content':[
                      dict(type='tool_result',tool_use_id='wake')]})]
            path.write_text(''.join(json.dumps(r)+'\n' for r in rows))
            raw=dict(prompt='/example:run',interval_seconds=1200,quota_replacement=dict(
                version=1,fid='fid',session_id='sid',pid=42,proc_start='start',
                basis='historical-wakeup-spec',invocation='/example:run',user_message_uuid='original',
                user_message_sha256=hashlib.sha256(text.encode()).hexdigest(),
                schedule_message_uuid='rearm',schedule_tool_use_id='wake'))
            plan.write_text(json.dumps(raw))
            source=dict(session='test',pane='%2',pid=42,session_id='sid',transcript=str(path))
            with patch.dict(os.environ,FLEET_QUOTA_LOOP_REPLACEMENT=str(plan)), \
                 patch.object(src,'run',side_effect=lambda argv,**kw:'fid' if argv[-1]=='#{@fleet_id}' else ''), \
                 patch.object(durable,'proc_start',return_value='start'), \
                 patch.object(cron,'check_durable_store',return_value=None):
                proof=src.quota_loop_replacement(source,'')
                self.assertEqual(proof['mode'],'authorized-replacement')
                self.assertEqual(proof['native_exit_invocations'],['/example:run'])
                self.assertNotIn('scheduledFor',json.dumps(proof))
                # The same historical receipt remains usable as a specification;
                # it is never presented as a current process's live CronList.
                with patch.object(cron,'process_start',return_value=time.time()):
                    self.assertFalse(cron.has_native_activity(path,42))
                    self.assertEqual(src.quota_loop_replacement(source,''),proof)
                for change in ('bad-user-hash','unconfirmed','later-mutation','stopped'):
                    bad=json.loads(json.dumps(raw)); changed=json.loads(json.dumps(rows))
                    if change=='bad-user-hash': bad['quota_replacement']['user_message_sha256']='wrong'
                    if change=='unconfirmed': changed.pop()
                    if change=='stopped': changed[1]['message']['content'][0]['input']['stop']=True
                    if change=='later-mutation':
                        changed.append(dict(type='assistant',uuid='later',message={'content':[
                            dict(type='tool_use',id='new',name='ScheduleWakeup',input=inp)]}))
                    plan.write_text(json.dumps(bad));path.write_text(''.join(json.dumps(r)+'\n' for r in changed))
                    with self.subTest(change=change),self.assertRaises(ValueError):
                        src.quota_loop_replacement(source,'')

    def test_competing_or_durable_owner_is_not_replaced(self):
        # The authorization file is not permission to overwrite another timer.
        import fleet_transfer_cron as cron
        with patch.dict(os.environ, FLEET_QUOTA_LOOP_REPLACEMENT='/missing'), \
             patch.object(cron, 'check_durable_store', side_effect=ValueError('durable owner')), \
             patch.object(src, 'run', return_value='fid'):
            with self.assertRaises(ValueError):
                src.quota_loop_replacement(dict(pid=42, session_id='sid', session='test', pane='%2'), '')

    def test_exit_dialog_must_match_authorized_invocation(self):
        helper = module('transfer_package', '.fleet-transfer.py')
        screen = ('Background work is running\nThe following will stop when you exit:\n'
                  'scheduled task · Runs once in 5m · /loop 30m check task\n'
                  '❯ 1. Exit and stop tasks\n2. Move to background and exit\n3. Stay\n'
                  'Enter to confirm · Esc to cancel')
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp)
            (bundle/'manifest.json').write_text(json.dumps(dict(quota_loop_replacement=dict(
                authorization=dict(invocation='/loop 30m check task')))))
            self.assertTrue(helper.loop_exit_confirmation(screen, bundle))
            self.assertTrue(helper.loop_exit_confirmation(screen.replace('/loop 30m ', '/loop '), bundle))
            self.assertFalse(helper.loop_exit_confirmation(screen.replace('check task','other task'), bundle))
            self.assertFalse(helper.loop_exit_confirmation(screen.replace('scheduled task ·',
                'scheduled task · Runs once in 1m · /loop extra\nscheduled task ·'), bundle))


class QuotaSettled(unittest.TestCase):
    def test_native_failed_turn_requires_all_controller_proofs(self):
        with tempfile.TemporaryDirectory() as tmp:
            transcript = Path(tmp) / 'native.jsonl'
            record = dict(type='assistant', sessionId='exact', uuid='error-id', error='rate_limit',
                          isApiErrorMessage=True, apiErrorStatus=429, apiErrorIsTransient=False,
                          message={'content': [{'type': 'text', 'text': "API Error: Request rejected (429) · You've hit your weekly limit"}]})
            transcript.write_text(json.dumps(record) + '\n')
            source = dict(session='test', pane='%2', pid=42, session_id='exact', agent='claude',
                          state='exited', transcript=str(transcript))
            marks = ['exited', '7501', '{"state":"error"}', '', '', '', '']
            snapshot = unittest.mock.Mock(return_value=dict(state='empty', text=''))
            with patch.object(src, 'inspect', return_value=source) as inspect, \
                 patch.object(src, 'quota_marks', return_value=marks) as meta, \
                 patch.object(src, 'quota_schedules') as schedules, \
                 patch.object(src, 'quota_prompt_proof', return_value={'ok': True}) as prompt, \
                 patch.object(src.runpy, 'run_path', return_value={'snapshot': snapshot}), \
                 patch.object(src, 'quiet_processes') as quiet:
                src.quota_settled('test', '%2', 'exact')
                quiet.assert_called_once_with(source)
                self.assertEqual(prompt.call_count, 2)
                for why in ('active_turn', 'probe_timeout', 'draft'):
                    prompt.side_effect = ValueError(why)
                    with self.assertRaisesRegex(ValueError, why):
                        src.quota_settled('test', '%2', 'exact')
                prompt.side_effect = [{'ok': True}, ValueError('main turn restarted')]
                with self.assertRaisesRegex(ValueError, 'main turn restarted'):
                    src.quota_settled('test', '%2', 'exact')
                prompt.side_effect = None
                schedules.side_effect = ValueError('current scheduler unknown')
                with self.assertRaisesRegex(ValueError, 'current scheduler unknown'):
                    src.quota_settled('test', '%2', 'exact')
                schedules.side_effect = None
                tool = dict(type='assistant', sessionId='exact', message={'content':[
                    dict(type='tool_use', id='network-tool', name='WebFetch', input={})]})
                transcript.write_text(json.dumps(tool)+'\n'+json.dumps(record)+'\n')
                with self.assertRaisesRegex(ValueError, 'unfinished tool'):
                    src.quota_settled('test', '%2', 'exact')
                transcript.write_text('not valid JSON\n'+json.dumps(record)+'\n')
                with self.assertRaisesRegex(ValueError, 'unknown tool transcript'):
                    src.quota_settled('test', '%2', 'exact')
                transcript.write_text(json.dumps(record)+'\n')
                observations = iter((False, True))
                def tool_appears(*_):
                    if next(observations):
                        transcript.write_text(json.dumps(tool)+'\n'+json.dumps(record)+'\n')
                    return {'ok': True}
                with patch.object(src, 'quota_prompt_proof', side_effect=tool_appears):
                    with self.assertRaisesRegex(ValueError, 'changed during'):
                        src.quota_settled('test', '%2', 'exact')
                transcript.write_text(json.dumps(record)+'\n')
                with self.assertRaisesRegex(ValueError, 'conversation changed'):
                    src.quota_settled('test', '%2', 'other')
                for state in ('unknown', 'draft'):
                    snapshot.return_value = dict(state=state)
                    with self.assertRaisesRegex(ValueError, 'prompt'):
                        src.quota_settled('test', '%2', 'exact')
                snapshot.return_value = dict(state='empty', text='')
                quiet.side_effect = ValueError('live tool')
                with self.assertRaisesRegex(ValueError, 'live tool'):
                    src.quota_settled('test', '%2', 'exact')
                quiet.side_effect = None
                meta.side_effect = [marks, marks + ['changed']]
                with self.assertRaisesRegex(ValueError, 'changed during'):
                    src.quota_settled('test', '%2', 'exact')
                meta.side_effect = None
                transcript.write_text(json.dumps(dict(record, error='authentication_failed')) + '\n')
                with self.assertRaisesRegex(ValueError, 'no exact native'):
                    src.quota_settled('test', '%2', 'exact')

    def test_metadata_holds_approvals_loops_and_native_work(self):
        fields = ['exited', '7501', '{"state":"error"}', '', '', '', '']
        for key, bad in ((0, 'working'), (1, 'classifier'), (2, '{"state":"working"}'),
                         (3, 'perm'), (4, 'tool'), (5, 'loop'), (6, '1')):
            value = list(fields); value[key] = bad
            with patch.object(src, 'run', return_value='\t'.join(value + ['END'])):
                with self.assertRaises(ValueError): src.quota_marks('test', '%2')
        with patch.object(src, 'run', return_value='\t'.join(fields + ['END'])):
            self.assertEqual(src.quota_marks('test', '%2'), fields)
        # A missing delimiter / truncated read cannot admit a quota boundary.
        for raw in ('exited7501END', '\t'.join(fields), '\t'.join(fields + ['extra', 'END'])):
            with patch.object(src, 'run', return_value=raw):
                with self.assertRaisesRegex(ValueError, 'metadata is incomplete'):
                    src.quota_marks('test', '%2')


class QuotaDialog(unittest.TestCase):
    SCREEN = """You've hit your weekly limit · resets tomorrow
▔▔▔▔▔▔▔▔▔▔
   What do you want to do?

   ❯ 1. Stop and wait for limit to reset
     2. Wait here, then continue automatically at Oct 23 at 5pm
     3. Upgrade your plan

   Enter to confirm · Esc to cancel
"""

    def test_exact_native_quota_dialog_and_fingerprint(self):
        fp = src.quota_dialog(self.SCREEN)
        self.assertTrue(fp)
        for bad in (self.SCREEN.replace('Stop and wait for limit to reset', 'Allow Bash'),
                    self.SCREEN.replace('What do you want to do?', 'Approve tool?'),
                    self.SCREEN + '❯ unsent draft', self.SCREEN.replace('Esc to cancel', 'Enter to continue'),
                    self.SCREEN.replace('3. Upgrade your plan', '3. Other / Type something')):
            with self.subTest(screen=bad), self.assertRaises(ValueError):
                src.quota_dialog(bad)
        self.assertNotEqual(fp, src.quota_dialog(self.SCREEN.replace('Oct 23', 'Oct 24')))


    def test_native_menu_requires_exact_state_source_tools_and_scheduler(self):
        source = dict(agent='claude', state='needs', session_id='exact', transcript='/native',
                      pid=42, window='@2', pane='%2', session='test')
        marks = ['needs', '7501', '{"state":"blocked","app":"claude-code","msg":"dialog open"}', '', '', '', '']
        signal = dict(source_session='exact', error_id='error-id', transcript='/native')
        def run(argv, **kw):
            return '' if 'list-clients' in argv else self.SCREEN
        with patch.object(src, 'inspect', return_value=source) as inspect, \
             patch.object(src, 'source_marks', return_value=marks) as metadata, \
             patch.object(src.fallback, 'quota_error', return_value=signal) as quota, \
             patch.object(src, 'run', side_effect=run) as tm, \
             patch.object(src, 'quiet_processes') as tools, \
             patch.object(src, 'quota_prompt_proof', return_value={'ok': True}) as prompt, \
             patch.object(src.runpy, 'run_path', return_value={'schedule_readiness': unittest.mock.Mock()}) as modules:
            evidence = src.quota_dialog_check('test', '%2', 'exact')
            self.assertEqual(evidence['fingerprint'], src.quota_dialog(self.SCREEN))
            schedule = modules.return_value['schedule_readiness']
            schedule.assert_called_with('test', '%2', '/native', 42, 'exact', '', 'claude')
            for key, bad in ((0, 'working'), (1, 'classifier'), (2, '{"state":"blocked","kind":"permission"}'),
                             (3, 'ask'), (4, 'tool'), (5, 'loop'), (6, '1')):
                altered = list(marks); altered[key] = bad; metadata.return_value = altered
                with self.assertRaises(ValueError): src.quota_dialog_check('test', '%2', 'exact')
            metadata.return_value = marks
            for key in ('agent', 'state', 'session_id'):
                inspect.return_value = dict(source, **{key:'changed'})
                with self.assertRaises(ValueError): src.quota_dialog_check('test', '%2', 'exact')
            inspect.return_value = source
            quota.return_value = None
            with self.assertRaisesRegex(ValueError, 'hard-quota'): src.quota_dialog_check('test', '%2', 'exact')
            quota.return_value = signal
            tools.side_effect = ValueError('live tool')
            with self.assertRaisesRegex(ValueError, 'live tool'): src.quota_dialog_check('test', '%2', 'exact')
            tools.side_effect = None
            schedule.side_effect = ValueError('native scheduling unknown')
            with self.assertRaisesRegex(ValueError, 'scheduling'): src.quota_dialog_check('test', '%2', 'exact')
            schedule.side_effect = None
            prompt.side_effect = ValueError('native hidden draft')
            with self.assertRaisesRegex(ValueError, 'hidden draft'): src.quota_dialog_check('test', '%2', 'exact')
            prompt.side_effect = None
            tm.side_effect = lambda argv, **kw: str(int(src.time.time())) + ' @2' if 'list-clients' in argv else self.SCREEN
            with self.assertRaisesRegex(ValueError, 'person'): src.quota_dialog_check('test', '%2', 'exact')

    def test_native_prompt_proof_refuses_hidden_draft_busy_unknown_or_timeout(self):
        import fleet_session_gate as gate
        with patch.object(src, 'run', return_value='/sock/test'), patch.object(gate, 'park_proof') as query:
            for reply in ({'ok':False,'why':'draft'}, {'ok':False,'why':'busy'}, {'ok':False,'why':'probe_timeout'}, {}, None):
                query.return_value = reply
                with self.assertRaisesRegex(ValueError, 'not proven empty and stopped'):
                    src.quota_prompt_proof('test', '%2')
            query.return_value = {'ok': True, 'why': ''}
            self.assertTrue(src.quota_prompt_proof('test', '%2')['ok'])

    def test_native_prompt_proof_uses_real_inbox_dispatch_without_probe_seam(self):
        # Exercise park_proof itself: a mocked proof or command seam masks a
        # missing agent selector before the native inbox request is even sent.
        for reply in ({'ok': True, 'why': ''}, {'ok': False, 'why': 'busy'},
                      {'ok': False, 'why': 'draft'}):
            with self.subTest(reply=reply), tempfile.TemporaryDirectory() as tmp, \
                 patch.dict(os.environ, FLEET_CONF_DIR=tmp, FLEET_GATE_PARK_PROBE_CMD=''), \
                 patch.object(src, 'run', return_value='/sock/test'), \
                 concurrent.futures.ThreadPoolExecutor(max_workers=1) as worker:
                future = worker.submit(src.quota_prompt_proof, 'test', '%2')
                directory = Path(tmp) / 'global/mod-inbox/test/2'
                end = time.monotonic() + 3
                pending = []
                while not pending and not future.done() and time.monotonic() < end:
                    pending = list(directory.glob('*.json'))
                    time.sleep(.01)
                if future.done():
                    future.result()  # surface dispatch failures, not a timeout
                self.assertEqual(len(pending), 1, 'native proof request not delivered')
                request = json.loads(pending[0].read_text())
                self.assertEqual(request['query'], 'park.v1')
                self.assertTrue(request['nonce'])
                self.assertGreater(request['deadline'], time.time())
                pending[0].unlink()
                pending[0].with_suffix('.done').write_text(json.dumps(reply))
                if reply['ok']:
                    self.assertEqual(future.result(timeout=2), reply)
                else:
                    with self.assertRaisesRegex(ValueError, reply['why']):
                        future.result(timeout=2)

    def test_cancellation_is_write_ahead_once_and_never_restamps_or_replays(self):
        source = dict(agent='claude', state='needs', session_id='exact', pid=42)
        evidence = dict(source=source, fingerprint='fp', screen=self.SCREEN)
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, FLEET_CONF_DIR=tmp), \
             patch.object(src, 'quota_dialog_check', side_effect=lambda *a: dict(evidence)) as check, \
             patch.object(src, 'inspect', return_value=dict(source, state='exited')), \
             patch.object(src, 'quota_settled') as settled, patch.object(src, 'run', return_value='screen') as tm:
            src.quota_dialog_stop('test', '%2', 'exact')
            sends = [c.args[0] for c in tm.call_args_list if 'send-keys' in c.args[0]]
            self.assertEqual(sends, [['tmux', '-L', 'test', 'send-keys', '-t', '%2', 'Escape']])
            settled.assert_called_once_with('test', '%2', 'exact')
            record = json.loads(next(Path(tmp).glob('quota-dialog-stop/*.json')).read_text())
            self.assertEqual(record['state'], 'settled')
            self.assertEqual(record['source']['state'], 'needs')
            with self.assertRaisesRegex(ValueError, 'already attempted'):
                src.quota_dialog_stop('test', '%2', 'exact')
            self.assertEqual(len([c for c in tm.call_args_list if 'send-keys' in c.args[0]]), 1)

    def test_uncertain_stop_changed_identity_draft_or_tool_remains_recoverable(self):
        source = dict(agent='claude', state='needs', session_id='exact', pid=42)
        evidence = dict(source=source, fingerprint='fp', screen=self.SCREEN)
        for failure in ('draft', 'live tool', 'identity', 'timeout', 'dialog changed', 'send failed'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp, \
                 patch.dict(os.environ, FLEET_CONF_DIR=tmp), \
                 patch.object(src, 'quota_dialog_check', side_effect=[dict(evidence), dict(evidence, fingerprint='new') if failure == 'dialog changed' else dict(evidence)]), \
                 patch.object(src, 'inspect', return_value=dict(source, state='needs' if failure == 'timeout' else 'exited', pid=43 if failure == 'identity' else 42)), \
                 patch.object(src.time, 'monotonic', side_effect=[0, 6]), \
                 patch.object(src, 'quota_settled', side_effect=ValueError(failure) if failure in ('draft', 'live tool') else None), \
                 patch.object(src, 'run', side_effect=OSError('send failed') if failure == 'send failed' else None) as tm:
                with self.assertRaises((ValueError, OSError)):
                    src.quota_dialog_stop('test', '%2', 'exact')
                record = json.loads(next(Path(tmp).glob('quota-dialog-stop/*.json')).read_text())
                self.assertEqual(record['state'], 'recovery')
                self.assertLessEqual(tm.call_count, 1)
                self.assertFalse(any('set-option' in str(c) or '/exit' in str(c) for c in tm.call_args_list))


class Settled(unittest.TestCase):
    def test_a_pooled_codex_thread_is_a_fleet_thread(self):
        # T630: a Codex on the pool's credential proxy reads modelProvider "fleet";
        # refusing it left every pooled looping Codex unswitchable.
        source = dict(session_id='t1', worktree='/tmp', codex_identity={'remote': ''})
        for provider, ok in (('openai', True), ('fleet', True), ('azure', False), (None, False)):
            thread = dict(id='t1', modelProvider=provider, cwd='/tmp')
            with patch.object(src, 'RPC'), patch.dict(src.ATTENTION, thread_read=lambda *a, **k: thread):
                if ok:
                    self.assertEqual(src.native_thread(source), thread)
                else:
                    with self.assertRaisesRegex(ValueError, 'provider changed'):
                        src.native_thread(source)

    def test_manual_transfer_accepts_only_a_settled_looping_codex_round(self):
        source = dict(session='test', window='@2', pane='%2', pid=42, session_id='source', agent='codex', state='looping')
        idle = lambda last, items=(dict(status='completed'),), kind='idle': dict(
            status={'type': kind}, turns=[dict(status=last, items=list(items))])
        with patch.object(src, 'inspect', return_value=source), patch.object(src, 'native_thread') as thread:
            thread.return_value = idle('completed'); src.settled('test', '%2')
            for bad, why in ((idle('interrupted'), 'between rounds'), (idle('completed', kind='active'), 'still active'),
                             (idle('completed', [dict(status='inProgress')]), 'tool is still active')):
                thread.return_value = bad
                with self.assertRaisesRegex(ValueError, why): src.settled('test', '%2')
            thread.return_value = idle('completed')
            for other in (dict(source, state='working'), dict(source, agent='claude')):
                src.inspect.return_value = other
                with self.assertRaisesRegex(ValueError, 'between rounds'): src.settled('test', '%2')


class Background(unittest.TestCase):
    def setUp(self):
        self.source = dict(session='test', window='@2', pane='%2', pid=42, session_id='s', agent='claude',
                           worktree='/w', transcript='/t', state='working')
        self.sleep = module('sleep_bg', 'fleet_worker_life.py')
        # A `next dev` shell: zsh (43) → node (44), neither an MCP server.
        rows = {43: (42, 'zsh'), 44: (43, 'node')}
        self.argv = {42: ['claude'], 43: ['/bin/zsh', '-c', 'next dev -p 3117'], 44: ['node', 'next', 'dev']}
        mods = {'fleet_worker_life.py': vars(self.sleep), 'fleet_agent_argv.py': {'process_argv': lambda pid: self.argv[pid]}}
        for p in (patch.dict(self.sleep.TRANSFER, process_rows=lambda: rows),
                  patch.dict(self.sleep.MCP, claude_inventory=lambda *a: {}, classify=lambda *a: set()),
                  patch.dict(self.sleep.ARGV, process_argv=lambda pid: self.argv[pid],
                             process_executable=lambda pid: Path(self.argv[pid][0])),
                  patch.object(src.runpy, 'run_path', side_effect=lambda f: mods[Path(f).name]),
                  patch.object(src, 'process_start', return_value=('S', 'Mon Sep 20 10:00:00 2026')),
                  patch.object(src, 'process_cwd', return_value='/w/web')):
            p.start(); self.addCleanup(p.stop)

    def test_the_inventory_collects_what_hibernation_would_veto(self):
        with self.assertRaisesRegex(ValueError, 'pid=43'): self.sleep.quiet_processes(self.source)
        bg = src.background_inventory(self.source)
        self.assertEqual([(e['pid'], e['argv'], e['cwd']) for e in bg],
                         [(43, self.argv[43], '/w/web'), (44, self.argv[44], '/w/web')])
        note = src.background_note(bg)
        self.assertIn('Background commands terminated by migration', note)
        self.assertIn("/bin/zsh -c 'next dev -p 3117'", note)

    def test_claude_background_collects_a_named_pids_children(self):
        with patch.object(src, 'background_inventory', side_effect=lambda s: [s]):
            s = src.claude_background('42', '/w', 'fleet-x')[0]
        self.assertEqual((s['pid'], s['agent'], s['worktree'], s['session']), (42, 'claude', '/w', 'fleet-x'))


class TerminateBackground(unittest.TestCase):
    def test_only_the_recorded_live_process_is_stopped_and_named(self):
        with tempfile.TemporaryDirectory() as tmp:
            req = Path(tmp) / 'req'; bundle = Path(tmp) / 'bundle'; req.mkdir(); bundle.mkdir()
            (bundle / 'pickup.md').write_text('pickup\n'); (bundle / 'handoff.md').write_text('handoff\n')
            job = subprocess.Popen(['sleep', '60']); self.addCleanup(lambda p=job: (p.kill(), p.wait()))
            reused = subprocess.Popen(['sleep', '60']); self.addCleanup(lambda p=reused: (p.kill(), p.wait()))
            start = src.process_start(job.pid)[1]
            src.save(req / 'background.json', [
                dict(pid=job.pid, argv=['sleep', '60'], cwd=tmp, start=start),
                # a recorded pid now held by a DIFFERENT process must survive
                dict(pid=reused.pid, argv=['old'], cwd=tmp, start='Thu Jan  1 00:00:00 1970')])
            src.terminate_background(req, bundle)
            self.assertEqual(job.wait(timeout=5), -15)
            self.assertIsNone(reused.poll())
            self.assertEqual([e['stopped'] for e in src.read(req / 'background.json')], ['SIGTERM', 'exited'])
            for name in ('pickup.md', 'handoff.md'):
                text = (bundle / name).read_text()
                self.assertIn('Background commands terminated by migration', text)
                self.assertIn('`sleep 60` (cwd `%s`)' % tmp, text)

    def test_forced_migrate_prints_its_own_note_and_touches_no_bundle(self):
        # fleet-migrate.sh --force-bg (#873): the note comes back on stdout.
        with tempfile.TemporaryDirectory() as tmp:
            req = Path(tmp) / 'req'; req.mkdir()
            job = subprocess.Popen(['sleep', '61']); self.addCleanup(lambda p=job: (p.kill(), p.wait()))
            src.save(req / 'background.json', [dict(pid=job.pid, argv=['sleep', '61'], cwd=tmp,
                                                    start=src.process_start(job.pid)[1])])
            out = io.StringIO()
            with contextlib.redirect_stdout(out): src.terminate_background(req, None, 'The operator forced this move')
            self.assertEqual(job.wait(timeout=5), -15)
            self.assertIn('The operator forced this move, so these background commands', out.getvalue())
            self.assertEqual(list(Path(tmp).iterdir()), [req])


class Cli(unittest.TestCase):
    def test_the_retired_planner_and_its_entry_points_are_gone(self):
        bin_ = Path(__file__).parent
        self.assertFalse((bin_ / '.fleet-failover.py').exists())
        for args, word in ((['bash', str(bin_ / 'fleet-account.sh'), 'reconcile', '--session', 'x'], '已不用'),
                           (['bash', str(bin_ / 'fleet-account.sh'), 'failover-status'], '已不用')):
            r = subprocess.run(args, capture_output=True, text=True, timeout=30,
                               env=dict(os.environ, FLEET_SKIP_GLOBAL_CONF='1'))
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn(word, r.stderr)
        r = subprocess.run(['bash', str(bin_ / 'fleet-migrate.sh'), '--limited', '--session', 'x'],
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 2); self.assertIn('已不用', r.stderr)


if __name__ == '__main__':
    unittest.main()
