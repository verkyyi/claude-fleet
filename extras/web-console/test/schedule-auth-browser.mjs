// Real member bundle: a background 401 must preserve the current page and draft.
// SCHEDULE_TEST_REF=HEAD replays an older committed bundle without editing it.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { chromium } from '../../browser-transport/node_modules/playwright/index.mjs';
const browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
try {
  const context=await browser.newContext({viewport:{width:1440,height:900},locale:'en-US'});
  const page=await context.newPage();
  await page.clock.install();
  let expired=false, reads=0;
  await page.route('**/*',async route=>{
    const url=new URL(route.request().url());
    if(!url.pathname.startsWith('/v1/')){
      const rel=url.pathname.replace(/^\/app\/?/,'');
      const name=rel.startsWith('assets/')||rel==='manifest.webmanifest'?rel:'index.html';
      const body=process.env.SCHEDULE_TEST_REF?execFileSync('git',['show',`${process.env.SCHEDULE_TEST_REF}:extras/web-console/dist/app/${name}`],{maxBuffer:8*1024*1024}):await readFile(new URL(`../dist/app/${name}`,import.meta.url));
      return route.fulfill({body,contentType:name.endsWith('.js')?'application/javascript':name.endsWith('.css')?'text/css':'text/html'});
    }
    let data={};
    if(url.pathname==='/v1/me') data={role:'user',person:'alice',name:'Alice',pages:['app']};
    if(url.pathname==='/v1/chat/home')data={unified:true};
    if(url.pathname==='/v1/fleet/tasks')data={tasks:[]};
    if(url.pathname==='/v1/fleet/sessions')data={sessions:[],board:{rows:[],count:0,groups:{}}};
    if(url.pathname==='/v1/schedules'){
      reads++;
      if(expired)return route.fulfill({status:401,json:{error:'expired'}});
      data=url.searchParams.has('preview')?{next_run:1793203200}:{schedules:[{spec:{id:'schedule-private',revision:1,name:'Private schedule',prompt:'secret',at:'07:00',timezone:'Asia/Shanghai',enabled:true,delivery:{}},sync_state:'synced',observed:{}}],unread:[]};
    }
    return route.fulfill({json:data});
  });
  const url='http://fleet-schedule.invalid/app/?schedule=new&lang=en';
  await page.goto(url);
  await page.getByText('Private schedule',{exact:true}).waitFor();
  await page.getByRole('textbox',{name:'What should it do?'}).fill('Keep this unsaved task');
  expired=true;
  await Promise.all([page.waitForResponse(r=>new URL(r.url()).pathname==='/v1/schedules'&&r.status()===401),page.clock.fastForward(16000)]);
  // Let fetch completion and React commit, not another poll, settle.
  await page.waitForTimeout(250);
  assert.equal(page.url(),url,'background metadata navigated away from the current conversation');
  await page.getByText('Your sign-in expired. Sign in again.',{exact:false}).first().waitFor();
  assert.equal(await page.getByRole('textbox',{name:'What should it do?'}).inputValue(),'Keep this unsaved task');
  assert.equal(await page.getByText('Private schedule',{exact:true}).count(),0,'private data survived expiry');
  const stopped=reads;
  await page.clock.fastForward(60000);
  assert.equal(reads,stopped,'background polling continued after expiry');
  assert.equal(await page.getByRole('link',{name:'Sign in again',exact:true}).first().getAttribute('href'),'/app/signin');
  await context.close();
  console.log('PASS schedule auth: no navigation, private data cleared, draft kept, polling stopped');
} finally { await browser.close(); }
