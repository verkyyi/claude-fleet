import test from 'node:test';
import assert from 'node:assert/strict';
import { policyEntry, policyMode, policyChoices, policyPayload, savePolicy, effectiveHTML, machineTargets, userTargets, newDraft, draftChanged, POLICY_PATH, policyLimitHTML } from '../dist/lib/cred-policy.js';

const A = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const B = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
const C = 'codex:account:' + 'c'.repeat(32);
const creds = [
  { provider: 'claude', principal_id: 'pool', account: '<pool>', account_uuid: A },
  { provider: 'codex', principal_id: 'gh:1', account: 'mine', account_uuid: C },
  { provider: 'claude', principal_id: 'gh:2', account: 'private', account_uuid: B },
  { provider: 'claude', principal_id: 'pool', account: 'legacy' },
  { provider: 'github', principal_id: 'pool', account: 'github', account_uuid: A },
];

test('absent, explicit deny, selected and malformed policies remain distinct', () => {
  const view = { nodes: [{ id: 'mini', allow: [] }], users: [{ id: 'gh:1', allow: [A] }] };
  assert.equal(policyMode(policyEntry(view, 'node', 'other')), 'deny');
  assert.equal(policyMode(policyEntry(view, 'node', 'mini')), 'deny');
  assert.equal(policyMode(policyEntry(view, 'user', 'gh:1')), 'selected');
  assert.equal(policyMode({ allow: [], error: 'bad JSON' }), 'invalid');
  assert.deepEqual(policyPayload('node', 'mini', 'all', [A]), { scope: 'node', id: 'mini', allow: null, all: true });
  assert.deepEqual(policyPayload('user', 'gh:1', 'deny', [A]).allow, []);
  assert.deepEqual(policyPayload('node', 'mini', 'selected', [C, A, A]).allow, [A, C]);
  assert.throws(() => policyPayload('node', 'mini', 'selected', []));
  assert.throws(() => policyPayload('node', 'mini', 'invalid', []));
  assert.throws(() => policyPayload('node', 'mini', 'selected', ['legacy']));
});

test('choices use stable IDs, filter private accounts and preserve unavailable selections', () => {
  const choices = policyChoices(creds, { allow: [B] }, 'user', 'gh:1');
  assert.equal(choices.find((c) => c.id === B).label, 'Previously allowed subscription, currently unavailable');
  assert.ok(choices.some((c) => c.id === A && c.label.includes('<pool>')));
  assert.ok(choices.some((c) => c.id === C));
  assert.ok(choices.some((c) => !c.id && c.label.includes('legacy')));
  assert.ok(!choices.some((c) => c.label.includes('private') || c.label.includes('github')));
  assert.equal(policyChoices(creds, null, 'node', 'mini').filter((c) => c.id).length, 3);
});

test('save writes only the selected scope, after checking its current policy', async () => {
  const calls = [];
  const before = { id: 'mini', allow: [C, A] };
  const api = async (url, opts) => {
    calls.push([url, opts]);
    return opts ? { ok: true } : { nodes: [{ id: 'mini', allow: [A, C] }], users: [] };
  };
  const payload = policyPayload('node', 'mini', 'deny', []);
  await savePolicy(api, before, payload);
  assert.deepEqual(calls, [[POLICY_PATH, undefined], [POLICY_PATH, { method: 'PUT', json: payload }]]);
});

test('changed policy or failed reads refuse to write; write errors remain visible', async () => {
  let writes = 0;
  const payload = policyPayload('node', 'mini', 'all', []);
  await assert.rejects(savePolicy(async (_, opts) => {
    if (opts) writes++;
    return { nodes: [{ id: 'mini', allow: [] }] };
  }, undefined, payload), /changed/);
  assert.equal(writes, 0);
  await assert.rejects(savePolicy(async () => { throw new Error('403'); }, undefined, payload), /403/);
  await assert.rejects(savePolicy(async (_, opts) => {
    if (opts) throw new Error('offline');
    return { nodes: [] };
  }, undefined, payload), /offline/);
});

