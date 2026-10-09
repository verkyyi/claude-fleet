// 服务与定时任务 (claude-fleet#2526, EPIC #2524 C2): /v1/nodes' machines[].services
// as two tables — 常驻 / 定时 — a failed row red, a drawer with its log's last
// line; every word through t(), in both languages.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { FAILED, STATES, serviceRows, servicesSection, logDrawer, stateWord, svcClick, actionsFor, svcRequest, svcAct, svcDrawerClick } from '../dist/lib/services.js';
import { useLocale } from '../dist/lib/i18n.js';
import { en } from '../dist/lib/i18n/en.js';
import { zhCN } from '../dist/lib/i18n/zh-CN.js';

const NOW = Date.parse('2026-10-09T07:05:00Z');
const SNAP = {
  machines: [
    { hostname: 'mini2.tail.ts.net', alias: 'mini2', services_at: '2026-10-09T07:04:30Z', services: [
      { name: 'sms-watch', kind: 'service', login: 'verky', state: 'running', started_at: '2026-10-09T06:05:00Z', last_log_line: 'sent 3 texts' },
      { name: 'daily-report', kind: 'task', login: 'verky', state: 'failed', last_run: '2026-10-09T07:00:00Z', next_run: '2026-10-10T07:00:00Z', last_rc: 1, last_log_line: 'give up: skill <b>not</b> found' },
      { name: 'flappy', kind: 'service', login: 'verky', state: 'down', last_rc: 2, next_run: '2026-10-09T07:05:30Z', restarts: 4 },
    ] },
    { hostname: 'm4', status: 'online' },
  ],
};

test('rows: every entry, the failed set, the machine label', () => {
  assert.deepEqual(FAILED, ['down', 'failed', 'invalid', 'no_login']);
  const rows = serviceRows(SNAP);
  assert.deepEqual(rows.map((r) => [r.machine, r.name, r.kind, r.failed]), [
    ['mini2', 'daily-report', 'task', true], ['mini2', 'flappy', 'service', true], ['mini2', 'sms-watch', 'service', false]]);
  assert.equal(rows[2].lastRun, '2026-10-09T06:05:00Z', 'a service last ran when it started');
  assert.deepEqual(serviceRows({ machines: [{ hostname: 'x' }] }), []);
  assert.deepEqual(serviceRows(null), []);
});

test('tables: 常驻 and 定时, failed red, the count says how many failed', () => {
  useLocale('zh-CN');
  const rows = serviceRows(SNAP);
  const html = servicesSection(rows, NOW);
  assert.match(html, /id="svc-service"[\s\S]*常驻服务[\s\S]*1 项失败 · 共 2 项/);
  assert.match(html, /id="svc-task"[\s\S]*定时任务[\s\S]*1 项失败 · 共 1 项/);
  assert.match(html, /<tr data-svc="0" style="cursor:pointer;color:var\(--bad\)">[\s\S]*daily-report[\s\S]*失败/);
  assert.match(html, /已退出·待重启（rc=2）/);
  assert.match(html, /<tr data-svc="2" style="cursor:pointer">[\s\S]*运行中[\s\S]*sent 3 texts/);
  assert.match(html, /give up: skill &lt;b&gt;not&lt;\/b&gt; found/, 'a log line is escaped');
  assert.ok(!html.includes('<b>not</b>'));
  const none = servicesSection([], NOW);
  assert.match(none, /没有登记的常驻服务/);
  assert.match(none, /没有登记的定时任务/);
  useLocale('en');
  assert.match(servicesSection(rows, NOW), /Scheduled tasks[\s\S]*1 failed of 1/);
  assert.equal(stateWord(rows[1]), 'Exited · restarting (rc=2)');
});

test('drawer: the row, its last line, the command for the whole log', () => {
  useLocale('zh-CN');
  const rows = serviceRows(SNAP);
  const d = logDrawer(rows[0], NOW);
  assert.match(d, /<h3>daily-report<\/h3>/);
  assert.match(d, /give up: skill &lt;b&gt;not&lt;\/b&gt; found/);
  assert.match(d, /fleet task logs daily-report -n 200/, 'a task\'s log is fleet task logs (#2529)');
  assert.ok(!d.includes('重启次数'), 'a task has no restarts');
  const f = logDrawer(rows[1], NOW);
  assert.match(f, /fleet service logs flappy -n 200/);
  assert.match(f, /重启次数<\/dt><dd>4</);
  assert.match(d, /在 mini2 上运行/);
  assert.match(logDrawer(rows[1], NOW), /还没有输出/);
  let opened = null;
  const ctx = { drawer: (h) => { opened = h; } };
  const ev = (n) => ({ target: { closest: (sel) => (sel === 'tr[data-svc]' && n != null ? { dataset: { svc: String(n) } } : null) } });
  assert.equal(svcClick(ctx, ev(2), rows), true);
  assert.match(opened, /sms-watch/);
  assert.equal(svcClick(ctx, ev(null), rows), false);
});

