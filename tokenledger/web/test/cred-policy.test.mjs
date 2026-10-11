import test from 'node:test';
import assert from 'node:assert/strict';
import { policyEntry, policyMode, policyChoices, policyPayload, savePolicy, effectiveHTML, POLICY_PATH } from '../dist/lib/cred-policy.js';

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
  assert.equal(policyMode(policyEntry(view, 'node', 'other')), 'inherit');
  assert.equal(policyMode(policyEntry(view, 'node', 'mini')), 'deny');
  assert.equal(policyMode(policyEntry(view, 'user', 'gh:1')), 'selected');
  assert.equal(policyMode({ allow: [], error: 'bad JSON' }), 'invalid');
  assert.deepEqual(policyPayload('node', 'mini', 'inherit', [A]), { scope: 'node', id: 'mini', allow: null });
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
  const payload = policyPayload('node', 'mini', 'inherit', []);
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
