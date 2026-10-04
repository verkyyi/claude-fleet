// web/dist/scope.js — the top nav bar, and the reusable "scope controls"
// widget (subscription select · span segmented control · chips row).
//
// As of the Task 15 nav restructure, these are two SEPARATE things:
//   - renderNav() draws the sticky bar itself — wordmark, view nav,
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
// OVERTURNED TWICE, and #98 is the second time — the history is in
// web/dist/lib/nav.js's header, which is the one place it is told in full.
// The short version for this file: #54 said of the nav it had just added
// "Nothing here fetches, mounts, hides or remembers anything: it moves the
// viewport." Every clause of that is now false except the first. The bar's
// entries write `view` into the hash (#97), and app.js mounts one band and
// unmounts the rest from it (#98), which is what finally makes the highlight
// honest: the current view IS the current entry, so the scroll-spy that used
// to measure band positions on every frame is gone. What did NOT change is the
// first clause — no fetching in this file. app.js owns the load loop and calls
// back into whichever handlers were passed at update() time.
import { DIMS, accountsInScope, VIEW_ALL } from './lib/state.js';
import { SECTIONS, VIEW_QUOTA, VIEW_DEFAULT } from './lib/nav.js';
import { shortProject } from './lib/format.js';
import { accountGroups, quotaWindowAccounts, sourceLabel } from './lib/providers.js';
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

/* ---------------------------------------------------------- the view nav */

/** NAV_ENTRIES is what the bar prints, and it is SECTIONS with TWO entries in
 *  front of it: the way back to where the page starts, and the way to the whole
 *  page. Neither is a band and index.html has no element for either, which is
 *  why they are added here rather than in nav.js's table.
 *
 *  `nav.all` earns its place twice over. Without it a reader who pressed "Usage"
 *  has no way back to `view=all` short of editing the URL, because no band entry
 *  writes it — the page would be a one-way door. And with it there is ALWAYS
 *  exactly one current entry, so the bar can say where the reader is instead of
 *  going blank whenever they are looking at everything.
 *
 *  `nav.overview` is #130's half of the same argument, and it exists because
 *  that second property is the one that would otherwise have broken. Once the
 *  default stopped being `all`, a bare URL was a view no entry in this list
 *  named: the bar would have opened with NOTHING marked on the one page every
 *  shared link lands on, and the two-band page would have been the one that was
 *  a one-way door — reachable only by deleting the query from the URL by hand.
 *
 *  It goes FIRST, ahead of "All", which is a change to the bar #130 makes
 *  deliberately. The entries then read left to right as the page reads: where
 *  you land, then everything, then each band on its own. Putting it second
 *  would have made the leftmost entry a place the reader has never been.
 *
 *  The alternative considered was making each band entry a toggle (press the
 *  current one again to go back). Rejected: an affordance nobody can see is not
 *  an affordance, and it would leave `view=all` with nothing marked. */
const NAV_ENTRIES = [
  { key: 'nav.overview', view: VIEW_DEFAULT },
  { key: 'nav.all', view: VIEW_ALL },
  ...SECTIONS,
];

/** The nav's buttons, keyed by the view each one writes. Built once by
 *  buildSecNav and then only ever hidden/marked. */
const navButtons = new Map();

/** navHeight is how much of the viewport the sticky bar covers, measured rather
 *  than assumed: the bar wraps at narrow widths and loses its wordmark under
 *  720px, so a hardcoded offset would be wrong on the half of the page sizes it
 *  was not written against. Published to CSS as --navh.
 *
 *  #98 deleted the scroll-spy, which was one of this number's two readers, and
 *  deliberately KEPT the number: styles.css sets `scroll-margin-top: var(--navh)`
 *  on every card and band so anything the page scrolls to — the session overlay
 *  closing back onto its row, a browser restoring a scroll position — stops
 *  short of the sticky bar instead of under it, and ⟨C5⟩'s badge is measured
 *  against the same bar. The +8 is breathing room: landing a band label flush
 *  against the bar reads as tucked under it.
 *
 *  #96 put the lifetime token badge IN that bar, which is the first thing to
 *  live there whose first frame lands about one round trip after the page does
 *  (now.js's startLive). It is sized to fit inside the row's existing height so
 *  it does not move this number at all (styles.css's `.scope #pulse` carries the
 *  measurements) — the observer below is its backstop, not its mechanism. Worth
 *  saying because it cuts the other way too: whatever else goes in this bar, the
 *  cheap answer is to make it fit, not to let it resize and re-publish. */
function navHeight(root) {
  document.documentElement.style.setProperty(
    '--navh', Math.round(root.getBoundingClientRect().height) + 8 + 'px');
}

/** Held for lifetime, not for use — see where it is assigned in renderNav. */
let barObserver = null;

