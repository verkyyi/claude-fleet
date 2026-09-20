import test from 'node:test';
import assert from 'node:assert/strict';
import { isDismissed, setDismissed } from '../dist/lib/dismiss.js';

// A Storage-shaped fake. The module takes one as its last argument precisely so
// this file can drive it without a browser.
const fake = () => {
  const m = new Map();
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), map: m };
};

test('a dismissal persists, and re-opening is honoured too', () => {
  const s = fake();
  assert.equal(isDismissed('banner-all-subs', s), false, 'nothing is dismissed to start with');
  setDismissed('banner-all-subs', true, s);
  assert.equal(isDismissed('banner-all-subs', s), true);
  // Namespaced: this store belongs to the whole origin, and the ops fold and
  // the chart toggles are already in it.
  assert.ok([...s.map.keys()].every((k) => k.startsWith('ccquota-dismissed-')));
  // A second banner is a second key, not the same one.
  assert.equal(isDismissed('something-else', s), false);
  setDismissed('banner-all-subs', false, s);
  assert.equal(isDismissed('banner-all-subs', s), false);
});

// The #92 acceptance criterion: a private window, or cleared site data, must
// leave the page rendering -- with the banner shown, never hidden. Both
// directions fail closed and neither may throw.
test('an unusable store means "not dismissed", never a throw', () => {
  const throws = { get getItem() { throw new Error('SecurityError'); }, get setItem() { throw new Error('SecurityError'); } };
  assert.equal(isDismissed('banner-all-subs', throws), false);
  assert.doesNotThrow(() => setDismissed('banner-all-subs', true, throws));

  const thrower = { getItem: () => { throw new Error('QuotaExceeded'); }, setItem: () => { throw new Error('QuotaExceeded'); } };
  assert.equal(isDismissed('banner-all-subs', thrower), false);
  assert.doesNotThrow(() => setDismissed('banner-all-subs', true, thrower));

  // No store at all -- which is also what the module resolves to in Node,
  // where `globalThis.localStorage` is absent. So the bare calls must be safe.
  assert.equal(isDismissed('banner-all-subs', null), false);
  assert.doesNotThrow(() => setDismissed('banner-all-subs', true, null));
  assert.equal(isDismissed('banner-all-subs'), false);
  assert.doesNotThrow(() => setDismissed('banner-all-subs', true));
});

// A value the page did not write -- a half-cleared store, or a key another
// build used -- is not a dismissal. Only the exact '1' is.
test('only an exact "1" counts as dismissed', () => {
  const s = fake();
  for (const junk of ['0', 'true', '', 'yes', '11']) {
    s.setItem('ccquota-dismissed-banner-all-subs', junk);
    assert.equal(isDismissed('banner-all-subs', s), false, junk);
  }
});
