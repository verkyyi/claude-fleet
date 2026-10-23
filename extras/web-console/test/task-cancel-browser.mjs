// Real app bundle, controlled HTTP answers; no production writes. Requires the
// browser-transport Playwright install and a built web-console/dist/app.
// node test/task-cancel-browser.mjs
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { chromium } from '../../browser-transport/node_modules/playwright/index.mjs';

const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_BIN ? { executablePath: process.env.CHROME_BIN } : {}) });
const origin = 'http://fleet-cancel.invalid';
const fid = '00000000-0000-4000-8000-000000000900';
const worker = `00000000-0000-4000-8000-000000000001/${fid}`;

async function scenario({ status = 200, readonly = false, pending = true, tag = 'queued', live = false, controlled = false } = {}) {
  const context = await browser.newContext({ viewport: { width: 1280, height: 850 } });
  const page = await context.newPage();
  const writes = [];
  let cancelled = false, reads = 0;
  await page.route('**/*', async (route) => {
    const req = route.request(), u = new URL(req.url());
    if (!u.pathname.startsWith('/v1/')) {
      const rel = u.pathname.replace(/^\/app\/?/, '');
      const file = new URL(`../dist/app/${rel.startsWith('assets/') || rel === 'manifest.webmanifest' ? rel : 'index.html'}`, import.meta.url);
      const contentType = file.pathname.endsWith('.js') ? 'application/javascript' : file.pathname.endsWith('.css') ? 'text/css' : 'text/html';
      return route.fulfill({ body: await readFile(file), contentType });
    }
    let body = {};
    if (u.pathname === '/v1/me') body = { role: 'user', person: 'test-owner', name: 'Test', pages: ['app'], entry: true, read_only: readonly };
    if (u.pathname === '/v1/chat/home') body = { machine: 'test', login: 'test', state: 'ok', unified: false };
    if (u.pathname === '/v1/fleet/tasks') body = { tasks: [] };
    if (u.pathname === '/v1/fleet/tasks/T900') body = { id: 'T900', fid, ...(controlled ? { execution_endpoint: 'fixture-node' } : {}) };
    if (u.pathname === '/v1/fleet/sessions') {
      reads++;
      body = { sessions: live ? [{ machine_name: 'test', worker: { worker_id: worker, key: 'scratch-900', state: 'working', title: 'Controlled task' } }] : [],
        board: { count: 1, groups: {}, gone_days: 7, digest: String(reads), rows: [{ id: fid, task_id: fid, task: 'T900', title: 'Controlled task',
          group: 'queue', tag: cancelled ? 'idle' : tag, pending_start: cancelled ? false : pending,
          ...(live ? { worker_id: worker } : {}), words: ['待启动', 'Waiting to start'], at: 1 }] } };
    }
    if (req.method() === 'POST') {
      writes.push({ path: u.pathname, body: JSON.parse(req.postData()) });
      if (u.pathname === `/v1/fleet/tasks/${fid}/cancel`) {
        if (status === 200) cancelled = true;
        return route.fulfill({ status, json: status === 200 ? { cancelled: true } : { error: status === 409 ? 'session_already_started' : 'controlled_failure' } });
      }
      if (u.pathname === '/v1/fleet/tasks/T900/stop') return route.fulfill({ status: 202, json: { stop_requested: true, execution_exit_confirmed: false, operation: { operation_id: '00000000-0000-4000-8000-000000000901', action: 'worker_stop' } } });
      body = { status: 'accepted' };
    }
    return route.fulfill({ json: body });
  });
  await page.goto(`${origin}/app/s/${fid}`);
  await page.locator('[data-workspace=chat]').waitFor();
  return { page, context, writes, reads: () => reads };
}

try {
  for (const opts of [{ pending: false }, { pending: undefined }, { tag: 'idle' }, { tag: 'ended' }, { live: true }]) {
    // Explicitly cover absence with null; the scenario's default is true.
    const s = await scenario({ ...opts, ...(opts.pending === undefined && 'pending' in opts ? { pending: null } : {}) });
    assert.equal(await s.page.getByRole('button', { name: /^(取消启动|Cancel start)$/ }).count(), 0);
    if (opts.live) {
      await s.page.getByRole('button', { name: /^(停止|Stop)$/ }).click();
      await s.page.waitForFunction(() => document.querySelector('[data-sonner-toast]'));
      assert.equal(s.writes[0]?.path, '/v1/fleet/write');
      assert.equal(s.writes[0]?.body.tool, 'worker_stop');
    }
    assert.equal(s.writes.filter((w) => w.path.endsWith('/cancel')).length, 0);
    await s.context.close();
  }
  const controlled = await scenario({ live: true, pending: false, controlled: true });
  await controlled.page.getByRole('button', { name: /^(停止|Stop)$/ }).click();
  await controlled.page.waitForFunction(() => document.querySelector('[data-sonner-toast]'));
  assert.equal(controlled.writes.length, 1);
  assert.equal(controlled.writes[0].path, '/v1/fleet/tasks/T900/stop');
  assert.ok(controlled.writes[0].body.idempotency_key);
  await controlled.context.close();
  const ro = await scenario({ readonly: true });
  assert.equal(await ro.page.getByRole('button', { name: /^(取消启动|Cancel start)$/ }).isDisabled(), true);
  assert.equal(ro.writes.length, 0);
  await ro.context.close();

  for (const status of [200, 503, 409]) {
    const s = await scenario({ status });
    const cancel = s.page.getByRole('button', { name: /^(取消启动|Cancel start)$/ });
    const before = s.reads();
    await cancel.click();
    if (status === 200) {
      await s.page.getByText(/^(已撤销启动请求。|Start request cancelled\.)$/).waitFor();
      await cancel.waitFor({ state: 'detached' });
      assert.ok(s.reads() > before, 'successful cancellation refreshes the board');
    } else {
      const alert = s.page.getByRole('alert');
      await alert.waitFor();
      assert.match(await alert.innerText(), status === 409 ? /session_already_started/ : /controlled_failure/);
      assert.equal(await cancel.count(), 1, 'failure retains the pending task/action');
      if (status === 409) {
        assert.match(await alert.innerText(), /刷新|Refresh/);
        assert.ok(s.reads() > before, 'a start race refreshes the board');
      }
    }
    assert.deepEqual(s.writes, [{ path: `/v1/fleet/tasks/${fid}/cancel`, body: {} }]);
    assert.equal(await s.page.locator('[data-status-slot]').count(), 1, 'one status slot remains');
    await s.context.close();
  }
  console.log('PASS pending cancellation: real request only, RO disabled, successful refresh, failure retained, 409 guidance, active worker_stop unchanged');
} finally { await browser.close(); }
