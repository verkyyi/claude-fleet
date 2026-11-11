#!/usr/bin/env python3
# Native request fixtures, exact identity checks and private tmux state races.
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
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
sys.path.insert(0,str(BIN));import fleet_codex_fake_appserver as fake
SID='11111111-1111-4111-8111-111111111111'
DATA=dict(session_id=SID,owner='123',home='/fixture',remote='unix:///fixture.sock')
REQUEST={'id':'server-1','method':a.QUESTION,'params':{'threadId':SID,'turnId':'turn1','itemId':'call1','isBlocking':True,
 'questions':[{'id':'q1','header':'Choice','question':'继续？','options':[{'label':'是','description':'继续'},{'label':'否','description':'停止'}]},
              {'id':'q2','header':'Text','question':'Path?','options':None}]}}


def Fake(request=None,state='active',before=False):
    """A connection to the one fake Codex (T585) whose thread holds `request`, replayed
    before or after the resume's answer, as the real server does."""
    codex=fake.Codex(threads=[dict(id=SID)]);set_state(codex,state)
    codex.server_request(copy.deepcopy(request or REQUEST),replay='before' if before else 'after')
    return codex.client()


def set_state(codex,state):
    codex.threads[SID]['status']={'type':state,'activeFlags':['waitingOnUserInput']}


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
            pending=a.Pending(DATA);f.codex.resolve(REQUEST['id'])
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
                set_state(f.codex,'idle');mon.next_at=0;mon.reconcile_at=0;mon.tick()
                self.assertEqual(call('display-message','-p','#{@claude_state}/#{@claude_needs}'),'done/')
                self.assertEqual(call('display-message','-p','#{@claude_needs_detail}'),'')
                opt('@codex_attention','ask');opt('@claude_state','needs');opt('@claude_needs','blocked')
                mon.next_at=0;mon.reconcile_at=0;mon.tick()
                self.assertEqual(call('display-message','-p','#{@claude_state}/#{@claude_needs}'),'needs/blocked')
                opt('@cc_launcher_pid','456');set_state(f.codex,'active');mon.next_at=0;mon.tick()
                self.assertEqual(call('display-message','-p','#{@claude_state}/#{@claude_needs}'),'needs/blocked')
                self.assertTrue(f.closed)
                mon.close()
        finally:subprocess.run(tm+['kill-server'],capture_output=True)


