// 服务与定时任务 (claude-fleet#2526, EPIC #2524 C2): /v1/nodes' machines[].services
// as two tables — 常驻 / 定时 — a failed row red, a drawer with its log's last
// line; every word through t(), in both languages.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { FAILED, serviceRows, servicesSection, logDrawer, stateWord, svcClick } from '../dist/lib/services.js';
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
  assert.match(d, /fleet service logs daily-report -n 200/);
  assert.match(d, /在 mini2 上运行/);
  assert.match(logDrawer(rows[1], NOW), /还没有输出/);
  let opened = null;
  const ctx = { modal: (h) => { opened = h; } };
  const ev = (n) => ({ target: { closest: (sel) => (sel === 'tr[data-svc]' && n != null ? { dataset: { svc: String(n) } } : null) } });
  assert.equal(svcClick(ctx, ev(2), rows), true);
  assert.match(opened, /sms-watch/);
  assert.equal(svcClick(ctx, ev(null), rows), false);
});

test('every word through t(), every key in both dictionaries', () => {
  for (const f of ['lib/services.js', 'admin/nodes.js']) {
    const src = readFileSync(new URL('../dist/' + f, import.meta.url), 'utf8');
    for (const m of src.matchAll(/t\('(ui\.[\w.-]*\w)'/g)) assert.ok(m[1] in en && m[1] in zhCN, m[1]);
  }
  for (const k of Object.keys(en).filter((k) => k.startsWith('ui.svc.'))) assert.ok(k in zhCN, k);
  for (const s of ['service', 'task']) for (const p of ['ui.svc.title.', 'ui.svc.none.', 'ui.svc.kind.']) assert.ok(en[p + s] && zhCN[p + s], p + s);
  for (const st of ['running', 'stopped', 'down', 'failed', 'invalid', 'no_login', 'unknown']) assert.ok(en['ui.svc.st.' + st] && zhCN['ui.svc.st.' + st], st);
  const src = readFileSync(new URL('../dist/lib/services.js', import.meta.url), 'utf8');
  const markup = src.replace(/\/\/.*$/gm, '').match(/>[^<>${}`'"]*[A-Za-z]{3,}[^<>${}`'"]*</g) || [];
  assert.deepEqual(markup, [], 'bare words in markup');
});
