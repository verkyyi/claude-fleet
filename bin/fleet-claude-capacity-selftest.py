#!/usr/bin/env python3
# selftest-entry
"""Isolated Claude policy, identity and actual native first/tool/resume wire."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
from types import SimpleNamespace
from unittest.mock import patch

BIN=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('proxy',BIN/'fleet-cred-proxy.py')
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)
c=p.claude_capacity

def iso(t):return datetime.fromtimestamp(t,timezone.utc).isoformat()
def evidence(account,units,now):
    return dict(account=account,owner='pool',credential_id='cred:'+account,lease_key=p.pool_key('claude',json.dumps(dict(claudeAiOauth=dict(accessToken='fake-'+account))).encode()),
        plan='max',tier='max'+str(units),metadata_status='valid',complete=True,refresh_healthy=True,
        profile=dict(plan='max',tier='max'+str(units),pool='claude',unit='pro-session',basis='official-5h',source='official',confidence='verified',version='v1',five_hour_units=units,effective_from=iso(now-3600)),
        windows=[dict(id=name,minutes=minutes,used_percent=0,observed_at=iso(now),reset_at=iso(now+remaining))
            for name,minutes,remaining in [('five_hour',300,3600),('seven_day',10080,86400)]])

class ClaudeCapacity(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.cfg=SimpleNamespace(state=self.tmp.name,pool=self.tmp.name+'/pool',store=True,log='',name='fixture',accounts=self.tmp.name+'/accounts',
            codex_auth=self.tmp.name+'/auth.json',codex_homes=self.tmp.name+'/homes',node_env=self.tmp.name+'/node.env',pick_ceiling=85,timeout=5,quota_push='',quota_push_secs=1,ttl=86400,switch_ttl=120)
        self.t=p.Tenant(self.cfg);self.t.held=lambda provider:['a','b'];p.Proxy.tenants,p.Proxy.reads,p.Proxy.limited={},{},{}
        self.now=time.time();self.install()
        for a in ('a','b'):p.pool_put(self.cfg,'claude',a,json.dumps(dict(claudeAiOauth=dict(accessToken='fake-'+a))).encode())

    def install(self,mode='active',units=(5,20)):
        self.t.claude_cache=dict(policy='claude-capacity-v1',mode=mode,catalog_revision=9,accounts=[evidence(a,u,self.now) for a,u in zip(('a','b'),units)])
        self.t.claude_until=time.time()+30
        self.t.claude_state['mode']=mode

    def route(self,body=None):return c.route('POST','/v1/messages',{},json.dumps(body or dict(model='claude-sonnet-4-6',messages=[dict(role='user',content='hello')])).encode())

    def test_cache_and_single_login_identity(self):
        data=dict(self.t.claude_cache,expires_at=iso(time.time()+25))
        with patch.object(p,'node_env',return_value={'CCQUOTA_HUB_URL':'https://fixture.invalid','CCQUOTA_TOKEN':'fake'}), patch.object(p.urllib.request,'urlopen',return_value=__import__('io').BytesIO(json.dumps(data).encode())):
            self.t.claude_cache={};self.assertEqual(self.t.refresh_claude_metadata()['mode'],'active')
        self.assertLessEqual(self.t.claude_until-time.time(),30)
        self.cfg.pool='';p.write_json(os.path.join(self.cfg.state,'pool.json'),{})
        for a in ('a','b'):
            path=Path(p.own_path(self.cfg,'claude',a));path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(dict(claudeAiOauth=dict(accessToken='fake-'+a))))
        before=Path(self.cfg.state,'claude-routing.json').read_bytes()
        self.assertEqual(self.t.claude_pick('s',self.route(),preview=True)['proposed']['account'],'b')
        self.assertEqual(before,Path(self.cfg.state,'claude-routing.json').read_bytes())
        choice=self.t.claude_pick('s',self.route());self.t.claude_record('s',choice,[c.reference('tool','tool_source')])
        Path(p.own_path(self.cfg,'claude','b')).write_text(json.dumps(dict(claudeAiOauth=dict(accessToken='replaced'))))
        with self.assertRaises(ValueError):self.t.claude_pick('s',dict(self.route(),independent=False,references=[c.reference('tool','tool_source')]))
        self.t.claude_until=0
        with self.assertRaises(p.ClaudeCapacityError):self.t.claude_pick('s',self.route())

    def test_shared_vectors(self):
        for v in json.loads((BIN.parent/'tokenledger/shared/credproxy/testdata/claude_capacity.json').read_text()):
            with self.subTest(name=v['name']):
                q=c.evaluate(v['evidence'],v['model'],c.epoch(v['now']))
                self.assertEqual(q['state'],v['state'])
                if 'reason' in v:self.assertEqual(q['reason'],v['reason'])
                if 'score' in v:self.assertAlmostEqual(q['score'],v['score'])
                self.assertEqual(q['weekly_capacity'],'unknown');self.assertNotIn('estimated_weekly_units',q)
        bodies=json.loads((BIN.parent/'tokenledger/shared/credproxy/testdata/claude_native_context.json').read_text())
        for i,body in enumerate(bodies):
            route=self.route(body);self.assertFalse(route['unknown']);self.assertEqual(route['independent'],i==0)
            if i:self.assertEqual(set(route['references']),{c.reference('tool','tool_source'),c.reference('signature','fixture-signature')})

    def test_hard_limits_before_metadata(self):
        for row in self.t.claude_cache['accounts']:
            row['metadata_status']='observed_metadata_stale_or_missing';row['windows'][1]['used_percent']=100
        with self.assertRaises(p.ClaudeCapacityError):self.t.claude_pick('s',self.route())
        self.assertFalse(self.t.picks)
        preview=self.t.claude_pick('s',self.route(),preview=True)
        self.assertTrue(all(q['state']=='limited' for q in preview['inputs']))
        self.assertIsNone(preview['proposed'])

    def test_scope_freshness_identity_and_hold(self):
        first=self.t.claude_pick('s',self.route());self.assertEqual(first['account'],'b')
        self.install(units=(20,5));self.assertEqual(self.t.claude_pick('s',self.route())['account'],'b')
        self.t.claude_state['sessions']['s']['changed']-=601
        self.assertEqual(self.t.claude_pick('s',self.route())['account'],'a')
        row=self.t.claude_cache['accounts'][0];w=dict(row['windows'][1],id='seven_day_sonnet',model='family:sonnet',used_percent=100);row['windows'].append(w)
        self.assertEqual(self.t.claude_pick('s',self.route())['account'],'b')
        self.t.claude_until=0
        with self.assertRaises(p.ClaudeCapacityError):self.t.claude_pick('s',self.route())

    def test_affinity_unknown_collision_and_restart(self):
        first=self.t.claude_pick('s',self.route());ref=c.reference('tool','tool_source');self.t.claude_record('s',first,[ref])
        self.install(units=(20,5));self.t.claude_state['sessions']['s']['changed']-=601
        self.assertEqual(self.t.claude_pick('s',self.route())['account'],'a')
        body=dict(model='claude-sonnet-4-6',messages=[dict(role='user',content=[dict(type='tool_result',tool_use_id='tool_source',content='OK')])])
        self.assertEqual(self.t.claude_pick('s',self.route(body))['account'],'b')
        saved=Path(self.tmp.name,'claude-routing.json').read_bytes()
        self.t.claude_pick('s',self.route(),preview=True);self.assertEqual(saved,Path(self.tmp.name,'claude-routing.json').read_bytes())
        restored=p.Tenant(self.cfg);self.assertEqual(restored.claude_state,self.t.claude_state)
        body['messages'][0]['content'][0]['tool_use_id']='missing'
        with self.assertRaises(ValueError):self.t.claude_pick('s',self.route(body))
        self.t.claude_record('s',dict(identity='cred:a'),[ref]);body['messages'][0]['content'][0]['tool_use_id']='tool_source'
        with self.assertRaises(ValueError):self.t.claude_pick('s',self.route(body))

    def server(self,handler):
        srv=ThreadingHTTPServer(('127.0.0.1',0),handler);thread=threading.Thread(target=srv.serve_forever);thread.start()
        def close():srv.shutdown();srv.server_close();thread.join(timeout=3)
        self.addCleanup(close);return srv

    def http_fixture(self):
        attempts=[]
        class Upstream(BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_POST(h):
                raw=h.rfile.read(int(h.headers['Content-Length']));body=json.loads(raw)
                attempts.append(dict(account=h.headers.get('Authorization'),body=body,path=h.path))
                n=len(attempts)
                content=[dict(type='thinking',thinking='Use the fixture tool.',signature='fixture-signature'),dict(type='tool_use',id='tool_source',name='Bash',input=dict(command='printf TOOL_OK',description='Print fixture nonce'))] if n==1 else [dict(type='text',text='FIXTURE_NONCE')]
                message=dict(id='msg_fixture_'+str(n),type='message',role='assistant',model=body['model'],content=[],stop_reason=None,stop_sequence=None,usage=dict(input_tokens=10,output_tokens=0))
                events=[dict(type='message_start',message=message)]
                for i,block in enumerate(content):
                    start=dict(block)
                    if block['type']=='text':start['text']='';delta=dict(type='text_delta',text=block['text'])
                    elif block['type']=='thinking':start['thinking']='';start['signature']='';delta=dict(type='thinking_delta',thinking=block['thinking'])
                    else:start['input']={};delta=dict(type='input_json_delta',partial_json=json.dumps(block['input']))
                    events.append(dict(type='content_block_start',index=i,content_block=start))
                    events.append(dict(type='content_block_delta',index=i,delta=delta))
                    if block['type']=='thinking':events.append(dict(type='content_block_delta',index=i,delta=dict(type='signature_delta',signature=block['signature'])))
                    events.append(dict(type='content_block_stop',index=i))
                events.extend([dict(type='message_delta',delta=dict(stop_reason='tool_use' if n==1 else 'end_turn',stop_sequence=None),usage=dict(output_tokens=5)),dict(type='message_stop')])
                data=''.join('event: '+v['type']+'\ndata: '+json.dumps(v)+'\n\n' for v in events).encode()
                h.send_response(200);h.send_header('Content-Type','text/event-stream');h.send_header('Content-Length',str(len(data)));h.end_headers();h.wfile.write(data)
        up=self.server(Upstream);self.cfg.anthropic_url='http://127.0.0.1:'+str(up.server_port);self.cfg.codex_url=self.cfg.relay_url=self.cfg.central_url=''
        self.t.router.candidates=lambda *args:(['direct'],'fixture')
        for name,value in [('T',self.t),('tenants',{}),('sink',self.t),('fixed',None),('ustats',None)]:
            pp=patch.object(p.Proxy,name,value);pp.start();self.addCleanup(pp.stop)
        proxy=self.server(p.Proxy);return proxy,attempts

    def test_http_tools_and_full_quota(self):
        proxy,attempts=self.http_fixture();token=self.t.keys.mint('','s',86400)
        def request(body):
            conn=p.http.client.HTTPConnection('127.0.0.1',proxy.server_port,timeout=5)
            try:
                conn.request('POST','/v1/messages',json.dumps(body),{'Authorization':'Bearer '+token,'Content-Type':'application/json'})
                res=conn.getresponse();return res.status,res.read()
            finally:conn.close()
        body=dict(model='claude-sonnet-4-6',messages=[dict(role='user',content='Run tool')])
        self.assertEqual(request(body)[0],200)
        body['messages'].append(dict(role='user',content=[dict(type='tool_result',tool_use_id='tool_source',content='TOOL_OK')]))
        self.assertEqual(request(body)[0],200)
        self.assertEqual([r['account'] for r in attempts],['Bearer fake-b']*2)
        self.assertEqual(attempts[-1]['body'],body)
        for row in self.t.claude_cache['accounts']:row['windows'][1]['used_percent']=100
        self.assertEqual(request(body)[0],429);self.assertEqual(len(attempts),2)

    def test_http_off_keeps_legacy_direct(self):
        self.install(mode='off')
        proxy,attempts=self.http_fixture();token=self.t.keys.mint('a','s',86400)
        conn=p.http.client.HTTPConnection('127.0.0.1',proxy.server_port,timeout=5)
        self.addCleanup(conn.close)
        body=dict(model='claude-sonnet-4-6',messages=[dict(role='user',content='hello')])
        for _ in range(2):
            conn.request('POST','/v1/messages',json.dumps(body),{'Authorization':'Bearer '+token,'Content-Type':'application/json'})
            res=conn.getresponse();self.assertEqual(res.status,200);res.read()
        self.assertEqual([r['account'] for r in attempts],['Bearer fake-a']*2)

    @unittest.skipUnless(os.environ.get('FLEET_CLAUDE_NATIVE_FIXTURE'),'explicit fake-token native loopback only')
    def test_native_cli_tool_loopback(self):
        proxy,attempts=self.http_fixture();wire=[]
        original=self.t.claude_pick
        # Capture actual native bodies before classifier as well as upstream.
        real_route=c.route
        def capture(method,path,headers,body):
            if path.split('?')[0]=='/v1/messages':
                wire.append(json.loads(body))
                if os.environ.get('FLEET_CLAUDE_NATIVE_WIRE'):Path(os.environ['FLEET_CLAUDE_NATIVE_WIRE']).write_text(json.dumps(wire,indent=2))
            return real_route(method,path,headers,body)
        pp=patch.object(c,'route',capture);pp.start();self.addCleanup(pp.stop)
        root=Path(self.tmp.name);home=root/'home';work=root/'work';home.mkdir();work.mkdir()
        token=self.t.keys.mint('','native',86400)
        env=dict(PATH=os.environ['PATH'],HOME=str(home),CLAUDE_CONFIG_DIR=str(home/'.claude'),TMPDIR=str(root),
                 ANTHROPIC_API_KEY=token,ANTHROPIC_BASE_URL='http://127.0.0.1:'+str(proxy.server_port),
                 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1',DISABLE_AUTOUPDATER='1',NO_PROXY='*',no_proxy='*')
        base=[os.environ['FLEET_CLAUDE_NATIVE_FIXTURE'],'--bare','-p','--output-format','stream-json','--verbose','--tools','Bash','--allowedTools','Bash',
              '--strict-mcp-config','--model','claude-sonnet-4-6','--permission-mode','bypassPermissions']
        sid=''
        for prompt in ['Use Bash to print TOOL_OK, then reply FIXTURE_NONCE.','Repeat the nonce. Do not use tools.']:
            result=subprocess.run(base+(['--resume',sid] if sid else [])+[prompt],env=env,cwd=work,text=True,capture_output=True,timeout=40)
            self.assertEqual(result.returncode,0,(result.stdout,result.stderr))
            events=[json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
            init=next(e for e in events if e.get('type')=='system' and e.get('subtype')=='init');sid=init['session_id']
            self.assertTrue(any(e.get('type')=='result' and e.get('result')=='FIXTURE_NONCE' for e in events),events)
        self.assertEqual(len(attempts),3);self.assertEqual([r['account'] for r in attempts],['Bearer fake-b']*3)
        self.assertEqual([r['body'] for r in attempts],wire)
        outputs=[part for m in wire[1]['messages'] if isinstance(m.get('content'),list) for part in m['content'] if part.get('type')=='tool_result']
        self.assertTrue(outputs);self.assertIn('TOOL_OK',json.dumps(outputs))
        self.assertEqual(self.t.picks['claude','native'],'b')
        self.assertIn('fixture-signature',json.dumps(wire[1]))
        self.assertNotIn('fixture-signature',Path(self.tmp.name,'claude-routing.json').read_text())

if __name__=='__main__':unittest.main()
