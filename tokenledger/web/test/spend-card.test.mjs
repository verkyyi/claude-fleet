import test from 'node:test';
import assert from 'node:assert/strict';

// The defect this file exists for (issue #94): the card whose entire job is to
// show ONE number was printing up to eight sentences around it — three of fx
// disclosure, three from the server, plus the incomplete and unpriced caveats.
// The fix is a fold, and a fold is exactly the kind of change that quietly
// becomes a DELETION later: a sentence dropped on the way into the <details>
// looks identical to a sentence that was never there, because nobody re-opens
// a closed fold to count what is inside it.
//
// So this file pins the split rather than the layout. Three properties:
//   1. the default (closed) view is the figure and its terms, nothing else;
//   2. what says "this number is LOW" — the `≥` and spend.incomplete — is
//      NEVER inside the fold, because folding a knowingly biased figure shows
//      it as if it were exact;
//   3. every sentence that used to be on the card is still in the DOM.
//
// web/dist has no npm pipeline (see the Makefile: "a contributor needs only a
// Go toolchain"), so there is no jsdom. The stub below is the whole DOM that
// `el` and this card touch, in the same shape charts-aria.test.mjs uses.

const makeNode = (tag) => ({
  tagName: tag,
  attrs: {},
  children: [],
  listeners: {},
  style: {},
  dataset: {},
  open: false,
  setAttribute(k, v) {
    this.attrs[k] = String(v);
    if (k === 'open') this.open = true;
  },
  getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; },
  removeAttribute(k) { delete this.attrs[k]; },
  appendChild(c) { this.children.push(c); return c; },
  append(...cs) { this.children.push(...cs); },
  replaceChildren(...cs) { this.children = cs; },
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); },
  querySelector: () => null,
  getBoundingClientRect: () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 }),
});

globalThis.document = {
  createElementNS: (_ns, tag) => makeNode(tag),
  createTextNode: (text) => ({ tagName: '#text', text, children: [] }),
  // dom.js caches `#tip` at module-eval time and i18n.js stamps `lang` on the
  // root element; both have to answer or the imports below throw.
  querySelector: () => null,
  querySelectorAll: () => [],
  documentElement: makeNode('html'),
};
globalThis.addEventListener = () => {};
globalThis.innerWidth = 1200;
globalThis.innerHeight = 800;

const store = new Map();
globalThis.localStorage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null),
  setItem: (k, v) => store.set(k, String(v)),
  removeItem: (k) => store.delete(k),
};

const { renderSpend } = await import('../dist/spend.js');
const { useFxRate } = await import('../dist/lib/format.js');
const { useLocale, t } = await import('../dist/lib/i18n.js');

useLocale('en');

/* --------------------------------------------------------------- helpers */

const textOf = (node) => {
  if (!node || typeof node !== 'object') return '';
  if (node.tagName === '#text') return node.text;
  return (node.children || []).map(textOf).join(' ');
};

const kids = (node, tag) => (node.children || []).filter((c) => c.tagName === tag);

const classOf = (node) => String((node.attrs && node.attrs.class) || '');

const find = (node, pred) => {
  if (!node || typeof node !== 'object') return null;
  if (pred(node)) return node;
  for (const kid of node.children || []) {
    const hit = find(kid, pred);
    if (hit) return hit;
  }
  return null;
};

/** render returns { card, fold, visible } — `visible` being the text a reader
 *  gets with the fold shut, which is the whole point of the change. */
function render(summary) {
  const root = makeNode('div');
  renderSpend(root, summary);
  const card = root.children[0];
  const fold = find(card, (n) => n.tagName === 'details');
  const visible = (card.children || []).filter((c) => c !== fold).map(textOf).join(' ');
  return { card, fold, visible };
}

/* -------------------------------------------------------------- fixtures */

const NOTE = 'Real spend is subscription invoices plus gateway metering.';

const FX = {
  available: true, rate: 7.1184, base: 'USD', target: 'CNY',
  as_of: '2026-09-19T00:00:00Z', fallback: false, stale: false,
};

const complete = () => ({
  real_spend: {
    currency: 'USD', subscription: 200, gateway: 12.8, vendor_bill: 0,
    total: 212.8, complete: true,
  },
  real_spend_note: NOTE,
  cost: [{ source: 'claude', kind: 'notional', events: 10, cost_usd: 1, unpriced_events: 0 }],
});