/** onView is how the nav writes the view — app.js's setState, handed over on
 *  every renderNav rather than captured when the buttons were built.
 *
 *  That distinction is the whole of it. buildSecNav runs exactly ONCE, behind
 *  renderNav's `data-bound` guard, so a handler baked into the click listener
 *  would hold app.js's FIRST route's state forever and spread that state's
 *  span, chips and subscription back over whatever the reader had set since.
 *  Re-pointing this on every route is what makes "switch view" a change of one
 *  key rather than a rewind of the other twelve. */
let onView = null;

/** selectView writes one key — the view — and nothing else happens here.
 *
 *  It writes location.hash through app.setState, with the rest of the state
 *  carried over, and that OVERTURNS what #54 said: "It does NOT write
 *  location.hash, and that is load-bearing." The hazard that comment named is
 *  real and has not gone anywhere: this page's hash is its entire state
 *  (lib/state.js — "the hash is the only copy of the state"), and a plain
 *  <a href="#spend"> still parses as an unknown path, resets the subscription,
 *  span, chips and repo filter to their defaults, and rewrites the URL back to
 *  `#/`. What changed is that there is now a key worth writing (#97): `view` is
 *  a member of the state like any other, so setState spreads the current state
 *  and moves that one key, and the reader's filters survive the switch by
 *  construction.
 *
 *  These stay <button>s and not links for a reason that also survived: a real
 *  <a href> would have to be rebuilt with the whole current scope on every
 *  state change, or it would promise the one thing above — a URL that resets
 *  what the reader set. A button asks app.js what the state is at the moment it
 *  is pressed.
 *
 *  #54's `goToSection` also SCROLLED, and said so was temporary: until a view
 *  unmounted anything, a button that only wrote the hash would look broken —
 *  same page, nothing moved. #98 mounts, so the scroll is gone, and with it the
 *  prefers-reduced-motion check that existed only to soften it. What the reader
 *  sees now is the page becoming the band they asked for, at the top, which is
 *  where a new page starts. The forced-open handling for the operations fold
 *  moved to app.js's mountView, beside the rest of the mounting. */
const selectView = (view) => onView?.(view);

/** buildSecNav fills the empty <nav id="secnav"> from NAV_ENTRIES. Called
 *  once. */
function buildSecNav(root) {
  const nav = $('#secnav', root);
  if (!nav) return;
  nav.setAttribute('aria-label', t('nav.sections'));
  nav.replaceChildren(...NAV_ENTRIES.map(({ key, view }) => {
    const b = el('button', { type: 'button', 'data-view': view }, t(key));
    b.addEventListener('click', () => selectView(view));
    navButtons.set(view, b);
    return b;
  }));
  nav.hidden = false;
}

/** syncNav marks the entry for the view the page is CURRENTLY SHOWING, and
 *  hides the one entry that does not exist everywhere.
 *
 *  Both halves used to be one question — "is this entry's target visible right
 *  now" — answered by measuring the DOM, because with every band always mounted
 *  the only thing that could remove a destination was the `hidden` on
 *  #repo-band. #98 unmounts bands, so that measurement now answers "is this the
 *  view you are on", which would leave the bar with a single entry and no way
 *  off it. They are two questions and this takes two arguments:
 *
 *    `view`     what to mark. The current view IS the current entry, so there
 *               is nothing to measure and nothing to re-measure on scroll.
 *    `progress` whether this hub has a progress band at all. Remembered between
 *               calls because renderNav calls this on every route while only
 *               app.js's loadRepoTier knows the answer, and it learns it late:
 *               /v1/repos is deliberately off the critical path, so the first
 *               route runs with an empty repo list on every hub.
 *
 *  aria-current, not aria-selected: `aria-selected` is only valid on a handful
 *  of roles (tab, option, row…), and giving these buttons role="tab" would mean
 *  a tablist — aria-controls, roving tabindex, arrow-key navigation — which is
 *  the retired Now/Review tabs coming back wearing ARIA. `aria-current="true"`
 *  is the generic "the current item in a set of related items", it is valid on
 *  a plain button in a <nav>, and it is what styles.css already draws. This is
 *  the line #54 flagged for #98 to revisit; revisited, and it stays, for a
 *  reason #54 did not have: the answer moved from scroll position to state, but
 *  the attribute that states it was right all along.
 *
 *  The bar itself is no longer hidden from here. #54 hid it when fewer than two
 *  entries survived, because a nav offering one destination is a label
 *  pretending to be a control — and on a hub with no repo band that check could
 *  genuinely bite. It cannot any more: Overview, All, Quota, Ledger, Usage and
 *  Operations are on every hub, so the count never drops below six, and
 *  buildSecNav's one unhide is the last word. */
let hasProgress = false;
export function syncNav(view, progress) {
  if (progress !== undefined) hasProgress = progress;
  if (!$('#secnav')) return;
  for (const [v, b] of navButtons) {
    b.hidden = v === 'progress' && !hasProgress;
    if (b.hidden || v !== view) b.removeAttribute('aria-current');
    else b.setAttribute('aria-current', 'true');
  }
}

