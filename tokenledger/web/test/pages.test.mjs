// The four everyday pages' computations (claude-fleet#1989): Overview's days,
// bars and attention list, Sessions' rows, filters and empty states, Config's
// item lists — and a source check that no page asks the hub for someone
// else's rows.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  dayKeys, dayTokens, stack, delta, bars, areaChart, niceMax,
  sessionRows, counts, filterRows, running, attention, stateOf,
  activeDevices, clientDevices, whyNotClient, scopeOf, deviceHistory, looksLikeKey, bundleItems, parseImport, quotaTable, quotaState, myMachines, takesOf, usageDays, usageBudget,
} from '../dist/lib/pages.js';
import { askOf, askLine } from '../dist/lib/pages.js';
import { useLocale } from '../dist/lib/i18n.js';
import { en } from '../dist/lib/i18n/en.js';

const NOW = Date.parse('2026-10-06T15:00:00Z');

test('14 UTC days end today, oldest first', () => {
  const k = dayKeys(NOW, 14);
  assert.equal(k.length, 14);
  assert.equal(k[0], '2026-09-23');
  assert.equal(k[13], '2026-10-06');
});

test('a sparse series fills absent days with 0', () => {
  const k = dayKeys(NOW, 3);
  assert.deepEqual(dayTokens(k, [{ key: '2026-10-05', tokens: 7 }, { key: '2026-09-01', tokens: 99 }]), [0, 7, 0]);
  assert.deepEqual(dayTokens(k, undefined), [0, 0, 0]);
  assert.deepEqual(stack([1, 2], [3]), [[1, 3], [2, 0]]);
});

test('delta: percent change, nothing when there is no earlier window', () => {
  assert.deepEqual(delta(114, 100, 'ui.ov.vsYesterday'), { text: '+14% vs yesterday', down: false });
  assert.deepEqual(delta(50, 100, 'ui.ov.vsLastWeek'), { text: '-50% vs last week', down: true });
  assert.deepEqual(delta(5, 0, 'ui.ov.vsYesterday'), { text: '', down: false });
  try {
    useLocale('zh-CN');
    assert.equal(delta(114, 100, 'ui.ov.vsYesterday').text, '比昨天 +14%');
    assert.equal(stateOf('waiting').label, '在等你回答');
  } finally { useLocale('en'); }
});

test('bars merge one machine across endpoints, largest first, tail folded', () => {
  const rows = bars([{ label: 'm4', tokens: 5 }, { label: 'mini2', tokens: 9 }, { label: 'm4', tokens: 6 }, { label: 'zero', tokens: 0 }]);
  assert.deepEqual(rows, [['m4', 11], ['mini2', 9]]);
  const many = bars(Array.from({ length: 9 }, (_, i) => ({ label: 'h' + i, tokens: 10 - i })), 4);
  assert.equal(many.length, 4);
  assert.deepEqual(many[3], ['other', 7 + 6 + 5 + 4 + 3 + 2]);
  assert.deepEqual(bars(null), []);
});

test('the area chart scales to a nice top and labels its days', () => {
  assert.equal(niceMax(0), 1);
  assert.equal(niceMax(171e6), 200e6);
  assert.equal(niceMax(31), 50);
  const k = dayKeys(NOW, 14);
  const svg = areaChart(stack(k.map(() => 1e6), k.map(() => 5e5)), k);
  assert.match(svg, /role="img"/);
  assert.match(svg, /Oct 6/);
  assert.match(svg, /21M in all/);
  assert.equal(areaChart([], []), '');
});

