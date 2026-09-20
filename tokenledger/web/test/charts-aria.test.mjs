import test from 'node:test';
import assert from 'node:assert/strict';

// The defect this file exists for (issue #56): of the thirteen charts this
// dashboard draws, ELEVEN announced nothing at all. An `<svg>` full of
// `<rect>`s and a `<div>` grid of coloured `<i>`s are not "hard to read"
// without a role and a label — they are absent from the accessibility tree
// entirely, and no amount of care in the drawing changes that. Two charts had
// labels only because two separate issues (#52, and the repo flow chart)
// happened to add them by hand, one chart at a time, which is exactly how the
// other eleven stayed missing for as long as they did.
//
// So the property pinned here is not "chart X has a label" — it is that EVERY
// chart primitive charts.js exports returns something a screen reader can
// name. A chart added later that forgets fails this file rather than shipping
// silent, which is the only version of this fix that survives the next chart.
//
// charts.js is DOM-producing, and this repo deliberately has no npm pipeline
// (see the Makefile: "a contributor needs only a Go toolchain"), so there is
// no jsdom to reach for. The stub below is the whole DOM these primitives
// touch — createElementNS, setAttribute, appendChild — in about forty lines,
// which is cheaper than the dependency and pins the attributes just as well.

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
  // Enough of a selector engine for the one shape charts.js asks for:
  // `timeline` looks its two brush handles up as '.h.l' / '.h.r'.
  querySelector(sel) {
    const want = sel.split('.').filter(Boolean);
    const walk = (n) => {
      const have = String((n.attrs && n.attrs.class) || '').split(/\s+/);
      if (want.every((c) => have.includes(c))) return n;
      for (const kid of n.children || []) {
        const hit = kid && kid.attrs ? walk(kid) : null;
        if (hit) return hit;
      }
      return null;
    };
    for (const kid of this.children) {
      const hit = kid && kid.attrs ? walk(kid) : null;
      if (hit) return hit;
    }
    return null;
  },
  getBoundingClientRect: rect,
});

// One stable `#tip` node: dom.js caches it at module-eval time, so the tests
// below can read back exactly what a hover or a focus wrote into it.
const tipNode = makeNode('div');

globalThis.document = {
  createElementNS: (_ns, tag) => makeNode(tag),
  createTextNode: (text) => ({ tagName: '#text', text, children: [] }),
  // dom.js caches `#tip` at module-eval time and i18n.js stamps `lang` on the
  // root element; both have to answer or the imports below throw.
  querySelector: (sel) => (sel === '#tip' ? tipNode : null),
  querySelectorAll: () => [],
  documentElement: makeNode('html'),
};
globalThis.addEventListener = () => {};
globalThis.innerWidth = 1200;
globalThis.innerHeight = 800;

const C = await import('../dist/charts.js');

/** labelled asserts the one property this file is about: `node` is in the
 *  accessibility tree as an image, and it says something. Charts that return
 *  a wrapper (svg + legend) put the role on the drawing inside, so this
 *  walks down to find it — what matters is that a labelled graphic exists
 *  somewhere in what the caller gets back, not how deep it sits. */
function findLabelled(node) {
  if (!node || typeof node !== 'object') return null;
  if (node.attrs && node.attrs.role === 'img' && node.attrs['aria-label']) return node;
  for (const kid of node.children || []) {
    const hit = findLabelled(kid);
    if (hit) return hit;
  }
  return null;
}

function labelled(node, what) {
  const hit = findLabelled(node);
  assert.ok(hit, `${what} returned no element with role="img" + aria-label — it is invisible to a screen reader`);
  // A label that is only the empty string, or that is the i18n KEY because
  // the dictionary entry was never written, passes a naive truthiness check
  // and tells a reader nothing. Both are failures.
  const label = hit.attrs['aria-label'];
  assert.ok(label.length > 10, `${what}: aria-label is too short to say anything: ${JSON.stringify(label)}`);
  assert.ok(!/^[a-z]+\.[a-zA-Z.]+$/.test(label), `${what}: aria-label is an untranslated i18n key: ${label}`);
  return label;
}

/* --------------------------------------------------------------- fixtures */

