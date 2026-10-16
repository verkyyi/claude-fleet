import assert from 'node:assert/strict';
import { taskStatus, taskLanding, taskPR, taskTicket, agentMismatch, taskRead } from '../src/app/task-state.ts';

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
assert.deepEqual(taskTicket({ ticket_ref: 'hub:forge/repo#42', issue: 'wrong/repo#42' }), { backend: 'hub', repo: 'forge/repo', n: 42 });
const hub = { backend: 'hub', repo: 'team/app', number: 42 }, gh = { ...hub, backend: 'gh' };
const legacy = { issue: 'team/app#42' };
const unknownRef = { backend: '', repo: 'team/app', n: 42 };
assert.deepEqual(taskTicket(legacy), unknownRef); // failed ticket read
assert.deepEqual(taskTicket(legacy, []), unknownRef); // empty ticket read
assert.deepEqual(taskTicket(legacy, [{ ...hub, repo: 'other/repo' }]), unknownRef); // zero match
assert.deepEqual(taskTicket(legacy, [hub, gh]), unknownRef); // same repo/number, ambiguous home
assert.deepEqual(taskTicket(legacy, [hub]), { backend: 'hub', repo: 'team/app', n: 42 });
assert.deepEqual(taskTicket(legacy, [gh]), { backend: 'gh', repo: 'team/app', n: 42 });
assert.deepEqual(taskTicket({ ...legacy, ticket_ref: 'gh:team/app#42' }, [hub]), { backend: 'gh', repo: 'team/app', n: 42 });
assert.deepEqual(taskTicket({ ...legacy, ticket_ref: 'hub:team/app#42' }, [hub, gh]), { backend: 'hub', repo: 'team/app', n: 42 });
assert.equal(taskTicket({ ticket_ref: 'unknown:team/app#42', issue: 'wrong/repo#42' }), null);

const initial = { data: null, failed: false };
const read = taskRead(initial, { tasks: [running], observed_at: '2026-10-16T06:20:00Z' }, 'later');
const outage = taskRead(read, null, 'later');
assert.equal(outage.failed, true);
assert.equal(outage.data, read.data); // unchanged timestamp and confirmed status
assert.equal(taskRead(read, {}, 'later').data, read.data);
assert.equal(taskRead(read, { tasks: [null] }, 'later').data, read.data);
assert.equal(taskRead(read, { tasks: [], stale: true }, 'later').data.observed_at, undefined);
assert.deepEqual(taskRead(initial, null, 'later'), { data: null, failed: true });
assert.deepEqual(taskRead(outage, { tasks: [] }, 'reconnected'), { data: { tasks: [], observed_at: 'reconnected' }, failed: false });
assert.equal(taskRead(initial, { tasks: [running], stale: true }, 'cached').data.stale, true);
console.log('PASS task authority, retained native sessions, legacy unknown, agent mismatch, PR landing, qualified refs and outage reads');
