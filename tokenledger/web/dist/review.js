// web/dist/review.js — the Review view: timeline+brush, KPI strip, findings,
// two group-by breakdowns, efficiency, an hour×weekday heatmap, wall history,
// and the sessions table. Everything here is scoped to the brush SELECTION
// (`sel`), the subscription and the chips; card 1 is the one exception that
// draws over the whole `span` EXTENT so the brush has something to drag
// across.
//
// Backend field names were read from internal/api/{review,query}.go and
// internal/store/rollup_query.go in the sibling ccquota worktree (read-only)
// rather than guessed — see task-12-report.md for the two adapter-layer
// notes (stack shape, 6h bucket-key parsing) that fell out of that reading.
import { apiQuery, withChip, GROUPS } from './lib/state.js';
import { SKIPPED } from './lib/seq.js';
import { extent, resolve } from './lib/brush.js';
import { foldHourly, sentence } from './lib/fold.js';
import { fmtInt, fmtUSD, fmtMoney, fmtCost, fmtFull, fmtPct, fmtDur, delta, fmtSigned,
         scaleMax, shareText, shortProject, DELTA_CAP_PCT } from './lib/format.js';
import { SOURCES, KIND_LABEL, kindOf, costOf, activeSources, costLine,
         billedCostLine, notionalSourcesAcross, fmtSourceCost } from './lib/cost.js';
import { el, escapeHTML } from './lib/dom.js';
import { ownerLine, splitMuted } from './lib/findings.js';
import { muteControls } from './lib/mute.js';
import { createScopeControls } from './scope.js';
import * as C from './charts.js';
import { pricingCoverage } from './lib/providers.js';
import { t } from './lib/i18n.js';

// Review's scope-controls widget: subscription select + span segmented
// control + chips row (Task 15 nav restructure). Mounted on the Timeline
// card (card 1, below) rather than the sticky bar — the Timeline already
// owns the time range via its brush, so the span control that scales it
// belongs right next to it. Built once, module-eval time; kept current by
// app.js's route() calling scope.js's renderScopeControls on every
// hashchange, independent of this view's own async load() cycle — see
// now.js's identical `nowScope` for the fuller version of this comment.
const reviewScope = createScopeControls({ span: true });

// GRAN mirrors brush.js's SPANS bucket sizes (7d→1h, 30d→6h, 90d→1d) — the
// two must agree, since card 1's `bucket`/`extent.n` come from brush.js while
// its data comes from asking the API for this same granularity.
const GRAN = { '7d': 'hour', '30d': '6h', '90d': 'day' };
// DIM_TO_API translates a URL/chip dimension name to the `by=`/filter query
// value the Go API actually expects (internal/api/scope.go, store.Dimension).
const DIM_TO_API = { project: 'project', login: 'user', machine: 'endpoint', model: 'model', branch: 'branch', team: 'team', source: 'source' };
// Same keys the chips row reads (scope.js), so a dimension is called one thing
// on the group-by control and the chip it produces.
const DIM_LABEL = { project: t('dim.project'), login: t('dim.login'), machine: t('dim.machine'), model: t('dim.model'), branch: t('dim.branch'), team: t('dim.team'), source: t('dim.source') };
// The per-person page, which this binary has routed (internal/api/server.go)
// and served (internal/api/user.go) since it was added, and which /access has
// been listing as a door the whole time — while the dashboard linked to it
// from nowhere, so the only way in was to type the URL (issue #99).
//
// Built here, not by the server: the login IS the path segment, and
// `serveUserPage` takes it straight off the path, so anything that can
// contain a slash or a `#` has to be encoded or it becomes a different route.
// A relative path deliberately — the page is served by the same hub as this
// dashboard, on whatever host and port and behind whatever prefix the reader
// reached it on, and an absolute URL would have to guess all three.
export const userHref = (login) => `/u/${encodeURIComponent(login)}`;
// kpiTile's `tone` only special-cases the literal string 'neutral' (its own
// default) — anything else gets the up=red/down=green colouring. Named here
// rather than passed as an arbitrary truthy string so every "more usage is
// worse" tile says so the same way. Sessions counts as one of these too
// (more concurrent/total sessions reads the same as more turns or more
// tokens — it's usage volume, not a ratio); cache hit and subagent share
// stay 'neutral' since a higher ratio there is not inherently bad.
const TONE_MORE_IS_WORSE = 'volume';

let brushTimer = 0;

/* ---------------------------------------------------------------- helpers */

function errMsg(reason) { return (reason && reason.message) || String(reason); }
function errCard(title, result) {
  return el('div', { class: 'card' }, el('h2', {}, title),
    el('div', { class: 'empty' }, t('common.queryFailed', { error: errMsg(result.reason) })));
}
function section(root, id) {
  let s = root.querySelector('#' + id);
  if (!s) { s = el('section', { id }); root.appendChild(s); }
  return s;
}
const ratio = (a, b) => (b > 0 ? a / b : 0);
const fmtMD = (ms) => new Date(ms).toISOString().slice(5, 10);

// bucketISO turns one of the three raw bucket-key shapes the rollup emits
// (day 'YYYY-MM-DD', 6h 'YYYY-MM-DDTHH', hour 'YYYY-MM-DDTHH:00' — see
// internal/api/history.go's bucketKey) into a full RFC3339 string. Driven by
// the known granularity rather than the key's length: lib/buckets.js's
// `bucketMs` does read all three lengths (it has to — it is handed keys from
// callers that never normalized), but a granularity we already know beats a
// shape we have to guess at, and normalizing once here also gives every
// downstream reader (`ms`, the table, the chart) one key format.
function bucketISO(key, gran) {
  if (gran === 'day') return key + 'T00:00:00Z';
  if (gran === '6h') return key + ':00:00Z';
  return key + ':00Z';
}

// normalizeSeries adapts one /v1/history response's `series` to what
// charts.js's `timeline` actually reads: a full-ISO `key` (see bucketISO
// above).
//
// It used to also fold `stack=model` into a name→tokens map, because the
// backend's `Series.Stack` is an ARRAY of Bucket in `stack_models` order and
// not the map the chart helper wants. That translation is gone with the stack
// itself (issue #103) — the timeline no longer asks for one. charts.js's
// `timeline` still ACCEPTS a stack, which is the chart library's contract
// rather than this page's; nothing here hands it one.
function normalizeSeries(rawSeries, gran) {
  return (rawSeries || []).map((s) => {
    const iso = bucketISO(s.key, gran);
    return {
      // `cost` travels as the per-source split all the way to the tooltip.
      // It used to be a single cost_usd, which is the shape that made a
      // blended figure the path of least resistance.
      key: iso, ms: Date.parse(iso), events: s.events, tokens: s.tokens, cost: s.cost,
      unpriced_events: s.unpriced_events, sidechain_tokens: s.sidechain_tokens, raw: s,
    };
  });
}

// applyFindingScope is a finding's "apply →" action: add every chip in its
// `scope` (already keyed by chip/dim name — internal/findings/findings.go's
// Finding.Scope doc comment) and, for the two kinds that point at a specific
// card, scroll to it. Deliberately NOT an `<a href="#sessions">` — the app's
// own routing reads `location.hash` as view state (lib/state.js's `parse`),
// so a bare hash-fragment navigation would reset the whole page to the Now
// view instead of scrolling.
function applyFindingScope(state, app, f) {
  let next = state;
  for (const [k, v] of Object.entries(f.scope || {})) next = withChip(next, k, v);
  app.setState(next);
  if (f.link === '#sessions' || f.link === '#wall-history') {
    const id = f.link.slice(1);
    requestAnimationFrame(() => {
      const t = document.getElementById(id);
      if (t) t.scrollIntoView({ behavior: 'smooth', block: 'start' });
    });
  }
}

/* -------------------------------------------------------- card 1: timeline */

