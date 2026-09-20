// web/dist/lib/format.js — pure number/time formatting. No DOM.
// fmtInt, fmtUSD, fmtFull, shortProject, relTime, ago are copied verbatim from
// the <script> block of the original web/dist/index.html — they were already
// pure, just inlined there.
import { t, locale, displayCurrency } from './i18n.js';

export const fmtInt = (n) => {
  n = Number(n) || 0;
  if (n >= 1e9) return (n / 1e9).toFixed(1) + "B";
  if (n >= 1e6) return (n / 1e6).toFixed(1) + "M";
  if (n >= 1e3) return (n / 1e3).toFixed(1) + "k";
  return String(Math.round(n));
};
/** DEFAULT_CURRENCY mirrors store.DefaultCurrency in Go: what an amount is in
 *  when nothing says otherwise. */
export const DEFAULT_CURRENCY = 'USD';

// One formatter per (locale, currency). Intl.NumberFormat is expensive to
// build and these are rebuilt per cell otherwise.
const money = new Map();
function moneyFormat(currency) {
  const loc = locale();
  const key = loc + '|' + currency;
  let f = money.get(key);
  if (!f) {
    try {
      f = new Intl.NumberFormat(loc, {
        style: 'currency', currency,
        minimumFractionDigits: 2, maximumFractionDigits: 2,
      });
    } catch {
      // An unrecognised currency code throws rather than degrading. A figure
      // with an odd code must still render — as the number and the code,
      // which is strictly more honest than stamping a dollar sign on it.
      f = {
        format: (n) => (Number(n) || 0).toLocaleString(loc, { minimumFractionDigits: 2, maximumFractionDigits: 2 })
          + ' ' + currency,
      };
    }
    money.set(key, f);
  }
  return f;
}

// The one rate the page converts at, installed once at boot (app.js) from
// /v1/fx. One value for the whole page on purpose: fetching it per card would
// let two cards render the same figure at two rates if their requests straddled
// a refresh, which is the sort of quietly-inconsistent money this hub exists to
// keep out.
//
// Null until it arrives, and null forever on a hub that cannot reach a feed —
// in which case every figure renders in the currency it was billed in, which is
// always the truthful rendering.
let fx = null;

/** useFxRate installs (or clears) the display conversion rate. */
export function useFxRate(r) {
  fx = r && r.available && r.rate > 0 ? r : null;
  return fx;
}

/** currentFx is the installed rate, for the surfaces that must disclose it. */
export const currentFx = () => fx;

/** convert returns [amount, currency, converted] for a figure to DISPLAY.
 *
 *  Unchanged unless a rate covering exactly this pair is loaded. The inverse is
 *  used when it is the pair we hold — one rate answers USD→CNY and CNY→USD, and
 *  refetching for the mirror would risk the two disagreeing. */
function convert(amount, billed) {
  const display = displayCurrency();
  if (!fx || billed === display) return [amount, billed, false];
  if (fx.base === billed && fx.target === display) return [amount * fx.rate, display, true];
  if (fx.base === display && fx.target === billed) return [amount / fx.rate, display, true];
  return [amount, billed, false];
}

/** APPROX marks a figure that has been through a rate. One character, always
 *  present, the same way `≥` marks a lower bound: whatever the tooltip says,
 *  the number on the page has to carry its own caveat. */
export const APPROX = '≈ ';

/** fmtMoney renders an amount for the viewer.
 *
 *  The LEDGER keeps every figure in the currency it was billed in — cost_usd
 *  stays USD, a plan priced in CNY stays CNY, and api.RealSpendOver still
 *  refuses to add two currencies rather than converting one into the other.
 *  This is the display layer on top of that, and it does two things:
 *
 *    1. renders in the viewer's locale, so a zh-CN reader sees "US$85.75"
 *       rather than an ambiguous "$85.75";
 *    2. converts to the viewer's own currency when a rate is loaded, marked
 *       with `≈` and with the billed amount and the rate in its tooltip.
 *
 *  The conversion is never arithmetic anyone depends on: totals are summed in
 *  the billed currency and converted after, so the parts still add to the whole,
 *  and a figure that has been converted says so. pricing.GatewayCNYPerUSD's
 *  comment warns that a live feed "would silently restate every historical
 *  figure each morning" — it is right, and `≈` plus moneyTitle is how this stops
 *  being silent. */
