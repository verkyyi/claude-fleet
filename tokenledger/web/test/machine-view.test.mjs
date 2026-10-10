// One machine's page (claude-fleet#2796): the blocks made from
// /v1/nodes/<host>, how old each says it is, and the way in from the lists.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { FRESH, freshness, pageAllowed, PAGES } from '../dist/lib/shell.js';
import { useLocale } from '../dist/lib/i18n.js';
import { machineHref, backHref, detailModel, versionModel, loadModel, memModel, nextIndex, clientRedirect, HOUR } from '../dist/lib/machine-view.js';

useLocale('zh-CN');
const NOW = Date.parse('2026-10-10T01:00:00Z');
const ago = (s) => new Date(NOW - s * 1000).toISOString();

test('freshness: N 秒前, yellow past a minute, grey past five, 时间未知 without a time', () => {
  assert.deepEqual(freshness(ago(8), NOW), { cls: '', text: '8 秒前' });
  assert.equal(freshness(ago(FRESH.warn / 1000 + 5), NOW).cls, 'warn');
  const old = freshness(ago(FRESH.stale / 1000 + 60), NOW);
  assert.equal(old.cls, 'stale');
  assert.match(old.text, /数据旧了/);
  for (const none of [null, undefined, '', '0001-01-01T00:00:00Z', 'garbage']) {
    const f = freshness(none, NOW);
    assert.deepEqual(f, { cls: 'unknown', text: '时间未知' }, String(none));
  }
});

test('machineHref is the short name; from the admin list it says so; back goes there', () => {
  assert.equal(machineHref('macmini.tail435588.ts.net'), '/machines/macmini');
  assert.equal(machineHref('m4', true), '/machines/m4?from=nodes');
  assert.equal(backHref('?from=nodes'), '/nodes');
  assert.equal(backHref(''), '/machines');
  assert.equal(clientRedirect(false), '/connect');
  assert.equal(clientRedirect(true), '/admin/devices');
});

test('the machine page is allowed to whoever has either machine list, and is no menu item', () => {
  assert.ok(pageAllowed({ pages: ['mymachines'] }, 'machine'));
  assert.ok(pageAllowed({ pages: ['machines'] }, 'machine'));
  assert.ok(!pageAllowed({ pages: ['sessions'] }, 'machine'));
  assert.ok(!pageAllowed({ pages: ['machine'] }, 'machine'), 'only through a list');
  assert.ok(PAGES.find((p) => p.id === 'machine').within);
});

const detail = (over = {}) => ({
  at: ago(0),
  machine: { hostname: 'macmini.tail435588.ts.net', alias: '', status: 'online', role: 'host' },
  logins: [{ os_user: '24haowan', status: 'online', sessions: 2, last_heartbeat: ago(5) }],
  other_logins: 2, logins_at: ago(5),
  services: [{ name: 'sms', kind: 'service', login: '24haowan', state: 'running' }], services_at: ago(20),
  version: { agent: 'prod-341ae18', fleet: 'abc1234', want: 3, reached: 3, release: 'aaaaaaaa1', want_release: 'aaaaaaaa1', at: null },
  load: { now: 4, ncpu: 8, hist: [0.2, 0.4, 0.5], hist_step_sec: 300, at: null },
  mem: { used: 12 * 2 ** 30, total: 16 * 2 ** 30, pressure: 0.75, at: null },
  sessions: [{ machine_name: 'macmini', os_user: '24haowan', worker: { key: 'issue-1', state: 'working', born: 5 } }],
  sessions_at: ago(5),
  ...over,
});

test('detailModel: five blocks, each with its own age; an old node is 时间未知 and 节点太旧，未报', () => {
  const v = detailModel(detail(), NOW);
  assert.equal(v.name, 'macmini');
  assert.equal(v.label, 'macmini');
  assert.deepEqual(v.logins.map((r) => r.login), ['24haowan']);
  assert.equal(v.others, 2, '另有 2 个登录');
  assert.equal(v.services.length, 1);
  assert.equal(v.sessions.length, 1);
  assert.equal(v.loginsAt.text, '5 秒前');
  assert.equal(v.servicesAt.text, '20 秒前');
  assert.equal(v.sysAt.cls, 'unknown');
  assert.equal(v.versionAt.cls, 'unknown');
  assert.equal(v.version.reported, false);
  assert.equal(v.version.behind, false);
  assert.equal(v.load.perCore, 0.5);
  assert.equal(v.mem.pct, 75);
});

test('versionModel: components that lag are marked; the updater phase is read', () => {
  const v = versionModel({ agent: 'a', want: 4, reached: 3, components: { claude: '2.1.2', tmux: '3.7c' }, want_components: { claude: '2.1.3', tmux: '3.7c' }, phase: 'verify', at: ago(30) });
  assert.equal(v.behind, true);
  assert.equal(v.reported, true);
  assert.deepEqual(v.comps.map((c) => [c.name, c.off]), [['claude', true], ['tmux', false]]);
  assert.equal(v.phase, 'verify');
  assert.equal(versionModel(null).reached, null);
});

test('loadModel: the last hour of five-minute points; a shorter trend says when it starts', () => {
  const full = loadModel({ now: 2, ncpu: 4, hist: Array.from({ length: 24 }, (_, i) => i / 10) });
  assert.equal(full.hist.length, HOUR);
  assert.equal(full.shortMin, null);
  assert.equal(full.peak, 2.3);
  const short = loadModel({ now: 2, ncpu: 4, hist: [0.1, 0.2, 0.3], hist_step_sec: 300 });
  assert.equal(short.shortMin, 10);
  assert.equal(loadModel({}).noTrend, true);
  assert.equal(loadModel({ ncpu: 0 }).perCore, null);
  assert.equal(memModel({}).known, false);
});

test('j/k walk the rows and stop at the ends', () => {
  assert.equal(nextIndex(-1, 3, 'j'), 0);
  assert.equal(nextIndex(0, 3, 'j'), 1);
  assert.equal(nextIndex(2, 3, 'j'), 2);
  assert.equal(nextIndex(0, 3, 'k'), 0);
  assert.equal(nextIndex(2, 3, 'k'), 1);
  assert.equal(nextIndex(-1, 0, 'j'), -1);
});

test('both machine lists open a row into its page', () => {
  const read = (m) => readFileSync(new URL('../dist' + m, import.meta.url), 'utf8');
  for (const m of ['/machines.js', '/admin/nodes.js']) {
    const src = read(m);
    assert.match(src, /machineHref\(/, `${m} links each machine`);
    assert.match(src, /listNav\(ctx/, `${m} takes j/k + ↵`);
    assert.match(src, /data-href=/, `${m} marks its rows`);
  }
  assert.match(read('/machine.js'), /\/v1\/nodes\/' \+ encodeURIComponent/, 'the page reads only /v1/nodes/<host>');
});
