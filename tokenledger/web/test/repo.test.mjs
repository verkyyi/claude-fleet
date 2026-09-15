import test from 'node:test';
import assert from 'node:assert/strict';
import { isoWeekStart, weeklyFlow, net, scaleBands, ageHistogram, stalled,
         shippedButOpen, fmtAge, pickRepo, STALLED_SORTS, labelFacets,
         filterStalled, sortStalled } from '../dist/lib/repo.js';

const day = (d, opened, closed, open) => ({ day: d, opened, closed, open_at_end: open });
const DAY = 86400;

test('a week starts on Monday, in UTC', () => {
  // 2026-09-14 is a Monday; the Sunday before it belongs to the previous week.
  assert.equal(isoWeekStart('2026-09-14'), '2026-09-14');
  assert.equal(isoWeekStart('2026-09-20'), '2026-09-14');
  assert.equal(isoWeekStart('2026-09-13'), '2026-09-07');
  assert.equal(isoWeekStart('not-a-day'), null);
});

// opened and closed are RATES and sum; open_at_end is a LEVEL and does not.
// Summing seven levels would print a backlog seven times larger than anything
// the repository ever actually held, on a card whose whole job is to say
// whether the backlog is growing.
test('weekly flow sums the rates and takes the last level', () => {
  const [w] = weeklyFlow([
    day('2026-09-14', 3, 1, 100),
    day('2026-09-15', 2, 5, 97),
    day('2026-09-16', 0, 2, 95),
  ]);
  assert.equal(w.week, '2026-09-14');
  assert.equal(w.opened, 5);
  assert.equal(w.closed, 8);
  assert.equal(w.openAtEnd, 95, 'the level must be the last day, never a sum');
  assert.equal(net(w), -3);
});

test('weeks come back in order and a missing level stays missing', () => {
  const ws = weeklyFlow([
    { day: '2026-09-21', opened: 1, closed: 0 },
    day('2026-09-07', 1, 1, 10),
  ]);
  assert.deepEqual(ws.map((w) => w.week), ['2026-09-07', '2026-09-21']);
  assert.equal(ws[1].openAtEnd, null, 'a day that reported no level must not invent one');
});

// The bands are the repository's own percentiles. There is no code path in
// this module that produces a band edge from a constant.
test('bands are cut from the shipped percentiles', () => {
  const bands = scaleBands({ p50_seconds: 3 * 3600, p90_seconds: 4 * DAY, p95_seconds: 11 * DAY });
  assert.deepEqual(bands.map((b) => b.edge), ['p50', 'p90', 'p95', 'p95']);
  assert.deepEqual(bands.map((b) => b.to), [3 * 3600, 4 * DAY, 11 * DAY, null]);
});

test('a partial distribution still gives a usable ladder', () => {
  const bands = scaleBands({ p95_seconds: 11 * DAY });
  assert.deepEqual(bands.map((b) => [b.from, b.to]), [[0, 11 * DAY], [11 * DAY, null]]);
});

// No scale is a different answer from no issues, and the two must never
// render the same: one says "nothing is old", the other says "there is no way
// to know". A fallback threshold here would be a claim about this repository
// that nobody measured.
test('no percentiles means no bands and no histogram — not an empty one', () => {
  assert.deepEqual(scaleBands(null), []);
  assert.deepEqual(scaleBands({}), []);
  assert.equal(ageHistogram([{ age_seconds: 10 * DAY }], null), null);
  assert.equal(ageHistogram([{ age_seconds: 10 * DAY }], {}), null);
});

// Out-of-order percentiles are a shipper bug. Sorting them silently would
// hide it from the only person who can fix it.
test('percentiles that are not ordered are refused, not repaired', () => {
  assert.deepEqual(scaleBands({ p50_seconds: 10 * DAY, p95_seconds: 1 * DAY }), []);
});

test('issues land in the band their own age puts them in', () => {
  const scale = { p50_seconds: 1 * DAY, p90_seconds: 5 * DAY, p95_seconds: 10 * DAY };
  const hist = ageHistogram([
    { age_seconds: 3600 }, { age_seconds: 2 * DAY }, { age_seconds: 7 * DAY },
    { age_seconds: 40 * DAY }, { age_seconds: 400 * DAY },
  ], scale);
  assert.deepEqual(hist.map((b) => b.count), [1, 1, 1, 2]);
});

