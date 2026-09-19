#!/usr/bin/env python3
"""Quota episodes, recovery, exact owners, drafts and transfer launch contracts."""
import importlib.util
import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

def module(name, file):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(file))
    m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m

flow=module('flow','.fleet-failover.py')
inputs=module('inputs','fleet-input.py')
transfer=module('transfer','.fleet-transfer.py')

def account(agent,name,used):
    return dict(agent=agent,key=agent+'/'+name,account=name,label=name,profile=name,
                available=True,utilization=used,score=200-2*used,login='valid')


class Failover(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.source=dict(session='test',window='@2',pane='%2',pid=42,session_id='source',agent='codex')
        self.account=account('codex','original',100)
        self.other=account('claude','other',10)
        self.data={'accounts':[self.account]}
        self.path=self.root/'attempt'
        self.patches=[patch.object(flow,'request_path',return_value=self.path),
                      patch.object(flow,'evidence',return_value=(True,'turn:1')),
                      patch.object(flow,'stamp'),
                      patch.dict(flow.ACCOUNT,bench=lambda *_:None),
                      patch.dict(os.environ,FLEET_ACCOUNT_CEILING='85',FLEET_CONF_DIR=str(self.root))]
        for p in self.patches:p.start()
        self.addCleanup(lambda:[p.stop() for p in reversed(self.patches)])

    def request(self):return flow.read(self.path/'request.json',{})

    def test_hibernation_and_failover_share_verified_infrastructure_checks(self):
        sleep=module('sleep_guard','fleet-sleep.py')
        source=dict(self.source,codex_identity={'remote':'unix:///owned'})
        rows={43:(42,'codex'),44:(43,'codex-code-mode-host')}
        argv={43:['codex','app-server','--listen','unix:///owned'],44:['code-host']}
        exes={43:Path('/release/codex'),44:Path('/release/codex-code-mode-host')}
        loaded=['source']
        class Client:
            def __init__(self,*a,**kw):pass
            def close(self):pass
            def call(self,method,params):
                if method=='thread/loaded/list':return {'data':loaded}
                if method=='thread/read':return {'thread':{'status':{'type':'active'}}}
                raise AssertionError(method)
        with patch.object(flow.runpy,'run_path',return_value=vars(sleep)),patch.object(flow,'RPC',Client), \
             patch.dict(sleep.TRANSFER,process_rows=lambda:rows), \
             patch.dict(sleep.ARGV,process_argv=lambda pid:argv[pid],process_executable=lambda pid:exes[pid]):
            flow.quiet_processes(source)
            rows[45]=(44,'bash');argv[45]=['bash','job'];exes[45]=Path('/bin/bash')
            with self.assertRaisesRegex(ValueError,'background/tool'):flow.quiet_processes(source)
            del rows[45]
            loaded.append('child')
            with self.assertRaisesRegex(ValueError,'subagent'):flow.quiet_processes(source)

    def test_wait_retries_after_alert_dedup_and_prefers_same_agent(self):
        flow.reconcile_one(self.source,self.account,self.data)
        self.assertEqual(self.request()['state'],'waiting-quota')
        until=self.request()['benched_until']
        flow.reconcile_one(self.source,self.account,self.data)
        self.assertEqual(self.request()['benched_until'],until)
        self.data['accounts'] += [self.other,account('codex','second',60)]
        with patch.object(flow,'move') as move:
            flow.reconcile_one(self.source,self.account,self.data)
            self.assertEqual(move.call_args.args[2]['account'],'second')

    def test_failed_target_cooldown_uses_another_available_subscription(self):
        flow.reconcile_one(self.source,self.account,self.data)
        r=self.request();r['failed_targets']={'codex/second':time.time()+120};flow.save(self.path/'request.json',r)
        self.data['accounts'] += [self.other,account('codex','second',60)]
        with patch.object(flow,'move') as move:
            flow.reconcile_one(self.source,self.account,self.data)
            self.assertEqual(move.call_args.args[2]['agent'],'claude')

    def test_stale_quota_error_recovers_once_after_fresh_reading(self):
        flow.reconcile_one(self.source,self.account,self.data)
        r=self.request();r['benched_until']=1;flow.save(self.path/'request.json',r)
        self.account.update(utilization=10,score=180)
        with patch.object(flow,'validate'), patch.object(flow,'read',side_effect=lambda p,d=None: {'state':'empty'} if Path(p).name=='input.json' else json.loads(Path(p).read_text()) if Path(p).exists() else d), patch.object(flow.subprocess,'run') as send:
            flow.reconcile_one(self.source,self.account,self.data)
            flow.reconcile_one(self.source,self.account,self.data)
        self.assertEqual(send.call_count,1)
        self.assertEqual(self.request()['state'],'recovered')

    def test_interrupted_prepare_never_starts_a_second_writer(self):
        flow.reconcile_one(self.source,self.account,self.data)
        r=self.request();r['state']='preparing';flow.save(self.path/'request.json',r)
        self.data['accounts'].append(self.other)
        with patch.object(flow,'move') as move:flow.reconcile_one(self.source,self.account,self.data)
        self.assertFalse(move.called);self.assertEqual(self.request()['state'],'ambiguous')

    def test_a_new_quota_episode_in_same_native_session_can_retry(self):
        flow.reconcile_one(self.source,self.account,self.data)
        r=self.request();r['state']='recovered';flow.save(self.path/'request.json',r)
        flow.evidence.return_value=(True,'turn:2')
        self.data['accounts'].append(self.other)
        with patch.object(flow,'move') as move:flow.reconcile_one(self.source,self.account,self.data)
        self.assertTrue(move.called)

    def test_dry_run_creates_no_request_or_pane_mutation(self):
        flow.reconcile_one(self.source,self.account,self.data,dry=True)
        self.assertFalse(self.path.exists());self.assertFalse(flow.stamp.called)

    def test_ambiguous_reset_write_is_not_repeated(self):
        flow.reconcile_one(self.source,self.account,self.data)
        r=self.request();r['benched_until']=1;flow.save(self.path/'request.json',r)
        self.account.update(utilization=10,score=180)
        with patch.object(flow,'validate'), patch.object(flow,'read',side_effect=lambda p,d=None: {'state':'empty'} if Path(p).name=='input.json' else json.loads(Path(p).read_text()) if Path(p).exists() else d), patch.object(flow.subprocess,'run',side_effect=subprocess.TimeoutExpired('send',15)) as send:
            flow.reconcile_one(self.source,self.account,self.data)
            flow.reconcile_one(self.source,self.account,self.data)
        self.assertEqual(send.call_count,1);self.assertEqual(self.request()['state'],'ambiguous')

    def test_model_only_limit_does_not_bench_or_move_subscription(self):
        self.account.update(utilization=58,score=84)
        self.data['accounts'].append(self.other)
        with patch.object(flow,'move') as move:
            flow.reconcile_one(self.source,self.account,self.data)
        self.assertFalse(move.called)
        self.assertEqual(self.request()['state'],'waiting-evidence')
        self.assertNotIn('benched_until',self.request())

    def loop_record(self):
        record=self.root/'packet/loop/state.json';record.parent.mkdir(parents=True)
        self.source.update(previous=str(record.parent.parent/'manifest.json'),worktree=str(self.root))
        # Pre-upgrade records have no agent/generation field. Their controller
        # only knows the durable status gate, not the new tmux quota flag.
        data=dict(id='legacy-loop',status='active',thread_id='source',manifest=self.source['previous'],
                  worktree=str(self.root),deliveries=7,schedule=dict(prompt='继续',interval_seconds=300,next_run_at=1))
        flow.LOOP['save'](record,data)
        return record

    def test_legacy_loop_waits_and_releases_once_after_quota_reset(self):
        record=self.loop_record()
        with patch.dict(flow.LOOP,current=lambda *_:None), patch.object(flow,'inspect',return_value=self.source), patch.object(flow,'opt',return_value=''):
            flow.reconcile_one(self.source,self.account,self.data)
            saved=flow.read(record);self.assertEqual(saved['status'],'waiting-quota')
            self.assertEqual(saved['quota_request'],str(self.path));self.assertEqual(saved['deliveries'],7)
            flow.quota_loop(self.path,self.source,'recovered')
            saved=flow.read(record);due=saved['schedule']['next_run_at']
            self.assertEqual(saved['status'],'active');self.assertGreater(due,time.time())
            flow.quota_loop(self.path,self.source,'recovered')
            self.assertEqual(flow.read(record)['schedule']['next_run_at'],due)
            self.assertEqual(flow.read(record)['deliveries'],7)

    def test_quota_never_revives_stopped_or_replacement_owner(self):
        record=self.loop_record()
        with patch.dict(flow.LOOP,current=lambda *_:None), patch.object(flow,'inspect',return_value=dict(self.source,pid=99)), patch.object(flow,'opt',return_value=''):
            flow.quota_loop(self.path,self.source,'waiting-quota')
            self.assertEqual(flow.read(record)['status'],'active')
        saved=flow.read(record);saved['status']='stopped';flow.LOOP['save'](record,saved)
        flow.quota_loop(self.path,self.source,'waiting-quota')
        flow.quota_loop(self.path,self.source,'recovered')
        self.assertEqual(flow.read(record)['status'],'stopped')

    def test_restored_wait_requires_cancelled_old_request_and_fresh_health(self):
        record=self.loop_record()
        with patch.dict(flow.LOOP,current=lambda *_:None), patch.object(flow,'inspect',return_value=self.source), patch.object(flow,'opt',return_value=''):
            flow.reconcile_one(self.source,self.account,self.data)
            request=self.request();request['state']='cancelled';flow.save(self.path/'request.json',request)
            self.source=dict(self.source,pid=99)
            self.path=self.root/'restored-attempt';flow.request_path.return_value=self.path
            flow.evidence.return_value=(False,'restored')
            self.account.update(utilization=10,score=180,available=False)
            with patch.object(flow,'inspect',return_value=self.source):
                flow.reconcile_one(self.source,self.account,self.data)
                self.assertEqual(flow.read(record)['status'],'waiting-quota')
                self.account['available']=True
                flow.reconcile_one(self.source,self.account,self.data)
                self.assertEqual(flow.read(record)['status'],'active')
                self.assertFalse(self.path.exists())

    def test_only_subscription_quota_error_is_migration_evidence(self):
        for name in ('rateLimitExceeded','sessionBudgetExceeded','internalServerError'):
            self.assertFalse(flow.quota_error(dict(status={'type':'idle'},turns=[dict(status='failed',error={'codexErrorInfo':name})])))
        self.assertTrue(flow.quota_error(dict(status={'type':'idle'},turns=[dict(status='failed',error={'codexErrorInfo':'usageLimitExceeded'})])))
        self.assertFalse(flow.quota_error(dict(status={'type':'active','activeFlags':['waitingOnApproval']},turns=[dict(status='failed',error={'codexErrorInfo':'usageLimitExceeded'})])))

    def test_recovered_inspection_clears_stale_unsupported_status(self):
        path=flow.root()/'unsupported-test-2.json';flow.save(path,{'state':'unsupported'})
        with patch.object(flow,'tm',side_effect=lambda *a: '@2|worker' if a[1]=='list-windows' else ''), patch.object(flow,'inspect',return_value=self.source), patch.object(flow,'opt',return_value=''), patch.object(flow,'source_account',return_value=self.account), patch.dict(flow.ACCOUNT,inventory=lambda:self.data), patch.object(flow,'reconcile_one'):
            flow.reconcile_windows('test',True)
            self.assertTrue(path.exists())
            flow.reconcile_windows('test',False)
            self.assertFalse(path.exists())

    def test_retained_workers_are_not_inspected_or_migrated(self):
        with patch.object(flow,'tm',side_effect=lambda *a: '@2|worker' if a[1]=='list-windows' else 'sleeping'), \
             patch.object(flow,'inspect') as inspect, patch.dict(flow.ACCOUNT,inventory=lambda:self.data), \
             patch.object(flow,'reconcile_one') as reconcile:
            flow.reconcile_windows('test',True)
        inspect.assert_not_called();reconcile.assert_not_called()

    def test_sleep_preserves_pending_request_until_wake(self):
        path=flow.root()/'retained';path.mkdir(parents=True)
        request=dict(source=self.source,state='waiting',hard=False)
        flow.save(path/'request.json',request)
        with patch.object(flow,'opt',return_value='sleeping'),patch.object(flow,'inspect') as inspect:
            flow.cancel_obsolete('test',True)
        inspect.assert_not_called()
        self.assertEqual(flow.read(path/'request.json')['state'],'waiting')


class Drafts(unittest.TestCase):
    def test_waiting_loop_and_unsent_draft_survive_another_handoff(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp);repo=p/'repo';repo.mkdir();prior=p/'prior';(prior/'loop').mkdir(parents=True)
            manifest=prior/'manifest.json';draft=prior/'draft.txt';draft.write_text('1、做。2、')
            manifest.write_text(json.dumps({'draft':{'state':'unsent','path':str(draft)}}))
            (prior/'loop/state.json').write_text(json.dumps(dict(id='stable-id',status='waiting-quota',
                thread_id='source',deliveries=7,generation=2,schedule=dict(prompt='继续检查',interval_seconds=300,next_run_at=1))))
            transcript=p/'source.jsonl';transcript.write_text(json.dumps(dict(type='user',sessionId='source',message={'content':'original task'}))+'\n')
            a=argparse.Namespace(**{k:'' for k in ('handoff','loop','target_file','quota_request','draft_file','registry','codex_home','target_home','handle','issue','origin','repo')},
                worktree=str(repo),main=str(repo),output=str(p/'packets'),previous=str(manifest),sid='source',pid=42,
                transcript=str(transcript),session='isolated',window='@2',pane='%2',launcher='/fleet/launch',source_agent='claude',to='codex',native_resume=False)
            out=io.StringIO()
            with patch.object(transfer,'run',return_value=''),contextlib.redirect_stdout(out):transfer.package(a)
            packet=Path(out.getvalue().strip());m=json.loads((packet/'manifest.json').read_text())
            loop=json.loads(Path(m['loop_spec_path']).read_text())
            self.assertEqual((loop['id'],loop['generation'],loop['deliveries']),('stable-id',3,7))
            self.assertEqual(loop['next_run_at'],1)
            self.assertEqual(Path(m['draft']['path']).read_text(),'1、做。2、')
            self.assertEqual(m['previous_handoff'],str(manifest))
            self.assertNotIn('1、做。2、',(packet/'pickup.md').read_text())

    def test_ghost_text_in_rgb_color_is_empty(self):
        screen='\x1b[38;2;255;2;66m›\x1b[0m \x1b[2mAsk Codex anything\x1b[0m\n'
        self.assertEqual(inputs.analyze(screen,2,0,80)['state'],'empty')

    def test_cjk_draft_preserved_verbatim_and_unfinished_buffers_wait(self):
        text='1、做。2、'
        screen='› '+text+'\n\n'
        result=inputs.analyze(screen,2+inputs.width(text),0,80)
        self.assertEqual(result['state'],'draft');self.assertEqual(result['text'],text)
        self.assertEqual(inputs.analyze(screen,2,0,80)['state'],'unknown')
        self.assertEqual(inputs.analyze('› abc\ncontinued',5,0,80)['state'],'unknown')
        self.assertEqual(inputs.analyze('› [Pasted text #1]',18,0,80)['state'],'unknown')

    def test_pinned_launcher_keeps_target_home_and_draft_out_of_prompt(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)
            data=dict(target={'agent':'codex','codex_home':'/specific home'},source={'codex_home':'/old home'},workspace={'path':tmp})
            (p/'manifest.json').write_text(json.dumps(data))
            transfer.launcher(p,'/fleet/launcher')
            script=(p/'launch.sh').read_text()
            self.assertIn("--codex-home '/specific home'",script)
            self.assertNotIn('/old home',script)
            data['target']={'agent':'claude','label':'work'};data['native_resume']=True
            data['source'].update(agent='claude',session_id='exact-uuid')
            (p/'manifest.json').write_text(json.dumps(data));transfer.launcher(p,'/fleet/launcher')
            script=(p/'launch.sh').read_text()
            self.assertIn('--agent claude --resume exact-uuid',script)
            self.assertIn('FLEET_ACCOUNT_LABEL=work',script)


if __name__=='__main__':unittest.main()
