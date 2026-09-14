import test from 'node:test';
import assert from 'node:assert/strict';
import { en } from '../dist/lib/i18n/en.js';
import { zhCN } from '../dist/lib/i18n/zh-CN.js';
import { pickLocale, interpolate, lookup, t, tIn, useLocale, withLocale,
         LOCALES, LOCALE_LABEL, DICTS, FALLBACK } from '../dist/lib/i18n.js';
import { SOURCE_LABEL, sourceLabel } from '../dist/lib/providers.js';

// A key present in one dictionary and not the other is the failure mode this
// whole file exists for: it ships silently, and the only symptom is one English
// sentence in the middle of a Chinese card (or, worse, a raw `spend.title`).
test('every locale has exactly the same keys', () => {
  const keys = Object.keys(en);
  assert.ok(keys.length > 300, `only ${keys.length} keys — did a dictionary fail to load?`);
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
  assert.equal(lookup('zh-CN', 'spend.title'), zhCN['spend.title']);
  // A locale with no entry for a key gets the English sentence...
  assert.equal(lookup('fr', 'spend.title'), en['spend.title']);
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
  assert.equal(t('spend.title'), en['spend.title']);
});

test('tIn and useLocale switch language without a browser', () => {
  assert.equal(tIn('zh-CN', 'spend.title'), zhCN['spend.title']);
  try {
    useLocale('zh-CN');
    assert.equal(t('spend.title'), zhCN['spend.title']);
    assert.equal(t('spend.unpriced', { n: 7 }), zhCN['spend.unpriced'].replace('{n}', '7'));
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

// web/embed_test.go's TestDashboard_EverySourceIsNamedAndEveryChargeIsATerm
// anchors on lib/providers.js's SOURCE_LABEL to catch a source added to
// model.Sources with no label. That guard only keeps working while SOURCE_LABEL
// stays the English text -- so the dictionary must agree with it rather than
// quietly replace it.
test('the English source labels and the dictionary agree', () => {
  for (const [src, label] of Object.entries(SOURCE_LABEL)) {
    assert.equal(en['source.' + src], label, `source.${src} has drifted from SOURCE_LABEL`);
    assert.equal(sourceLabel(src), label, `sourceLabel(${src}) does not read from the dictionary`);
  }
  // A source with no dictionary entry falls back to its identifier, which is at
  // least greppable, rather than to an empty picker option.
  assert.equal(sourceLabel('brand_new_source'), 'brand_new_source');
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