// timelineCard ALWAYS builds the card shell (title, hint, reviewScope.el)
// before branching on the fetch's outcome, and both branches append to that
// SAME card element. This is deliberate (Task 15 fix round): reviewScope.el
// is the persistent scope-controls widget Review mounts on this card (see
// the module comment above and scope.js's createScopeControls) -- if a
// rejected `/v1/history` short-circuited to a wholly separate error card the
// way errCard()'s other three callers do, replaceChildren() at this card's
// call site would detach the subscription/span/chips widget from the live
// DOM along with the rest of the card, stranding the viewer with no way to
// change scope until the URL is hand-edited. Building the shell first and
// branching only on what comes AFTER it means the widget survives a failed
// fetch exactly like it survives a successful one.
function timelineCard(result, ctx, state, app) {
  const card = el('div', { class: 'card' }, el('h2', {}, t('timeline.title')),
    el('p', { class: 'hint' }, t('timeline.hint')),
    reviewScope.el);

  if (result.status === 'rejected') {
    card.appendChild(el('div', { class: 'empty' }, t('common.queryFailed', { error: errMsg(result.reason) })));
    return card;
  }

  const { ext, sel, gran } = ctx;
  const data = result.value;
  // One bar per bucket, not six stacked bands (issue #103). This card is the
  // page's SELECTOR -- the brush below decides the window every other card
  // reports on -- and its question is "when was work running". Stacking it by
  // model made the selector also answer "which model", which is breakdown
  // card 2's question 400px further down, drawn there with numbers, a share
  // and a previous-period mark. The stack said the same thing in the one
  // notation a ranking reads worst: coloured bands whose top-6 membership
  // re-ranks as the brush moves.
  const norm = normalizeSeries(data.series, gran);
  const tSeries = norm.map((n) => ({ key: n.key, tokens: n.tokens, events: n.events, cost: n.cost, unpriced_events: n.unpriced_events }));

  const captionText = (s) => {
    const to = s.to == null ? ext.end : s.to;
    const len = to - s.from;
    return t('timeline.caption', { from: fmtMD(s.from), to: fmtMD(to), len: fmtDur(len) });
  };
  const caption = el('p', { class: 'caption' }, captionText({ from: sel.from, to: sel.live ? null : sel.to }));

  const onBrush = (brushSel, { final }) => {
    caption.textContent = captionText(brushSel);
    if (!final) return;
    clearTimeout(brushTimer);
    // Read app.state at fire time, not the `state` this card was built from:
    // up to 250ms can pass before this fires, and another change (a chip
    // removed, the subscription switched) may have landed a fresh state in
    // that window. Spreading the stale captured `state` here would silently
    // revert it -- the race this whole redesign exists to kill, reintroduced
    // in a narrower window.
    brushTimer = setTimeout(() => app.setState({ ...app.state, from: brushSel.from, to: brushSel.to }), 250);
  };

  const chart = C.timeline(tSeries, {
    bucket: ext.bucket, extent: ext,
    selection: { from: sel.from, to: sel.live ? null : sel.to },
    onBrush,
  });
  chart.appendChild(caption);

  const table = C.bucketTable(data.series || [], t('timeline.bucket'));
  const wrap = el('div', {});
  C.withTable(wrap, chart, table, 'review-timeline');
  card.appendChild(wrap);
  return card;
}

/* -------------------------------------------------------------- card 2: kpis */

function kpisCard(result) {
  if (result.status === 'rejected') return errCard(t('kpis.title'), result);
  const d = result.value, p = d.prev || {};

  const cacheHit = ratio(d.cache_read_tokens, d.cache_read_tokens + d.input_tokens + d.cache_create_tokens);
  const prevCacheHit = ratio(p.cache_read_tokens || 0, (p.cache_read_tokens || 0) + (p.input_tokens || 0) + (p.cache_create_tokens || 0));
  // There is no "$ per 1M output" TILE here any more (issue #93). The rate is
  // only meaningful within ONE billed source, and this deployment's default
  // scope spans several subscription sources — so the tile rendered a literal
  // '—' on every default load and only ever spoke when a source chip was on.
  // The same formula still runs, per model and with its denominator visible,
  // in the efficiency card's "$ per 1M output tokens, by model" list.
  const subShare = ratio(d.sidechain_tokens, d.tokens);
  const prevSubShare = ratio(p.sidechain_tokens || 0, p.tokens || 0);

  // One tile per source that ran, each labelled with the kind of money it is,
  // and NO combined spend tile. There used to be a single "spend (notional)"
  // figure summing whatever sources the scope contained; once a pay-per-call
  // source exists that number is an estimate and an invoice added together,
  // and it looks exactly as plausible as a correct one.
  const provenance = {};
  (d.pricing || []).forEach((pr) => { provenance[pr.source] = pr; });
  // No fallback to ['claude']. An empty scope is an empty scope; inventing a
  // Claude column for it is how this page came to read as Claude-first in the
  // first place.
  // BILLED sources only. A "claude spend" tile carried an API-equivalent
  // estimate of money nobody is charged, in the same tile shape, next to the
  // gateway's real invoice — the two looked equally like a bill because nothing
  // about a tile says which kind of money it holds. Subscription work is
  // reported in tokens on this page; what it COSTS is the plan price, which is a
  // term in the real-spend tile beside these.
  const sourceTiles = activeSources(d).filter((src) => kindOf(src) === 'billed').map((src) => {
    const c = costOf(d, src), pc = costOf(p, src);
    const tile = C.kpiTile({
      id: 'kpi-spend-' + src,
      label: t('kpis.spendTile', { source: src, kind: KIND_LABEL[kindOf(src)] }),
      value: fmtCost(c),
      delta: c.unpriced_events || pc.unpriced_events ? null : delta(c.cost_usd, pc.cost_usd),
      tone: TONE_MORE_IS_WORSE,
    });
    const pr = provenance[src];
    tile.title = [
      pr ? t('kpis.ratesAsOf', { date: pr.rates_as_of || t('kpis.ratesUnstated'), note: pr.note }) : null,
      c.unpriced_events > 0
        ? t('kpis.unpricedTip', { n: fmtFull(c.unpriced_events), source: src })
        : null,
    ].filter(Boolean).join('\n\n');
    return tile;
  });

  // There is no "real spend" TILE here either (issue #93). `real_spend.total`
  // already has a card of its own -- spend.js's `#real-spend`, the page
  // headline -- and app.js hands BOTH readers the same `results[SUMMARY_INDEX]`
  // object, so the tile and the headline were the same field of the same
  // response rendered twice on one screen. Being the only tile with no delta
  // was the tell: it never had a second thing to say.

  const card = el('div', { class: 'card' }, el('h2', {}, t('kpis.title')),
    el('p', { class: 'hint' }, t('kpis.hint')));
  if (d.pricing_note) card.appendChild(el('p', {class:'hint'}, d.pricing_note));
  if ((d.cost_unclassified || []).length) card.appendChild(el('p', {class:'hint'},
    t('kpis.unclassified', { list: d.cost_unclassified.map((c) => `${c.source} ${fmtUSD(c.cost_usd)}`).join(', ') })));
  // ONE collapsible for all the pricing METADATA, not four stacked blocks
  // (issue #93). Provenance, subscription spend, coverage and the unpriced
  // reasons all answer the same question -- "where does this number come from,
  // and how much of it is even priced" -- and they were four separate things
  // between the card's title and its actual tiles, so the reader scrolled past
  // ~40 lines of apparatus to reach the measurements.
  //
  // Folded, NOT dropped: coverage is how a reader decides whether to trust the
  // figures at all, so the percentage stays in the summary line, readable with
  // the fold shut. Only the detail behind it moves out of the way. Same
  // treatment the ledger card gives its own provenance.
  const coverage = pricingCoverage(d);
  const meta = [];
  // Provenance per source: which rate table, reviewed when, and which kind of
  // money the figure is. One date printed once for the whole card could only
  // ever be right about one source.
  if ((d.pricing || []).length) meta.push(
    el('h3', {}, t('kpis.provenance')),
    el('table', {}, el('thead', {}, el('tr', {}, el('th', {}, t('kpis.col.source')), el('th', {}, t('kpis.col.kind')), el('th', {}, t('kpis.col.ratesAsOf')), el('th', {}, t('kpis.col.basis')))),
      el('tbody', {}, d.pricing.map((pr) => el('tr', {},
        el('td', {}, pr.source), el('td', {}, KIND_LABEL[pr.kind] || pr.kind),
        el('td', {}, pr.rates_as_of || '—'), el('td', {}, pr.note))))));
  if ((d.subscription_spend || []).length) meta.push(
    el('h3', {}, t('kpis.subSpend')),
    el('p', {class:'hint'}, d.real_spend_note || ''),
    el('table', {}, el('thead', {}, el('tr', {}, el('th', {}, t('kpis.col.sourcePlan')), el('th', {}, t('kpis.col.seats')), el('th', {}, t('kpis.col.months')), el('th', {}, t('kpis.col.amount')))),
      el('tbody', {}, d.subscription_spend.map((sp) => el('tr', {},
        el('td', {}, `${sp.source} / ${sp.plan}`), el('td', {}, fmtFull(sp.seats)),
        el('td', {}, (sp.months || 0).toFixed(2)),
        // Each plan states its own currency -- store.SubscriptionSpend refuses
        // to fold two of them into one row, so a row is never mixed.
        el('td', {}, sp.priced ? fmtMoney(sp.amount, sp.currency) : t('kpis.noRecordedPrice')))))));
  meta.push(el('p', {class:'hint'}, t('kpis.coverageHint', {
    priced: fmtFull(coverage.priced), total: fmtFull(coverage.total), unpriced: fmtFull(coverage.unpriced) })));
  if (d.unpriced_reasons?.length) meta.push(
    el('h3', {}, t('kpis.whyUnpriced', { n: fmtFull(coverage.unpriced) })),
    el('table', {}, el('thead', {}, el('tr', {}, el('th', {}, t('kpis.col.sourceModel')), el('th', {}, t('kpis.col.reason')), el('th', {}, t('kpis.col.requests')))),
      el('tbody', {}, d.unpriced_reasons.map((r) => el('tr', {}, el('td', {}, `${r.source} / ${r.model || t('common.unknownTime')}`), el('td', {}, r.reason), el('td', {}, fmtFull(r.events)))))));
  card.appendChild(el('details', {class:'unpriced-reasons'},
    el('summary', {}, t('kpis.coverage', { pct: coverage.percent })), ...meta));
  // With the Claude fallback gone, a scope that ran nothing has no spend tile
  // at all. Say so, rather than leaving a KPI row of zeroes that looks like a
  // measurement.
  if (!sourceTiles.length) card.appendChild(el('p', { class: 'hint' }, t('kpis.noSpend')));
  if (d.cache_write_known_events > 0) card.appendChild(el('p', {class:'hint'},
    t('kpis.cacheWrites', { tokens: fmtInt(d.cache_write_tokens), n: fmtInt(d.cache_write_known_events) })));
  card.appendChild(el('div', { class: 'kpis' },
    C.kpiTile({ id: 'kpi-tokens', label: t('kpis.tile.tokens'), value: fmtInt(d.tokens), delta: delta(d.tokens, p.tokens), tone: TONE_MORE_IS_WORSE }),
    ...sourceTiles,
    C.kpiTile({ id: 'kpi-turns', label: t('kpis.tile.requests'), value: fmtInt(d.events), delta: delta(d.events, p.events), tone: TONE_MORE_IS_WORSE }),
    C.kpiTile({ id: 'kpi-sessions', label: t('kpis.tile.sessions'), value: fmtInt(d.sessions), delta: delta(d.sessions, p.sessions), tone: TONE_MORE_IS_WORSE }),
    C.kpiTile({ id: 'kpi-cachehit', label: t('kpis.tile.cacheHit'), value: fmtPct(cacheHit), delta: delta(cacheHit, prevCacheHit), tone: 'neutral' }),
    C.kpiTile({ id: 'kpi-subagent', label: t('kpis.tile.subagent'), value: fmtPct(subShare), delta: delta(subShare, prevSubShare), tone: 'neutral' })));
  return card;
}

