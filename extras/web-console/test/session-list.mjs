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
import { compactRows, descendants, foldedDup, fromRow, members, sessionTree, treeAt, treeContext, treeLines, urgentOf, headMeta, isTerminal, isUnread, listItem, listRows, listStatus, machineCount, needsAttention, matchRow, openFor, openLine, repliesDone, rowMeta, rowRef, rowState, clockOrDay, rowsSignal, scheduleLabel, scheduleLines, scheduleResult, scheduleRuns, searchRows, seenMark } from '../src/app/session-list.ts';
import { bellGroups, runFailed } from '../src/app/notices.ts';
import { scheduleSeed } from '../src/app/new-session.ts';

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
assert.equal(rowRef(open[0]), fid(30));
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
assert.equal(listStatus(R({ glyph: 'ask', group: 'ask' })).kind, null, 'a historical glyph is not a current native request');
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
assert.ok(src.includes('更多会话') && !src.includes('>PIN</div>') && !src.includes('attention-next'), 'no PIN heading, no 待处理 · N');
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
assert.ok(workspace.includes('await stopRow(r)'), 'explicit stop uses the shared Task-aware route');

const original = listRows(rows);
const changed = rows.map(r => r.id === 'idle' ? {...r, board: {...r.board, activity_at: 999}} : r);
assert.equal(listRows(changed, original).open[0].id, 'idle', 'an older conversation moves first after new turn activity');
assert.deepEqual(listRows(rows.map(r => ({...r, glyph:'work'})), original).open.map(r=>r.id), original.open.map(r=>r.id), 'status alone does not reorder conversations');
const histories = [10, 20].map((at, i) => ({...gone[0], id:`history-${i}`, at:at*1000, board:{...gone[0].board, activity_at:i ? 5 : 30}}));
assert.deepEqual(listRows(histories).gone.map(r=>r.id), ['history-0', 'history-1'], 'history uses turn activity, not window closure');
assert.deepEqual(listRows([...histories].reverse()).gone.map(r=>r.id), ['history-0', 'history-1']);
assert.deepEqual(listRows(histories.map(r=>({...r, board:{...r.board, activity_at:30}}))).gone.map(r=>r.id), ['history-0', 'history-1'], 'equal timestamps use identity');
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

// The same policy fixtures are consumed by fleet-view-task-list-selftest.py.
const policyCases = JSON.parse(readFileSync(new URL('./fixtures/session-list-policy.json', import.meta.url), 'utf8'));
for (const c of policyCases) {
  const input = c.rows.map((r) => R({ ...r, code: r.id, at: r.activity_at * 1000,
    board: { ...r, running: r.state === 'working', lost: r.state === 'unknown' },
    live: r.group === 'gone' ? undefined : { state: r.state } }));
  const groups = compactRows(input, { current: c.current, preferences: c.preferences, now: c.now * 1000 });
  assert.deepEqual([...groups.pin, ...groups.open].map(r => r.id), c.visible, c.name);
  assert.deepEqual(groups.gone.map(r => r.id), c.more, c.name);
  const sourced = [...groups.sources.schedule, ...groups.sources.api];
  // a session's own (agent) has no group of its own any more: the main list, under its opener
  assert.equal(groups.sources.agent, undefined, `${c.name}: no agent group`);
  assert.deepEqual(c.sources.agent, [], `${c.name}: the fixture names no agent group`);
  for (const k of ['schedule', 'api']) assert.deepEqual(groups.sources[k].map(r => r.id), c.sources[k], `${c.name}: ${k}`);
  assert.deepEqual([...groups.pin, ...groups.open, ...sourced].filter(needsAttention).map(r => r.id), c.attention, c.name);
  assert.equal(new Set([...groups.pin, ...groups.open, ...groups.gone, ...sourced].map(r => r.id)).size, input.length);
  assert.equal(searchRows([...groups.pin, ...groups.open, ...groups.gone, ...sourced], '').length, input.length);
}
const freshRows = Array.from({length:12}, (_,i) => R({id:`fresh${i}`, code:`fresh${i}`, at:now-i*1000}));
const initial = compactRows(freshRows, {now});
const changedRows = freshRows.map(r => r.id==='fresh11' ? {...r,at:now+1000} : r);
const frozen = compactRows(changedRows, {now,previous:initial,interacting:true});
assert.deepEqual(frozen.open.map(r=>r.id), initial.open.map(r=>r.id), 'interaction keeps row positions');
assert.equal(compactRows(changedRows,{now,previous:frozen}).open[0].id,'fresh11', 'new Turn returns a folded session');
assert.equal(compactRows(changedRows,{now,previous:frozen,interacting:true,current:'fresh10'}).open.some(r=>r.id==='fresh10'),true,'opening hidden session protects it immediately');

