import test from 'node:test';
import assert from 'node:assert/strict';
import { SECTIONS, BANDS, VIEW_ALL, VIEW_DEFAULT, DEFAULT_BANDS, bandsFor } from '../dist/lib/nav.js';
import { en } from '../dist/lib/i18n/en.js';

// #98 deleted this file's other export, `pickActive`, and the six tests that
// covered it. It was the scroll-spy's one decision -- given the measured tops
// of the visible bands and the height of the sticky bar, which band is the
// reader under -- and it went with the spy, because a view that MOUNTS one band
// and unmounts the rest has no such question left: the current view is the
// current entry, and there is no position on the page to measure. The tests
// below are its replacement, over the decision that took its place.

test('every section prints its own band key, and the dictionary has it', () => {
  // The nav must not carry its own copy of the band names: `band.ledger` is
  // what index.html prints on the band itself, so the two cannot disagree.
  assert.deepEqual(SECTIONS.map((s) => s.key),
    ['band.quota', 'band.ledger', 'band.usage', 'band.progress', 'ops.title']);
  // t() falls back to the key, so a nav entry naming a key no dictionary has
  // renders the literal `band.ledger` in the sticky bar of every page view.
  for (const { key } of SECTIONS) {
    assert.ok(key in en, `${key} is missing from the dictionary`);
  }
  // scope.js puts two more entries in front of these -- the way back to where
  // the page starts (#130) and the way to the whole page -- and neither is a
  // band, so neither is in SECTIONS. Both still print through t(), so both
  // still need a key that exists.
  assert.ok('nav.overview' in en, 'nav.overview is missing from the dictionary');
  assert.ok('nav.all' in en, 'nav.all is missing from the dictionary');
});

// #97: each entry also names the value it writes into the hash. The words are
// what a reader sees in a link they were sent, so they are short and they are
// not the element ids -- `view=progress` says where you are being sent,
// `view=repo-band` names a div. state.js derives VIEWS from this column, which
// is why a typo here is a routing bug and not just a cosmetic one. As of #98
// index.html tags its nodes with the same column (`data-band="progress"`), so
// one word now spans the URL, the markup and the fetch plan.
test('every section names the view it writes', () => {
  assert.deepEqual(SECTIONS.map((s) => s.view),
    ['quota', 'ledger', 'usage', 'progress', 'ops']);
  assert.deepEqual(BANDS, SECTIONS.map((s) => s.view));
  for (const { key, view } of SECTIONS) {
    assert.match(view, /^[a-z]+$/, `${key}: a view is a URL word`);
    // The markup's `-band` suffix must not reach the URL. Operations is the
    // exception the table already calls out on its other column: its band label
    // IS its <summary>, so `ops` is label and view at once -- one word, not an
    // id leaking out.
    assert.ok(!view.endsWith('-band'), `${key}: ${view} is an element id, not a URL word`);
  }
  // No two entries may write the same view: they would be two buttons the
  // router cannot tell apart, and mounting would have no way to pick a band.
  assert.equal(new Set(SECTIONS.map((s) => s.view)).size, SECTIONS.length);
  // ...and none of them may collide with either of the two words that are not
  // bands. `all` would mount every band if one tried to be; the default view
  // would mount two, and bandsFor would never reach the band of that name.
  assert.ok(!BANDS.includes(VIEW_ALL), 'a band may not be named "all"');
  assert.ok(!BANDS.includes(VIEW_DEFAULT), `a band may not be named "${VIEW_DEFAULT}"`);
  assert.notEqual(VIEW_DEFAULT, VIEW_ALL, 'the default view and "all" are two sets, so they are two words');
});

// #130's own table: what the page opens as. DEFAULT_BANDS is asserted against
// BANDS rather than only against its literal contents, because a typo in it is
// otherwise silent -- bandsFor filters, so a band spelled wrong simply does not
// come back and the page opens one band shorter than anyone intended.
test('the default set is quota and ledger, and both are real bands', () => {
  assert.deepEqual([...DEFAULT_BANDS], ['quota', 'ledger']);
  for (const band of DEFAULT_BANDS) {
    assert.ok(BANDS.includes(band), `${band} is not a band, so no view can mount it`);
  }
  // It is a strict subset both ways: smaller than the whole page (that is the
  // point of #130) and larger than one band (or it would be a band view with a
  // second name).
  assert.ok(DEFAULT_BANDS.length > 1 && DEFAULT_BANDS.length < BANDS.length);
});

// bandsFor is the whole of #98's routing decision, and as of #130 it has three
// cases rather than two. The isolation is what #98 asked for; `all` staying the
// WHOLE page is what keeps the bar's way back honest -- what it no longer keeps
// is where a bare link lands, which is #130 and is asserted below.
test('"all" is every band, and any single view is exactly itself', () => {
  assert.deepEqual(bandsFor(VIEW_ALL), BANDS);
  for (const band of BANDS) {
    assert.deepEqual(bandsFor(band), [band], `view=${band} must mount only its own band`);
  }
});

// The fourth turn (#130), asserted as the thing it actually is: the default is
// no longer `all`. lib/nav.js's header records all four turns and must keep
// doing so; this is the executable half.
test('the default view is the default set, and it is not the whole page', () => {
  assert.deepEqual(bandsFor(VIEW_DEFAULT), ['quota', 'ledger']);
  assert.deepEqual(bandsFor(VIEW_DEFAULT), [...DEFAULT_BANDS]);
  // The regression this file exists to catch: someone "simplifies" by pointing
  // the default back at every band, and every saving #130 bought goes quietly.
  assert.notDeepEqual(bandsFor(VIEW_DEFAULT), BANDS);
  // ...and the opposite regression: `all` quietly narrowed to the default set,
  // which would leave the page with no way to show usage, progress and ops
  // together at all.
  assert.equal(bandsFor(VIEW_ALL).length, BANDS.length);
  // Page order, not DEFAULT_BANDS' order: bandsFor filters BANDS, so this holds
  // however the list is written.
  assert.deepEqual(bandsFor(VIEW_DEFAULT), BANDS.filter((b) => DEFAULT_BANDS.includes(b)));
});

test('a view mounts its band and nothing else, in page order', () => {
  // Page order, not the order the caller happened to ask in: index.html's
  // <main> is a fixed sequence and app.js re-lists the survivors from it, so a
  // band can never appear above one that is written above it.
  assert.deepEqual(bandsFor(VIEW_ALL), ['quota', 'ledger', 'usage', 'progress', 'ops']);
  // Quota leads, and this is the assertion that says so (#95). The band it is
  // ahead of is the ledger, which #98 had just argued should open the page --
  // lib/nav.js's SECTIONS carries the argument for overturning that. Asserted
  // here rather than left to the list above because a later edit that "tidies"
  // the order alphabetically or by age would pass every other check in this
  // file.
  assert.equal(bandsFor(VIEW_ALL)[0], 'quota');
  // The ledger view does not carry the usage band's questions, which is the
  // measurable half of #98: review.js drops three of its four first-screen
  // requests here.
  assert.ok(!bandsFor('ledger').includes('usage'));
  assert.ok(!bandsFor('usage').includes('ledger'));
});

test('a view nothing can write mounts nothing', () => {
  // state.js's parse() falls back to the default before this is ever reached,
  // so this is the belt to that braces. Mounting nothing is the visible failure
  // rather than the silent one -- a page that shows every band for an unknown
  // word would hide the routing bug that produced it.
  assert.deepEqual(bandsFor('bogus'), []);
  assert.deepEqual(bandsFor(undefined), []);
});
