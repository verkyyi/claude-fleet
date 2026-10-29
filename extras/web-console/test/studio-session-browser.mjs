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
    if (!u.pathname.startsWith('/v1/')) {
      const rel=u.pathname.replace(/^\/app\/?/,'');
      const file=new URL(`../dist/app/${rel.startsWith('assets/')?rel:'index.html'}`,import.meta.url);
      return route.fulfill({body:await readFile(file),contentType:file.pathname.endsWith('.js')?'application/javascript':file.pathname.endsWith('.css')?'text/css':'text/html'});
    }
    let body={};
    if(u.pathname==='/v1/me') body={person:'alice',role:'user',studio:true,pages:['app']};
    if(u.pathname==='/v1/fleet/tasks') body={tasks:[]};
    if(u.pathname==='/v1/fleet/sessions') body={sessions:[],board:{rows:listed?[{id:fid,worker_id:worker,title:'Studio fixture',group:'work',tag:'working',words:['工作中','Working'],at:1,agent:'claude'}]:[],count:listed?1:0,groups:{}}};
    if(u.pathname==='/v1/chat/studio') body={projects:[],sessions:{catalog:session}};
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
  await context.close();
  console.log('PASS studio native worker: restored binding, live transcript, catalog refresh and reload');
} finally { await browser.close(); }
