// work.mjs — 会话's one list (T769, src/app/work.ts): a task and its session
// are ONE row (joined by identity), a session no record names is its own row,
// groups follow ⌘P's panel, an EPIC's members sit under it while in its group
// and name it in their own, an EPIC with no members has none, a link's code
// finds its row. Run: node --experimental-strip-types test/work.mjs
import assert from 'node:assert/strict';
import { buildRows, findRow, messagesOf, nestedKids, rowsIn, taskWords } from '../src/app/work.ts';

const now = Date.now();
const iso = (minAgo) => new Date(now - minAgo * 60000).toISOString();
const F = '5b1e0000-0000-4000-8000-00000000f001';
const v1 = (x) => ({ authority_version: 1, generation: 1, created_at: iso(60), title: 'x', ...x });
const fid = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const sess = (id, state, x = {}) => ({ id: `${F}/${id}`, key: id, title: id, repo: '', machine: 'office-mac', state,
  group: state === 'needs' ? 'ask' : 'run', ask: state === 'needs' ? { kind: 'question', msg: 'which colour?' } : null,
  born: (now - 3600e3) / 1000, ended: '', tokens: 0, say: '', ...x });
const gone = (id, x = {}) => ({ id: `${F}/${id}`, key: id, title: id, repo: '', machine: 'office-mac', state: 'ended', group: 'ended',
  ask: null, born: 0, ended: iso(3000), tokens: 0, wid: `${F}/w-${id}`, ...x });

const tasks = [
  v1({ id: 'T1', fid: fid(1), title: 'asks', task_state: 'running', worker_id: `${F}/a`, request_payload: JSON.stringify({ params: { title: 'asks', body: 'the whole ask' } }) }),
  v1({ id: 'T2', fid: fid(2), title: 'epic', task_state: 'running', worker_id: `${F}/e` }),
  v1({ id: 'T3', fid: fid(3), title: 'member working', task_state: 'running', parent_task: fid(2), worker_id: `${F}/m` }),
  v1({ id: 'T4', fid: fid(4), title: 'member queued', task_state: 'accepted', parent_task: fid(2) }),
  v1({ id: 'T5', fid: fid(5), title: 'failed', outcome: 'failed', worker_id: `${F}/w-f`, evidence: '37 rows' }),
  v1({ id: 'T6', fid: fid(6), title: 'merge', task_state: 'running', worker_id: `${F}/p`, pr: 'o/r#12', pr_state: 'waiting' }),
  v1({ id: 'T7', fid: fid(7), title: 'empty epic', task_state: 'accepted' }),
  v1({ id: 'T8', fid: fid(8), title: 'done', outcome: 'succeeded', worker_id: `${F}/w-d`, updated_at: iso(30) }),
  v1({ id: 'T9', fid: fid(9), title: 'waits on you', task_state: 'waiting', asked: 'pick one' }),
  { id: 'T10', title: 'legacy', state: 'open', created_at: iso(10) },
];
const live = [sess('a', 'needs'), sess('e', 'working', { say: 'one of three' }), sess('m', 'working'), sess('p', 'done'), sess('loose', 'idle')];
const ended = [gone('f'), gone('d'), gone('old')];
const rows = buildRows(tasks, live, ended);
const by = (t) => rows.find((r) => r.title === t);

// one row per task, one per unrecorded session: 10 tasks + 1 live + 1 ended
assert.equal(rows.length, 12);
assert.equal(rows.filter((r) => r.live?.key === 'a').length, 1, 'a task and its session are one row');
assert.equal(by('asks').live.key, 'a');
assert.ok(rows.find((r) => r.live?.key === 'loose' && !r.task), 'a session no record names is its own row');
assert.ok(rows.find((r) => r.ended?.key === 'old' && !r.task), 'an ended session no record names is its own row');
assert.equal(by('failed').ended.key, 'f', 'an ended session joins its record by worker_id');

