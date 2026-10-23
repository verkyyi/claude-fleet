// session-list.mjs — the session list (GR5E C2, src/app/session-list.ts and
// SessionList.tsx): a row draws a status glyph and its title and nothing else;
// the list is ⌘P's top-level entries in ⌘P's order (the hub's board), an EPIC
// only as its parent, the put-away ones apart; a search finds a code, a title
// or a machine; the one detail line; a row is bold until opened.
// Run: node --experimental-strip-types test/session-list.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { boardRows, nestedKids } from '../src/app/work.ts';
import { pendingStartRef } from '../src/app/task-cancel.ts';
import { headMeta, isTerminal, isUnread, listItem, listRows, listStatus, machineCount, matchRow, openFor, openLine, repliesDone, rowMeta, rowRef, rowState, searchRows, seenMark } from '../src/app/session-list.ts';

const tr2 = (w) => (w ? w.join('|') : '');
const F = '5b1e0000-0000-4000-8000-00000000f001';
const fid = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const v1 = (x) => ({ authority_version: 1, generation: 1, created_at: new Date().toISOString(), title: 'x', ...x });
const now = Date.now();
// A start cancellation needs a real pending request and a task identity. Missing
// telemetry, historical idle sessions and live workers must not get this action.
const pending = { id: 'T900', board: { task: 'T900', pending_start: true, tag: 'queued' } };
assert.equal(pendingStartRef(pending), 'T900');
assert.equal(pendingStartRef({ ...pending, task: { fid: fid(900), id: 'T900' } }), fid(900));
for (const changed of [
  { ...pending, live: { id: 'fleet/live' } },
  { ...pending, board: { ...pending.board, pending_start: false } },
  { ...pending, board: { ...pending.board, pending_start: undefined } },
  { ...pending, board: { ...pending.board, tag: 'idle' } },
  { ...pending, board: { ...pending.board, tag: 'ended', history: { id: 'old' } } },
  { id: 'not-a-task', board: { pending_start: true, tag: 'queued' } },
]) assert.equal(pendingStartRef(changed), '');
const sess = (id, state, x = {}) => ({ id: `${F}/${id}`, key: id, title: id, repo: '', machine: 'build-box', state, group: 'run',
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
  { id: fid(30), task: 'T30', task_id: fid(30), title: 'webchat codex', group: 'ask', ...W('asking', ['在问你', 'Asking you']), worker_id: `${F}/a`, machine: 'build-box', at: 90 },
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
const panelTop = board.rows.filter((b) => b.group !== 'gone').map((b) => b.id);
assert.deepEqual(open.map((r) => r.id), panelTop, 'the list is the panel\'s top level, same order, difference 0');
assert.deepEqual(gone.map((r) => r.title), ['old']);
assert.ok(open.some((r) => r.title.startsWith('member')), 'old members remain independently accessible');
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

// the one detail line: code · agent · how long — the machine only past one (会话合一 Y01K)
// (node's language is the machine's: either one)
assert.match(rowMeta(open[0], now), new RegExp(`^${open[0].code} · (未知|Unknown) · (开了 3 小时|open 3 h)$`));
assert.match(rowMeta(open[0], now, 2), new RegExp(`^${open[0].code} · build-box · (未知|Unknown) · (开了 3 小时|open 3 h)$`));
assert.equal(machineCount(rows), 2, 'build-box and office');
assert.match(rowMeta(gone[0], now), /^(未知 · 更早的会话|Unknown · Earlier session)$/);
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

// C25B: the 会话 page opens an EPIC only onto the members drawn under it — its
// own group's, the search's — and draws them below it; none ⇒ no ▸
const epic = rows.find((r) => r.title === 'epic');
assert.deepEqual(nestedKids(epic).map((k) => k.title), ['member'], 'only its own group\'s member hangs under it');
const page = readFileSync(new URL('../src/app/pages/sessions.tsx', import.meta.url), 'utf8');
const line = page.slice(page.indexOf('const RowLine: FC'), page.indexOf('// ✦ 消息'));
assert.ok(!line.includes('nestedKids('), 'the row draws ▸ off the members shown, never all of them');
assert.ok(/\{kids\.length \? \(\s*<button[^>]*aria-expanded/.test(line), '▸ only with a member under it');
const loop = page.slice(page.indexOf('const kids = nestedKids(r).filter(match);'));
assert.ok(loop.indexOf('<RowLine r={r} kids={kids}') < loop.indexOf('kids.map((k) =>'), 'members drawn below their EPIC');

// 我的对话 is pinned on the old road only (C25B); on the new one it is a session of the list (会话合一 Y01K)
assert.ok(src.includes('{oldRoad ? <List>{web}</List> : null}'), 'the old chat entry is retained');
assert.ok(src.includes('const oldRoad = useUnified() === false'), 'only the entry saying unified off keeps that row');

// 会话合一 (Y01K): a terminal's session wears >_ (an older hub lists terminal sessions only)
assert.ok(isTerminal({ origin: 'terminal' }) && !isTerminal({ origin: 'web' }) && isTerminal({ live: {} }) && !isTerminal({}));
// One status slot; no pending inferred from a missing session or a draft.
const R = (x) => ({ code: 'K7Q2', glyph: 'idle', group: 'queue', tag: ['空闲', 'Idle'], ...x });
assert.equal(listStatus(R({ glyph: 'work', group: 'work' })).kind, 'work');
assert.equal(listStatus(R({ glyph: 'ask', group: 'ask' })).kind, 'ask');
assert.equal(listStatus(R({})).kind, null);
assert.equal(listStatus(R({ board: { tag: 'queued' } })).kind, null);
assert.equal(listStatus(R({ task: v1({task_state:'accepted', operation_id:'op'}) })).kind, null);
assert.equal(listStatus(R({ task: v1({task_state:'accepted'}) })).kind, null);
assert.equal(listStatus(R({ task: v1({task_state:'starting'}) })).kind, 'pending');
assert.equal(listStatus(R({ task: v1({task_state:'starting',cancel_request:'stop'}) })).kind, null);
assert.equal(listStatus(R({ live:{state:'idle'}, task: v1({task_state:'starting'}) })).kind, 'pending');
assert.equal(listStatus(R({ live:{state:'looping'} })).kind, null);
assert.equal(listStatus(R({ live:{state:'needs'}, board:{tag:'looping',loop:true} })).kind, 'ask');
assert.equal(listStatus(R({ live:{state:'working'}, board:{tag:'looping',loop:true} })).words.length, 2);
assert.equal(listStatus(R({ live:{state:'working'}, board:{lost:true} })).kind, null);
assert.equal(listStatus(R({ board:{tag:'not_seen'} })).unknown, true);
assert.ok(!drawn.includes('row-word') && !drawn.includes('TermTag'), 'no trailing status or terminal label');
const pinned = {...rows[0], id:'pinned',group:'pin'};
assert.deepEqual(listRows([...rows,pinned]).pin.map(r=>r.id), ['pinned']);
assert.deepEqual(listRows(rows.map(r=>({...r,group:r.group==='gone'?'gone':'queue'}))).open.map(r=>r.id), open.map(r=>r.id), 'state changes do not reorder rows');
assert.equal(listRows([{...rows[0],group:'gone'}]).gone.length,0, 'attention stays outside history');
assert.ok(src.includes('更早的会话') && src.includes('>PIN</div>'));
assert.deepEqual(rowState(R({ glyph: 'done', tag: ['本轮结束', 'Turn ended'] })), ['空闲', 'Idle'], 'a turn ended is idle to the person');
// the head: code and state, no machine; its own stream's word wins
assert.match(headMeta(R({ glyph: 'work', group: 'work' })), /^K7Q2 · (回答中|Replying)$/);
assert.match(headMeta(R({ glyph: 'work', group: 'work' }), false), /^K7Q2 · (空闲|Idle)$/);
assert.match(headMeta(R({}), true), /^K7Q2 · (回答中|Replying)$/);
assert.equal(openLine(R({})), 'fleet open K7Q2');
// 新回复: a row that left 回答中 between two reads; never one put away
assert.deepEqual(repliesDone({ a: 'work', b: 'work', c: 'idle', d: 'work' },
  [R({ id: 'a', glyph: 'done' }), R({ id: 'b', glyph: 'work' }), R({ id: 'c' }), R({ id: 'd', group: 'gone' })]).map((r) => r.id), ['a']);
// a parked web session reads as any idle one — no mark of its own
const pk = boardRows({ count: 1, groups: {}, gone_days: 7, digest: 'x', rows: [
  { id: 'w1', title: '周报初稿', group: 'ask', tag: 'parked', words: ['停放', 'Parked'], origin: 'web', why: ['停放了', 'parked'], at: 1 },
  { id: 't1', title: '编排', group: 'ask', tag: 'parked', words: ['停放', 'Parked'], origin: 'terminal', at: 1 }] }, [], []);
assert.deepEqual([pk[0].glyph, pk[0].tone, pk[0].tag[0], pk[0].why, pk[0].origin], ['idle', 'muted', '空闲', undefined, 'web']);
assert.deepEqual([pk[1].glyph, pk[1].tag[0]], ['wait', '停放'], 'a terminal\'s parked row stays as it was');


// PV4D: shared board facts reach hover/long-press and the visible status.
const plan = boardRows({rows:[{id:'planned', title:'plan',group:'queue',tag:'queued', words:['未派发','Not dispatched'],
 agent_words:['Codex（计划）','Codex (planned)'], agent_basis:'planned',context:['尚未启动 · 协调负责人：AB12','Not started · Coordinator: AB12'],at:1}]},[],[])[0];
assert.match(rowMeta(plan), /Codex/);
assert.match(rowMeta(plan), /AB12/);
assert.equal(listStatus(plan).kind,null, 'planned allocation alone is not accepted execution');

const workspace = readFileSync(new URL('../src/app/Workspace.tsx', import.meta.url), 'utf8');
assert.ok(!workspace.includes('TerminalView') && !workspace.includes('termOn'), 'task workspace cannot mount terminal backup');
assert.ok(workspace.includes('p.delete("view")') && workspace.includes('toast.info'), 'old terminal links go to conversation with explanation');
assert.ok(workspace.includes('sessionWrite("worker_stop"'), 'explicit stop bypasses gated reap');

const original = listRows(rows);
const changed = rows.map(r => ({...r, at: r.id==='idle'?999999:r.at}));
assert.deepEqual(listRows(changed, original).open.map(r=>r.id), original.open.map(r=>r.id), 'observed timestamp changes do not reorder an open list');
assert.deepEqual(listRows([{...rows[0],id:'pin1',group:'pin',at:1},{...rows[0],id:'pin2',group:'pin',at:999}]).pin.map(r=>r.id),['pin1','pin2'], 'PIN keeps its explicit order');

assert.equal(listStatus(R({board:{pending_start:true}})).kind,'pending', 'hub request observation is authoritative');
assert.equal(listStatus(R({task:v1({task_state:'starting'}),board:{pending_start:false}})).kind,null, 'explicit false disables old-hub inference');

assert.equal(listStatus(R({board:{loop:true}})).kind,'loop');
assert.equal(listStatus(R({board:{tag:'looping',running:true}})).kind,'work');
assert.equal(listStatus(R({board:{tag:'looping',loop:false}})).kind,null, 'waiting for tool/children is not a recurring plan');


const lostPlan = listStatus(R({board:{lost:true, pending_start:true,loop:true}}));
assert.equal(lostPlan.kind,null, 'lost rows have no execution status symbol');
assert.equal(lostPlan.words.length,3, 'details retain last-known request/plan facts and unknown observation');

assert.equal(listStatus(R({board:{tag:'starting'}})).kind,'pending', 'old-hub explicit starting is retained');
assert.equal(listStatus(R({board:{tag:'queued'},task:v1({task_state:'starting'})})).kind,null, 'old board observation beats stale record');
const exitedWindow = R({id:'exited-window',at:1,group:'gone',live:{state:'exited'},board:{tag:'exited'}});
assert.deepEqual(listRows([exitedWindow]).open.map(r=>r.id),['exited-window'], 'agent exit alone does not fold a retained live window');
assert.equal(listRows([exitedWindow]).gone.length,0);
assert.deepEqual(listRows([{...exitedWindow,live:undefined}]).gone.map(r=>r.id),['exited-window'], 'closed window remains in earlier sessions');
console.log('ok session-list.mjs');
