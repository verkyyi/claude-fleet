// web/dist/scope.js — the top nav bar, and the reusable "scope controls"
// widget (subscription select · span segmented control · chips row).
//
// As of the Task 15 nav restructure, these are two SEPARATE things:
//   - renderNav() draws the sticky bar itself — wordmark, section nav,
//     language switch and theme toggle. It holds no scope state; that is the
//     other half of this file.
//   - createScopeControls() builds ONE instance of the scope-controls widget
//     (subscription + optional span + chips). Each view MOUNTS its own
//     instance on its first substantive card — the card whose meaning the
//     scope actually belongs to (Review's Timeline card owns the brush that
//     the span scales; Now's "Am I about to hit the wall?" card is
//     per-subscription by definition) — rather than the widget living in one
//     global location. Now and Review need overlapping-but-different
//     subsets (Now has no time range, so it renders no span control at all),
//     which is exactly what `createScopeControls({ span })` parametrises;
//     everything else (subscription list, chip rendering/removal) is shared,
//     unchanged behaviour, just relocated. Every instance self-registers
//     here so app.js's route() can update all of them from one call
//     (renderScopeControls) without knowing how many views exist or where
//     each one mounted its widget.
//
// OVERTURNED (#54). The bullet above used to end: "There is no longer anything
// to navigate BETWEEN: the page is one surface, so the bar holds neither
// navigation nor scope state." The premise is still true and this change does
// not touch it — the page is one surface, one <main>, one refresh loop, and the
// Now/Review tabs stay retired (web/embed_test.go guards that by name). What
// the sentence got wrong was the inference: "one surface" is a statement about
// STRUCTURE, and it was read as one about SIZE. At 68f5811 the surface is
// 4,459px over ~20 cards with 36% of it behind the operations fold, and on a
// page that long the reader still has to get somewhere — they were just doing
// it by scrolling and guessing. An anchor nav is not a second structure; it is
// the one structure, made addressable. Nothing here fetches, mounts, hides or
// remembers anything: it moves the viewport.
//
// No fetching in this file either way — app.js owns the load loop and calls
// back into whichever handlers were passed at update() time.
import { DIMS } from './lib/state.js';
import { SECTIONS, pickActive } from './lib/nav.js';
import { shortProject } from './lib/format.js';
import { accountGroups, sourceLabel } from './lib/providers.js';
import { el, $ } from './lib/dom.js';
import { t, locale, LOCALES, LOCALE_LABEL, chooseLocale } from './lib/i18n.js';
// `app` is read only inside functions below (never at module-eval time), so
// this is a safe circular import: app.js imports renderNav/renderScopeControls/
// setBusy from here, and by the time any of them is actually CALLED (from
// route(), which only runs after app.js has fully evaluated and boot()'s
// account fetch has resolved), `app`'s exported binding is fully populated.
// This is how a chip for the "machine" dimension resolves its label — this
// module's own state has no room for the endpoint roster that now.js caches
// on `app.endpoints` after every /v1/endpoints fetch.
import { app } from './app.js';

// Restored as early as possible (module-eval time, right after the document
// is parsed) so there is no flash of the wrong theme — copied verbatim from
// the old page's top-level snippet.
try {
  const saved = localStorage.getItem('ccquota-theme');
  if (saved) document.documentElement.setAttribute('data-theme', saved);
} catch {}

/** chipLabel resolves the DISPLAY text for one chip. Everything but
 *  machine/project/session shows its raw filter value. */
function chipLabel(dim, value) {
  if (dim === 'machine') {
    const eps = app.endpoints || [];
    const ep = eps.find((e) => e.endpoint_id === value);
    return ep ? (ep.label || ep.hostname || value) : value;
  }
  if (dim === 'project') return shortProject(value);
  if (dim === 'session') return value.slice(0, 8);
  return value;
}

/* ---------------------------------------------------------------- nav bar */

/** SHORT_LOCALE is what the switch PRINTS. The button is one character wide
 *  next to the theme toggle, so it cannot carry "简体中文" — and what it shows is
 *  the language you would switch TO, written in that language, which is the one
 *  form a reader of either language can act on without knowing the other. */
const SHORT_LOCALE = { en: 'EN', 'zh-CN': '中' };

/** nextLocale is the one the switch moves to. With two languages this is a
 *  toggle; written as a rotation so a third dictionary needs no new code here. */
export const nextLocale = (cur) => LOCALES[(LOCALES.indexOf(cur) + 1) % LOCALES.length];

/* ------------------------------------------------------- the section nav */