// groups: the panel's
assert.equal(by('asks').group, 'ask');
assert.equal(by('asks').line, 'which colour?');
assert.equal(by('failed').group, 'ask');
assert.equal(by('waits on you').group, 'ask');
assert.equal(by('epic').group, 'work');
assert.equal(by('merge').group, 'queue');
assert.deepEqual(by('merge').tag, ['等合并', 'Awaiting merge']);
assert.equal(rows.find((r) => r.live?.key === 'loose').group, 'queue');
assert.equal(by('done').group, 'gone');
assert.equal(by('legacy').group, 'queue', 'a legacy record is open and unknown, never finished');
assert.deepEqual(by('legacy').tag, ['还不清楚', 'Unknown']);
// a session done is not a task succeeded (T644 C4)
assert.notEqual(by('merge').group, 'gone');

// a record closed as succeeded stays so while its window still runs (T644 C4)
const kept = buildRows([v1({ id: 'T11', fid: fid(11), title: 'kept', outcome: 'succeeded', worker_id: `${F}/k` })], [sess('k', 'working')], []);
assert.deepEqual([kept[0].group, kept[0].tag[1]], ['work', 'Working']);

// EPIC: members listed under it; nested while in its group, else in their own naming it
const epic = by('epic');
assert.deepEqual(epic.kids.map((k) => k.title).sort(), ['member queued', 'member working']);
assert.deepEqual(nestedKids(epic).map((k) => k.title), ['member working']);
assert.ok(!rowsIn(rows, 'work').some((r) => r.title === 'member working'), 'a nested member leaves the top');
assert.ok(rowsIn(rows, 'queue').some((r) => r.title === 'member queued' && r.parentTitle === 'epic'));
assert.equal(by('empty epic').kids.length, 0, 'an EPIC with no members has none to unfold');

// a link's code finds its row: written code, old number, identity
assert.equal(findRow(rows, 'T6')?.title, 'merge');
assert.equal(findRow(rows, `#${by('asks').code.toLowerCase()}`)?.title, 'asks');
assert.equal(findRow(rows, `${F}/loose`)?.live?.key, 'loose');
assert.equal(findRow(rows, ''), undefined);

// the person's own words: a dispatch's request, else the title
assert.equal(taskWords(by('asks').task), 'asks\n\nthe whole ask');
assert.equal(taskWords(by('legacy').task), 'legacy');

// ✦ 消息: asks, failures, what finished today
const kinds = messagesOf(rows).map((m) => `${m.kind}:${m.row.title}`).sort();
assert.deepEqual(kinds, ['ask:asks', 'ask:waits on you', 'done:done', 'fail:failed']);

console.log('ok work.mjs');

// A4G2: the hub's one list — the page draws its rows, groups, order and words as
// they are (the same the ⌘P panel draws); a record and its session are one row
// even when the record never learned a worker_id (joined by the hub, by identity).
{
  const { boardRows } = await import('../src/app/work.ts');
  const ts = [v1({ id: 'T20', fid: fid(20), title: 'running task', task_state: 'accepted' }),
    v1({ id: 'T21', fid: fid(21), title: 'member', task_state: 'accepted', parent_task: fid(20) })];
  const lv = [sess('k20', 'working', { say: 'step 2' })];
  const board = { count: 3, groups: { pin: 1, work: 2, gone: 1 }, gone_days: 7, digest: 'x', rows: [
    { id: 'p1', title: '编排', group: 'pin', tag: 'looping', words: ['在循环', 'Looping'], at: 50 },
    { id: fid(20), task: 'T20', task_id: fid(20), title: 'running task', group: 'work', tag: 'working', words: ['在干活', 'Working'], worker_id: `${F}/k20`, at: 40 },
    { id: fid(21), task: 'T21', task_id: fid(21), title: 'member', group: 'work', tag: 'working', words: ['在干活', 'Working'], parent: fid(20), depth: 1, at: 30 },
    { id: 'g1', title: 'old', group: 'gone', tag: 'ended_no_result', words: ['结束·没交回结果', 'Ended · no result'], at: 10 },
  ] };
  const br = boardRows(board, ts, lv);
  assert.deepEqual(br.map((r) => r.group), ['pin', 'work', 'work', 'gone'], 'the hub order and groups stand');
  assert.equal(br[1].live.key, 'k20', 'the row joins its live session by worker_id');
  assert.equal(br[1].task.id, 'T20', 'and its record by the record ID');
  assert.equal(br[1].line, 'step 2');
  assert.deepEqual(br[3].tag, ['结束·没交回结果', 'Ended · no result'], 'the hub words');
  assert.deepEqual(rowsIn(br, 'work').map((r) => r.title), ['running task'], 'a member sits under its parent');
  assert.deepEqual(nestedKids(br[1]).map((r) => r.title), ['member']);
  console.log('ok — the one list (A4G2)');
}

