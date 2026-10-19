// A9/A12: committed portal build, local API fixtures, desktop/mobile + keyboard.
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
  { ...base, id: 'T2', title: 'Provider mismatch', actual_agent: 'claude' },
  { id: 'T3', title: 'Legacy absence is unknown', state: 'open', created_at: observed },
  { ...base, id: 'T4', title: 'Merged PR, still working', pr: 'fixture/repo#78', pr_state: 'merged' },
];
let offline = false;
const requests = [];
const origin = 'http://127.0.0.1:9876';
async function fixture(route) {
  const req = route.request();
  const url = new URL(req.url());
  assert.equal(url.origin, origin, 'portal attempted another origin');
  const path = url.pathname;
  requests.push({ method: req.method(), path });
  if (path.startsWith('/v1/')) {
    if (path === '/v1/fleet/tasks' && offline) { await route.fulfill({ status: 503, json: {} }); return; }
    const data = path === '/v1/fleet/tasks' ? { tasks, observed_at: observed }
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
    await page.goto(`${origin}/app/tasks?lang=en`);
    const card = id => page.locator(`[data-task-id="${id}"]`);
    await card('T1').waitFor();
    assert.match(await card('T1').innerText(), /Completed/);
    assert.match(await card('T1').innerText(), /Waiting for GitHub/);
    assert.match(await card('T2').innerText(), /Agent mismatch/);
    assert.match(await card('T3').innerText(), /Unknown/);
    assert.match(await card('T4').innerText(), /Working[\s\S]*PR merged/);
    assert.match(await card('T1').getByRole('link', { name: /Session/ }).getAttribute('href'), /terminal/);
    await card('T1').locator('summary').focus();
    await page.keyboard.press('Enter');
    assert.equal(await card('T1').locator('details').getAttribute('open'), '');
    assert.match(await card('T1').innerText(), /Verified actual agent/);
    offline = true;
    await page.getByRole('button', { name: 'Refresh', exact: true }).click();
    await page.getByRole('button', { name: 'Retry read', exact: true }).waitFor();
    assert.match(await page.locator('main').innerText(), /Stale information/);
    assert.equal(await page.locator('time').getAttribute('datetime'), observed);
    assert.match(await card('T1').innerText(), /Completed/);
    assert.ok(await page.locator('a[href="/app/tasks"]:visible').count() > 0, 'existing navigation missing');
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), 'horizontal overflow');
    await page.screenshot({ path: resolve(work, `evidence/tasks-${viewport.width}.png`), fullPage: true });
    evidence.push({ viewport, observed_at: observed, retained_result: 'succeeded', pr: 'waiting', keyboard: 'PASS', errors });
    assert.deepEqual(errors, []);
    await page.close();
  }
  assert.ok(requests.every(r => r.method === 'GET'), 'view wrote task state');
  await writeFile(resolve(work, 'evidence/browser-snapshots.json'), JSON.stringify({ fixture: true, evidence, requests }, null, 2));
  console.log('PASS committed portal: desktop/mobile navigation, keyboard details, stale confirmed timestamp, honest outcome and PR separation');
} finally {
  if (browser) await browser.close();
}