const incomplete = () => ({
  real_spend: {
    currency: 'USD', subscription: 200, gateway: 12.8, vendor_bill: 0,
    total: 212.8, complete: false, missing: ['vendor invoices'],
  },
  real_spend_note: NOTE,
  cost: [{ source: 'claude', kind: 'notional', events: 10, cost_usd: 1, unpriced_events: 4 }],
});

test.afterEach(() => { store.clear(); useFxRate(null); });

/* ----------------------------------------------------------------- tests */

test('the default view is the figure and its terms, and no prose', () => {
  useFxRate(FX);
  const { visible } = render(complete());
  assert.match(visible, /What this actually cost/);
  assert.match(visible, /212\.80|1,514/); // the figure, billed or converted
  assert.match(visible, /subscriptions/);  // the terms line
  // None of the explanation reaches the closed card.
  assert.doesNotMatch(visible, /converted for display/);
  assert.doesNotMatch(visible, new RegExp(NOTE.slice(0, 20)));
  assert.doesNotMatch(visible, /no price data/);
});

// The two exceptions. Both say the FIGURE is low rather than explaining it,
// and a low figure presented as exact is the one thing this fold must not do.
test('the incomplete warning stays outside the fold', () => {
  const { card, fold, visible } = render(incomplete());
  assert.ok(fold, 'the explanation fold is missing entirely');
  assert.match(visible, /Incomplete — vendor invoices/);
  assert.equal(find(fold, (n) => /Incomplete/.test(textOf(n)) && n.tagName === 'p'), null,
    'spend.incomplete was folded away — a known-low total would read as exact');
  // ...and it is still styled as a warning where the reader can see it.
  const warn = (card.children || []).find((c) => classOf(c).includes('warn'));
  assert.ok(warn && /Incomplete/.test(textOf(warn)), 'the incomplete line lost its warn styling');
});

test('the ≥ lower-bound mark stays on the figure itself', () => {
  const { card } = render(incomplete());
  const figure = (card.children || []).find((c) => classOf(c) === 'figure');
  assert.ok(figure, 'no .figure on the card');
  assert.match(textOf(figure), /≥/, 'the lower-bound mark left the number it qualifies');
  // And a complete total must NOT carry it.
  const done = render(complete());
  const fig2 = (done.card.children || []).find((c) => classOf(c) === 'figure');
  assert.doesNotMatch(textOf(fig2), /≥/);
});

// A fold is only honest if nothing was dropped on the way in.
test('every folded sentence is still in the DOM, one click away', () => {
  useFxRate(FX);
  const { fold } = render(incomplete());
  const inside = textOf(fold);
  assert.match(inside, /converted for display at 7\.1184 USD\/CNY/); // fx.rateLine
  assert.match(inside, /currency it was billed in/);                 // fx.billedIn
  assert.ok(inside.includes(NOTE), 'the server-side real_spend_note was dropped, not folded');
  assert.match(inside, /4 request\(s\) have no price data/);         // spend.unpriced
});

test('the summary says what is inside, not "details"', () => {
  useFxRate(FX);
  const { fold } = render(complete());
  const summary = kids(fold, 'summary')[0];
  assert.ok(summary, '<details> with no <summary> — the fold has no label at all');
  const label = textOf(summary);
  assert.equal(label, t('spend.working'));
  assert.doesNotMatch(label, /^(details|more|详情|更多)$/i,
    'a summary that says "details" makes opening the fold a guess');
});

// app.js re-renders this card on every 60-second refresh. A fold that forgot
// would shut under a reader mid-sentence.
test('the fold is closed by default and remembers being opened', () => {
  useFxRate(FX);
  const first = render(complete());
  assert.equal(first.fold.open, false, 'the fold ships open, so the card still prints its prose');

  // Opening it is a `toggle` on the real element; replay that, then re-render.
  first.fold.open = true;
  for (const fn of first.fold.listeners.toggle || []) fn();
  assert.equal(render(complete()).fold.open, true, 'the fold forgot it was open across a refresh');
});

// A hub that reaches no fx feed, a summary with no server note and nothing
// unpriced has no working to show: an empty <details> is a door onto a blank
// room, and the reader does not find that out until they open it.
test('no explanation means no fold at all', () => {
  const bare = complete();
  delete bare.real_spend_note;
  bare.cost = [];
  const { fold, visible } = render(bare);
  assert.equal(fold, null, 'an empty fold was rendered');
  assert.match(visible, /subscriptions/);
});

test('a missing real_spend renders an absence, not a fold full of excuses', () => {
  const { card } = render({ real_spend: null, cost: [] });
  const figure = (card.children || []).find((c) => classOf(c) === 'figure');
  assert.equal(textOf(figure), '—');
});
