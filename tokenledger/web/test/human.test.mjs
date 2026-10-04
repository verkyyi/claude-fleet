import test from 'node:test';
import assert from 'node:assert/strict';
import { groupByOwner, weeklyHuman, windowRatio, trend, pct, untold } from '../dist/lib/human.js';

const step = (o) => ({
  fragment: 1, ord: 1, owner: '发起人', owner_kind: 'person', owner_id: 'wose1',
  title: 't', waiting_seconds: 3600, todo_at: '2026-09-12T00:00:00Z', ...o,
});

test('one person written two ways is one group', () => {
  // The registry resolves 发起人 and Verky Yi to the same id. Two groups for
  // one human would understate what that human is holding.
  const g = groupByOwner([
    step({ fragment: 1, owner: '发起人', owner_id: 'wose1', waiting_seconds: 100 }),
    step({ fragment: 2, owner: 'Verky Yi', owner_id: 'wose1', waiting_seconds: 900 }),
  ]);
  assert.equal(g.length, 1);
  assert.equal(g[0].steps.length, 2);
  // Labelled with the spelling of the longest-stuck step.
  assert.equal(g[0].owner, 'Verky Yi');
  assert.equal(g[0].steps[0].fragment, 2, 'longest wait first inside the group');
});

test('groups sort by the longest wait, not by name or size', () => {
  const g = groupByOwner([
    step({ owner: 'A', owner_id: 'a', waiting_seconds: 10 }),
    step({ owner: 'A', owner_id: 'a', waiting_seconds: 20 }),
    step({ owner: 'B', owner_id: 'b', waiting_seconds: 900 }),
  ]);
  assert.deepEqual(g.map((x) => x.owner), ['B', 'A']);
});

test('steps nobody can be reminded about are groups, not omissions', () => {
  const g = groupByOwner([
    step({ owner: 'agent', owner_kind: 'not-a-person', owner_id: '', waiting_seconds: 5000 }),
    step({ owner: '某位同事', owner_kind: 'unresolved', owner_id: '', waiting_seconds: 4000 }),
    step({ owner: '发起人', waiting_seconds: 10 }),
  ]);
  assert.equal(g.length, 3);
  assert.deepEqual(g.map((x) => x.kind), ['not-a-person', 'unresolved', 'person']);
});

test('two unresolved names do not merge into one group', () => {
  // They have no id, so the raw string is all that distinguishes them —
  // merging would invent a person who owes both.
  const g = groupByOwner([
    step({ owner: '张三', owner_kind: 'unresolved', owner_id: '' }),
    step({ owner: '李四', owner_kind: 'unresolved', owner_id: '' }),
  ]);
  assert.equal(g.length, 2);
});

test('untold counts what the system, not the person, is holding up', () => {
  const steps = [step({ todo_at: null }), step({ todo_at: null }), step({})];
  assert.equal(untold(steps), 2);
  assert.equal(groupByOwner(steps)[0].untold, 2);
});

test('a week with no fragments has no ratio — not a zero one', () => {
  const w = weeklyHuman([{ day: '2026-09-14', fragments: 0, with_human: 0, steps: 0 }]);
  assert.equal(w.length, 1);
  assert.equal(w[0].ratio, null, 'a quiet week must not render as "nothing needed a human"');
});

test('weekly folding sums both halves of the ratio', () => {
  const w = weeklyHuman([
    { day: '2026-09-14', fragments: 51, with_human: 2, steps: 3, steps_done: 1 }, // Monday
    { day: '2026-09-15', fragments: 49, with_human: 0, steps: 0, steps_done: 0 },
  ]);
  assert.equal(w.length, 1, 'both days are in the same ISO week');
  assert.equal(w[0].fragments, 100);
  assert.equal(w[0].withHuman, 2);
  assert.equal(w[0].ratio, 0.02);
  assert.equal(w[0].stepsDone, 1);
});

test('the window ratio sums the halves rather than averaging the weeks', () => {
  const weeks = [
    { week: 'a', fragments: 400, withHuman: 4 },   // 1%
    { week: 'b', fragments: 4, withHuman: 1 },     // 25%
  ];
  // Averaging the two ratios gives 13%, which would be a sentence about a
  // quiet week rather than about the repository.
  assert.equal(windowRatio(weeks), 5 / 404);
  assert.equal(windowRatio([]), null);
});

test('one week is never a direction', () => {
  const t1 = trend([{ week: 'a', fragments: 10, withHuman: 1, ratio: 0.1 }]);
  assert.equal(t1.direction, 'unknown');
  assert.equal(t1.before, null);
  assert.equal(trend([]).direction, 'unknown');
  // Weeks with no denominator cannot start the comparison either.
  assert.equal(trend([{ week: 'a', fragments: 0, withHuman: 0, ratio: null }]).direction, 'unknown');
});

test('a direction needs to be bigger than the daily wobble', () => {
  const mk = (r, f = 100) => ({ week: 'w', fragments: f, withHuman: r * f, ratio: r });
  assert.equal(trend([mk(0.10), mk(0.02)]).direction, 'down');
  assert.equal(trend([mk(0.02), mk(0.10)]).direction, 'up');
  assert.equal(trend([mk(0.020), mk(0.022)]).direction, 'level');
});

test('the latest week is compared on ratio, never on counts', () => {
  // A partial week always has fewer fragments; comparing counts would print a
  // collapse every Monday morning.
  const t = trend([
    { week: 'a', fragments: 400, withHuman: 8, ratio: 0.02 },
    { week: 'b', fragments: 12, withHuman: 0, ratio: 0 },
  ]);
  assert.equal(t.direction, 'down');
});

test('small shares keep a decimal', () => {
  assert.equal(pct(0.024), '2.4%');
  assert.equal(pct(0.02), '2%');
  assert.equal(pct(0.5), '50%');
  assert.equal(pct(null), null);
});

test('weeks before the repo had any fragments are not a quiet period', async () => {
  const { trimLeadingEmpty } = await import('../dist/lib/human.js');
  const weeks = [
    { week: 'a', fragments: 0, ratio: null },
    { week: 'b', fragments: 0, ratio: null },
    { week: 'c', fragments: 10, withHuman: 1, ratio: 0.1 },
    // An interior gap is a REAL quiet week and must survive: closing it up
    // would slide two weeks a month apart next to each other.
    { week: 'd', fragments: 0, ratio: null },
    { week: 'e', fragments: 4, withHuman: 0, ratio: 0 },
  ];
  assert.deepEqual(trimLeadingEmpty(weeks).map((w) => w.week), ['c', 'd', 'e']);
  assert.deepEqual(trimLeadingEmpty([]).map((w) => w.week), []);
  // Nothing to trim leaves the list untouched (and does not lose week one).
  assert.equal(trimLeadingEmpty(weeks.slice(2)).length, 3);
});