// The same backlog is stalled in one repository and perfectly healthy in
// another. That is the entire point of scaling to the repo's own p95.
test('the same ages are stalled or not depending on the repository', () => {
  const issues = [
    { number: 1, state: 'open', age_seconds: 40 * DAY },
    { number: 2, state: 'open', age_seconds: 2 * DAY },
    { number: 3, state: 'closed', age_seconds: 900 * DAY },
  ];
  const fast = stalled(issues, { p95_seconds: 11 * DAY });
  assert.deepEqual(fast.rows.map((i) => i.number), [1]);

  const slow = stalled(issues, { p95_seconds: 180 * DAY });
  assert.deepEqual(slow.rows, [], 'nothing is stalled where p95 is half a year');
  assert.equal(slow.reason, 'none');
});

test('without a p95 there is no stalled list at all', () => {
  const r = stalled([{ state: 'open', age_seconds: 900 * DAY }], { p50_seconds: 1 });
  assert.deepEqual(r.rows, []);
  assert.equal(r.reason, 'no-scale', 'the caller must be able to say WHY the list is empty');
});

test('stalled rows come back worst first', () => {
  const r = stalled([
    { number: 1, state: 'open', age_seconds: 20 * DAY },
    { number: 2, state: 'open', age_seconds: 60 * DAY },
    { number: 3, state: 'open', age_seconds: 30 * DAY },
  ], { p95_seconds: 10 * DAY });
  assert.deepEqual(r.rows.map((i) => i.number), [2, 3, 1]);
});

// Open, and the work already landed. That is a close, not an investigation,
// and it is the actionable half of any stalled list.
test('shipped-but-open finds the issues nobody closed', () => {
  const got = shippedButOpen([
    { number: 1, state: 'open', shipped_at: '2026-09-01T00:00:00Z' },
    { number: 2, state: 'open' },
    { number: 3, state: 'closed', shipped_at: '2026-09-01T00:00:00Z' },
  ]);
  assert.deepEqual(got.map((i) => i.number), [1]);
});

// A backlog whose ages read "1123200" is a backlog nobody reads.
test('ages render at the coarsest unit that still says something', () => {
  const t = (k, v) => `${v.n}${k.split('.').pop()}`;
  assert.equal(fmtAge(600, t), '10m');
  assert.equal(fmtAge(3 * 3600, t), '3h');
  assert.equal(fmtAge(4.6 * DAY, t), '4.6d');
  assert.equal(fmtAge(400 * DAY, t), '13.3mo');
  assert.equal(fmtAge(-5, t), '0m', 'a negative age is a clock problem, not a negative number on a card');
});

// A link outliving the repository it names should still open on something.
// Rendering an empty page instead would make a stale bookmark look like a hub
// that lost its data.
test('an unknown repository in the URL falls back, it does not blank the page', () => {
  const repos = [{ repo: 'o/a' }, { repo: 'o/b' }];
  assert.equal(pickRepo('o/b', repos), 'o/b');
  assert.equal(pickRepo('o/gone', repos), 'o/a', 'falls back to the most recently observed');
  assert.equal(pickRepo(null, repos), 'o/a');
  assert.equal(pickRepo('o/a', []), undefined, 'no repositories at all is the caller\u2019s problem to render');
});

/* ------------------------------------------------- narrowing the stalled list */

// The rows the live hub actually returns: 24 stalled issues of which 11 had
// already shipped, 8 carried no label at all, and one label (`do-not-close`)
// is deliberately on issues nobody intends to close. A fixture that gave every
// row a label would never have caught the facet arithmetic below.
const issue = (number, ageDays, extra = {}) => ({
  number, state: 'open', age_seconds: ageDays * DAY, comments: 0, ...extra,
});

test('label facets count labels, not rows — and never claim to', () => {
  const rows = [
    issue(1, 40, { labels: ['security', 'priority:p0'] }),
    issue(2, 30, { labels: ['security'] }),
    issue(3, 20, { labels: ['product'] }),
    issue(4, 19, {}), // no labels at all: eight of the real twenty-four
  ];
  const facets = labelFacets(rows);
  assert.deepEqual(facets, [
    { label: 'security', count: 2 },
    { label: 'priority:p0', count: 1 },
    { label: 'product', count: 1 },
  ], 'commonest first, then alphabetical so the picker does not reshuffle on a tie');
  // The sum is 4 over 4 rows here only by accident; the invariant is that
  // nothing in this function ever claims the counts partition the rows.
  assert.equal(facets.reduce((a, f) => a + f.count, 0), 4);
  assert.deepEqual(labelFacets([]), []);
  assert.deepEqual(labelFacets(null), []);
});