/* --------------------------------------------------------- card 3: findings */

function findingsCard(result, state, app) {
  const card = el('div', { class: 'card findings' }, el('h2', {}, t('findings.title')));
  if (result.status === 'rejected') {
    card.appendChild(el('div', { class: 'empty' }, t('common.queryFailed', { error: errMsg(result.reason) })));
    return card;
  }
  const data = result.value;
  // No blind .slice(0, 8) any more. The server already caps -- and since
  // findings grew a muted tier it caps the two tiers SEPARATELY (see
  // internal/findings/findings.go's finish), so a flat slice here would have
  // chopped the silenced alerts off the end and made a mute look like a
  // deletion, which is the one thing this feature must not do.
  const { live, muted } = splitMuted(Array.isArray(data) ? data : (data.findings || []));
  if (!live.length && !muted.length) {
    card.appendChild(el('div', { class: 'empty' }, t('findings.empty')));
    return card;
  }
  for (const f of live) card.appendChild(findingRow(f, state, app));
  if (muted.length) {
    // Folded, not hidden: a silenced finding is still a true statement about
    // this period, and the summary line carries the count so the fold is
    // informative while closed.
    const d = el('details', { class: 'muted-tail' },
      el('summary', {}, t('findings.mutedCount', { n: muted.length })));
    for (const f of muted) d.appendChild(findingRow(f, state, app));
    card.appendChild(d);
  }
  return card;
}

function findingRow(f, state, app) {
  const hasScope = f.scope && Object.keys(f.scope).length > 0;
  // Who to go to, when the hub knows. A runaway session has an owner; an
  // unpriced model or a spend spike is everybody's, so those print nothing
  // here rather than an "unknown" that reads like missing data.
  const owner = ownerLine(f);
  return el('div', { class: 'f' },
    el('span', { class: 'dot ' + (f.severity || 'info') }),
    el('div', {},
      el('div', {}, el('b', {}, f.title)),
      f.detail ? el('div', { class: 'muted' }, f.detail) : null,
      owner ? el('div', { class: 'owner' }, owner) : null,
      hasScope ? el('a', {
        href: '#', style: 'display:inline-block;margin-top:4px;font-size:12.5px',
        onclick: (e) => { e.preventDefault(); applyFindingScope(state, app, f); },
      }, t('findings.apply')) : null,
      muteControls(f, app)));
}

/* ------------------------------------------------------- card 4: breakdowns */

