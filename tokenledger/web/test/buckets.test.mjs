import test from 'node:test';
import assert from 'node:assert/strict';
import { bucketMs, inferBucket, densify } from '../dist/lib/buckets.js';

const HOUR = 36e5, DAY = 864e5;
const at = (iso, extra = {}) => ({ ms: Date.parse(iso), key: iso, ...extra });

test('every raw bucket-key shape the rollup emits reads as the same instant', () => {
  // internal/api/history.go's bucketKey: 10 chars for day, 13 for 6h, 16 for
  // hour. The 13-char one is the whole reason this is length-based and not
  // Date.parse alone — Date.parse('2026-09-19T06') is NaN in Node and in
  // every browser engine.
  assert.equal(bucketMs('2026-09-19'), Date.parse('2026-09-19T00:00:00Z'));
  assert.equal(bucketMs('2026-09-19T06'), Date.parse('2026-09-19T06:00:00Z'));
  assert.equal(bucketMs('2026-09-19T06:00'), Date.parse('2026-09-19T06:00:00Z'));
  // ...and the already-normalized form review.js hands the charts.
  assert.equal(bucketMs('2026-09-19T06:00:00Z'), Date.parse('2026-09-19T06:00:00Z'));
  // A key with no zone marker is still UTC, not the viewer's timezone: a
  // dashboard read from Shanghai and from London must draw the same bar.
  assert.equal(bucketMs('2026-09-19'), bucketMs('2026-09-19T00:00:00Z'));
  assert.equal(bucketMs(1758240000000), 1758240000000);
});

test('inferBucket takes the smallest gap, which is the only one that can be one bucket', () => {
  const ms = ['2026-09-01', '2026-09-02', '2026-09-05', '2026-09-06'].map(bucketMs);
  assert.equal(inferBucket(ms), DAY);          // not the 3-day hole, not the mean
  assert.equal(inferBucket([1000]), 0);
  assert.equal(inferBucket([]), 0);
  assert.equal(inferBucket([5, 5, 5]), 0);     // nothing to infer from
});

test('densify puts back the buckets the API never sent', () => {
  // /v1/history emits a bucket only when it had rows, so this is what a
  // weekend of silence actually looks like on the wire.
  const out = densify([at('2026-09-01T00:00:00Z'), at('2026-09-04T00:00:00Z')], DAY);
  assert.equal(out.length, 4);
  assert.deepEqual(out.map((p) => new Date(p.ms).toISOString().slice(0, 10)),
    ['2026-09-01', '2026-09-02', '2026-09-03', '2026-09-04']);
  // The filled ones are marked and carry no payload — every caller reads a
  // missing stack as zero, and a fake zero must not be mistaken for a
  // measured one by anything downstream.
  assert.deepEqual(out.map((p) => !!p.empty), [false, true, true, false]);
  assert.equal(out[1].stack, undefined);
  // Real points pass through by reference, payload intact.
  assert.equal(out[3].key, '2026-09-04T00:00:00Z');
});

test('densify sorts first, so an out-of-order response still fills correctly', () => {
  const out = densify([at('2026-09-03T00:00:00Z'), at('2026-09-01T00:00:00Z')], DAY);
  assert.deepEqual(out.map((p) => !!p.empty), [false, true, false]);
  assert.ok(out.every((p, i) => i === 0 || p.ms > out[i - 1].ms));
});

test('a series with no holes comes back untouched', () => {
  const src = [at('2026-09-19T00:00:00Z'), at('2026-09-19T01:00:00Z'), at('2026-09-19T02:00:00Z')];
  const out = densify(src, HOUR);
  assert.equal(out.length, 3);
  assert.ok(out.every((p) => !p.empty));
});

test('densify infers the bucket when the caller does not know it', () => {
  const out = densify([at('2026-09-19T00:00:00Z'), at('2026-09-19T01:00:00Z'),
                       at('2026-09-19T04:00:00Z')]);
  assert.deepEqual(out.map((p) => !!p.empty), [false, false, true, true, false]);
});

test('degenerate input never loops and never throws', () => {
  assert.deepEqual(densify([], DAY), []);
  assert.equal(densify([at('2026-09-19T00:00:00Z')], DAY).length, 1);
  // Nothing to infer and no bucket given: returned as-is rather than guessed.
  assert.equal(densify([at('2026-09-19T00:00:00Z'), at('2026-09-19T00:00:00Z')]).length, 2);
  // A nonsense bucket (seconds where ms were meant) would ask for ~2.6M
  // points; the cap hands back the input instead of hanging the tab.
  const wide = densify([at('2026-01-01T00:00:00Z'), at('2026-04-01T00:00:00Z')], 1);
  assert.equal(wide.length, 2);
});

test('the real worst case the dashboard can ask for still fills', () => {
  // lib/brush.js's SPANS: 90d snaps to a 1d bucket → 90 points, well inside
  // the cap. The cap must not be tight enough to silently disable the fill
  // on a span a user can actually select.
  const out = densify([at('2026-01-01T00:00:00Z'), at('2026-04-01T00:00:00Z')], DAY);
  assert.equal(out.length, 91);
});
