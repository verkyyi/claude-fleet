// web/dist/lib/cost.js — reading a cost aggregate that is kept split by source.
//
// The hub holds three kinds of money and this file exists so the dashboard
// cannot add two of them:
//
//   notional  claude + codex — what the tokens WOULD have cost at API rates.
//             Nobody is billed it; the subscription is.
//   billed    gateway — metered per call, so the figure is the invoice.
//   subscription  what the plans cost per month. Real, and not in the cost
//             column at all — it arrives as summary.subscription_spend.
//
// Real spend is subscription + billed. There is deliberately no total() here:
// every aggregate arrives as `cost: [{source, kind, events, cost_usd,
// unpriced_events}]`, and the only folds offered are the two that mean
// something. A blended figure is always plausible, which is exactly why
// nothing may produce one by accident.
//
// Each entry is already shaped like the object fmtCost (lib/format.js) reads —
// cost_usd, unpriced_events, events — so a per-source cell is fmtCost(entry).

import { fmtUSD, fmtCost } from './format.js';

/** Display order. Sources absent from a scope still get a column, so a table's
 *  columns do not move when one source goes quiet; the entry's `events` is
 *  what says whether $0.00 is a figure or an absence. */
export const SOURCES = ['claude', 'codex', 'gateway', 'vendor_bill', 'voice'];

export const KIND_LABEL = { notional: 'notional', billed: 'billed', unknown: 'unclassified' };

/** kindOf mirrors model.CostKind in Go: which kind of money a source's figure
 *  is. Kept here as well as arriving on every entry, so a column HEADER can be
 *  labelled before any row is read. */
export const kindOf = (source) => ((source === 'gateway' || source === 'vendor_bill' || source === 'voice') ? 'billed'
  : (source === 'claude' || source === 'codex' ? 'notional' : 'unknown'));

/** entries of a bucket/summary/series, always an array. */
export const costEntries = (b) => (Array.isArray(b && b.cost) ? b.cost : []);

/** one source's entry, or a zeroed stand-in that renders as an absence. */
export const costOf = (b, source) =>
  costEntries(b).find((c) => c.source === source) ||
  { source, kind: kindOf(source), events: 0, cost_usd: 0, unpriced_events: 0 };

const foldKind = (b, kind) =>
  costEntries(b).reduce((sum, c) => (c.kind === kind ? sum + (c.cost_usd || 0) : sum), 0);

/** notional totals claude + codex. Legitimate: they are the same kind of
 *  money, both answering "what would this have cost at API rates". */
export const notionalCost = (b) => foldKind(b, 'notional');

/** billed totals the metered sources. The only cost from this column that may
 *  be added to a subscription invoice. */
export const billedCost = (b) => foldKind(b, 'billed');

/** unpriced request count across sources — a count, not money, so it adds. */
export const unpricedEvents = (b) =>
  costEntries(b).reduce((sum, c) => sum + (c.unpriced_events || 0), 0);

/** sources that actually have usage in this scope, in display order. */
export const activeSources = (b) =>
  SOURCES.filter((s) => {
    const c = costOf(b, s);
    return (c.events || 0) > 0 || (c.cost_usd || 0) !== 0;
  });

/** sources with usage anywhere in a list of buckets — what a table's cost
 *  columns should be, so a Claude-only hub does not grow two empty ones. */
export function activeSourcesAcross(buckets) {
  const seen = new Set();
  (buckets || []).forEach((b) => activeSources(b).forEach((s) => seen.add(s)));
  return SOURCES.filter((s) => seen.has(s));
}

/** one source's cell: the figure, or an em dash when that source never ran. */
export const fmtSourceCost = (b, source) => {
  const c = costOf(b, source);
  if (!c.events) return '—';
  // Subscription work carries no amount on this page. The figure the API holds
  // for it is an API-equivalent estimate of money nobody was charged, and a
  // ledger's largest number must not be one of those. Absent, not zero: the plan
  // did cost something, it just is not attributable to this row. One place
  // decides it, so every table and tooltip agrees.
  if (c.kind === 'notional') return '—';
  return fmtCost(c);
};

/** a one-line summary of a bucket for a tooltip or a mobile row: each active
 *  source named, never a sum. "no cost" when nothing ran. */
export const costLine = (b) => {
  const active = activeSources(b);
  if (!active.length) return 'no cost';
  // A notional source is named without a figure rather than dropped: "this ran
  // on a subscription" is the answer, and omitting it would read as "nothing
  // ran here".
  return active.map((s) => {
    const c = costOf(b, s);
    return c.kind === 'notional'
      ? `${s} — subscription`
      : `${s} ${fmtSourceCost(b, s)} ${KIND_LABEL[c.kind]}`;
  }).join(' · ');
};

/** fold a list of splits into one, per source. Used where the page assembles
 *  a total the API did not (model-mix column totals). */
export function addCost(into, from) {
  costEntries(from).forEach((c) => {
    const at = into.find((x) => x.source === c.source);
    if (at) {
      at.events += c.events || 0;
      at.cost_usd += c.cost_usd || 0;
      at.unpriced_events += c.unpriced_events || 0;
    } else {
      into.push({ ...c });
    }
  });
  return into;
}

/** real spend, straight from the summary's own figure when the API supplied
 *  one. Rendered with what it could not include, because the error is always
 *  in the direction nobody checks. */
export function fmtRealSpend(rs) {
  if (!rs) return '—';
  return fmtUSD(rs.total) + (rs.complete ? '' : ' ≥');
}
