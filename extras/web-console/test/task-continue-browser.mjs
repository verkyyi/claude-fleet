// Built app + actual browser, loopback-shaped mocked API. No production writes.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { chromium } from '../../browser-transport/node_modules/playwright/index.mjs';
const browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
const fid='00000000-0000-4000-8000-000000000970',stop='00000000-0000-4000-8000-000000000971';
const op='00000000-0000-4000-8000-000000000972',exit='00000000-0000-4000-8000-000000000973';
async function scenario({readonly=false,mobile=false,unclaimed=false,owner='',legacy=false,status=202}={}) {
  const context=await browser.newContext({viewport:mobile?{width:390,height:844}:{width:1280,height:850}});
  const page=await context.newPage(), writes=[];let started=false, responseStatus=status;
  await page.route('**/*',async route=>{
    const req=route.request(),u=new URL(req.url());
    if(!u.pathname.startsWith('/v1/')) {
      const rel=u.pathname.replace(/^\/app\/?/,'');
      const f=new URL(`../dist/app/${rel.startsWith('assets/')||rel==='manifest.webmanifest'?rel:'index.html'}`,import.meta.url);
      return route.fulfill({body:await readFile(f),contentType:f.pathname.endsWith('.js')?'application/javascript':f.pathname.endsWith('.css')?'text/css':'text/html'});
    }
    let body={};
    if(u.pathname==='/v1/me')body={role:'user',person:'owner',pages:['app'],entry:true,read_only:readonly};
    if(u.pathname==='/v1/chat/home')body={machine:'test',login:'test',state:'ok',unified:false};
    if(u.pathname==='/v1/fleet/tasks')body={tasks:[{id:'T970',fid,short:'TEST',title:'Continue fixture',created_at:'2026-10-23T00:00:00Z',
      authority_version:1,generation:started?3:2,cancel_request:started?'':stop,operation_id:op,
      ...(!legacy?{execution_owner:owner,execution_endpoint:unclaimed?'test-node':''}:{})}]};
    if(u.pathname==='/v1/fleet/sessions')body={sessions:[],board:{count:1,digest:String(started),groups:{},gone_days:7,rows:[{
      id:fid,task_id:fid,task:'T970',title:'Continue fixture',group:started?'queue':'gone',tag:started?'starting':'ended',
      state:'',pending_start:started,words:started?['待启动','Waiting to start']:['未运行','Not running'],at:1}]}};
    if(req.method()==='POST') {
      writes.push({path:u.pathname,body:JSON.parse(req.postData())});
      assert.equal(u.pathname,'/v1/fleet/tasks/T970/continue','no legacy resume or spawn fallback');
      if(responseStatus!==202)return route.fulfill({status:responseStatus,json:{error:'fixture-unavailable'}});
      started=true;
      body={task:'T970',agent:writes.at(-1).body.agent||'claude',authorized_generation:3,
        operation:{operation_id:op,action:'worker_start'},...(unclaimed?{stop_operation_id:stop}:{exit_operation_id:exit})};
      return route.fulfill({status:202,json:body});
    }
    return route.fulfill({json:body});
  });
  await page.goto('http://fleet-continue.invalid/app/s/'+fid);
  await page.locator('[data-workspace=chat]').waitFor();
  return {context,page,writes,setStatus:value=>responseStatus=value};
}
try {
  for(const opts of [{legacy:true},{owner:'fleet/live'}]) {
    const s=await scenario(opts);assert.equal(await s.page.getByRole('button',{name:/^(继续|Continue)$/}).count(),0);
    assert.equal(s.writes.length,0);await s.context.close();
  }
  const ro=await scenario({readonly:true});
  assert.equal(await ro.page.getByRole('button',{name:/^(继续|Continue)$/}).isDisabled(),true);
  assert.equal(ro.writes.length,0);await ro.context.close();
  for(const opts of [{},{mobile:true,unclaimed:true},{status:503}]) {
    const s=await scenario(opts),button=s.page.getByRole('button',{name:/^(继续|Continue)$/});
    assert.equal(s.writes.length,0,'opening history does not launch');
    await button.click();
    if(opts.status===503) {
      await s.page.getByText(/没能继续|Could not continue/).waitFor();
      assert.equal(await button.count(),1);s.setStatus(202);await button.click();
    }
    await s.page.getByText(/^(已提交继续请求。|Continue request submitted\.)$/).waitFor();
    await button.waitFor({state:'detached'});
    assert.equal(s.writes[0].body.expected_generation,2);assert.equal(s.writes[0].body.expected_stop_operation_id,stop);
    if(opts.status===503)assert.deepEqual(s.writes[0],s.writes[1]);
    if(opts.mobile)await s.page.getByRole('button',{name:/^(返回|Back)$/}).click();
    await s.page.locator('[data-status-slot]').first().waitFor();
    assert.equal(await s.page.locator('[data-status-slot]').count(),1,'continuation keeps one status slot: '+JSON.stringify(opts));
    await s.context.close();
  }
  const swap=await scenario();
  await swap.page.getByTestId('ws-more').click();
  await swap.page.getByRole('menuitem',{name:/用 Codex 继续|Continue with Codex/}).click();
  await swap.page.getByText(/^(已提交继续请求。|Continue request submitted\.)$/).waitFor();
  assert.equal(swap.writes[0].body.agent,'codex');await swap.context.close();
  console.log('PASS Task continue browser: explicit only, read-only, no fallback, stable retry, new pending, mobile, provider choice');
} finally {await browser.close();}
