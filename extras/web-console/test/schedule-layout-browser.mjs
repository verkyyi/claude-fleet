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
    const actions=[], bodies=[]; let fullReads=0;
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
      if(url.pathname==='/v1/chat/view'){
        if(url.searchParams.has('cached'))return route.fulfill({status:404,json:{}});
        const result=JSON.stringify({action:'create',schedule:rows[0]});
        if(url.searchParams.has('tool')){fullReads++;return route.fulfill({json:{text:result}});}
        const items=[{t:'user',text:'Create a daily group brief'},
          {t:'tool',id:'new-create',name:'fleet.schedule',summary:'fleet · schedule'},
          {t:'tool_result',id:'new-create',text:JSON.stringify({action:'create',schedule_id:'schedule-brief'})+'\n'+result.slice(0,80)+'…',more:true},
          {t:'tool',id:'old-create',name:'mcp__fleet__schedule',summary:'schedule'},
          {t:'tool_result',id:'old-create',text:result.slice(0,160)+'…',more:true}];
        const frames=[{t:'state',agent:'codex',session:'native',state:'ended',busy:false,can_talk:false,talk_reason:'historical',history_status:'readable'},
          {t:'items',replace:true,session:'native',items,at:1000,older:0},{t:'history_end'}];
        return route.fulfill({contentType:'text/event-stream',body:frames.map(f=>'data: '+JSON.stringify(f)+'\n\n').join('')});
      }
      if(url.pathname==='/v1/schedules'){
        if(route.request().method()==='POST'){
          const body=route.request().postDataJSON();actions.push(body.action); bodies.push(body);
          if(body.action==='create'){
            const created={...row('schedule-created',body.name,'scheduled',body.agent),spec:{...body,...(body.trigger ? {once_at:body.trigger.type==='now'?Math.floor(Date.now()/1000):Date.parse(body.trigger.at)/1000,trigger:undefined}:{}),id:'schedule-created',revision:1,enabled:true},sync_state:'pending',observed:{}};
            rows.push(created); data={action:'create',schedule:created};
          } else data={ok:true};
        } else if(url.searchParams.has('session_id'))data={run:{id:'run-1',schedule_id:'schedule-brief',title:'Group brief 2026-10-28'}};
        else if(url.searchParams.has('id'))data={schedule:rows.find(r=>r.spec.id===url.searchParams.get('id')),runs};
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
    await page.getByRole('region',{name:'Schedule creation receipt'}).nth(1).waitFor();
    assert.equal(fullReads,1,'new short receipt should not fetch the full tool output; legacy preview fetches once');
    if(process.env.SCHEDULE_SCREENSHOTS)await page.screenshot({path:`${process.env.SCHEDULE_SCREENSHOTS}/visual-chat-${width}.png`,fullPage:true});
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
    for(const mode of ['now','once']) {
      await page.goto(base+'?schedule=new&lang=en');
      await page.getByRole('textbox',{name:'Name',exact:true}).fill('One-shot '+mode);
      await page.getByRole('textbox',{name:'What should it do?'}).fill('Summarize once');
      await page.getByRole('combobox',{name:'When to run',exact:true}).selectOption(mode);
      if(mode==='once')await page.getByRole('textbox',{name:'Date and time (include UTC offset)'}).fill('2027-01-01T07:00:00+08:00');
      await page.getByRole('button',{name:'Save schedule',exact:true}).click();
      await page.getByRole('region',{name:'Schedule creation receipt'}).waitFor();
      assert.equal(bodies.filter(b=>b.action==='create').at(-1).trigger.type,mode);
      assert.equal(bodies.filter(b=>b.action==='create').at(-1).at,undefined,'no accidental daily recurrence');
      assert.equal(bodies.filter(b=>b.action==='create').at(-1).execution,undefined,'retries not silently enabled');
      assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
    }
    await context.close();
    assert.deepEqual(errors,[],`browser errors at ${width}`);
    console.log(`PASS ${width}px: layout, run navigation, retry count, native and form receipts, edit link`);
  }
} finally {await browser.close();}
