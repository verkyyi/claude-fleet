#!/usr/bin/env python3
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

BIN=Path(__file__).absolute().parent
spec=importlib.util.spec_from_file_location('attention',BIN/'fleet-codex-attention.py')
a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)
SID='11111111-1111-4111-8111-111111111111'
DATA=dict(session_id=SID,owner='123',home='/fixture',remote='unix:///fixture.sock')
REQUEST={'id':'server-1','method':a.QUESTION,'params':{'threadId':SID,'turnId':'turn1','itemId':'call1','isBlocking':True,
 'questions':[{'id':'q1','header':'Choice','question':'继续？','options':[{'label':'是','description':'继续'},{'label':'否','description':'停止'}]},
              {'id':'q2','header':'Text','question':'Path?','options':None}]}}


class Fake:
    def __init__(self,request=None,state='active',before=False):
        self.request=copy.deepcopy(request or REQUEST);self.events=[];self.sent=[];self.calls=[];self.closed=False
        self.state=state;self.before=before;self.replayed=False;self.already=False
        self.socket=None
    def call(self,method,params):
        self.calls.append((method,params))
        if method in ('thread/read','thread/resume'):
            if method=='thread/resume':
                self.replayed=True
                if self.before:self.events.append(self.request)
            if self.already:self.events.append(self.resolution())
            return {'thread':{'id':SID,'status':{'type':self.state,'activeFlags':['waitingOnUserInput']}}}
        raise AssertionError(method)
    def resolution(self):return {'method':'serverRequest/resolved','params':{'threadId':SID,'requestId':self.request['id']}}
    def receive(self,nonblocking=False):
        if nonblocking:return None
        if self.replayed:self.replayed=False;return self.request
        raise TimeoutError('no matching pending request')
    def send(self,value):self.sent.append(value);self.events.append(self.resolution())
    def close(self):self.closed=True


