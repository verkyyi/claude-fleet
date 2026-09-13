// web/dist/lib/rows.js — turning a provider breakdown into table rows.
//
// The row key is (provider, model), not model. A gateway that fails over
// between vendors reaches one model id through several upstreams at several
// contracted prices, so a row keyed on the model alone would add two invoices
// together and present one plausible number. Pure — no DOM; the rendering
// lives in ../consumption.js.
import { activeSources, costOf, kindOf } from './cost.js';

// Billed first: it is the money somebody was actually charged, and it is the
// shorter list. Unknown last, because a source this build has not classified
// belongs to no total and should not sit between the two that do.
const KIND_ORDER = { billed: 0, notional: 1, unknown: 2 };

/** consumptionRows flattens one breakdown into rows carrying the two facts a
 *  reader needs before comparing anything: which contract served it, and
 *  which kind of money the figure is. */
export function consumptionRows(buckets) {
  return (buckets || []).map((b) => {
    const sources = activeSources(b);
    const src = sources[0] || 'claude';
    // A provider can front more than one source. Summing their cost is
    // legitimate only when they are the same kind of money; when they are
    // not, the row reports the kind as unknown rather than adding them.
    const kinds = new Set(sources.map(kindOf));
    const kind = kinds.size === 1 ? kindOf(src) : 'unknown';
    const cost = sources.reduce((n, s) => n + (costOf(b, s).cost_usd || 0), 0);
    const unpriced = sources.reduce((n, s) => n + (costOf(b, s).unpriced_events || 0), 0);
    return {
      provider: b.key,
      // Empty is the reporting side declaring none. Naming it beats a blank
      // cell the reader has to interpret, and it must not look like a vendor.
      providerLabel: b.key || 'not declared',
      sources,
      kind,
      events: b.events || 0,
      // null, not 0: vendor_bill is charged money that counts no tokens at
      // all, and 0 would claim it was measured.
      tokens: b.tokens ? b.tokens : null,
      cost,
      unpriced,
    };
  });
}

/** sortRows orders rows without ever ranking one kind of money against
 *  another: kinds stay grouped, and the sort applies inside each group.
 *  Returns a new array — callers hold the unsorted one for other views. */
export function sortRows(rows, key) {
  const within = (a, b) => {
    if (key === 'tokens') {
      // Absent sorts last whichever way you read it: it is not a small
      // number, it is the absence of one.
      if (a.tokens == null && b.tokens == null) return 0;
      if (a.tokens == null) return 1;
      if (b.tokens == null) return -1;
      return b.tokens - a.tokens;
    }
    if (key === 'cost') return b.cost - a.cost;
    return b.events - a.events;
  };
  return [...rows].sort((a, b) =>
    (KIND_ORDER[a.kind] - KIND_ORDER[b.kind]) || within(a, b));
}
