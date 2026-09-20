import test from 'node:test';
import assert from 'node:assert/strict';
import { SECTIONS, pickActive } from '../dist/lib/nav.js';
import { en } from '../dist/lib/i18n/en.js';

// The bar is ~96px; these tops are viewport-relative, the way
// getBoundingClientRect() reports them.
const NAV = 96;

test('at the top of the page the first band is current', () => {
  // Nothing has passed under the bar yet: every band is below it.
  assert.equal(pickActive([120, 900, 2400, 3800], NAV), 0);
});

test('the current band is the last one scrolled past, not the nearest', () => {
  // Usage is 40px above the line and Progress is 700px below it. "Nearest
  // band" would pick Progress; the reader is reading Usage.
  assert.equal(pickActive([-1400, 56, 796, 2200], NAV), 1);
  // Scroll on until Progress crosses: now it is Progress.
  assert.equal(pickActive([-2100, -640, 90, 1500], NAV), 2);
});

test('a band on the line counts as passed, and a jump that lands just short still counts', () => {
  assert.equal(pickActive([-500, 96, 1800], NAV), 1);
  // Subpixel layout does not flip it back...
  assert.equal(pickActive([-500, 96.4, 1800], NAV), 1);
  // ...and neither does a click that settles a pixel or two below the line,
  // which is the case that had the nav marking the band ABOVE the one the
  // reader had just jumped to.
  assert.equal(pickActive([-500, 97.8, 1800], NAV), 1);
  assert.equal(pickActive([-500, 100, 1800], NAV), 1);
  // Grace runs out well before the next band, which is ~700px away here.
  assert.equal(pickActive([-500, 101, 1800], NAV), 0);
});

test('the bottom of the document always lights the last entry', () => {
  // The whole reason this override exists: Operations folded shut is a single
  // <summary> line, so scrolled to the very end its top is still well below
  // the bar and the plain rule would leave Progress marked.
  assert.equal(pickActive([-3800, -2400, -900, 700], NAV, true), 3);
  assert.equal(pickActive([-3800, -2400, -900, 700], NAV, false), 2);
});

test('the pick is over the VISIBLE entries, so a hub with no repo data agrees', () => {
  // scope.js passes only the bands that exist; on a hub nobody ships repo
  // facts to, Progress is not among them and the indices close up.
  const noProgress = [-2000, -700, 400]; // ledger, usage, ops
  assert.equal(pickActive(noProgress, NAV), 1);
  assert.equal(pickActive(noProgress, NAV, true), 2);
});

test('nothing to navigate means nothing marked', () => {
  assert.equal(pickActive([], NAV), -1);
});

test('every section targets a band label, and prints that band own key', () => {
  assert.deepEqual(SECTIONS.map((s) => s.target),
    ['ledger-band', 'usage-band', 'repo-band', 'ops']);
  // The nav must not carry its own copy of the band names: `band.ledger` is
  // what index.html prints on the band itself, so the two cannot disagree.
  assert.deepEqual(SECTIONS.map((s) => s.key),
    ['band.ledger', 'band.usage', 'band.progress', 'ops.title']);
  // t() falls back to the key, so a nav entry naming a key no dictionary has
  // renders the literal `band.ledger` in the sticky bar of every page view.
  for (const { key } of SECTIONS) {
    assert.ok(key in en, `${key} is missing from the dictionary`);
  }
});
