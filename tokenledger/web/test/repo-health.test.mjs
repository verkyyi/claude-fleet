import test from 'node:test';
import assert from 'node:assert/strict';
import { healthRows, healthAge } from '../dist/lib/repo.js';

const at = '2026-09-15T00:00:00Z';
const NOW = Date.parse('2026-09-16T00:00:00Z'); // one day later
const DAY = 86400;

const block = (readings, extra = {}) => ({ observed_at: at, readings, ...extra });

test('readings come through verbatim and in order', () => {
  const rows = healthRows(block([
    { key: 'touch', label: 'x', value: 'p50 1.7 天 · p90 ≥ 8.8 天', note: '30 天窗口', ok: true },
    { key: 'inflow', value: '0%（0 / 252）', ok: true },
  ]));
  assert.deepEqual(rows.map((r) => r.key), ['touch', 'inflow']);
  // The bound marker survives. Stripping it turns "at least 8.8 days" into
  // "8.8 days", which reports the response time as faster than it was
  // measured to be.
  assert.equal(rows[0].value, 'p50 1.7 天 · p90 ≥ 8.8 天');
  assert.equal(rows[0].note, '30 天窗口');
});

// Fail-closed, and strictly. An older shipper that never sets `ok`, or one
// that sends the string "true", must land on "not measured" -- the row still
// renders, but it never renders as a clean reading.
test('anything but ok === true is not a measured reading', () => {
  const rows = healthRows(block([
    { key: 'a', value: 'v' },
    { key: 'b', value: 'v', ok: 'true' },
    { key: 'c', value: 'v', ok: 1 },
    { key: 'd', value: 'v', ok: true },
  ]));
  assert.deepEqual(rows.map((r) => r.ok), [false, false, false, true]);
});

// A blank figure is the failure this whole card is about: an empty cell reads
// as "nothing wrong", which is the one thing a missing measurement cannot say.
test('a blank value is never an ok reading', () => {
  const [row] = healthRows(block([{ key: 'rot', value: '   ', ok: true }]));
  assert.equal(row.ok, false);
  assert.equal(row.value, '');
});

test('a block with nothing in it yields no rows rather than throwing', () => {
  assert.deepEqual(healthRows(null), []);
  assert.deepEqual(healthRows({}), []);
  assert.deepEqual(healthRows(block([{ value: 'no key' }])), []);
});

test('age is measured against the observation, not the arrival', () => {
  const age = healthAge(block([], { stale_after_seconds: 2 * DAY }), NOW);
  assert.equal(age.seconds, DAY);
  assert.equal(age.stale, false);
  assert.equal(healthAge(block([], { stale_after_seconds: DAY / 2 }), NOW).stale, true);
});

// The page must not invent a freshness threshold. A daily shipper and a weekly
// one disagree about what stale means, and a number picked here would describe
// whoever picked it -- the same rule every age band on this page already obeys.
test('with no shipped cadence, staleness is unknown rather than assumed', () => {
  assert.equal(healthAge(block([]), NOW).stale, null);
  assert.equal(healthAge(block([], { stale_after_seconds: 0 }), NOW).stale, null);
  assert.equal(healthAge(block([], { stale_after_seconds: 'soon' }), NOW).stale, null);
});

test('nothing to age is null, not zero', () => {
  assert.equal(healthAge(null, NOW), null);
  assert.equal(healthAge({ readings: [] }, NOW), null);
  assert.equal(healthAge({ observed_at: 'never', readings: [] }, NOW), null);
});
