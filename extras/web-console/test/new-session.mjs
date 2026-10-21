// new-session.mjs — the new-session screen (GR5E C3, src/app/new-session.ts):
// the five starts (对话 × Claude Code / Codex, 终端 × Claude Code / Codex / 只开
// Shell) hold their shape; what is remembered; a chat and the Shell stay on the
// home; a home that is out says why and nothing starts; an agent start is one
// worker_start with or without words; the row it became is found by its key.
// Run: node --experimental-strip-types test/new-session.mjs
import assert from 'node:assert/strict';
import { blocker, fixChoice, machinesOf, readChoice, rowForRequest, startArgs, targetOf } from '../src/app/new-session.ts';

// the five, and nothing else
const five = [['chat', 'claude'], ['chat', 'codex'], ['term', 'claude'], ['term', 'codex'], ['term', 'shell']];
for (const [mode, agent] of five) assert.deepEqual(fixChoice({ mode, agent }), { mode, agent, machine: '' }, `${mode}/${agent}`);
assert.equal(fixChoice({ mode: 'chat', agent: 'shell' }).agent, 'claude', 'the Shell is the terminal\'s only');
assert.equal(fixChoice({ mode: 'chat', agent: 'claude', machine: 'studio-2' }).machine, '', 'a chat runs on the home only');
assert.equal(fixChoice({ mode: 'term', agent: 'shell', machine: 'studio-2' }).machine, '', 'the Shell is the home\'s');
assert.equal(fixChoice({ mode: 'term', agent: 'codex', machine: 'studio-2' }).machine, 'studio-2');

// remembered: the last choice, a broken one is the default
assert.deepEqual(readChoice(JSON.stringify({ mode: 'term', agent: 'codex', machine: 'studio-2', words: 'never kept' })), { mode: 'term', agent: 'codex', machine: 'studio-2' });
assert.deepEqual(readChoice('{nope'), { mode: 'chat', agent: 'claude', machine: '' });
assert.deepEqual(readChoice(null), { mode: 'chat', agent: 'claude', machine: '' });

// machines: the person's own, the home first, never a client or a link row
const home = { machine: 'mac-mini', login: 'me', state: 'ok' };
const nodes = { nodes: [
  { hostname: 'studio-2', os_user: 'me', status: 'online' },
  { hostname: 'mac-mini', os_user: 'me', status: 'online' },
  { hostname: 'mac-mini', os_user: 'other', status: 'online' },
  { hostname: 'laptop', os_user: 'me', status: 'online' },
  { hostname: 'mac-mini', os_user: 'me', status: 'online', machine_link: true },
  { hostname: 'gone-box', os_user: 'me', status: 'lost' },
], machines: [{ hostname: 'laptop', role: 'client' }, { hostname: 'studio-2', alias: 'Studio' }] };
const logins = [{ machine: 'mac-mini', login: 'me' }, { machine: 'studio-2', login: 'me' }, { machine: 'laptop', login: 'me' }, { machine: 'gone-box', login: 'me' }];
const ms = machinesOf(nodes, logins, home);
assert.deepEqual(ms.map((m) => [m.hostname, m.label, m.state, m.home]),
  [['mac-mini', 'mac-mini', 'on', true], ['gone-box', 'gone-box', 'lost', false], ['studio-2', 'Studio', 'on', false]]);
// a home the roster does not list yet is still there to pick
assert.equal(machinesOf({ nodes: [] }, logins, home)[0].hostname, 'mac-mini');

// where each start opens
assert.equal(targetOf(fixChoice({ mode: 'term', agent: 'codex', machine: 'studio-2' }), ms).hostname, 'studio-2');
assert.equal(targetOf(fixChoice({ mode: 'term', agent: 'claude', machine: 'nowhere' }), ms).hostname, 'mac-mini', 'an unknown machine is the home');
assert.equal(targetOf(fixChoice({ mode: 'chat', agent: 'codex' }), ms).hostname, 'mac-mini');

// all five can start on a home that is up
for (const [mode, agent] of five) assert.equal(blocker(fixChoice({ mode, agent }), ms, home), '', `${mode}/${agent} starts`);
// the home out: said, for every start that runs there
for (const state of ['offline', 'maintenance']) {
  const out = { ...home, state };
  const outMs = machinesOf(nodes, logins, out);
  for (const [mode, agent] of five) assert.match(blocker(fixChoice({ mode, agent }), outMs, out), /mac-mini/, `${state}: ${mode}/${agent}`);
  // an agent on another machine that is up is not stopped by the home
  assert.equal(blocker(fixChoice({ mode: 'term', agent: 'claude', machine: 'studio-2' }), outMs, out), '');
}
assert.match(blocker(fixChoice({ mode: 'term', agent: 'claude', machine: 'gone-box' }), ms, home), /gone-box/);
// no home: the hub's own words when it gave them
const none = { state: 'no_home', why: 'no machine of yours runs fleet' };
assert.equal(blocker(fixChoice({ mode: 'chat', agent: 'claude' }), machinesOf({ nodes: [] }, logins, none), none), 'no machine of yours runs fleet');
assert.ok(blocker(fixChoice({ mode: 'term', agent: 'shell' }), [], null));
// an old home: the chat says so, a terminal still opens
const old = { ...home, state: 'old_agent' };
assert.match(blocker(fixChoice({ mode: 'chat', agent: 'claude' }), ms, old), /fleet/);
assert.equal(blocker(fixChoice({ mode: 'term', agent: 'codex' }), ms, old), '');

// the write: a no-repo session with its agent and machine; empty words start too
assert.deepEqual(startArgs(fixChoice({ mode: 'term', agent: 'codex' }), '  ', ms[0], 'web-1'),
  { kind: 'scratch', no_repo: true, coding_agent: 'codex', idempotency_key: 'web-1', node: 'mac-mini' });
assert.deepEqual(startArgs(fixChoice({ mode: 'term', agent: 'claude' }), ' 看下日志 ', ms[2], 'web-2'),
  { kind: 'scratch', no_repo: true, coding_agent: 'claude', idempotency_key: 'web-2', body: '看下日志', node: 'studio-2' });

// the row it became: the record whose dispatch carries the key
const row = (id, rid) => ({ id, task: { id, request_payload: JSON.stringify({ params: { dispatch: { request_id: rid } } }) } });
const rows = [row('T1', 'web-0'), { id: 'x' }, { id: 'T3', task: { id: 'T3', request_payload: '{bad' } }, row('T2', 'web-2')];
assert.equal(rowForRequest(rows, 'web-2').id, 'T2');
assert.equal(rowForRequest(rows, 'web-9'), null);
assert.equal(rowForRequest(null, 'web-2'), null);

console.log('new-session: ok');
