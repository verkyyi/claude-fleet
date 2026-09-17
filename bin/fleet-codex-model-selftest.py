#!/usr/bin/env python3
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

BIN=Path(__file__).absolute().parent
spec=importlib.util.spec_from_file_location('model',BIN/'fleet-codex-model.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
SID='11111111-1111-4111-8111-111111111111'


class Rpc:
    def __init__(self):self.model='main-model';self.state='idle';self.calls=[];self.confirm=True;self.closed=False;self.error=None
    def call(self,method,params):
        self.calls.append((method,params))
        thread={'id':SID,'status':{'type':self.state}}
        if method=='thread/read':return {'thread':thread}
        if method=='thread/turns/list':return {'data':[{'id':'failed-turn','status':'failed' if self.error else 'completed','error':{'codexErrorInfo':self.error}}]}
        if method=='thread/resume':return {'thread':thread,'model':self.model}
        if method=='thread/settings/update':
            if self.confirm:self.model=params['model']
            return {}
        raise AssertionError(method)
    def close(self):self.closed=True


class Models(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory(prefix='codex-model-');self.addCleanup(temp.cleanup)
        self.root=Path(temp.name).resolve();self.home=str(self.root/'home');Path(self.home).mkdir()
        self.env=patch.dict(os.environ,FLEET_CONF_DIR=str(self.root/'conf'),FLEET_CODEX_MODEL_LIMIT_IDS='{"main-model":"main-bucket","fallback-model":"other-bucket"}',FLEET_CODEX_QUOTA_TTL='300',FLEET_CODEX_QUOTA_FLOOR='5')
        self.env.start();self.addCleanup(self.env.stop)
        self.data=dict(home=self.home,owner='123',session_id=SID,remote='unix:///fixture.sock',model='main-model')
        self.rpc=Rpc();self.tmux=[];self.flags='done||||'
        def tm(args,socket):
            self.tmux.append(args)
            return self.flags if args[0]=='display-message' else ''
        self.patches=[patch.object(m,'Client',return_value=self.rpc),patch.dict(m.cx,identity=lambda *_:dict(self.data),tmux=tm)]
        for p in self.patches:p.start();self.addCleanup(p.stop)
        self.quota()
    def quota(self,base=10,main=100,other=20):
        a=m.account
        self.cache=dict(home=self.home,auth=a['fingerprint'](self.home),at=time.time(),rateLimits={'primary':{'usedPercent':base}},rateLimitsByLimitId={'main-bucket':{'primary':{'usedPercent':main}},'other-bucket':{'primary':{'usedPercent':other}}})
        a['save'](a['cache_path'](self.home),self.cache)
    def test_native_switch_preserves_thread_and_only_changes_model(self):
        self.assertTrue(m.switch(self.data,'%1','fixture','fallback-model'))
        mutations=[p for method,p in self.rpc.calls if method=='thread/settings/update']
        self.assertEqual(mutations,[{'threadId':SID,'model':'fallback-model'}])
        self.assertEqual(self.rpc.model,'fallback-model');self.assertTrue(self.rpc.closed)
        self.assertEqual(self.tmux[-1][0],'if-shell')
        self.assertIn('@cc_model',self.tmux[-1][-1])
        self.assertFalse(any(method in ('turn/start','thread/start') for method,_ in self.rpc.calls))
    def test_dry_run_busy_and_changed_identity_never_mutate(self):
        self.assertTrue(m.switch(self.data,'%1','fixture','fallback-model',dry=True))
        self.rpc.state='active'
        with self.assertRaises(ValueError):m.switch(self.data,'%1','fixture','fallback-model')
        self.rpc.state='idle'
        with patch.dict(m.cx,identity=lambda *_:dict(self.data,owner='456')):
            with self.assertRaises(ValueError):m.switch(self.data,'%1','fixture','fallback-model')
        self.assertFalse(any(method=='thread/settings/update' for method,_ in self.rpc.calls))
    def test_failed_confirmation_never_stamps_success(self):
        self.rpc.confirm=False
        with self.assertRaisesRegex(ValueError,'not confirmed'):m.switch(self.data,'%1','fixture','fallback-model')
        self.assertFalse(any(args[0]=='if-shell' for args in self.tmux))
    def test_pending_handoff_and_explicit_blocker_prevent_automatic_switch(self):
        self.flags='done||request||'
        with self.assertRaises(ValueError):m.switch(self.data,'%1','fixture','fallback-model',automatic=True)
        self.flags='needs|blocked|||'
        self.assertFalse(m.switch(self.data,'%1','fixture','fallback-model',automatic=True))
        self.assertFalse(any(method=='thread/settings/update' for method,_ in self.rpc.calls))
    def test_fallback_requires_distinct_explicit_buckets_and_headroom(self):
        self.assertTrue(m.eligible(self.home,'main-model','fallback-model'))
        with patch.dict(os.environ,FLEET_CODEX_MODEL_LIMIT_IDS='{}'):self.assertFalse(m.eligible(self.home,'main-model','fallback-model'))
        with patch.dict(os.environ,FLEET_CODEX_MODEL_LIMIT_IDS='{"main-model":"main-bucket","fallback-model":"main-bucket"}'):self.assertFalse(m.eligible(self.home,'main-model','fallback-model'))
        self.quota(base=100);self.assertFalse(m.eligible(self.home,'main-model','fallback-model'))
        self.quota(other=100);self.assertFalse(m.eligible(self.home,'main-model','fallback-model'))
        self.quota(main=20);self.assertFalse(m.eligible(self.home,'main-model','fallback-model'))
    def test_stale_missing_and_expired_buckets_never_allow_fallback(self):
        for mutation in ('stale','missing','reset'):
            self.quota()
            if mutation=='stale':self.cache['at']=time.time()-301
            elif mutation=='missing':self.cache['rateLimitsByLimitId'].pop('other-bucket')
            else:self.cache['rateLimitsByLimitId']['other-bucket']['primary']['resetsAt']=time.time()-1
            m.account['save'](m.account['cache_path'](self.home),self.cache)
            self.assertFalse(m.eligible(self.home,'main-model','fallback-model'))
    def test_only_a_native_quota_failed_turn_gets_a_recovery_message(self):
        rule=m.subprocess.check_output(['bash',str(BIN/'fleet-lang.sh'),'resume'],text=True)
        for error in (None,'contextWindowExceeded','usageLimitExceeded','rateLimitExceeded'):
            self.rpc.model='main-model';self.rpc.error=error;self.flags='working||||'
            with patch.object(m.subprocess,'check_output',return_value=rule),patch.object(m.subprocess,'run',return_value=type('Result',(),{'returncode':0})()) as queue:
                self.assertTrue(m.switch(self.data,'%1','fixture','fallback-model',automatic=True))
                self.assertEqual(queue.call_count,1 if error in ('usageLimitExceeded','rateLimitExceeded') else 0)
                if queue.called:
                    argv=queue.call_args.args[0]
                    self.assertEqual(argv[:6],['codex','queue','--remote',self.data['remote'],'--thread',SID])
                    self.assertIn('language this session',argv[-1])

    def test_native_current_model_overrides_stale_tmux_model_hint(self):
        self.rpc.model='another-model'
        self.assertFalse(m.switch(self.data,'%1','fixture','fallback-model',automatic=True))
        self.assertFalse(any(method=='thread/settings/update' for method,_ in self.rpc.calls))

    def test_queue_failure_is_reported_and_stops_further_worker_changes(self):
        self.rpc.error='usageLimitExceeded'
        rule=m.subprocess.check_output(['bash',str(BIN/'fleet-lang.sh'),'resume'],text=True)
        def tm(args,socket):
            self.tmux.append(args)
            if args[0]=='list-windows':
                return '\n'.join(pane+'|codex|123|done|'+json.dumps(self.data) for pane in ('%1','%2'))
            return self.flags if args[0]=='display-message' else ''
        errors=io.StringIO()
        with patch.dict(os.environ,FLEET_CODEX_MODEL_FALLBACK='fallback-model'),patch.dict(m.cx,tmux=tm),patch.object(m.sys,'stderr',errors),patch.object(m.subprocess,'check_output',return_value=rule),patch.object(m.subprocess,'run',return_value=type('Result',(),{'returncode':1})()):
            self.assertTrue(m.watch('fixture'))
        self.assertIn('model changed, but recovery message was not accepted',errors.getvalue())
        self.assertEqual(sum(method=='thread/settings/update' for method,_ in self.rpc.calls),1)
        self.assertFalse(any('%2' in args for args in self.tmux))


unittest.main(verbosity=2)
