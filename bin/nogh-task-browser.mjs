// A9/A12: committed portal build, local API fixtures, desktop/mobile + keyboard.
// Since T769 the tasks live on the one 会话 page; since GR5E C9 /app/tasks?q=<code>
// opens that session (/app/s/<code>), and the 会话 page holds the rest.
// No native provider or deployed UI claim; screenshots are fixture evidence.
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { resolve, dirname, extname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const work = resolve(process.argv[2]);
const { chromium } = await import(pathToFileURL(resolve(work, 'browser/node_modules/playwright/index.mjs')).href);
const observed = '2026-10-16T06:20:00Z';
const base = { authority_version: 1, generation: 1, created_at: observed, updated_at: observed,
  state: 'running', requested_agent: 'codex', resolved_agent: 'codex', actual_agent: 'codex' };
const tasks = [
  { ...base, id: 'T1', title: 'Retained native, explicit success', outcome: 'succeeded', live: { state: 'working' },
    worker_id: 'fixture-fleet/fixture-session', pr: 'fixture/repo#77', pr_state: 'waiting' },
  { ...base, id: 'T5', title: 'Completed retained idle', outcome: 'succeeded', live: { state: 'idle' },
    worker_id: 'fixture-fleet/idle-session' },
  { ...base, id: 'T2', title: 'Provider mismatch', actual_agent: 'claude' },
  { id: 'T3', title: 'Legacy absence is unknown', state: 'open', created_at: observed },
  { ...base, id: 'T4', title: 'Merged PR, still working', pr: 'fixture/repo#78', pr_state: 'merged' },
];
let offline = false;
const requests = [];
const origin = 'http://127.0.0.1:9876';
// T1's session is still up: its record's result stands beside it (T644 C4)
const sessions = { sessions: [{ machine_name: 'fixture-mac', worker: { worker_id: 'fixture-fleet/fixture-session', key: 'task-t1',
  title: 'Retained native, explicit success', state: 'working', born: Date.parse(observed) / 1000 } },
  { machine_name: 'fixture-mac', worker: { worker_id: 'fixture-fleet/idle-session', key: 'task-t5',
    title: 'Completed retained idle', state: 'idle', born: Date.parse(observed) / 1000 } }] };
async function fixture(route) {
  const req = route.request();
  const url = new URL(req.url());
  assert.equal(url.origin, origin, 'portal attempted another origin');
  const path = url.pathname;
  requests.push({ method: req.method(), path });
  if (path.startsWith('/v1/')) {
    if (path === '/v1/fleet/tasks' && offline) { await route.fulfill({ status: 503, json: {} }); return; }
    // no push channel here: the page's own 10 s poll stands in (sessions.ts)
    if (path === '/v1/fleet/stream') { await route.fulfill({ status: 503, json: {} }); return; }
    const data = path === '/v1/fleet/tasks' ? { tasks, observed_at: observed }
      : path === '/v1/fleet/sessions' ? (url.searchParams.get('state') === 'ended' ? { sessions: [] } : sessions)
      : path === '/v1/me' ? { name: 'Fixture', login: 'fixture', role: 'user' } : {};
    await route.fulfill({ json: data }); return;
  }
  const dist = resolve(root, 'extras/web-console/dist/app');
  const asset = path.startsWith('/app/assets/') ? resolve(dist, path.slice('/app/'.length)) : resolve(dist, 'index.html');
  if (!asset.startsWith(dist + '/')) { await route.fulfill({ status: 404 }); return; }
  try {
    const body = await readFile(asset);
    const contentType = ({ '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html', '.woff2': 'font/woff2' })[extname(asset)] || 'application/octet-stream';
    await route.fulfill({ body, contentType });
  } catch { await route.fulfill({ status: 404 }); }
}
let browser;
const evidence = [];
try {
  browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  for (const viewport of [{ width: 1280, height: 900 }, { width: 390, height: 844 }]) {
    offline = false;
    // Fulfil the committed assets/API before network resolution. Chromium's
    // resolver otherwise probes Google's IPv6 DNS address even for loopback;
    // offline browser routing avoids that unrelated background probe entirely.
    const page = await browser.newPage({ viewport, locale: 'en-US', offline: true });
    await page.route('**/*', fixture);
    page.setDefaultTimeout(8000);
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    // the old 任务 address with a code opens that session (GR5E C9): its
    // workspace (C4), 详情 in a drawer: native terminal access is a copied
    // command; there is no web terminal backup
    await page.goto(`${origin}/app/tasks?q=T1&lang=en`);
    await page.waitForURL(/\/app\/s\/T1\?lang=en$/);
    await page.getByRole('button', { name: 'Details' }).first().click();
    const one = page.getByRole('dialog');
    await one.getByText(/Waiting for GitHub/).first().waitFor();
    await one.getByText(/^fleet open /).first().waitFor();
    assert.equal(await one.getByRole('button', { name: /^Web terminal \(backup\)$/ }).count(), 0);
    assert.equal(await page.locator('.xterm-helper-textarea').count(), 0);
    assert.equal(await page.locator('[data-workspace=chat]').count(), 1);
    await page.keyboard.press('Escape');
    // 会话's full page holds the rest
    await page.goto(`${origin}/app/sessions?lang=en`);
    const row = id => page.locator(`[data-task-id="${id}"]`);
    // the details: beside the list on a computer, a sheet on a phone
    const detail = viewport.width >= 1024 ? page.locator('aside') : page.getByRole('dialog');
    await row('T1').waitFor();
    assert.match(await row('T1').innerText(), /Working/);
    assert.doesNotMatch(await row('T1').innerText(), /Completed/);
    assert.match(await row('T5').innerText(), /Completed · retained/);
    // A committed result remains true while the retained session takes new work.
    await row('T1').click();
    await detail.locator('summary').click();
    assert.match(await detail.innerText(), /Task state\s*Completed/);
    assert.match(await detail.innerText(), /Session observation\s*Working/);
    if (viewport.width < 1024) await page.keyboard.press('Escape');
    assert.match(await row('T2').innerText(), /Agent mismatch/);
    assert.match(await row('T3').innerText(), /Unknown/);
    await row('T4').focus();
    await page.keyboard.press('Enter');
    await detail.locator('h2:visible', { hasText: 'Merged PR, still working' }).waitFor();
    assert.match(await detail.innerText(), /PR merged/);
    await detail.locator('summary').focus();
    await page.keyboard.press('Enter');
    assert.equal(await detail.locator('details').getAttribute('open'), '');
    assert.match(await detail.innerText(), /Task state\s*Working/);
    assert.match(await detail.innerText(), /Verified actual agent/);
    if (viewport.width < 1024) await page.keyboard.press('Escape');
    offline = true;
    await page.getByRole('button', { name: 'Retry read', exact: true }).waitFor({ timeout: 15000 });
    assert.match(await page.locator('main').innerText(), /Stale information/);
    assert.equal(await page.locator('time').getAttribute('datetime'), observed);
    assert.match(await row('T1').innerText(), /Working/);
    assert.doesNotMatch(await row('T1').innerText(), /Completed/);
    // the session list is the one way in (GR5E C2): the mark leads back to it;
    // a phone's screen other than the list wears a back bar instead (GR5E C7)
    if (viewport.width >= 768) assert.ok(await page.locator('a[href="/app"]:visible').count() > 0, 'existing navigation missing');
    else assert.ok(await page.locator('[data-phone-bar="back"] button[aria-label="Back"]:visible').count() > 0, 'phone back bar missing');
    assert.equal(await page.locator('a[href="/app/tasks"]').count(), 0, 'a separate Tasks page is still linked');
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), 'horizontal overflow');
    await page.screenshot({ path: resolve(work, `evidence/tasks-${viewport.width}.png`), fullPage: true });
    evidence.push({ viewport, observed_at: observed, retained_result: 'succeeded', pr: 'waiting', keyboard: 'PASS', errors });
    assert.deepEqual(errors, []);
    await page.close();
  }
  assert.ok(requests.every(r => r.method === 'GET'), 'view wrote task state');
  await writeFile(resolve(work, 'evidence/browser-snapshots.json'), JSON.stringify({ fixture: true, evidence, requests }, null, 2));
  console.log('PASS committed portal: one 会话 list, /tasks?q= opens that session, desktop/mobile details, keyboard, stale confirmed timestamp, honest outcome and PR separation');
} finally {
  if (browser) await browser.close();
}