const FS = {
  sessions: [
    { machine_name: 'mini2', os_user: 'verk', availability: 'online', worker: { worker_id: 'w1', key: 'issue-1950', repo: 'verkyyi/claude-fleet', title: 'Team settings', state: 'working', worktree: '/wt/1950', born: 200, agent: 'claude' } },
    { machine_name: 'm4', os_user: 'verk', availability: 'lost', worker: { worker_id: 'w2', key: 'issue-1953', title: 'Doctor row', state: 'waiting', worktree: '/wt/1953', born: 300 } },
    { machine_name: 'm4', os_user: 'verk', availability: 'online', worker: { worker_id: 'w3', key: 'scratch-6', state: 'idle', born: 100 } },
    { machine_name: 'm4', os_user: 'verk', availability: 'online', worker: { worker_id: 'w4', key: 'issue-9', state: 'blocked', born: 50 } },
  ],
  nodes: [{ machine_name: 'mini2', availability: 'online' }, { machine_name: 'm1', availability: 'lost' }, { machine_name: 'm2', availability: 'maintenance' }],
};
const LIVE = { sessions: [{ worktree: '/wt/1950', context_used_pct: 41.2, model: 'claude-opus-5-5', account: 'Max · A' }, { cwd: '/wt/1953', context_unknown: true, context_used_pct: 0 }] };

test('rows join live context and model by worktree, newest first', () => {
  const rows = sessionRows(FS, LIVE);
  assert.deepEqual(rows.map((r) => r.key), ['issue-1953', 'issue-1950', 'scratch-6', 'issue-9']);
  const w = rows.find((r) => r.key === 'issue-1950');
  assert.equal(w.ctx, 41.2);
  assert.equal(w.model, 'claude-opus-5-5');
  assert.equal(w.account, 'Max · A');
  assert.equal(rows.find((r) => r.key === 'issue-1953').ctx, null, 'unknown context is a dash, not 0%');
  assert.equal(rows.find((r) => r.key === 'issue-1953').availability, 'lost');
});

test('a worker that waits on you says what it asks, in its own words (claude-fleet#2538)', () => {
  const fs = { sessions: [
    { machine_name: 'm5', availability: 'online', worker: { worker_id: 'a', key: 'issue-1', state: 'needs', needs: 'ask', detail: 'hook words', status_kind: 'permission', status_msg: 'Bash: git push origin x', born: 3 } },
    { machine_name: 'm5', availability: 'online', worker: { worker_id: 'b', key: 'issue-2', state: 'needs', needs: 'ask', detail: '放在 m5 还是 m4？', born: 2 } },
    { machine_name: 'm5', availability: 'online', worker: { worker_id: 'c', key: 'issue-3', state: 'working', status_msg: 'Running tests', born: 1 } },
  ] };
  const rows = sessionRows(fs, null);
  const by = (k) => rows.find((r) => r.key === k);
  assert.equal(by('issue-1').state, 'waiting', 'a fleet worker\'s needs is a waiting row');
  assert.deepEqual(by('issue-1').ask, { kind: 'permission', msg: 'Bash: git push origin x' }, 'the agent\'s own report wins');
  assert.deepEqual(by('issue-2').ask, { kind: 'question', msg: '放在 m5 还是 m4？' }, 'else the needs subtype + detail');
  assert.equal(by('issue-3').ask, null, 'a working session asks nothing');
  assert.equal(askLine(by('issue-1').ask), 'permission: Bash: git push origin x');
  assert.equal(askLine(by('issue-1').ask, 8), 'permission: Bash: gi…');
  assert.equal(askLine(null), '');
  assert.equal(askOf({ status_msg: 'x'.repeat(300) }, 'waiting').msg.length, 200);
  assert.match(attention(rows, [], false)[0].sub, /^permission: Bash: git push origin x · /);
  try { useLocale('zh-CN'); assert.equal(askLine(by('issue-2').ask), '问题：放在 m5 还是 m4？'); } finally { useLocale('en'); }
});

test('an empty or failed list is no rows, not a crash', () => {
  assert.deepEqual(sessionRows(null, null), []);
  assert.deepEqual(sessionRows({ sessions: [] }, undefined), []);
  assert.deepEqual(counts([]), { all: 0, working: 0, waiting: 0, idle: 0 });
  assert.deepEqual(attention([], [], true), []);
});

test('filters count by group and search across key, repo, title, machine', () => {
  const rows = sessionRows(FS, LIVE);
  assert.deepEqual(counts(rows), { all: 4, working: 1, waiting: 2, idle: 1 });
  assert.deepEqual(filterRows(rows, 'waiting', '').map((r) => r.key), ['issue-1953', 'issue-9']);
  assert.deepEqual(filterRows(rows, 'all', 'TEAM').map((r) => r.key), ['issue-1950']);
  assert.deepEqual(filterRows(rows, 'all', 'm4').length, 3);
  assert.deepEqual(filterRows(rows, 'idle', 'nope'), []);
  assert.equal(running(rows).length, 3);
  assert.equal(stateOf('weird').label, 'Unknown');
});