/** The nav's buttons, keyed by the element id each one scrolls to. Built once
 *  by buildSecNav and then only ever toggled/marked, so the spy never has to
 *  re-query the DOM on a scroll frame. */
const navButtons = new Map();

/** reduceMotion is asked per interaction rather than cached: the OS setting can
 *  change while the page is open, and a viewer who turns it on mid-session did
 *  so to stop exactly this kind of movement. */
const reduceMotion = () =>
  typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;

/** visible answers "does this target take up space right now", which is not the
 *  same as "does it exist". #repo-band carries the `hidden` attribute on every
 *  hub no shipper pushes repo facts to, and a nav entry pointing at it would
 *  scroll to a zero-height element in the middle of the page. offsetParent is
 *  null for anything display:none — including inside a closed <details>, which
 *  is why #ops itself (never its children) is the operations target. */
const visible = (n) => !!n && !n.hidden && n.offsetParent !== null;

/** navHeight is how much of the viewport the sticky bar covers, measured rather
 *  than assumed: the bar wraps at narrow widths and loses its wordmark under
 *  720px, so a hardcoded offset would be wrong on the half of the page sizes it
 *  was not written against. Published to CSS as --navh so the scroll-margin on
 *  the targets and the spy's line are the same number by construction, never
 *  two constants that drift. The +8 is breathing room: landing a band label
 *  flush against the bar reads as tucked under it. */
function navHeight(root) {
  const h = Math.round(root.getBoundingClientRect().height) + 8;
  document.documentElement.style.setProperty('--navh', h + 'px');
  return h;
}

/** goToSection scrolls to one band. It does NOT write location.hash, and that
 *  is load-bearing rather than fussy: this page's hash is its entire state
 *  (lib/state.js — "the hash is the only copy of the state"), and app.js
 *  re-derives the subscription, span, chips and repo filter from it on every
 *  hashchange. A plain <a href="#spend"> would therefore parse as an unknown
 *  path, reset every one of those to its default, and rewrite the URL back to
 *  `#/` — so the nav would silently throw away the reader's filters as the
 *  price of scrolling. That is also why these are <button>s and not links:
 *  there is no URL here worth copying, and an <a> would promise one. */
function goToSection(id) {
  // The operations tier is a closed <details> for most viewers. Scrolling to a
  // shut fold parks the reader on a single <summary> line and answers nothing,
  // so asking for Operations opens Operations. app.js's toggle listener
  // persists that, which is correct: the viewer asked.
  if (id === 'ops') {
    const d = $('#ops');
    if (d && !d.open) d.open = true;
  }
  const node = document.getElementById(id);
  if (!node) return;
  node.scrollIntoView({ behavior: reduceMotion() ? 'auto' : 'smooth', block: 'start' });
}

/** buildSecNav fills the empty <nav id="secnav"> from SECTIONS. Called once. */
function buildSecNav(root) {
  const nav = $('#secnav', root);
  if (!nav) return;
  nav.setAttribute('aria-label', t('nav.sections'));
  nav.replaceChildren(...SECTIONS.map(({ target, key }) => {
    const b = el('button', { type: 'button', 'data-target': target }, t(key));
    b.addEventListener('click', () => goToSection(target));
    navButtons.set(target, b);
    return b;
  }));
  nav.hidden = false;
}

/** syncNav shows exactly the entries whose target is on the page right now, and
 *  hides the nav entirely if fewer than two survive — a nav offering one
 *  destination is a label pretending to be a control. The only entry that
 *  actually comes and goes is Progress; app.js calls this from load() right
 *  after it decides whether the progress band exists on this hub. */
export function syncNav() {
  const nav = $('#secnav');
  if (!nav) return;
  let shown = 0;
  for (const { target } of SECTIONS) {
    const b = navButtons.get(target);
    if (!b) continue;
    b.hidden = !visible(document.getElementById(target));
    if (!b.hidden) shown++;
  }
  nav.hidden = shown < 2;
  spy();
}

/* ------------------------------------------------------------- scroll spy */

let spyQueued = false;
/** Held for lifetime, not for use — see where it is assigned. */
let pageObserver = null;

/** spy marks the entry the reader is currently under. Reads layout and writes
 *  one attribute per button; the pick itself is lib/nav.js's pickActive, kept
 *  pure so it can be tested without a browser (web/test/nav.test.mjs). */
