#!/usr/bin/env python3
# A person's native model switch, with no model calls (the quota-triggered
# automatic fallback left with the local Codex account registry, T560).
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

BIN=Path(__file__).absolute().parent
spec=importlib.util.spec_from_file_location('model',BIN/'fleet-codex-model.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
SID='11111111-1111-4111-8111-111111111111'


class Rpc:
    def __init__(self):self.model='main-model';self.state='idle';self.calls=[];self.confirm=True;self.closed=False
    def call(self,method,params):
        self.calls.append((method,params))
        thread={'id':SID,'status':{'type':self.state}}
        if method=='thread/read':return {'thread':thread}
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
        self.env=patch.dict(os.environ,FLEET_CONF_DIR=str(self.root/'conf'))
        self.env.start();self.addCleanup(self.env.stop)
        self.data=dict(home=self.home,owner='123',session_id=SID,remote='unix:///fixture.sock',model='main-model')
        self.rpc=Rpc();self.tmux=[];self.flags='done||||'
        def tm(args,socket):
            self.tmux.append(args)
            return self.flags if args[0]=='display-message' else ''
        self.patches=[patch.object(m,'Client',return_value=self.rpc),patch.dict(m.cx,identity=lambda *_:dict(self.data),tmux=tm)]
        for p in self.patches:p.start();self.addCleanup(p.stop)
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
    def test_pending_handoff_prevents_the_switch(self):
        self.flags='done||request||'
        with self.assertRaises(ValueError):m.switch(self.data,'%1','fixture','fallback-model')
        self.assertFalse(any(method=='thread/settings/update' for method,_ in self.rpc.calls))

    def test_same_model_is_no_change(self):
        self.assertFalse(m.switch(self.data,'%1','fixture','main-model'))
        self.assertFalse(any(method=='thread/settings/update' for method,_ in self.rpc.calls))

    def test_limits_normalize_keeps_usage_only(self):
        raw={'rateLimits':{'primary':{'usedPercent':40,'resetsAt':9,'secret':'x'},'planType':'pro'},
             'rateLimitsByLimitId':{'b':{'secondary':{'usedPercent':5}}},'ordinaryUsageAllowed':True}
        self.assertEqual(m.normalize(raw),{'rateLimits':{'planType':'pro','primary':{'usedPercent':40,'resetsAt':9}},
            'rateLimitsByLimitId':{'b':{'secondary':{'usedPercent':5}}},'ordinaryUsageAllowed':True})
        with self.assertRaises(ValueError):m.normalize({})

    def test_no_automatic_fallback_left(self):
        self.assertFalse(hasattr(m,'watch') or hasattr(m,'eligible'))
        self.assertNotIn('fleet-codex-account',(BIN/'fleet-codex-model.py').read_text())


unittest.main(verbosity=2)
