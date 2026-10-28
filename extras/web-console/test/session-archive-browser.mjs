// Built app at phone/desktop widths; isolated responses, no production writes.
import assert from 'node:assert/strict';
import { readFile, mkdir } from 'node:fs/promises';
import { chromium } from '../../browser-transport/node_modules/playwright/index.mjs';
const browser = await chromium.launch({ headless:true, ...(process.env.CHROME_BIN ? {executablePath:process.env.CHROME_BIN} : {}) });
const fid = '00000000-0000-4000-8000-000000000900';
const origin = 'http://fleet-archive.invalid';
try {
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
        assert.equal(u.pathname,'/v1/fleet/session_archive','archiving must not stop/resume/send');
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
  console.log('PASS session archive: 390 + 1440, failure, archive, reload, restore; no lifecycle writes');
}finally{await browser.close();}
