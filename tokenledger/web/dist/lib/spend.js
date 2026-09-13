// web/dist/lib/spend.js — reading real spend as its named terms.
//
// Pure, like everything else under lib/: no DOM, so it is testable under
// `node --test`. The rendering lives in ../spend.js.
//
// Real spend has four terms and they are kept apart on purpose. Subscription
// money bills monthly whether or not a token is spent; gateway money is
// metered per call; vendor-bill money is read off an invoice for paths no
// gateway can see; voice money is reported by the calling application for the
// WebSocket tier no proxy sits in. All four are money somebody paid — that is
// why they may be summed at all — but the FIELD NAMES are claims about
// provenance, and folding one into another is a claim the figure cannot
// support.

const LABEL = {
  subscription: 'subscriptions',
  gateway: 'metered · via the gateway',
  vendor_bill: 'metered · billed by the vendor directly',
  // Normally absent, and that is the source working as designed: voice rows
  // carry usage and attribution, not money, so the spend behind them reaches
  // this page under vendor_bill instead. A figure here means a collector
  // priced those calls — safe only if the matching billing item left the bill
  // collector's include list, or the same money is standing in two terms.
  voice: 'metered · reported by the calling application',
};

/** spendTerms lists the non-zero terms of real spend, in display order.
 *
 *  A zero term is dropped rather than shown as $0.00: this deployment either
 *  has that kind of charge or it does not, and a row of zero per term teaches a
 *  reader nothing while making the real ones harder to find. */
export function spendTerms(rs) {
  if (!rs) return [];
  return ['subscription', 'gateway', 'vendor_bill', 'voice']
    .map((key) => ({ key, label: LABEL[key], amount: rs[key] || 0 }))
    .filter((t) => t.amount !== 0);
}