function spy() {
  spyQueued = false;
  const root = $('#scope');
  const nav = $('#secnav');
  if (!root || !nav || nav.hidden) return;
  const live = SECTIONS
    .map(({ target }) => ({ target, node: document.getElementById(target) }))
    .filter(({ target, node }) => visible(node) && !navButtons.get(target)?.hidden);
  // Within 2px of the end counts as the end: browsers round the document
  // height, and a page that stops 0.5px short would never light the last entry.
  const atBottom = Math.ceil(scrollY + innerHeight) >= document.documentElement.scrollHeight - 2;
  const at = pickActive(live.map(({ node }) => node.getBoundingClientRect().top), navHeight(root), atBottom);
  for (const b of navButtons.values()) b.removeAttribute('aria-current');
  // aria-current, not aria-selected: this says "the section you are looking at",
  // which is a position on one page. aria-selected would say "the view you
  // chose", and this page has exactly one view — see the overturn note up top.
  if (at >= 0) navButtons.get(live[at].target)?.setAttribute('aria-current', 'true');
}

/** queueSpy coalesces a burst of scroll events into one measurement per frame.
 *  Passive, because this listener never prevents a scroll and saying so is what
 *  keeps the scroll off the main thread. */
function queueSpy() {
  if (spyQueued) return;
  spyQueued = true;
  requestAnimationFrame(spy);
}

/** renderNav renders/updates the sticky top bar: wordmark, section nav,
 *  language switch and theme toggle. `root` is the static
 *  `<header id="scope">` from index.html (always present, never recreated), so
 *  listeners are bound exactly once behind a `data-bound` guard the same way
 *  the whole bar used to be before Task 15 split it. */
export function renderNav(root) {
  if (!root.dataset.bound) {
    // Theme toggle: copied verbatim from the old page's click handler.
    $('#theme', root).addEventListener('click', () => {
      const cur = document.documentElement.getAttribute('data-theme');
      const next = cur === 'dark' ? 'light' : cur === 'light' ? 'auto' : 'dark';
      document.documentElement.setAttribute('data-theme', next);
      try { localStorage.setItem('ccquota-theme', next); } catch {}
    });
    // The language switch. It persists and reloads (lib/i18n.js's
    // chooseLocale says why a reload rather than a re-render), so there is
    // nothing to update here afterwards — the fresh page renders in the new
    // language from module-eval time.
    const lang = $('#lang', root);
    if (lang) {
      const next = nextLocale(locale());
      lang.textContent = SHORT_LOCALE[next] || next;
      lang.setAttribute('title', LOCALE_LABEL[next] || next);
      lang.setAttribute('aria-label', LOCALE_LABEL[next] || next);
      lang.addEventListener('click', () => chooseLocale(nextLocale(locale())));
    }
    buildSecNav(root);
    addEventListener('scroll', queueSpy, { passive: true });
    addEventListener('resize', queueSpy);
    // Opening or closing the operations fold moves every band above it by
    // thousands of pixels without the page scrolling, so the spy has to
    // re-measure on a toggle as much as on a scroll.
    $('#ops')?.addEventListener('toggle', queueSpy);
    // ...and so does the page GROWING under a reader who has not scrolled.
    //
    // This is not a hypothetical. Every card on this page arrives from an async
    // fetch, so the first spy runs against a nearly empty <main>: the document
    // is then shorter than the viewport, which is the `atBottom` case, and the
    // bar opens with Operations marked while the reader is looking at the top
    // of the ledger. It stays wrong until the first scroll, because until #54
    // a scroll was the only thing that could ever have changed the answer.
    // A load that lands, the repo band appearing, a card switching to its table
    // view — all of them move every band below them and none of them scrolls.
    // The reference is held rather than dropped on the floor: an observer
    // reachable from nothing is at the mercy of how a given engine reads the
    // spec's collection rules, and the failure mode if one is collected is
    // silent — the nav just stops following, which is the bug above returning.
    if (typeof ResizeObserver === 'function') {
      pageObserver = new ResizeObserver(queueSpy);
      pageObserver.observe($('#page'));
    }
    root.dataset.bound = '1';
  }
  syncNav();
}

export function setBusy(b) {
  const p = $('#progress');
  if (p) p.hidden = !b;
}

/* --------------------------------------------------------- scope controls */

// Every instance created by createScopeControls, so renderScopeControls can
// update all of them without the caller (app.js) needing to know which views
// exist or import each view's own mount point.
const instances = [];

/** createScopeControls builds one instance of the scope widget: a
 *  subscription <select>, an OPTIONAL span segmented control, and a chips
 *  row with per-chip remove + "Clear all". Unlike the old single sticky-bar
 *  render, this element is built ONCE (by whichever view calls this at its
 *  own module-eval time, e.g. now.js's `const nowScope =
 *  createScopeControls({ span: false })`) and is a plain, freestanding DOM
 *  node from then on — the caller embeds `instance.el` into its card same as
 *  now.js already does for its persistent heroWrapEl/liveWrapEl, and just
 *  re-appends the same reference on every rebuild. Because construction and
 *  event binding happen exactly once, in this closure, there is no
 *  `data-bound` guard to forget here (unlike renderNav's root, which is
 *  handed a pre-existing static element it does not own). */
