#!/usr/bin/env python3
# selftest-entry
"""bin/fleet-cred-proxy.py capacity policy, legacy upgrade/fallback and no replay.
Shared numeric contract: tokenledger/shared/credproxy/testdata/capacity_policy.json.
"""
import copy
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

BIN = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('proxy', BIN / 'fleet-cred-proxy.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class Capacity(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cfg = SimpleNamespace(state=self.tmp.name, pool='', store=True, log='', name='fixture',
            accounts=self.tmp.name+'/accounts', codex_auth=self.tmp.name+'/auth.json',
            codex_homes=self.tmp.name+'/homes', node_env=self.tmp.name+'/node.env',
            pick_ceiling=85, timeout=5, quota_push='', quota_push_secs=1, ttl=86400)
        self.t = p.Tenant(self.cfg)
        self.t.held = lambda provider: ['a','b']
        p.Proxy.tenants, p.Proxy.reads, p.Proxy.limited = {}, {}, {}
        self.install()

    def install(self, scores=(.8,3), states=('usable','usable'), mode='active'):
        self.t.capacity_cache = dict(policy='codex-capacity-v2',mode=mode,catalog_revision=1,accounts=[
            dict(account=a,owner='pool',credential_id=a+'-identity',state=st,score=score,
                refresh_healthy=True,conservative=dict(state=st),capacity=dict(
                    profile=dict(pool='codex',unit='relative-work',basis='fixture-v1',confidence='provisional'),
                    estimated_remaining_units=score,calibration_factor=1,calibration_status='pending_matched_observations'))
            for a,score,st in zip(('a','b'), scores,states)])
        self.t.capacity_until=time.time()+30

    def test_shared_vectors(self):
        vectors=json.loads((BIN.parent/'tokenledger/shared/credproxy/testdata/capacity_policy.json').read_text())
        for v in vectors:
            self.install(v['scores'],v['states'])
            decision=self.t.codex_pick(v['name'],preview=True)
            self.assertEqual(decision['account'],('a','b')[v['pick']])
            self.assertFalse(decision['mutates_bindings'])
        self.assertFalse(Path(self.tmp.name,'codex-routing.json').exists())
        self.assertFalse(self.t.picks)

    def test_hold_material_concurrency_and_persistence(self):
        self.install((1,.5)); self.assertEqual(self.t.codex_pick('session')['account'],'a')
        self.install((.5,1),('usable','tight'))
        self.assertEqual(self.t.codex_pick('session')['reason'],'minimum_hold')
        self.t.codex_state['sessions']['session']['changed']=time.time()-601
        results=[]
        workers=[threading.Thread(target=lambda:results.append(self.t.codex_pick('session')['account'])) for _ in range(12)]
        for w in workers:w.start()
        for w in workers:w.join()
        self.assertEqual(results,['b']*12)
        new=p.Tenant(self.cfg); new.held=self.t.held
        self.assertEqual(new.codex_state['sessions']['session']['account'],'b')
        self.install((1.25,1)); self.t.codex_state['sessions']['session']['changed']=time.time()-601
        self.assertEqual(self.t.codex_pick('session')['account'],'b')

    def test_affinity_pin_encrypted_tool_and_unknown(self):
        self.install((1,.5)); self.t.codex_pick('s')
        event=dict(response=dict(id='response-a',output=[dict(type='reasoning',encrypted_content='opaque'),dict(type='function_call',call_id='call-a')]))
        refs=p.codex_output_refs(event); self.t.codex_record('s','a',refs,p.codex_ref('account','source-a'))
        self.install((.5,3)); self.t.codex_state['sessions']['s']['changed']=time.time()-601
        self.t.codex_pick('s')
        for body in (dict(previous_response_id='response-a'), dict(input=[dict(type='reasoning',encrypted_content='opaque')]),dict(input=[dict(type='function_call_output',call_id='call-a',output='text')])):
            independent, refs, unknown=p.codex_context('POST','/codex/responses',{},json.dumps(body).encode())
            self.assertFalse(independent)
            self.assertEqual(self.t.codex_pick('s',independent,refs,unknown)['account'],'a')
            with self.assertRaises(ValueError):self.t.codex_pick('s',independent,refs,unknown,pin='b')
        with self.assertRaises(ValueError):self.t.codex_pick('s',False,[],True)
        with self.assertRaises(ValueError):self.t.codex_pick('s',False,[p.codex_ref('id','missing')])
        self.t.codex_limits['a']=time.time()+600
        with self.assertRaises(ValueError):self.t.codex_pick('s',False,[p.codex_ref('id','response-a')])
        raw=Path(self.tmp.name,'codex-routing.json').read_text()
        self.assertNotIn('opaque',raw);self.assertNotIn('response-a',raw)

    def test_legacy_fallback_and_upgrade_snapshot(self):
        p.Proxy.reads={('codex','a'):dict(rl5h='95',rl7d='95'),('codex','b'):dict(rl5h='20',rl7d='20')}
        for mode in ('off','shadow','active'):
            self.install(mode=mode)
            # pick_account is deliberately the unchanged legacy picker.
            self.assertEqual(self.t.codex_request('old-'+mode,False,'POST','/codex/responses',{},b'{"previous_response_id":"old-context"}')['account'],'b')
            if mode!='active':
                self.assertEqual(self.t.codex_request('fallback-'+mode,True,'POST','/codex/responses',{},b'{"input":"hello"}')['account'],'b')
        self.t.capacity_until=0
        self.assertEqual(self.t.pick_account('codex','unreachable'),'b')
        with patch.object(p,'ctl_call',return_value=dict(picks={'codex:native-old':'b','claude:c':'a'})):
            p.snapshot_legacy_picks(self.tmp.name,None,self.tmp.name)
        upgraded=p.Tenant(self.cfg); upgraded.held=self.t.held
        self.assertEqual(upgraded.picks['codex','native-old'],'b')
        self.assertEqual(upgraded.codex_request('native-old',False,'POST','/codex/responses',{},b'{"previous_response_id":"old-native-context"}')['account'],'b')
        old_pass=upgraded.keys.mint('', 'native-old',86400)
        claims,_=upgraded.keys.verify(old_pass)
        self.assertNotIn('capacity_policy',claims)
        active_pass=upgraded.keys.mint('', 'new',86400,capacity=True)
        self.assertEqual(upgraded.keys.verify(active_pass)[0]['capacity_policy'],2)

    def test_managed_affinity_survives_off_stale_and_label_reuse(self):
        self.install((1,.5)); self.t.codex_pick('s')
        source=p.codex_ref('account','actual-source-a')
        ref=p.codex_ref('id','response-a')
        self.t.codex_record('s','a',[ref],source)
        p.Proxy.reads={('codex','a'):dict(rl5h='90',rl7d='90'),('codex','b'):dict(rl5h='10',rl7d='10')}
        body=b'{"previous_response_id":"response-a"}'
        for mode in ('off','shadow','active'):
            self.install(mode=mode)
            for stale in (False,True):
                self.t.capacity_until=0 if stale else time.time()+30
                decision=self.t.codex_request('s',True,'POST','/codex/responses',{},body)
                self.assertEqual((decision['account'],decision['expected_source']),('a',source))
        # This is the gate used by attempt(), after the actual held credential
        # has been loaded. Refresh retains the AccountID; label reuse does not.
        h=object.__new__(p.Proxy); h.t=self.t; h.headers={}; h.codex_expected_source=source
        h.fail=lambda *a: failures.append(a)
        h.log=lambda **k:None;failures=[]
        def target(*a):
            h.codex_source_identity=p.codex_ref('account','different-account-under-label-a')
            return 'http://127.0.0.1:1','/responses',{},set(),'file'
        h.target=target
        with patch.object(p.http.client,'HTTPConnection',side_effect=AssertionError('wrong account was sent')):
            self.assertIsNone(h.attempt('direct',None,'codex','/codex/responses',body,None,'s','a',[],time.time(),False,[],0))
        self.assertEqual(failures[0][0],409)
        h.target=lambda *a: (setattr(h,'codex_source_identity',source) or ('http://127.0.0.1:1','/responses',{},set(),'file'))
        h.command='POST'; h.auto=True
        h.upstream=lambda *a,**k: 'sent-same-source'
        self.assertEqual(h.attempt('direct',None,'codex','/codex/responses',body,None,'s','a',[],time.time(),False,[],0),'sent-same-source')
        # The same AccountID across refreshed credentials keeps the same hash.
        self.assertEqual(p.codex_ref('account','actual-source-a'),source)

    def test_load_continuation_activity_dead_stale_preview(self):
        self.install((1,1)); self.t.codex_pick('active')
        state=self.t.codex_state['sessions']['active']; state['seen']=time.time()-601
        self.assertEqual(sum(r['local_recent_reservations'] for r in self.t.codex_pick('preview',preview=True)['inputs']),0)
        self.t.codex_activity('active',state['account'])
        before=copy.deepcopy(self.t.codex_state)
        self.assertEqual(sum(r['local_recent_reservations'] for r in self.t.codex_pick('preview',preview=True)['inputs']),1)
        self.assertEqual(before,self.t.codex_state)
        p.write_json(os.path.join(self.tmp.name,'live.json'),{'active':99999999})
        with patch.object(p,'pid_alive',return_value=False):
            self.assertEqual(sum(r['local_recent_reservations'] for r in self.t.codex_pick('preview',preview=True)['inputs']),0)

    def test_metadata_cache_has_no_request_io(self):
        with patch.object(p.urllib.request,'urlopen',side_effect=AssertionError('request did I/O')):
            self.t.codex_pick('s',preview=True)
            self.t.capacity_until=0
            self.assertEqual(self.t.capacity_metadata(),{})
        self.t.capacity_cache={}; self.t.capacity_retry=0
        Path(self.cfg.node_env).write_text('CCQUOTA_HUB_URL=http://127.0.0.1:1\nCCQUOTA_TOKEN=fixture\n')
        with patch.object(p.urllib.request,'urlopen',side_effect=OSError('unreachable')):
            self.assertEqual(self.t.refresh_capacity_metadata(),{})

    def test_metadata_timestamp_compatibility_and_isolated_lib(self):
        # Go RFC3339Nano output must work with system Python, explicit offsets,
        # and the protected LIB copy (no sibling fleet_iso module is shipped).
        epoch=1791352055
        stamps=['2026-10-07T05:47:35Z', '2026-10-07T05:47:35.2Z',
            '2026-10-07T05:47:35.27204Z', '2026-10-07T05:47:35.272044642Z',
            '2026-10-07T05:47:35.272044642+00:00', '2026-10-07T13:47:35.272044642+08:00',
            '2026-10-07T00:47:35.272044642-05:00']
        Path(self.cfg.node_env).write_text('CCQUOTA_HUB_URL=http://127.0.0.1:1\nCCQUOTA_TOKEN=fixture\n')
        for stamp in stamps:
            with self.subTest(stamp=stamp):
                data=copy.deepcopy(self.t.capacity_cache); data['expires_at']=stamp
                self.t.capacity_retry=0
                with patch.object(p.time,'time',return_value=epoch-25), patch.object(p.urllib.request,'urlopen',return_value=io.BytesIO(json.dumps(data).encode())):
                    self.assertEqual(self.t.refresh_capacity_metadata()['mode'],'active')
                    self.assertAlmostEqual(self.t.capacity_until,p.iso_epoch(stamp))
        for stamp in ('2026-10-07T05:47:35', '2026-10-07T05:47:35+25:00',
                '2026-10-07T05:47:35+00:60', '2026-13-07T05:47:35Z', 'junk', None):
            self.t.capacity_cache={}; self.t.capacity_until=0; self.t.capacity_retry=0
            with patch.object(p.time,'time',return_value=epoch-25), patch.object(p.urllib.request,'urlopen',return_value=io.BytesIO(json.dumps(dict(policy='codex-capacity-v2',accounts=[],expires_at=stamp)).encode())):
                self.assertEqual(self.t.refresh_capacity_metadata(),{})
                self.assertEqual(self.t.capacity_until,0)
        lib=Path(self.tmp.name,'isolated-lib'); lib.mkdir()
        shutil.copy2(BIN/'fleet-cred-proxy.py',lib/'fleet-cred-proxy.py')
        shutil.copy2(BIN/'fleet-credsep-launch.py',lib/'fleet-credsep-launch.py')
        code="import importlib.util, sys; s=importlib.util.spec_from_file_location('proxy', sys.argv[1]); p=importlib.util.module_from_spec(s); s.loader.exec_module(p); assert abs(p.iso_epoch(sys.argv[2])-1791352055.272044)<1e-6; assert 'fleet_iso' not in sys.modules"
        subprocess.run([sys.executable,'-I','-c',code,str(lib/'fleet-cred-proxy.py'),stamps[3]],cwd=str(lib),check=True)

    def test_background_cache_success_scope_dedup_and_mint_boundary(self):
        import datetime
        data=copy.deepcopy(self.t.capacity_cache)
        data['expires_at']=(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=25)).isoformat()
        Path(self.cfg.node_env).write_text('CCQUOTA_HUB_URL=http://127.0.0.1:1\nCCQUOTA_TOKEN=fixture\n')
        response=io.BytesIO(json.dumps(data).encode())
        self.t.capacity_retry=0
        with patch.object(p.urllib.request,'urlopen',return_value=response) as fetch:
            self.assertEqual(self.t.refresh_capacity_metadata()['mode'],'active')
            self.assertEqual(fetch.call_count,1)
            self.t.codex_request('s',True,'POST','/codex/responses',{},b'{"input":"hello"}')
            self.assertEqual(fetch.call_count,1)
        self.assertLessEqual(self.t.capacity_until-time.time(),30)
        self.assertLess(self.t.capacity_retry,self.t.capacity_until-5)
        # Held aliases fold to one; foreign metadata cannot add a held account.
        self.t.capacity_cache['accounts'].append(dict(self.t.capacity_cache['accounts'][0],account='foreign',score=999))
        self.assertNotIn('foreign',[r['account'] for r in self.t.codex_pick('preview',preview=True)['inputs']])
        self.cfg.pool=self.tmp.name+'/pool'
        p.write_json(os.path.join(self.tmp.name,'pool.json'),{'codex:a':'same-token-key','codex:b':'same-token-key'})
        self.assertEqual(len(self.t.codex_pick('preview',preview=True)['inputs']),1)
        self.cfg.pool=''
        self.t.picks['codex','old']='a'
        old=p.ctl_handle(dict(op='mint',provider='codex',sid='old'),self.t)['token']
        self.assertNotIn('capacity_policy',self.t.keys.verify(old)[0])
        new=p.ctl_handle(dict(op='mint',provider='codex',sid='brand-new'),self.t)['token']
        self.assertEqual(self.t.keys.verify(new)[0]['capacity_policy'],2)

    def test_pause_dedup_unknown_basis_and_local_full(self):
        self.t.paused.add(('codex','b'));self.assertEqual(self.t.codex_pick('s',preview=True)['account'],'a')
        self.t.paused.clear()
        self.t.capacity_cache['accounts'][1]['capacity']['profile']['basis']='incomparable'
        decision=self.t.codex_pick('s',preview=True)
        self.assertEqual(decision['reason'],'conservative_order')
        self.t.note_quota('s','codex','b','direct',[('x-codex-primary-used-percent','100')])
        self.assertEqual(self.t.codex_pick('new',preview=True)['account'],'a')

    def test_codex_429_single_attempt_claude_retry_unchanged(self):
        class Response:
            status=429;reason='Limited'
            def __init__(self): self.raw=io.BytesIO(b'{"error":{"code":"usage_limit_reached"}}')
            def getheaders(self):return [('Content-Type','application/json')]
            def getheader(self,k,default=''):return default
            def read(self,n=-1):return self.raw.read(n)
            def read1(self,n):return self.read(n)
        class Conn:
            def __init__(self,*a,**k):pass
            def connect(self):pass
            def request(self,*a,**k):calls.append(a)
            def getresponse(self):return Response()
            def close(self):pass
        h=object.__new__(p.Proxy); h.t=self.t; h.command='POST'; h.path='/codex/responses'; h.wfile=io.BytesIO();h.rehome=True
        h.send_response_only=lambda *a:None;h.send_header=lambda *a:None;h.end_headers=lambda:None;h.log=lambda **k:None
        h.ustat=lambda *a:None; calls=[]
        with patch.object(p.http.client,'HTTPConnection',Conn),patch.object(self.t,'repick',return_value='b') as repick:
            result=h.upstream('http://127.0.0.1:1','/responses',{},b'{}','direct','s','a','file',[],time.time(),'codex',True)
            self.assertIsNone(result);self.assertEqual(len(calls),1);repick.assert_not_called()
            self.assertIn(b'usage_limit_reached',h.wfile.getvalue())
            result=h.upstream('http://127.0.0.1:1','/messages',{},b'{}','direct','s','a','file',[],time.time(),'claude',True)
            self.assertEqual(result,('acct','b'));repick.assert_called_once()


if __name__=='__main__':unittest.main()
