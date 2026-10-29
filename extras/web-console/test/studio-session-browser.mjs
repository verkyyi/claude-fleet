// Studio persists native FIDs; live chat must use the owner's current worker address.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { chromium } from '../../browser-transport/node_modules/playwright/index.mjs';
const fid = '00000000-0000-4000-8000-000000000001';
const worker = `00000000-0000-4000-8000-000000000002/${fid}`;
const browser = await chromium.launch({headless:true});
try {
  const context = await browser.newContext({viewport:{width:1440,height:900}});
  const page = await context.newPage();
  const sent = [];
  let listed = false;
  let renewals = 0, bootstrap = 0, clock = Date.now();
  await page.addInitScript(({worker}) => {
    const original = window.fetch.bind(window);
    window.fetch = async (input, init) => {
      const u = new URL(String(input), location.origin);
      if (u.pathname !== '/v1/chat/view' || u.searchParams.has('cached')) return original(input, init);
      if (u.searchParams.get('worker') !== worker) return new Response(JSON.stringify({code:'not_yours'}), {status:404});
      const enc = new TextEncoder();
      return new Response(new ReadableStream({start(c) {
        c.enqueue(enc.encode(`data: ${JSON.stringify({t:'state',agent:'claude',session:'s1',can_talk:true,busy:false,queue:[]})}\n\n`));
        c.enqueue(enc.encode(`data: ${JSON.stringify({t:'items',replace:true,session:'s1',at:1,items:[{t:'text',d:'原生会话可读'}]})}\n\n`));
        init?.signal?.addEventListener('abort',()=>c.error(new DOMException('Aborted','AbortError')),{once:true});
      }}), {headers:{'Content-Type':'text/event-stream'}});
    };
  }, {worker});
  const session = {key:'catalog',fid,agent:'claude',proposal_id:'',versions:[]};
  await page.route('**/*', async route => {
    const req=route.request(), u=new URL(req.url());
    if(u.hostname==='space.example.com') return route.fulfill({contentType:'text/html; charset=utf-8',body:'<h1>预览正文</h1>'});
    if (!u.pathname.startsWith('/v1/')) {
      const rel=u.pathname.replace(/^\/app\/?/,'');
      const file=new URL(`../dist/app/${rel.startsWith('assets/')?rel:'index.html'}`,import.meta.url);
      return route.fulfill({body:await readFile(file),contentType:file.pathname.endsWith('.js')?'application/javascript':file.pathname.endsWith('.css')?'text/css':'text/html'});
    }
    let body={};
    if(u.pathname==='/v1/me') body={person:'alice',role:'user',studio:true,pages:['app']};
    if(u.pathname==='/v1/fleet/tasks') body={tasks:[]};
    if(u.pathname==='/v1/fleet/sessions') body={sessions:[],board:{rows:listed?[{id:fid,worker_id:worker,title:'Studio fixture',group:'work',tag:'working',words:['工作中','Working'],at:1,agent:'claude'}]:[],count:listed?1:0,groups:{}}};
    if(u.pathname==='/v1/chat/studio') body={projects:[],sessions:{[session.key]:session}};
    if(u.pathname==='/v1/chat/studio/preview') {
      renewals++;
      const v=session.versions.find(v=>v.version_id===req.postDataJSON().version_id);
      v.embed=`https://space.example.com/embed/${v.version_id}/ticket-${renewals}`;
      v.embed_exp=new Date(clock+3600000).toISOString();
      body={state:'ready'};
    }
    if(u.pathname==='/v1/chat/studio/action') { bootstrap++; body={state:'queued'}; }
    if(u.pathname==='/v1/chat/studio/open') body={...session,reused:true};
    if(u.pathname==='/v1/chat/view') body={mirror:null};
    if(u.pathname==='/v1/chat/say') {
      sent.push({worker:u.searchParams.get('worker'),...req.postDataJSON()});
      body={state:'queued',delivery:'fixture'};
    }
    return route.fulfill({json:body});
  });
  for(let i=0;i<2;i++) {
    await page.goto('http://127.0.0.1:18963/app/studio?project=catalog');
    if(!listed) {
      await page.getByText('正在连接会话…',{exact:true}).waitFor();
      listed = true;
    }
    await page.getByText('原生会话可读',{exact:true}).waitFor({timeout:10000});
    try {
      await Promise.all([
        page.waitForResponse(r=>new URL(r.url()).pathname==='/v1/chat/say',{timeout:5000}),
        page.getByRole('button',{name:'刷新项目',exact:true}).click(),
      ]);
    } catch(e) { console.error(await page.locator('main').innerText()); throw e; }
    assert.equal(sent.length,i+1,'refreshing a reused catalog sends once');
    assert.equal(sent[i].worker,worker,'catalog refresh uses the same owned worker as live chat');
  }
  session.key='page-test'; session.proposal_id='page1';
  session.versions=[1,2].map(n=>({version_id:`v${n}`,version:String(n),status:'hold',at:n,renewable:true,
    embed:`https://space.example.com/embed/v${n}/initial`,embed_exp:new Date(clock+240000).toISOString()}));
  session.operations=[{id:'op1',action:'publish',state:'unknown',at:1,message:'结果待核实'}];
  await page.goto('http://127.0.0.1:18963/app/studio?project=page-test&version=v1');
  await page.getByRole('combobox',{name:'版本',exact:true}).waitFor();
  await page.frameLocator('iframe').getByText('预览正文').waitFor();
  assert.equal(await page.getByRole('combobox',{name:'版本',exact:true}).inputValue(),'v1');
  assert.equal(bootstrap,0,'renewal never sends an Agent message');
  await page.getByLabel('操作记录').getByText(/结果待核实/).waitFor();
  await page.clock.install({time:clock});
  for(const hours of [8,25]) {
    clock=Date.now()+hours*3600000;
    await page.clock.setSystemTime(clock);
    const renewed=page.waitForResponse(r=>new URL(r.url()).pathname==='/v1/chat/studio/preview');
    await page.evaluate(()=>window.dispatchEvent(new Event('online')));
    await renewed;
    await page.waitForTimeout(150);
    await page.getByRole('combobox',{name:'版本',exact:true}).waitFor();
    assert.equal(await page.getByRole('combobox',{name:'版本',exact:true}).inputValue(),'v1','renewal of v1 never selects v2');
  }
  assert.equal(bootstrap,0);
  await page.goto('http://127.0.0.1:18963/app/studio');
  await page.waitForURL('**/studio?project=page-test&version=v1');
  await page.getByLabel('操作记录').getByText(/结果待核实/).waitFor();
  assert.equal(await page.getByRole('combobox',{name:'版本',exact:true}).inputValue(),'v1','return restores project and inspected version');
  await context.close();
  console.log('PASS studio: native chat, 8h/25h preview renewal without Agent turns, restored project/version and durable receipts');
} finally { await browser.close(); }
