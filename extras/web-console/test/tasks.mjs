import assert from 'node:assert/strict';
import { taskStatus, taskLanding, taskPR, taskTicket, agentMismatch, taskRead, taskBlockerItems, idCode, displayCodes, writtenCode, taskOpen } from '../src/app/task-state.ts';

const running = { id: 'T7001', title: 'Fixture', created_at: '2026-10-16T06:00:00Z',
  authority_version: 1, state: 'running', requested_agent: 'codex', resolved_agent: 'codex', actual_agent: 'codex' };
assert.equal(taskStatus(running), 'running'); // lost inventory is not lost authority
for (const state of ['working', 'idle', 'done', 'exited', 'new-state', undefined]) {
  assert.equal(taskStatus({ state: 'open', live: { state } }), 'unknown');
  assert.equal(taskStatus({ ...running, outcome: 'succeeded', live: { state } }), 'succeeded');
}
for (const outcome of ['succeeded', 'failed', 'cancelled', 'refused']) {
  assert.equal(taskStatus({ ...running, outcome, parked: 'old note' }), outcome);
  assert.equal(taskStatus({ ...running, state: outcome }), 'unknown'); // needs committed result
  assert.equal(taskStatus({ state: 'open', outcome }), 'unknown'); // legacy is not adopted
}
assert.equal(taskStatus({ ...running, cancel_request: 'requested' }), 'running');
assert.equal(taskStatus({ ...running, state: 'waiting' }), 'waiting');
assert.equal(taskStatus({ ...running, task_state: 'starting' }), 'starting');
assert.equal(taskStatus({ ...running, authority_version: 99 }), 'unknown');
assert.equal(agentMismatch(running), false);
assert.equal(agentMismatch({ ...running, actual_agent: 'claude' }), true);
assert.equal(agentMismatch({ ...running, resolved_agent: 'claude', actual_agent: undefined }), true);
assert.equal(agentMismatch({ ...running, actual_agent: undefined, agent: 'claude' }), false);
assert.equal(taskLanding({ ...running, outcome: 'succeeded' }), 'unverified');
assert.equal(taskLanding({ ...running, pr_state: 'waiting', pr: 'team/app#51' }), 'waiting');
assert.equal(taskLanding({ ...running, pr_state: 'merged', pr: 'team/app#51', live: { state: 'working' } }), 'merged');
assert.equal(taskLanding({ ...running, pr_state: 'waiting' }), 'unverified');
assert.equal(taskLanding({ ...running, pr_state: 'none' }), 'none');
assert.equal(taskLanding({ state: 'open', pr_state: 'merged' }), 'unverified');
assert.equal(taskPR({ pr: '51', repo: 'team/app' }).url, 'https://github.com/team/app/pull/51');
assert.equal(taskPR({ pr: 'other/repo#51', repo: 'team/app' }).repo, 'other/repo');
assert.equal(taskPR({ pr: 'https://github.com/team/app/pull/51' }).n, '51');
for (const pr of ['51', 'javascript:alert(1)', 'https://other.test/team/app/pull/51', 'hub:team/app#51']) {
  assert.equal(taskPR({ pr }), null);
}
// a task's ticket is a GitHub issue: its ticket_ref first, else the record's issue (T477)
assert.deepEqual(taskTicket({ ticket_ref: 'gh:team/app#42', issue: 'wrong/repo#42' }), { repo: 'team/app', n: 42 });
assert.deepEqual(taskTicket({ issue: 'team/app#42' }), { repo: 'team/app', n: 42 });
assert.equal(taskTicket({ ticket_ref: 'hub:team/app#42', issue: 'wrong/repo#42' }), null);
assert.equal(taskTicket({}), null);

