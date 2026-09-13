import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  SOURCES, kindOf, costOf, notionalCost, billedCost, unpricedEvents,
  activeSources, activeSourcesAcross, fmtSourceCost, costLine, addCost, fmtRealSpend,
} from '../dist/lib/cost.js';

// The dashboard half of the guard in internal/store/cost_guard_test.go. The
// hub keeps three kinds of money apart all the way to the wire; nothing here
// may put two of them back together.
//
// The figures are an order of magnitude apart so that a blend (123) cannot be
// produced any other way.
const bucket = {
  key: '/p/alpha',
  events: 6,
  cost: [
    { source: 'claude', kind: 'notional', events: 3, cost_usd: 3, unpriced_events: 0 },
    { source: 'codex', kind: 'notional', events: 2, cost_usd: 20, unpriced_events: 1 },
    { source: 'gateway', kind: 'billed', events: 1, cost_usd: 100, unpriced_events: 0 },
  ],
};

test('folds are per kind, and the blend is unreachable', () => {
  assert.equal(notionalCost(bucket), 23);
  assert.equal(billedCost(bucket), 100);
  assert.notEqual(notionalCost(bucket), 123);
  assert.notEqual(billedCost(bucket), 123);
  // Counts DO add across sources — they are the same kind of thing.
  assert.equal(unpricedEvents(bucket), 1);
});

test('no export produces a blended total', () => {
  const mod = readFileSync(new URL('../dist/lib/cost.js', import.meta.url), 'utf8');
  for (const banned of ['export const total', 'export function total', 'totalCost']) {
    assert.ok(!mod.includes(banned),
      `lib/cost.js exports ${banned} — a blended cost figure is exactly what this module exists to prevent`);
  }
});

// Read the source list out of the Go file instead of keeping a second copy of
// it here. The old version of this test asserted a hand-written array while
// calling itself "matches Go" — so the day Go grew a fourth source, the mirror
// was wrong and the test still passed for every other reason. Now adding a
// source in Go fails here until lib/cost.js is taught about it.
function goSources() {
  const modelDir = new URL('../../internal/model/', import.meta.url);
  const consts = readFileSync(new URL('model.go', modelDir), 'utf8');
  const list = readFileSync(new URL('cost.go', modelDir), 'utf8')
    .match(/var Sources = \[\]string\{([^}]*)\}/);
  assert.ok(list, 'cannot find model.Sources in internal/model/cost.go');
  return list[1].split(',').map((s) => s.trim()).filter(Boolean).map((ident) => {
    const m = consts.match(new RegExp(`${ident}\\s*=\\s*"([^"]+)"`));
    assert.ok(m, `cannot resolve ${ident} to a string literal in internal/model/model.go`);
    return m[1];
  });
}

test('kinds match model.CostKind in Go', () => {
  assert.deepEqual(SOURCES, goSources(),
    'lib/cost.js SOURCES has drifted from model.Sources in Go');
  assert.equal(kindOf('claude'), 'notional');
  assert.equal(kindOf('codex'), 'notional');
  assert.equal(kindOf('gateway'), 'billed');
  // Read off a vendor invoice — different measurement, same kind of money.
  assert.equal(kindOf('vendor_bill'), 'billed');
  // An unrecognised source is classified as neither, so it lands in no fold.
  assert.equal(kindOf('some-future-thing'), 'unknown');
  const future = { cost: [{ source: 'some-future-thing', kind: 'unknown', events: 1, cost_usd: 7, unpriced_events: 0 }] };
  assert.equal(notionalCost(future), 0);
  assert.equal(billedCost(future), 0);
});

test('a source with no usage renders as an absence, not as $0.00', () => {
  const claudeOnly = { cost: [{ source: 'claude', kind: 'notional', events: 3, cost_usd: 3, unpriced_events: 0 }] };
  assert.equal(fmtSourceCost(claudeOnly, 'claude'), '$3.00');
  assert.equal(fmtSourceCost(claudeOnly, 'gateway'), '—');
  assert.deepEqual(activeSources(claudeOnly), ['claude']);
  // …and a table over such buckets grows only the columns it needs.
  assert.deepEqual(activeSourcesAcross([claudeOnly, claudeOnly]), ['claude']);
  assert.deepEqual(activeSourcesAcross([claudeOnly, bucket]), ['claude', 'codex', 'gateway']);
  assert.deepEqual(activeSourcesAcross([]), []);
});

test('a partially unpriced source reads as a lower bound', () => {
  assert.equal(fmtSourceCost(bucket, 'codex'), '≥ $20.00');
  assert.equal(fmtSourceCost(bucket, 'claude'), '$3.00');
});

test('costLine names every source and never sums them', () => {
  const line = costLine(bucket);
  assert.match(line, /claude \$3\.00 notional/);
  assert.match(line, /gateway \$100\.00 billed/);
  assert.ok(!line.includes('123'), `costLine produced a blend: ${line}`);
  assert.equal(costLine({ cost: [] }), 'no cost');
});

test('addCost folds per source, never into one accumulator', () => {
  const into = [];
  addCost(into, bucket);
  addCost(into, bucket);
  assert.equal(notionalCost({ cost: into }), 46);
  assert.equal(billedCost({ cost: into }), 200);
  assert.equal(costOf({ cost: into }, 'gateway').events, 2);
  assert.equal(into.length, 3, 'sources were merged into one entry');
});

test('real spend is subscription + billed, and says when it is short', () => {
  assert.equal(fmtRealSpend({ total: 300, complete: true }), '$300.00');
  assert.equal(fmtRealSpend({ total: 300, complete: false }), '$300.00 ≥');
  assert.equal(fmtRealSpend(null), '—');
});
