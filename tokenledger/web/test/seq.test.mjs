import test from 'node:test';
import assert from 'node:assert/strict';
import { createLoader } from '../dist/lib/seq.js';

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
