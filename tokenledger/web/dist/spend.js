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

// Where the explanation fold remembers whether it is open. Namespaced like
// every other per-browser fold state on this page ('ccquota-fleet').
const FOLD_KEY = 'ccquota-spend-working';

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

  // `spend.incomplete` is the ONE sentence that stays out of the fold below,
  // and it stays out for the same reason the `≥` stays on the figure: neither
  // explains the number, both say the number itself is LOW. A card that folds
  // "this total is missing a source" is a card showing a knowingly biased
  // figure as if it were exact. Everything else here is working, and working
  // folds (issue #94).
  if (rs && !rs.complete) {
    card.appendChild(el('p', { class: 'hint warn' },
      t('spend.incomplete', { missing: (rs.missing || []).join('; ') })));
  }

  // The working: up to three sentences of fx disclosure, three more from the
  // server, and the unpriced-requests caveat — around a card whose whole job is
  // to show one number. None of it is deleted; all of it moves one click away.
  const working = [];

  // Disclosed once, in the fold under the headline: at what rate, read when,
  // and whether it is a live reading at all. pricing.GatewayCNYPerUSD's comment
  // warns that a live feed "would silently restate every historical figure each
  // morning" — this line is the difference between restating them and saying
  // so, and `≈` on the figure itself is what survives the fold being shut.
  const fx = currentFx();
  if (fx) {
    const bits = [t('fx.rateLine', {
      rate: fx.rate.toFixed(4), base: fx.base, target: fx.target, asOf: fxAsOf(),
    })];
    if (fx.fallback) bits.push(t('fx.fallbackLine', { source: fx.source }));
    else if (fx.stale) bits.push(t('fx.staleLine', { asOf: fxAsOf() }));
    bits.push(t('fx.billedIn'));
    working.push(el('p', { class: 'hint' + (fx.fallback ? ' warn' : '') }, bits.join(' ')));
  }
  // Server-side prose (internal/api/i18n.go), reproduced verbatim: it is what
  // stops a reader taking the notional figure for money somebody paid. Only
  // where it sits changed.
  if (summary.real_spend_note) working.push(el('p', { class: 'hint' }, summary.real_spend_note));
  const unpriced = unpricedEvents(summary);
  if (unpriced) {
    working.push(el('p', { class: 'hint' }, t('spend.unpriced', { n: unpriced })));
  }
  if (working.length) card.appendChild(workingFold(working));

  root.replaceChildren(card);
}

/** workingFold collapses the explanation behind the figure.
 *
 *  <details>, not a class that hides them: it is the one collapse the platform
 *  gives a keyboard and find-in-page for free, so a reader searching the page
 *  for "汇率" still lands on the sentence. The summary names what is inside —
 *  "how this number is worked out" — because "详情" would make opening it a
 *  guess.
 *
 *  Open state is remembered per browser, the way the fleet roster's fold is
 *  (now.js): app.js re-renders this card on every 60-second refresh, and a fold
 *  that forgot would snap shut under a reader mid-sentence. */
function workingFold(kids) {
  let open = false;
  try { open = localStorage.getItem(FOLD_KEY) === '1'; } catch {}
  const det = el('details', { class: 'working', open: open ? '' : false },
    el('summary', {}, t('spend.working')), ...kids);
  det.addEventListener('toggle', () => {
    try { localStorage.setItem(FOLD_KEY, det.open ? '1' : '0'); } catch {}
  });
  return det;
}