class MonitorEvents(unittest.TestCase):
    def setUp(self):
        self.now=100
        self.data=dict(DATA)
        self.native=Fake(state='idle')
        self.options='done||'
        self.writes=[]
        self.monitor=a.Monitor(DATA['remote'],{'TMUX_PANE':'%fixture','FLEET_CODEX_LAUNCHER_PID':'123'})
        self.tmp=tempfile.mkdtemp();self.addCleanup(shutil.rmtree,self.tmp,True)
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

    def test_long_idle_slows_the_monitor_and_work_keeps_two_seconds(self):
        # 36 Codex sessions × two tmux forks every 2 s slowed one machine's tmux:
        # a session done (nothing asked) past IDLE_AFTER is looked at every IDLE_SECS
        old=str(int(a.time.time())-1000)
        with patch.dict(os.environ,{'FLEET_CODEX_ATTENTION_IDLE_SECS':'6','FLEET_CODEX_ATTENTION_IDLE_AFTER':'300'}):
            self.options='done|||'+old
            self.now+=2;self.monitor.tick()
            self.assertEqual(self.monitor.next_at,self.now+6)
            for state in ('working|||'+old,'needs|ask|ask|'+old,'done|||'+str(int(a.time.time()))):
                self.options=state
                self.now+=7;self.monitor.tick()
                self.assertEqual(self.monitor.next_at,self.now+2,state)

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

    def test_native_idle_clears_working_after_interrupt_without_stop_hook(self):
        self.options='working|||17'
        self.native.events.append(self.status('idle'))
        self.tick()
        self.assertIn('@claude_state done',self.writes[-1][-1])
        self.assertIn('@turn_activity_at',self.writes[-1][-1])
        self.assertIn('#{==:#{@claude_state},working}',self.writes[-1][-2])
        self.assertIn('#{==:#{@claude_state_ts},17}',self.writes[-1][-2])
        self.assertNotIn('thread/resume',[method for method,_ in self.native.calls])

    def test_queued_old_idle_cannot_demote_a_new_native_turn_in_same_second(self):
        self.options='working|||17'
        self.native.codex.threads[SID]['status']={'type':'active','activeFlags':[]}
        self.tick()
        self.monitor.reconcile_at=self.now+30
        self.native.events.append(self.status('idle'))
        self.tick()
        self.assertFalse(self.writes)
        self.assertEqual(self.monitor.reconcile_at,0)

    def test_native_idle_never_clears_explicit_blocked_or_loop_state(self):
        for state in ('needs|blocked||17', 'looping|||17'):
            self.options=state
            self.monitor.reconcile_at=0
            self.native.events.append(self.status('idle'))
            self.tick()
        self.assertFalse(self.writes)

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
        self.assertNotIn('@turn_activity_at',self.writes[-1][-1])
        self.options='needs|ask|ask'
        self.native.events.append(self.status('idle'))
        self.tick()
        self.assertIn('@claude_state done',self.writes[-1][-1])
        self.assertIn('@turn_activity_at',self.writes[-1][-1])
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
        self.assertIn('@turn_activity_at',self.writes[-1][-1])
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

    def test_failed_turn_in_system_error_leaves_working(self):
        # T1381: a turn the credential proxy refused on every retry ends in
        # systemError with no Stop hook; the row must not read working forever.
        # T1392: it reads as a visible failure (needs/error), never done.
        self.options='working|||17'
        self.native.codex.threads[SID]['status']={'type':'systemError','activeFlags':[]}
        self.native.codex._turns[SID]=[dict(id='t1',clientId='c1',status='failed')]
        self.native.events.append(self.status('systemError'))
        self.tick()
        self.assertIn('@claude_state needs',self.writes[-1][-1])
        self.assertIn('@claude_needs error',self.writes[-1][-1])
        self.assertNotIn('@claude_state done',self.writes[-1][-1])
        self.assertIn('#{==:#{@claude_state},working}',self.writes[-1][-2])
        # an unsettled (or not failed) last turn, or a person's blocker, writes nothing
        for turn,options in (('inProgress','working|||17'),('failed','needs|blocked||17')):
            self.writes.clear();self.options=options
            self.native.codex._turns[SID]=[dict(id='t1',clientId='c1',status=turn)]
            self.native.events.append(self.status('systemError'))
            self.tick()
            self.assertFalse(any('@claude_state ' in w[-1] for w in self.writes),(turn,options))

    def failed(self,error,state='systemError',options='working|||17'):
        self.writes.clear();self.options=options
        self.native.codex.threads[SID]['status']={'type':state,'activeFlags':[]}
        self.native.codex._turns[SID]=[dict(id='t0',status='completed'),dict(id='t1',status='failed',error=error)]
        self.native.events.append(self.status(state))
        self.tick()
        return self.writes[-1][-1] if self.writes else ''

    def test_t1392_retryable_failure_is_visible_and_books_one_resume(self):
        # the GW7F case: `■ unexpected status 409 …` with the row at «working» for two days
        e409={'message':'unexpected status 409 Conflict: {"error":"Codex continuation source unknown"}','codexErrorInfo':None}
        before=int(a.time.time())
        with patch.dict(os.environ,{'FLEET_CODEX_TURN_RETRY_SECS':'30','FLEET_CODEX_TURN_RETRY_MAX':'2','FLEET_CONF_DIR':self.tmp}):
            for state in ('systemError',):
                w=self.failed(e409,state)
                self.assertIn('@claude_state needs',w);self.assertIn('@claude_needs error',w)
                self.assertIn('unexpected status 409 Conflict',w)
                self.assertIn('自动重试 1/2，30 秒后',w)
                at=int(w.split('@turn_retry_at ')[1].split()[0].strip("'"))
                self.assertTrue(before+30<=at<=int(a.time.time())+30,w)
                self.assertRegex(w,r"@turn_retry '1 \d+'")
            # inside the window, a second failure books the second resume at twice the wait
            w=self.failed(e409,options='working|||17||1 %d'%before)
            self.assertIn('自动重试 2/2，60 秒后',w)
            # the budget spent: left for a person, no resume booked
            w=self.failed(e409,options='working|||17||2 %d'%before)
            self.assertIn('已自动重试 2 次仍失败，等你处理',w);self.assertIn("@turn_retry_at ''",w)
            # an old book (past the window) starts again
            w=self.failed(e409,options='working|||17||2 %d'%(before-4000))
            self.assertIn('自动重试 1/2',w)
            # FLEET_CODEX_TURN_RETRY=0: shown, never resumed
            with patch.dict(os.environ,{'FLEET_CODEX_TURN_RETRY':'0'}):
                w=self.failed(e409)
            self.assertIn('不会自动重试，等你处理',w);self.assertIn("@turn_retry_at ''",w)
        self.assertIn('booked 1/2',Path(self.tmp,'logs','codex-turn-retry.log').read_text())

    def test_t1392_final_failure_is_shown_never_resumed(self):
        with patch.dict(os.environ,{'FLEET_CONF_DIR':self.tmp}):
            for error in ({'message':'unexpected status 403 Forbidden: person_budget_exceeded','codexErrorInfo':None},
                          {'message':'You have hit your usage limit','codexErrorInfo':'usageLimitExceeded'},
                          {'message':'unexpected status 429 Too Many Requests','codexErrorInfo':None},
                          {'message':'bad request','codexErrorInfo':'badRequest'}):
                w=self.failed(error)
                self.assertIn('@claude_needs error',w);self.assertIn('不会自动重试，等你处理',w);self.assertIn("@turn_retry_at ''",w)

    def test_t1392_due_resume_is_sent_once_over_the_inbox(self):
        sent=[];values={'#{@turn_retry_at}':'100','#{@turn_error}':'unexpected status 409 Conflict'}
        def tmux(arguments):
            if arguments[0]=='display-message':
                return values.get(arguments[-1],self.options)
            if arguments[0]=='if-shell' and '#{==:#{@turn_retry_at},100}' in arguments[-2] and values['#{@turn_retry_at}']=='100':
                values['#{@turn_retry_at}']='sent:100'
            self.writes.append(arguments);return ''
        self.native.codex.threads[SID]['status']={'type':'systemError','activeFlags':[]}
        with patch.dict(a.session,tmux=tmux),patch.object(a,'resume_send',side_effect=lambda *x:sent.append(x)),\
             patch.dict(os.environ,{'FLEET_CONF_DIR':self.tmp}):
            self.options='needs|error||17|100|1 17'
            self.tick()
            self.assertEqual(len(sent),1);self.assertEqual(sent[0][0],'%fixture')
            self.assertIn('unexpected status 409 Conflict',sent[0][1]);self.assertIn('Continue the task',sent[0][1])
            self.assertIn('已自动续一轮',self.writes[-1][-1])
            self.assertIn('#{==:#{@claude_state_ts},17}',self.writes[-1][-2])
            self.options='needs|error||17|sent:100|1 17'
            for _ in range(3):self.tick()
            self.assertEqual(len(sent),1)
            # not due yet: nothing sent
            values['#{@turn_retry_at}']=str(int(a.time.time())+600);self.options='needs|error||17|%s|1 17'%values['#{@turn_retry_at}']
            self.tick();self.assertEqual(len(sent),1)

    def test_t1392_running_again_ends_the_error_row(self):
        self.native.codex.threads[SID]['status']={'type':'active','activeFlags':[]}
        self.options='needs|error||17|sent:100|1 17'
        self.native.events.append(self.status('active'))
        self.tick()
        w=self.writes[-1]
        self.assertIn('@claude_state working',w[-1]);self.assertIn("@claude_needs ''",w[-1])
        self.assertIn('#{==:#{@claude_needs},error}',w[-2])

    def test_t1392_turn_error_classification(self):
        for error,retry in (({'message':'unexpected status 409 Conflict'},True),
                            ({'message':'unexpected status 502 Bad Gateway'},True),
                            ({'message':'stream disconnected before completion: Transport error'},True),
                            ({'message':'x','codexErrorInfo':{'responseTooManyFailedAttempts':{'httpStatusCode':503}}},True),
                            ({'message':'x','codexErrorInfo':{'responseTooManyFailedAttempts':{'httpStatusCode':401}}},False),
                            ({'message':'x','codexErrorInfo':{'responseStreamDisconnected':{'httpStatusCode':None}}},True),
                            ({'message':'x','codexErrorInfo':'serverOverloaded'},True),
                            ({'message':'unexpected status 401 Unauthorized','codexErrorInfo':'unauthorized'},False),
                            ({'message':'context window exceeded','codexErrorInfo':'contextWindowExceeded'},False),
                            ({'message':'something odd'},False),(None,False)):
            self.assertEqual(a.turn_error({'status':'failed','error':error})[1],retry,error)
        summary=a.turn_error({'error':{'message':'unexpected status 409: Authorization: Bearer abcdefghijklmnop\nsecond line'}})[0]
        self.assertNotIn('abcdefghijklmnop',summary);self.assertNotIn('second line',summary)
        self.assertLessEqual(len(a.error_summary('x'*500)),160)

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
                set_state(self.native.codex,'active')
            return result
        with patch.object(self.native,'call',side_effect=racing_read):
            self.tick()
        self.assertFalse(self.writes)
        self.assertEqual(self.monitor.reconcile_at,0)
        self.tick()
        self.assertIn('@claude_needs ask',self.writes[-1][-1])
        self.assertNotIn('@turn_activity_at',self.writes[-1][-1])
        self.assertEqual(len(self.native.calls),2)

    def test_resolved_attention_during_snapshot_is_not_reintroduced(self):
        set_state(self.native.codex,'active')
        original=self.native.call
        def racing_read(method,params):
            result=original(method,params)
            if method=='thread/read':
                self.native.events.append(self.status('idle'))
                set_state(self.native.codex,'idle')
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