const HOURLY = [
  { key: '2026-09-18T00:00', tokens: 1200, events: 4, cost: [] },
  { key: '2026-09-18T01:00', tokens: 3400, events: 9, cost: [] },
  { key: '2026-09-18T02:00', tokens: 800, events: 2, cost: [] },
];
const MODELS = ['claude-opus-4-1', 'claude-sonnet-4-5'];
const STACKED = HOURLY.map((s, i) => ({
  key: s.key,
  tokens: s.tokens,
  stack: { [MODELS[0]]: s.tokens * 0.6, [MODELS[1]]: s.tokens * 0.3, 'some-other-model': s.tokens * 0.1 + i },
}));
const EXT = { start: Date.parse('2026-09-18T00:00:00Z'), end: Date.parse('2026-09-18T03:00:00Z'), bucket: 36e5, n: 3 };

const grid7x24 = () => Array.from({ length: 7 }, () => new Array(24).fill(0));

/* ------------------------------------------------------------------ tests */

test('every chart primitive returns a named graphic', () => {
  labelled(C.bars(HOURLY, 'hour'), 'bars');
  labelled(C.timeline(STACKED, { bucket: EXT.bucket, extent: EXT, stackNames: MODELS }), 'timeline');
  labelled(C.stackedArea(STACKED, MODELS, { bucket: EXT.bucket, granularity: 'hour' }), 'stackedArea');
  labelled(C.lines([{ label: 'work', points: [{ ts: EXT.start, five_hour_pct: 40, seven_day_pct: 20 }] }],
    { start: EXT.start, end: EXT.end }), 'lines');
  labelled(C.turnBars([{ tokens: 900, model: MODELS[0] }, { tokens: 400, model: MODELS[1], sidechain: true }]), 'turnBars');
  labelled(C.composition([{ key: 'cache read', tokens: 800, color: '#111' },
    { key: 'output', tokens: 200, color: '#222' }]), 'composition');

  const grid = grid7x24(), events = grid7x24();
  grid[3][14] = 9000; events[3][14] = 12;
  labelled(C.heatmap(grid, events), 'heatmap');
});

test('a chart names the span it covers, not just its own kind', () => {
  // The span is the half of the label a reader actually needs to decide
  // whether to open the table: "tokens over time" is true of six cards.
  const tl = labelled(C.timeline(STACKED, { bucket: EXT.bucket, extent: EXT, stackNames: MODELS }), 'timeline');
  assert.match(tl, /09-18/, 'timeline label does not name the extent it was drawn over');

  const wall = labelled(C.lines([{ label: 'work', points: [] }], { start: EXT.start, end: EXT.end }), 'lines');
  assert.match(wall, /09-18/, 'wall-history label does not name the window it was drawn over');

  const grid = grid7x24();
  grid[3][14] = 9000;
  const heat = labelled(C.heatmap(grid, grid7x24()), 'heatmap');
  assert.match(heat, /14:00/, 'heatmap label does not name its busiest hour');
});

test('an empty heatmap says so rather than claiming a busiest hour', () => {
  const label = labelled(C.heatmap(grid7x24(), grid7x24()), 'empty heatmap');
  assert.doesNotMatch(label, /00:00/, 'an all-zero grid reported cell 0,0 as its peak');
});

test('the table toggle names itself, reports its state, and points at the table', () => {
  const card = makeNode('div');
  const chart = C.bars(HOURLY, 'hour');
  const table = C.bucketTable(HOURLY, 'Hour');
  C.withTable(card, chart, table, 'test-card');

  const btn = card.children.find((c) => c.tagName === 'button');
  assert.ok(btn, 'withTable produced no toggle button');
  assert.ok(btn.getAttribute('aria-label'), 'the toggle has no accessible name — "⊞" is not one');
  assert.equal(btn.getAttribute('aria-controls'), table.id, 'aria-controls does not point at the table it swaps in');
  assert.ok(table.id, 'the table got no id for aria-controls to reference');

  // The state has to be TRUE, not merely present: an aria-expanded that is
  // only correct on first render asserts something false for the rest of the
  // session, which is worse than leaving it off.
  assert.equal(btn.getAttribute('aria-expanded'), 'false');
  assert.equal(chart.hidden, false);
  btn.listeners.click[0]();
  assert.equal(btn.getAttribute('aria-expanded'), 'true', 'clicking the toggle did not update aria-expanded');
  assert.equal(chart.hidden, true);
  btn.listeners.click[0]();
  assert.equal(btn.getAttribute('aria-expanded'), 'false');
});

