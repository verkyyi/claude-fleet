import test from 'node:test';
import assert from 'node:assert/strict';
import { fmtMoney, fmtUSD, DEFAULT_CURRENCY } from '../dist/lib/format.js';
import { fmtRealSpend } from '../dist/lib/cost.js';
import { spendTerms } from '../dist/lib/spend.js';
import { useLocale } from '../dist/lib/i18n.js';

// The page used to stamp "$" on every figure regardless of what the data said.
// A hub whose plans are priced in CNY was shown "$46.00" for ¥46.00 — a wrong
// currency on a real invoice, which is a worse error than a wrong language.
test('an amount is rendered in the currency it was billed in', () => {
  assert.equal(fmtMoney(85.75, 'USD'), '$85.75');
  assert.match(fmtMoney(46, 'CNY'), /¥46\.00$/);
  // No currency stated is USD, matching store.DefaultCurrency in Go.
  assert.equal(DEFAULT_CURRENCY, 'USD');
  assert.equal(fmtMoney(85.75, undefined), fmtMoney(85.75, 'USD'));
  assert.equal(fmtMoney(85.75, ''), fmtMoney(85.75, 'USD'));
});

// The one thing this must NOT do. api.RealSpendOver refuses to add two
// currencies together and reports the total as incomplete instead ("this hub
// does no currency conversion"); showing a converted figure on the way out
// would reintroduce exactly the money nobody was charged that the Go side
// declines to invent.
test('the locale changes the rendering, never the amount', () => {
  try {
    for (const loc of ['en', 'zh-CN']) {
      useLocale(loc);
      for (const [n, cur] of [[85.75, 'USD'], [46, 'CNY'], [1234567.5, 'USD']]) {
        const digits = fmtMoney(n, cur).replace(/[^0-9.]/g, '');
        assert.equal(Number(digits.replace(/,/g, '')), n,
          `${loc}/${cur}: the number itself changed`);
      }
    }
  } finally {
    useLocale('en');
  }
});

test('a zh-CN viewer is told WHICH dollar', () => {
  try {
    useLocale('zh-CN');
    // "$85.75" is ambiguous to a reader who also sees ¥; "US$85.75" is not.
    assert.equal(fmtMoney(85.75, 'USD'), 'US$85.75');
    assert.equal(fmtMoney(46, 'CNY'), '¥46.00');
  } finally {
    useLocale('en');
  }
  // English output is unchanged from before this existed.
  assert.equal(fmtUSD(85.75), '$85.75');
  assert.equal(fmtUSD(0), '$0.00');
  assert.equal(fmtUSD(1234567.5), '$1,234,567.50');
});

// A junk currency code makes Intl.NumberFormat throw. The figure must still
// render: the number plus the code is more honest than a dollar sign over it.
test('an unrecognised currency code still renders', () => {
  const got = fmtMoney(12.5, 'NOT-A-CURRENCY');
  assert.match(got, /12\.50/);
  assert.match(got, /NOT-A-CURRENCY/);
  assert.ok(!got.includes('$'), `fell back to a dollar sign: ${got}`);
});

test('real spend and its terms carry the currency the total is in', () => {
  const rs = { currency: 'CNY', subscription: 40, gateway: 6, vendor_bill: 0, total: 46, complete: true };
  assert.match(fmtRealSpend(rs), /¥46\.00/);
  // Every term is a part of that total, so it cannot be in another currency.
  for (const term of spendTerms(rs)) {
    assert.equal(term.currency, 'CNY', `${term.key} lost the currency`);
  }
  // An incomplete total still says so.
  assert.match(fmtRealSpend({ ...rs, complete: false }), /≥$/);
  assert.equal(fmtRealSpend(null), '—');
});

import { useFxRate, currentFx, moneyTitle, APPROX } from '../dist/lib/format.js';
import { displayCurrency, LOCALE_CURRENCY } from '../dist/lib/i18n.js';

const USD_CNY = { available: true, base: 'USD', target: 'CNY', rate: 7.0912,
                  as_of: '2026-09-14T00:00:00Z', source: 'https://example.test/fx', fallback: false, stale: false };

