// web/dist/spend.js — the one figure on this page that is money somebody paid.
//
// The top axis of the page is the BILLING RELATIONSHIP, not the product name.
// There are exactly two ways this deployment is charged — a subscription that
// bills monthly whether or not a token is spent, and metered spend that bills
// per call — and `gateway` is neither of those things: it is the channel one
// of the metered sources reports through. Putting it on the top axis beside
// two products is what made the old page read as "Claude, plus some others".
//
// # Where the figure lives (issue #128)
//
// In the STICKY BAR, as a chip, and no longer in a card of its own. The card
// was 206px of the default view at 1280px whose whole content was one number,
// its terms, and a shut fold — and it stopped being on screen the moment
// anyone scrolled past it. #123 made the same move with the alert count and
// wrote the argument out in full (now.js's alertBell, styles.css's
// `.scope #alertbell`); this is the same argument applied to the other thing
// on this page a reader is here for.
//
// Two things did NOT move into the fold on the way, and they are the same two
// spend.js has always kept out of one:
//
//   * the `≥` on the figure, and
//   * the fact that the total is INCOMPLETE.
//
// Neither explains the number. Both say the number itself is LOW, and a
// knowingly-low figure shown as if it were exact is the one thing this file
// exists to prevent. So both are in the chip's SUMMARY — the part that is on
// screen with nothing opened — and the panel below carries only the working.
//
// The incomplete SENTENCE is in the panel rather than the summary, and that is
// a width fact, not a demotion: the server writes it per unpriced plan
// ("claude/pro (1 seat(s)) has no recorded price for this period; ..."), 155
// characters on this deployment's own fixture, and a sticky bar that grew to
// hold it would move --navh — which is every anchor's landing offset, and the
// one rule the bar does not bend (scope.js:119-125). What the summary carries
// instead is the word: `spend.incompleteShort`, beside the `≥`, in the warn
// colour AND in words, because a bar is where "colour is never alone"
// (styles.css:256) bites hardest.
import { el } from './lib/dom.js';
import { t } from './lib/i18n.js';
import { fmtMoney, moneyTitle, currentFx, fxAsOf } from './lib/format.js';
import { unpricedEvents } from './lib/cost.js';
import { spendTerms } from './lib/spend.js';

export { spendTerms };

// Where the explanation fold remembers whether it is open. Namespaced
// `ccquota-<thing>`, the convention every per-browser fold state on this page
// follows. (It used to cite 'ccquota-fleet' as the sibling example; #100
// removed that fold, so the convention is stated rather than pointed at.)
const FOLD_KEY = 'ccquota-spend-working';

// Whether the chip's own panel is open. Module state rather than localStorage,
// and deliberately the opposite choice from FOLD_KEY above: this is now.js's
// `bellOpen` pattern for the same reason the bell uses it. A bar fold is a
// glance, not a reading position — it should not still be hanging open over
// the page on a reader's next visit — while the working fold inside it IS a
// reading position, which is why that one is still remembered across the
// 60-second refresh that re-renders both.
let chipOpen = false;

/** renderLedgerChip draws the ledger's headline into the sticky bar.
 *
 *  Shut, it is the label, the figure, and whatever says the figure is low.
 *  Open, it is the terms and the working fold that used to sit in the card.
 *
 *  The height rule is #pulse's and it is not optional: the summary is sized to
 *  fit inside the height the bar already has, and the panel is taken out of
 *  flow, so NEITHER state moves --navh. styles.css carries both measurements.
 *
 *  Renders nothing when there is no summary at all — a query that FAILED has
 *  no honest figure, and a bar entry that quietly disappeared would report a
 *  deployment that spent nothing. That case is renderSpend's, below. */
