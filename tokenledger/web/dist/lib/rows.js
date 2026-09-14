// web/dist/lib/rows.js — turning a provider breakdown into table rows.
//
// The row key is (provider, model), not model. A gateway that fails over
// between vendors reaches one model id through several upstreams at several
// contracted prices, so a row keyed on the model alone would add two invoices
// together and present one plausible number. Pure — no DOM; the rendering
// lives in ../consumption.js.
import { activeSources, costOf, kindOf } from './cost.js';
import { t } from './i18n.js';

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
      providerLabel: b.key || t('rows.notDeclared'),
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

/** A row is tail noise when it reports almost nothing AND no money.
 *
 *  Both halves are load-bearing. Measured on this deployment: four gateway
 *  "providers" are bare IP addresses with one or two requests, no tokens and no
 *  charge — and they sat in the table as prominently as the upstream that served
 *  1,555 requests. But `volc` has only SEVEN requests and $38.37, the largest
 *  single amount in the table, so a rule that folded by request count alone
 *  would hide the biggest money on the page. A row that cost something is never
 *  tail, however quiet it was.
 *
 *  The threshold is about noise, not size: a hub whose table is long because it
 *  has fifty busy providers needs a different answer (a top-N fold), and this
 *  one deliberately does not pretend to be it. */
export const TAIL_MAX_EVENTS = 2;

/** Folding two rows into "other 2" saves no one anything and costs a reader the
 *  two names. Below this many, the tail stays as it is. */
export const TAIL_MIN_ROWS = 3;

const isTail = (r) => r.events <= TAIL_MAX_EVENTS && !r.cost;

/** foldTail collapses the insignificant tail into one row per KIND.
 *
 *  Per kind, never across: the folded row carries a cost, and summing a metered
 *  charge into an API-equivalent estimate is the one arithmetic this hub never
 *  does. (In practice a folded row's cost is 0 by definition — the per-kind
 *  split is kept anyway, because the reason it is 0 is a filter someone could
 *  later relax, and the guard should not depend on that.)
 *
 *  Returns rows in the same order, with each kind's tail replaced by a single
 *  synthetic row. Every total is conserved: what the table adds up to does not
 *  change, only how many lines it takes to say it. */
export function foldTail(rows) {
  const tail = rows.filter(isTail);
  if (tail.length < TAIL_MIN_ROWS) return rows;

  const folded = new Map(); // kind -> synthetic row
  for (const r of tail) {
    const at = folded.get(r.kind) || {
      provider: null, kind: r.kind, events: 0, tokens: null, cost: 0, unpriced: 0, foldedCount: 0,
    };
    at.events += r.events;
    at.cost += r.cost;
    at.unpriced += r.unpriced;
    at.foldedCount++;
    // null stays null: these rows count no tokens at all, and 0 would claim they
    // were measured.
    if (r.tokens != null) at.tokens = (at.tokens || 0) + r.tokens;
    folded.set(r.kind, at);
  }
  // A kind whose whole tail was one row is not worth folding on its own.
  for (const [kind, row] of [...folded]) {
    if (row.foldedCount < 2) folded.delete(kind);
  }
  if (!folded.size) return rows;

  for (const row of folded.values()) {
    row.providerLabel = t('rows.foldedTail', { n: row.foldedCount, max: TAIL_MAX_EVENTS });
  }

  // Walk the kind RUNS rather than the whole list, so each fold row lands at the
  // end of its own kind rather than after every other kind. Appending them all
  // at the end put a billed fold row below the notional rows, which breaks the
  // one ordering rule this table has: kinds stay grouped, always.
  const out = [];
  const placed = new Set();
  for (let i = 0; i < rows.length;) {
    const kind = rows[i].kind;
    while (i < rows.length && rows[i].kind === kind) {
      if (!(isTail(rows[i]) && folded.has(kind))) out.push(rows[i]);
      i++;
    }
    if (folded.has(kind) && !placed.has(kind)) {
      out.push(folded.get(kind));
      placed.add(kind);
    }
  }
  return out;
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
    if (key === 'cost') {
      // Sorting a subscription row by cost orders it on a figure the table does
      // not print (that amount is an API-equivalent estimate, and the page
      // reports subscription work in tokens). Ordering rows by an invisible
      // number reads as no order at all, so inside the notional group "by cost"
      // falls back to the visible proxy: tokens.
      if (a.kind === 'notional' && b.kind === 'notional') {
        return (b.tokens || 0) - (a.tokens || 0);
      }
      return b.cost - a.cost;
    }
    return b.events - a.events;
  };
  return [...rows].sort((a, b) =>
    (KIND_ORDER[a.kind] - KIND_ORDER[b.kind]) || within(a, b));
}
