// session-list.mjs — the session list (GR5E C2, src/app/session-list.ts and
// SessionList.tsx): a row draws a status glyph and its title and nothing else;
// the list is ⌘P's top-level entries in ⌘P's order (the hub's board), an EPIC
// only as its parent, the put-away ones apart; a search finds a code, a title
// or a machine; the one detail line; a row is bold until opened.
// Run: node --experimental-strip-types test/session-list.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { boardRows } from '../src/app/work.ts';
import { isUnread, listItem, listRows, matchRow, openFor, rowMeta, rowRef, searchRows, seenMark } from '../src/app/session-list.ts';

const F = '5b1e0000-0000-4000-8000-00000000f001';
const fid = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const v1 = (x) => ({ authority_version: 1, generation: 1, created_at: new Date().toISOString(), title: 'x', ...x });
const now = Date.now();
const sess = (id, state, x = {}) => ({ id: `${F}/${id}`, key: id, title: id, repo: '', machine: 'mini2', state, group: 'run',
  ask: null, born: (now - 3 * 3600e3) / 1000, ended: '', tokens: 0, say: '', ...x });

const tasks = [
  v1({ id: 'T30', fid: fid(30), short: 'R9A2', title: 'webchat codex', task_state: 'running', resolved_agent: 'claude' }),
  v1({ id: 'T31', fid: fid(31), short: 'GR5E', title: 'epic', task_state: 'running' }),
  v1({ id: 'T32', fid: fid(32), short: 'DBEV', title: 'member', task_state: 'running', parent_task: fid(31) }),
  v1({ id: 'T33', fid: fid(33), short: 'K5H0', title: 'member elsewhere', task_state: 'accepted', parent_task: fid(31) }),
];
const live = [sess('a', 'needs', { ask: { kind: 'question', msg: '设计页已发布，等你点头' } }), sess('e', 'working')];
const W = (tag, words) => ({ tag, words });
const board = { count: 5, groups: {}, gone_days: 7, digest: 'x', rows: [
  { id: fid(30), task: 'T30', task_id: fid(30), title: 'webchat codex', group: 'ask', ...W('asking', ['在问你', 'Asking you']), worker_id: `${F}/a`, machine: 'mini2', at: 90 },
  { id: fid(31), task: 'T31', task_id: fid(31), title: 'epic', group: 'work', ...W('working', ['在干活', 'Working']), worker_id: `${F}/e`, at: 80 },
  { id: fid(32), task: 'T32', task_id: fid(32), title: 'member', group: 'work', ...W('working', ['在干活', 'Working']), parent: fid(31), depth: 1, at: 70 },
  { id: 'loose', title: 'a loose shell', group: 'work', ...W('working', ['在干活', 'Working']), machine: 'office-mac', at: 60 },
  { id: fid(33), task: 'T33', task_id: fid(33), title: 'member elsewhere', group: 'queue', ...W('queued', ['排着', 'Queued']), parent: fid(31), at: 50 },
  { id: 'idle', title: 'idle one', group: 'queue', ...W('idle', ['空闲', 'Idle']), at: 40 },
  { id: 'g1', title: 'old', group: 'gone', ...W('ended', ['已结束', 'Ended']), at: 10 },
] };
const rows = boardRows(board, tasks, live);

// ⌘P's top-level entries, in ⌘P's order: an EPIC's members only inside it (in
// its group or not), the put-away ones apart
const { open, gone } = listRows(rows);
const panelTop = board.rows.filter((b) => !b.parent && b.group !== 'gone').map((b) => b.id);
assert.deepEqual(open.map((r) => r.id), panelTop, 'the list is the panel\'s top level, same order, difference 0');
assert.deepEqual(gone.map((r) => r.title), ['old']);
assert.ok(!open.some((r) => r.title.startsWith('member')), 'members sit only in their parent');
assert.deepEqual(rows.find((r) => r.title === 'epic').kids.map((k) => k.title), ['member', 'member elsewhere']);

// a row draws a glyph and a title — nothing else
const it = listItem(open[0], {});
assert.deepEqual(Object.keys(it).sort(), ['bold', 'glyph', 'ref', 'title', 'tone']);
assert.deepEqual([it.glyph, it.tone, it.title], ['ask', 'ask', 'webchat codex']);
const src = readFileSync(new URL('../src/app/SessionList.tsx', import.meta.url), 'utf8');
const rowBody = src.slice(src.indexOf('const SessionRow: FC'), src.indexOf('const WebChatRow'));
const drawn = rowBody.slice(rowBody.indexOf('const body = ('), rowBody.indexOf('</Link>'));
for (const extra of ['r.code', 'r.line', 'r.tag', 'rowMeta', 'machine', 'ago(', 'Badge'])
  assert.ok(!drawn.includes(extra), `a list row draws no ${extra}`);
assert.ok(drawn.includes('<RowGlyph') && drawn.includes('{it.title}'), 'a list row draws its glyph and its title');

// its address: the task's code, else its own id
assert.equal(rowRef(open[0]), 'R9A2');
assert.equal(rowRef(rows.find((r) => r.id === 'loose')), 'loose');

// a search finds what the row does not show: a code, a title, a machine — a member too
assert.ok(matchRow(open[0], '#r9a2'));
assert.ok(matchRow(open[0], 'CODEX'));
assert.deepEqual(searchRows(rows, 'office').map((r) => r.title), ['a loose shell']);
assert.deepEqual(searchRows(rows, 'K5H0').map((r) => r.title), ['member elsewhere']);
assert.equal(searchRows(rows, '').length, rows.length);

// the one detail line: code · machine · agent · where · how long
// (node's language is the machine's: either one)
assert.match(rowMeta(open[0], now), new RegExp(`^${open[0].code} · mini2 · Claude Code · (在终端里|in a terminal) · (开了 3 小时|open 3 h)$`));
assert.match(rowMeta(gone[0], now), /^(已结束|ended)$/);
assert.match(openFor(now - 5 * 60e3, now), /^(开了 5 分钟|open 5 min)$/);
assert.equal(openFor(0, now), '');

// bold until opened, and again once it moves on
const seen = {};
assert.ok(isUnread(open[0], seen));
seen[open[0].id] = seenMark(open[0]);
assert.ok(!isUnread(open[0], seen));
assert.equal(listItem(open[0], seen).bold, false);
assert.ok(isUnread({ ...open[0], tag: ['在干活', 'Working'] }, seen), 'a row whose state moved on reads bold again');

// sixty rows: the list's own work stays trivial
const many = { ...board, rows: Array.from({ length: 60 }, (_, i) => ({ id: `s${i}`, title: `session ${i}`, group: i % 3 ? 'work' : 'queue', ...W('working', ['在干活', 'Working']), at: 100 - i })) };
const t0 = performance.now();
for (let i = 0; i < 100; i++) listRows(boardRows(many, [], [])).open.map((r) => listItem(r, {}));
assert.ok(performance.now() - t0 < 1000, 'sixty rows a hundred times well under a second');
assert.equal(listRows(boardRows(many, [], [])).open.length, 60);

console.log('ok session-list.mjs');
