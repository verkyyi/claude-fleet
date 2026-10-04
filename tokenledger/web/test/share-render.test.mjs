import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// The defect this file exists for (issue #121): share.html built its page as
// one `root.replaceChildren(…)` call with two members written as
// `cond ? el("div", …) : null`. `replaceChildren()` takes `(Node or
// DOMString)…` — a member that is not a Node is STRINGIFIED, not skipped — so
// each falsy branch put a text node reading "null" on the page, immediately
// above the footer. Both holes are shapes /v1/share returns on its ordinary
// path: a hub with no quota reading yet sends `subscriptions: []`, and
// `model_split: []` arrives with it. #73's visual evidence was shot against
// exactly that synthetic data and every screenshot carries the "null".
//
// The guard below is deliberately stronger than "the page has no 'null' on
// it". A DOM that stringifies whatever it is handed is what made a one-word
// omission invisible for as long as it was, so the stub REFUSES a non-Node
// child anywhere in the file — append(), appendChild() and replaceChildren()
// alike. A card added later that reaches for the same `: null` idiom fails
// here rather than shipping the same word to a link someone shared.
//
// Like palette.test.mjs, this runs the page's real implementation lifted out
// of share.html, never a transcription of it. This repo deliberately has no
// npm pipeline (see the Makefile: "a contributor needs only a Go toolchain"),
// so there is no jsdom to reach for; the stub is the whole DOM this page
// touches, in about fifty lines.

const TEXT_NODE = 3, ELEMENT_NODE = 1;

function makeDom() {
  const isNode = (v) => v !== null && typeof v === 'object' && typeof v.nodeType === 'number';
  const adopt = (parent, kids) => kids.map((k) => {
    // The one assertion the real DOM does not make for us.
    assert.ok(isNode(k), `${parent.tagName} was handed a non-Node child: ${JSON.stringify(k)}` +
      ' — the browser would stringify it into a visible text node');
    return k;
  });

  const makeNode = (tag) => ({
    nodeType: ELEMENT_NODE,
    tagName: tag,
    className: '',
    attrs: {},
    children: [],
    style: {},
    textContent: '',
    setAttribute(k, v) { this.attrs[k] = String(v); },
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; },
    append(...kids) { this.children.push(...adopt(this, kids.flat())); },
    appendChild(kid) { this.children.push(...adopt(this, [kid])); return kid; },
    replaceChildren(...kids) { this.children = adopt(this, kids.flat()); },
  });

  const root = makeNode('div');
  const document = {
    querySelector: (sel) => (sel === '#root' ? root : null),
    // HTML elements report an upper-case tagName, SVG ones keep their case —
    // the assertions below read tag names, so the stub matches the browser.
    createElement: (tag) => makeNode(tag.toUpperCase()),
    createElementNS: (_ns, tag) => makeNode(tag),
    createTextNode: (s) => ({ nodeType: TEXT_NODE, textContent: String(s) }),
  };
  return { document, root };
}

// Everything the page renders, flattened, in document order.
function textOf(node) {
  if (node.nodeType === TEXT_NODE) return node.textContent;
  return (node.textContent || '') + node.children.map(textOf).join(' ');
}

const tagsOf = (node) => node.children.map((c) => `${c.tagName || '#text'}.${c.className || ''}`);

function sharePage() {
  const html = readFileSync(new URL('../dist/share.html', import.meta.url), 'utf8');
  const script = html.match(/<script>\n([\s\S]*?)\n<\/script>/);
  assert.ok(script, 'share.html has lost its single inline <script> block');

  const { document, root } = makeDom();
  // The page's tail kicks off its own fetch on load. This stub makes that a
  // no-op so the test drives render() with data of its own choosing — and
  // keeps the .catch() handler, which is the page's OTHER replaceChildren().
  const chain = { onError: null };
  const fetchStub = () => {
    const p = { then: () => p, catch: (fn) => { chain.onError = fn; return p; } };
    return p;
  };
  const render = new Function('document', 'fetch', 'location',
    `${script[1]}\nreturn render;`)(document, fetchStub, { search: '' });
  return { render, root, renderError: (e) => chain.onError(e) };
}