test('every word through t(), every key in both dictionaries', () => {
  for (const f of ['lib/services.js', 'admin/nodes.js', 'machines.js']) {
    const src = readFileSync(new URL('../dist/' + f, import.meta.url), 'utf8');
    for (const m of src.matchAll(/t\('(ui\.[\w.-]*\w)'/g)) assert.ok(m[1] in en && m[1] in zhCN, m[1]);
  }
  for (const k of Object.keys(en).filter((k) => k.startsWith('ui.svc.'))) assert.ok(k in zhCN, k);
  for (const s of ['service', 'task']) for (const p of ['ui.svc.title.', 'ui.svc.none.', 'ui.svc.kind.']) assert.ok(en[p + s] && zhCN[p + s], p + s);
  for (const st of [...STATES, 'unknown']) assert.ok(en['ui.svc.st.' + st] && zhCN['ui.svc.st.' + st], st);
  const src = readFileSync(new URL('../dist/lib/services.js', import.meta.url), 'utf8');
  const markup = src.replace(/\/\/.*$/gm, '').match(/>[^<>${}`'"]*[A-Za-z]{3,}[^<>${}`'"]*</g) || [];
  assert.deepEqual(markup, [], 'bare words in markup');
});

test('我的机器 shows both tables under the viewer\'s machines, a row opens its drawer', () => {
  const src = readFileSync(new URL('../dist/machines.js', import.meta.url), 'utf8');
  assert.match(src, /serviceRows\(snap\)/);
  assert.match(src, /servicesSection\(svcs\)/);
  assert.match(src, /svcClick\(ctx, e, S\.svcs\)/);
});

// claude-fleet#2527 (C3): the drawer's buttons post the hub's service_control on
// the row's (machine, login, name) — 停 · 起 · 重启 · 现在跑一次 · 改计划.
test('buttons: which ones a row gets, what each posts, what it says', async () => {
  useLocale('zh-CN');
  const rows = serviceRows(SNAP);          // daily-report (task, failed) · flappy (down) · sms-watch (running)
  assert.deepEqual(actionsFor(rows[0]), ['run_now', 'set_schedule', 'stop']);
  assert.deepEqual(actionsFor(rows[2]), ['restart', 'stop']);
  assert.deepEqual(actionsFor({ ...rows[2], state: 'stopped' }), ['start']);
  assert.deepEqual(actionsFor({ ...rows[2], state: 'invalid' }), []);
  const d = logDrawer(rows[0], NOW);
  assert.match(d, /<div class="modal-f"><button class="btn" data-svc-act="run_now">现在跑一次<\/button><button class="btn" data-svc-act="set_schedule">改计划<\/button><button class="btn danger" data-svc-act="stop">停<\/button>/);
  assert.match(d, /data-svc-sched hidden[\s\S]*data-svc-at[\s\S]*data-svc-tz[\s\S]*data-svc-act="save_schedule">保存/);
  assert.ok(!logDrawer(rows[2], NOW).includes('data-svc-sched'), 'a service has no schedule form');

  const req = svcRequest(rows[0], 'run_now');
  assert.deepEqual({ ...req, idempotency_key: 'k' },
    { machine: 'mini2.tail.ts.net', login: 'verky', name: 'daily-report', action: 'run_now', idempotency_key: 'k' });
  assert.match(req.idempotency_key, /^[A-Za-z0-9_.:-]{1,128}$/, 'the hub\'s idempotency key shape');

  const posted = [], said = [];
  let closed = 0;
  const ctx = { api: async (url, o) => { posted.push([url, o.json]); return answer; }, toast: (m) => said.push(m), close: () => { closed++; } };
  let answer = { status: 'succeeded', result: { how: 'service run' } };
  await svcAct(ctx, rows[0], 'run_now');
  assert.equal(posted[0][0], '/v1/fleet/service_control');
  assert.equal(posted[0][1].action, 'run_now');
  assert.match(said[0], /daily-report 现在跑一次 —— 一分钟内会话出现/);
  answer = { status: 'failed', result: { error: { code: 'REFUSED', message: 'alpha/daily is stopped' } } };
  await svcAct(ctx, rows[0], 'stop');
  assert.match(said[1], /停：被拒绝 — alpha\/daily is stopped/);
  ctx.api = async () => { throw new Error('only your own services'); };
  await svcAct(ctx, rows[2], 'restart');
  assert.match(said[2], /重启：被拒绝 — only your own services/);
  assert.equal(closed, 3);

  // the drawer's clicks: 改计划 opens the form, 保存 checks HH:MM then posts
  ctx.api = async (url, o) => { posted.push([url, o.json]); return { status: 'succeeded' }; };
  const form = { hidden: true };
  const fields = { '[data-svc-sched]': form, '[data-svc-at]': { value: ' 7pm ' }, '[data-svc-tz]': { value: 'Asia/Shanghai' } };
  const root = { querySelector: (s) => fields[s] || null };
  const click = (act) => ({ target: { closest: (sel) => (sel === '[data-svc-act]' ? { dataset: { svcAct: act } } : null) } });
  assert.equal(svcDrawerClick(ctx, click('set_schedule'), rows[0], root), true);
  assert.equal(form.hidden, false);
  const n = posted.length;
  svcDrawerClick(ctx, click('save_schedule'), rows[0], root);
  assert.equal(posted.length, n, 'a bad time was posted');
  assert.match(said[said.length - 1], /HH:MM/);
  fields['[data-svc-at]'].value = '07:30';
  svcDrawerClick(ctx, click('save_schedule'), rows[0], root);
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual([posted.at(-1)[1].action, posted.at(-1)[1].at, posted.at(-1)[1].tz], ['set_schedule', '07:30', 'Asia/Shanghai']);
  assert.equal(svcDrawerClick(ctx, { target: { closest: () => null } }, rows[0], root), false);
});