class Attention(unittest.TestCase):
    def setUp(self):
        self.identity=patch.dict(a.session,identity=lambda *_:dict(DATA));self.identity.start();self.addCleanup(self.identity.stop)

    def test_question_replay_before_or_after_resume_response(self):
        for before in (False,True):
            f=Fake(before=before)
            with patch.object(a,'Client',return_value=f):
                pending=a.Pending(DATA);self.assertEqual(pending.show()['questions'],REQUEST['params']['questions'])
                pending.respond(a.answers(pending.request,['1','text:/a path']), '%1','isolated')
                self.assertEqual(f.sent,[{'id':'server-1','result':{'answers':{'q1':{'answers':['是']},'q2':{'answers':['/a path']}}}}])
                self.assertIn(('thread/resume',{'threadId':SID,'excludeTurns':True}),f.calls)
                pending.close();self.assertTrue(f.closed)

    def test_wrong_token_old_thread_and_replaced_launcher_send_nothing(self):
        f=Fake()
        with patch.object(a,'Client',return_value=f):
            with self.assertRaises(TimeoutError):a.Pending(DATA,token='old-token')
        self.assertFalse(f.sent);self.assertTrue(f.closed)
        f=Fake(state='notLoaded')
        with patch.object(a,'Client',return_value=f):
            with self.assertRaises(ValueError):a.Pending(DATA)
        self.assertFalse(any(method=='thread/resume' for method,_ in f.calls))
        f=Fake()
        with patch.object(a,'Client',return_value=f):
            pending=a.Pending(DATA)
            with patch.dict(a.session,identity=lambda *_:dict(DATA,owner='456')):
                with self.assertRaises(ValueError):pending.respond({'answers':{}},'%1','isolated')
        self.assertFalse(f.sent)

    def test_resolved_request_cannot_be_answered_again(self):
        f=Fake()
        with patch.object(a,'Client',return_value=f):
            pending=a.Pending(DATA);f.already=True
            with self.assertRaisesRegex(ValueError,'already resolved'):pending.respond({'answers':{}},'%1','isolated')
        self.assertFalse(f.sent)

    def test_question_validation_and_request_fingerprint(self):
        for picks in (['1'],['3','text:path'],['text:arbitrary','text:path'],['1','text:']):
            with self.assertRaises(ValueError):a.answers(REQUEST,picks)
        self.assertNotEqual(a.fingerprint(DATA,REQUEST),a.fingerprint(dict(DATA,owner='456'),REQUEST))
        changed=copy.deepcopy(REQUEST);changed['params']['questions'][0]['question']='different question'
        self.assertNotEqual(a.fingerprint(DATA,REQUEST),a.fingerprint(DATA,changed))

    def test_native_permission_denial_is_opt_in_and_never_approval(self):
        req={'id':7,'method':'item/commandExecution/requestApproval','params':{'threadId':SID,'turnId':'t','itemId':'i','command':'fixture command'}}
        token=a.fingerprint(DATA,req)
        cmd=['attention','deny','--pane','%1','--category','perm','--request-token',token]
        with patch.object(sys,'argv',cmd),patch.dict(os.environ,FLEET_ALLOW_AUTO_DENY='0'):
            with self.assertRaisesRegex(ValueError,'not armed'):a.main()
        f=Fake(req)
        with patch.object(sys,'argv',cmd),patch.dict(os.environ,FLEET_ALLOW_AUTO_DENY='1'),patch.object(a,'Client',return_value=f):
            self.assertEqual(a.main(),0)
        self.assertEqual(f.sent,[{'id':7,'result':{'decision':'decline'}}])

    def test_cli_requires_shown_token_and_accepts_trailing_picks(self):
        with patch.object(sys,'argv',['attention','answer','--pane','%1','1','text:path']):
            with self.assertRaisesRegex(ValueError,'request-token'):a.main()
        f=Fake();token=a.fingerprint(DATA,REQUEST)
        with patch.object(sys,'argv',['attention','answer','--pane','%1','--request-token',token,'1','text:path']),patch.object(a,'Client',return_value=f):
            self.assertEqual(a.main(),0)
        self.assertEqual(f.sent[0]['result']['answers']['q2']['answers'],['path'])

    def test_kind_uses_native_flags_only(self):
        for flags,result in [([],''),(['waitingOnUserInput'],'ask'),(['waitingOnApproval'],'perm')]:
            self.assertEqual(a.kind({'status':{'type':'active','activeFlags':flags}}),result)
        self.assertEqual(a.kind({'status':{'type':'idle','activeFlags':['waitingOnApproval']}}),'')

    @unittest.skipUnless(shutil.which('tmux'),'tmux missing')
    def test_monitor_private_socket_identity_races_and_explicit_blocker(self):
        label='codex-attention-test-'+str(os.getpid())
        tm=['tmux','-L',label]
        def call(*args):return subprocess.check_output(tm+list(args),text=True).strip()
        def opt(name,value):call('set-option','-w','-t','%0',name,value)
        try:
            call('new-session','-d','-s','fixture','sleep 60')
            for name,value in [('@cc_agent','codex'),('@cc_launcher_pid','123'),('@codex_session_id',SID),('@claude_state','working')]:opt(name,value)
            f=Fake();mon=a.Monitor(DATA['remote'],{'TMUX_PANE':'%0','FLEET_CODEX_LAUNCHER_PID':'123'})
            with patch.dict(a.session,tmux=lambda args:call(*args)),patch.object(a,'Client',return_value=f):
                mon.tick();self.assertEqual(call('display-message','-p','#{@claude_state}/#{@claude_needs}'),'needs/ask')
                # the question's own words, as Claude's needs carry them (#1951)
                self.assertEqual(call('display-message','-p','#{@claude_needs_detail}'),'继续？')
                f.state='idle';mon.next_at=0;mon.reconcile_at=0;mon.tick()
                self.assertEqual(call('display-message','-p','#{@claude_state}/#{@claude_needs}'),'done/')
                self.assertEqual(call('display-message','-p','#{@claude_needs_detail}'),'')
                opt('@codex_attention','ask');opt('@claude_state','needs');opt('@claude_needs','blocked')
                mon.next_at=0;mon.reconcile_at=0;mon.tick()
                self.assertEqual(call('display-message','-p','#{@claude_state}/#{@claude_needs}'),'needs/blocked')
                opt('@cc_launcher_pid','456');f.state='active';mon.next_at=0;mon.tick()
                self.assertEqual(call('display-message','-p','#{@claude_state}/#{@claude_needs}'),'needs/blocked')
                self.assertTrue(f.closed)
                mon.close()
        finally:subprocess.run(tm+['kill-server'],capture_output=True)