// A hub that has collected transcripts but has no quota reading yet: the exact
// payload /v1/share returns, and the one that printed the word.
const EMPTY = {
  title: 'Acme Engineering · Claude Code',
  generated_at: '2026-09-20T12:00:00Z',
  since_days: 7,
  scale: { subscriptions: 0, machines: 3, logins: 4, projects: 12, sessions: 318 },
  subscriptions: [],
  turns: 12840,
  tokens: 470000000,
  show_costs: false,
  history: [
    { key: '2026-09-13', label: '', events: 0, tokens: 41000000 },
    { key: '2026-09-19', label: '', events: 0, tokens: 95000000 },
  ],
  model_split: [],
  disclaimer: 'Figures are measured from local transcripts.',
};

const FULL = {
  ...EMPTY,
  scale: { ...EMPTY.scale, subscriptions: 2 },
  subscriptions: [
    { name: 'Subscription A', plan: 'Max 20x', five_hour_pct: 41.2, seven_day_pct: 63.8, available: true },
    { name: 'Subscription B', five_hour_pct: 0, seven_day_pct: 0, available: false },
  ],
  model_split: [
    { key: 'claude-opus-4-1', label: '', events: 0, tokens: 300000000 },
    { key: 'claude-sonnet-4-5', label: '', events: 0, tokens: 170000000 },
  ],
};

test('an empty share payload renders no literal "null"', () => {
  const { render, root } = sharePage();
  render(EMPTY);

  // The stub above already refuses a non-Node child, so reaching this line
  // means nothing was stringified. Assert the visible symptom too: this is
  // the string a reader of a shared link saw, and it names the bug.
  const text = textOf(root);
  assert.ok(!/\bnull\b/.test(text), `the page prints a literal "null": ${JSON.stringify(text)}`);
  assert.ok(!/\bundefined\b/.test(text), `the page prints a literal "undefined": ${JSON.stringify(text)}`);

  // And the holes are holes, not blank cards: header, three cards, footer.
  assert.deepEqual(tagsOf(root), ['HEADER.', 'DIV.card', 'DIV.card', 'DIV.card', 'FOOTER.']);
});

test('the optional cards still render when their data arrives', () => {
  // The filter must drop the empty branches and nothing else — a guard that
  // also ate the cards would pass the test above and ship a page with less on
  // it than before.
  const { render, root } = sharePage();
  render(FULL);

  assert.deepEqual(tagsOf(root),
    ['HEADER.', 'DIV.card', 'DIV.card', 'DIV.card', 'DIV.card', 'DIV.card', 'FOOTER.']);

  const text = textOf(root);
  assert.ok(text.includes('Model mix'), 'the model-mix card went missing');
  assert.ok(text.includes('Plan utilization right now'), 'the utilization card went missing');
  assert.ok(text.includes('Subscription A'), 'the subscription rows went missing');
  assert.ok(!/\bnull\b/.test(text), `the populated page prints a literal "null": ${JSON.stringify(text)}`);
});

test('the error path builds its card out of Nodes too', () => {
  // The page's OTHER replaceChildren(). A dead share token is the most common
  // thing a recipient sees, so it is the least forgiving place to print the
  // word — and it has no conditional member today only because nobody has
  // added one. Same stub, same refusal.
  const { renderError, root } = sharePage();
  renderError(new Error('share link expired'));

  const text = textOf(root);
  assert.ok(text.includes('This link is not available'), 'the error card went missing');
  assert.ok(text.includes('share link expired'), 'the error card lost its reason');
  assert.ok(!/\bnull\b|\bundefined\b/.test(text), `the error card prints a literal: ${JSON.stringify(text)}`);
});