function breakdownCard(n, dim, result, state, app, hasTeam, sharedMax) {
  const stateKey = n === 1 ? 'g1' : 'g2';
  const groups = GROUPS.filter((g) => g !== 'team' || hasTeam || g === dim);
  const seg = el('div', { class: 'seg', role: 'group', 'aria-label': t('breakdown.groupBy', { n }) },
    groups.map((g) => el('button', {
      type: 'button', 'aria-pressed': String(g === dim),
      onclick: () => app.setState({ ...state, [stateKey]: g }, { push: false }),
    }, DIM_LABEL[g])));

  // FIX (issue #51): the heading was `Breakdown {n}` — two cards side by side
  // both titled with nothing but a slot number, while the one fact a reader
  // needs to tell them apart (which dimension this one groups by) lived only
  // in the segmented control below. The dimension is now the title; `n` stays
  // as a muted slot badge, because the control's aria-label and the table
  // toggle's storage key still speak in slot numbers and a reader following
  // either of those needs to find the card they name.
  //
  // toLowerCase() on the dimension name is English grammar, not a fact about
  // the word: Chinese has no case, and lower-casing a translated label is at
  // best a no-op and at worst wrong for a language that does. The dictionary
  // supplies whatever form the sentence needs.
  const card = el('div', { class: 'card' },
    el('h2', {}, t('breakdown.title', { dim: DIM_LABEL[dim] }),
      el('span', { class: 'slot' }, `#${n}`)),
    el('p', { class: 'hint' }, t('breakdown.hint')),
    seg);
  if (result.status === 'rejected') {
    card.appendChild(el('div', { class: 'empty' }, t('common.queryFailed', { error: errMsg(result.reason) })));
    return card;
  }

  const buckets = result.value.buckets || [];
  const selectedKey = state.chips[dim];
  // The share denominator (issue #51's open question, answered here): the sum
  // of the TOKENS ON THIS CARD, over the current brush selection.
  //
  // Following the selection is the only choice that keeps a share next to the
  // absolute figure it is a share of — every other number in this card, and
  // on the page, already moves with the brush, and a share that did not would
  // disagree with the token count sitting beside it on the same line.
  //
  // The card's own rows, not a page-wide total, because the two breakdowns do
  // not always cover the same scope: `omitDim` drops a chip on the card's own
  // dimension (review.js's fetchers), so card 1 can be showing every project
  // while card 2 shows one project split by model. One shared denominator
  // across both would make one card's shares sum to well under 100% for no
  // reason a reader could see. `/v1/usage` sends no total of its own — it
  // sends the top `limit` buckets — so this IS the honest denominator, and
  // the column's tooltip says how many rows went into it rather than letting
  // "share" imply the whole selection.
  //
  // Tokens only. A cost share would need a per-source denominator (the three
  // kinds of money never add — internal/store/cost.go deliberately has no
  // Total()), and this card's cost cell is already one figure per source.
  const tokenTotal = buckets.reduce((sum, b) => sum + (b.tokens || 0), 0);
  const body = el('div', {});
  let expanded = false;

  const draw = () => {
    body.replaceChildren();
    if (!buckets.length) {
      body.appendChild(el('div', { class: 'empty' }, t('common.noUsagePeriod')));
      return;
    }
    const shown = expanded ? buckets.slice(0, 50) : buckets.slice(0, 12);
    // FIX (execution review, Finding 4): the rollup never fills
    // `Bucket.Label` for the project dimension (only machine/team get one —
    // internal/store/query.go's labelEndpoints/labelTeams), so `b.label ||
    // b.key` fell through to the raw cwd for every row. CSS truncates a
    // long path from the right, and every sibling worktree here shares the
    // same "/Users/.../24haowan-monorepo-scratch-NN" prefix, so all 12+ rows
    // rendered visually identical. shortProject (lib/format.js) keeps the
    // LAST segment — the one that actually distinguishes them — instead of
    // clipping it; every other surface (sessions table, findings, chips)
    // already uses it for exactly this reason. The chip/filter identity
    // (`r.key`, still `b.key`) and the row's tooltip stay the full raw path.
    const displayLabel = (b) => (dim === 'project' ? shortProject(b.key) : (b.label || b.key || t('common.unknown')));
    // delta() itself caps its rendered `text` past DELTA_CAP_PCT (a huge
    // percentage against a near-zero baseline carries no information beyond
    // "there was almost nothing before", and forced this exact row's width
    // past its card on real data — see lib/format.js). `d.pct` stays the
    // real, uncapped number; when it WAS capped, the row's tip carries it.
    //
    // Issue #51 moved the comparison off the end of the line and onto the
    // bar: `prev` draws the previous period as a marker on the same track at
    // the same scale, so the change is a distance rather than a percentage
    // the reader has to turn back into two numbers. The line now spends its
    // width on the two figures that ARE the row — tokens and this card's
    // share of them — and the full comparison (absolute AND percentage,
    // which `delta` never used to give) lives in the hover, always, not just
    // when the percentage was too big to print.
    const rows = shown.map((b) => {
      const d = delta(b.tokens, b.prev_tokens || 0);
      const capped = d.pct != null && Math.abs(d.pct) >= DELTA_CAP_PCT;
      const share = shareText(b.tokens, tokenTotal);
      const prev = b.prev_tokens || 0;
      const billed = billedCostLine(b);
      return {
        key: b.key, label: displayLabel(b), title: dim === 'project' ? b.key : null, value: b.tokens,
        prev,
        prevTitle: t('breakdown.prevMark', { prev: fmtFull(prev) }),
        // Three facts in one string (issue #51's `right`) were one fact in
        // practice: `.v` is a third of half a page, so every row rendered
        // `717,858 · 23.0% · claude …` and the cost was an ellipsis on all
        // twelve. The two that differ per row now have their own aligned
        // cells, and the third — a NAME, not a number, and the same name on
        // every row — is stated once under the bars instead (see below).
        // Billed money is a real figure and stays on the row.
        cells: [
          { text: fmtFull(b.tokens), class: 'tok' },
          { text: share || '—', class: 'pct', title: t('breakdown.shareTip', { n: buckets.length, total: fmtFull(tokenTotal) }) },
          ...(billed ? [{ text: billed, class: 'money' }] : []),
        ],
        // The one dimension with a page of its own. `withChip` (the row's
        // own click) and this are both useful and neither replaces the
        // other: the chip filters THIS page to that person, the link opens
        // that person's page. Issue #99 — the page has been routed and
        // served since /u/ was added and nothing on the dashboard led to it.
        ...(dim === 'login' ? { href: userHref(b.key), hrefLabel: t('breakdown.openUser', { user: displayLabel(b) }) } : {}),
        tip: `<b>${escapeHTML(displayLabel(b))}</b><br>` +
          `${escapeHTML(t('breakdown.tip.cur', { tokens: fmtFull(b.tokens), share: share || '—' }))}<br>` +
          `${escapeHTML(costLine(b))}<br>` +
          `${escapeHTML(prev > 0
            ? t('breakdown.tip.prev', { prev: fmtFull(prev), abs: fmtSigned(d.abs), pct: d.text })
            : t('breakdown.tip.noPrev'))}` +
          (capped ? `<br>${escapeHTML(t('breakdown.tip.exact', { pct: `${d.pct > 0 ? '+' : ''}${d.pct.toFixed(1)}%` }))}` : ''),
      };
    });
    const chart = C.rankedBars(rows, { max: sharedMax, selectedKey, onClick: (r) => app.setState(withChip(state, dim, r.key)) });
    // Same shortening for the table fallback — bucketTable draws the
    // identical `b.label || b.key` off the RAW bucket objects, so the fix
    // has to travel with the data, not just the rankedBars view.
    const tableBuckets = dim === 'project' ? buckets.map((b) => ({ ...b, label: shortProject(b.key) })) : buckets;
    const table = C.bucketTable(tableBuckets, DIM_LABEL[dim], [
      // `at: 'tokens'` (charts.js, issue #51): both of these are read
      // AGAINST the tokens column, and they used to sit past Unpriced with
      // every cost column in between — a subtraction the reader had to do
      // across a horizontal scroll.
      { at: 'tokens', label: t('breakdown.prevTokens'), value: (b) => fmtFull(b.prev_tokens || 0) },
      { at: 'tokens', label: t('breakdown.share'),
        title: t('breakdown.shareTip', { n: buckets.length, total: fmtFull(tokenTotal) }),
        value: (b) => shareText(b.tokens, tokenTotal) || '—' },
      // Previous period, per source, for the same reason the current one is:
      // one "prev cost" column would have re-blended what the row beside it
      // keeps apart.
      ...SOURCES.filter((src) => buckets.some((b) => costOf({ cost: b.prev_cost }, src).events > 0))
        .map((src) => ({ label: t('breakdown.prevSource', { source: src }), value: (b) => fmtSourceCost({ cost: b.prev_cost }, src) })),
    ], { keyHref: dim === 'login' ? (b) => userHref(b.key) : null });
    // Stated once per card, under the bars: a shared scale is only useful if
    // the reader knows the bars are on one, and the figure names what a full
    // track is worth so a bar can be read without hovering it. It rides
    // INSIDE the chart half of withTable, since "a full bar is N tokens"
    // says nothing about the table the toggle swaps in.
    //
    // The subscription note rides here for the same reason (issue #99): it
    // is what the rows used to repeat twelve times, and it is a fact about
    // the BARS' right-hand column, not about the table — which already has
    // one cost column per source, headed with the kind of money it is.
    const notional = notionalSourcesAcross(buckets);
    const chartNotes = [
      sharedMax > 1 ? el('p', { class: 'hint scale-note' }, t('breakdown.scaleNote', { max: fmtFull(sharedMax) })) : null,
      notional.length ? el('p', { class: 'hint scale-note' }, t('breakdown.subscriptionNote', { sources: notional.join(', ') })) : null,
      // Only on `source`, and only because `source` and the consumption
      // table's `provider` read as the same cut to anyone who has not been
      // told otherwise -- both look like "group by vendor" (issue #103).
      // The distinction was real but lived only in a code comment
      // (web/dist/consumption.js's header), which is not somewhere a reader
      // of this page can see it. The consumption table's own hint says the
      // mirror of this sentence.
      dim === 'source' ? el('p', { class: 'hint scale-note' }, t('breakdown.sourceNote')) : null,
    ].filter(Boolean);
    const chartWrap = chartNotes.length ? el('div', {}, chart, chartNotes) : chart;
    C.withTable(body, chartWrap, table, `review-breakdown-${n}`);
    if (!expanded && buckets.length > 12) {
      body.appendChild(el('a', {
        href: '#', style: 'display:inline-block;margin-top:10px',
        onclick: (e) => { e.preventDefault(); expanded = true; draw(); },
      }, t('common.showAll', { n: buckets.length })));
    }
  };
  draw();
  card.appendChild(body);
  return card;
}

