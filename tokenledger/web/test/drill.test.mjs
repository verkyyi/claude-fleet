import test from 'node:test';
import assert from 'node:assert/strict';

// Issue #99: `/u/<login>` has been routed (internal/api/server.go) and served
// (internal/api/user.go) since it was added, and /access has been listing it
// as a door the whole time — while nothing on the dashboard linked to it. A
// by-user breakdown row was a dead end: the only way to that page was to type
// the URL.
//
// What this file pins is the SHAPE of the way in, because every part of it is
// something a later edit can quietly undo:
//   - the link is an `<a href>`, so cmd-click / middle-click / "open in new
//     tab" work. A `<div onclick>` looks identical and is none of those.
//   - it does not replace the row's existing click (which adds a filter
//     chip). Both are useful; the issue asks for the second, not instead of
//     the first.
//   - it lives inside `.v`, NOT in a fourth grid column, so a card with links
//     draws its bars at the same width as a card without. That is issue #51's
//     shared scale: two lists at one `max` are comparable by eye only if a
//     full track is the same number of pixels on both.
//   - the table fallback has it too. The table IS the chart for anyone the
//     drawing does not serve, and a door only in the bars is a door behind a
//     picture.
//
// The DOM stub is the one in charts-aria.test.mjs, for the reason stated
// there: this repo has no npm pipeline, so there is no jsdom to reach for.

const rect = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 });

const makeNode = (tag) => ({
  tagName: tag,
  attrs: {},
  children: [],
  listeners: {},
  style: {},
  dataset: {},
  setAttribute(k, v) { this.attrs[k] = String(v); },
  getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; },
  removeAttribute(k) { delete this.attrs[k]; },
  appendChild(c) { this.children.push(c); return c; },
  append(...cs) { this.children.push(...cs); },
  replaceChildren(...cs) { this.children = cs; },
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); },
  querySelector: () => null,
  getBoundingClientRect: rect,
});

const tipNode = makeNode('div');
globalThis.document = {
  createElementNS: (_ns, tag) => makeNode(tag),
  createTextNode: (text) => ({ tagName: '#text', text, children: [] }),
  querySelector: (sel) => (sel === '#tip' ? tipNode : null),
  querySelectorAll: () => [],
  documentElement: makeNode('html'),
};
globalThis.addEventListener = () => {};
globalThis.innerWidth = 1200;
globalThis.innerHeight = 800;

const C = await import('../dist/charts.js');

const hasClass = (n, c) => String((n.attrs && n.attrs.class) || '').split(/\s+/).includes(c);
const find = (n, pred) => {
  if (!n || typeof n !== 'object') return null;
  if (pred(n)) return n;
  for (const kid of n.children || []) {
    const hit = find(kid, pred);
    if (hit) return hit;
  }
  return null;
};
const anchor = (n) => find(n, (x) => x.tagName === 'a');

const ROW = { key: 'liang.hui', value: 900, prev: 400, cells: [{ text: '900', class: 'tok' }, { text: '23.0%', class: 'pct' }] };

test('a row with an href gets a real link, named, that a reader can open', () => {
  const bars = C.rankedBars([{ ...ROW, href: '/u/liang.hui', hrefLabel: "Open liang.hui's own page" }]);
  const a = anchor(bars);
  assert.ok(a, 'the row rendered no <a> — there is still no way from this row to that page');
  assert.equal(a.getAttribute('href'), '/u/liang.hui');
  // The glyph is not an accessible name. Without this the link announces as
  // "link" — or as the character itself — which is exactly as useful as the
  // dead end it replaced.
  const name = a.getAttribute('aria-label');
  assert.ok(name && name.length > 4, `the drill-in link has no accessible name: ${JSON.stringify(name)}`);
  assert.ok(!/^[a-z]+\.[a-zA-Z.]+$/.test(name), `accessible name is an untranslated i18n key: ${name}`);
});

test('the link is inside the value column, not a fourth track-stealing column', () => {
  // The regression this pins was real and measured: given its own 22px grid
  // column plus a gap, the bar track lost ~60px, and a side-by-side pair drawn
  // at one shared `max` disagreed about how long the same number of tokens is.
  const bars = C.rankedBars([{ ...ROW, href: '/u/liang.hui', hrefLabel: 'Open' }]);
  const row = bars.children[0];
  assert.equal(row.children.length, 3,
    'the bar row grew a column — the track is drawn in the 1fr between them, so this shortens every bar on the card');
  const v = row.children[2];
  assert.ok(hasClass(v, 'v'), 'the third child is no longer the value column');
  assert.ok(anchor(v), 'the link is not inside the value column');
});

test('the link does not take over the row: the chip click is still there', () => {
  let chipped = 0;
  const bars = C.rankedBars([{ ...ROW, href: '/u/liang.hui', hrefLabel: 'Open' }], { onClick: () => { chipped += 1; } });
  const row = bars.children[0];
  assert.equal(row.getAttribute('role'), 'button', 'the row stopped being clickable when it gained a link');
  row.listeners.click[0]();
  assert.equal(chipped, 1, 'clicking the row no longer adds a filter chip');
  // And the link stops the click at itself, so opening the page does not also
  // filter the list the reader is walking away from.
  const a = anchor(row);
  let stopped = false;
  a.listeners.click[0]({ stopPropagation: () => { stopped = true; } });
  assert.ok(stopped, 'a click on the link would bubble to the row and filter the page being left');
});

test('a row without an href is exactly what it was', () => {
  const bars = C.rankedBars([{ key: 'laptop', value: 10, right: '10%' }]);
  assert.equal(anchor(bars), null, 'a caller that asked for no link got one');
  assert.equal(bars.children[0].children.length, 3);
});

test('cells are separate elements, so a column of figures reads as a column', () => {
  // One packed string ("717,858 · 23.0% · claude — subscription") is ~260px
  // of content in a column that is 32% of half a page. It clipped on every
  // row, and what survived did not line up, because each row's text starts
  // wherever its own content does.
  const bars = C.rankedBars([ROW]);
  const v = bars.children[0].children[2];
  const cells = (v.children || []).filter((c) => hasClass(c, 'vc'));
  assert.equal(cells.length, 2, 'the figures did not come out as separate cells');
  assert.ok(hasClass(cells[1], 'pct'), 'the share cell lost the class that gives it a fixed width');
});

test('the table fallback carries the same door', () => {
  const buckets = [{ key: 'liang.hui', events: 3, tokens: 900, cost: [] }];
  const table = C.bucketTable(buckets, 'Login', [], { keyHref: (b) => `/u/${b.key}` });
  const a = anchor(table);
  assert.ok(a, 'the table key cell is not a link — the drill-in exists only in the drawing');
  assert.equal(a.getAttribute('href'), '/u/liang.hui');
  // Unasked-for, absent: every other bucketTable caller renders plain text.
  assert.equal(anchor(C.bucketTable(buckets, 'Login')), null);
});
