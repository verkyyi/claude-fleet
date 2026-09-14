// web/dist/consumption.js — every model this deployment ran, and what it cost.
//
// One table, keyed on (provider, model). `gateway` does not appear as a row:
// it is the channel a metered source reports through, not something that ran
// a model. It shows up in exactly two places on this page — the billing
// column's tooltip, and collection health further down.
import { el, $ } from './lib/dom.js';
import { fmtInt, fmtUSD, fmtCost } from './lib/format.js';
import { consumptionRows, foldTail, sortRows } from './lib/rows.js';
import { CSORTS } from './lib/state.js';
import { costOf, KIND_LABEL } from './lib/cost.js';

const SORT_LABEL = { cost: 'cost', tokens: 'tokens', events: 'requests' };

// What the row's kind means to somebody reading a bill, rather than what the
// cost column calls it internally.
const BILLING = { billed: 'metered', notional: 'subscription', unknown: 'unclassified' };

function sortControl(state, app) {
  const seg = el('div', { class: 'seg' });
  for (const k of CSORTS) {
    const b = el('button', { type: 'button' }, 'by ' + SORT_LABEL[k]);
    b.setAttribute('aria-pressed', String(state.csort === k));
    b.addEventListener('click', () => app.setState({ ...state, csort: k }));
    seg.appendChild(b);
  }
  return seg;
}

/** modelRows renders one provider's models underneath its row, fetched on
 *  demand. Scoped by ?provider=, so the figures are that contract's own. */
async function expand(tr, row, state, app, range) {
  if (tr.dataset.loaded) { tr.hidden = !tr.hidden; return; }
  tr.dataset.loaded = '1';
  tr.hidden = false;
  const cell = $('td', tr);
  cell.replaceChildren(el('span', { class: 'hint' }, 'loading…'));
  try {
    const qs = new URLSearchParams({
      account: state.sub || 'all', by: 'model', limit: '50',
      provider: row.provider,
      since: new Date(range.from).toISOString(), until: new Date(range.to).toISOString(),
    });
    const d = await app.api('/v1/usage?' + qs.toString());
    const models = (d.buckets || []).filter((b) => b.key);
    if (!models.length) { cell.replaceChildren(el('span', { class: 'hint' }, 'no models in this period')); return; }
    const t = el('table', { class: 'sub' },
      el('tbody', {}, models.map((b) => {
        const c = costOf(b, row.sources[0] || 'gateway');
        return el('tr', {},
          el('td', {}, b.key),
          el('td', { class: 'num' }, b.tokens ? fmtInt(b.tokens) : '—'),
          el('td', { class: 'num' }, fmtCost(c)));
      })));
    cell.replaceChildren(t);
  } catch (err) {
    cell.replaceChildren(el('span', { class: 'hint' }, 'could not load models: ' + err.message));
  }
}

export function renderConsumption(root, result, state, app, range) {
  if (!result || result.status !== 'fulfilled') {
    root.replaceChildren(el('div', { class: 'card' }, el('h2', {}, 'Consumption'),
      el('p', { class: 'empty' }, result ? 'Could not load: ' + (result.reason && result.reason.message) : '')));
    return;
  }
  const d = result.value;
  // Fold AFTER sorting, so each kind's tail row lands at the end of its own run
  // rather than being ordered among the rows it replaces.
  const rows = foldTail(sortRows(consumptionRows(d.buckets), state.csort));
  const card = el('div', { class: 'card', id: 'consumption-table' },
    el('h2', {}, 'Consumption'),
    el('p', { class: 'hint' },
      'Every model that ran, by the upstream that served it. Subscription rows show no amount: ' +
      'a plan bills monthly, not per request, so its cost belongs to the plan rather than to any ' +
      'row here. Their usage is the token count.'),
    sortControl(state, app));

  if (!rows.length) {
    card.appendChild(el('p', { class: 'empty' }, 'No usage in this selection.'));
    root.replaceChildren(card);
    return;
  }

  const body = el('tbody');
  for (const r of rows) {
    // The folded row stands for several providers at once, so there is no single
    // ?provider= to expand it by. It renders as plain text rather than a button
    // that would look clickable and do nothing.
    if (r.provider === null) {
      body.append(el('tr', { class: 'folded' },
        el('td', {}, r.providerLabel),
        el('td', {}, BILLING[r.kind]),
        el('td', { class: 'num' }, fmtInt(r.events)),
        el('td', { class: 'num' }, r.tokens == null ? '—' : fmtInt(r.tokens)),
        el('td', { class: 'num' }, '—')));
      continue;
    }
    // NOT class="detail": that name is taken by the session overlay, which is
    // position:fixed — reusing it turns this row into a floating panel.
    const detail = el('tr', { class: 'models', hidden: true }, el('td', { colspan: '5' }));
    const tr = el('tr', { class: 'expandable' },
      el('td', {}, el('button', { type: 'button', class: 'link' }, r.providerLabel)),
      el('td', { title: `cost kind: ${KIND_LABEL[r.kind] || r.kind}` }, BILLING[r.kind]),
      el('td', { class: 'num' }, fmtInt(r.events)),
      el('td', { class: 'num' }, r.tokens == null ? '—' : fmtInt(r.tokens)),
      // An amount here would be an API-equivalent estimate for work billed by
      // the month. Absent, not zero — the same nil-not-zero rule the tokens
      // column keeps for rows that count no tokens at all.
      el('td', { class: 'num' }, r.kind === 'notional'
        ? '—'
        : (r.unpriced ? '≥ ' + fmtUSD(r.cost) : fmtUSD(r.cost))));
    $('button', tr).addEventListener('click', () => expand(detail, r, state, app, range));
    body.append(tr, detail);
  }
  card.appendChild(el('div', { class: 'scroll' },
    el('table', {},
      el('thead', {}, el('tr', {},
        el('th', {}, 'Provider'), el('th', {}, 'Billing'),
        el('th', { class: 'num' }, 'Requests'), el('th', { class: 'num' }, 'Tokens'),
        el('th', { class: 'num' }, 'Cost'))),
      body)));

  // Two different absences share the blank row, and neither is a vendor.
  if (d.provider_note) card.appendChild(el('p', { class: 'hint' }, d.provider_note));
  root.replaceChildren(card);
}