/** renderNav renders/updates the sticky top bar: wordmark, view nav, language
 *  switch and theme toggle. `root` is the static `<header id="scope">` from
 *  index.html (always present, never recreated), so listeners are bound exactly
 *  once behind a `data-bound` guard the same way the whole bar used to be
 *  before Task 15 split it.
 *
 *  `cb.onView` is the one handler the bar takes, and it takes it on EVERY call
 *  precisely because the listeners are bound once — see onView above. `cb.view`
 *  is what to mark, and comes from the same route() call. */
export function renderNav(root, { onView: onViewCb, view } = {}) {
  onView = onViewCb || null;
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
    // The four listeners that used to be bound here — scroll, resize, the
    // operations fold's toggle, and a ResizeObserver on #page — were all the
    // scroll-spy's, and all four are gone with it. Every one of them existed
    // because the answer to "which entry is current" could change without the
    // reader doing anything: a load landing, the repo band appearing, a card
    // switching to its table view. The answer is now `state.view`, which
    // changes only when the reader presses something, so there is nothing to
    // watch.
    //
    // What IS still watched is the bar's own height, and only that. --navh
    // feeds styles.css's scroll-margin (see navHeight), and the bar genuinely
    // does resize on its own: it wraps at narrow widths, loses its wordmark
    // under 720px, and gains or loses the Progress entry when /v1/repos lands.
    // Observing the bar rather than the page is the narrow version of what the
    // spy's observer did — one element that changes rarely, instead of the
    // whole document changing on every fetch. The reference is held rather than
    // dropped on the floor: an observer reachable from nothing is at the mercy
    // of how a given engine reads the spec's collection rules, and the failure
    // mode if one is collected is silent.
    if (typeof ResizeObserver === 'function') {
      barObserver = new ResizeObserver(() => navHeight(root));
      barObserver.observe(root);
    }
    root.dataset.bound = '1';
  }
  syncNav(view);
  navHeight(root);
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

/** allLabelKey picks which "all" the picker is offering, because on the quota
 *  view it is no longer the same set.
 *
 *  The page-wide label names both halves of what this list holds — accounts and
 *  metered usage pools — and that is exactly right everywhere the list holds
 *  both. The quota view's does not offer the pools at all (#126), so keeping
 *  the "/ usage pools" half would leave a category heading over nothing, which
 *  is the same defect as the count it sits next to. Both keys take `{n}` and
 *  only `{n}`, so web/test/i18n.test.mjs's placeholder check covers the new one
 *  on the same terms as the old. */
const allLabelKey = (state) =>
  (state.view === VIEW_QUOTA ? 'scope.allQuotaAccounts' : 'scope.allAccounts');

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

    const relevant = accountsInScope(accounts, state);
    // On the quota view, and ONLY there, the picker drops the accounts that
    // cannot have a quota reading at all (#126). This widget is the PAGE's, not
    // a band's — #95 moved it out of the quota card precisely so every view
    // would have one — so the narrowing has to be per-view rather than per
    // instance: the ledger and usage bands are about money and calls, where a
    // gateway caller is half the answer, and filtering them would delete the
    // reader's only way to reach it. The quota band is the one place a caller
    // billed per call is an option that leads nowhere: the card already splits
    // it out of its own rows (providers.js's quotaAccounts), so until now the
    // picker above it offered twelve choices the card below would answer with
    // "no window". Keyed on VIEW_QUOTA and nothing else, which is why C8's
    // coming multi-band default (#130) leaves this alone.
    const pickable = state.view === VIEW_QUOTA ? quotaWindowAccounts(relevant, state.sub) : relevant;
    // Grouped, not prefixed. The old `Claude · ` / `Codex · ` prefix asserted
    // a two-source world and, worse, said "account" meant one thing when it
    // means two: a subscription somebody pays for monthly, or one calling
    // application on the gateway. The optgroup heading carries that now.
    const groups = accountGroups(pickable).map((g) =>
      el('optgroup', { label: g.label },
        ...g.options.map((o) => el('option', { value: o.value }, o.text))));
    // No "all" when there is exactly one in scope: route() resolves that state
    // to the one account (state.js's resolveSub, #92), so the option would be a
    // control reporting a choice the router undoes on the very next tick. One
    // subscription is not a set to aggregate, and a picker over a set of one is
    // not a picker.
    //
    // `relevant`, not `pickable`, and that is load-bearing: resolveSub reads
    // accountsInScope, so it is the UNNARROWED set that decides whether the
    // router will overwrite 'all'. Keying this on the narrowed one would, on a
    // hub with one subscription and a dozen gateway callers, drop the 'all'
    // option while the router kept the state on 'all' — a <select> whose value
    // matches no option, which renders blank.
    //
    // The COUNT is the narrowed one, because the count names what this list
    // offers. Reading it off `relevant` while the options came from `pickable`
    // is the specific lie #126 was filed about: "all 16" over five rows.
    sel.replaceChildren(
      ...(relevant.length === 1 ? [] : [el('option', { value: 'all' }, t(allLabelKey(state), { n: pickable.length }))]),
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
