import test from 'node:test';
import assert from 'node:assert/strict';
import { extent, snap, defaultSelection, fit, clamp, resolve, SPANS } from '../dist/lib/brush.js';

const now = Date.UTC(2026, 8, 2, 10, 20); // 2026-09-02T10:20Z

test('extent is bucket-aligned and ends at ceil(now)', () => {
  const e = extent('30d', now);
  assert.equal(e.bucket, 6 * 36e5);
  assert.equal(e.end, Date.UTC(2026, 8, 2, 12));
  assert.equal(e.n, 120);
  assert.equal(e.start, e.end - 120 * e.bucket);
  assert.equal(extent('7d', now).n, 168);
  assert.equal(extent('90d', now).n, 90);
});

test('snap', () => {
  const b = 36e5;
  assert.equal(snap(Date.UTC(2026, 8, 2, 10, 20), b, 'floor'), Date.UTC(2026, 8, 2, 10));
  assert.equal(snap(Date.UTC(2026, 8, 2, 10, 20), b, 'ceil'), Date.UTC(2026, 8, 2, 11));
  assert.equal(snap(Date.UTC(2026, 8, 2, 10, 40), b), Date.UTC(2026, 8, 2, 11));
});

test('default selection is the last 7 days, or the whole span', () => {
  const e = extent('30d', now);
  assert.deepEqual(defaultSelection('30d', now), { from: e.end - 7 * 864e5, to: null });
  assert.deepEqual(defaultSelection('7d', now), { from: extent('7d', now).start, to: null });
});

test('fit keeps a selection inside the extent and resets one outside', () => {
  const e = extent('7d', now);
  const inside = { from: e.start + 36e5, to: e.start + 5 * 36e5 };
  assert.deepEqual(fit(inside, '7d', now), inside);
  const outside = { from: e.start - 864e5, to: e.start + 36e5 };
  assert.deepEqual(fit(outside, '7d', now), defaultSelection('7d', now));
});

test('clamp keeps at least one bucket and stays in range', () => {
  const e = extent('7d', now);
  assert.deepEqual(clamp({ from: e.start - 1, to: e.start }, e), { from: e.start, to: e.start + e.bucket });
  assert.deepEqual(clamp({ from: e.end - 1, to: e.end + 5 }, e), { from: e.end - e.bucket, to: e.end });
});

test('resolve: to=null is live and means the extent end', () => {
  const e = extent('30d', now);
  assert.deepEqual(resolve({ from: e.start, to: null }, '30d', now), { from: e.start, to: e.end, live: true });
  assert.deepEqual(resolve({ from: e.start, to: e.start + e.bucket }, '30d', now), { from: e.start, to: e.start + e.bucket, live: false });
});