export function createScopeControls({ span = true } = {}) {
  let handlers = {};

  const sel = el('select', { 'aria-label': t('scope.subscription') });
  sel.addEventListener('change', (e) => handlers.onSub && handlers.onSub(e.target.value));

  const sourceSel = el('select', { 'aria-label': t('scope.source') });
  if (sourceSel) sourceSel.addEventListener('change', (e) => handlers.onSource && handlers.onSource(e.target.value));

  const spanSeg = span
    ? el('div', { class: 'seg', role: 'group', 'aria-label': t('scope.span') },
        ['7d', '30d', '90d'].map((v) => el('button', { type: 'button', 'data-span': v }, v)))
    : null;
  if (spanSeg) {
    for (const btn of spanSeg.querySelectorAll('button')) {
      btn.addEventListener('click', () => handlers.onSpan && handlers.onSpan(btn.dataset.span));
    }
  }

  const chipsRow = el('div', { class: 'chips-row', hidden: true });

  const filters = el('div', { class: 'filters' }, sel, sourceSel, spanSeg);
  const root = el('div', { class: 'scope-controls' }, filters, chipsRow);

  function update(state, accounts, cb) {
    handlers = cb || {};

    const relevant = accounts.filter((a) => !state.chips.source || (a.source || 'claude') === state.chips.source);
    // Grouped, not prefixed. The old `Claude · ` / `Codex · ` prefix asserted
    // a two-source world and, worse, said "account" meant one thing when it
    // means two: a subscription somebody pays for monthly, or one calling
    // application on the gateway. The optgroup heading carries that now.
    const groups = accountGroups(relevant).map((g) =>
      el('optgroup', { label: g.label },
        ...g.options.map((o) => el('option', { value: o.value }, o.text))));
    sel.replaceChildren(
      el('option', { value: 'all' }, t('scope.allAccounts', { n: relevant.length })),
      ...groups);
    sel.style.display = relevant.length ? '' : 'none';
    sel.value = state.sub;

    if (sourceSel) {
      const sources = [...new Set(accounts.map((a) => a.source || 'claude'))];
      if (state.chips.source && !sources.includes(state.chips.source)) sources.push(state.chips.source);
      sourceSel.replaceChildren(el('option', { value: '' }, t('scope.allSources')),
        ...sources.map((source) => el('option', { value: source }, sourceLabel(source))));
      sourceSel.value = state.chips.source || '';
    }

    if (spanSeg) {
      for (const btn of spanSeg.querySelectorAll('button')) {
        btn.setAttribute('aria-pressed', String(btn.dataset.span === state.span));
      }
    }

    const dims = DIMS.filter((d) => state.chips[d]);
    if (!dims.length) {
      chipsRow.hidden = true;
      chipsRow.replaceChildren();
      return;
    }
    chipsRow.hidden = false;
    // The chip names its DIMENSION in the viewer's language, but its VALUE
    // verbatim: a project path, a model id and an endpoint name are what the
    // filter actually matches on, and translating one would make the chip
    // disagree with the URL it stands for.
    const chips = dims.map((d) => el('span', { class: 'chip' },
      t('dim.' + d) + ': ',
      el('b', {}, chipLabel(d, state.chips[d])),
      el('button', { type: 'button', 'aria-label': t('scope.removeChip', { dim: t('dim.' + d) }), onclick: () => handlers.onChipRemove && handlers.onChipRemove(d) }, '×')));
    chips.push(el('span', { class: 'chip clear' },
      el('button', { type: 'button', onclick: () => handlers.onClear && handlers.onClear() }, t('scope.clearAll'))));
    chipsRow.replaceChildren(...chips);
  }

  const instance = { el: root, update };
  instances.push(instance);
  return instance;
}

/** renderScopeControls updates EVERY scope-controls instance that has been
 *  created (Now's and Review's, however many that ends up being) from the
 *  current state. Called synchronously from app.js's route() on every
 *  hashchange — same timing the old single renderScope() had — so a
 *  subscription/span/chip change is reflected immediately, without waiting
 *  for that view's async load() cycle to finish. The instance whose view is
 *  hidden right now still gets updated; that just keeps it correct for when
 *  the user switches tabs, and is cheap (a handful of DOM writes). */
export function renderScopeControls(state, accounts, cb) {
  for (const inst of instances) inst.update(state, accounts, cb);
}
