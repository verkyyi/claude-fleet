// The Bubble Cloud proposal workbench (task APVZ) in the real app, its API mocked: the four
// columns, the config areas saving with their revision, a new proposal opened with its client
// card, the rendering bench's batch / pick / slide hand-off, the script panel, and the narrow
// screen's notice. BC_SHOTS=<dir> also writes screenshots.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { chromium } from '../../browser-transport/node_modules/playwright/index.mjs';
const fid = '00000000-0000-4000-8000-0000000000bc';
const worker = `00000000-0000-4000-8000-000000000002/${fid}`;
const shots = process.env.BC_SHOTS || '';
const PNG = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const browser = await chromium.launch({headless:true, ...(process.env.CHROME_PATH ? {executablePath:process.env.CHROME_PATH} : {})});
try {
  const context = await browser.newContext({viewport:{width:1440,height:900}});
  const page = await context.newPage();
  const calls = [], said = [], opened = [];
  let failStudio = 0, inflight = 0, overlap = 0;
  let config = {rev:1, company:{name:'Bubble Cloud Events', positioning:'Full-service corporate events for Bay Area tech companies.'},
    clients:[{id:'c-google', name:'Google', event:'Holiday party', date:'12/14', include_prices:false}],
    templates:[{id:'tpl-html', name:'Corporate event proposal (13 pages, HTML — start here)', kind:'template', version_id:'v-tpl'}]};
  const renders = [
    {id:'aaaaaaaaaaa1', kind:'render', proposal:'P1', slide:'4', model:'gemini', prompt:'arch', status:'ok', cost:0.067, score:8.6, judge:{notes:'venue kept'}, thumb:PNG, at:2},
    {id:'aaaaaaaaaaa2', kind:'render', proposal:'P1', slide:'4', model:'gpt', prompt:'arch', status:'ok', cost:0.048, thumb:PNG, at:1},
  ];
  const assets = [{id:'bbbbbbbbbbb1', kind:'asset', label:'lobby', group:'venue', thumb:PNG, at:1}];
  const scripts = [{slide:'1', title:'Cover', text:'Open with the theme in one line.'}, {slide:'4', title:'Entrance', text:'This arch greets 300 guests.'}];
  const session = {key:'new-bc', fid, agent:'claude', profile:'bubble-cloud', client:'c-google', proposal_id:'P1', title:'Google · Holiday party',
    versions:[{proposal_id:'P1', title:'Google · Holiday party', version_id:'v1', version:'1', status:'hold', at:1, scripts,
      embed:'https://space.example.com/embed/v1/t', embed_exp:new Date(Date.now()+3600000).toISOString(), renewable:true}], actions:[]};
  await page.addInitScript(({worker}) => {
    const original = window.fetch.bind(window);
    window.fetch = async (input, init) => {
      const u = new URL(String(input), location.origin);
      if (u.pathname !== '/v1/chat/view' || u.searchParams.has('cached')) return original(input, init);
      const enc = new TextEncoder();
      return new Response(new ReadableStream({start(c) {
        c.enqueue(enc.encode(`data: ${JSON.stringify({t:'state',agent:'claude',session:'s1',can_talk:true,busy:false,queue:[]})}\n\n`));
        c.enqueue(enc.encode(`data: ${JSON.stringify({t:'items',replace:true,session:'s1',at:1,items:[{t:'text',d:'方案 Agent 在线'}]})}\n\n`));
        init?.signal?.addEventListener('abort',()=>c.error(new DOMException('Aborted','AbortError')),{once:true});
      }}), {headers:{'Content-Type':'text/event-stream'}});
    };
  }, {worker});
  await page.route('**/*', async route => {
    const req = route.request(), u = new URL(req.url());
    if (u.hostname === 'space.example.com') return route.fulfill({contentType:'text/html; charset=utf-8', body:'<h1 style="font:48px sans-serif">Deck preview</h1>'});
    if (!u.pathname.startsWith('/v1/')) {
      const rel = u.pathname.replace(/^\/app\/?/, '');
      const file = new URL(`../dist/app/${rel.startsWith('assets/') ? rel : 'index.html'}`, import.meta.url);
      return route.fulfill({body:await readFile(file), contentType:file.pathname.endsWith('.js') ? 'application/javascript' : file.pathname.endsWith('.css') ? 'text/css' : 'text/html'});
    }
    let body = {};
    if (u.pathname === '/v1/me') body = {person:'alice', role:'user', studio:true, pages:['app']};
    if (u.pathname === '/v1/fleet/tasks') body = {tasks:[]};
    if (u.pathname === '/v1/fleet/sessions') body = {sessions:[], board:{rows:[{id:fid, worker_id:worker, title:'BC', group:'work', tag:'working', words:['工作中','Working'], at:1, agent:'claude'}], count:1, groups:{}}};
    if (u.pathname === '/v1/chat/studio') {
      if (++inflight > 1) overlap++;
      await new Promise(r => setTimeout(r, 50)); inflight--;
      if (failStudio > 0) { failStudio--; return route.fulfill({status:502, json:{error:'home slow'}}); }
      body = {projects:[], sessions:{[session.key]:session}};
    }
    if (u.pathname === '/v1/chat/studio/open') { opened.push(req.postDataJSON()); body = {...session, key:'new-2', proposal_id:'', versions:[]}; }
    if (u.pathname === '/v1/chat/studio/bc') {
      const a = req.postDataJSON(); calls.push(a);
      if (a.op === 'read') body = {config, assets, renders};
      if (a.op === 'save') { assert.equal(a.rev, config.rev); config = {...config, ...a, rev:config.rev + 1}; delete config.op; body = {rev:config.rev}; }
      if (a.op === 'usage') body = {spent:0.115, cap:5, models:['gemini','gpt','seedream']};
      if (a.op === 'generate') { renders.push({id:'aaaaaaaaaaa3', kind:'render', proposal:a.proposal, slide:a.slide, model:'gemini', prompt:a.prompt, status:'running', at:3}); body = {state:'started', ids:['aaaaaaaaaaa3']}; }
      if (a.op === 'pick') { for (const r of renders) r.picked = r.id === a.id; body = {}; }
    }
    if (u.pathname === '/v1/chat/view') body = {mirror:null};
    if (u.pathname === '/v1/chat/say') { said.push(req.postDataJSON().text); body = {state:'queued'}; }
    return route.fulfill({json:body});
  });

  await page.goto('http://127.0.0.1:18964/app/studio?profile=bc&project=new-bc');
  await page.getByTestId('bubble-cloud-studio').waitFor();
  await page.getByText('方案 Agent 在线', {exact:true}).waitFor({timeout:10000});
  for (const name of ['配置', '与 Agent 对话', '画布', '讲稿与发布']) assert.ok(await page.getByRole('region', {name}).or(page.getByRole('complementary', {name})).isVisible(), name);
  await page.getByText('This arch greets 300 guests.').waitFor();
  if (shots) await page.screenshot({path:`${shots}/bc-1440-deck.png`});

  // A single failed read (a slow home) puts up no notice; reads never overlap.
  failStudio = 1;
  await page.waitForFunction(() => true); await page.waitForTimeout(6500);
  assert.equal(failStudio, 0, 'the failing read happened');
  assert.equal(await page.getByRole('alert').count(), 0, 'one blip shows no reconnecting notice');
  assert.equal(overlap, 0, 'studio reads never overlap');

  // Company profile: an edit is saved with the revision it was read at.
  await page.getByRole('textbox').filter({hasText:'Full-service corporate events'}).fill('Full-service corporate events, Bay Area.');
  await page.getByRole('button', {name:'保存', exact:true}).click();
  await page.getByText('已保存，下一份方案就用新的').waitFor();
  assert.equal(config.company.positioning, 'Full-service corporate events, Bay Area.');

  // A slide edit goes to the session as one line.
  await page.getByRole('button', {name:'4', exact:true}).click();
  await page.getByPlaceholder('这一页改什么').fill('标题更短');
  await page.getByRole('button', {name:'发给 Agent'}).click();
  await page.getByText('已发给 Agent：改第 4 页').waitFor();
  assert.match(said.at(-1), /^改第 4 页：标题更短/);

  // The rendering bench: sorted by score, a batch, a pick, a hand-off to its slide.
  await page.getByRole('button', {name:'效果图', exact:true}).click();
  await page.getByText('本方案已花 $0.12 / 上限 $5').waitFor();
  await page.getByText('8.6 分').waitFor();
  await page.getByLabel('效果图要求').fill('gold and white balloon arch');
  await page.getByRole('button', {name:/bbbbbbbbbbb1|lobby/}).first().click();
  await page.getByRole('button', {name:'出一批'}).click();
  await page.getByText('已开始，每张约 20–90 秒').waitFor();
  const gen = calls.find(c => c.op === 'generate');
  assert.deepEqual([gen.proposal, gen.slide, gen.models, gen.n, gen.refs], ['P1', '4', ['gemini'], 2, ['bbbbbbbbbbb1']]);
  await page.getByText('生成中').first().waitFor();
  await page.getByRole('button', {name:'挑这张'}).first().click();
  assert.equal(calls.filter(c => c.op === 'pick').at(-1).id, 'aaaaaaaaaaa1');
  await page.getByRole('button', {name:'用到这一页'}).first().click();
  await page.waitForFunction(() => true);
  await page.getByText(/已请 Agent 把它用到第 4 页/).waitFor();
  assert.match(said.at(-1), /第 4 页用效果图 aaaaaaaaaaa1/);
  if (shots) await page.screenshot({path:`${shots}/bc-1440-images.png`});

  // A new proposal from a client card carries the profile and the card.
  await page.getByRole('button', {name:'客户', exact:true}).click();
  await page.getByRole('button', {name:/Google/}).click();
  await page.getByRole('button', {name:'用这个客户新建方案'}).click();
  await page.waitForFunction(() => location.search.includes('project=new-2'));
  assert.equal(opened[0].profile, 'bubble-cloud'); assert.equal(opened[0].client, 'c-google');
  assert.ok(new URL(page.url()).searchParams.get('profile') === 'bc', 'the profile stays in the address');

  // Desktop only: a narrow window says so instead of squeezing four columns.
  await page.setViewportSize({width:900, height:800});
  await page.getByText('方案工作台只做了电脑版').waitFor();
  console.log('PASS bubble-cloud: four columns, config save, slide edit, bench batch / pick / hand-off, new proposal, desktop only, one blip silent, no overlapping reads');
} finally { await browser.close(); }