test('the display currency follows the locale', () => {
  try {
    useLocale('en');
    assert.equal(displayCurrency(), 'USD');
    useLocale('zh-CN');
    assert.equal(displayCurrency(), 'CNY');
  } finally { useLocale('en'); }
  // Every locale this build ships must name a currency, or its viewers get
  // whatever 'USD' happens to mean to them.
  for (const loc of Object.keys(LOCALE_CURRENCY)) assert.ok(LOCALE_CURRENCY[loc]);
});

test('with a rate loaded, a zh-CN viewer reads CNY — marked', () => {
  try {
    useLocale('zh-CN');
    useFxRate(USD_CNY);
    const got = fmtMoney(85.75, 'USD');
    assert.ok(got.startsWith(APPROX), `converted figure is not marked: ${got}`);
    assert.match(got, /¥/);
    // 85.75 × 7.0912 = 607.97…  The digits must be the conversion, not the
    // original with a different symbol stamped on it.
    const n = Number(got.replace(/[^0-9.]/g, ''));
    assert.ok(Math.abs(n - 85.75 * USD_CNY.rate) < 0.02, `converted to ${n}`);
  } finally { useFxRate(null); useLocale('en'); }
});

test('a figure already in the display currency is never round-tripped', () => {
  try {
    useLocale('zh-CN');
    useFxRate(USD_CNY);
    const got = fmtMoney(46, 'CNY');
    assert.ok(!got.startsWith(APPROX), `a CNY figure was marked as converted: ${got}`);
    assert.equal(got, '¥46.00');
  } finally { useFxRate(null); useLocale('en'); }
});

test('one rate answers both directions', () => {
  try {
    // An English viewer on a CNY-billed deployment: the same rate, inverted,
    // rather than a second fetch the two could disagree on.
    useLocale('en');
    useFxRate(USD_CNY);
    const got = fmtMoney(709.12, 'CNY');
    assert.ok(got.startsWith(APPROX), got);
    const n = Number(got.replace(/[^0-9.]/g, ''));
    assert.ok(Math.abs(n - 100) < 0.05, `709.12 CNY should be ~$100, got ${n}`);
  } finally { useFxRate(null); useLocale('en'); }
});

// The failure mode that matters: no feed must never mean a wrong number. It
// means no conversion, and the figure stands in the currency it was billed in.
test('no rate means no conversion, not a guess', () => {
  try {
    useLocale('zh-CN');
    useFxRate(null);
    const got = fmtMoney(85.75, 'USD');
    assert.ok(!got.startsWith(APPROX), got);
    assert.equal(got, 'US$85.75');
    assert.equal(moneyTitle(85.75, 'USD'), '', 'an unconverted figure should make no claim to qualify');
    // A feed that answered "I cannot do this pair" is the same as no feed.
    useFxRate({ available: false, base: 'USD', target: 'CNY' });
    assert.equal(currentFx(), null);
    assert.equal(fmtMoney(85.75, 'USD'), 'US$85.75');
    // So is a nonsense rate.
    useFxRate({ available: true, base: 'USD', target: 'CNY', rate: 0 });
    assert.equal(currentFx(), null);
  } finally { useFxRate(null); useLocale('en'); }
});

test('a converted figure carries what was actually billed', () => {
  try {
    useLocale('zh-CN');
    useFxRate(USD_CNY);
    const tip = moneyTitle(85.75, 'USD');
    assert.match(tip, /US\$85\.75/, `the billed amount is missing: ${tip}`);
    assert.match(tip, /7\.0912/, `the rate is missing: ${tip}`);
  } finally { useFxRate(null); useLocale('en'); }
});

// Converting the parts and the whole at one rate keeps them adding up. Two
// rates on one page is the bug this guards against.
test('converted terms still add to the converted total', () => {
  try {
    useLocale('zh-CN');
    useFxRate(USD_CNY);
    const rs = { currency: 'USD', subscription: 46, gateway: 1.06, vendor_bill: 38.7, voice: 0,
                 total: 85.76, complete: true };
    const num = (s) => Number(s.replace(/[^0-9.]/g, ''));
    const parts = spendTerms(rs).reduce((a, term) => a + num(fmtMoney(term.amount, term.currency)), 0);
    assert.ok(Math.abs(parts - num(fmtMoney(rs.total, rs.currency))) < 0.02,
      `parts ${parts} do not add to the total`);
  } finally { useFxRate(null); useLocale('en'); }
});
