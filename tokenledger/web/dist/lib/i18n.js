// web/dist/lib/i18n.js — this page in two languages.
//
// One dictionary per locale, English as the fallback for every key a locale
// has not translated: a missing key renders the English sentence, never a raw
// `spend.title` in the middle of a card. That is the whole failure mode worth
// designing against — a half-translated page should read as English in places,
// not as a key dump.
//
// Three things are deliberately NOT translated:
//
//   - `price_basis`, and the rest of an event's stored details. That string is
//     written at INGEST time and records which rate actually priced the event.
//     It is an audit record, not a label: a historical event must keep the
//     basis it was priced under, and rewriting it per viewer would be editing
//     the ledger to match who is looking at it.
//   - identifiers: model ids, account uuids, endpoint names, source keys.
//     `gateway` is what the API calls it and what an operator greps for.
//   - the product name. TokenLedger is TokenLedger.
//
// Server prose (RealSpendNote and friends) IS translated, but not here: every
// request carries ?locale=, so those notes arrive already in the viewer's
// language. See internal/i18n on the Go side.
import { en } from './i18n/en.js';
import { zhCN } from './i18n/zh-CN.js';

export const FALLBACK = 'en';
export const LOCALES = ['en', 'zh-CN'];
export const LOCALE_LABEL = { en: 'English', 'zh-CN': '简体中文' };
export const DICTS = { en, 'zh-CN': zhCN };
export const STORAGE_KEY = 'ccquota-locale';

/** pickLocale resolves the locale to use from a stored choice and the
 *  browser's language list, in that order of authority. Pure, so the choice
 *  rule is testable without a browser.
 *
 *  A stored choice always wins — it is the viewer saying so explicitly. Failing
 *  that, an exact tag match, then a primary-subtag match: `zh-TW` and `zh-HK`
 *  resolve to `zh-CN` on purpose. This build ships no Traditional dictionary,
 *  and Simplified is far closer to what that reader wants than English is. */
export function pickLocale(stored, languages) {
  if (stored && LOCALES.includes(stored)) return stored;
  for (const tag of languages || []) {
    if (!tag) continue;
    if (LOCALES.includes(tag)) return tag;
    const primary = String(tag).toLowerCase().split('-')[0];
    const hit = LOCALES.find((l) => l.toLowerCase().split('-')[0] === primary);
    if (hit) return hit;
  }
  return FALLBACK;
}

/** interpolate fills `{name}` placeholders. An unknown placeholder is left
 *  STANDING rather than replaced with "undefined": a typo in a key's variable
 *  name should look like a bug, not like missing data. */
export function interpolate(template, vars) {
  if (!vars) return template;
  return String(template).replace(/\{(\w+)\}/g, (whole, name) =>
    (Object.prototype.hasOwnProperty.call(vars, name) ? String(vars[name]) : whole));
}

/** lookup is the pure half of t(): dictionary → English → the key itself. */
export function lookup(loc, key) {
  const dict = DICTS[loc] || DICTS[FALLBACK];
  const raw = dict[key];
  if (raw != null) return raw;
  const fb = DICTS[FALLBACK][key];
  return fb != null ? fb : key;
}

// The live locale. Resolved once, at module-eval time, and changed only by
// chooseLocale below (which reloads the page — see there for why).
//
// Auto-detection is guarded on `document` rather than on `navigator`: under
// `node --test` the pure lib modules get imported with no DOM, and a test
// machine whose navigator.language happens to be Chinese must not quietly
// change what fold.js's sentence() or cost.js's costLine() return. No
// document, no detection: node always gets English.
let current = FALLBACK;
if (typeof document !== 'undefined') {
  let stored = null;
  try { stored = localStorage.getItem(STORAGE_KEY); } catch {}
  const langs = (typeof navigator !== 'undefined' && (navigator.languages || [navigator.language])) || [];
  current = pickLocale(stored, langs);
  document.documentElement.setAttribute('lang', current);
}

export const locale = () => current;

/** LOCALE_CURRENCY is the currency a viewer of each locale reads money in.
 *
 *  A reader's language is a decent proxy for the currency they think in, and it
 *  is the only signal this page has. It decides DISPLAY only — what was
 *  actually billed is a property of the charge, not of who is looking at it. */
export const LOCALE_CURRENCY = { en: 'USD', 'zh-CN': 'CNY' };

/** displayCurrency is the currency this viewer's figures are rendered in. */
export const displayCurrency = () => LOCALE_CURRENCY[current] || 'USD';

/** useLocale sets the in-memory locale without persisting or reloading. For
 *  tests, and for anything that needs to render one string in a locale that is
 *  not the viewer's. */
export function useLocale(loc) {
  current = LOCALES.includes(loc) ? loc : FALLBACK;
  if (typeof document !== 'undefined') document.documentElement.setAttribute('lang', current);
  return current;
}

/** chooseLocale is the viewer's own switch: persist, then reload.
 *
 *  A reload rather than a re-render, and that is not laziness. Several modules
 *  build their label maps at module-eval time (consumption.js's BILLING,
 *  review.js's DIM_LABEL, lib/spend.js's LABEL) because they are constants in
 *  every sense that matters at runtime. Re-rendering in place would leave those
 *  in the old language while everything around them changed — a half-switched
 *  page, which is worse than a one-second reload. The scope is in the URL and
 *  every fold state is in localStorage, so a reload lands the viewer exactly
 *  where they were. */
export function chooseLocale(loc) {
  const next = LOCALES.includes(loc) ? loc : FALLBACK;
  try { localStorage.setItem(STORAGE_KEY, next); } catch {}
  if (typeof location !== 'undefined' && location.reload) location.reload();
  else useLocale(next);
  return next;
}

/** t translates one key in the current locale.
 *
 *  `t('spend.incomplete', { missing: '…' })` — variables are named, never
 *  positional, because a translator moves them: Chinese puts the count after
 *  the noun where English puts it before. */
export const t = (key, vars) => interpolate(lookup(current, key), vars);

/** withLocale tags an API path with the viewer's language.
 *
 *  The server carries prose of its own that the page only relays — the real
 *  spend note, each source's price note, the empty-provider explanation. Those
 *  cannot be translated here: they are written where the figures are computed,
 *  and the page has no business restating a claim about money it did not make.
 *  So the request says which language it wants, and the note arrives ready to
 *  print. See internal/i18n on the Go side.
 *
 *  An explicit `locale=` already on the path wins, so a hand-built URL can ask
 *  for something else. */
export function withLocale(path) {
  if (/[?&]locale=/.test(path)) return path;
  return path + (path.includes('?') ? '&' : '?') + 'locale=' + encodeURIComponent(current);
}

/** tIn is t() in a named locale. Used by the language switcher, which has to
 *  label the OTHER language in its own words. */
export const tIn = (loc, key, vars) => interpolate(lookup(loc, key), vars);