// X24T: inside 定时任务 a schedule's runs fold under it — by schedule_id, else
// by the title without its day; the newest run and any working / asking run show.
{
  const run = (id, title, x = {}) => ({ id, title, at: 0, group: 'gone', board: { source: 'schedule', ...x } });
  assert.equal(scheduleLabel('LivePage 模板工厂 10-30'), 'LivePage 模板工厂');
  assert.equal(scheduleLabel('LivePage 模板工厂 10-30 #2'), 'LivePage 模板工厂');
  assert.equal(scheduleLabel('Group brief 2026-10-30'), 'Group brief');
  assert.equal(scheduleLabel('daily-2026-10-31'), 'daily');
  assert.equal(scheduleLabel('daily-2026-10-31-2'), 'daily');
  assert.equal(scheduleLabel('10-30'), '10-30', 'a title that is only a day stays');
  const runs = scheduleRuns([
    run('a3', 'Brief 10-31', { schedule_id: 's1' }),
    run('d2', 'daily-2026-10-31'),
    run('a2', 'Brief 10-30', { schedule_id: 's1', state: 'needs' }),
    run('a1', 'Brief renamed 10-29', { schedule_id: 's1' }),
    run('d1', 'daily-2026-10-30'),
    run('b1', 'Brief 10-28', { schedule_id: 's2' }),
  ]);
  assert.deepEqual(runs.map(g => [g.key, g.label, g.shown.map(r => r.id), g.older.map(r => r.id)]), [
    ['s1', 'Brief', ['a3', 'a2'], ['a1']],
    ['title:daily', 'daily', ['d2'], ['d1']],
    ['s2', 'Brief', ['b1'], []],
  ], 'one line per schedule; an asking run is never folded; same name, other schedule apart');
  assert.deepEqual(scheduleRuns([]), []);
}
// Y8XY / PV5W: a schedule's runs never reach the main list — running, waiting
// to start or asking. 定时任务 · N holds them: one line per schedule (its own
// order), its runs newest first under it, the most urgent run its dot, its last
// result (✓/✗ HH:MM today, else MM-DD) or 下次 HH:MM; the runs of a schedule the
// list does not have gather on 其他运行.
{
  const run = (id, x = {}, b = {}) => ({ id, title: id, at: 0, group: 'run', ...x, board: { source: 'schedule', ...b } });
  const rows = [
    run('w', {}, { schedule_id: 's1', running: true, activity_at: 9 }),
    run('p', {}, { schedule_id: 's1', pending_start: true, activity_at: 8 }),
    run('q', {}, { schedule_id: 's2', state: 'needs', activity_at: 7 }),
    run('e', { group: 'gone' }, { schedule_id: 's1', tag: 'ended', activity_at: 6 }),
    run('x', { group: 'gone' }, { schedule_id: 'deleted', tag: 'ended', activity_at: 5 }),
    run('y', { group: 'gone' }, { tag: 'ended', activity_at: 4 }),
    run('arch', {}, { schedule_id: 's1', running: true, archived: true }),
    { id: 'mine', title: 'mine', at: 0, group: 'run', board: { running: true } },
  ];
  const g = compactRows(rows, { now });
  assert.deepEqual([...g.pin, ...g.open, ...g.gone].map(r => r.id), ['mine'], 'the main list is the person\'s own sessions only');
  // 2026-11-03 13:17 and 2026-11-02 07:10 in Shanghai; "now" 2026-11-03 18:00
  const at = (iso) => Date.parse(iso) / 1000;
  const nowMs = Date.parse('2026-11-03T18:00:00+08:00');
  const spec = (id, name, observed, x = {}) => ({ spec: { id, name, timezone: 'Asia/Shanghai', enabled: true, ...x }, observed });
  const schedules = [
    spec('s2', 'Weekly notes', { last_run: at('2026-11-02T07:10:00+08:00'), last_result: 'failed' }),
    spec('s1', 'Group brief', { last_run: at('2026-11-03T13:17:00+08:00'), last_result: 'ok' }),
    spec('s3', 'Never ran', { next_run: at('2026-11-04T07:10:00+08:00') }),
    spec('s4', 'Paused', { next_run: at('2026-11-04T07:10:00+08:00') }, { enabled: false }),
  ];
  const sl = scheduleLines(schedules, rows, nowMs);
  assert.deepEqual(sl.lines.map((l) => [l.id, l.runs.map((r) => r.id), l.urgent?.id, l.failed, l.result]), [
    ['s2', ['q'], 'q', true, '✗ 11-02'],
    ['s1', ['w', 'p', 'e'], 'w', false, '✓ 13:17'],
    ['s3', [], undefined, false, scheduleResult(schedules[2], nowMs)],
    ['s4', [], undefined, false, ''],
  ], 'one line per schedule in its order: runs newest first, the most urgent run, the last result');
  assert.match(scheduleResult(schedules[2], nowMs), /^(下次|Next) 11-04$/);
  assert.match(scheduleResult(spec('s5', 'x', { next_run: at('2026-11-03T21:05:00+08:00') }), nowMs), /^(下次|Next) 21:05$/, 'today: its clock');
  assert.deepEqual(sl.other.map((r) => r.id), ['x', 'y'], 'a run of an unlisted schedule stays reachable');
  assert.equal(clockOrDay(at('2026-11-03T00:05:00+08:00'), 'Asia/Shanghai', nowMs), '00:05');
  // the hub sends ISO strings too (a live board crashed on them): read, never thrown
  assert.equal(clockOrDay('2026-11-02T16:05:00Z', 'Asia/Shanghai', nowMs), '00:05', 'an ISO time is read');
  assert.equal(clockOrDay('not a time', 'Asia/Shanghai', nowMs), '', 'an unreadable time is nothing');
  assert.equal(clockOrDay('2026-11-02T16:05:00Z', 'Not/AZone', nowMs) !== undefined, true, 'a bad zone falls back');
  assert.match(scheduleResult(spec('s6', 'x', { last_run: '2026-11-02T16:05:00Z' }), nowMs), /^✓ 00:05$/);
  assert.match(scheduleResult(spec('s7', 'x', { next_run: 'garbage' }), nowMs), /^$/);
  assert.equal(clockOrDay(at('2026-11-03T00:05:00+08:00'), 'America/Los_Angeles', nowMs), '11-02', 'the day in the schedule\'s own zone');
  assert.equal(rowsSignal(sl.lines[1].runs), 'work');
  assert.equal(rowsSignal([...sl.lines[0].runs, ...sl.lines[1].runs]), 'ask', 'asking over working');
  assert.deepEqual(scheduleLines([], []), { lines: [], other: [] });
}
console.log('session-list: schedule runs OK');