class MonitorEvents(unittest.TestCase):
    def setUp(self):
        self.now=100
        self.data=dict(DATA)
        self.native=Fake(state='idle')
        self.options='working||'
        self.writes=[]
        self.monitor=a.Monitor(DATA['remote'],{'TMUX_PANE':'%fixture','FLEET_CODEX_LAUNCHER_PID':'123'})
        def tmux(arguments):
            if arguments[0]=='display-message':return self.options
            self.writes.append(arguments)
            return ''
        patches=[patch.dict(a.session,identity=lambda *_:dict(self.data),tmux=tmux),
                 patch.object(a,'request_detail',return_value='fixture question'),
                 patch.object(a.time,'monotonic',side_effect=lambda:self.now)]
        for fixture in patches:
            fixture.start();self.addCleanup(fixture.stop)
        connection=patch.object(a,'Client',return_value=self.native)
        self.connect=connection.start();self.addCleanup(connection.stop)
        self.addCleanup(self.monitor.close)

    def tick(self):
        self.now+=2
        self.monitor.tick()

    def status(self,state,flags=(),identifier=SID):
        return {'method':'thread/status/changed','params':{'threadId':identifier,
                'status':{'type':state,'activeFlags':list(flags)}}}

    def test_idle_reuses_connection_and_only_reconciles_every_thirty_seconds(self):
        self.native.events.append(self.status('idle'))
        for _ in range(30):self.tick()
        self.assertEqual(self.connect.call_count,1)
        self.assertEqual(self.native.calls,[('thread/read',{'threadId':SID,'includeTurns':False})]*2)
        self.assertFalse(self.native.closed)
        self.assertFalse(self.native.sent)
        self.assertFalse(self.writes)
        self.monitor.close()
        self.assertTrue(self.native.closed)

    def test_unproven_stream_keeps_original_snapshot_cadence(self):
        for _ in range(3):self.tick()
        self.assertEqual(self.connect.call_count,1)
        self.assertEqual(len(self.native.calls),3)
        self.assertFalse(self.monitor.event_stream)

    def native_meter(self):
        self.monitor.native_usage=True
        self.monitor.meter=Mock()
        original=self.native.call
        def capable(method,params):
            result=original(method,params)
            result['thread'].update(source='appServer',parentThreadId=None)
            if method=='thread/resume':result.update(model='native-fixture',reasoningEffort='high')
            return result
        self.native.call=capable
        return self.monitor.meter

    def test_native_meter_reuses_connection_coalesces_exact_usage_and_never_answers(self):
        meter=self.native_meter()
        self.tick()
        self.assertEqual([method for method,_ in self.native.calls],['thread/read','thread/resume'])
        self.assertEqual(self.connect.call_args.kwargs['opt_out_notifications'],a.TELEMETRY_OPT_OUT)
        meter.reset_mock()
        for identifier,count in ((SID,1),('other-thread',999),(SID,2)):
            self.native.events.append({'method':'thread/tokenUsage/updated','params':{
                'threadId':identifier,'tokenUsage':{'last':{'totalTokens':count},'modelContextWindow':100}}})
        self.native.events.append(REQUEST)
        self.tick()
        self.assertEqual(meter.observe.call_count,1)
        self.assertEqual(meter.observe.call_args.args[1]['last']['totalTokens'],2)
        self.assertEqual(meter.observe.call_args.args[2],{'model':'native-fixture','effort':'high'})
        self.assertFalse(self.native.sent)
        self.assertEqual(self.connect.call_count,1)
        self.monitor.close()
        meter.reset_native.assert_called()

    def test_native_meter_does_not_load_old_or_helper_threads(self):
        meter=self.native_meter()
        for status,source,parent,origin in (('notLoaded','appServer',None,None),('systemError','appServer',None,None),
                                            ('idle',{'subAgent':'thread_title'},None,None),('idle','appServer','parent',None),
                                            ('idle','appServer',None,'thread_title')):
            self.monitor.close();self.monitor.next_at=0
            def snapshot(method,params):
                self.assertEqual(method,'thread/read')
                return {'thread':{'id':SID,'status':{'type':status},'source':source,'parentThreadId':parent,'threadSource':origin}}
            with patch.object(self.native,'call',side_effect=snapshot):self.tick()
            self.assertFalse(self.monitor.subscribed)
        meter.observe.assert_not_called()

    def test_native_meter_malformed_event_or_changed_identity_restores_fallback(self):
        meter=self.native_meter()
        self.tick();meter.reset_mock()
        self.native.events.append({'method':'thread/tokenUsage/updated','params':{'threadId':SID,'tokenUsage':None}})
        self.tick()
        self.assertIsNone(self.monitor.client)
        meter.reset_native.assert_called_once()
        meter.observe.assert_not_called()

    def test_native_meter_settings_follow_native_events_not_config_guesses(self):
        meter=self.native_meter()
        self.tick();meter.reset_mock()
        self.native.events.append({'method':'thread/settings/updated','params':{
            'threadId':SID,'threadSettings':{'model':'updated-model','effort':None}}})
        self.tick()
        self.assertEqual(meter.observe.call_args.args[2],{'model':'updated-model','effort':None})
        self.native.events.append({'method':'model/rerouted','params':{'threadId':SID,'toModel':'rerouted-model'}})
        self.tick()
        self.assertEqual(meter.observe.call_args.args[2]['model'],'rerouted-model')

    def test_native_meter_closed_or_unloaded_thread_resets_and_rejoins_when_loaded(self):
        meter=self.native_meter()
        for event in ({'method':'thread/closed','params':{'threadId':SID}}, self.status('notLoaded')):
            self.monitor.close();self.monitor.next_at=0
            self.tick();meter.reset_mock()
            self.monitor.reconcile_at=self.now+30
            self.native.events.append(event)
            self.tick()
            self.assertFalse(self.monitor.subscribed)
            meter.reset_native.assert_called_once()
            meter.keep_native.assert_not_called()
            self.monitor.reconcile_at=0
            self.tick()
            self.assertTrue(self.monitor.subscribed)

    def test_native_meter_resume_failure_keeps_fallback_and_never_starts_a_turn(self):
        meter=self.native_meter()
        original=self.native.call
        def unavailable(method,params):
            if method=='thread/resume':raise ValueError('no rollout found for fresh thread')
            return original(method,params)
        with patch.object(self.native,'call',side_effect=unavailable):self.tick()
        self.assertIsNone(self.monitor.client)
        meter.reset_native.assert_called()
        meter.observe.assert_not_called()
        self.assertFalse(self.native.sent)

    def test_native_meter_rechecks_identity_and_resume_result_before_observation(self):
        meter=self.native_meter()
        original=self.native.call
        for race in ('identity','thread'):
            self.data=dict(DATA)
            def changed(method,params):
                result=original(method,params)
                if method=='thread/resume':
                    if race=='identity':self.data['home']='/replacement-home'
                    else:result['thread']['id']='replacement-thread'
                return result
            with patch.object(self.native,'call',side_effect=changed):self.tick()
            self.assertIsNone(self.monitor.client)
            self.assertFalse(self.monitor.subscribed)
        meter.observe.assert_not_called()

    def test_native_events_update_exact_thread_without_resuming_or_reading_again(self):
        self.tick()
        self.native.events.append(self.status('active',['waitingOnUserInput'],'other-thread'))
        self.tick();self.assertFalse(self.writes)
        self.assertFalse(self.monitor.event_stream)
        self.native.events.append(self.status('active',['waitingOnUserInput']))
        self.tick()
        self.assertEqual(len(self.writes),1)
        self.assertIn('@claude_needs ask',self.writes[-1][-1])
        self.options='needs|ask|ask'
        self.native.events.append(self.status('idle'))
        self.tick()
        self.assertIn('@claude_state done',self.writes[-1][-1])
        self.assertEqual(len(self.native.calls),2)
        self.assertFalse(self.native.sent)

    def test_disconnect_preserves_attention_and_reconnects_with_snapshot(self):
        self.tick()
        self.options='needs|ask|ask'
        with patch.object(self.monitor,'events',side_effect=EOFError('fixture disconnect')):
            self.tick()
        self.assertTrue(self.native.closed)
        self.assertFalse(self.writes)
        replacement=Fake(state='idle')
        self.connect.return_value=replacement
        self.tick()
        self.assertEqual(self.connect.call_count,2)
        self.assertIn('@claude_state done',self.writes[-1][-1])
        self.assertEqual(len(replacement.calls),1)

    def test_identity_change_closes_old_stream_before_processing_events(self):
        self.tick()
        self.native.events.append(self.status('active',['waitingOnApproval']))
        self.data['owner']='replacement'
        self.tick()
        self.assertTrue(self.native.closed)
        self.assertFalse(self.writes)
        self.assertEqual(self.connect.call_count,1)

    def test_account_home_change_rebinds_even_with_same_thread_and_owner(self):
        self.tick()
        replacement=Fake(state='idle')
        self.connect.return_value=replacement
        self.data['home']='/new-account-home'
        self.tick()
        self.assertTrue(self.native.closed)
        self.assertEqual(self.connect.call_count,2)
        self.assertEqual(len(replacement.calls),1)

    def test_unloaded_and_failed_threads_never_mean_success(self):
        self.tick()
        self.options='needs|ask|ask'
        for state in ('notLoaded','systemError','future-state'):
            self.native.events.append(self.status(state))
            self.tick()
            self.assertNotIn('@claude_state',self.writes[-1][-1])
        self.native.events.append({'method':'thread/closed','params':{'threadId':SID}})
        self.tick()
        self.assertNotIn('@claude_state',self.writes[-1][-1])

    def test_malformed_or_excessive_events_drop_connection_without_state_changes(self):
        for backlog in ([{'method':'thread/status/changed','params':{'threadId':SID,'status':'invalid'}}],
                        [self.status('active',['waitingOnApproval'])]*129):
            self.monitor.close()
            self.native=Fake(state='idle')
            self.connect.return_value=self.native
            self.tick()
            self.native.events.extend(backlog)
            self.tick()
            self.assertTrue(self.native.closed)
            self.assertFalse(self.writes)

    def test_initial_snapshot_supersedes_queued_old_events(self):
        self.native.events.append(self.status('active',['waitingOnApproval']))
        self.tick()
        self.assertFalse(self.writes)
        self.assertFalse(self.native.events)

    def test_status_changing_during_snapshot_cannot_clear_pending_attention(self):
        self.options='needs|perm|perm'
        original=self.native.call
        def racing_read(method,params):
            result=original(method,params)
            if method=='thread/read':
                self.native.events.append(self.status('active',['waitingOnUserInput']))
                self.native.state='active'
            return result
        with patch.object(self.native,'call',side_effect=racing_read):
            self.tick()
        self.assertFalse(self.writes)
        self.assertEqual(self.monitor.reconcile_at,0)
        self.tick()
        self.assertIn('@claude_needs ask',self.writes[-1][-1])
        self.assertEqual(len(self.native.calls),2)

    def test_resolved_attention_during_snapshot_is_not_reintroduced(self):
        self.native.state='active'
        original=self.native.call
        def racing_read(method,params):
            result=original(method,params)
            if method=='thread/read':
                self.native.events.append(self.status('idle'))
                self.native.state='idle'
            return result
        with patch.object(self.native,'call',side_effect=racing_read):
            self.tick()
        self.assertFalse(self.writes)
        self.tick()
        self.assertFalse(self.writes)
        self.assertEqual(len(self.native.calls),2)

    def test_matching_event_during_snapshot_needs_no_extra_read(self):
        original=self.native.call
        def notified_read(method,params):
            result=original(method,params)
            if method=='thread/read':
                self.native.events.append({'method':'thread/status/changed','params':{
                    'threadId':SID,'status':copy.deepcopy(result['thread']['status'])}})
            return result
        with patch.object(self.native,'call',side_effect=notified_read):
            self.tick()
        self.assertTrue(self.monitor.event_stream)
        self.tick()
        self.assertEqual(len(self.native.calls),1)
        self.assertFalse(self.writes)

    def test_new_root_identity_cannot_reuse_old_thread_snapshot(self):
        self.tick()
        self.data['session_id']='22222222-2222-4222-8222-222222222222'
        self.tick()
        self.assertTrue(self.native.closed)
        self.assertFalse(self.writes)
        self.assertIsNone(self.monitor.client)


unittest.main(verbosity=2)
