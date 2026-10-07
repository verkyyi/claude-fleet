import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { en } from '../dist/lib/i18n/en.js';
import { zhCN } from '../dist/lib/i18n/zh-CN.js';
import { normalizeLocale, readCookie, langURL } from '../dist/lib/i18n.js';
import { pickLocale, interpolate, lookup, t, tIn, useLocale, withLocale,
         LOCALES, LOCALE_LABEL, DICTS, FALLBACK, punct, LOCALE_PUNCT } from '../dist/lib/i18n.js';

// A key present in one dictionary and not the other is the failure mode this
// whole file exists for: it ships silently, and the only symptom is one English
// sentence in the middle of a Chinese page (or, worse, a raw `ui.nav.overview`).
test('every locale has exactly the same keys', () => {
  const keys = Object.keys(en);
  assert.ok(keys.length > 200, `only ${keys.length} keys — did a dictionary fail to load?`);
  for (const loc of LOCALES) {
    const dict = DICTS[loc];
    const missing = keys.filter((k) => !(k in dict));
    const extra = Object.keys(dict).filter((k) => !(k in en));
    assert.deepEqual(missing, [], `${loc} is missing keys`);
    assert.deepEqual(extra, [], `${loc} has keys English does not`);
  }
});

test('no translation is blank', () => {
  for (const loc of LOCALES) {
    for (const [k, v] of Object.entries(DICTS[loc])) {
      assert.equal(typeof v, 'string', `${loc}/${k} is not a string`);
      assert.notEqual(v.trim(), '', `${loc}/${k} is empty — it would render as nothing`);
    }
  }
});

