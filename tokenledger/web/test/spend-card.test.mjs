import test from 'node:test';
import assert from 'node:assert/strict';

// The defect this file exists for (issue #94): the card whose entire job was to
// show ONE number was printing up to eight sentences around it — three of fx
// disclosure, three from the server, plus the incomplete and unpriced caveats.
// The fix is a fold, and a fold is exactly the kind of change that quietly
// becomes a DELETION later: a sentence dropped on the way into the <details>
// looks identical to a sentence that was never there, because nobody re-opens
// a closed fold to count what is inside it.
//
// #128 moved the figure into the sticky bar and stopped rendering the card at
// all, which does not retire that risk — it doubles it. There are two folds
// between the reader and those sentences now (the chip's panel, and the
// working fold inside it), and the card that used to show the terms in the
// open is gone. So this file pins the SPLIT, not the layout, against the new
// shape. Four properties:
//   1. the shut chip is the period label and the figure, and no prose;
//   2. what says "this number is LOW" — the `≥` and the fact of being
//      incomplete — is never only inside a fold, because folding a knowingly
//      biased figure shows it as if it were exact;
//   3. every sentence that used to be on the card is still in the DOM;
//   4. #spend draws nothing on the happy path, and the failed query — the one
//      thing a figure cannot state — still reaches the reader as a card.
//
// web/dist has no npm pipeline (see the Makefile: "a contributor needs only a
// Go toolchain"), so there is no jsdom. The stub below is the whole DOM that
// `el` and this chip touch, in the same shape charts-aria.test.mjs uses.

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

const { renderLedgerChip, renderSpend } = await import('../dist/spend.js');
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

/** render returns { chip, panel, shut } — `shut` being the text a reader gets
 *  with nothing opened, which is the whole point of the change. */
function render(summary, state = { span: '30d' }) {
  const root = makeNode('div');
  renderLedgerChip(root, summary, state);
  const chip = root.children[0];
  if (!chip) return { chip: null, panel: null, shut: '' };
  const head = kids(chip, 'summary')[0];
  const panel = (chip.children || []).find((c) => classOf(c) === 'ledger-panel');
  return { chip, head, panel, shut: textOf(head) };
}

/** fulfilled/rejected wrap a value the way seq.js hands one to app.js. */
const fulfilled = (value) => ({ status: 'fulfilled', value });
const rejected = (reason) => ({ status: 'rejected', reason });

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

test('the shut chip says which period, and prints the figure and no prose', () => {
  useFxRate(FX);
  const { shut, head } = render(complete());
  assert.match(shut, /spent/);                 // the verb
  // The PERIOD is its own node, and that is load-bearing rather than tidy:
  // styles.css drops the verb on a phone and keeps this, so a figure that
  // would otherwise read as a lifetime bill still says which window it covers.
  const per = (head.children || []).find((c) => classOf(c) === 'per');
  assert.ok(per, 'the chip has no period node — a phone would print a bare figure');
  assert.equal(textOf(per), '30d');
  assert.match(shut, /212\.80|1,514/);        // the figure, billed or converted
  // None of the explanation reaches the shut chip.
  assert.doesNotMatch(shut, /converted for display/);
  assert.doesNotMatch(shut, new RegExp(NOTE.slice(0, 20)));
  assert.doesNotMatch(shut, /no price data/);
  assert.doesNotMatch(shut, /subscriptions/);  // the terms are in the panel now
});

// A brushed range sets from/to and leaves `span` at whatever it was, so naming
// the days would name a window the figure no longer covers.
test('a custom range is not reported as the span the control still shows', () => {
  const { head } = render(complete(), { span: '30d', from: '2026-09-01', to: '2026-09-07' });
  const per = (head.children || []).find((c) => classOf(c) === 'per');
  assert.equal(textOf(per), 'this range');
  assert.doesNotMatch(textOf(head), /30d/);
});

// The two exceptions. Both say the FIGURE is low rather than explaining it, and
// a low figure presented as exact is the one thing these folds must not do.
test('the ≥ lower-bound mark stays on the figure itself', () => {
  const { head } = render(incomplete());
  const fig = (head.children || []).find((c) => classOf(c) === 'n');
  assert.ok(fig, 'no figure on the chip');
  assert.match(textOf(fig), /≥/, 'the lower-bound mark left the number it qualifies');
  // And a complete total must NOT carry it.
  const done = render(complete());
  const fig2 = (done.head.children || []).find((c) => classOf(c) === 'n');
  assert.doesNotMatch(textOf(fig2), /≥/);
});

test('being incomplete is said on the shut chip, not only inside the panel', () => {
  const { shut, panel } = render(incomplete());
  assert.match(shut, /incomplete/i,
    'the chip shows a total that is knowingly low without saying so');
  // ...and the full sentence, which is too long for a sticky bar, is in the
  // panel — but NOT inside the working fold, where it would be one more click
  // away than the thing it warns about.
  const working = find(panel, (n) => n.tagName === 'details');
  assert.match(textOf(panel), /Incomplete — vendor invoices/);
  assert.equal(find(working, (n) => /Incomplete/.test(textOf(n)) && n.tagName === 'p'), null,
    'spend.incomplete was folded into the working — a known-low total would read as exact');
  // ...and it is still styled as a warning wherever it is shown.
  const warn = (panel.children || []).find((c) => classOf(c).includes('warn'));
  assert.ok(warn && /Incomplete/.test(textOf(warn)), 'the incomplete line lost its warn styling');
  const word = (render(incomplete()).head.children || []).find((c) => classOf(c) === 'w');
  assert.ok(word, 'the warning is carried by colour alone on the chip');
});