const initial = { data: null, failed: false };
const read = taskRead(initial, { tasks: [running], observed_at: '2026-10-16T06:20:00Z' }, 'later');
const outage = taskRead(read, null, 'later');
assert.equal(outage.failed, true);
assert.equal(outage.data, read.data); // unchanged timestamp and confirmed status
assert.equal(taskRead(read, {}, 'later').data, read.data);
assert.equal(taskRead(read, { tasks: [null] }, 'later').data, read.data);
assert.equal(taskRead(read, { tasks: [], stale: true }, 'later').data.observed_at, read.data.observed_at);
assert.deepEqual(taskRead(read, { tasks: [], stale: true }, 'later').data.tasks, [running]);
assert.deepEqual(taskRead(initial, null, 'later'), { data: null, failed: true });
assert.deepEqual(taskRead(outage, { tasks: [] }, 'reconnected'), { data: { tasks: [], observed_at: 'reconnected' }, failed: false });
assert.equal(taskRead(initial, { tasks: [running], stale: true }, 'cached').data.stale, true);
console.log('PASS task authority, retained native sessions, legacy unknown, agent mismatch, PR landing, qualified refs and outage reads');

const blocked = { ...running, generation: 2, task_blockers: { version: 1, generation: 2, items: [
  { blocker_id: 'one', state: 'resolved' }, { blocker_id: 'two', state: 'active' },
  { blocker_id: 'three', state: 'revoked' },
] }, asked: 'still asking', live: { state: 'needs', needs: 'perm' } };
assert.deepEqual(taskBlockerItems(blocked).map((b) => b.state), ['resolved', 'active', 'revoked']);
assert.equal(taskStatus(blocked), 'running');
assert.equal(blocked.asked, 'still asking');
assert.equal(taskBlockerItems({ ...blocked, generation: 3 }), null);
assert.equal(taskBlockerItems(running), null);
assert.equal(taskBlockerItems({ ...blocked, task_blockers: { version: 1, generation: 2, items: [] } }).length, 0);

// A task goes by its code (EPIC T644 R2): the same encoding as bin/fleet_id.py
// encode (vectors from it), the panel's display rule over the unfinished set.
assert.equal(idCode('00000000-0000-0000-0000-000000000000'), 'A0000000000000000000000000');
assert.equal(idCode('ffffffff-ffff-ffff-ffff-ffffffffffff'), 'ZZZZZZZZZZZZZZZZZZZZZZZZZX');
assert.equal(idCode('3f2504e0-4f89-11d3-9a0c-0305e82c3301'), 'FDMQ6PHPNRY42YF888A0Z7K322');
assert.equal(idCode('e42de263-a50c-47cc-bf28-7d4a8c2ae93d'), 'XKFRQ941F1RNSGVBTRHM0QC0B7');
assert.equal(idCode('T627'), '');
const withFid = (fid, short, extra = {}) => ({ ...running, id: 'T' + short, task: 'T' + short, fid, short, ...extra });
const a = withFid('3f2504e0-4f89-11d3-9a0c-0305e82c3301', 'FDMQ');
const b = withFid('3f2504e0-0000-11d3-9a0c-0305e82c3301', 'FDMP'); // shares FD — and the next place?
const c = withFid('e42de263-a50c-47cc-bf28-7d4a8c2ae93d', 'XKFR');
const done = withFid('e42de263-a50c-0000-bf28-7d4a8c2ae93d', 'XKFP', { outcome: 'succeeded' });
const legacy = { id: 'T12', title: 'old', created_at: '2026-10-01T00:00:00Z', state: 'open' };
assert.equal(idCode(b.fid).slice(0, 2), idCode(a.fid).slice(0, 2));
const codes = displayCodes([a, b, c, done, legacy]);
const n = [...idCode(a.fid)].findIndex((ch, i) => ch !== idCode(b.fid)[i]) + 1;
assert.equal(codes.get(a), 'FDMQ'); // Task written code stays stable
assert.equal(codes.get(b), 'FDMP');
assert.equal(codes.get(c), 'XKFR');
assert.equal(codes.get(done), 'XKFP'); // a finished task shows its written code
assert.equal(codes.get(legacy), 'T12'); // a record with no ID yet keeps its number
assert.equal(displayCodes([a, { ...b, outcome: 'cancelled' }]).get(a), 'FDMQ'); // history cannot rename neighbors
assert.equal(writtenCode(a), 'FDMQ');
assert.equal(taskOpen(done), false);
assert.equal(taskOpen(a), true);
console.log('PASS task codes: encode vectors, stable written codes across current and historical outcomes');
