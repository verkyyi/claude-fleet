// web/dist/consumption.js — every model this deployment ran, and what it cost.
//
// One table, keyed on (provider, model). `gateway` does not appear as a row:
// it is the channel a metered source reports through, not something that ran
// a model. It shows up in exactly two places on this page — the billing
// column's tooltip, and collection health further down.
//
// This table is the page's PRIMARY model reading (issue #103). (provider,
// model) is the only key under which a per-model cost is safe: one model id
// reached through two upstreams is two contracts at two prices, which is what
// commit 321e027 fixed. The usage band's "by model" breakdown keys on `model`
// alone, so it ranks and compares periods while this one is what the money is
// actually attributed to.
//
// The provider/source distinction above is no longer only in this comment:
// `consumption.hint` says it on the card, and `breakdown.sourceNote` says the
// mirror of it on the breakdown card whenever that card is grouped by source.
// It had to reach the page, because the two axes read as one cut to anyone who
// has not been shown the difference.
import { el, $ } from './lib/dom.js';
import { fmtInt, fmtUSD } from './lib/format.js';
import { bucketCost, consumptionRows, foldTail, scopeKey, sortRows } from './lib/rows.js';
import { CSORTS } from './lib/state.js';
import { KIND_LABEL } from './lib/cost.js';
import { t } from './lib/i18n.js';

const SORT_LABEL = { cost: t('sort.cost'), tokens: t('sort.tokens'), events: t('sort.events') };

// What the row's kind means to somebody reading a bill, rather than what the
// cost column calls it internally.
const BILLING = { billed: t('billing.billed'), notional: t('billing.notional'), unknown: t('billing.unknown') };

/** The cost cell, from a bucket's OWN cost fold. One function so the provider
 *  row and its model sub-table cannot disagree about what a row cost.
 *
 *  An amount on a notional row would be an API-equivalent estimate for work
 *  billed by the month. Absent, not zero — the same nil-not-zero rule the
 *  tokens column keeps for rows that count no tokens at all. */
const costCell = (c) => (c.kind === 'notional'
  ? '—'
  : (c.unpriced ? '≥ ' + fmtUSD(c.cost) : fmtUSD(c.cost)));

function sortControl(state, app) {
  const seg = el('div', { class: 'seg' });
  for (const k of CSORTS) {
    const b = el('button', { type: 'button' }, t('consumption.sortBy', { what: SORT_LABEL[k] }));
    b.setAttribute('aria-pressed', String(state.csort === k));
    b.addEventListener('click', () => app.setState({ ...state, csort: k }));
    seg.appendChild(b);
  }
  return seg;
}

/** modelRows renders one provider's models underneath its row, fetched on
 *  demand. Scoped by ?provider=, so the figures are that contract's own —
 *  including the blank contract, which is why the key goes through scopeKey:
 *  a bare `?provider=` reads as "no constraint" at the other end and answered
 *  the "declares no upstream" row with every upstream on the hub (issue #134). */
async function expand(tr, row, state, app, range) {
  if (tr.dataset.loaded) { tr.hidden = !tr.hidden; return; }
  tr.dataset.loaded = '1';
  tr.hidden = false;
  const cell = $('td', tr);
  cell.replaceChildren(el('span', { class: 'hint' }, t('common.loading')));
  try {
    const qs = new URLSearchParams({
      account: state.sub || 'all', by: 'model', limit: '50',
      provider: scopeKey(row.provider),
      since: new Date(range.from).toISOString(), until: new Date(range.to).toISOString(),
    });
    const d = await app.api('/v1/usage?' + qs.toString());
    const models = (d.buckets || []).filter((b) => b.key);
    if (!models.length) { cell.replaceChildren(el('span', { class: 'hint' }, t('consumption.noModels'))); return; }
    const modelsTable = el('table', { class: 'sub' },
      el('tbody', {}, models.map((b) => el('tr', {},
        el('td', {}, b.key),
        el('td', { class: 'num' }, b.tokens ? fmtInt(b.tokens) : '—'),
        // This model's own cost split, not the parent row's first source: one
        // upstream can front two sources, and pricing the sub-rows off whichever
        // sorted first reported a metered charge as $0.00 (issue #134).
        el('td', { class: 'num' }, costCell(bucketCost(b)))))));
    cell.replaceChildren(modelsTable);
  } catch (err) {
    cell.replaceChildren(el('span', { class: 'hint' }, t('consumption.modelsFailed', { error: err.message })));
  }
}

export function renderConsumption(root, result, state, app, range) {
  if (!result || result.status !== 'fulfilled') {
    root.replaceChildren(el('div', { class: 'card' }, el('h2', {}, t('consumption.title')),
      el('p', { class: 'empty' }, result ? t('consumption.couldNotLoad', { error: (result.reason && result.reason.message) }) : '')));
    return;
  }
  const d = result.value;
  // Fold AFTER sorting, so each kind's tail row lands at the end of its own run
  // rather than being ordered among the rows it replaces.
  const rows = foldTail(sortRows(consumptionRows(d.buckets), state.csort));
  const card = el('div', { class: 'card', id: 'consumption-table' },
    el('h2', {}, t('consumption.title')),
    el('p', { class: 'hint' }, t('consumption.hint')),
    sortControl(state, app));

  if (!rows.length) {
    card.appendChild(el('p', { class: 'empty' }, t('consumption.empty')));
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
      el('td', { title: t('consumption.costKindTip', { kind: KIND_LABEL[r.kind] || r.kind }) }, BILLING[r.kind]),
      el('td', { class: 'num' }, fmtInt(r.events)),
      el('td', { class: 'num' }, r.tokens == null ? '—' : fmtInt(r.tokens)),
      el('td', { class: 'num' }, costCell(r)));
    $('button', tr).addEventListener('click', () => expand(detail, r, state, app, range));
    body.append(tr, detail);
  }
  card.appendChild(el('div', { class: 'scroll' },
    el('table', {},
      el('thead', {}, el('tr', {},
        el('th', {}, t('consumption.col.provider')), el('th', {}, t('consumption.col.billing')),
        el('th', { class: 'num' }, t('consumption.col.requests')), el('th', { class: 'num' }, t('consumption.col.tokens')),
        el('th', { class: 'num' }, t('consumption.col.cost')))),
      body)));

  // Two different absences share the blank row, and neither is a vendor.
  if (d.provider_note) card.appendChild(el('p', { class: 'hint' }, d.provider_note));
  root.replaceChildren(card);
}
