import test from 'node:test';
import assert from 'node:assert/strict';
import { createLoader, SKIPPED } from '../dist/lib/seq.js';

const later = (v, ms, signal) => new Promise((res, rej) => {
  const t = setTimeout(() => res(v), ms);
  signal?.addEventListener('abort', () => { clearTimeout(t); rej(new DOMException('aborted', 'AbortError')); });
});

test('a slower older load never overwrites a newer one', async () => {
  const L = createLoader();
  const applied = [];
  const a = L.run([(s) => later('old', 50, s)], (r) => applied.push(r[0].value));
  const b = L.run([(s) => later('new', 10, s)], (r) => applied.push(r[0].value));
  const [ra, rb] = await Promise.all([a, b]);
  assert.equal(ra, false);
  assert.equal(rb, true);
  assert.deepEqual(applied, ['new']);
  assert.equal(L.inFlight, false);
});

test('a failed request is reported per fetcher, not thrown', async () => {
  const L = createLoader();
  let got;
  await L.run([() => Promise.reject(new Error('boom')), () => Promise.resolve(1)], (r) => { got = r; });
  assert.equal(got[0].status, 'rejected');
  assert.equal(got[1].value, 1);
});

// A null slot means "this round is not asking that question". It exists so the
// page can leave out the requests that only fill the folded operations tier
// without renumbering the ones that stay — see now.js's NEEDED table and
// review.js's OPS_ONLY.

test('a null fetcher is not sent, and does not shift the ones that are', async () => {
  const L = createLoader();
  const sent = [];
  const f = (name) => () => { sent.push(name); return Promise.resolve(name); };
  let got;
  await L.run([f('a'), null, f('c'), null], (r) => { got = r; });
  assert.deepEqual(sent, ['a', 'c']);
  // Positions are a contract: app.js reads review's SUMMARY_INDEX by number,
  // and every apply() destructures. A hole stays a hole.
  assert.equal(got.length, 4);
  assert.equal(got[0].value, 'a');
  assert.equal(got[2].value, 'c');
  assert.equal(got[1].status, SKIPPED);
  assert.equal(got[3].status, SKIPPED);
});

test('a skipped slot is neither fulfilled nor rejected', async () => {
  // This is the whole reason SKIPPED is its own status. A card reading a
  // fulfilled-with-nothing slot draws an empty state -- "the hub has no
  // sessions to show" -- which about an unasked question is a false reading,
  // and reading a rejected one draws an error about a request that never
  // failed because it never happened.
  const L = createLoader();
  let got;
  await L.run([null], (r) => { got = r; });
  assert.equal(got[0].status, SKIPPED);
  assert.notEqual(got[0].status, 'fulfilled');
  assert.notEqual(got[0].status, 'rejected');
  assert.ok(!('value' in got[0]));
  assert.ok(!('reason' in got[0]));
});

test('an all-null list still applies, and still sequences', async () => {
  const L = createLoader();
  const applied = [];
  const ok = await L.run([null, null], (r) => applied.push(r.map((x) => x.status)));
  assert.equal(ok, true);
  assert.deepEqual(applied, [[SKIPPED, SKIPPED]]);
  assert.equal(L.inFlight, false);
});

test('holes do not break the newer-load-wins rule', async () => {
  const L = createLoader();
  const applied = [];
  // The fold can open mid-load: the first call is the small set, the second
  // the full one. The full one is newer and must be the one that lands.
  const a = L.run([null, (s) => later('small', 50, s)], (r) => applied.push(r[1].value));
  const b = L.run([(s) => later('full-0', 10, s), (s) => later('full-1', 10, s)], (r) => applied.push(r[1].value));
  const [ra, rb] = await Promise.all([a, b]);
  assert.equal(ra, false);
  assert.equal(rb, true);
  assert.deepEqual(applied, ['full-1']);
});

// replay is the other half of #36's fix, finally applied to the whole page: a
// change that only narrows or reorders rows already on screen must send
// nothing at all. Before it, sorting the consumption table cost 19 requests to
// reorder an array the browser was already holding.

test('replay redraws from the kept results and sends nothing', async () => {
  const L = createLoader();
  const sent = [];
  const applied = [];
  const f = (name) => () => { sent.push(name); return Promise.resolve(name); };
  await L.run([f('a'), f('b')], (r) => applied.push(r.map((x) => x.value)));
  assert.deepEqual(sent, ['a', 'b']);

  const again = [f('a'), f('b')];
  assert.equal(L.replay(again, (r) => applied.push(r.map((x) => x.value))), true);
  assert.deepEqual(sent, ['a', 'b'], 'a replay sends nothing');
  assert.deepEqual(applied, [['a', 'b'], ['a', 'b']]);
});

test('replay refuses before anything has been applied', () => {
  const L = createLoader();
  let applied = false;
  assert.equal(L.replay([() => Promise.resolve(1)], () => { applied = true; }), false);
  assert.equal(applied, false, 'refusing means "you have to fetch", so nothing is drawn');
});

test('replay refuses when this round asks something the kept set never asked', async () => {
  // The fold opened: the kept results are the small set, with holes exactly
  // where the open fold's cards read. Replaying them would draw those cards as
  // "no readings" -- see covers() in seq.js.
  const L = createLoader();
  const f = (name) => () => Promise.resolve(name);
  await L.run([f('a'), null], () => {});
  assert.equal(L.replay([f('a'), f('b')], () => {}), false, 'closed -> open must fetch');
  // The other direction is the common one and is safe: the fold closed, the
  // extra result simply goes unread.
  await L.run([f('a'), f('b')], () => {});
  assert.equal(L.replay([f('a'), null], () => {}), true, 'open -> closed replays');
  // A list of a different length is not the same plan at all.
  assert.equal(L.replay([f('a')], () => {}), false);
});

test('a replay supersedes an in-flight load', async () => {
  // The 60-second refresh went out 200ms ago and its apply() closes over the
  // state as it stood then. Left to land, it would put the table back in the
  // order the reader just clicked away from.
  const L = createLoader();
  const applied = [];
  await L.run([(s) => later('first', 1, s)], (r) => applied.push(r[0].value));
  const refresh = L.run([(s) => later('refresh', 50, s)], (r) => applied.push(r[0].value));
  assert.equal(L.replay([(s) => later('x', 1, s)], (r) => applied.push(r[0].value)), true);
  assert.equal(await refresh, false, 'the superseded refresh does not apply');
  assert.deepEqual(applied, ['first', 'first'], 'the click wins, drawn from the kept rows');
  assert.equal(L.inFlight, false);
});
