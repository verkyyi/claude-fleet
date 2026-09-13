// web/dist/spend.js — the one figure on this page that is money somebody paid.
//
// The top axis of the page is the BILLING RELATIONSHIP, not the product name.
// There are exactly two ways this deployment is charged — a subscription that
// bills monthly whether or not a token is spent, and metered spend that bills
// per call — and `gateway` is neither of those things: it is the channel one
// of the metered sources reports through. Putting it on the top axis beside
// two products is what made the old page read as "Claude, plus some others".
import { el } from './lib/dom.js';
import { fmtUSD } from './lib/format.js';
import { notionalCost, unpricedEvents } from './lib/cost.js';
import { spendTerms } from './lib/spend.js';

export { spendTerms };

export function renderSpend(root, summary) {
  if (!summary) { root.replaceChildren(); return; }
  const rs = summary.real_spend;
  const terms = spendTerms(rs);
  const card = el('div', { class: 'card', id: 'real-spend' },
    el('h2', {}, 'What this actually cost'));

  card.appendChild(el('p', { class: 'figure' },
    rs ? fmtUSD(rs.total) + (rs.complete ? '' : ' ≥') : '—'));
  if (terms.length) {
    card.appendChild(el('p', { class: 'terms' },
      terms.map((t) => `${t.label} ${fmtUSD(t.amount)}`).join('  +  ')));
  }

  // The notional figure sits beside the total and outside it, labelled with
  // what it is. It is the biggest number on the page and the one nobody is
  // billed; printing it without that sentence is exactly how it gets read as
  // a bill.
  const notional = notionalCost(summary);
  if (notional) {
    card.appendChild(el('p', { class: 'hint' },
      `Not part of that total: ${fmtUSD(notional)} of API-equivalent cost for subscription ` +
      `work. Nobody is billed per token on a plan — the plan is the bill.`));
  }
  if (summary.real_spend_note) card.appendChild(el('p', { class: 'hint' }, summary.real_spend_note));
  if (rs && !rs.complete) {
    card.appendChild(el('p', { class: 'hint warn' },
      'Incomplete — ' + (rs.missing || []).join('; ')));
  }
  const unpriced = unpricedEvents(summary);
  if (unpriced) {
    card.appendChild(el('p', { class: 'hint' },
      `${unpriced} request(s) have no price data, so every figure here is a lower bound.`));
  }
  root.replaceChildren(card);
}