test('the toggle comes before the content it is the way out of', () => {
  // Reading and tab order, not layout — the button is position:absolute, so
  // this is invisible on screen and decisive off it. It used to be appended
  // last, i.e. after the whole chart and the whole table.
  const card = makeNode('div');
  C.withTable(card, C.bars(HOURLY, 'hour'), C.bucketTable(HOURLY, 'Hour'), 'order-card');
  assert.equal(card.children[0].tagName, 'button');
});

test('a ranked row whose only detail is in the tip is reachable by keyboard', () => {
  // now.js's endpoint shares are the case: no onClick, and the tip is the
  // only place the "this is an estimate" caveat and the untruncated share
  // appear. Without a tabstop a keyboard user cannot reach either.
  const withTip = C.rankedBars([{ key: 'laptop', value: 10, right: '10%', tip: '<b>laptop</b><br>estimate' }]);
  const row = withTip.children[0];
  assert.equal(row.getAttribute('tabindex'), '0', 'a row carrying a tip is not focusable');
  assert.ok(row.listeners.focus, 'focus does not raise the tip');
  assert.ok(row.listeners.blur, 'blur does not hide the tip');

  // Still clickable rows keep their button semantics, and a row with neither
  // a tip nor a click target does NOT become a stray tab stop.
  const clickable = C.rankedBars([{ key: 'a', value: 1, right: '1' }], { onClick: () => {} });
  assert.equal(clickable.children[0].getAttribute('role'), 'button');
  assert.equal(clickable.children[0].getAttribute('tabindex'), '0');

  const plain = C.rankedBars([{ key: 'a', value: 1, right: '1' }]);
  assert.equal(plain.children[0].getAttribute('tabindex'), null, 'a plain readout row became a tab stop for nothing');
});

test('focusing a row fills the tip instead of writing NaN into its position', () => {
  // A FocusEvent has no clientX/clientY. The old arithmetic produced
  // "NaNpx" for both coordinates, the browser drops an invalid length, and
  // the tip therefore stayed wherever the last mouse hover had left it —
  // top-left of the viewport in a keyboard-only session — while its text
  // changed underneath. So the fix is not just "call showTip on focus": the
  // tooltip has to hang off the focused element's own box.
  const rows = C.rankedBars([{ key: 'laptop', value: 10, right: '10%', tip: '<b>laptop</b><br>estimate' }]);
  const row = rows.children[0];
  row.getBoundingClientRect = () => ({ ...rect(), left: 120, top: 280, right: 400, bottom: 300 });

  row.listeners.focus[0]({ type: 'focus', currentTarget: row, target: row });

  assert.equal(tipNode.innerHTML, '<b>laptop</b><br>estimate', 'focus did not fill the tip');
  assert.equal(tipNode.style.opacity, '1', 'the tip was filled but left invisible');
  assert.doesNotMatch(tipNode.style.left, /NaN/, 'the tip was positioned with a pointer coordinate that does not exist');
  assert.doesNotMatch(tipNode.style.top, /NaN/, 'the tip was positioned with a pointer coordinate that does not exist');
  // Below and right of the row, the same relation the mouse path produces.
  assert.equal(tipNode.style.left, '134px');
  assert.equal(tipNode.style.top, '314px');

  row.listeners.blur[0]();
  assert.equal(tipNode.style.opacity, '0', 'blur left the tip on screen');
});

test('a mouse hover still positions from the cursor', () => {
  // The focus path must not have cost the pointer path its own anchoring:
  // a real clientX of 0 is a position, not a missing one.
  const rows = C.rankedBars([{ key: 'laptop', value: 10, right: '10%', tip: 'x' }]);
  const row = rows.children[0];
  row.listeners.mousemove[0]({ clientX: 0, clientY: 0 });
  assert.equal(tipNode.style.left, '14px');
  assert.equal(tipNode.style.top, '14px');
});