export function renderLedgerChip(root, summary, state) {
  if (!summary) { root.replaceChildren(); return; }
  const rs = summary.real_spend;
  const terms = spendTerms(rs);

  // `—`, not a hidden chip: a summary that came back without a real_spend is an
  // absence the page should show, the same way the card used to print it.
  const figure = rs ? fmtMoney(rs.total, rs.currency) + (rs.complete ? '' : ' ≥') : '—';
  const low = !!rs && !rs.complete;
  const missing = low ? t('spend.incomplete', { missing: (rs.missing || []).join('; ') }) : '';

  // The label says WHICH PERIOD, because this figure is the selected range's
  // and nothing else on the page would say so once the card's own title
  // ("what this period actually cost") is gone. It is the page's only lifetime
  // total that is `counter.tokens` — the one #pulse is already printing two
  // slots along — and a bare money figure in a bar beside it would be read as
  // the lifetime bill.
  //
  // The span word comes from the scope state rather than the response so that
  // it cannot disagree with the segmented control a reader just pressed; a
  // BRUSHED range sets from/to and leaves `span` at whatever it was, so that
  // case says "this range" rather than naming days it no longer covers.
  const period = state && (state.from || state.to)
    ? t('spend.chip.range')
    : (state && state.span) || t('spend.chip.range');

  // Two spans, not one string, because they are not equally droppable. `.per`
  // is the period and it is what stops the figure being read as a lifetime
  // bill; `.lbl` is the verb in front of it, which a reader can infer from a
  // money figure in a ledger's own bar. styles.css drops the verb on a phone
  // and keeps the period, which is the whole reason this is two nodes.
  const said = [t('spend.title'), figure, missing].filter(Boolean).join(' · ');
  const tip = rs ? moneyTitle(rs.total, rs.currency) : '';
  const head = el('summary', { title: tip ? said + ' · ' + tip : said, 'aria-label': said },
    el('span', { class: 'lbl' }, t('spend.chip.verb')),
    el('span', { class: 'per' }, period),
    el('b', { class: 'n' }, figure),
    low ? el('span', { class: 'w' }, t('spend.incompleteShort')) : null);

  const panel = el('div', { class: 'ledger-panel' });
  // The sentence, first, and OUTSIDE the working fold below — the full text of
  // the word in the summary, in the same warn colour, before any explanation.
  if (low) panel.appendChild(el('p', { class: 'hint warn' }, missing));
  if (terms.length) {
    panel.appendChild(el('p', { class: 'terms' },
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

  // The working: up to three sentences of fx disclosure, three more from the
  // server, and the unpriced-requests caveat — around a figure whose whole job
  // is to be one number. None of it is deleted; all of it is one click further
  // away than it was, because the card that held it is gone and the fold that
  // held it is not (issue #94's principle, applied to the same sentences).
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
  if (working.length) panel.appendChild(workingFold(working));

  // `name`, so the two folds in this bar are an accordion the PLATFORM runs:
  // opening this one closes the alert bell and vice versa. Both panels hang
  // from the same corner of .scope, and two open at once would stack one over
  // the other -- an exclusive group is one attribute against a pair of
  // outside-click handlers, and it keeps the promise now.js's bell makes about
  // there being no component here (see its "# Why <details>" note).
  const det = el('details', { class: 'ledger', name: 'barfold', open: chipOpen ? '' : false },
    head, panel);
  det.addEventListener('toggle', () => { chipOpen = det.open; });
  root.replaceChildren(det);
}

/** renderSpend keeps #spend — the shell's slot in the ledger band — in work.
 *
 *  A summary query that FAILED is the one thing the chip above cannot say. Its
 *  summary is a figure, and there is no honest figure for "the request came
 *  back 500"; a bar with no money chip would report a deployment that has
 *  spent nothing, and a chip printing an error glyph would be a pill the
 *  reader has to open to learn that nothing is known.
 *
 *  So the failure is a card, here, where the ledger's card has always been.
 *  This is also what keeps #spend from becoming the dead markup embed_test.go
 *  bans (`id="footer"`): app.js writes this slot on every pass, and on this
 *  path it draws. It is the same split #123 made between #alertbell and
 *  #alerts, for the same reason and in the same shape.
 *
 *  Takes the SETTLED RESULT rather than the value, because "rejected" and
 *  "never asked for" are different states that both arrive as a missing value,
 *  and only the first of them is something to tell the reader about. */
export function renderSpend(root, result) {
  if (!result || result.status !== 'rejected') { root.replaceChildren(); return; }
  root.replaceChildren(el('div', { class: 'card', id: 'real-spend' },
    el('h2', {}, t('spend.title')),
    el('div', { class: 'empty' }, t('common.queryFailed', { error: errMsg(result.reason) }))));
}

const errMsg = (e) => (e && e.message) || String(e || '');

/** workingFold collapses the explanation behind the figure.
 *
 *  <details>, not a class that hides them: it is the one collapse the platform
 *  gives a keyboard and find-in-page for free, so a reader searching the page
 *  for "汇率" still lands on the sentence. The summary names what is inside —
 *  "how this number is worked out" — because "详情" would make opening it a
 *  guess.
 *
 *  Open state is remembered per browser, the way the fleet roster's fold is
 *  (now.js): app.js re-renders this on every 60-second refresh, and a fold
 *  that forgot would snap shut under a reader mid-sentence. It is NOT in the
 *  bar's accordion group (`name` above): it is nested inside one member of
 *  that group, and naming it would make opening the working shut the chip
 *  containing it. */
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
