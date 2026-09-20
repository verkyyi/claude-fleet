import test from 'node:test';
import assert from 'node:assert/strict';
import { consumptionRows, foldTail, sortRows } from '../dist/lib/rows.js';

const gw = (n, cost) => ({ source: 'gateway', kind: 'billed', events: n, cost_usd: cost, unpriced_events: 0 });
const cc = (n, cost) => ({ source: 'claude', kind: 'notional', events: n, cost_usd: cost, unpriced_events: 0 });
const vb = (n, cost) => ({ source: 'vendor_bill', kind: 'billed', events: n, cost_usd: cost, unpriced_events: 0 });

// The wording of a blank row now depends on which sources are in it (see the
// "not declared" tests at the bottom). What never depends on anything: the row
// keeps the empty key as its identity, and never renders as a blank cell or as
// something a reader could mistake for a vendor's name.
test('a blank provider key is always said in words, never left blank', () => {
  for (const cost of [[cc(5, 1)], [cc(5, 1), gw(1, 2)], []]) {
    const [r] = consumptionRows([{ key: '', events: 5, tokens: 10, cost }]);
    assert.equal(r.provider, '');
    assert.ok(r.providerLabel && r.providerLabel !== r.provider,
      `blank bucket rendered as ${JSON.stringify(r.providerLabel)}`);
  }
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

// ── the tail fold ────────────────────────────────────────────────────────
// Modelled on the real 30-day table: four bare-IP gateway "providers" with one
// or two requests and no charge, beside a vendor bill of $38.37 that has only
// SEVEN requests. Folding by request count alone would hide the largest amount
// in the table.
const realShape = () => [
  { provider: 'dashscope.aliyuncs.com', kind: 'billed', events: 1555, tokens: 2326517, cost: 0.2678, unpriced: 35 },
  { provider: 'api.deepseek.com', kind: 'billed', events: 107, tokens: 102122, cost: 0, unpriced: 107 },
  { provider: 'volc', kind: 'billed', events: 7, tokens: null, cost: 38.3681, unpriced: 0 },
  { provider: 'aliyun', kind: 'billed', events: 2, tokens: null, cost: 0.9241, unpriced: 0 },
  { provider: '180.184.47.154', kind: 'billed', events: 1, tokens: null, cost: 0, unpriced: 1 },
  { provider: '39.96.198.249', kind: 'billed', events: 2, tokens: null, cost: 0, unpriced: 2 },
  { provider: '39.96.213.166', kind: 'billed', events: 2, tokens: null, cost: 0, unpriced: 2 },
  { provider: '8.140.217.18', kind: 'billed', events: 1, tokens: null, cost: 0, unpriced: 1 },
];

test('the tail folds, and the money never does', () => {
  const out = foldTail(realShape());
  const names = out.map((r) => r.providerLabel || r.provider);
  // The four bare IPs are gone as individual rows...
  for (const ip of ['180.184.47.154', '39.96.198.249', '39.96.213.166', '8.140.217.18']) {
    assert.ok(!names.includes(ip), `${ip} survived the fold`);
  }
  // ...and the quiet-but-expensive rows did not move.
  assert.ok(names.includes('volc'), 'folded a row holding $38.37');
  assert.ok(names.includes('aliyun'), 'folded a row holding $0.92');
  const folded = out.find((r) => r.provider === null);
  assert.equal(folded.foldedCount, 4);
  assert.equal(folded.events, 6);
  assert.match(folded.providerLabel, /other 4 providers/);
});

// The table must still add up to what it added up to. A fold that loses a
// request is worse than a long table.
test('folding conserves every total', () => {
  const before = realShape();
  const after = foldTail(before);
  const sum = (rows, k) => rows.reduce((n, r) => n + (r[k] || 0), 0);
  for (const k of ['events', 'cost', 'unpriced']) {
    assert.equal(sum(after, k), sum(before, k), `${k} changed across the fold`);
  }
});

// A row that cost money is never tail, however few requests it made.
test('a priced row is never folded', () => {
  const rows = [
    { provider: 'a', kind: 'billed', events: 1, tokens: null, cost: 99, unpriced: 0 },
    { provider: 'b', kind: 'billed', events: 1, tokens: null, cost: 0, unpriced: 0 },
    { provider: 'c', kind: 'billed', events: 1, tokens: null, cost: 0, unpriced: 0 },
    { provider: 'd', kind: 'billed', events: 1, tokens: null, cost: 0, unpriced: 0 },
  ];
  const out = foldTail(rows);
  assert.ok(out.some((r) => r.provider === 'a'), 'folded a row that cost $99');
  assert.equal(out.find((r) => r.provider === null).foldedCount, 3);
});

test('too small a tail is left alone', () => {
  const rows = [
    { provider: 'a', kind: 'billed', events: 500, tokens: 1, cost: 5, unpriced: 0 },
    { provider: 'b', kind: 'billed', events: 1, tokens: null, cost: 0, unpriced: 0 },
    { provider: 'c', kind: 'billed', events: 2, tokens: null, cost: 0, unpriced: 0 },
  ];
  assert.deepEqual(foldTail(rows).map((r) => r.provider), ['a', 'b', 'c']);
});

// Kinds are never summed together — the one arithmetic this hub does not do.
test('the fold is per kind, never across', () => {
  const rows = [
    { provider: 'g1', kind: 'billed', events: 1, tokens: null, cost: 0, unpriced: 0 },
    { provider: 'g2', kind: 'billed', events: 1, tokens: null, cost: 0, unpriced: 0 },
    { provider: 'n1', kind: 'notional', events: 1, tokens: null, cost: 0, unpriced: 0 },
    { provider: 'n2', kind: 'notional', events: 1, tokens: null, cost: 0, unpriced: 0 },
  ];
  const folded = foldTail(rows).filter((r) => r.provider === null);
  assert.equal(folded.length, 2, 'kinds were folded into one row');
  assert.deepEqual(folded.map((r) => r.kind).sort(), ['billed', 'notional']);
});

// Absent tokens stay absent: these rows count no tokens at all, and 0 would
// claim they were measured.
test('a folded row of token-less rows reports no tokens', () => {
  const rows = [
    { provider: 'a', kind: 'billed', events: 1, tokens: null, cost: 0, unpriced: 0 },
    { provider: 'b', kind: 'billed', events: 1, tokens: null, cost: 0, unpriced: 0 },
    { provider: 'c', kind: 'billed', events: 1, tokens: null, cost: 0, unpriced: 0 },
  ];
  assert.equal(foldTail(rows).find((r) => r.provider === null).tokens, null);
});

// Kinds stay grouped, always — including the rows the fold creates. Appending
// every fold row at the end of the list put a BILLED "other" row below the
// notional rows, which is the one ordering rule this table has.
test('a fold row sits at the end of its own kind, not after every kind', () => {
  const rows = sortRows([
    { provider: 'gw', kind: 'billed', events: 900, tokens: 9, cost: 5, unpriced: 0 },
    { provider: 'i1', kind: 'billed', events: 1, tokens: null, cost: 0, unpriced: 1 },
    { provider: 'i2', kind: 'billed', events: 1, tokens: null, cost: 0, unpriced: 1 },
    { provider: 'i3', kind: 'billed', events: 1, tokens: null, cost: 0, unpriced: 1 },
    { provider: 'sub', kind: 'notional', events: 400, tokens: 99, cost: 70, unpriced: 0 },
  ], 'cost');
  const kinds = foldTail(rows).map((r) => r.kind);
  assert.deepEqual(kinds, ['billed', 'billed', 'notional'],
    'the folded billed row escaped its kind group');
});

// --- the operator's name for an upstream --------------------------------

// Bucket.label arrives from --pricing by way of the api layer. Before it had a
// caller, every provider row printed the raw key.
test('a labelled upstream shows the operator name, not the hostname', () => {
  const [r] = consumptionRows([
    { key: 'ark.cn-beijing.volces.com', label: '火山方舟', events: 3, tokens: 9, cost: [gw(3, 2)] },
  ]);
  assert.equal(r.provider, 'ark.cn-beijing.volces.com');
  assert.equal(r.providerLabel, '火山方舟');
});

// The hub never invents a name. An upstream nobody configured keeps the string
// the data actually carries, however unfriendly it is.
test('an unlabelled upstream keeps its raw key', () => {
  const [r] = consumptionRows([
    { key: '180.184.47.154', label: '', events: 2, tokens: 0, cost: [gw(2, 0.08)] },
  ]);
  assert.equal(r.providerLabel, '180.184.47.154');
});

// --- what "not declared" is allowed to claim -----------------------------

// One source, and it is claude: a Claude transcript has nowhere to record an
// upstream, so the blank has exactly one possible cause and the row may name
// it. This is derived from the bucket, never configured.
test('a blank bucket that is all claude says which source declares nothing', () => {
  const [r] = consumptionRows([{ key: '', events: 5, tokens: 10, cost: [cc(5, 1)] }]);
  assert.equal(r.provider, '');
  assert.equal(r.providerLabel, 'Claude (declares no upstream)');
});

// Two sources in one blank bucket means the blank has more than one origin --
// the pre-dimension rollup rows are the other. Attributing all of it to claude
// would be the invention this table exists to avoid.
test('a blank bucket spanning two sources falls back to the plain wording', () => {
  const [r] = consumptionRows([{ key: '', events: 6, tokens: 10, cost: [cc(5, 1), gw(1, 2)] }]);
  assert.equal(r.providerLabel, 'not declared');
});

// A codex-only blank row is a different absence again, and gets no claim made
// about it either.
test('a blank bucket from another single source is not called Claude', () => {
  const cx = (n, cost) => ({ source: 'codex', kind: 'notional', events: n, cost_usd: cost, unpriced_events: 0 });
  const [r] = consumptionRows([{ key: '', events: 4, tokens: 10, cost: [cx(4, 1)] }]);
  assert.equal(r.providerLabel, 'not declared');
});

// A bucket with no active source at all has no evidence to derive from.
test('a blank bucket with no active source stays unqualified', () => {
  const [r] = consumptionRows([{ key: '', events: 0, tokens: 0, cost: [] }]);
  assert.equal(r.providerLabel, 'not declared');
});
