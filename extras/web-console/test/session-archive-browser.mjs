// Built app at phone/desktop widths; isolated responses, no production writes.
import assert from 'node:assert/strict';
import { readFile, mkdir } from 'node:fs/promises';
import { chromium } from '../../browser-transport/node_modules/playwright/index.mjs';
const browser = await chromium.launch({ headless:true, ...(process.env.CHROME_BIN ? {executablePath:process.env.CHROME_BIN} : {}) });
const fid = '00000000-0000-4000-8000-000000000900';
const origin = 'http://fleet-archive.invalid';
try {
  // Search always reaches archives; protected rows leave ordinary room. The same
  // clock is visible on desktop and available in the phone's long-press detail.
  for (const width of [390, 1440]) for (const lang of ['en', 'zh']) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, locale: lang === 'zh' ? 'zh-CN' : 'en-US' });
    const page = await context.newPage();
    const now = Math.floor(Date.now() / 1000);
    const session = (n, code, title, extra = {}) => ({ id: `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`, code, title,
      group: 'queue', tag: 'idle', state: 'idle', words: ['空闲', 'Idle'], activity_at: now - 100 - n, at: now - 86400, ...extra });
    const rows = [...Array.from({ length: 11 }, (_, i) => session(i, `AA${i}`, `Waiting ${i}`, { group: 'ask', tag: 'needs', state: 'needs' })),
      ...Array.from({ length: 11 }, (_, i) => session(100 + i, `RR${i}`, `Cost estimate ${i}`)),
      session(990, 'ZX90', 'Archived estimate', { group: 'gone', tag: 'ended', state: 'exited', archived: true, tree_at: now - 10 })];
    await page.route('**/*', async route => {
      const u = new URL(route.request().url());
      if (!u.pathname.startsWith('/v1/')) {
        const rel = u.pathname.replace(/^\/app\/?/, '');
        const file = new URL(`../dist/app/${rel.startsWith('assets/') || rel === 'manifest.webmanifest' ? rel : 'index.html'}`, import.meta.url);
        return route.fulfill({ body: await readFile(file), contentType: file.pathname.endsWith('.js') ? 'application/javascript' : file.pathname.endsWith('.css') ? 'text/css' : 'text/html' });
      }
      assert.equal(route.request().method(), 'GET', 'search and time display write nothing');
      let body = {};
      if (u.pathname === '/v1/me') body = { role: 'user', person: 'test-owner', name: 'Test', pages: ['app'], entry: true };
      if (u.pathname === '/v1/chat/home') body = { state: 'ok', machine: 'test', login: 'test', unified: false };
      if (u.pathname === '/v1/fleet/tasks') body = { tasks: [] };
      if (u.pathname === '/v1/fleet/sessions') body = { sessions: [], board: { count: rows.length, active: 22, groups: {}, gone_days: 7, digest: 'activity', rows } };
      return route.fulfill({ json: body });
    });
    await context.addCookies([{ name: "cf_lang", value: lang, url: origin }]);
    await page.goto(`${origin}/app/`);
    const list = page.locator(`[data-session-list="${width < 768 ? 'page' : 'side'}"]`);
    await list.locator('[data-row="RR0"]').waitFor();
    assert.equal(await list.locator('[data-row^="AA"]').count(), 11);
    assert.equal(await list.locator('[data-row^="RR"]').count(), 10, 'asks do not consume ordinary slots');
    assert.equal(await list.locator('[data-row="ZX90"]').count(), 0, 'archive stays hidden outside search');
    await page.locator('button[aria-label="Search sessions"]:visible, button[aria-label="搜索会话"]:visible').click();
    const input = page.locator('input[aria-label="Search by code, title or machine"]:visible, input[aria-label="搜编号、标题、机器"]:visible');
    await input.fill('estimate');
    const archived = list.locator('[data-row="ZX90"]');
    await archived.waitFor();
    assert.equal(await list.locator('[data-row]').first().getAttribute('data-row'), 'ZX90', 'tree activity breaks search ties');
    assert.equal(await archived.locator('[data-archived-label]').innerText(), lang === 'zh' ? '已归档' : 'Archived');
    assert.equal(await archived.locator('[data-last-active]').isVisible(), width >= 480);
    assert.equal(await archived.locator('[data-last-active]').textContent(), lang === 'zh' ? '刚刚' : 'now');
    assert.ok((await archived.getAttribute('aria-label')).includes(lang === 'zh' ? '最后活跃' : 'Last active'));
    await input.fill('ZX90');
    assert.equal(await list.locator('[data-row]').count(), 1, 'code search finds an archive with its group shut');
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, 'no horizontal overflow');
    if (process.env.ACTIVITY_SHOTS) { await mkdir(process.env.ACTIVITY_SHOTS, { recursive: true }); await page.screenshot({ path: `${process.env.ACTIVITY_SHOTS}/activity-${lang}-${width}.png`, fullPage: true }); }
    if (width < 480) {
      await archived.dispatchEvent('pointerdown', { pointerType: 'touch', clientX: 80, clientY: 180 });
      await page.getByRole('dialog').waitFor();
      assert.ok((await page.getByRole('dialog').innerText()).includes(lang === 'zh' ? '最后活跃' : 'Last active'));
      await archived.dispatchEvent('pointerup', { pointerType: 'touch' });
    }
    await context.close();
  }
  console.log('PASS session activity: archives in search, time order, protected capacity, bilingual clock + narrow detail');
  for (const width of [390,1440]) {
    const context = await browser.newContext({viewport:{width,height:900}});
    const page = await context.newPage();
    let archived=false, fail=false, writes=[];
    await page.route('**/*',async route=>{
      const req=route.request(), u=new URL(req.url());
      if(!u.pathname.startsWith('/v1/')) {
        const rel=u.pathname.replace(/^\/app\/?/,'');
        const file=new URL(`../dist/app/${rel.startsWith('assets/')||rel==='manifest.webmanifest'?rel:'index.html'}`,import.meta.url);
        return route.fulfill({body:await readFile(file),contentType:file.pathname.endsWith('.js')?'application/javascript':file.pathname.endsWith('.css')?'text/css':'text/html'});
      }
      let body={};
      if(u.pathname==='/v1/me')body={role:'user',person:'test-owner',name:'Test',pages:['app'],entry:true};
      if(u.pathname==='/v1/chat/home')body={state:'ok',machine:'test',login:'test',unified:false};
      if(u.pathname==='/v1/fleet/tasks')body={tasks:[]};
      if(u.pathname==='/v1/fleet/sessions')body={sessions:[],board:{count:archived?0:1,active:1,groups:{},gone_days:7,digest:String(archived),rows:[{id:fid,code:'AB12',title:'Keep my conversation',group:'work',tag:'working',state:'working',running:true,active:true,archived,words:['在干活','Working'],at:Date.now()/1000,activity_at:Date.now()/1000}]}};
      if(req.method()==='POST'){
        const args=JSON.parse(req.postData());writes.push({path:u.pathname,args});
        assert.equal(u.pathname,'/v1/fleet/session_archive','nothing to stop here: archiving writes only the archive');
        assert.equal(args.id,fid);
        if(fail)return route.fulfill({status:503,json:{error:'archive unavailable'}});
        archived=args.archived;body={status:'succeeded',id:fid,archived};
      }
      return route.fulfill({json:body});
    });
    await page.goto(origin+'/app/');
    const list=page.locator(`[data-session-list="${width<768?'page':'side'}"]`);
    const row=list.locator('[data-row="AB12"]');
    await row.waitFor();
    fail=true;
    await list.getByRole('button',{name:/^(归档|Archive)$/}).click();
    await list.getByRole('alert').waitFor();
    assert.equal(await row.count(),1,'failed save keeps the session visible');
    fail=false;
    await list.getByRole('button',{name:/^(归档|Archive)$/}).click();
    await row.waitFor({state:'detached'});
    await list.getByRole('button',{name:/^(已归档|Archived)/}).click();
    await row.waitFor();
    assert.equal(await list.getByRole('button',{name:/^(取消归档|Unarchive)$/}).count(),1);
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,'no horizontal overflow');
    if(process.env.ARCHIVE_SHOTS){await mkdir(process.env.ARCHIVE_SHOTS,{recursive:true});await page.screenshot({path:`${process.env.ARCHIVE_SHOTS}/archive-${width}.png`,fullPage:true});}
    await page.reload();
    await list.getByRole('button',{name:/^(已归档|Archived)/}).click();
    await row.waitFor();
    await list.getByRole('button',{name:/^(取消归档|Unarchive)$/}).click();
    await row.waitFor({state:'detached'});
    await list.getByRole('button',{name:/^(返回会话|Back to sessions)$/}).click();
    await row.waitFor();
    assert.deepEqual(writes.map(x=>x.args.archived),[true,true,false]);
    await context.close();
  }
  // A successful explicit resume/message restores the row before a fresh board.
  for (const action of ['resume', 'message']) {
    const context = await browser.newContext({viewport:{width:1440,height:900},locale:'en-US'});
    await context.addCookies([{name:'cf_lang',value:'en',url:origin}]);
    const page = await context.newPage();
    const fid='00000000-0000-4000-8000-000000000903', worker=`fleet/${fid}`;
    let fail=true; const writes=[];
    await page.addInitScript(() => {
      const original=window.fetch.bind(window);
      window.fetch=async(input,init)=>{
        const u=new URL(String(input),location.origin);
        if(u.pathname!='/v1/chat/view'||u.searchParams.has('cached'))return original(input,init);
        const enc=new TextEncoder();
        return new Response(new ReadableStream({start(c){
          for(const f of [{t:'state',agent:'claude',session:'native',can_talk:true,busy:false,queue:[]},
            {t:'items',replace:true,session:'native',at:1,items:[{t:'text',d:'Archived conversation'}]}])
            c.enqueue(enc.encode('data: '+JSON.stringify(f)+'\n\n'));
          init?.signal?.addEventListener('abort',()=>c.error(new DOMException('Aborted','AbortError')),{once:true});
        }}),{headers:{'Content-Type':'text/event-stream'}});
      };
    });
    await page.route('**/*',async route=>{
      const req=route.request(),u=new URL(req.url());
      if(!u.pathname.startsWith('/v1/')){
        const rel=u.pathname.replace(/^\/app\/?/,'');
        const file=new URL(`../dist/app/${rel.startsWith('assets/')?rel:'index.html'}`,import.meta.url);
        return route.fulfill({body:await readFile(file),contentType:file.pathname.endsWith('.js')?'application/javascript':file.pathname.endsWith('.css')?'text/css':'text/html'});
      }
      let body={};
      if(u.pathname==='/v1/me')body={role:'user',person:'test-owner',name:'Test',pages:['app'],entry:true};
      if(u.pathname==='/v1/chat/home')body={state:'ok',machine:'test',login:'test',unified:false};
      if(u.pathname==='/v1/fleet/tasks')body={tasks:[]};
      if(u.pathname==='/v1/fleet/sessions')body={sessions:[],board:{count:0,active:0,groups:{},rows:[{
        id:fid,code:'EF56',title:'Return this session',group:action==='resume'?'gone':'work',tag:action==='resume'?'ended':'working',
        state:action==='resume'?'exited':'working',origin:'cli',worker_id:worker,archived:true,words:['空闲','Idle'],agent:'claude',
        at:Date.now()/1000-864000,activity_at:Date.now()/1000-864000,history:action==='resume'?{id:fid,resume_id:worker}:undefined}]}};
      if(u.pathname==='/v1/chat/view')body={mirror:null};
      if(req.method()==='POST'){
        writes.push(u.pathname);
        if(u.pathname==='/v1/fleet/session_archive'){
          assert.deepEqual(req.postDataJSON(),{id:fid,archived:false});body={status:'succeeded'};
        }else if(fail)return route.fulfill({status:503,json:{error:'not delivered'}});
        else body=u.pathname==='/v1/chat/say'?{state:'queued',delivery:'test'}:{status:'succeeded'};
      }
      return route.fulfill({json:body});
    });
    await page.goto(origin+'/app/s/EF56');
    try { await page.getByText('Archived conversation',{exact:true}).waitFor({timeout:10000}); } catch(e) { console.error(action, await page.locator('body').innerText()); throw e; }
    const list=page.locator('[data-session-list="side"]');
    const row=list.locator('[data-row="EF56"]');
    assert.equal(await row.count(),0,'viewing archived history alone does not restore it');
    assert.deepEqual(writes,[]);
    if(action==='resume'){
      await page.getByRole('button',{name:'Details',exact:true}).click();
      await page.getByRole('button',{name:'Resume',exact:true}).click();
      await page.getByText(/Could not resume it/).waitFor();
      assert.ok(!writes.includes('/v1/fleet/session_archive'),'failed resume preserves archive');
      fail=false;
      await page.getByRole('button',{name:'Resume',exact:true}).click();
    }else{
      const input=page.locator('textarea:visible').last();
      await input.fill('Continue this conversation');
      await Promise.all([page.waitForResponse(r=>new URL(r.url()).pathname==='/v1/chat/say'), input.press('Enter')]);
      assert.ok(!writes.includes('/v1/fleet/session_archive'),'failed message preserves archive');
      fail=false;
      await input.fill('Continue now');
      await input.press('Enter');
    }
    await row.waitFor();
    assert.equal(writes.at(-1),'/v1/fleet/session_archive','reactivation saves visibility after success');
    assert.equal(await row.locator('[data-archived-label]').count(),0,'local saved result wins over a stale board');
    await context.close();
  }
  console.log('PASS archived resume/message: failed action stays archived, successful action returns immediately, history reads write nothing');
  // Archive = stop + hide (task DDBQ): a running task asks first, then stops, then archives.
  {
    const context = await browser.newContext({viewport:{width:1440,height:900}});
    const page = await context.newPage();
    const tid='00000000-0000-4000-8000-000000000901', op='00000000-0000-4000-8000-000000000902';
    let archived=false; const writes=[];
    await page.route('**/*',async route=>{
      const req=route.request(), u=new URL(req.url());
      if(!u.pathname.startsWith('/v1/')) {
        const rel=u.pathname.replace(/^\/app\/?/,'');
        const file=new URL(`../dist/app/${rel.startsWith('assets/')||rel==='manifest.webmanifest'?rel:'index.html'}`,import.meta.url);
        return route.fulfill({body:await readFile(file),contentType:file.pathname.endsWith('.js')?'application/javascript':file.pathname.endsWith('.css')?'text/css':'text/html'});
      }
      let body={};
      if(u.pathname==='/v1/me')body={role:'user',person:'test-owner',name:'Test',pages:['app'],entry:true};
      if(u.pathname==='/v1/chat/home')body={state:'ok',machine:'test',login:'test',unified:false};
      if(u.pathname==='/v1/fleet/tasks')body={tasks:[]};
      if(u.pathname==='/v1/fleet/tasks/T42')body={id:'T42',title:'Run the build',created_at:'2026-10-29T00:00:00Z'};
      if(u.pathname==='/v1/fleet/sessions')body={sessions:[],board:{count:archived?0:1,active:1,groups:{},gone_days:7,digest:'s'+archived,rows:[{id:tid,code:'CD34',task:'T42',task_id:tid,execution_endpoint:'mac',title:'Run the build',group:'work',tag:'working',state:'working',running:true,active:true,archived,words:['在干活','Working'],at:Date.now()/1000,activity_at:Date.now()/1000}]}};
      if(req.method()==='POST'){
        writes.push(u.pathname);
        if(u.pathname==='/v1/fleet/tasks/T42/stop')body={stop_requested:true,execution_exit_confirmed:false,operation:{operation_id:op,action:'worker_stop',status:'succeeded'}};
        else if(u.pathname==='/v1/fleet/session_archive'){archived=JSON.parse(req.postData()).archived;body={status:'succeeded',id:tid,archived};}
      }
      return route.fulfill({json:body});
    });
    await page.goto(origin+'/app/');
    const list=page.locator('[data-session-list="side"]');
    const row=list.locator(`[data-row="${tid}"]`);   // a task row goes by its task_id (rowRef)
    await row.waitFor();
    await list.getByRole('button',{name:/^(归档|Archive)$/}).click();
    const dialog=page.getByRole('alertdialog');
    await dialog.waitFor();
    assert.deepEqual(writes,[],'nothing is written before the person says yes');
    await dialog.getByRole('button',{name:/^(停止并归档|Stop and archive)$/}).click();
    await row.waitFor({state:'detached'});
    assert.deepEqual(writes,['/v1/fleet/tasks/T42/stop','/v1/fleet/session_archive'],'stop first, then archive');
    await context.close();
  }
  console.log('PASS session archive: 390 + 1440, failure, archive, reload, restore; a running one asks, stops, then archives');
}finally{await browser.close();}