/* ------------------------------------------------------- card 5: efficiency */

function efficiencyCard(summaryResult, breakdown2Result, state) {
  const card = el('div', { class: 'card' }, el('h2', {}, t('efficiency.title')),
    el('p', { class: 'hint' }, t('efficiency.hint')));
  if (summaryResult.status === 'rejected') {
    card.appendChild(el('div', { class: 'empty' }, t('common.queryFailed', { error: errMsg(summaryResult.reason) })));
    return card;
  }
  const d = summaryResult.value;

  const parts = [
    // slotColor, not the name-keyed palette: these five are a FIXED
    // enumeration drawn in a designed order (biggest contributor first), and
    // their names are translated — hashing them would hand the same chart
    // different colours in English and in Chinese (issue #55).
    { key: t('part.cacheRead'), tokens: d.cache_read_tokens, color: C.slotColor(0) },
    { key: t('part.cacheCreate'), tokens: d.cache_create_tokens, color: C.slotColor(1) },
    { key: t('part.output'), tokens: Math.max(0, (d.output_tokens || 0) - (d.thinking_tokens || 0)), color: C.slotColor(2) },
    { key: t('part.input'), tokens: d.input_tokens, color: C.slotColor(3) },
    { key: t('part.thinking'), tokens: d.thinking_tokens, color: C.slotColor(4) },
  ];
  const compTotal = parts.reduce((a, p) => a + (p.tokens || 0), 0) || 1;
  const compChart = C.composition(parts);
  const compTable = el('div', { class: 'scroll' }, el('table', {},
    el('thead', {}, el('tr', {}, el('th', {}, t('efficiency.col.part')), el('th', { class: 'num' }, t('efficiency.col.tokens')), el('th', { class: 'num' }, t('efficiency.col.share')))),
    el('tbody', {}, parts.map((p) => el('tr', {},
      el('td', {}, p.key), el('td', { class: 'num' }, fmtFull(p.tokens)),
      el('td', { class: 'num' }, ((p.tokens / compTotal) * 100).toFixed(1) + '%'))))));
  const compWrap = el('div', {});
  C.withTable(compWrap, compChart, compTable, 'review-efficiency');
  card.appendChild(compWrap);

  // The three mini-lists that used to sit here (effort, entrypoint, and
  // "turns: main vs. subagent") are gone — issue #93.
  //
  // `turns` was `kpi-subagent` in a second unit: the tile above states the
  // subagent SHARE, the list restated the same split as two turn counts. One
  // question, one reading; the tile keeps it.
  //
  // `effort` and `entrypoint` were the page's ONLY outlet for those two
  // dimensions — neither is in lib/state.js's GROUPS, so no breakdown card can
  // reach them. They are deleted anyway because issue #60 made them first-class
  // grouping axes on the MCP surface (internal/mcp/mcp.go's `usage_by_effort`
  // and `usage_by_entrypoint`, both verified present before this deletion):
  // the DATA is still collected and still answerable, it just is not on this
  // page. That is the trade, and it is deliberate — see the PR body.

  // $ per 1M output by model, read from breakdown card 2's response when that
  // card is grouped by model — which is the default (lib/state.js's
  // DEFAULTS.g2). There used to be a dedicated limit-8 `by=model` fetch behind
  // this as a fallback (fetcher index 5); it was DEAD on every default load,
  // because the line above preferred breakdown 2 and breakdown 2 is by model
  // unless the reader changes it. It was a request sent on every first screen
  // whose result was then discarded. Deleted with the fetcher (issue #93).
  //
  // The cost of deleting it is that this list now follows breakdown card 2: a
  // reader who regroups that card loses this one. Better to say so than to send
  // a request nobody reads — so the empty state names the control to change.
  const source = state.g2 === 'model' && breakdown2Result.status === 'fulfilled'
    ? breakdown2Result.value.buckets : null;
  const perMSection = el('div', { style: 'margin-top:16px' }, el('h2', {}, t('efficiency.perMTitle')));
  if (!source) {
    perMSection.appendChild(el('div', { class: 'empty' },
      state.g2 === 'model' ? t('efficiency.perMFailed') : t('efficiency.perMNeedsModel')));
  } else {
    // Same rule as the KPI tile: a cost-per-token rate belongs to one source.
    // A model whose bucket spans sources is left out rather than given a
    // numerator that mixes an estimate with an invoice; its cost is in the
    // by-source breakdown, where it means something. In practice a model id
    // belongs to one source anyway, so this drops nothing on a real hub.
    const rows = source
      .filter((b) => (b.output_tokens || 0) > 0 && !b.unpriced_events && activeSources(b).length === 1
        && kindOf(activeSources(b)[0]) === 'billed')
      .map((b) => {
        const src = activeSources(b)[0];
        const v = (costOf(b, src).cost_usd / b.output_tokens) * 1e6;
        return { key: b.key, label: b.label || b.key, value: v, right: `${fmtUSD(v)} ${KIND_LABEL[kindOf(src)]}` };
      })
      .sort((a, c) => c.value - a.value);
    perMSection.appendChild(rows.length ? C.rankedBars(rows) : el('div', { class: 'empty' }, t('efficiency.perMEmpty')));
  }
  card.appendChild(perMSection);
  return card;
}

/* -------------------------------------------------------------- card 7: when */

// The shortest selection this card has anything of its own to say about, and
// it is ONE constant on purpose: whenCard reads it to decide what to draw and
// renderReview reads it to decide whether to ask for the data at all. Two
// copies of the threshold is how a card ends up drawn from a response nobody
// sent, or a response sent for a card that will not draw it.
//
// 48 hours because this card's reading is PERIODIC -- hour × weekday, every
// Tuesday 15:00 folded onto one another -- and a fold needs more than one
// reading per cell to be a fold at all. Under two days most cells hold one
// observation or none, and the grid is just the selection's own hours laid out
// in a rectangle.
const WHEN_MIN_MS = 48 * 3600e3;