// E101: what the hub says is still holding a row rides on it as it is (its
// words, its tone); a parked row is a clock in the ask colour and joins its
// ended session (接回 wakes it); a stopped one is a red cross.
{
  const { boardRows } = await import('../src/app/work.ts');
  const ts = [v1({ id: 'T30', fid: fid(30), title: 'parked', task_state: 'running', worker_id: `${F}/w-p` }),
    v1({ id: 'T31', fid: fid(31), title: 'poster', outcome: 'succeeded', worker_id: `${F}/k31` })];
  const board = { count: 2, groups: { ask: 2, queue: 1 }, gone_days: 7, digest: 'x', rows: [
    { id: fid(30), task: 'T30', task_id: fid(30), title: 'parked', group: 'ask', tag: 'parked', words: ['已停放 · 等你', 'Parked · waiting on you'], at: 40,
      why: ['已停放 · 在等你点头，回话即唤醒', 'Parked · waiting for your go-ahead — reply to wake it'], why_tone: 'orange' },
    { id: 'st', title: 'stopped', group: 'ask', tag: 'stopped', words: ['出错停住', 'Stopped on an error'], at: 30,
      why: ['出错停住：要你看一下', 'Stopped on an error: needs a look'], why_tone: 'red' },
    { id: fid(31), task: 'T31', task_id: fid(31), title: 'poster', group: 'queue', tag: 'completed', words: ['已完成', 'Completed'], worker_id: `${F}/k31`, at: 20,
      why: ['还没收：做完了，后台的活还在跑 · 18 分钟后收', 'Not closed yet: done, but a background job is still running · closes in 18 min'] },
  ] };
  const br = boardRows(board, ts, [sess('k31', 'looping')], [gone('p')]);
  assert.deepEqual([br[0].glyph, br[0].tone, br[0].whyTone], ['wait', 'ask', 'orange'], 'parked: a clock in the ask colour');
  assert.equal(br[0].ended?.wid, `${F}/w-p`, 'parked joins its ended session — its 接回');
  assert.deepEqual([br[1].glyph, br[1].tone, br[1].whyTone], ['fail', 'fail', 'red'], 'stopped: a red cross');
  assert.equal(br[2].why[0], '还没收：做完了，后台的活还在跑 · 18 分钟后收');
  assert.equal(br[2].whyTone, 'grey', 'no tone said: grey');
  assert.equal(boardRows({ ...board, rows: [{ ...board.rows[2], why: undefined }] }, ts, []).at(0).why, undefined, 'nothing said, no line');
  console.log('ok — why it is still open (E101)');
}

// PV4D: board-only plans retain the hub's explicit evidence and coordinator.
{
 const { boardRows, GROUPS } = await import('../src/app/work.ts');
 const facts = {id:'plan', title:'not launched', group:'queue', tag:'queued', words:['未派发','Not dispatched'],
   agent:'codex', agent_basis:'planned', agent_words:['Codex（计划）','Codex (planned)'],
   context:['尚未启动 · 协调负责人：AB12','Not started · Coordinator: AB12'], coordinator:'AB12', at:1};
 const [r] = boardRows({rows:[facts]}, [], []);
 assert.equal(r.live, undefined);
 assert.equal(r.board.agent_basis,'planned');
 assert.equal(r.board.coordinator,'AB12');
 assert.deepEqual(r.tag,facts.words);
 assert.equal(GROUPS.find(x=>x.g==='queue').label[1],'Pending / retained');
}
