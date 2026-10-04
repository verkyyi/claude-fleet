import test from 'node:test';
import assert from 'node:assert/strict';
import { mine, sessionView, byMachine, summary, ageText } from '../dist/lib/sessions.js';

const row = (machine, login, worker = {}, over = {}) => ({
  worker_id: `f-${machine}-${login}/issue-${worker.issue ?? 0}`,
  machine_name: machine, os_user: login, fleet_id: `f-${machine}-${login}`, fleet_name: 'fleet',
  availability: 'online', age_sec: 3,
  worker: { key: `issue-${worker.issue ?? 0}`, state: 'working', agent: 'claude', lifecycle: 'awake', ...worker },
  ...over,
});
const me = (accounts) => ({ principal: { id: 'p1' }, accounts });
const acct = (hostname, login, state = 'active') => ({ hostname, login, state });

const ALL = [
  row('m5', 'alice', { issue: 1 }),
  row('m4', 'alice', { issue: 2 }),
  row('m5', 'bob', { issue: 3 }),
];

test('a person sees only the sessions on their own active (machine, login) accounts', () => {
  const got = mine(ALL, me([acct('m5', 'alice'), acct('m4', 'alice')]));
  assert.deepEqual(got.map((s) => s.worker.issue), [1, 2]);
  assert.ok(!got.some((s) => s.os_user === 'bob'));
});

test('a same-named login on another machine is not theirs', () => {
  assert.deepEqual(mine(ALL, me([acct('m5', 'alice')])).map((s) => s.worker.issue), [1]);
});

test('a removed / pending account shows nothing, and no account means nothing — never everything', () => {
  assert.deepEqual(mine(ALL, me([acct('m5', 'alice', 'removed'), acct('m4', 'alice', 'creating')])), []);
  assert.deepEqual(mine(ALL, me([])), []);
  assert.deepEqual(mine(ALL, { principal: { id: 'p1' } }), []);
});

test('the operator door (no principal) keeps what the hub already scoped', () => {
  assert.equal(mine(ALL, { principal: null, accounts: [] }).length, 3);
  assert.equal(mine(ALL, null).length, 3);
  assert.deepEqual(mine(undefined, null), []);
});

test('byMachine never lets another person\'s session through to the page', () => {
  const groups = byMachine(ALL, me([acct('m5', 'alice')]));
  assert.deepEqual(groups.map((g) => g.machine), ['m5']);
  assert.deepEqual(groups[0].sessions.map((v) => v.login), ['alice']);
});

test('a lost node is 失联 with how long ago, keeps its last state, and is not "needs you"', () => {
  const v = sessionView(row('m4', 'alice', { issue: 2, state: 'waiting' }, { availability: 'lost', age_sec: 600 }));
  assert.equal(v.lost, true);
  assert.equal(v.lostText, '失联 · 最后见到 10 分钟前');
  assert.equal(v.stateText, '等你回答');
  assert.equal(v.needsYou, false);
});

test('any non-online availability is 失联, never shown as live', () => {
  for (const a of ['lost', '', undefined, 'unknown-word']) {
    assert.equal(sessionView(row('m4', 'alice', {}, { availability: a })).lost, true, `availability=${a}`);
  }
  assert.equal(sessionView(row('m4', 'alice')).lost, false);
  assert.equal(sessionView(row('m4', 'alice')).lostText, '');
});

test('维护中 is heard: not 失联, still ranked live, labelled on the card and the heading (#1427)', () => {
  const v = sessionView(row('m5', 'alice', { state: 'waiting' }, { availability: 'maintenance', age_sec: 5 }));
  assert.equal(v.lost, false);
  assert.equal(v.maint, true);
  assert.equal(v.lostText, '维护中');
  assert.equal(v.needsYou, true, 'a waiting session on a 维护中 machine is a live ask');
  const groups = byMachine([
    row('m5', 'alice', {}, { availability: 'maintenance' }),
    row('m4', 'alice', {}, { availability: 'online' }),
  ], { accounts: [{ hostname: 'm5', login: 'alice', state: 'active' }, { hostname: 'm4', login: 'alice', state: 'active' }] });
  const m5 = groups.find((g) => g.machine === 'm5');
  const m4 = groups.find((g) => g.machine === 'm4');
  assert.equal(m5.lost, false);
  assert.equal(m5.lostText, '维护中');
  assert.equal(m4.lostText, '');
});

test('a machine heading is 失联 only when every login on it is', () => {
  const groups = byMachine([
    row('m4', 'alice', { issue: 1 }, { availability: 'lost', age_sec: 7200 }),
    row('m5', 'alice', { issue: 2 }, { availability: 'lost', age_sec: 30 }),
    row('m5', 'carol', { issue: 3 }),
  ], null);
  const m4 = groups.find((g) => g.machine === 'm4');
  const m5 = groups.find((g) => g.machine === 'm5');
  assert.equal(m4.lost, true);
  assert.equal(m4.lostText, '失联 · 最后见到 2 小时前');
  assert.equal(m5.lost, false);
  assert.equal(m5.sessions.find((v) => v.title === '#2').lost, true);
});

test('waiting / blocked sessions come first and are counted', () => {
  const groups = byMachine([
    row('m5', 'alice', { issue: 1, state: 'idle' }),
    row('m5', 'alice', { issue: 2, state: 'working' }),
    row('m5', 'alice', { issue: 3, state: 'blocked' }),
    row('m5', 'alice', { issue: 4, state: 'waiting' }),
    row('m4', 'alice', { issue: 5, state: 'waiting' }, { availability: 'lost', age_sec: 100 }),
  ], null);
  assert.deepEqual(groups.find((g) => g.machine === 'm5').sessions.map((v) => v.title), ['#4', '#3', '#2', '#1']);
  assert.deepEqual(summary(groups), { total: 5, needs: 2, lost: 1, machines: 2 });
});

test('titles: window name, else #issue, else 临时会话', () => {
  assert.equal(sessionView(row('m', 'a', { issue: 7, name: '修登录页' })).title, '修登录页');
  assert.equal(sessionView(row('m', 'a', { issue: 7, name: '修登录页', repo: 'o/r' })).meta, '#7 · o/r · claude');
  assert.equal(sessionView(row('m', 'a', { issue: 7 })).title, '#7');
  assert.equal(sessionView(row('m', 'a', { issue: null, scratch: true })).title, '临时会话');
});

test('ageText', () => {
  assert.equal(ageText(0.2), '1 秒前');
  assert.equal(ageText(45), '45 秒前');
  assert.equal(ageText(600), '10 分钟前');
  assert.equal(ageText(7200), '2 小时前');
  assert.equal(ageText(3 * 86400), '3 天前');
  assert.equal(ageText(null), '');
  assert.equal(ageText(-1), '');
});