function whenCard(result, ctx) {
  const { sel } = ctx;
  // Issue #102: below the threshold this card used to draw hourly BARS, and
  // that is the timeline's answer, one band up -- the same buckets of the same
  // measure in the same chronological order, which on `span=7d` is literally
  // the same 1h granularity. The card's own hint has always promised hour ×
  // weekday, so the bars did not even match what it said it was showing.
  //
  // So a short selection gets no chart: it gets the sentence that names the
  // card that does answer it. One number, one place on the page (issue #93).
  //
  // Read from the SELECTION, not from `result`, and that is what lets the two
  // agree: renderReview stops sending the hourly request under this threshold,
  // so `result` is usually a SKIPPED hole here -- but seq.js's replay() can
  // also hand back a fulfilled long-window result the moment the brush
  // narrows, before any request goes out. The selection is the one fact both
  // the fetch plan and this card are derived from.
  if (sel.to - sel.from < WHEN_MIN_MS) {
    return el('div', { class: 'card' }, el('h2', {}, t('when.title')),
      el('div', { class: 'empty' }, t('when.tooShort')));
  }
  if (result.status === 'rejected') return errCard(t('when.title'), result);
  const data = result.value;
  const series = data.series || [];

  const card = el('div', { class: 'card' }, el('h2', {}, t('when.title')),
    el('p', { class: 'hint' }, t('when.hint')));
  if (!series.length) {
    card.appendChild(el('div', { class: 'empty' }, t('common.noUsagePeriod')));
    return card;
  }

  const { grid, events } = foldHourly(series);
  const chart = el('div', {}, C.heatmap(grid, events),
    el('p', { class: 'hint', style: 'margin-top:10px' }, sentence(grid)));
  const table = C.bucketTable(series, t('when.hour'));
  const wrap = el('div', {});
  C.withTable(wrap, chart, table, 'review-when');
  card.appendChild(wrap);
  return card;
}

/* -------------------------------------------------------- card 8: wall history */

// Issue #101: this card used to lead with a utilization-over-time line chart,
// and that line said the same thing as the wall card's gauges one band up --
// one is this instant, the other is this instant joined up. What no other card
// on the page can answer is the table's question: how many times did this
// subscription sit ON the limit, and for how long. So the chart is gone and
// the table, which `withTable` kept hidden behind a ⊞ by default, is the card.
//
// The per-account `<p class=hint>` summary lines went with it. They named the
// same four values as the table's four columns, which was defensible while the
// table was the hidden half and the chart was what you saw -- and is just the
// page printing a number twice (issue #93) now that the table is always up.
function wallHistoryCard(result) {
  const card = el('div', { class: 'card', id: 'wall-history' }, el('h2', {}, t('wallHistory.title')),
    el('p', { class: 'hint' }, t('wallHistory.hint')));
  if (result.status === 'rejected') {
    card.appendChild(el('div', { class: 'empty' }, t('common.queryFailed', { error: errMsg(result.reason) })));
    return card;
  }
  const data = result.value;
  const accounts = [...(data.accounts || []), ...(data.quota_series || [])];
  if (!accounts.length) {
    // Not "snapshots exist from <date>": that hardcoded a date true only of
    // the author's hub, and every other hub would show it verbatim and
    // wrongly. No response field gives an actual earliest-snapshot date to
    // derive it from, so say plainly that this period has none.
    //
    // This used to count POINTS rather than rows, which is the same test by a
    // longer route: the server only emits a series for an account it found at
    // least one observation for. Counting rows keeps the guard honest now that
    // the request asks for one point per series rather than 400.
    card.appendChild(el('div', { class: 'empty' }, t('wallHistory.empty')));
    return card;
  }

  const table = el('div', { class: 'scroll' }, el('table', {},
    el('thead', {}, el('tr', {}, el('th', {}, t('wallHistory.col.subscription')), el('th', { class: 'num' }, t('wallHistory.col.episodes')),
      el('th', { class: 'num' }, t('wallHistory.col.time')), el('th', { class: 'num' }, t('wallHistory.col.prev')))),
    el('tbody', {}, accounts.map((a) => el('tr', {},
      el('td', {}, a.label), el('td', { class: 'num' }, fmtFull(a.critical_episodes || 0)),
      el('td', { class: 'num' }, fmtDur((a.critical_seconds || 0) * 1000)),
      el('td', { class: 'num' }, fmtDur((a.prev_critical_seconds || 0) * 1000)))))));

  card.appendChild(table);
  return card;
}

/* ---------------------------------------------------------- card 9: sessions */

function sessionDuration(r) {
  const ms = new Date(r.ended) - new Date(r.started);
  return Number.isFinite(ms) && ms > 0 ? fmtDur(ms) : '—';
}

function chipLink(state, app, dim, value, text) {
  return el('a', {
    href: '#',
    onclick: (e) => { e.preventDefault(); e.stopPropagation(); app.setState(withChip(state, dim, value)); },
  }, text);
}

function sessionRow(r, state, app) {
  const open = () => app.setState({ ...state, session: r.session_id });
  return el('tr', { role: 'button', tabindex: '0', onclick: open, onkeydown: (e) => { if (e.key === 'Enter') open(); } },
    el('td', {}, new Date(r.started).toLocaleString()),
    el('td', { title: r.cwd }, chipLink(state, app, 'project', r.cwd, shortProject(r.cwd))),
    el('td', {}, chipLink(state, app, 'login', r.os_user, `${r.os_user}@${r.endpoint || r.endpoint_id}`)),
    el('td', { title: (r.models || []).join(', ') }, r.model || '—'),
    el('td', {}, sessionDuration(r)),
    el('td', { class: 'num' }, fmtFull(r.turns)),
    el('td', { class: 'num' }, fmtInt(r.tokens)),
    sessionCostCell(r),
    el('td', { class: 'num' }, fmtPct(r.cache_hit || 0)),
    el('td', { class: 'num' }, fmtPct(r.sidechain_share || 0)));
}

// A session's money, or the honest absence of it.
//
// Most sessions are subscription work, whose cost_usd is an API-equivalent
// estimate — the figure this page no longer prints. Saying "subscription"
// without an amount answers the question the column asks ("what did this cost")
// more truthfully than a number nobody was billed.
const sessionKind = (r) => r.cost_kind || kindOf(r.source);

function sessionCostText(r) {
  return sessionKind(r) === 'notional' ? t('cost.subscription') : `${fmtCost(r)} ${KIND_LABEL[sessionKind(r)]}`;
}

function sessionCostCell(r) {
  const kind = sessionKind(r);
  if (kind === 'notional') {
    return el('td', {
      class: 'num',
      title: t('sessions.subTip', { source: r.source || 'claude' }),
    }, '—', el('span', { class: 'kind' }, ' ' + t('cost.subscription')));
  }
  return el('td', { class: 'num', title: t('sessions.costTip', { source: r.source, kind: KIND_LABEL[kind] }) },
    fmtCost(r), el('span', { class: 'kind' }, ` ${KIND_LABEL[kind]}`));
}

function sessionMobileCard(r, state, app) {
  const open = () => app.setState({ ...state, session: r.session_id });
  return el('div', { class: 'srow', role: 'button', tabindex: '0', onclick: open, onkeydown: (e) => { if (e.key === 'Enter') open(); } },
    el('div', {}, chipLink(state, app, 'project', r.cwd, shortProject(r.cwd)), ' — ', chipLink(state, app, 'login', r.os_user, r.os_user)),
    el('div', {}, `${r.model || '—'} · ${r.endpoint || r.endpoint_id}`),
    el('div', {}, `${new Date(r.started).toLocaleString()} · ${sessionDuration(r)}`),
    el('div', {}, t('sessions.mobile.tokens', { tokens: fmtInt(r.tokens), cost: sessionCostText(r), turns: fmtFull(r.turns) })),
    el('div', {}, t('sessions.mobile.cache', { hit: fmtPct(r.cache_hit || 0), sub: fmtPct(r.sidechain_share || 0) })));
}

const SESSION_COLS = [
  { key: 'started', label: t('sessions.col.started'), sort: 'started' },
  { key: 'project', label: t('sessions.col.project') },
  { key: 'who', label: t('sessions.col.who') },
  { key: 'model', label: t('sessions.col.model') },
  { key: 'duration', label: t('sessions.col.duration'), sort: 'duration', num: true },
  { key: 'turns', label: t('sessions.col.turns'), sort: 'turns', num: true },
  { key: 'tokens', label: t('sessions.col.tokens'), sort: 'tokens', num: true },
  // Sorting by cost ranks rows that are each a single source's money; it
  // never sums them, and each cell says which kind it is.
  { key: 'cost', label: t('sessions.col.cost'), sort: 'cost', num: true },
  { key: 'cachehit', label: t('sessions.col.cacheHit'), num: true },
  { key: 'subagent', label: t('sessions.col.subagent'), num: true },
];

