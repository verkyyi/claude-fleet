// Real app bundle: responsive detail, keyboard history navigation, and a
// persisted create receipt that opens the same edit form as the sidebar.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { chromium } from '../../browser-transport/node_modules/playwright/index.mjs';
const browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
try {
  for(const width of [1440,390]) {
    const context=await browser.newContext({viewport:{width,height:900},locale:'en-US'});
    const page=await context.newPage();
    const errors=[];page.on('pageerror',e=>errors.push(e.message));
    const row=(id,name,status,agent)=>({spec:{id,revision:1,name,prompt:'Summarize the group discussion.\nInclude sources and action items.',at:'07:30',timezone:'Asia/Shanghai',agent,enabled:true,delivery:{wechat:true,livepage:true}},sync_state:'synced',observed:{status,last_run:1793143800,next_run:1793230200,last_line:'Read 26 messages; composing the final summary.'}});
    let rows=[row('schedule-brief','Group brief','running','claude'),row('schedule-ai','AI brief','scheduled','codex'),row('schedule-failed','Weekly notes','failed','claude')];
    const runs=[{id:'run-1',state:'running',attempt:1,started:1793143800,ended:0,summary:'',delivery:{},session_id:'12345678-1234-4234-8234-123456789abc'},{id:'run-2',state:'succeeded',attempt:2,started:1793057400,ended:1793058060,summary:'Today’s group summary\nFull conclusion',delivery:{wechat:'sent',livepage:'sent'},session_id:'12345678-1234-4234-8234-123456789abd'},{id:'run-3',state:'failed',attempt:1,started:1792971000,ended:1792971300,error:'Source needs authorization',delivery:{wechat:'undelivered'},session_id:''}];
    const actions=[];
    await page.route('**/*',async route=>{
      const url=new URL(route.request().url());
      if(!url.pathname.startsWith('/v1/')){
        const rel=url.pathname.replace(/^\/app\/?/,'');
        const name=rel.startsWith('assets/')||rel==='manifest.webmanifest'?rel:'index.html';
        return route.fulfill({body:await readFile(new URL(`../dist/app/${name}`,import.meta.url)),contentType:name.endsWith('.js')?'application/javascript':name.endsWith('.css')?'text/css':'text/html'});
      }
      let data={};
      if(url.pathname==='/v1/me') data={role:'user',person:'alice',name:'Alice',pages:['app']};
      if(url.pathname==='/v1/chat/home')data={unified:true};
      if(url.pathname==='/v1/fleet/tasks')data={tasks:[]};
      if(url.pathname==='/v1/fleet/sessions')data={sessions:[],board:{rows:[],count:0,groups:{}}};
      if(url.pathname==='/v1/schedules'){
        if(route.request().method()==='POST'){
          const body=route.request().postDataJSON();actions.push(body.action);
          if(body.action==='create'){
            const created={...row('schedule-created',body.name,'scheduled',body.agent),spec:{...body,id:'schedule-created',revision:1,enabled:true},sync_state:'pending',observed:{}};
            rows.push(created); data={action:'create',schedule:created};
          } else data={ok:true};
        } else if(url.searchParams.has('id'))data={schedule:rows.find(r=>r.spec.id===url.searchParams.get('id')),runs};
        else if(url.searchParams.has('preview'))data={next_run:1793230200};
        else data={schedules:rows,unread:[]};
      }
      return route.fulfill({json:data});
    });
    const base='https://fleet-schedule.invalid/app/';
    await page.goto(base+'?schedule=schedule-brief&lang=en');
    await page.getByRole('table',{name:'Run history'}).waitFor();
    assert.equal(await page.getByText('Retry 1',{exact:true}).count(),1,'attempt 1 is not a retry');
    assert.equal(await page.getByText('Retry 2',{exact:true}).count(),0);
    assert.equal(await page.getByRole('button',{name:'▶ Run now',exact:true}).isDisabled(),true,'do not start an already running task');
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,`overflow at ${width}`);
    if(width===1440)assert.equal(await page.locator('a[aria-current="page"]').filter({hasText:'Group brief'}).count(),1);
    if(process.env.SCHEDULE_SCREENSHOTS)await page.screenshot({path:`${process.env.SCHEDULE_SCREENSHOTS}/visual-detail-${width}.png`,fullPage:true});
    const history=page.getByRole('row',{name:/Open conversation/}).first();
    await history.focus();await page.keyboard.press('Enter');
    await page.waitForURL(/\/s\/fid/);
    assert.ok(page.url().includes('123456789abc'));
    await page.goto(base+'?schedules=1&lang=en');
    await page.getByRole('link',{name:'Weekly notes',exact:true}).last().waitFor();
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
    if(process.env.SCHEDULE_SCREENSHOTS)await page.screenshot({path:`${process.env.SCHEDULE_SCREENSHOTS}/visual-cards-${width}.png`,fullPage:true});
    if(width===390){
      await page.goto(base+'?lang=en');
      await page.getByRole('button',{name:'New session',exact:true}).waitFor();
      await page.getByRole('link',{name:'⏰ Schedule',exact:true}).waitFor();
      await page.getByRole('link',{name:/Schedules 3/}).waitFor();
      assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
      if(process.env.SCHEDULE_SCREENSHOTS)await page.screenshot({path:`${process.env.SCHEDULE_SCREENSHOTS}/visual-list-${width}.png`,fullPage:true});
    }
    await page.goto(base+'?schedule=new&lang=en');
    await page.getByRole('textbox',{name:'Name',exact:true}).fill('New daily brief');
    await page.getByRole('textbox',{name:'What should it do?'}).fill('Summarize my notes');
    await page.getByRole('button',{name:'Save schedule',exact:true}).click();
    const receipt=page.getByRole('region',{name:'Schedule creation receipt'});
    await receipt.waitFor();
    assert.equal(actions.filter(a=>a==='create').length,1);
    await receipt.getByText('Saved; waiting for the runtime to confirm registration.',{exact:true}).waitFor();
    await receipt.getByRole('link',{name:'Change time'}).click();
    await page.getByRole('textbox',{name:'Name',exact:true}).waitFor();
    assert.equal(await page.getByRole('textbox',{name:'Name',exact:true}).inputValue(),'New daily brief');
    await context.close();
    assert.deepEqual(errors,[],`browser errors at ${width}`);
    console.log(`PASS ${width}px: layout, run navigation, retry count, create receipt, edit link`);
  }
} finally {await browser.close();}
