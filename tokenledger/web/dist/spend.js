// web/dist/spend.js — the one figure on this page that is money somebody paid.
//
// The top axis of the page is the BILLING RELATIONSHIP, not the product name.
// There are exactly two ways this deployment is charged — a subscription that
// bills monthly whether or not a token is spent, and metered spend that bills
// per call — and `gateway` is neither of those things: it is the channel one
// of the metered sources reports through. Putting it on the top axis beside
// two products is what made the old page read as "Claude, plus some others".
import { el } from './lib/dom.js';
import { t } from './lib/i18n.js';
import { fmtMoney, moneyTitle, currentFx, fxAsOf } from './lib/format.js';
import { unpricedEvents } from './lib/cost.js';
import { spendTerms } from './lib/spend.js';

export { spendTerms };

export function renderSpend(root, summary) {
  if (!summary) { root.replaceChildren(); return; }
  const rs = summary.real_spend;
  const terms = spendTerms(rs);
  const card = el('div', { class: 'card', id: 'real-spend' },
    el('h2', {}, t('spend.title')));

  const figure = el('p', { class: 'figure' },
    rs ? fmtMoney(rs.total, rs.currency) + (rs.complete ? '' : ' ≥') : '—');
  if (rs) {
    const tip = moneyTitle(rs.total, rs.currency);
    if (tip) figure.title = tip;
  }
  card.appendChild(figure);
  if (terms.length) {
    card.appendChild(el('p', { class: 'terms' },
      terms.map((term) => `${term.label} ${fmtMoney(term.amount, term.currency)}`).join('  +  ')));
  }

  // The API-equivalent figure is deliberately NOT here, and not anywhere else
  // on this page.
  //
  // It used to sit right under this total, labelled as not-a-bill. Measured on
  // this deployment: real spend over 30 days was $39.56 and the API-equivalent
  // figure for the same window was $73,270 — 1,852x larger, in a comparable
  // type size, immediately below. No label survives that contrast; the number a
  // reader carries away from a page is the biggest one on it. A ledger whose
  // largest figure is money nobody was charged is not a ledger.
  //
  // The figure still exists in the API (`cost_notional`) and still prices
  // subscription work for `plan --spend`'s value-for-money ratio. What changed
  // is that this page no longer prints it: subscription work is reported in
  // TOKENS, which is the unit it is actually measured in, and the money owed for
  // it is the plan price — a term in the total above.
  // Disclosed once, under the headline: at what rate, read when, and whether
  // it is a live reading at all. pricing.GatewayCNYPerUSD's comment warns that a
  // live feed "would silently restate every historical figure each morning" —
  // this line is the difference between restating them and saying so.
  const fx = currentFx();
  if (fx) {
    const bits = [t('fx.rateLine', {
      rate: fx.rate.toFixed(4), base: fx.base, target: fx.target, asOf: fxAsOf(),
    })];
    if (fx.fallback) bits.push(t('fx.fallbackLine', { source: fx.source }));
    else if (fx.stale) bits.push(t('fx.staleLine', { asOf: fxAsOf() }));
    bits.push(t('fx.billedIn'));
    card.appendChild(el('p', { class: 'hint' + (fx.fallback ? ' warn' : '') }, bits.join(' ')));
  }
  if (summary.real_spend_note) card.appendChild(el('p', { class: 'hint' }, summary.real_spend_note));
  if (rs && !rs.complete) {
    card.appendChild(el('p', { class: 'hint warn' },
      t('spend.incomplete', { missing: (rs.missing || []).join('; ') })));
  }
  const unpriced = unpricedEvents(summary);
  if (unpriced) {
    card.appendChild(el('p', { class: 'hint' }, t('spend.unpriced', { n: unpriced })));
  }
  root.replaceChildren(card);
}