function sessionsCard(result, state, app, sel) {
  const sortLabel = (SESSION_COLS.find((c) => c.sort === state.sort) || {}).label || state.sort;
  const card = el('div', { class: 'card sessions', id: 'sessions' }, el('h2', {}, t('sessions.title')),
    el('p', { class: 'hint' }, t('sessions.hint', { sort: sortLabel })));
  if (result.status === 'rejected') {
    card.appendChild(el('div', { class: 'empty' }, t('common.queryFailed', { error: errMsg(result.reason) })));
    return card;
  }

  let rows = result.value.slice();
  let mayHaveMore = rows.length >= 50;

  const setSort = (s) => () => app.setState({ ...state, sort: s }, { push: false });
  const thead = el('tr', {}, SESSION_COLS.map((c) => el('th', {
    class: c.num ? 'num' : null,
    role: c.sort ? 'button' : null, tabindex: c.sort ? '0' : null,
    'aria-sort': c.sort && state.sort === c.sort ? 'descending' : null,
    onclick: c.sort ? setSort(c.sort) : null,
    onkeydown: c.sort ? (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); setSort(c.sort)(); } } : null,
  }, c.label)));

  const tbody = el('tbody', {}, rows.map((r) => sessionRow(r, state, app)));
  const table = el('div', { class: 'scroll' }, el('table', {}, el('thead', {}, thead), tbody));
  const cardsWrap = el('div', { class: 'cards' }, rows.map((r) => sessionMobileCard(r, state, app)));

  if (!rows.length) {
    card.appendChild(el('div', { class: 'empty' }, t('sessions.empty')));
    return card;
  }

  const moreWrap = el('div', {});
  const drawMore = () => {
    moreWrap.replaceChildren();
    if (!mayHaveMore) return;
    moreWrap.appendChild(el('a', {
      href: '#', style: 'display:inline-block;margin-top:10px',
      onclick: async (e) => {
        e.preventDefault();
        const qs = apiQuery(state, { from: sel.from, to: sel.to, extra: { sort: state.sort, limit: 50, offset: rows.length } });
        let more;
        try { more = await app.api('/v1/sessions?' + qs); } catch { return; }
        mayHaveMore = more.length >= 50;
        rows = rows.concat(more);
        tbody.replaceChildren(...rows.map((r) => sessionRow(r, state, app)));
        cardsWrap.replaceChildren(...rows.map((r) => sessionMobileCard(r, state, app)));
        drawMore();
      },
    }, t('common.loadMore')));
  };
  drawMore();

  card.appendChild(table);
  card.appendChild(cardsWrap);
  card.appendChild(moreWrap);
  return card;
}

/* ------------------------------------------------------------------- main */

function applyAll(root, state, app, ctx, results) {
  const [historyExtR, summaryR, findingsR, g1R, g2R, hourR, wallR, sessionsR] = results;
  // Cached by now.js after its own /v1/endpoints fetch (Review issues no
  // endpoints request of its own — see task-12-report.md). Empty until the
  // Now view has loaded at least once, which just means "team" starts out
  // hidden from the group-by control rather than crashing.
  const hasTeam = (app.endpoints || []).some((e) => e.team);

  // The usage band's four sections, and they are skipped WHOLESALE when that
  // band is not on the page -- `root` is app.js's `$('#analysis')`, and a view
  // that does not mount the usage band makes that null. This apply still runs
  // in that case, because #spend is drawn from the same results (app.js wraps
  // this function) and the ledger band may well be mounted: one loader, three
  // bands, and each half checks its own mount point.
  //
  // Asking `root` rather than a passed-in flag is deliberate and it is the same
  // rule app.js applies to #spend and #consumption: an apply can arrive from
  // seq.js's replay() after the reader has already switched away, and the DOM
  // is the one copy of "is this band on the page" that cannot be stale.
  if (root) drawUsageBand(root, state, app, ctx, { historyExtR, summaryR, g1R, g2R, hasTeam });

  // findings / when+wall / sessions answer operational questions, so they mount
  // in the folded operations tier rather than beside the money -- and their four
  // requests (see READ_BY above) are only SENT when that tier is live.
  //
  // TWO conditions, and they are genuinely different questions -- the first
  // draft of #98 checked only the mount point and crashed on the very first
  // page view:
  //
  //   the mount point   -- is the operations BAND on this view at all. Null on
  //                        `view=ledger` / `view=usage`, where #ops is detached.
  //   the SKIPPED hole  -- did THIS round of requests include the tier. A
  //                        mounted #ops is still a <details> the reader has
  //                        folded shut, and #ops-analysis sits inside it, in
  //                        the document, findable -- which is the default state
  //                        of `view=all`. So the mount point says yes while the
  //                        results are holes, and findingsCard reading one of
  //                        them is the TypeError that found this.
  //
  // Position 2 stands for the TIER: READ_BY gives these four one reader between
  // them, so the tier is asked for or it is not, and findings is the position
  // that carries no second condition of its own. Reading the hole rather than a
  // flag is what makes this agree with the fetch plan by construction, incl. on
  // a replay -- and the mount check is what covers the other direction, where a
  // replay hands back a live-ops result set after the reader has switched to a
  // view that has no #ops-analysis to draw it into.
  //
  // Position 5 (the hourly history) is the one that can be a hole INSIDE a live
  // tier: issue #102 also gates it on the selection being long enough for the
  // when card to fold. So it must not be read here to mean "the tier is off",
  // and whenCard answers from the selection before it touches the result at
  // all. Position 2 is the tier question; 5 is a question about 5.
  //
  // There is no `|| root` fallback any more. It used to read
  // `querySelector('#ops-analysis') || root`, to keep working on "an embedded
  // or cut-down page" -- but that fallback now names a failure #98 would have
  // introduced: on `view=usage`, #ops-analysis is unmounted while `root` is
  // #analysis, so it would drop three operations cards into the middle of the
  // usage band. A missing mount point means the band is not here; that is the
  // answer, not a reason to improvise.
  const opsRoot = document.querySelector('#ops-analysis');
  if (!opsRoot || findingsR.status === SKIPPED) return;
  section(opsRoot, 'r-findings').replaceChildren(findingsCard(findingsR, state, app));
  section(opsRoot, 'r-whenwall').replaceChildren(el('div', { class: 'grid2' },
    whenCard(hourR, ctx), wallHistoryCard(wallR)));
  section(opsRoot, 'r-sessions').replaceChildren(sessionsCard(sessionsR, state, app, ctx.sel));
}

function drawUsageBand(root, state, app, ctx, { historyExtR, summaryR, g1R, g2R, hasTeam }) {
  section(root, 'r-timeline').replaceChildren(timelineCard(historyExtR, ctx, state, app));
  section(root, 'r-kpis').replaceChildren(kpisCard(summaryR));
  // ONE scale for both breakdown cards (issue #51). They draw the same
  // quantity — tokens — over the same brush selection, cut two different
  // ways, and side by side each normalized to its own tallest row: a
  // full-width bar on the left and a full-width bar on the right were
  // different numbers, every time, with nothing on screen saying so. The max
  // spans every bucket BOTH responses returned (not just the 12 rows a card
  // shows unexpanded), so clicking "show all" cannot move the scale under a
  // reader mid-comparison, and it counts previous-period figures too so the
  // marker charts.js draws for them always lands on the track.
  const bdScaleRows = (r) => (r.status === 'fulfilled' ? (r.value.buckets || []) : [])
    .map((b) => ({ value: b.tokens || 0, prev: b.prev_tokens || 0 }));
  const bdMax = scaleMax([...bdScaleRows(g1R), ...bdScaleRows(g2R)]);
  section(root, 'r-breakdowns').replaceChildren(el('div', { class: 'grid2' },
    breakdownCard(1, state.g1, g1R, state, app, hasTeam, bdMax),
    breakdownCard(2, state.g2, g2R, state, app, hasTeam, bdMax)));
  // "Model mix over time" used to sit beside this in a grid2. It is gone
  // (issue #93): it drew `historyExtR` -- the SAME response the timeline above
  // already draws, already stacked by model -- so it cost no request and
  // carried no reading the page did not have. Efficiency now has the row to
  // itself.
  //
  // #93 removed the third copy of `by=model` by deleting a card; #103 removed
  // the second by unstacking the timeline. What is left is THIS card, and it
  // is deliberately the usage band's only model cut: the efficiency card's
  // "$ per 1M output by model" reads its response (there is no second fetch
  // behind it since #93), so `DEFAULTS.g2` staying `model` is load-bearing and
  // not merely inherited. lib/state.js says the same thing from the other end.
  // The page's PRIMARY model reading is neither of them -- it is the
  // consumption table, one band up, keyed on (provider, model).
  section(root, 'r-efficiency').replaceChildren(efficiencyCard(summaryR, g2R, state));
}

