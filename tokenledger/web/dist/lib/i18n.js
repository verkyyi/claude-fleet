// web/dist/lib/i18n.js — this page in two languages.
//
// One dictionary per locale, English as the fallback for every key a locale
// has not translated: a missing key renders the English sentence, never a raw
// `ui.nav.overview` in the middle of a page. That is the whole failure mode worth
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
//     `codex` is what the API calls it and what an operator greps for.
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

/** LANG_COOKIE is the choice this browser remembers — the same cookie the hub
 *  reads to draw its public pages (internal/api/pagelang.go, #2023). */
export const LANG_COOKIE = 'cf_lang';

/** normalizeLocale maps a tag onto a locale this build ships, or null:
 *  `zh`, `zh-CN`, `zh-TW`, `zh-HK` → zh-CN (no Traditional dictionary, and
 *  Simplified is far closer than English); `en*` → en; anything else null. */
export function normalizeLocale(tag) {
  if (!tag) return null;
  const s = String(tag).trim();
  if (LOCALES.includes(s)) return s;
  const primary = s.toLowerCase().split('-')[0];
  return LOCALES.find((l) => l.toLowerCase().split('-')[0] === primary) || null;
}

/** pickLocale resolves the locale to use. Pure, so the rule is testable
 *  without a browser. The same rule the hub applies (#2023):
 *
 *    ?lang= in the link  >  the cf_lang cookie  >  a stored choice  >  the browser
 *
 *  The link wins so a shared link opens in the language it was sent in. The
 *  signed-in account's choice is folded in by the SERVER, which writes it into
 *  the cookie on every page it serves — so a new device already has it here.
 *  `stored` is the older localStorage choice, read for browsers that made it
 *  before the cookie existed. A value this build has no dictionary for is
 *  ignored rather than obeyed. */
export function pickLocale(stored, languages, { query, cookie } = {}) {
  for (const explicit of [query, cookie, stored]) {
    const hit = normalizeLocale(explicit);
    if (hit) return hit;
  }
  for (const tag of languages || []) {
    const hit = normalizeLocale(tag);
    if (hit) return hit;
  }
  return FALLBACK;
}

/** readCookie is one cookie's value from a document.cookie string. */
export function readCookie(all, name) {
  for (const part of String(all || '').split(';')) {
    const [k, ...v] = part.trim().split('=');
    if (k === name) {
      try { return decodeURIComponent(v.join('=')); } catch { return v.join('='); }
    }
  }
  return null;
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
  let query = null;
  try { query = new URLSearchParams(location.search).get('lang'); } catch {}
  current = pickLocale(stored, langs, { query, cookie: readCookie(document.cookie, LANG_COOKIE) });
  document.documentElement.setAttribute('lang', current);
}

export const locale = () => current;

/** LOCALE_PUNCT is the punctuation this page SUPPLIES ITSELF, in the width of
 *  the language it is writing in.
 *
 *  Only for marks the page adds between or after pieces of text: the separator
 *  when it joins a list of fragments, the full stop when it closes a sentence
 *  it started, the gap between a bold lead-in and the sentence that follows.
 *  Chinese wants the full-width marks and no space around them; English wants
 *  the half-width marks and the space.
 *
 *  Text that arrives ALREADY WRITTEN is never punctuated here — a reason from
 *  /v1/limits, an endpoint's own words, a translator's sentence. Those carry
 *  their own terminator, written by whoever wrote the sentence (#107: the
 *  banner used to append an ASCII "." to the server's reason, which is right in
 *  English and a Latin dot dropped mid-sentence in Chinese). See the matching
 *  rule in internal/api/i18n.go. */
export const LOCALE_PUNCT = {
  en: { list: '; ', end: '.', gap: ' ' },
  'zh-CN': { list: '；', end: '。', gap: '' },
};

/** punct is this viewer's punctuation set. */
export const punct = () => LOCALE_PUNCT[current] || LOCALE_PUNCT[FALLBACK];

/** useLocale sets the in-memory locale without persisting or reloading. For
 *  tests, and for anything that needs to render one string in a locale that is
 *  not the viewer's. */
export function useLocale(loc) {
  current = LOCALES.includes(loc) ? loc : FALLBACK;
  if (typeof document !== 'undefined') document.documentElement.setAttribute('lang', current);
  return current;
}