// A translator moves a variable; a translator must not LOSE one. `{n}` dropped
// from a Chinese string is a sentence that silently stops saying how many.
test('placeholders survive translation', () => {
  const vars = (s) => [...String(s).matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();
  for (const k of Object.keys(en)) {
    for (const loc of LOCALES) {
      assert.deepEqual(vars(DICTS[loc][k]), vars(en[k]), `${loc}/${k} placeholders differ`);
    }
  }
});

test('a stored choice beats the browser, and zh-TW lands on Simplified', () => {
  assert.equal(pickLocale('zh-CN', ['en-US']), 'zh-CN');
  assert.equal(pickLocale('en', ['zh-CN']), 'en');
  // Not a locale this build has: ignored rather than obeyed.
  assert.equal(pickLocale('fr', ['zh-CN']), 'zh-CN');
  assert.equal(pickLocale(null, ['zh-TW', 'en']), 'zh-CN');
  assert.equal(pickLocale(null, ['zh-HK']), 'zh-CN');
  assert.equal(pickLocale(null, ['fr-FR', 'de']), 'en');
  assert.equal(pickLocale(null, []), 'en');
  assert.equal(pickLocale(undefined, undefined), 'en');
});

test('a missing key falls back to English, never to a blank', () => {
  assert.equal(lookup('zh-CN', 'ui.nav.overview'), zhCN['ui.nav.overview']);
  // A locale with no entry for a key gets the English sentence...
  assert.equal(lookup('fr', 'ui.nav.overview'), en['ui.nav.overview']);
  // ...and a key no dictionary has renders as itself, which is visibly a bug
  // rather than an invisible hole in a sentence about money.
  assert.equal(lookup('en', 'no.such.key'), 'no.such.key');
});

test('interpolation is by name, and an unknown placeholder stays visible', () => {
  assert.equal(interpolate('{a} then {b}', { a: '1', b: '2' }), '1 then 2');
  assert.equal(interpolate('{a} then {b}', { a: '1' }), '1 then {b}');
  assert.equal(interpolate('no vars', { a: '1' }), 'no vars');
  assert.equal(interpolate('{a}', null), '{a}');
});

// Under node there is no document, so detection never runs: the pure lib
// modules (fold.js's sentence, cost.js's costLine) must read the same whatever
// language the test machine's browser would have asked for.
test('node defaults to English regardless of the host locale', () => {
  assert.equal(FALLBACK, 'en');
  assert.equal(t('ui.nav.overview'), en['ui.nav.overview']);
});

test('tIn and useLocale switch language without a browser', () => {
  assert.equal(tIn('zh-CN', 'ui.nav.overview'), zhCN['ui.nav.overview']);
  try {
    useLocale('zh-CN');
    assert.equal(t('ui.nav.overview'), zhCN['ui.nav.overview']);
    assert.equal(t('ui.usr.bad'), zhCN['ui.usr.bad']);
  } finally {
    useLocale('en');
  }
});

test('every locale names itself in its own language', () => {
  for (const loc of LOCALES) {
    assert.ok(LOCALE_LABEL[loc], `${loc} has no label for the switcher`);
  }
  assert.equal(LOCALE_LABEL['zh-CN'], '简体中文');
});

// The server writes prose the page only relays (real spend, each source's price
// basis, the empty-provider explanation). It cannot translate what it did not
// write, so every request has to say which language it wants.
test('withLocale tags a path exactly once, query string or not', () => {
  try {
    useLocale('zh-CN');
    assert.equal(withLocale('/v1/accounts'), '/v1/accounts?locale=zh-CN');
    assert.equal(withLocale('/v1/usage?by=model'), '/v1/usage?by=model&locale=zh-CN');
    // Already asked for something: left alone, so a hand-built URL wins.
    assert.equal(withLocale('/v1/usage?locale=en'), '/v1/usage?locale=en');
    assert.equal(withLocale(withLocale('/v1/accounts')), '/v1/accounts?locale=zh-CN');
  } finally {
    useLocale('en');
  }
});

// #107: punctuation the PAGE supplies follows the page's language (sessions.html
// joins its two sentences with punct().gap); punctuation inside text that
// arrives already written is never touched.
test('punctuation the page supplies follows the reader language', () => {
  try {
    useLocale('en');
    assert.deepEqual(punct(), { list: '; ', end: '.', gap: ' ' });
    useLocale('zh-CN');
    assert.deepEqual(punct(), { list: '；', end: '。', gap: '' });
    // A locale with no set of its own falls back rather than yielding undefined
    // and printing "undefined" between two fragments.
    useLocale('fr');
    assert.deepEqual(punct(), LOCALE_PUNCT.en);
  } finally {
    useLocale('en');
  }
});

// #2023: the link and the cookie join the rule, in the hub's order —
// ?lang= > cf_lang cookie > the older stored choice > the browser.
test('a link beats the cookie, the cookie beats the browser', () => {
  assert.equal(pickLocale(null, ['en-US'], { query: 'zh' }), 'zh-CN');
  assert.equal(pickLocale('zh-CN', ['zh-CN'], { query: 'en', cookie: 'zh-CN' }), 'en');
  assert.equal(pickLocale(null, ['zh-CN'], { cookie: 'en' }), 'en');
  assert.equal(pickLocale('en', ['en'], { cookie: 'zh-CN' }), 'zh-CN');
  // An unknown value on any rung is skipped, not obeyed.
  assert.equal(pickLocale(null, ['zh-TW'], { query: 'fr', cookie: 'xx' }), 'zh-CN');
  assert.equal(normalizeLocale('ZH'), 'zh-CN');
  assert.equal(normalizeLocale('en-GB'), 'en');
  assert.equal(normalizeLocale('fr'), null);
});

test('readCookie and langURL', () => {
  assert.equal(readCookie('a=1; cf_lang=zh-CN; b=2', 'cf_lang'), 'zh-CN');
  assert.equal(readCookie('a=1', 'cf_lang'), null);
  assert.equal(readCookie('', 'cf_lang'), null);
  assert.equal(langURL('https://h/x?scope=a&lang=en#f', 'zh-CN'), 'https://h/x?scope=a&lang=zh#f');
  assert.equal(langURL('https://h/', 'en'), 'https://h/?lang=en');
});

// claude-fleet#2027: the old dashboard (#1989) left ~370 keys behind that no
// page printed any more, and nobody translating could tell them from the live
// ones. Every key must be used by some file under web/dist: as a literal
// ('ui.ses.history'), or under a prefix a page builds a key from
// (t('ui.aud.k.' + kind)). A page whose last t('…') goes takes its key along.
test('every key is used by a page under web/dist', () => {
  const dist = join(dirname(fileURLToPath(import.meta.url)), '..', 'dist');
  const files = [];
  (function walk(d) {
    for (const f of readdirSync(d)) {
      const p = join(d, f);
      if (statSync(p).isDirectory()) { if (f !== 'i18n') walk(p); } else if (/\.(js|html)$/.test(f)) files.push(p);
    }
  })(dist);
  const src = files.map((f) => readFileSync(f, 'utf8')).join('\n');
  // A key built at runtime: 'ui.set.k.' + it.key, … — any quoted prefix
  // ending in a dot and followed by `+`.
  const prefixes = [...src.matchAll(/['"`]((?:[\w]+\.)+)['"`]\s*\+/g)].map((m) => m[1]);
  const unused = Object.keys(en).filter((k) =>
    !['\'', '"', '`'].some((q) => src.includes(q + k + q)) && !prefixes.some((p) => k.startsWith(p)));
  assert.deepEqual(unused, [], 'keys no file under web/dist uses — delete them from en.js and zh-CN.js');
});