test('attention: sessions waiting for everyone, machines only for an admin', () => {
  const rows = sessionRows(FS, LIVE);
  const user = attention(rows, FS.nodes, false);
  assert.deepEqual(user.map((a) => a.title), ['issue-1953 needs an answer', 'issue-9 is blocked']);
  const admin = attention(rows, FS.nodes, true);
  assert.deepEqual(admin.slice(2).map((a) => a.title), ['m1 is lost', 'm2 is in maintenance']);
  try { useLocale('zh-CN'); assert.equal(attention(rows, FS.nodes, true)[2].title, 'm1 失联了'); } finally { useLocale('en'); }
});

test('devices: active ones, and the hand-issue key check', () => {
  assert.equal(activeDevices([{ fingerprint: 'a' }, { fingerprint: 'b', revoked_at: 'x' }]).length, 1);
  assert.equal(activeDevices(undefined).length, 0);
  assert.ok(looksLikeKey('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIabc you@laptop'));
  assert.ok(!looksLikeKey('hello'));
  assert.ok(!looksLikeKey(''));
});

// The Devices page folds the viewer's own history under the table
// (claude-fleet#2520): /v1/fleet/devices' audit, each row named by its device.
test('deviceHistory: past devices and the certificate audit, named', () => {
  const h = deviceHistory({
    devices: [{ fingerprint: 'SHA256:new', name: 'mbp-2026' }, { fingerprint: 'SHA256:old', name: 'mbp-2023', revoked_at: '2026-09-01T00:00:00Z' }],
    audit: [
      { at: '2026-10-01T00:00:00Z', action: 'renew', fingerprint: 'SHA256:new', actor: 'device' },
      { at: '2026-09-01T00:00:00Z', action: 'revoke', fingerprint: 'SHA256:old', actor: 'gh:1' },
      { at: '2026-08-01T00:00:00Z', action: 'renew_refused', fingerprint: 'SHA256:gone', detail: 'idle' },
    ],
  });
  assert.deepEqual(h.past.map((d) => d.name), ['mbp-2023']);
  assert.deepEqual(h.events.map((e) => [e.action, e.device, e.bad]), [['renew', 'mbp-2026', false], ['revoke', 'mbp-2023', true], ['renew_refused', '', true]]);
  assert.deepEqual(deviceHistory(undefined), { past: [], events: [] });
  const con = readFileSync(new URL('../dist/connect.js', import.meta.url), 'utf8');
  assert.match(con, /devicesPanel\(devs\.value, false\) \+ historyPanel\(devs\.value\)/, 'Devices & SSH draws the history fold under its table');
  const dev = readFileSync(new URL('../dist/lib/devices-view.js', import.meta.url), 'utf8');
  assert.match(dev, /<details class="panel fold" id="devhistory">/, 'the history is folded');
});

// The overview says what it counts (claude-fleet#2680): the viewer's own
// (machine, login) pairs, and to an admin where the whole hub went (#2515).
test('overview scope: the pairs counted, and a pointer for an admin', () => {
  useLocale('zh-CN');
  try {
    const logins = [{ machine: 'mini2', login: 'verky' }, { machine: 'macmini', login: 'verky' }];
    assert.equal(scopeOf({ role: 'user', logins }), '只算你在这些登录上的用量：mini2·verky、macmini·verky。');
    assert.match(scopeOf({ role: 'admin', logins }), /管理 · 按人概览/);
    assert.equal(scopeOf({ logins: [] }), '');
    assert.equal(scopeOf(null), '');
  } finally { useLocale('en'); }
});

