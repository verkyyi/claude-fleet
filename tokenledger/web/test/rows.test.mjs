import test from 'node:test';
import assert from 'node:assert/strict';
import { consumptionRows, sortRows } from '../dist/lib/rows.js';

const gw = (n, cost) => ({ source: 'gateway', kind: 'billed', events: n, cost_usd: cost, unpriced_events: 0 });
const cc = (n, cost) => ({ source: 'claude', kind: 'notional', events: n, cost_usd: cost, unpriced_events: 0 });
const vb = (n, cost) => ({ source: 'vendor_bill', kind: 'billed', events: n, cost_usd: cost, unpriced_events: 0 });

test('a blank provider key is "not declared", never a vendor', () => {
  const [r] = consumptionRows([{ key: '', events: 5, tokens: 10, cost: [cc(5, 1)] }]);
  assert.equal(r.provider, '');
  assert.equal(r.providerLabel, 'not declared');
});

test('rows carry their billing kind so the two are never sorted together', () => {
  const rows = consumptionRows([
    { key: 'dashscope.aliyuncs.com', events: 5, tokens: 10, cost: [gw(5, 3)] },
    { key: '', events: 5, tokens: 99, cost: [cc(5, 900)] },
  ]);
  assert.equal(rows.find((r) => r.provider === 'dashscope.aliyuncs.com').kind, 'billed');
  assert.equal(rows.find((r) => r.provider === '').kind, 'notional');
});

// vendor_bill is charged money with no tokens at all. Zero tokens would read
// as "measured, and it was zero"; the truth is that this source counts none.
test('a row with cost and no tokens reports tokens as absent, not zero', () => {
  const [r] = consumptionRows([{ key: 'ark.cn-beijing.volces.com', events: 3, tokens: 0, cost: [vb(3, 42)] }]);
  assert.equal(r.tokens, null);
  assert.equal(r.cost, 42);
});

// Sorting one kind of money against another produces exactly the blended
// reading the per-source split exists to prevent.
test('sorting by cost sorts within a kind and keeps the kinds apart', () => {
  const rows = consumptionRows([
    { key: 'a', events: 1, tokens: 1, cost: [gw(1, 5)] },
    { key: '', events: 1, tokens: 1, cost: [cc(1, 900)] },
    { key: 'b', events: 1, tokens: 1, cost: [gw(1, 50)] },
  ]);
  const sorted = sortRows(rows, 'cost');
  assert.deepEqual(sorted.map((r) => r.kind), ['billed', 'billed', 'notional']);
  assert.deepEqual(sorted.filter((r) => r.kind === 'billed').map((r) => r.provider), ['b', 'a']);
});

test('sorting by tokens puts absent last rather than treating it as zero', () => {
  const rows = consumptionRows([
    { key: 'a', events: 1, tokens: 0, cost: [vb(1, 1)] },
    { key: 'b', events: 1, tokens: 5, cost: [gw(1, 1)] },
  ]);
  assert.deepEqual(sortRows(rows, 'tokens').map((r) => r.provider), ['b', 'a']);
});

// One provider can carry more than one source (a relay fronting both a
// metered vendor and an invoiced one). The row must say so rather than
// silently reporting the first.
test('a provider spanning two sources names both', () => {
  const [r] = consumptionRows([{ key: 'relay', events: 4, tokens: 10, cost: [gw(2, 1), vb(2, 9)] }]);
  assert.deepEqual(r.sources, ['gateway', 'vendor_bill']);
  assert.equal(r.cost, 10);
});

test('sortRows does not mutate its input', () => {
  const rows = consumptionRows([
    { key: 'a', events: 1, tokens: 1, cost: [gw(1, 5)] },
    { key: 'b', events: 1, tokens: 9, cost: [gw(1, 1)] },
  ]);
  const before = rows.map((r) => r.provider);
  sortRows(rows, 'tokens');
  assert.deepEqual(rows.map((r) => r.provider), before);
});

// The page no longer prints an amount for subscription rows, so ordering them by
// that amount would order them on something invisible — which reads as no order
// at all. Inside the notional group, "by cost" falls back to tokens.
test('subscription rows sort by tokens under "by cost", since their amount is not shown', () => {
  const rows = [
    { provider: 'a', kind: 'notional', cost: 99, tokens: 10, events: 1 },
    { provider: 'b', kind: 'notional', cost: 1, tokens: 500, events: 1 },
    { provider: 'c', kind: 'notional', cost: 50, tokens: 100, events: 1 },
  ];
  assert.deepEqual(sortRows(rows, 'cost').map((r) => r.provider), ['b', 'c', 'a']);
});

// Billed rows still sort by the real charge — that figure IS printed.
test('metered rows still sort by cost', () => {
  const rows = [
    { provider: 'a', kind: 'billed', cost: 1, tokens: 999, events: 1 },
    { provider: 'b', kind: 'billed', cost: 50, tokens: 1, events: 1 },
  ];
  assert.deepEqual(sortRows(rows, 'cost').map((r) => r.provider), ['b', 'a']);
});

// Kinds stay grouped whatever the key: billed first, and the fallback above
// must not let a token-heavy subscription row jump above a metered charge.
test('a token-heavy subscription row never outranks a metered one', () => {
  const rows = [
    { provider: 'sub', kind: 'notional', cost: 0, tokens: 1e9, events: 1 },
    { provider: 'gw', kind: 'billed', cost: 0.01, tokens: 5, events: 1 },
  ];
  assert.deepEqual(sortRows(rows, 'cost').map((r) => r.provider), ['gw', 'sub']);
});