export function fmtMoney(n, currency) {
  const billed = (currency || DEFAULT_CURRENCY).toUpperCase();
  const [amount, cur, converted] = convert(Number(n) || 0, billed);
  return (converted ? APPROX : '') + moneyFormat(cur).format(amount);
}

/** moneyTitle is the tooltip for a converted figure: what was actually billed,
 *  and the rate it came through. Empty when nothing was converted — there is
 *  no claim to qualify. */
export function moneyTitle(n, currency) {
  const billed = (currency || DEFAULT_CURRENCY).toUpperCase();
  const [, , converted] = convert(Number(n) || 0, billed);
  if (!converted) return '';
  return t('fx.billedTip', {
    amount: moneyFormat(billed).format(Number(n) || 0),
    rate: fx.rate.toFixed(4), base: fx.base, target: fx.target,
    asOf: fxAsOf(),
  });
}

/** fxAsOf is when the FEED last moved, not when this page fetched it: a feed
 *  that has stopped updating must read as stale even though the last request
 *  succeeded a second ago. */
export function fxAsOf() {
  if (!fx) return '';
  if (!fx.as_of) return t('common.unknownTime');
  const d = new Date(fx.as_of);
  // locale(), not the browser default: the rest of the sentence around this
  // date is in the viewer's language, and "9/13/2026" in the middle of a
  // Chinese one is the same half-translated seam the dictionaries exist to
  // close.
  return Number.isFinite(d.getTime()) ? d.toLocaleDateString(locale()) : t('common.unknownTime');
}

/** fmtUSD is fmtMoney for the `cost_usd` column, which is USD by construction:
 *  every rate table resolves to USD at ingest (the gateway's own CNY rates are
 *  converted once, at a pinned and human-reviewed rate, and STORED as USD). A
 *  figure that carries its own currency — real spend, a subscription plan —
 *  must use fmtMoney and pass it. */
export const fmtUSD = (n) => fmtMoney(n, DEFAULT_CURRENCY);
// Aggregates retain the known subtotal and a separate missing-price count.
// A wholly unpriced bucket is unknown; a partial subtotal is a lower bound.
export const fmtCost = (b) => {
  if (b.cost_usd == null) return '—';
  if (b.unpriced_events > 0) {
    const count = b.events ?? b.turns;
    if (count > 0 && b.unpriced_events >= count) return '—';
    return '≥ ' + fmtUSD(b.cost_usd);
  }
  return fmtUSD(b.cost_usd);
};
export const fmtFull = (n) => (Number(n) || 0).toLocaleString();

/** shortProject trims a working directory to its last two segments. Full paths
 *  are long, and on a shared hub they leak more than they inform. */
export const shortProject = (p) => {
  if (!p) return t('common.unknown');
  const parts = p.replace(/\\/g, "/").replace(/\/+$/, "").split("/").filter(Boolean);
  if (parts.length <= 2) return p;
  // Two segments where they fit, one where they do not. What distinguishes
  // sibling worktrees is the LAST segment, so it must never be the part that
  // gets clipped — otherwise every row reads "…/projects/24haowan-monorepo…".
  const two = parts.slice(-2).join("/");
  return "…/" + (two.length <= 30 ? two : parts[parts.length - 1]);
};

export const relTime = (iso) => {
  if (!iso) return t('reset.unknown');
  const ms = new Date(iso) - Date.now();
  if (ms <= 0) return t('reset.now');
  const m = Math.round(ms / 60000);
  if (m < 60) return t('reset.minutes', { m });
  const h = Math.floor(m / 60);
  if (h < 24) return t('reset.hours', { h, m: m % 60 });
  return t('reset.days', { d: Math.floor(h / 24), h: h % 24 });
};

export const ago = (secs) => {
  if (secs == null) return "";
  if (secs < 90) return t('ago.seconds', { n: Math.round(secs) });
  if (secs < 5400) return t('ago.minutes', { n: Math.round(secs / 60) });
  return t('ago.hours', { n: Math.round(secs / 3600) });
};