// 通知 (task PV5W): the bell counts asking + new results + FAILED schedule runs;
// a schedule that did its job is listed, never counted. Asking oldest first,
// schedule runs merged per schedule, a failed one first.
{
  const nowMs = Date.parse('2026-11-03T18:00:00+08:00');
  const s = Math.floor(nowMs / 1000);
  const R = (id, b = {}, x = {}) => ({ id, title: id, at: 0, glyph: 'idle', tone: 'muted', group: 'queue', tag: ['空闲', 'Idle'], line: '', kids: [], ...x, board: { id, tag: 'idle', ...b } });
  const rows = [
    R('ask-new', { state: 'needs', activity_at: s - 10 }),
    R('ask-old', { state: 'needs', activity_at: s - 500 }),
    R('done1', { activity_at: s - 20 }),
    R('done-asking', { state: 'needs', activity_at: s - 30 }),
    R('quiet', { activity_at: s - 40 }),
    R('arch', { state: 'needs', archived: true }),
  ];
  const run = (id, sid, state, ended, x = {}) => ({ id, schedule_id: sid, state, started: ended - 60, ended, summary: `sum ${id}`, error: '', ...x });
  const unread = [
    run('a1', 'brief', 'ok', s - 3600), run('a2', 'brief', 'ok', s - 60),
    run('b1', 'notes', 'failed', s - 7200, { error: 'boom' }),
    run('c1', 'old', 'ok', s - 3 * 86400),
  ];
  const g = bellGroups(rows, { done1: 'x', 'done-asking': 'y', gone: 'z' }, unread, { brief: 'Group brief', notes: 'Weekly notes' }, nowMs);
  assert.deepEqual(g.asking.map((r) => r.id), ['ask-old', 'done-asking', 'ask-new'], 'oldest wait first; never an archived one');
  assert.deepEqual(g.results.map((r) => r.id), ['done1'], 'a new result once, not twice beside its ask');
  assert.deepEqual(g.schedules.map((x) => [x.id, x.runs.length, x.failed, x.line]), [['notes', 1, 1, 'boom'], ['brief', 2, 0, 'sum a2'], ['old', 1, 0, 'sum c1']], 'merged per schedule, a failed one first');
  assert.match(g.schedules[1].label, /^(Group brief · 今天 2 次|Group brief · 2 today)$/);
  assert.match(g.schedules[2].label, /^(old · 1 次|old · 1 runs)$/);
  assert.equal(g.count, 3 + 1 + 1, 'asking 3 + new result 1 + failed run 1 — successful runs are not counted');
  assert.equal(bellGroups(rows, {}, unread.filter((r) => r.state === 'ok'), {}, nowMs).count, 3, 'success alone adds nothing');
  assert.ok(runFailed({ state: 'failed', error: '' }) && runFailed({ state: 'stopped', error: 'x' }) && !runFailed({ state: 'ok', error: '' }));
  assert.equal(bellGroups(null, {}, [], {}, nowMs).count, 0);
  const bell = readFileSync(new URL('../src/app/Bell.tsx', import.meta.url), 'utf8');
  for (const w of ['在问你', '新结果', '定时任务', '说明', '全部已读', 'readSchedule(read', 'markSeen(r)', 'Popover', 'Sheet'])
    assert.ok(bell.includes(w), `the bell has ${w}`);
  assert.ok(bell.includes('open && "text-clay"'), 'the bell is clay while open');
  const shell = readFileSync(new URL('../src/app/Shell.tsx', import.meta.url), 'utf8');
  assert.ok(!shell.includes('ScheduleNotice') && !shell.includes('LegacyMigrationNotice') && !shell.includes('定时任务有新结果'), 'no bars over the page');
  assert.ok(shell.includes('<Bell />') && shell.includes('<Bell phone'), 'a bell on the sidebar head and the phone bar');
  assert.ok(shell.indexOf('<Bell phone') < shell.indexOf('to={meTab("account").path}'), 'left of the avatar');
  assert.ok(shell.includes('<TrialBar') && shell.includes('<NetBarOf />') && shell.includes('<ReplyToast />'));
  assert.ok(!shell.includes('StudioLink') && shell.includes('<Sparkles />增长运营 Agent'), '增长运营 Agent lives in the person menu only');
  assert.ok(!shell.includes('NewScheduleButton') && !src.includes('NewScheduleButton'), 'no separate schedule button');
  assert.ok(src.includes('data-new-split') && src.includes('新建定时任务') && src.includes('schedulePath("new")'), '新会话 is a split button with 新建定时任务');
  const ns = readFileSync(new URL('../src/app/NewSession.tsx', import.meta.url), 'utf8');
  const nd = readFileSync(new URL('../src/app/NewDialog.tsx', import.meta.url), 'utf8');
  for (const f of [ns, nd]) assert.ok(f.includes('定时运行') && f.includes('scheduleSeed(') && f.includes('schedulePath("new")'), 'the 定时运行 switch hands the words to the schedule form');
  assert.deepEqual(scheduleSeed('Daily brief\nsummarise it', 'codex', 'o/r'), { prompt: 'Daily brief\nsummarise it', name: 'Daily brief', agent: 'codex', repo: 'o/r' });
  assert.deepEqual(scheduleSeed('x', 'deepseek'), { prompt: 'x', name: 'x', agent: '', repo: '' });
}
console.log('session-list: bell OK');

