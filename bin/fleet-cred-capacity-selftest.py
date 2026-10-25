#!/usr/bin/env python3
# selftest-entry
"""bin/fleet-cred-proxy.py capacity policy, legacy upgrade/fallback and no replay.
Shared numeric contract: tokenledger/shared/credproxy/testdata/capacity_policy.json.
"""
import copy
import importlib.util
import io
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import shutil
import subprocess
import socket
import stat
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

    def test_native_context_shared_vectors(self):
        cases=json.loads((BIN.parent/'tokenledger/shared/credproxy/testdata/codex_native_context.json').read_text())
        for case in cases:
            with self.subTest(name=case['name']):
                independent,refs,unknown=p.codex_context(case['method'],case['path'],case['headers'],json.dumps(case['body']).encode())
                self.assertEqual(independent,case['independent'])
                self.assertEqual(unknown,case['unknown'])
                self.assertEqual(refs,{p.codex_ref(ref['kind'],ref['value']) for ref in case['references']})

    def native_http_fixture(self, tool=False):
        attempts=[]
        class Upstream(BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_POST(handler):
                raw=handler.rfile.read(int(handler.headers['Content-Length']))
                attempts.append((handler.headers.get('chatgpt-account-id'),json.loads(raw)))
                n=len(attempts);suffix='' if n==1 else '_'+str(n)
                reasoning=dict(type='reasoning',id='rs_source'+suffix,summary=[],encrypted_content='fixture-opaque'+suffix)
                message=dict(type='message',id='msg_source'+suffix,role='assistant',status='completed',phase='final_answer',
                    content=[dict(type='output_text',text='LOCAL_OK' if n==1 else 'FIXTURE_NONCE',annotations=[])])
                items=[reasoning,message]
                if tool and n == 1:
                    items=[reasoning,dict(type='custom_tool_call',id='ct_source',call_id='call_source',
                        name='exec',input='text("TOOL_OK");')]
                response=dict(id='resp_source'+suffix,object='response',status='completed',output=items,
                    usage=dict(input_tokens=10,output_tokens=2,total_tokens=12))
                events=[dict(type='response.created',response=dict(id=response['id'],object='response',status='in_progress',output=[]))]
                for index,item in enumerate(items):
                    events.extend([dict(type='response.output_item.added',output_index=index,item=item),
                        dict(type='response.output_item.done',output_index=index,item=item)])
                events.append(dict(type='response.completed',response=response))
                data=''.join('event: '+e['type']+'\ndata: '+json.dumps(e)+'\n\n' for e in events).encode()
                handler.send_response(200);handler.send_header('Content-Type','text/event-stream')
                handler.send_header('Content-Length',str(len(data)));handler.end_headers();handler.wfile.write(data)
        def server(handler):
            srv=ThreadingHTTPServer(('127.0.0.1',0),handler)
            thread=threading.Thread(target=srv.serve_forever);thread.start()
            def stop():srv.shutdown();srv.server_close();thread.join(timeout=3)
            self.addCleanup(stop)
            return srv
        upstream=server(Upstream)
        self.cfg.codex_url='http://127.0.0.1:%d'%upstream.server_port
        self.cfg.anthropic_url=self.cfg.relay_url=self.cfg.central_url=''
        self.cfg.switch_ttl=120
        self.t.router.candidates=lambda *args:(['direct'],'fixture')
        for account in ('a','b'):
            path=Path(self.cfg.codex_homes,account,'auth.json');path.parent.mkdir(parents=True,exist_ok=True)
            path.write_text(json.dumps(dict(tokens=dict(access_token='fake-token-'+account,account_id='fixture-'+account))))
        for name,value in (('T',self.t),('tenants',{}),('sink',self.t),('fixed',None),('ustats',None)):
            patcher=patch.object(p.Proxy,name,value);patcher.start();self.addCleanup(patcher.stop)
        proxy=server(p.Proxy)
        return proxy,attempts

    def test_native_first_and_resume_through_http_proxy(self):
        proxy,attempts=self.native_http_fixture()
        vectors=json.loads((BIN.parent/'tokenledger/shared/credproxy/testdata/codex_native_context.json').read_text())
        first,resume=[case['body'] for case in vectors[:2]]
        token=self.t.keys.mint('', 'native',86400,capacity=True)
        self.assertEqual(self.t.keys.verify(token)[0]['capacity_policy'],2)
        def request(body,credential=token):
            conn=p.http.client.HTTPConnection('127.0.0.1',proxy.server_port,timeout=5)
            try:
                conn.request('POST','/codex/responses',json.dumps(body).encode(),{'Authorization':'Bearer '+credential,'Content-Type':'application/json'})
                answer=conn.getresponse();return answer.status,answer.read()
            finally:conn.close()
        status,raw=request(first)
        self.assertEqual(status,200,raw);self.assertIn(b'LOCAL_OK',raw)
        self.assertEqual(self.t.picks['codex','native'],'b')
        self.assertEqual(attempts[0][1],first)  # classify without stripping client IDs
        # Advance at an independent boundary, then replay real provider state:
        # continuation follows its source, even though the sticky pick is now a.
        self.install((10,.1));self.t.codex_state['sessions']['native']['changed']=time.time()-601
        self.assertEqual(self.t.codex_pick('native')['account'],'a')
        status,raw=request(resume)
        self.assertEqual(status,200,raw);self.assertIn(b'FIXTURE_NONCE',raw)
        self.assertEqual([a for a,_ in attempts],['fixture-b','fixture-b'])
        self.assertEqual(attempts[1][1],resume)
        self.assertEqual(self.t.picks['codex','native'],'a')
        status,_=request(dict(input=[dict(type='reasoning',encrypted_content='unseen-opaque')]))
        self.assertEqual(status,409);self.assertEqual(len(attempts),2)
        status,_=request(dict(input=[dict(type='message',id='msg_client_unseen',role='assistant',
            content=[dict(type='output_text',text='unrecorded')])]))
        self.assertEqual(status,409);self.assertEqual(len(attempts),2)
        fresh=self.t.keys.mint('', 'unknown-first',86400,capacity=True)
        status,_=request(dict(input=first['input'],opaque_state='unknown'),fresh)
        self.assertEqual(status,409);self.assertNotIn(('codex','unknown-first'),self.t.picks)
        self.assertEqual(len(attempts),2)
        # Same label with changed upstream identity must still fail before send.
        path=Path(self.cfg.codex_homes,'b','auth.json')
        path.write_text(json.dumps(dict(tokens=dict(access_token='fake-replaced',account_id='fixture-replaced'))))
        status,_=request(resume)
        self.assertEqual(status,409);self.assertEqual(len(attempts),2)

    @unittest.skipUnless(os.environ.get('FLEET_CODEX_NATIVE_FIXTURE'),'explicit local native CLI fixture only')
    def test_native_cli_loopback(self):
        proxy,attempts=self.native_http_fixture()
        root=Path(self.tmp.name);home=root/'native-home';work=root/'native-work';home.mkdir();work.mkdir()
        token=self.t.keys.mint('', 'native-cli',86400,capacity=True)
        env=dict(PATH=os.environ['PATH'],HOME=str(home),CODEX_HOME=str(home),TMPDIR='/tmp',FLEET_FIXTURE_TOKEN=token)
        base=[os.environ['FLEET_CODEX_NATIVE_FIXTURE'],'exec','--skip-git-repo-check','--ignore-user-config',
            '-m','gpt-6.1-sol','-s','read-only','-C',str(work),'--json']
        for config in ('model_provider="fixture"','model_providers.fixture.name="Local fixture"',
                'model_providers.fixture.base_url="http://127.0.0.1:%d/codex"'%proxy.server_port,
                'model_providers.fixture.env_key="FLEET_FIXTURE_TOKEN"','model_providers.fixture.wire_api="responses"',
                'model_providers.fixture.requires_openai_auth=false','model_reasoning_effort="low"'):
            base+=['-c',config]
        sid=''
        for prompt,expected in (('Remember FIXTURE_NONCE. Reply LOCAL_OK. Do not use tools.','LOCAL_OK'),
                ('What nonce? Reply only it. Do not use tools.','FIXTURE_NONCE')):
            command=base+(['resume',sid] if sid else [])+[prompt]
            try:
                answer=subprocess.run(command,env=env,cwd=str(work),stdin=subprocess.DEVNULL,text=True,capture_output=True,timeout=40)
            except subprocess.TimeoutExpired as e:
                self.fail(str((e.stdout,e.stderr)))
            self.assertEqual(answer.returncode,0,(answer.stdout,answer.stderr))
            messages=[]
            for line in answer.stdout.splitlines():
                event=json.loads(line)
                if event.get('type')=='thread.started':sid=event['thread_id']
                if event.get('item',{}).get('type')=='agent_message':messages.append(event['item']['text'])
            self.assertEqual(''.join(messages),expected);self.assertTrue(sid)
        self.assertEqual(len(attempts),2)
        self.assertEqual([account for account,_ in attempts],['fixture-b','fixture-b'])
        self.assertEqual(self.t.picks['codex','native-cli'],'b')
        self.assertNotIn('fixture-opaque',Path(self.tmp.name,'codex-routing.json').read_text())

    @unittest.skipUnless(os.environ.get('FLEET_CODEX_NATIVE_FIXTURE'),'explicit local native CLI fixture only')
    def test_native_cli_tool_loopback(self):
        proxy,attempts=self.native_http_fixture(tool=True)
        wire=[]
        original=self.t.codex_request
        def capture(sid,enrolled,method,path,headers,body,pin=""):
            wire.append(json.loads(body))
            if os.environ.get('FLEET_CODEX_NATIVE_WIRE'):
                Path(os.environ['FLEET_CODEX_NATIVE_WIRE']).write_text(json.dumps(wire,indent=2))
            return original(sid,enrolled,method,path,headers,body,pin)
        self.t.codex_request=capture
        root=Path(self.tmp.name);home=root/'native-home';work=root/'native-work';home.mkdir();work.mkdir()
        token=self.t.keys.mint('', 'native-cli',86400,capacity=True)
        env=dict(PATH=os.environ['PATH'],HOME=str(home),CODEX_HOME=str(home),TMPDIR='/tmp',FLEET_FIXTURE_TOKEN=token,NO_PROXY='*',no_proxy='*')
        base=[os.environ['FLEET_CODEX_NATIVE_FIXTURE'],'exec','--skip-git-repo-check','--ignore-user-config',
            '-m','gpt-6.1-sol','-s','danger-full-access','-C',str(work),'--json']
        for config in ('model_provider="fixture"','model_providers.fixture.name="Local fixture"',
                'model_providers.fixture.base_url="http://127.0.0.1:%d/codex"'%proxy.server_port,
                'model_providers.fixture.env_key="FLEET_FIXTURE_TOKEN"','model_providers.fixture.wire_api="responses"',
                'model_providers.fixture.requires_openai_auth=false','model_reasoning_effort="high"',
                'features.daemon_auto_start=false','approval_policy="never"','features.hooks=true','features.plugins=false','features.apps=false',
                'analytics.enabled=false','check_for_update_on_startup=false',
                'model_providers.fixture.request_max_retries=0','model_providers.fixture.stream_max_retries=0'):
            base+=['-c',config]
        sid=''
        for prompt,expected in (('Use exec to print TOOL_OK, then reply FIXTURE_NONCE.','FIXTURE_NONCE'),
                ('What nonce? Reply only it. Do not use tools.','FIXTURE_NONCE')):
            command=base+(['resume',sid] if sid else [])+[prompt]
            try:
                answer=subprocess.run(command,env=env,cwd=str(work),stdin=subprocess.DEVNULL,text=True,capture_output=True,timeout=40)
            except subprocess.TimeoutExpired as e:
                self.fail(str((e.stdout,e.stderr)))
            self.assertEqual(answer.returncode,0,(answer.stdout,answer.stderr))
            messages=[]
            for line in answer.stdout.splitlines():
                event=json.loads(line)
                if event.get('type')=='thread.started':sid=event['thread_id']
                if event.get('item',{}).get('type')=='agent_message':messages.append(event['item']['text'])
            self.assertEqual(''.join(messages),expected);self.assertTrue(sid)
        self.assertEqual(len(attempts),3)
        self.assertEqual([account for account,_ in attempts],['fixture-b']*3)
        self.assertEqual(self.t.picks['codex','native-cli'],'b')
        self.assertNotIn('fixture-opaque',Path(self.tmp.name,'codex-routing.json').read_text())

        result=next(item for item in wire[1]['input'] if item.get('type')=='custom_tool_call_output')
        self.assertEqual(result['call_id'],'call_source')
        self.assertNotEqual(result['id'],'ct_source')
        self.assertIn('TOOL_OK',json.dumps(result['output']))
        self.assertEqual([body for _,body in attempts],wire)

    def test_native_tool_result_http(self):
        proxy,attempts=self.native_http_fixture(tool=True)
        token=self.t.keys.mint('', 'native-tool-http',86400,capacity=True)
        def request(body):
            conn=p.http.client.HTTPConnection('127.0.0.1',proxy.server_port,timeout=5)
            try:
                conn.request('POST','/codex/responses',json.dumps(body).encode(),
                    {'Authorization':'Bearer '+token,'Content-Type':'application/json'})
                answer=conn.getresponse();return answer.status,answer.read()
            finally:conn.close()
        self.assertEqual(request(dict(input='Run the fixture tool'))[0],200)
        self.install((10,.1));self.t.codex_state['sessions']['native-tool-http']['changed']=time.time()-601
        self.assertEqual(self.t.codex_pick('native-tool-http')['account'],'a')
        result=dict(type='custom_tool_call_output',id='client-result',call_id='call_source',output='TOOL_OK')
        body=dict(input=[result])
        self.assertEqual(request(body)[0],200)
        self.assertEqual(request(dict(input=[result,dict(role='user',content='Resume')]))[0],200)
        self.assertEqual([account for account,_ in attempts],['fixture-b']*3)
        self.assertEqual(attempts[1][1],body)
        self.assertEqual(request(dict(input=[dict(result,call_id='unseen')]))[0],409)
        self.assertEqual(len(attempts),3)

    def test_native_tool_result_affinity(self):
        self.install((1,.5)); self.t.codex_pick('s')
        self.t.codex_record('s','a',p.codex_output_refs(dict(output=[dict(
            type='custom_tool_call',id='ct_source',call_id='call_source')])),p.codex_ref('account','fixture-a'))
        self.install((.5,3)); self.t.codex_state['sessions']['s']['changed']=time.time()-601
        self.assertEqual(self.t.codex_pick('s')['account'],'b')
        body=dict(input=[dict(type='custom_tool_call_output',id='client-result',call_id='call_source',output='TOOL_OK')])
        route=p.codex_context('POST','/codex/responses',{},json.dumps(body).encode())
        self.assertEqual(self.t.codex_pick('s',*route)['account'],'a')
        for change in (dict(call_id='unseen'),dict(call_id=''),dict(call_id=None),
                       dict(encrypted_content='opaque'),dict(output=[dict(type='input_file',file_id='file')])):
            altered=copy.deepcopy(body);altered['input'][0].update(change)
            route=p.codex_context('POST','/codex/responses',{},json.dumps(altered).encode())
            with self.assertRaises(ValueError):self.t.codex_pick('s',*route)
        with self.assertRaises(ValueError):self.t.codex_pick('s',*p.codex_context(
            'POST','/codex/responses',{},json.dumps(body).encode()),pin='b')
        # A collision between two provider identities remains unresolved.
        self.t.codex_record('s','b',[p.codex_ref('id','call_source')],p.codex_ref('account','fixture-b'))
        with self.assertRaises(ValueError):self.t.codex_pick('s',*p.codex_context(
            'POST','/codex/responses',{},json.dumps(body).encode()))

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

    def test_reopened_worker_http_continuation(self):
        proxy,attempts=self.native_http_fixture()
        vectors=json.loads((BIN.parent/'tokenledger/shared/credproxy/testdata/codex_native_context.json').read_text())
        first,resume=[case['body'] for case in vectors[:2]]
        worker='11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222'
        def mint(sid):
            result=p.ctl_handle(dict(op='mint',provider='codex',sid=sid,worker=worker),self.t)
            self.assertTrue(result['ok'])
            return result['token']
        def request(token,body):
            conn=p.http.client.HTTPConnection('127.0.0.1',proxy.server_port,timeout=5)
            try:
                conn.request('POST','/codex/responses',json.dumps(body).encode(),
                    {'Authorization':'Bearer '+token,'Content-Type':'application/json'})
                answer=conn.getresponse();return answer.status,answer.read()
            finally:conn.close()
        original=mint('original')
        self.assertEqual(request(original,first)[0],200)
        # Simulate an older daemon's record: ownership only in workers.json.
        self.t.codex_state['sessions']['original'].pop('worker',None)
        reopened=mint('reopened')
        self.install((10,.1))  # independent requests now prefer another source
        before=copy.deepcopy(self.t.codex_state)
        independent,refs,unknown=p.codex_context('POST','/codex/responses',{},json.dumps(resume).encode())
        self.assertEqual(self.t.codex_pick('reopened',independent,refs,unknown,preview=True)['account'],'b')
        self.assertEqual(self.t.codex_state,before)
        status,raw=request(reopened,resume)
        self.assertEqual(status,200,raw)
        self.assertEqual([a for a,_ in attempts],['fixture-b','fixture-b'])
        self.assertEqual(attempts[-1][1],resume)
        self.assertTrue(refs.issubset(self.t.codex_state['sessions']['reopened']['refs']))
        # Revoke removes the old bearer and workers.json row, not provenance.
        self.assertTrue(p.ctl_handle(dict(op='revoke',sid='original'),self.t)['ok'])
        self.assertNotIn('original',p.read_json(Path(self.tmp.name,'workers.json'),{}))
        restored=p.Tenant(self.cfg);restored.held=self.t.held
        restored.capacity_cache=self.t.capacity_cache;restored.capacity_until=time.time()+30
        self.assertEqual(restored.codex_pick('reopened',False,refs)['account'],'b')
        self.assertEqual(request(reopened,resume)[0],200)
        self.assertEqual(request(original,resume)[0],401)
        del self.t.codex_state['sessions']['original']
        self.assertEqual(request(mint('third'),resume)[0],200)
        # Exact origin checks still run at the HTTP boundary after recovery.
        source=Path(self.cfg.codex_homes,'b','auth.json')
        source.write_text(json.dumps(dict(tokens=dict(access_token='fake-replaced',account_id='fixture-replaced'))))
        self.assertEqual(request(reopened,resume)[0],409)
        self.assertEqual(len(attempts),4)

    def test_reopened_worker_rejects_unproven_history(self):
        worker='11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222'
        p.write_json(Path(self.tmp.name,'workers.json'),dict(old=worker,new=worker,conflict=worker))
        ref=p.codex_ref('id','recorded');missing=p.codex_ref('id','unseen')
        src=p.codex_ref('account','original-source')
        self.t.codex_record('old','a',[ref],src)
        for sid,refs in [('new',[ref,missing]),('other',[ref])]:
            with self.assertRaises(ValueError):self.t.codex_pick(sid,False,refs)
        with self.assertRaises(ValueError):self.t.codex_pick('new',False,[],True)
        # An old session's eviction fallback is never inherited by a new SID.
        self.t.codex_state['sessions']['old']['evicted_origin']='a\0'+src
        with self.assertRaises(ValueError):self.t.codex_pick('new',False,[missing])
        with self.assertRaises(ValueError):self.t.codex_pick('new',False,[ref],pin='b')
        self.t.codex_limits['a']=time.time()+60
        with self.assertRaises(ValueError):self.t.codex_pick('new',False,[ref])
        self.t.codex_limits.clear()
        self.t.held=lambda provider:['b']
        with self.assertRaises(ValueError):self.t.codex_pick('new',False,[ref])
        self.t.held=lambda provider:['a','b']
        self.t.codex_record('conflict','b',[ref],p.codex_ref('account','different-source'))
        with self.assertRaises(ValueError):self.t.codex_pick('new',False,[ref])
        self.t.codex_state['sessions']['conflict']['refs'][ref]=None
        with self.assertRaises(ValueError):self.t.codex_pick('new',False,[ref])
        del self.t.codex_state['sessions']['conflict']
        self.t.codex_state['sessions']['new']=dict(refs={ref:None})
        with self.assertRaises(ValueError):self.t.codex_pick('new',False,[ref])

    def test_long_session_past_ref_cap_stays_on_its_only_subscription(self):
        # A Codex session resends its whole history each turn; past 4096 recorded
        # references the table used to be wiped, and the next turn's old refs read
        # unknown: 409 「continuation source unknown」 on a session that never left
        # its one subscription (D3YD, T984). Evicted refs keep their one origin.
        self.install((1,.5)); self.assertEqual(self.t.codex_pick('long')['account'],'a')
        src=p.codex_ref('account','source-a')
        refs=[p.codex_ref('id','item-%d'%i) for i in range(5000)]
        for i in range(0,5000,250):
            self.t.codex_record('long','a',refs[i:i+250],src)
        v=self.t.codex_state['sessions']['long']
        self.assertLessEqual(len(v['refs']),4096); self.assertEqual(v['sole'],'a')
        for sent in (refs[:3]+refs[-3:], refs[:3]):
            got=self.t.codex_pick('long',False,sent)
            self.assertEqual((got['account'],got['expected_source']),('a',src))
        self.assertEqual(self.t.codex_pick('long',False,refs[:3]+[p.codex_ref('id','never-seen')])['account'],'a')
        # A session that ever switched has no single origin to vouch for: refuse.
        self.t.codex_pick('moved'); self.t.codex_state['sessions']['moved'].update(sole='')
        for i in range(0,5000,250):
            self.t.codex_record('moved','a',refs[i:i+250],src)
        with self.assertRaises(ValueError):self.t.codex_pick('moved',False,refs[:3])
        # Evicted refs of two sources: no single origin either.
        self.t.codex_pick('mixed')
        for i in range(0,5000,250):
            self.t.codex_record('mixed','a',refs[i:i+250],src if i<2500 else p.codex_ref('account','source-b'))
        with self.assertRaises(ValueError):self.t.codex_pick('mixed',False,refs[:3])
        # Below the cap an unseen ref is still refused, as before.
        self.t.codex_pick('short'); self.t.codex_record('short','a',refs[:10],src)
        with self.assertRaises(ValueError):self.t.codex_pick('short',False,[p.codex_ref('id','never-seen')])
        raw=Path(self.tmp.name,'codex-routing.json').read_text()
        self.assertNotIn('item-1',raw)

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
        with patch.object(p,'ctl_call',return_value=dict(picks={})):
            p.snapshot_legacy_picks(self.tmp.name,None,self.tmp.name)
        self.assertEqual(json.loads(Path(self.tmp.name,'codex-legacy-picks.json').read_text()),{})

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

class SharedSnapshot(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name); self.run=self.root/'run'/'.shared'; self.run.mkdir(parents=True)
        self.db=self.root/'db'; self.db.mkdir()
        self.role_uid=os.getuid() or 65534; self.role_gid=os.getgid()
        self.uid=0  # model the launcher's root -> service-role boundary, not peer_uid request seams
        self.requests=[]; self.reject=''; self.original_handle=p.ctl_handle
        spec=importlib.util.spec_from_file_location('launcher',BIN/'fleet-credsep-launch.py')
        self.launcher=importlib.util.module_from_spec(spec); spec.loader.exec_module(self.launcher)
        self.patch(self.launcher,'TEST',False)
        self.role=SimpleNamespace(pw_uid=self.role_uid,pw_gid=self.role_gid,pw_dir=self.tmp.name)
        (self.db/'.shared.json').write_text(json.dumps(dict(user='fixture-role',port=18923)))
        tenants={}
        for i,name in enumerate(('alpha','beta','newtenant')):
            state=self.db/name/'cred-proxy'; state.mkdir(parents=True)
            conf=self.root/('conf-'+name); conf.mkdir()
            (state.parent/'meta.json').write_text(json.dumps(dict(login=name,mode='shared',conf_dir=str(conf))))
            (state/'codex-legacy-picks.json').write_text('{"stale":"stale-account"}')
            if name!='newtenant':
                tenants[name]=SimpleNamespace(name=name,cfg=SimpleNamespace(uid=self.role_uid+100+i,state=str(state)),
                    picks={('codex','old-native'):'source-a',('claude','claude-session'):'ignored'} if name=='alpha' else {})
        manifest=self.db/'.shared'; manifest.mkdir()
        (manifest/'tenants.json').write_text(json.dumps(dict(tenants=[dict(login=n) for n in tenants])))
        self.patch(p.Proxy,'tenants',tenants)
        self.patch(p.Proxy,'log_any',lambda **kw:None)
        self.patch(p,'peer_uid',lambda conn:self.uid)
        self.patch(p,'ctl_handle',self.handle)
        self.env=dict(FLEET_CREDSEP_ROOT_BASE=str(self.db),FLEET_CREDSEP_RUN_BASE=str(self.root/'run'),
            FLEET_CREDSEP_LOG_BASE=str(self.root/'log'),FLEET_CRED_HANDOFF='1',FLEET_CRED_SHARED_TEST='0',FLEET_CREDSEP_TEST='0')
        env=patch.dict(os.environ,self.env); env.start(); self.addCleanup(env.stop)
        for key in ('FLEET_CRED_TEST_PEER_UID','FLEET_CRED_AS','FLEET_CRED_CTL_DIR'):
            os.environ.pop(key,None)
        self.server=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
        self.server.bind(str(self.run/'ctl.sock')); self.server.listen(8); self.server.settimeout(.1)
        self.done=threading.Event()
        def serve():
            while not self.done.is_set():
                try:conn,_=self.server.accept()
                except socket.timeout:continue
                except OSError:break
                p.ctl_conn(conn,None)
        self.thread=threading.Thread(target=serve); self.thread.start()
        self.addCleanup(self.stop_server)

    def patch(self,obj,name,value):
        patcher=patch.object(obj,name,value); result=patcher.start(); self.addCleanup(patcher.stop)
        return result

    def stop_server(self):
        self.done.set(); self.server.close(); self.thread.join(timeout=3)

    def handle(self,req,tenant):
        self.requests.append((self.uid,dict(req)))
        if tenant.name==self.reject:raise ValueError('fixture snapshot refused')
        return self.original_handle(req,tenant)

    def saved(self,name):
        return self.db/name/'cred-proxy'/'codex-legacy-picks.json'

    def test_control_auth_distinguishes_service_root_tenant_without_seam(self):
        for uid,who,allowed in ((0,'alpha',True),(self.role_uid,'alpha',False),
                (self.role_uid+100,'alpha',True),(self.role_uid+100,'beta',False),(0,'arbitrary-as',False)):
            self.uid=uid
            tenant,why=p.ctl_tenant(None,dict(op='picks',**{'as':who,'peer_uid':0}))
            self.assertEqual(tenant is not None,allowed,(uid,who,why))

    def run_launcher(self,drop):
        l=self.launcher
        with patch.object(l.os,'geteuid',side_effect=lambda:self.uid), patch.object(l.pwd,'getpwnam',return_value=self.role), \
                patch.object(l,'getpw',side_effect=lambda name:SimpleNamespace(pw_uid=self.role_uid+100+('alpha','beta','newtenant').index(name))), \
                patch.object(l,'copy_probe'), patch.object(l,'tenant_settings',return_value={}), \
                patch.object(l,'drop_to',side_effect=drop) as dropped, patch.object(l.os,'umask'), \
                patch.object(l.os,'chdir'), patch.object(l.os,'execve',side_effect=RuntimeError('fixture-exec')) as executed:
            try:l.shared()
            except RuntimeError as e:
                if str(e)!='fixture-exec':raise
            return dropped,executed

    def test_service_role_cannot_snapshot_without_test_seams(self):
        self.uid=self.role_uid
        with patch.object(self.launcher.os,'geteuid',return_value=self.role_uid):
            with self.assertRaises(SystemExit):
                self.launcher.snapshot_shared_picks(str(self.run),
                    [dict(login='alpha',state=str(self.saved('alpha').parent))],self.role)
        self.assertEqual(self.requests,[])
        self.assertEqual(json.loads(self.saved('alpha').read_text()),{'stale':'stale-account'})

    def test_shared_snapshot_before_drop_actual_mode_owner_and_empty(self):
        def drop(role):
            self.assertEqual(role,'fixture-role'); self.assertEqual(self.uid,0)
            for name,expected in (('alpha',{'old-native':'source-a'}),('beta',{})):
                saved=self.saved(name); info=saved.stat()
                self.assertEqual(json.loads(saved.read_text()),expected)
                self.assertEqual(stat.S_IMODE(info.st_mode),0o600)
                self.assertEqual((info.st_uid,info.st_gid),(self.role_uid,self.role_gid))
            # A newly joining tenant was not present at the old daemon: no arbitrary-as request.
            self.assertEqual(json.loads(self.saved('newtenant').read_text()),{'stale':'stale-account'})
            self.uid=self.role_uid
        dropped,executed=self.run_launcher(drop)
        dropped.assert_called_once(); executed.assert_called_once()
        self.assertEqual([r['as'] for _,r in self.requests],['alpha','beta'])
        self.assertTrue(all(uid==0 and 'peer_uid' not in req for uid,req in self.requests))
        with self.assertRaises(SystemExit):p.ctl_call(str(self.run),{'op':'picks','as':'alpha'})

    def test_active_snapshot_failure_aborts_before_drop_keeps_listener_and_state(self):
        self.reject='beta'; inode=(self.run/'ctl.sock').stat().st_ino
        old_manifest=(self.db/'.shared'/'tenants.json').read_bytes()
        drop=self.patch(self.launcher,'drop_to',unittest.mock.Mock())
        with self.assertRaises(SystemExit):self.run_launcher(drop)
        drop.assert_not_called()
        for name in ('alpha','beta'):
            self.assertEqual(json.loads(self.saved(name).read_text()),{'stale':'stale-account'})
        self.assertEqual((self.db/'.shared'/'tenants.json').read_bytes(),old_manifest)
        self.assertEqual((self.run/'ctl.sock').stat().st_ino,inode)
        self.reject=''
        self.assertEqual(p.ctl_call(str(self.run),{'op':'picks','as':'alpha'})['picks']['codex:old-native'],'source-a')

    def refresh_fixture(self,supervised=False):
        spec=importlib.util.spec_from_file_location('credsep',BIN/'fleet-credsep.py')
        refresh=importlib.util.module_from_spec(spec); spec.loader.exec_module(refresh)
        lib=self.root/'lib';lib.mkdir()
        self.patch(refresh,'LIB',str(lib))
        self.patch(refresh,'shared_supervised',lambda:supervised)
        self.patch(refresh,'settings_conf',lambda *a:False)
        self.patch(refresh,'shared_service',lambda:False)
        self.patch(refresh,'shared_record',lambda *a:None)
        self.patch(refresh,'relog_agent',lambda *a:None)
        self.patch(refresh,'shared_unserved',lambda *a:([],[]))
        self.patch(refresh,'unserved_tried',lambda *a:[])
        self.patch(refresh,'say',lambda *a:None)
        self.patch(refresh.os,'geteuid',lambda:self.uid)
        self.patch(refresh.pwd,'getpwnam',lambda name:self.role)
        def copy_changed(path,content,*args):
            Path(path).write_bytes(content);return True
        self.patch(refresh,'put_changed',copy_changed)
        return refresh,lib

    def assert_snapshots(self):
        for name,expected in (('alpha',{'old-native':'source-a'}),('beta',{})):
            info=self.saved(name).stat()
            self.assertEqual(json.loads(self.saved(name).read_text()),expected)
            self.assertEqual(stat.S_IMODE(info.st_mode),0o600)
            self.assertEqual((info.st_uid,info.st_gid),(self.role_uid,self.role_gid))

    def test_legacy_machine_refresh_snapshots_before_service_stop(self):
        refresh,lib=self.refresh_fixture()
        inode=(self.run/'ctl.sock').stat().st_ino
        def stop(*args):
            self.assertEqual(self.uid,0);self.assert_snapshots()
            self.assertEqual((self.run/'ctl.sock').stat().st_ino,inode)
            self.assertEqual([r['as'] for _,r in self.requests],['alpha','beta'])
            self.assertTrue(all(uid==0 and 'peer_uid' not in req for uid,req in self.requests))
        stopped=self.patch(refresh,'load_daemon',unittest.mock.Mock(side_effect=stop))
        self.assertEqual(refresh.machine_refresh(None),0)
        stopped.assert_called_once_with(refresh.SHARED_PATH,refresh.SHARED_LABEL)
        self.assertEqual(sorted(f.name for f in lib.iterdir() if f.is_file()),
            ['fleet-cred-proxy.py','fleet-credsep-launch.py'])

    def test_legacy_machine_refresh_refusal_never_stops_old_listener(self):
        refresh,lib=self.refresh_fixture();self.reject='beta'
        stopped=self.patch(refresh,'load_daemon',unittest.mock.Mock())
        with self.assertRaises(SystemExit):refresh.machine_refresh(None)
        stopped.assert_not_called()
        for name in ('alpha','beta'):
            self.assertEqual(json.loads(self.saved(name).read_text()),{'stale':'stale-account'})
        self.reject=''
        self.assertEqual(p.ctl_call(str(self.run),{'op':'picks','as':'alpha'})['picks']['codex:old-native'],'source-a')

    def test_legacy_restart_snapshots_with_missing_or_old_protected_launcher(self):
        refresh,lib=self.refresh_fixture()
        old=lib/'fleet-credsep-launch.py'
        for kind in ('missing','old'):
            with self.subTest(kind=kind):
                if kind=='old':old.write_text('raise RuntimeError("old protected launcher must not be imported")\n')
                original=old.read_bytes() if old.exists() else None
                self.requests.clear()
                for name in ('alpha','beta'):self.saved(name).write_text('{"stale":"stale-account"}')
                def stop(*args):
                    self.assert_snapshots()
                    self.assertEqual([r['as'] for _,r in self.requests],['alpha','beta'])
                with patch.object(refresh,'load_daemon',side_effect=stop) as stopped:
                    refresh.shared_restart()
                stopped.assert_called_once()
                self.assertEqual(old.read_bytes() if old.exists() else None,original)

    def test_old_protected_launcher_does_not_bypass_live_snapshot_refusal(self):
        refresh,lib=self.refresh_fixture()
        (lib/'fleet-credsep-launch.py').write_text('# old launcher without snapshot helper\n')
        self.reject='beta'
        stopped=self.patch(refresh,'load_daemon',unittest.mock.Mock())
        with self.assertRaises(SystemExit):refresh.shared_restart()
        stopped.assert_not_called()
        for name in ('alpha','beta'):
            self.assertEqual(json.loads(self.saved(name).read_text()),{'stale':'stale-account'})
        self.reject=''
        self.assertEqual(p.ctl_call(str(self.run),{'op':'picks','as':'alpha'})['picks']['codex:old-native'],'source-a')

    def test_missing_protected_launcher_cold_start_retains_saved_picks(self):
        refresh,lib=self.refresh_fixture()
        self.stop_server();(self.run/'ctl.sock').unlink()
        stopped=self.patch(refresh,'load_daemon',unittest.mock.Mock())
        refresh.shared_restart()
        stopped.assert_called_once()
        self.assertEqual(json.loads(self.saved('alpha').read_text()),{'stale':'stale-account'})

    def test_dry_restart_never_snapshots_or_stops_old_listener(self):
        refresh,lib=self.refresh_fixture()
        self.patch(refresh,'DRY',True)
        stopped=self.patch(refresh,'load_daemon',unittest.mock.Mock())
        refresh.shared_restart()
        stopped.assert_not_called();self.assertEqual(self.requests,[])
        self.assertEqual(json.loads(self.saved('alpha').read_text()),{'stale':'stale-account'})

    def test_supervised_restart_snapshots_before_stamp_with_old_protected_launcher(self):
        refresh,lib=self.refresh_fixture(supervised=True)
        (lib/'fleet-credsep-launch.py').write_text('# old launcher without snapshot helper\n')
        def stamp(*args):
            self.assert_snapshots()
            self.assertEqual([r['as'] for _,r in self.requests],['alpha','beta'])
        stamped=self.patch(refresh,'put',unittest.mock.Mock(side_effect=stamp))
        stopped=self.patch(refresh,'load_daemon',unittest.mock.Mock())
        refresh.shared_restart()
        stamped.assert_called_once();stopped.assert_not_called()

    def test_supervised_snapshot_refusal_never_stamps_restart(self):
        refresh,lib=self.refresh_fixture(supervised=True);self.reject='beta'
        stamped=self.patch(refresh,'put',unittest.mock.Mock())
        stopped=self.patch(refresh,'load_daemon',unittest.mock.Mock())
        with self.assertRaises(SystemExit):refresh.shared_restart()
        stamped.assert_not_called();stopped.assert_not_called()
        self.reject=''
        self.assertEqual(p.ctl_call(str(self.run),{'op':'picks','as':'alpha'})['picks']['codex:old-native'],'source-a')

    def test_cold_start_no_listener_retains_persisted_state(self):
        self.stop_server(); (self.run/'ctl.sock').unlink()
        self.launcher.snapshot_shared_picks(str(self.run),[dict(login='alpha',state=str(self.saved('alpha').parent))],self.role)
        self.assertEqual(json.loads(self.saved('alpha').read_text()),{'stale':'stale-account'})



if __name__=='__main__':unittest.main()
