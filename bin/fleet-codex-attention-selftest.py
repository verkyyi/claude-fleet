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
from unittest.mock import patch

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
    def receive(self):
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
                f.state='idle';mon.next_at=0;mon.tick()
                self.assertEqual(call('display-message','-p','#{@claude_state}/#{@claude_needs}'),'done/')
                opt('@codex_attention','ask');opt('@claude_state','needs');opt('@claude_needs','blocked')
                mon.next_at=0;mon.tick()
                self.assertEqual(call('display-message','-p','#{@claude_state}/#{@claude_needs}'),'needs/blocked')
                opt('@cc_launcher_pid','456');f.state='active';mon.next_at=0;mon.tick()
                self.assertEqual(call('display-message','-p','#{@claude_state}/#{@claude_needs}'),'needs/blocked')
        finally:subprocess.run(tm+['kill-server'],capture_output=True)


unittest.main(verbosity=2)
