import test from 'node:test';
import assert from 'node:assert/strict';
import { foldHourly, busiest, quietest, sentence } from '../dist/lib/fold.js';

const series = [
  { key: '2026-08-31T23:00', tokens: 100, events: 1 }, // Monday 23:00 UTC
  { key: '2026-09-01T00:00', tokens: 5, events: 1 },   // Tuesday 00:00 UTC
  { key: '2026-09-01T09:00', tokens: 900, events: 3 },
];

test('folds into local dow×hour with a fixed offset', () => {
  // +480 = UTC+8: Monday 23:00Z is Tuesday 07:00 local
  const { grid, total } = foldHourly(series, () => 480);
  assert.equal(total, 1005);
  assert.equal(grid[2][7], 100);   // Tue 07
  assert.equal(grid[2][8], 5);     // Tue 08
  assert.equal(grid[2][17], 900);  // Tue 17
  assert.equal(grid[1][23], 0);
});

test('busiest and quietest windows', () => {
  const { grid } = foldHourly(series, () => 0);
  assert.deepEqual(busiest(grid), { dow: 2, hour: 9, tokens: 900 });
  const q = quietest(grid, 4);
  assert.equal(q.tokens, 0);
  assert.ok(q.startHour >= 0 && q.startHour < 24);
  assert.match(sentence(grid), /busiest .*Tue 09:00/);
});