export const fmtPct = (x, digits = 1) => (Number(x) * 100).toFixed(digits) + '%';
export function fmtDur(ms) {
  const m = Math.round(ms / 60000);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ${m % 60}m`;
  return `${Math.floor(h / 24)}d ${h % 24}h`;
}
// A delta against a near-zero (but not exactly zero, which `delta` below
// already renders as "no previous data") baseline is technically defined
// but carries no information beyond "there was almost nothing before" — and
// on real data has been wide enough (measured: "+295242%") to force its own
// layout wider than the column it lives in. DELTA_CAP_PCT is the magnitude
// past which the exact number stops being worth rendering; `pct` on the
// returned object is always the real, uncapped value (its SIGN still drives
// kpiTile's up/down colouring either way), only `text` is capped.
export const DELTA_CAP_PCT = 999;

// delta compares two additive values. null pct means "no previous data".
//
// `abs` is the plain difference and is ALWAYS a number, including when `pct`
// is null: "no previous data" is a statement about the ratio, not about the
// subtraction. A percentage alone cannot be read back into either figure, and
// on a bar row the reader wants "+41M tokens" at least as often as "+18%" —
// so every caller that has the two numbers can now show the one it needs.
export function delta(cur, prev) {
  const abs = (Number(cur) || 0) - (Number(prev) || 0);
  if (!prev || !Number.isFinite(prev)) return { pct: null, abs, text: '—' };
  const pct = ((cur - prev) / prev) * 100;
  const sign = pct > 0 ? '+' : '';
  if (Math.abs(pct) >= DELTA_CAP_PCT) return { pct, abs, text: `${sign}≫${DELTA_CAP_PCT}%` };
  return { pct, abs, text: `${sign}${Math.abs(pct) >= 10 ? Math.round(pct) : pct.toFixed(1)}%` };
}

/** fmtSigned renders an absolute difference with its sign kept: `0` is "±0",
 *  not "0", so a row that did not move says so rather than looking like a
 *  missing figure. */
export const fmtSigned = (n) => {
  const v = Number(n) || 0;
  return (v > 0 ? '+' : v < 0 ? '−' : '±') + fmtFull(Math.abs(v));
};

/* ------------------------------------------------- one scale, one denominator */

/** scaleMax is the single denominator two or more bar lists must share before
 *  their bars can be compared by eye. `rows` is the CONCATENATION of every
 *  list that will be drawn at this scale; the result is the largest figure
 *  any of them will draw — current values AND previous-period markers, since
 *  a marker outside the track is a marker that lies about where it sits.
 *
 *  Sharing a denominator is the whole point: two lists normalized to their own
 *  first row draw a full-width bar each for two numbers that are not equal,
 *  which is the defect this exists to prevent. Never mix units through here —
 *  tokens and turns share no scale, and a shared max would make them look as
 *  if they did.
 *
 *  Floors at 1 so an all-zero list divides by something. */
export const scaleMax = (rows) =>
  Math.max(1, ...(rows || []).map((r) => Math.max(Number(r.value) || 0, Number(r.prev) || 0)));

/** shareText is `value` as a percentage of `total`, or null when there is no
 *  denominator to be a share OF.
 *
 *  null is deliberate and callers must render it as absence, not as "—": on
 *  this page a dash already means "no cost", "unknown" and "notional", and a
 *  fourth meaning would finish the job of making it mean nothing.
 *
 *  The CALLER owns what `total` is, and owes the reader that sentence. The one
 *  rule this file can enforce is the repo's: a denominator is a sum of ONE
 *  quantity. Token share takes a token total. Cost share takes one source's
 *  cost — never a cross-source total, which internal/store/cost.go refuses to
 *  compute for the same reason. */
export function shareText(value, total) {
  const t = Number(total) || 0;
  if (t <= 0) return null;
  const pct = ((Number(value) || 0) / t) * 100;
  if (pct > 0 && pct < 0.1) return '<0.1%';
  return `${pct.toFixed(1)}%`;
}
