import { test } from 'node:test';
import assert from 'node:assert/strict';
import { shortLabel, quotaWindows, blockedBy, isMoot, blockedLast } from '../dist/lib/quota-rows.js';
import { resetIn } from '../dist/lib/format.js';

const at = (h) => new Date(Date.now() + h * 3600e3).toISOString();
const claude = (u5, u7, r5 = at(2), r7 = at(59)) => ({
  available: true,
  five_hour: { utilization: u5, resets_at: r5 },
  seven_day: { utilization: u7, resets_at: r7 },
});

test('window labels are the short form: 5H, 7D', () => {
  assert.equal(shortLabel(300), '5H');
  assert.equal(shortLabel(10080), '7D');
  assert.equal(shortLabel(90), '90M');
  assert.equal(shortLabel(0), '');
});

test("Claude's fixed pair and Codex's list come out in one shape, shortest first", () => {
  assert.deepEqual(quotaWindows(claude(1, 2)).map((x) => x.minutes), [300, 10080]);
  const codex = { windows: [{ minutes: 10080, utilization: 1 }, { minutes: 300, utilization: 2 }] };
  assert.deepEqual(quotaWindows(codex).map((x) => x.minutes), [300, 10080]);
});

// The live case #153 was filed for: a full week, and a five-hour window that
// reads 0% "healthy". Claude sends no `blocked` flag, so the flag alone misses it.
test('★ a Claude account with a full 7D is blocked by 7D, though it sends no blocked flag', () => {
  const v = claude(0, 100);
  assert.equal(v.blocked, undefined);
  const b = blockedBy(v);
  assert.ok(b, 'must be blocked');
  assert.equal(b.minutes, 10080);
  const five = quotaWindows(v)[0];
  assert.equal(isMoot(five, b), true, '5H behind a blocked 7D is moot: none of it can be spent');
});

test('the provider saying blocked is enough, and picks the fullest window', () => {
  const v = { blocked: true, windows: [{ minutes: 10080, utilization: 97, resets_at: at(41) }] };
  assert.equal(blockedBy(v).minutes, 10080);
});

test('only 5H full: blocked by 5H, and the week is NOT moot — it still decides what is left', () => {
  const v = claude(100, 66);
  const b = blockedBy(v);
  assert.equal(b.minutes, 300);
  assert.equal(isMoot(quotaWindows(v)[1], b), false);
});

test('both full: the window that resets last is the answer', () => {
  const b = blockedBy(claude(100, 100, at(2), at(70)));
  assert.equal(b.minutes, 10080);
});

test('nothing full and no flag: not blocked', () => {
  assert.equal(blockedBy(claude(99, 99)), null);
  assert.equal(blockedBy({ available: false }), null);
});

test('blocked subscriptions go last, soonest back first; the rest keep their order', () => {
  const e = (id, v) => ({ account_uuid: id, limits: v });
  const out = blockedLast([
    e('a', claude(11, 66)),
    e('late', claude(0, 100, at(1), at(59))),
    e('b', claude(8, 42)),
    e('soon', claude(0, 100, at(1), at(41))),
    e('c', claude(14, 63)),
  ]).map((x) => x.account_uuid);
  assert.deepEqual(out, ['a', 'b', 'c', 'soon', 'late']);
});

test('time to reset is ONE unit, the largest, rounded down', () => {
  assert.equal(resetIn(at(4 * 24 + 3)), '4d');
  assert.equal(resetIn(at(23.9)), '23h', 'rounded down: never promises a day that is 23 hours away');
  assert.equal(resetIn(new Date(Date.now() + 61 * 60e3 + 5e3).toISOString()), '1h');
  assert.equal(resetIn(new Date(Date.now() + 21 * 60e3 + 5e3).toISOString()), '21m');
  assert.equal(resetIn(new Date(Date.now() + 5e3).toISOString()), 'now');
  assert.equal(resetIn(null), '—');
});
