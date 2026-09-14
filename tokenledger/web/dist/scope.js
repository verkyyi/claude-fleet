// web/dist/scope.js — the top nav bar, and the reusable "scope controls"
// widget (subscription select · span segmented control · chips row).
//
// As of the Task 15 nav restructure, these are two SEPARATE things:
//   - renderNav() draws the sticky bar itself — wordmark and theme toggle.
//     Nothing else. There is no longer anything to navigate BETWEEN: the page
//     is one surface, so the bar holds neither navigation nor scope state.
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
// No fetching in this file either way — app.js owns the load loop and calls
// back into whichever handlers were passed at update() time.
import { DIMS } from './lib/state.js';
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

/** renderNav renders/updates the sticky top bar: wordmark, language switch and
 *  theme toggle — nothing else. The view tabs are gone with the view: the page is one
 *  continuous surface. `root` is the static `<header id="scope">` from
 *  index.html (always present, never recreated), so listeners are bound
 *  exactly once behind a `data-bound` guard the same way the whole bar used
 *  to be before Task 15 split it. */
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
    root.dataset.bound = '1';
  }
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