// 我的设备 is the computers a person signs in FROM (claude-fleet#2680): a
// login on a machine that runs sessions, a key idle past the hub's limit and
// an older key of a name a newer one carries are not, and fold into history.
test('client devices: not a hosting machine, not idle, the newest key per name', () => {
  const now = Date.parse('2026-10-09T12:00:00Z');
  const body = {
    idle_sec: 7 * 86400,
    devices: [
      { fingerprint: 'mbp-new', name: 'MacBookPro', last_used_at: '2026-10-09T08:00:00Z' },
      { fingerprint: 'mbp-old', name: 'MacBookPro', last_used_at: '2026-10-05T08:00:00Z' },
      { fingerprint: 'ipad', name: 'iPad', last_used_at: '2026-10-08T08:00:00Z' },
      { fingerprint: 'mini2', name: 'mini2', host: true, last_used_at: '2026-10-09T09:00:00Z' },
      { fingerprint: 'stale', name: 'old-mbp', last_used_at: '2026-09-01T00:00:00Z' },
      { fingerprint: 'gone', name: 'x', revoked_at: '2026-09-02T00:00:00Z', last_used_at: '2026-09-01T00:00:00Z' },
    ],
  };
  assert.deepEqual(clientDevices(body, now).map((d) => d.fingerprint), ['mbp-new', 'ipad']);
  assert.deepEqual([...whyNotClient(body, now).entries()].filter((e) => e[1]),
    [['mbp-old', 'replaced'], ['mini2', 'host'], ['stale', 'idle'], ['gone', 'revoked']]);
  assert.deepEqual(deviceHistory(body, now).past.map((d) => [d.fingerprint, d.why]),
    [['mbp-old', 'replaced'], ['mini2', 'host'], ['stale', 'idle'], ['gone', 'revoked']]);
  assert.deepEqual(clientDevices(undefined), []);
  const ov = readFileSync(new URL('../dist/overview.js', import.meta.url), 'utf8');
  assert.match(ov, /clientDevices\(devs\.value\)\.length/, 'the overview tile counts client devices');
});

test('a bundle lists one row per server, hook, skill and setting', () => {
  const items = bundleItems({
    mcp: { github: {}, fetch: {} },
    hooks: { PreToolUse: [{ matcher: 'Bash', command: 'bash-guard.py' }] },
    skills: { 'fleet-open': '# skill' },
    claude_settings: { effort: 'high' },
    codex_config: { approval_policy: 'on-request' },
    hook_scripts: { 'guard.sh': '#!/bin/sh' },
  });
  assert.deepEqual(items, [
    ['mcp', 'fetch'], ['mcp', 'github'],
    ['hook', 'PreToolUse Bash · bash-guard.py'],
    ['script', 'guard.sh'], ['skill', 'fleet-open'],
    ['claude', 'effort = high'], ['codex', 'approval_policy = on-request'],
  ]);
  assert.deepEqual(bundleItems(null), []);
  assert.deepEqual(bundleItems({}), []);
});

test('import takes an export back, and refuses what is not one', () => {
  assert.deepEqual(parseImport('{"version":3,"bundle":{"mcp":{}}}'), { mcp: {} });
  assert.deepEqual(parseImport('{"skills":{}}'), { skills: {} });
  assert.throws(() => parseImport('nope'), /not JSON/);
  assert.throws(() => parseImport('[1]'), /settings object/);
});

