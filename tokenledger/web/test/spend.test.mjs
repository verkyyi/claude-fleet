import test from 'node:test';
import assert from 'node:assert/strict';
import { spendTerms } from '../dist/lib/spend.js';

test('names only the terms that are non-zero', () => {
  const t = spendTerms({ currency: 'USD', subscription: 200, gateway: 12.8, vendor_bill: 0, total: 212.8, complete: true });
  assert.deepEqual(t.map((x) => x.key), ['subscription', 'gateway']);
});

// vendor_bill exists precisely because some spend never touches the gateway.
// Folding it into the gateway term would put a claim about provenance on a
// number that does not support it.
test('vendor_bill is its own term, never folded into gateway', () => {
  const t = spendTerms({ subscription: 0, gateway: 1, vendor_bill: 9, total: 10, complete: true });
  assert.deepEqual(t.map((x) => x.key), ['gateway', 'vendor_bill']);
  assert.equal(t.find((x) => x.key === 'vendor_bill').amount, 9);
});

test('all-zero spend yields no terms rather than three zeroes', () => {
  assert.deepEqual(spendTerms({ subscription: 0, gateway: 0, vendor_bill: 0, total: 0, complete: true }), []);
});

test('missing real_spend is an absence, not zero', () => {
  assert.deepEqual(spendTerms(null), []);
});

// The terms must add up to the total the API computed. If they ever do not,
// the page is either dropping a term or inventing one.
test('the named terms sum to the API total', () => {
  const rs = { subscription: 200, gateway: 12.8, vendor_bill: 38.5, total: 251.3, complete: true };
  const sum = spendTerms(rs).reduce((n, t) => n + t.amount, 0);
  assert.ok(Math.abs(sum - rs.total) < 1e-9, `${sum} != ${rs.total}`);
});

// voice is the mirror of vendor_bill: it normally carries usage without money,
// so the term is usually absent. When a collector DOES price those calls the
// money is real and must be named — a term the page drops is money missing
// from the total printed right above it.
test('voice is its own term when a collector prices it', () => {
  const rs = { subscription: 0, gateway: 1, vendor_bill: 0, voice: 4, total: 5, complete: true };
  const t = spendTerms(rs);
  assert.deepEqual(t.map((x) => x.key), ['gateway', 'voice']);
  assert.equal(t.find((x) => x.key === 'voice').amount, 4);
  const sum = t.reduce((n, x) => n + x.amount, 0);
  assert.ok(Math.abs(sum - rs.total) < 1e-9, `${sum} != ${rs.total}`);
});

// The usual shape: voice reported usage, the invoice reported the money.
test('an unpriced voice source contributes no term', () => {
  const t = spendTerms({ subscription: 200, gateway: 0, vendor_bill: 38.5, voice: 0, total: 238.5, complete: true });
  assert.deepEqual(t.map((x) => x.key), ['subscription', 'vendor_bill']);
});