// A fold is only honest if nothing was dropped on the way in.
test('every folded sentence is still in the DOM, one click away', () => {
  useFxRate(FX);
  const { panel } = render(incomplete());
  const inside = textOf(panel);
  assert.match(inside, /subscriptions/);                             // the terms line
  assert.match(inside, /converted for display at 7\.1184 USD\/CNY/); // fx.rateLine
  assert.match(inside, /currency it was billed in/);                 // fx.billedIn
  assert.ok(inside.includes(NOTE), 'the server-side real_spend_note was dropped, not folded');
  assert.match(inside, /4 request\(s\) have no price data/);         // spend.unpriced
});

test('the summary says what is inside, not "details"', () => {
  useFxRate(FX);
  const { panel } = render(complete());
  const fold = find(panel, (n) => n.tagName === 'details');
  const summary = kids(fold, 'summary')[0];
  assert.ok(summary, '<details> with no <summary> — the fold has no label at all');
  const label = textOf(summary);
  assert.equal(label, t('spend.working'));
  assert.doesNotMatch(label, /^(details|more|详情|更多)$/i,
    'a summary that says "details" makes opening the fold a guess');
});

// app.js re-renders this chip on every 60-second refresh. A fold that forgot
// would shut under a reader mid-sentence.
test('the working fold is closed by default and remembers being opened', () => {
  useFxRate(FX);
  const first = find(render(complete()).panel, (n) => n.tagName === 'details');
  assert.equal(first.open, false, 'the fold ships open, so the chip still prints its prose');

  // Opening it is a `toggle` on the real element; replay that, then re-render.
  first.open = true;
  for (const fn of first.listeners.toggle || []) fn();
  const again = find(render(complete()).panel, (n) => n.tagName === 'details');
  assert.equal(again.open, true, 'the fold forgot it was open across a refresh');
});

// Both folds hang from the same corner of the bar, so the platform has to keep
// them exclusive — and the working fold inside must NOT join the group, or
// opening it would shut the chip that contains it.
test('the chip is in the bar accordion and the working fold is not', () => {
  useFxRate(FX);
  const { chip, panel } = render(complete());
  assert.equal(chip.getAttribute('name'), 'barfold');
  assert.equal(find(panel, (n) => n.tagName === 'details').getAttribute('name'), null);
});

// A hub that reaches no fx feed, a summary with no server note and nothing
// unpriced has no working to show: an empty <details> is a door onto a blank
// room, and the reader does not find that out until they open it.
test('no explanation means no fold at all', () => {
  const bare = complete();
  delete bare.real_spend_note;
  bare.cost = [];
  const { panel } = render(bare);
  assert.equal(find(panel, (n) => n.tagName === 'details'), null, 'an empty fold was rendered');
  assert.match(textOf(panel), /subscriptions/);
});

test('a missing real_spend renders an absence, not a chip full of excuses', () => {
  const { head } = render({ real_spend: null, cost: [] });
  const fig = (head.children || []).find((c) => classOf(c) === 'n');
  assert.equal(textOf(fig), '—');
});

/* ------------------------------------------------- #spend, the slot in <main>
   The figure is in the bar; what is left in the band is the one case a figure
   cannot carry. Both halves are load-bearing: drawing on the happy path would
   put the card back, and drawing nothing on a failure would let an absent chip
   report a deployment that spent nothing. */

test('#spend draws nothing on the happy path — the card is gone', () => {
  const root = makeNode('div');
  renderSpend(root, fulfilled(complete()));
  assert.deepEqual(root.children, [], 'the ledger card is back in the default view');
});

test('#spend draws nothing for a request that was never sent', () => {
  const root = makeNode('div');
  renderSpend(root, { status: 'skipped' });
  assert.deepEqual(root.children, [],
    'a band nobody asked for reported a failure that never happened');
  renderSpend(root, undefined);
  assert.deepEqual(root.children, []);
});

test('#spend reports a failed summary — a chip has no honest figure for it', () => {
  const root = makeNode('div');
  renderSpend(root, rejected(new Error('502 Bad Gateway')));
  const card = root.children[0];
  assert.ok(card, 'a /v1/summary that failed reached the reader as silence');
  assert.match(textOf(card), /502 Bad Gateway/);
  assert.match(textOf(card), new RegExp(t('spend.title')));
});

// The chip is the other half of that pair: with no summary at all it renders
// NOTHING rather than a reassuring dash, because the card above is saying why.
test('the chip is absent when the query failed, not showing a dash', () => {
  const root = makeNode('div');
  renderLedgerChip(root, null, { span: '30d' });
  assert.deepEqual(root.children, []);
});