/** SUMMARY_INDEX is where /v1/summary lands in the fetcher list above. It is
 *  exported so app.js can read that one result for the spend headline without
 *  hard-coding a position that a later edit would silently shift. */
export const SUMMARY_INDEX = 1;

/** READ_BY names, per fetcher position below, WHICH BANDS read that result --
 *  so a position whose every reader is unmounted is not sent at all.
 *
 *  This is the generalisation of what used to be `OPS_ONLY = new Set([2, 5, 6,
 *  7])`: the same idea (do not ask a question nothing on the page will draw),
 *  applied to every band instead of only to the folded operations tier. #98's
 *  point is that the old set was half the answer -- it saved four requests when
 *  the fold was shut, while `view=usage` still fetched the ledger's summary and
 *  `view=ledger` still fetched the timeline's history and both breakdowns,
 *  because until then every band was always on the page.
 *
 *  This file draws into THREE bands, which is why it is the one that needs the
 *  whole set rather than a boolean:
 *
 *    0  history (extent) -> usage:   r-timeline
 *    1  summary          -> usage:   r-kpis, r-efficiency
 *                           ledger:  #spend, which app.js draws from this same
 *                                    result rather than fetching /v1/summary a
 *                                    second time (SUMMARY_INDEX above). So this
 *                                    is the one position two bands share, and
 *                                    the only one either can drop alone.
 *    2  findings         -> ops:     r-findings
 *    3  usage by g1      -> usage:   r-breakdowns
 *    4  usage by g2      -> usage:   r-breakdowns, r-efficiency
 *    5  history (hour)   -> ops:     r-whenwall's "when do we work" card, and
 *                                    nothing else -- position 0 is the separate
 *                                    extent-wide history the timeline draws.
 *                                    The one position with a SECOND condition
 *                                    beside its band (issue #102): a selection
 *                                    under WHEN_MIN_MS leaves it a hole even
 *                                    on a live ops tier, because its only
 *                                    reader draws nothing at that length
 *    6  limits history   -> ops:     r-whenwall's wall card
 *    7  sessions         -> ops:     r-sessions
 *
 *  Positions, because a fetcher list is a positional contract (SUMMARY_INDEX is
 *  the standing proof); seq.js leaves each unsent slot as a SKIPPED hole rather
 *  than closing the gap, and its covers() reads those holes to decide whether a
 *  kept result set can answer a later round -- which is exactly what makes
 *  arriving at a band fetch it once and every return to it free.
 *
 *  The ops rows shifted down by one when issue #93 deleted the dead `by=model`
 *  fetcher that used to be position 5 -- which is exactly the breakage a
 *  positional contract invites, and exactly why the table is written out here.
 */
const READ_BY = [
  ['usage'],
  ['usage', 'ledger'],
  ['ops'],
  ['usage'],
  ['usage'],
  ['ops'],
  ['ops'],
  ['ops'],
];

/** renderReview's `shown` is app.js's set of LIVE bands -- mounted, and for
 *  operations also unfolded. It is a Set of the same words `view` takes and
 *  index.html tags its nodes with (lib/nav.js's BANDS). */
export function renderReview(root, state, app, shown) {
  // A re-render (any state change -- a chip removed, the subscription
  // switched, ...) invalidates whatever brush-commit timer a PREVIOUS render
  // may have armed: that timer closes over the state as it stood when it was
  // set, so left running it would fire ~250ms later and write that stale
  // state back over whatever just changed. See onBrush below.
  clearTimeout(brushTimer);
  const now = app.now();
  const ext = extent(state.span, now);
  const sel = resolve({ from: state.from, to: state.to }, state.span, now);
  const gran = GRAN[state.span] || 'day';
  const q = (opts) => apiQuery(state, { from: sel.from, to: sel.to, ...opts });
  const get = (path) => (signal) => app.api(path, signal);

  const fetchers = [
    // No model stack on this request any more (issue #103). The timeline draws
    // one bar per bucket now, so the per-bucket top-6 split it used to ask for
    // had nowhere to go -- the same "do not ask for what nothing will draw"
    // rule READ_BY applies per band, applied here to one parameter. The server
    // still serves that split for the API and MCP surfaces; this page is
    // simply not a caller any more.
    get(`/v1/history?${apiQuery(state, { from: ext.start, to: ext.end, extra: { granularity: gran } })}`),
    // SUMMARY_INDEX names this one: app.js reads the same result to draw the
    // spend headline, rather than fetching /v1/summary a second time. Two
    // fetches of one figure can land at different moments and disagree on
    // screen, which is worse than the coupling.
    get(`/v1/summary?${q({ extra: { compare: 1 } })}`),
    get(`/v1/findings?${q()}`),
    get(`/v1/usage?${q({ omitDim: state.g1, extra: { by: DIM_TO_API[state.g1], limit: 50, compare: 1 } })}`),
    get(`/v1/usage?${q({ omitDim: state.g2, extra: { by: DIM_TO_API[state.g2], limit: 50, compare: 1 } })}`),
    // There is no second `by=model` fetch here any more (issue #93). A
    // limit-8 one used to sit in this slot purely as the efficiency card's
    // fallback, and the card preferred the line above it whenever breakdown 2
    // was grouped by model -- which is the default. So on every default first
    // screen this request was sent, answered, and thrown away.
    // Not sent at all under 48 hours (issue #102). This response has exactly
    // one reader -- the when card's hour × weekday heatmap -- and that card
    // now refuses a window too short to fold, so below the threshold this was
    // a request whose answer had nowhere to go. WHEN_MIN_MS is the card's own
    // constant rather than a second copy of the number, which is what makes
    // "the card will draw it" and "we asked for it" the same condition.
    sel.to - sel.from < WHEN_MIN_MS ? null : get(`/v1/history?${q({ extra: { granularity: 'hour' } })}`),
    // points=1, not 400 (issue #101). 400 was the resolution a smooth line
    // needed; the wall-history card is a table of counts and durations now and
    // reads no point at all. It cannot be 0 -- the handler treats points<=0 as
    // "unset" and defaults back to 400 -- so 1 is the floor, and the response
    // still carries one row per series for the card's empty check.
    //
    // This costs the server nothing to compute and does not blunt the table:
    // LimitsHistoryView and QuotaHistorySeries both run criticalTime() over
    // the FULL scan and only then downsample to `points`, so the episode count
    // and the critical seconds are byte-identical at 400 and at 1. What it
    // saves is the payload -- 238KB -> 2KB over a 7-day window with three
    // subscriptions, all of it points nothing now draws.
    get(`/v1/limits/history?${q({ extra: { points: 1 } })}`),
    get(`/v1/sessions?${q({ extra: { sort: state.sort, limit: 50 } })}`),
  ].map((f, i) => (READ_BY[i].some((band) => shown.has(band)) ? f : null));

  const ctx = { ext, sel, gran };
  return { fetchers, apply: (results) => applyAll(root, state, app, ctx, results) };
}