// A picker reading "All" over a filtered table is worse than an empty table:
// the reader cannot see that anything is being hidden.
test('a label nothing carries any more stays in the picker at zero', () => {
  const rows = [issue(1, 40, { labels: ['security'] })];
  assert.deepEqual(labelFacets(rows, 'infra'), [
    { label: 'security', count: 1 },
    { label: 'infra', count: 0 },
  ]);
  // ...and one that IS carried is not duplicated onto the end.
  assert.deepEqual(labelFacets(rows, 'security'), [{ label: 'security', count: 1 }]);
});

test('filtering by label and by "already shipped" are independent', () => {
  const rows = [
    issue(1, 40, { labels: ['security'], shipped_at: '2026-09-01T00:00:00Z' }),
    issue(2, 30, { labels: ['security'] }),
    issue(3, 20, { labels: ['product'], shipped_at: '2026-09-02T00:00:00Z' }),
    issue(4, 19, {}),
  ];
  assert.deepEqual(filterStalled(rows, {}).map((r) => r.number), [1, 2, 3, 4], 'no filter keeps everything');
  assert.deepEqual(filterStalled(rows, { label: 'security' }).map((r) => r.number), [1, 2]);
  assert.deepEqual(filterStalled(rows, { shippedOnly: true }).map((r) => r.number), [1, 3]);
  assert.deepEqual(filterStalled(rows, { label: 'security', shippedOnly: true }).map((r) => r.number), [1]);
  assert.deepEqual(filterStalled(rows, { label: 'nothing-has-this' }), [],
    'an empty result is a real answer here; the caller must not read it as "nothing is stalled"');
  assert.deepEqual(filterStalled(null, { label: 'x' }), []);
});

test('both sort axes read descending, and ties never reshuffle', () => {
  const rows = [
    issue(10, 5, { comments: 3 }),
    issue(2, 40, { comments: 3 }),
    issue(7, 12, { comments: 9 }),
  ];
  assert.deepEqual(sortStalled(rows, 'age').map((r) => r.number), [2, 7, 10]);
  assert.deepEqual(sortStalled(rows, 'comments').map((r) => r.number), [7, 2, 10],
    'equal comment counts break on issue number, not on input order');
  // This card re-renders on the page's 60s timer. A sort that reordered equal
  // rows would move them under the reader once a minute.
  const once = sortStalled(rows, 'comments').map((r) => r.number);
  const again = sortStalled([...rows].reverse(), 'comments').map((r) => r.number);
  assert.deepEqual(again, once, 'the order must not depend on the order the rows arrived in');
  // An unknown axis is the age axis rather than an unsorted table: the URL is
  // validated upstream, and a table in input order would look sorted.
  assert.deepEqual(sortStalled(rows, 'nonsense').map((r) => r.number), [2, 7, 10]);
  assert.deepEqual(sortStalled(null, 'age'), []);
  assert.ok(STALLED_SORTS.includes('age') && STALLED_SORTS.includes('comments'));
});

// The three compose the way the card calls them, on the shape the live hub
// returns: stalled → filter → sort, with the totals the hint line prints.
test('stalled, filtered and sorted compose into what the card shows', () => {
  const scale = { p95_seconds: 18 * DAY };
  const rows = [
    issue(101, 71, { labels: ['security'] }),
    issue(102, 59, { labels: ['do-not-close'], shipped_at: '2026-09-01T00:00:00Z', comments: 4 }),
    issue(103, 20, { labels: ['security'], shipped_at: '2026-09-02T00:00:00Z', comments: 1 }),
    issue(104, 2, { labels: ['security'] }), // inside p95: never reaches the table
  ];
  const { rows: st } = stalled(rows, scale);
  assert.deepEqual(st.map((r) => r.number), [101, 102, 103]);
  const shown = sortStalled(filterStalled(st, { label: 'security', shippedOnly: true }), 'age');
  assert.deepEqual(shown.map((r) => r.number), [103]);
  assert.equal(shown.length, 1);
  assert.equal(st.length, 3, 'the hint prints "1 of 3" — the denominator is what is stalled, not what is open');
});