/** chooseLocale is the viewer's own switch: remember, then reload.
 *
 *  A reload rather than a re-render, and that is not laziness. Several modules
 *  build their label maps at module-eval time (consumption.js's BILLING,
 *  review.js's DIM_LABEL, lib/spend.js's LABEL) because they are constants in
 *  every sense that matters at runtime. Re-rendering in place would leave those
 *  in the old language while everything around them changed — a half-switched
 *  page, which is worse than a one-second reload. The scope is in the URL and
 *  every fold state is in localStorage, so a reload lands the viewer exactly
 *  where they were.
 *
 *  The reload carries ?lang= (#2023): that is what tells the hub to save the
 *  choice on a signed-in account, so it follows the person to their next
 *  device. Without it the account's OLD choice would outrank the new cookie on
 *  the very next page. The cookie is written here too, so a hub that does not
 *  know the parameter still remembers it for this browser. */
export function chooseLocale(loc) {
  const next = LOCALES.includes(loc) ? loc : FALLBACK;
  try { localStorage.setItem(STORAGE_KEY, next); } catch {}
  if (typeof document !== 'undefined') {
    document.cookie = `${LANG_COOKIE}=${encodeURIComponent(next)}; path=/; max-age=31536000; samesite=lax`;
  }
  if (typeof location !== 'undefined' && location.replace) location.replace(langURL(location.href, next));
  else useLocale(next);
  return next;
}

/** langURL is href with its ?lang= set to loc's short form (zh / en), every
 *  other parameter and the hash kept. */
export function langURL(href, loc) {
  const u = new URL(href);
  u.searchParams.set('lang', loc === 'zh-CN' ? 'zh' : 'en');
  return u.toString();
}

/** t translates one key in the current locale.
 *
 *  `t('ui.usr.added', { login: '…' })` — variables are named, never
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

/* ---------------------------------------------------------------- formats
 * Big numbers and times, by the reader's language (claude-fleet#1989, the
 * EPIC #1982 design's rules; C9 #2023 reuses them): English 212.4M · 1.31B ·
 * Oct 6, 18:20 · 6 min ago; Chinese counts in 万 / 亿 — 2.12 亿 · 13.1 亿 ·
 * 10月6日 18:20 · 6 分钟前. `loc` defaults to the page's language.
 */

const trim0 = (s) => (s.includes('.') ? s.replace(/\.?0+$/, '') : s);
// Three significant digits, never an exponent: 2.12 · 13.1 · 424 · 4240.
const sig3 = (v) => (Math.abs(v) >= 100 ? String(Math.round(v)) : trim0(v.toPrecision(3)));

/** fmtCompact prints a count short: 212.4M / 2.12 亿. */
export function fmtCompact(n, loc = current) {
  n = Number(n) || 0;
  const a = Math.abs(n);
  if (loc === 'zh-CN') {
    if (a >= 1e8) return sig3(n / 1e8) + ' 亿';
    if (a >= 1e4) return sig3(n / 1e4) + ' 万';
    return String(Math.round(n));
  }
  if (a >= 1e9) return trim0((n / 1e9).toFixed(2)) + 'B';
  if (a >= 1e6) return trim0((n / 1e6).toFixed(1)) + 'M';
  if (a >= 1e3) return trim0((n / 1e3).toFixed(1)) + 'k';
  return String(Math.round(n));
}

const toMs = (t) => (typeof t === 'number' ? t : Date.parse(t));
const pad2 = (x) => ('0' + x).slice(-2);

/** fmtDate is a day and a clock time: "Oct 6, 18:20" / "10月6日 18:20";
 *  `withTime: false` drops the clock. Local time. Invalid → "—". */
export function fmtDate(t, loc = current, withTime = true) {
  const ms = toMs(t);
  if (!Number.isFinite(ms) || ms <= 0) return '—';
  const d = new Date(ms);
  const time = withTime ? `${pad2(d.getHours())}:${pad2(d.getMinutes())}` : '';
  if (loc === 'zh-CN') return `${d.getMonth() + 1}月${d.getDate()}日${time ? ' ' + time : ''}`;
  const day = d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  return time ? `${day}, ${time}` : day;
}

/** fmtAgo is how long ago: "6 min ago" / "6 分钟前". Invalid → "—". */
export function fmtAgo(t, now = Date.now(), loc = current) {
  const ms = toMs(t);
  if (!Number.isFinite(ms) || ms <= 0) return '—';
  const s = Math.max(0, Math.round((now - ms) / 1000));
  const zh = loc === 'zh-CN';
  if (s < 60) return zh ? '刚刚' : 'just now';
  if (s < 3600) return zh ? `${Math.floor(s / 60)} 分钟前` : `${Math.floor(s / 60)} min ago`;
  if (s < 86400) return zh ? `${Math.floor(s / 3600)} 小时前` : `${Math.floor(s / 3600)} h ago`;
  return zh ? `${Math.floor(s / 86400)} 天前` : `${Math.floor(s / 86400)} d ago`;
}