// A user's answers are cut by the hub (#1985); the pages must not try to
// widen them. No page names another person or asks for a by-account / by-team
// cut, and only an admin's request carries a principal.
// Since claude-fleet#2515 the four daily pages are the same for an admin:
// none of them reads the whole hub (by person, /v1/admin/*) or names a
// principal, and no admin branch picks a wider read — those are the admin
// area's three pages, which read only /v1/admin/*.
const DAILY = ['overview.js', 'sessions-page.js', 'machines.js', 'connect.js', 'config.js', 'quota.js', 'usage.js', 'app-shell.js', 'lib/sessions-view.js', 'lib/devices-view.js'];
test('no page asks the hub for someone else\'s rows', () => {
  for (const f of DAILY) {
    const src = readFileSync(new URL('../dist/' + f, import.meta.url), 'utf8');
    assert.doesNotMatch(src, /by=(account|team|user)/, `${f} asks for a by-account/team/person cut`);
    assert.doesNotMatch(src, /[?&]user=/, `${f} filters by another user`);
    assert.doesNotMatch(src, /all=1/, `${f} asks for everyone's layer`);
    assert.doesNotMatch(src, /[?&]principal=/, `${f} names a principal`);
  }
  for (const f of ['overview.js', 'sessions-page.js', 'connect.js', 'config.js']) {
    const src = readFileSync(new URL('../dist/' + f, import.meta.url), 'utf8');
    assert.doesNotMatch(src, /\/v1\/admin\//, `${f} reads the admin area`);
    assert.doesNotMatch(src, /admin \? (q|api|ctx\.api)\(/, `${f} widens its read for an admin`);
  }
  const want = { 'admin/sessions.js': /sessionsPage\(\{ all: true \}\)/, 'admin/overview.js': /\/v1\/admin\/overview/, 'admin/devices.js': /\/v1\/admin\/devices/ };
  for (const [f, re] of Object.entries(want)) {
    assert.match(readFileSync(new URL('../dist/' + f, import.meta.url), 'utf8'), re, `${f} reads the whole hub`);
  }
  assert.match(readFileSync(new URL('../dist/lib/sessions-view.js', import.meta.url), 'utf8'), /all \? ctx\.api\('\/v1\/admin\/sessions'\)/);
});

// The person / subscription and owner columns are the admin area's only.
test('the daily tables carry no person, subscription or owner column', () => {
  const ses = readFileSync(new URL('../dist/lib/sessions-view.js', import.meta.url), 'utf8');
  for (const m of ses.matchAll(/ui\.col\.(person|subscription)/g)) {
    const before = ses.slice(Math.max(0, m.index - 120), m.index);
    assert.match(before, /\b(a|S\.all) \?/, 'a person/subscription column outside the all-sessions branch');
  }
  const dev = readFileSync(new URL('../dist/lib/devices-view.js', import.meta.url), 'utf8');
  assert.match(dev, /a \? `<th>\$\{esc\(t\('ui\.col\.owner'\)\)\}<\/th>`/);
  const con = readFileSync(new URL('../dist/connect.js', import.meta.url), 'utf8');
  assert.match(con, /devicesPanel\(devs\.value, false\)/, 'Devices & SSH draws the viewer\'s own, no owner column');
  const cfg = readFileSync(new URL('../dist/config.js', import.meta.url), 'utf8');
  assert.doesNotMatch(cfg, /id="publish"|data-restore/, 'publish and restore are the admin area\'s (Settings)');
  assert.match(cfg, /id="import"/);
  assert.doesNotMatch(cfg, /admin \? '' : `<button class="btn sm" id="import"/, 'an admin imports their own settings too');
});

// Every word on the four pages is a dictionary key (EPIC #1982 convention 11):
// no English sentence typed into a template, and no t() key the dictionary
// lacks (the parity test in i18n.test.mjs then holds zh-CN to it).
test('the app pages print only dictionary words', () => {
  for (const f of ['overview.js', 'sessions-page.js', 'machines.js', 'connect.js', 'config.js', 'quota.js', 'usage.js', 'app-shell.js', 'lib/shell.js', 'lib/pages.js', 'lib/sessions-view.js', 'lib/devices-view.js']) {
    const src = readFileSync(new URL('../dist/' + f, import.meta.url), 'utf8').replace(/^\s*(\/\/|\*|\/\*).*$/gm, '');
    const bare = src.match(/>[A-Z][a-z]+[ <.]/g) || [];
    assert.deepEqual(bare.filter((m) => !/>(Claude|Codex|GitHub)/.test(m)), [], `${f} types English into markup`);
    for (const [, key] of src.matchAll(/\bt\('(ui\.[\w.]*\w)'/g)) assert.ok(key in en, `${f}: t('${key}') is not in en.js`);
  }
});

// 我的额度 (claude-fleet#2517): no subscription is the empty state that sends
// the person to an admin; two are two rows, each with its windows, its reset
// and a status that says which window ran out.
test('quotaTable: the empty state, and one row per subscription', () => {
  useLocale('zh-CN');
  try {
    for (const none of [[], null, undefined]) {
      const html = quotaTable(none);
      assert.match(html, /入口还没给你分配订阅/);
      assert.match(html, /找管理员/);
      assert.doesNotMatch(html, /<table/);
    }
    const rows = [
      { subscription: 'icloud', provider: 'claude', used_5h_pct: 62, used_7d_pct: 31, resets_at: '2026-10-10T23:00:00Z', state: 'ok' },
      { subscription: '24helpful', provider: 'claude', used_5h_pct: 100, used_7d_pct: 96, resets_at: '2026-10-10T23:00:00Z', state: 'limited' },
    ];
    const html = quotaTable(rows);
    assert.equal((html.match(/class="quota-row"/g) || []).length, 2);
    assert.match(html, /icloud/);
    assert.match(html, /62%/);
    assert.match(html, /可用/);
    assert.match(html, /暂时用尽/);
    assert.doesNotMatch(html, /入口还没给你分配订阅/);
    assert.equal(quotaState({ state: 'limited', used_5h_pct: 40, used_7d_pct: 100 })[1], '本周用尽');
    assert.equal(quotaState({ state: 'paused' })[1], '管理员已暂停');
    assert.equal(quotaState({ state: 'unknown', used_5h_pct: null })[1], '还没有读数');
    assert.match(quotaTable([{ subscription: 'x', used_5h_pct: null, used_7d_pct: null, state: 'unknown' }]), /—/);
  } finally {
    useLocale('en');
  }
});

// 我的机器 (claude-fleet#2518): two machines that take sessions and a laptop
// that only coordinates are three rows; another login, a machine link and a
// pair /v1/me does not list are none.
test('my machines: two machines and a coordinating laptop, nobody else', () => {
  useLocale('en');
  const node = (hostname, os_user, extra) => ({ endpoint_id: hostname + '/' + os_user, hostname, os_user, status: 'online', load1: 2, ncpu: 8, sessions: 1, ...extra });
  const snap = {
    machines: [{ hostname: 'macmini.local', alias: 'm5' }, { hostname: 'mini2.local', alias: 'm4' }],
    nodes: [
      node('macmini.local', 'alice', { sessions: 2 }),
      node('mini2.local', 'alice', { sessions: 0, load1: 1.92 }),
      node('alice-mbp', 'alice', { compute_off: true, personal: true, status: 'lost' }),
      node('macmini.local', 'bob', { sessions: 5 }),
      node('macmini.local', 'root', { machine_link: true }),
      node('elsewhere', 'alice', {}),
    ],
  };
  const me = { role: 'user', logins: [{ machine: 'macmini.local', login: 'alice' }, { machine: 'mini2.local', login: 'alice' }, { machine: 'alice-mbp', login: 'alice' }] };
  const rows = myMachines(snap, me);
  assert.deepEqual(rows.map((r) => [r.label, r.login, r.takes, r.sessions]), [
    ['m4', 'alice', 'on', 0], ['m5', 'alice', 'on', 2], ['alice-mbp', 'alice', 'coord', null],
  ]);
  assert.equal(rows[0].loadCore, 0.24);
  assert.equal(rows[2].loadCore, null, 'a coordinating laptop has no load to show');
  assert.ok(!rows.some((r) => r.login === 'bob'), 'another login is never a row');
});

// One machine is one row (claude-fleet#2680): two logins of the viewer's on
// m4 name both on the one row and add their sessions; a machine whose login
// only coordinates for the moment still shows the machine's load, read from
// the newest heard beat — only a person's own computer shows none.
test('my machines: one row per machine, its load even while it only coordinates', () => {
  const node = (hostname, os_user, extra) => ({ endpoint_id: hostname + '/' + os_user, hostname, os_user, status: 'online', load1: 2, ncpu: 8, sessions: 1, ...extra });
  const snap = {
    machines: [{ hostname: 'macmini', alias: 'm5' }, { hostname: 'mini2', alias: 'm4' }],
    nodes: [
      node('mini2', 'verkyyi', { sessions: 3, load1: 4, last_heartbeat: '2026-10-09T10:00:00Z' }),
      node('mini2', 'verky', { sessions: 5, load1: 6, last_heartbeat: '2026-10-09T10:00:05Z' }),
      node('macmini', 'verky', { compute_off: true, compute_why: 'CCQUOTA_FLEET_COMPUTE=0', load1: 1, ncpu: 4 }),
    ],
  };
  const me = { logins: [{ machine: 'mini2', login: 'verky' }, { machine: 'mini2', login: 'verkyyi' }, { machine: 'macmini', login: 'verky' }] };
  const rows = myMachines(snap, me);
  assert.deepEqual(rows.map((r) => [r.label, r.login, r.takes, r.sessions, r.loadCore]), [
    ['m4', 'verky · verkyyi', 'on', 8, 0.75],
    ['m5', 'verky', 'coord', null, 0.25],
  ]);
  const [r] = myMachines({ nodes: [node('mini2', 'a', { sessions: null }), node('mini2', 'b', {})] }, {});
  assert.equal(r.sessions, undefined, 'one unknown count makes the machine unknown');
});

test('my machines: what takes sessions, and an unknown count stays unknown', () => {
  assert.equal(takesOf({ status: 'online' }), 'on');
  assert.equal(takesOf({ status: 'online', admit: false }), 'paused');
  assert.equal(takesOf({ status: 'maintenance' }), 'maint');
  assert.equal(takesOf({ status: 'lost' }), 'lost');
  assert.equal(takesOf({ status: 'lost', compute_off: true }), 'coord');
  const [r] = myMachines({ nodes: [{ hostname: 'h', os_user: 'u', status: 'lost', sessions: null, load1: 3, ncpu: 4 }] }, {});
  assert.equal(r.sessions, undefined, 'null sessions is unknown, never 0');
  assert.equal(r.loadCore, null, 'a lost machine shows no stale load');
  assert.deepEqual(myMachines(null, null), []);
});

test('my machines reads only the cut roster: no join code, no retire', () => {
  const src = readFileSync(new URL('../dist/machines.js', import.meta.url), 'utf8');
  assert.match(src, /api\('\/v1\/nodes'\)/);
  assert.doesNotMatch(src, /join-codes|retire|\/v1\/fleet\/settings|POST/);
});

// 我的用量 (claude-fleet#2519): a quiet week is the empty state; a week with
// usage is seven bars in day order; the budget panel shows both windows
// against their limits, says which one ran out and when it frees up, and says
// so plainly when no admin set one. The page asks only for its own (?mine=1).
test('my usage: the days, and the budget against both windows', () => {
  useLocale('zh-CN');
  try {
    assert.deepEqual(usageDays([]), []);
    assert.deepEqual(usageDays([{ day: '2026-10-08', tokens: 0 }]), []);
    const days = ['03', '04', '05', '06', '07', '08', '09'].map((d, i) => ({ day: `2026-10-${d}`, tokens: i * 1000 }));
    const rows = usageDays(days);
    assert.equal(rows.length, 7);
    assert.deepEqual(rows.map((r) => r[1]), [0, 1000, 2000, 3000, 4000, 5000, 6000]);

    const over = usageBudget({ limit_5h: 200000, limit_week: 1000000, used_5h: 50000, used_week: 1000000, over: true, window: 'week', reset_at: '2026-10-10T23:00:00Z' });
    assert.match(over, /已达个人额度（近 7 天）/);
    assert.match(over, /约 .* 恢复/);
    assert.match(over, /近 5 小时/);
    assert.match(over, /width:25%/);
    assert.match(over, /class="bad" style="width:100%"/);

    const ok = usageBudget({ limit_5h: 0, limit_week: 1000000, used_5h: 1200, used_week: 300000, over: false });
    assert.match(ok, /在预算内/);
    assert.match(ok, /不限/);
    assert.doesNotMatch(ok, /恢复/);

    const unset = usageBudget({});
    assert.match(unset, /没有设预算/);
    assert.match(unset, /用量不会被拦/);
  } finally {
    useLocale('en');
  }
  const src = readFileSync(new URL('../dist/usage.js', import.meta.url), 'utf8');
  assert.match(src, /\/v1\/fleet\/person-usage\?mine=1/);
});
