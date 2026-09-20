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