test('effective view uses the hub verdicts and escapes labels and denial reasons', () => {
  const html = effectiveHTML({ accounts: [
    { provider: 'claude', account: '<script>', account_uuid: A, allowed: false, reason: '<img onerror=x>' },
    { provider: 'codex', account: 'cx', account_uuid: C, allowed: true },
  ] });
  assert.match(html, /Denied by policy/);
  assert.match(html, /Allowed by policy/);
  assert.match(html, /&lt;script&gt;/);
  assert.match(html, /&lt;img onerror=x&gt;/);
  assert.ok(!html.includes('<script>'));
  assert.match(effectiveHTML({ accounts: [] }), /No subscriptions/);
});


test('default denies; all is an explicit grant and revocation never grants by omission', () => {
  const draft = newDraft(undefined);
  assert.equal(draft.mode, 'deny');
  assert.equal(draftChanged(draft), false);
  draft.mode = 'selected'; draft.selected = [A];
  assert.equal(draftChanged(draft), true);
  draft.mode = 'deny';
  assert.equal(draftChanged(draft), false);
  assert.deepEqual(policyPayload('user', 'gh:1', draft.mode, draft.selected).allow, []);
  const restricted = newDraft({ allow: [A] });
  restricted.mode = 'all';
  assert.equal(draftChanged(restricted), true);
  assert.equal(policyPayload('node', 'mini', restricted.mode, [A]).allow, null);
});

test('machine list deduplicates enrolled identities, never display hostnames', async () => {
  const requests = [];
  const rows = await machineTargets({ nodes: [{ id: 'offline', allow: [] }] }, { nodes: [
    { endpoint_id: 'one', hostname: 'spoofed-name' },
    { endpoint_id: 'two', hostname: 'another-display' },
    { endpoint_id: 'bad', hostname: 'cannot-resolve' },
  ] }, async (url) => {
    requests.push(url);
    if (url.endsWith('bad')) throw new Error('403');
    return { effective: { machine: 'enrolled-mini' } };
  });
  assert.deepEqual(rows.filter((r) => !r.error).map((r) => r.id), ['offline', 'enrolled-mini']);
  assert.equal(rows.find((r) => r.error).error, '403');
  assert.equal(requests.length, 3);
  const unknown = await machineTargets({}, { nodes: [{ endpoint_id: 'unknown', hostname: 'untrusted' }] }, async () => ({ effective: { machine: '' } }));
  assert.ok(unknown[0].error);
  assert.notEqual(unknown[0].id, 'untrusted');
});

test('user targets include unconfigured users and administrators without generating rules', () => {
  const view = { users: [{ id: 'gh:1', allow: [A] }] };
  assert.deepEqual(userTargets(view, { users: [{ principal: 'gh:1', login: 'alice' }], admins: [{ github_id: 2, login: 'bob' }] }), [
    { id: 'gh:1', label: 'alice' }, { id: 'gh:2', label: 'bob' },
  ]);
  assert.equal(view.users.length, 1);
});


test('grant editor shows Claude and Codex quota windows using exact identities', () => {
  const now = Date.parse('2026-10-11T00:00:00Z');
  const reset = new Date(now + 3600000).toISOString();
  const limits = { per_account: [
    { account_uuid: A.toUpperCase(), limits: { five_hour: { utilization: 0.32, resets_at: reset }, seven_day: { utilization: 88 }, observed_at: new Date(now).toISOString() } },
    { account_uuid: C, limits: { windows: [{ id: 'primary', minutes: 300, utilization: 0 }, { id: 'secondary', minutes: 10080, utilization: 1 }] } },
  ] };
  const claude = policyLimitHTML(A, limits, now);
  assert.match(claude, /32% used/);
  assert.match(claude, /88% used/);
  assert.match(claude, /width:88%/);
  assert.match(claude, /1h 0m/);
  assert.match(claude, /Last read/);
  const codex = policyLimitHTML(C, limits, now);
  assert.match(codex, /0% used/);
  assert.match(codex, /100% used/);
  assert.doesNotMatch(codex, /32%/);
});

test('missing or unavailable quota readings stay unknown rather than looking unused', () => {
  for (const limits of [null, {}, { per_account: [{ account_uuid: A, limits: { available: false, five_hour: { utilization: 0.4 } } }] }, { per_account: [{ account_uuid: B, label: A, limits: { five_hour: { utilization: 0 } } }] }]) {
    const html = policyLimitHTML(A, limits);
    assert.match(html, /Unknown/);
    assert.doesNotMatch(html, /% used|width:/);
  }
});