// 子会话挂在发起会话下面 (v5): a session another opened hangs under it — ordered
// by the tree's activity, always folded until the person opens it (folded hides
// everything, asking too: the ▸ and (N) say so by colour — clay over green),
// only the session open now drawn through a fold, at most two steps in;
// same-title duplicates of one opener fold into one line ×N; an older hub's rows
// (no `from`) stay exactly as flat as before, and there is no 会话派出的 group.
{
  const T = (id, b = {}, x = {}) => ({ id, code: '', title: `t-${id}`, glyph: 'idle', tone: 'muted', group: 'queue', tag: ['空闲', 'Idle'],
    line: '', quote: false, kids: [], at: (b.activity_at || 0) * 1000, ...x, board: { id, title: `t-${id}`, group: 'queue', tag: 'idle', words: ['空闲', 'Idle'], at: 0, ...b } });
  const kid = (id, parent, b = {}, x = {}) => T(id, { parent, from: `fid-${parent}`, source: 'agent', ...b }, x);
  const ids = (rs) => rs.map((r) => r.id);
  const nowS = Math.floor(now / 1000);

  // roots by tree_at: an old opener whose child just spoke passes a newer idle root;
  // siblings by their own tree_at; a subtree never leaves its root
  const rows = [
    T('a', { activity_at: nowS - 300, tree_at: nowS - 10 }),
    T('b', { activity_at: nowS - 100 }),
    kid('a1', 'a', { activity_at: nowS - 200 }),
    kid('a2', 'a', { activity_at: nowS - 50, tree_at: nowS - 10 }),
    kid('a2x', 'a2', { activity_at: nowS - 10 }),
  ];
  const g = compactRows(rows, { now });
  assert.deepEqual(ids(g.open), ['a', 'b'], 'roots only, by tree activity');
  assert.deepEqual(ids(g.tree.kids.get('a')), ['a2', 'a1'], 'siblings newest tree first');
  assert.equal(treeAt(g.tree)(rows[0]), (nowS - 10) * 1000);
  const zt = [T('z', { activity_at: 5 }), kid('z1', 'z', { activity_at: 9 })];
  assert.equal(treeAt(sessionTree(zt))(zt[0]), 9000, 'no tree_at: the newest of the subtree');
  assert.deepEqual(ids(descendants(g.tree, rows[0])), ['a2', 'a2x', 'a1'], 'depth first');

  // folded by default, (N) of what is hidden, a grey ▸
  const folded = treeLines(g.open, g.tree);
  assert.deepEqual(folded.map((l) => [l.r.id, l.depth, l.kids, l.open, l.hidden, l.signal]), [['a', 0, 2, false, 3, ''], ['b', 0, 0, false, 0, '']]);
  // a person's toggle wins; open shows each level, at most two steps in
  const opened = treeLines(g.open, g.tree, { a: true, a2: true });
  assert.deepEqual(opened.map((l) => [l.r.id, l.depth]), [['a', 0], ['a2', 1], ['a2x', 2], ['a1', 1], ['b', 0]]);
  const deep = [T('d0', { activity_at: 4 }), kid('d1', 'd0', { activity_at: 3 }), kid('d2', 'd1', { activity_at: 2 }), kid('d3', 'd2', { activity_at: 1 })];
  const dt = sessionTree(deep);
  assert.deepEqual(treeLines([deep[0]], dt, { d0: true, d1: true, d2: true }).map((l) => l.depth), [0, 1, 2, 2], 'depth ≥ 2 drawn at 2');

  // working under it: still folded by default; the ▸ goes green
  const busy = rows.map((r) => r.id === 'a1' ? { ...r, board: { ...r.board, running: true } } : r);
  const bt = sessionTree(busy);
  const shut = treeLines([busy[0]], bt)[0];
  assert.deepEqual([shut.open, shut.hidden, shut.signal], [false, 3, 'work'], 'folded with a working one inside: green');
  assert.equal(treeLines([busy[0]], bt, { a: true }).find((l) => l.r.id === 'a2').signal, '', 'only what is hidden counts');

  // asking the person: folded means folded — hidden too, the ▸ and (N) in clay (over green)
  const ask = busy.map((r) => r.id === 'a2x' ? { ...r, board: { ...r.board, state: 'needs' } } : r);
  const at2 = sessionTree(ask);
  const hid = treeLines([ask[0]], at2);
  assert.deepEqual(hid.map((l) => [l.r.id, l.open, l.hidden, l.signal]), [['a', false, 3, 'ask']], 'an asking child is hidden under a fold');
  assert.deepEqual(treeLines([ask[0]], at2, { a: true }).map((l) => [l.r.id, l.signal]), [['a', ''], ['a2', 'ask'], ['a1', '']], 'the fold nearest it says so');
  // only the session open now is drawn through a fold (待处理 · N reaches it that way)
  const cur = treeLines([ask[0]], at2, {}, 'a2x');
  assert.deepEqual(cur.map((l) => [l.r.id, l.depth]), [['a', 0], ['a2x', 2]]);
  assert.equal(cur[0].hidden, 2);
  // and never in More: an idle root days old stays shown while one under it asks
  const stale = ask.map((r) => ({ ...r, board: { ...r.board, activity_at: nowS - 3 * 86400, tree_at: undefined, running: false } }));
  const filler = Array.from({ length: 12 }, (_, i) => T(`f${i}`, { activity_at: nowS - i }));
  const kept = compactRows([...stale, ...filler], { now });
  assert.ok(ids(kept.open).includes('a') && !ids(kept.gone).includes('a'), 'a tree holding an ask is never folded into More');
  assert.ok(!ids(kept.open).includes('a2x') && !ids(kept.gone).includes('a2x'), 'a child is never a top-level row');

  // PIN: a pinned opener takes its subtree; the subtree stays out of the time order
  const pinned = compactRows(rows.map((r) => r.id === 'a' ? { ...r, group: 'pin' } : r), { now });
  assert.deepEqual([ids(pinned.pin), ids(pinned.open)], [['a'], ['b']]);
  assert.deepEqual(treeLines(pinned.pin, pinned.tree, { a: true }).map((l) => l.r.id), ['a', 'a2', 'a1']);

  // holding still while pointed at: a subtree moves with its root, a row nested since leaves the top
  const before = compactRows([T('p', { activity_at: nowS - 5 }), T('q', { activity_at: nowS - 1 })], { now });
  const after = compactRows([T('p', { activity_at: nowS - 5 }), kid('q', 'p', { activity_at: nowS })], { now, previous: before, interacting: true });
  assert.deepEqual(ids(after.open), ['p']);
  assert.deepEqual(ids(after.tree.kids.get('p')), ['q']);

  // a session's own (agent) is an ordinary row: no group of its own
  const loose = compactRows([T('mine', { activity_at: nowS - 2 }), T('bot', { source: 'agent', from: 'fid-x', activity_at: nowS - 1 })], { now });
  assert.deepEqual(ids(loose.open), ['bot', 'mine']);
  assert.deepEqual(Object.keys(loose.sources).sort(), ['api', 'schedule']);

  // a live child of an ended opener: not nested (the hub sends no parent); the
  // list says nothing of it — the detail pane's 来自 … reaches its history row
  const orphan = T('live', { from: 'fid-old', from_title: '老会话', from_ended: true, activity_at: nowS });
  const ended = T('old', { history: { id: 'fid-old', status: 'ended' } }, { group: 'gone' });
  const ot = sessionTree([orphan, ended]);
  assert.equal(ot.up.size, 0);
  assert.equal(fromRow([orphan, ended], orphan), ended, 'its history row is the way to it');
  assert.equal(fromRow([orphan], orphan), undefined, 'none: plain text');
  assert.ok(!src.includes('data-from-line') && !src.includes('fromLine'), 'no 来自 line in the list');
  assert.ok(page.includes('（已结束）') && page.includes('tree-crumb'), 'the detail pane keeps 来自 …');

  // same-title duplicates of one opener fold: the newest shown, ×N, the most urgent status
  const dup = [
    T('o', { activity_at: nowS - 100 }),
    kid('d1', 'o', { activity_at: nowS - 30 }, { title: 'Fix the cache' }),
    kid('d2', 'o', { activity_at: nowS - 20, state: 'needs' }, { title: ' fix  the cache ' }),
    kid('d3', 'o', { activity_at: nowS - 10 }, { title: 'Fix the cache' }),
    kid('other', 'o', { activity_at: nowS - 5 }, { title: 'Something else' }),
    kid('src', 'o', { activity_at: nowS - 1, source: 'api' }, { title: 'Fix the cache' }),
    T('top1', { from: 'fid-gone', activity_at: nowS - 50 }, { title: 'Daily' }),
    T('top2', { from: 'fid-gone', activity_at: nowS - 40 }, { title: 'Daily' }),
    T('plain1', { activity_at: nowS - 60 }, { title: 'Daily' }),
    T('plain2', { activity_at: nowS - 61 }, { title: 'Daily' }),
  ];
  const dg = compactRows(dup, { now });
  const dtr = dg.tree;
  assert.deepEqual(ids(dtr.kids.get('o')), ['src', 'other', 'd3'], 'one line for the duplicates, the newest; another source stays apart');
  assert.deepEqual(ids(members(dtr, dup[3])), ['d3', 'd2', 'd1']);
  assert.ok(foldedDup(dtr, dup[1]) && foldedDup(dtr, dup[2]) && !foldedDup(dtr, dup[3]));
  assert.equal(urgentOf(dtr, dup[3]).id, 'd2', 'the line draws its asking duplicate\'s status');
  assert.equal(urgentOf(dtr, dup[4]).id, 'other');
  assert.deepEqual(ids(dg.open), ['o', 'top2', 'plain1', 'plain2'], 'top level with the same from folds; no from never merges');
  assert.deepEqual(ids(members(dtr, dup[7])), ['top2', 'top1']);
  assert.equal(treeLines([dup[0]], dtr)[0].signal, 'ask', 'a folded duplicate\'s ask reaches the ▸');
  assert.deepEqual(ids(searchRows(dup, 'fix the')), ['d1', 'd3', 'src'], 'a folded duplicate is still found');
  assert.ok(!compactRows(dup.map((r) => r.id === 'd2' ? { ...r, board: { ...r.board, activity_at: nowS - 5 * 86400 } } : r), { now }).gone.some((r) => r.id === 'o'));
  assert.ok(page.includes('同名会话') && page.includes('Same-title sessions'), 'the detail pane lists the same-title sessions');

  // search: a hit under another names it — 父标题 › 子标题 — and a folded one is found
  assert.equal(treeContext(g.tree, rows[4]), 't-a2');
  assert.equal(treeContext(g.tree, rows[0]), '');
  assert.deepEqual(ids(searchRows(rows, 't-a2x')), ['a2x']);

  // an older hub: `parent` without `from` (an EPIC's members) — flat, exactly as before
  const oldGroups = compactRows(boardRows(board, tasks, live), { now });
  assert.equal(oldGroups.tree.kids.size, 0);
  assert.equal(oldGroups.tree.dupes.size, 0);
  const stripped = compactRows(boardRows(board, tasks, live).map((r) => ({ ...r, parent: undefined, board: r.board && { ...r.board, parent: undefined, depth: undefined } })), { now });
  for (const k of ['pin', 'open', 'gone']) assert.deepEqual(ids(oldGroups[k]), ids(stripped[k]), `old hub ${k}`);
  assert.deepEqual(treeLines(oldGroups.open, oldGroups.tree).map((l) => [l.depth, l.kids]), oldGroups.open.map(() => [0, 0]));
  // a schedule run is never an opener here: its runs live in the ⏰ card
  assert.equal(sessionTree([T('run', { source: 'schedule' }), kid('sub', 'run')]).up.size, 0);
  // a cycle a cached board might carry is cut, never looped
  assert.ok(sessionTree([kid('x', 'y'), kid('y', 'x')]).up.size < 2);

  // a row the hub could not date: its activity dates it, ages too
  const undated = boardRows({ rows: [{ id: 'u', title: 'u', group: 'queue', tag: 'idle', words: ['空闲', 'Idle'], at: 0, activity_at: 1234, history: { id: 'h', resume_id: 'r' } }] }, [], [])[0];
  assert.equal(undated.at, 1234000);
  assert.equal(undated.ended.ended, new Date(1234000).toISOString());

  // the row: ▾ / ▸ before the title, ×N and (N) after it, asking said by colour,
  // still glyphs, no why line but a parked one's, no 会话派出的 group
  assert.ok(!src.includes('会话派出的') && !src.includes('From sessions'), 'no 会话派出的 group');
  const rowSrc = src.slice(src.indexOf('const Twisty: FC'), src.indexOf('const WebChatRow'));
  assert.ok(rowSrc.includes('"▾"') && rowSrc.includes('"▸"') && rowSrc.includes('SIGNAL[line.signal]'), 'the twisty and its colour');
  assert.match(src, /SIGNAL: Record<Signal, string> = \{ ask: "text-clay", work: "text-ok", "": "text-muted-foreground" \}/, 'clay over green over grey');
  assert.ok(rowSrc.indexOf('<Twisty') < rowSrc.indexOf('{it.title}') && rowSrc.indexOf('{it.title}') < rowSrc.indexOf('×{dupes}') && rowSrc.indexOf('×{dupes}') < rowSrc.indexOf('({line.hidden})'));
  assert.ok(rowSrc.includes('line.signal === "ask" ? "text-clay font-medium"'), '(N) in clay while an ask is hidden');
  assert.ok(rowSrc.includes('asking && "text-clay"'), 'the title in the ask colour');
  assert.ok(rowSrc.includes('r.board?.tag === "parked" && r.why ? <RowWhy'), 'the why line only for a parked row');
  for (const w of ['在问你', 'Asking', '⚑', '↳']) assert.ok(!rowSrc.includes(w), `a row draws no ${w}`);
  assert.ok(!/animate-(spin|pulse)/.test(src) && !/animate-(spin|pulse)/.test(page), 'nothing in the list spins or pulses');
  // the section headers (定时任务, API): the chevron's colour, no 个在问你
  const groupSrc = src.slice(src.indexOf('const header = '), src.indexOf('{archiveToggle}\n      </>'));
  assert.ok(groupSrc.includes('SIGNAL[signal]') && !groupSrc.includes('在问你') && !groupSrc.includes('asking`'));
  // pinned first with no heading → the list → More → 定时任务 → API → archived;
  // no ⏰ card anywhere, no 待处理 · N
  const order = ['[...lines(pin), ...lines(open)].map(treeRow)', '更多会话', 'data-source-group="schedule"', 'data-source-group={src}', '{archiveToggle}\n      </>'].map((s) => src.indexOf(s));
  assert.ok(order.every((x, i) => x > 0 && (!i || x > order[i - 1])), `section order ${order}`);
  assert.ok(!src.includes('ScheduleGroup') && !src.includes('<section aria-label'), 'no schedules card');
  const sched = src.slice(src.indexOf('const ScheduleLineRow: FC'), src.indexOf("// the open session's ref"));
  assert.ok(sched.includes('schedulePath(s.id)') && sched.includes('<RowGlyph r={s.urgent} />') && sched.includes('s.failed ? "text-destructive"') && sched.includes('data-schedule-result'), 'a schedule is a row: its dot, red when failed, its result, opens the schedule');
  assert.ok(sched.indexOf('"▾"') > 0 && sched.indexOf('({s.runs.length})') > 0, 'its runs fold under it, (N) when folded');
  assert.ok(src.includes('toggle(`schedule:${key}`, o)') && src.includes('opened[`schedule:${id}`]'), 'a schedule\'s fold is remembered with the tree\'s');
  // 置顶: no heading, a clay pin at a top-level row's end (a click unpins), a faint one on hover pins (computer); the phone's in its long-press sheet
  const pinSrc = src.slice(src.indexOf('const usePin = '), src.indexOf('const SessionRow: FC'));
  assert.ok(pinSrc.includes('pinSession(worker, on)') && pinSrc.includes('已置顶 · 点击取消') && pinSrc.includes('"text-clay"') && pinSrc.includes('opacity-0 group-hover/menu-item:opacity-100'));
  assert.ok(pinSrc.includes('if (variant === "page" || !worker) return pinned ?'), 'the phone draws the pin, never a hover button');
  assert.ok(src.includes('pinnable: !l.depth') && src.includes('pinnable={topLevel}') && src.includes('<PressPin'), 'a child never wears it; the phone pins from its sheet');
}
console.log('session-list: session tree OK');
