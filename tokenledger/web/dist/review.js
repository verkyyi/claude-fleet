// web/dist/review.js — the Review view: timeline+brush, KPI strip, findings,
// two group-by breakdowns, efficiency, model mix over time, an hour×weekday
// heatmap, wall history, and the sessions table. Everything here is scoped
// to the brush SELECTION (`sel`), the subscription and the chips; card 1
// (and card 6, which reuses card 1's response) is the one exception that
// draws over the whole `span` EXTENT so the brush has something to drag
// across.
//
// Backend field names were read from internal/api/{review,query}.go and
// internal/store/rollup_query.go in the sibling ccquota worktree (read-only)
// rather than guessed — see task-12-report.md for the two adapter-layer
// notes (stack shape, 6h bucket-key parsing) that fell out of that reading.
import { apiQuery, withChip, GROUPS } from './lib/state.js';
import { extent, resolve } from './lib/brush.js';
import { foldHourly, sentence } from './lib/fold.js';
import { fmtInt, fmtUSD, fmtMoney, fmtCost, fmtFull, fmtPct, fmtDur, delta, shortProject, DELTA_CAP_PCT } from './lib/format.js';
import { SOURCES, KIND_LABEL, kindOf, costOf,
         activeSources, addCost, costLine, fmtSourceCost, fmtRealSpend } from './lib/cost.js';
import { el, escapeHTML } from './lib/dom.js';
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
// the known granularity rather than the key's length, which is what keeps
// this correct for 6h (charts.js's own length-based heuristic has no branch
// for a 13-char key, so `timeline`/`stackedArea` would otherwise mis-date
// every 30d-span bucket).
function bucketISO(key, gran) {
  if (gran === 'day') return key + 'T00:00:00Z';
  if (gran === '6h') return key + ':00:00Z';
  return key + ':00Z';
}

// normalizeSeries adapts one /v1/history response's `series` to what
// charts.js's `timeline`/`stackedArea` actually read: a full-ISO `key` (see
// bucketISO above) and, when the request asked for `stack=model`, a
// name→tokens MAP — the backend's `Series.Stack` is an ARRAY of Bucket in
// `stackModels` order, not the map both chart helpers expect.
function normalizeSeries(rawSeries, gran, stackModels) {
  return (rawSeries || []).map((s) => {
    const iso = bucketISO(s.key, gran);
    let stack;
    if (Array.isArray(s.stack) && stackModels && stackModels.length) {
      stack = {};
      stackModels.forEach((name, i) => { stack[name] = (s.stack[i] && s.stack[i].tokens) || 0; });
    }
    return {
      // `cost` travels as the per-source split all the way to the tooltip.
      // It used to be a single cost_usd, which is the shape that made a
      // blended figure the path of least resistance.
      key: iso, ms: Date.parse(iso), events: s.events, tokens: s.tokens, cost: s.cost,
      unpriced_events: s.unpriced_events, sidechain_tokens: s.sidechain_tokens, stack, raw: s,
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
  const topModels = (data.stack_models || []).filter((m) => m !== 'other');
  const norm = normalizeSeries(data.series, gran, data.stack_models || []);
  const tSeries = norm.map((n) => ({ key: n.key, tokens: n.tokens, events: n.events, cost: n.cost, unpriced_events: n.unpriced_events, stack: n.stack }));

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
    stackNames: topModels, onBrush,
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
  // $ per 1M output is only meaningful WITHIN one source. The numerator is
  // that source's money and the denominator is that source's tokens; mixing
  // them — a notional numerator over every source's output, or worse a
  // blended numerator — produces a rate per million tokens that no source
  // actually charges. So the tile answers only when the scope has exactly one
  // source in it, and otherwise says to pick one.
  // ...and only when that one source is BILLED. For subscription work the
  // numerator was an estimate, so the rate answered "what would a million
  // tokens have cost at API rates" — a question about a bill that does not
  // exist.
  const oneSource = activeSources(d).length === 1 ? activeSources(d)[0] : null;
  const only = oneSource && kindOf(oneSource) === 'billed' ? oneSource : null;
  const perM = only && d.output_tokens > 0 && !d.unpriced_events
    ? (costOf(d, only).cost_usd / d.output_tokens) * 1e6 : null;
  const prevPerM = only && p.output_tokens > 0 && !p.unpriced_events && activeSources(p).length === 1
    ? (costOf(p, only).cost_usd / p.output_tokens) * 1e6 : null;
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

  const perMTile = C.kpiTile({
    id: 'kpi-perm', label: t('kpis.perM'),
    value: perM == null ? '—' : fmtUSD(perM),
    delta: perM == null || prevPerM == null ? null : delta(perM, prevPerM),
    tone: TONE_MORE_IS_WORSE,
  });
  perMTile.title = only
    ? t('kpis.perM.one', { source: only })
    : oneSource
      ? t('kpis.perM.subscription', { source: oneSource })
      : t('kpis.perM.many');

  // The one figure that is money owed: subscriptions plus metered charges.
  // The notional figure is not a term in it and cannot become one — the API
  // computes it from the billed sources alone.
  const rs = d.real_spend;
  const realTile = C.kpiTile({
    id: 'kpi-real-spend', label: t('kpis.realSpend'),
    value: fmtRealSpend(rs), delta: null, tone: TONE_MORE_IS_WORSE,
  });
  if (rs) {
    realTile.title = [
      t('kpis.realSpendTip', {
        subscription: fmtMoney(rs.subscription, rs.currency),
        gateway: fmtMoney(rs.gateway, rs.currency),
        total: fmtMoney(rs.total, rs.currency) }),
      d.real_spend_note,
      rs.complete ? null : t('spend.incomplete', { missing: (rs.missing || []).join('; ') }),
    ].filter(Boolean).join('\n\n');
  }

  const card = el('div', { class: 'card' }, el('h2', {}, t('kpis.title')),
    el('p', { class: 'hint' }, t('kpis.hint')));
  if (d.pricing_note) card.appendChild(el('p', {class:'hint'}, d.pricing_note));
  // Provenance per source, beside the columns it belongs to: which rate table,
  // reviewed when, and which kind of money the figure is. One date printed
  // once for the whole card could only ever be right about one source.
  if ((d.pricing || []).length) card.appendChild(el('details', {class:'unpriced-reasons'},
    el('summary', {}, t('kpis.provenance')),
    el('table', {}, el('thead', {}, el('tr', {}, el('th', {}, t('kpis.col.source')), el('th', {}, t('kpis.col.kind')), el('th', {}, t('kpis.col.ratesAsOf')), el('th', {}, t('kpis.col.basis')))),
      el('tbody', {}, d.pricing.map((pr) => el('tr', {},
        el('td', {}, pr.source), el('td', {}, KIND_LABEL[pr.kind] || pr.kind),
        el('td', {}, pr.rates_as_of || '—'), el('td', {}, pr.note)))))));
  if ((d.subscription_spend || []).length) card.appendChild(el('details', {class:'unpriced-reasons'},
    el('summary', {}, t('kpis.subSpend')),
    el('p', {class:'hint'}, d.real_spend_note || ''),
    el('table', {}, el('thead', {}, el('tr', {}, el('th', {}, t('kpis.col.sourcePlan')), el('th', {}, t('kpis.col.seats')), el('th', {}, t('kpis.col.months')), el('th', {}, t('kpis.col.amount')))),
      el('tbody', {}, d.subscription_spend.map((sp) => el('tr', {},
        el('td', {}, `${sp.source} / ${sp.plan}`), el('td', {}, fmtFull(sp.seats)),
        el('td', {}, (sp.months || 0).toFixed(2)),
        // Each plan states its own currency -- store.SubscriptionSpend refuses
        // to fold two of them into one row, so a row is never mixed.
        el('td', {}, sp.priced ? fmtMoney(sp.amount, sp.currency) : t('kpis.noRecordedPrice'))))))));
  if ((d.cost_unclassified || []).length) card.appendChild(el('p', {class:'hint'},
    t('kpis.unclassified', { list: d.cost_unclassified.map((c) => `${c.source} ${fmtUSD(c.cost_usd)}`).join(', ') })));
  const coverage = pricingCoverage(d);
  card.appendChild(el('div', {class:'pricing-coverage'},
    el('p', {}, el('b', {}, t('kpis.coverage', { pct: coverage.percent }))),
    el('p', {class:'hint'}, t('kpis.coverageHint', {
      priced: fmtFull(coverage.priced), total: fmtFull(coverage.total), unpriced: fmtFull(coverage.unpriced) }))));
  if (d.unpriced_reasons?.length) card.appendChild(el('details', {class:'unpriced-reasons'},
    el('summary', {}, t('kpis.whyUnpriced', { n: fmtFull(coverage.unpriced) })),
    el('table', {}, el('thead', {}, el('tr', {}, el('th', {}, t('kpis.col.sourceModel')), el('th', {}, t('kpis.col.reason')), el('th', {}, t('kpis.col.requests')))),
      el('tbody', {}, d.unpriced_reasons.map((r) => el('tr', {}, el('td', {}, `${r.source} / ${r.model || t('common.unknownTime')}`), el('td', {}, r.reason), el('td', {}, fmtFull(r.events))))))));
  // With the Claude fallback gone, a scope that ran nothing has no spend tile
  // at all. Say so, rather than leaving a KPI row of zeroes that looks like a
  // measurement.
  if (!sourceTiles.length) card.appendChild(el('p', { class: 'hint' }, t('kpis.noSpend')));
  if (d.cache_write_known_events > 0) card.appendChild(el('p', {class:'hint'},
    t('kpis.cacheWrites', { tokens: fmtInt(d.cache_write_tokens), n: fmtInt(d.cache_write_known_events) })));
  card.appendChild(el('div', { class: 'kpis' },
    C.kpiTile({ id: 'kpi-tokens', label: t('kpis.tile.tokens'), value: fmtInt(d.tokens), delta: delta(d.tokens, p.tokens), tone: TONE_MORE_IS_WORSE }),
    ...sourceTiles,
    realTile,
    C.kpiTile({ id: 'kpi-turns', label: t('kpis.tile.requests'), value: fmtInt(d.events), delta: delta(d.events, p.events), tone: TONE_MORE_IS_WORSE }),
    C.kpiTile({ id: 'kpi-sessions', label: t('kpis.tile.sessions'), value: fmtInt(d.sessions), delta: delta(d.sessions, p.sessions), tone: TONE_MORE_IS_WORSE }),
    C.kpiTile({ id: 'kpi-cachehit', label: t('kpis.tile.cacheHit'), value: fmtPct(cacheHit), delta: delta(cacheHit, prevCacheHit), tone: 'neutral' }),
    perMTile,
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
  const list = (Array.isArray(data) ? data : (data.findings || [])).slice(0, 8);
  if (!list.length) {
    card.appendChild(el('div', { class: 'empty' }, t('findings.empty')));
    return card;
  }
  for (const f of list) {
    const hasScope = f.scope && Object.keys(f.scope).length > 0;
    card.appendChild(el('div', { class: 'f' },
      el('span', { class: 'dot ' + (f.severity || 'info') }),
      el('div', {},
        el('div', {}, el('b', {}, f.title)),
        f.detail ? el('div', { class: 'muted' }, f.detail) : null,
        hasScope ? el('a', {
          href: '#', style: 'display:inline-block;margin-top:4px;font-size:12.5px',
          onclick: (e) => { e.preventDefault(); applyFindingScope(state, app, f); },
        }, t('findings.apply')) : null)));
  }
  return card;
}

/* ------------------------------------------------------- card 4: breakdowns */

function breakdownCard(n, dim, result, state, app, hasTeam) {
  const stateKey = n === 1 ? 'g1' : 'g2';
  const groups = GROUPS.filter((g) => g !== 'team' || hasTeam || g === dim);
  const seg = el('div', { class: 'seg', role: 'group', 'aria-label': t('breakdown.groupBy', { n }) },
    groups.map((g) => el('button', {
      type: 'button', 'aria-pressed': String(g === dim),
      onclick: () => app.setState({ ...state, [stateKey]: g }, { push: false }),
    }, DIM_LABEL[g])));

  const card = el('div', { class: 'card' }, el('h2', {}, t('breakdown.title', { n })),
    // toLowerCase() on the dimension name is English grammar, not a fact about
    // the word: Chinese has no case, and lower-casing a translated label is at
    // best a no-op and at worst wrong for a language that does. The dictionary
    // supplies whatever form the sentence needs.
    el('p', { class: 'hint' }, t('breakdown.hint', { dim: DIM_LABEL[dim] })),
    seg);
  if (result.status === 'rejected') {
    card.appendChild(el('div', { class: 'empty' }, t('common.queryFailed', { error: errMsg(result.reason) })));
    return card;
  }

  const buckets = result.value.buckets || [];
  const selectedKey = state.chips[dim];
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
    // real, uncapped number; when it WAS capped, a `tip` on the row keeps it
    // reachable (rankedBars already renders `r.tip` via the floating
    // tooltip — no new plumbing needed for this).
    const rows = shown.map((b) => {
      const d = delta(b.tokens, b.prev_tokens || 0);
      const capped = d.pct != null && Math.abs(d.pct) >= DELTA_CAP_PCT;
      return {
        key: b.key, label: displayLabel(b), title: dim === 'project' ? b.key : null, value: b.tokens,
        right: `${fmtFull(b.tokens)} · ${costLine(b)} · ${d.text}`,
        tip: capped
          ? `<b>${escapeHTML(displayLabel(b))}</b><br>` +
            `${escapeHTML(t('breakdown.tip.tokens', { tokens: fmtFull(b.tokens), prev: fmtFull(b.prev_tokens || 0) }))}<br>` +
            `${escapeHTML(t('breakdown.tip.exact', { pct: `${d.pct > 0 ? '+' : ''}${d.pct.toFixed(1)}%` }))}`
          : null,
      };
    });
    const chart = C.rankedBars(rows, { selectedKey, onClick: (r) => app.setState(withChip(state, dim, r.key)) });
    // Same shortening for the table fallback — bucketTable draws the
    // identical `b.label || b.key` off the RAW bucket objects, so the fix
    // has to travel with the data, not just the rankedBars view.
    const tableBuckets = dim === 'project' ? buckets.map((b) => ({ ...b, label: shortProject(b.key) })) : buckets;
    const table = C.bucketTable(tableBuckets, DIM_LABEL[dim], [
      { label: t('breakdown.prevTokens'), value: (b) => fmtFull(b.prev_tokens || 0) },
      // Previous period, per source, for the same reason the current one is:
      // one "prev cost" column would have re-blended what the row beside it
      // keeps apart.
      ...SOURCES.filter((src) => buckets.some((b) => costOf({ cost: b.prev_cost }, src).events > 0))
        .map((src) => ({ label: t('breakdown.prevSource', { source: src }), value: (b) => fmtSourceCost({ cost: b.prev_cost }, src) })),
    ]);
    C.withTable(body, chart, table, `review-breakdown-${n}`);
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

function efficiencyCard(summaryResult, modelResult, breakdown2Result, state) {
  const card = el('div', { class: 'card' }, el('h2', {}, t('efficiency.title')),
    el('p', { class: 'hint' }, t('efficiency.hint')));
  if (summaryResult.status === 'rejected') {
    card.appendChild(el('div', { class: 'empty' }, t('common.queryFailed', { error: errMsg(summaryResult.reason) })));
    return card;
  }
  const d = summaryResult.value;

  const parts = [
    { key: t('part.cacheRead'), tokens: d.cache_read_tokens, color: C.seriesColor(0) },
    { key: t('part.cacheCreate'), tokens: d.cache_create_tokens, color: C.seriesColor(1) },
    { key: t('part.output'), tokens: Math.max(0, (d.output_tokens || 0) - (d.thinking_tokens || 0)), color: C.seriesColor(2) },
    { key: t('part.input'), tokens: d.input_tokens, color: C.seriesColor(3) },
    { key: t('part.thinking'), tokens: d.thinking_tokens, color: C.seriesColor(4) },
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

  const miniList = (title, rows) => el('div', {},
    el('h2', { style: 'margin-top:16px' }, title),
    rows.length ? C.rankedBars(rows) : el('div', { class: 'empty' }, t('efficiency.noData')));
  const effortRows = (d.effort || []).map((e) => ({
    key: e.key || t('efficiency.default'), value: e.tokens,
    right: t('efficiency.tokensTurns', { tokens: fmtFull(e.tokens), events: fmtFull(e.events) }),
  }));
  const entryRows = (d.entrypoint || []).map((e) => ({
    key: e.key || t('common.unknown'), value: e.tokens,
    right: t('efficiency.tokensTurns', { tokens: fmtFull(e.tokens), events: fmtFull(e.events) }),
  }));
  const mainEvents = Math.max(0, (d.events || 0) - (d.sidechain_events || 0));
  const subRows = [
    { key: t('efficiency.mainThread'), value: mainEvents, right: t('efficiency.turnsOnly', { events: fmtFull(mainEvents) }) },
    { key: t('efficiency.subagent'), value: d.sidechain_events || 0, right: t('efficiency.turnsOnly', { events: fmtFull(d.sidechain_events || 0) }) },
  ];
  card.appendChild(el('div', { class: 'eff-lists' },
    miniList(t('efficiency.effort'), effortRows), miniList(t('efficiency.entrypoint'), entryRows), miniList(t('efficiency.turns'), subRows)));

  // $ per 1M output by model: prefer breakdown 2's fuller (limit 50) list
  // when it is already grouped by model, otherwise fall back to the
  // dedicated limit-8 fetch (fetcher index 5) — either way the source can
  // independently fail without taking the rest of this card down.
  const source = state.g2 === 'model' && breakdown2Result.status === 'fulfilled'
    ? breakdown2Result.value.buckets
    : (modelResult.status === 'fulfilled' ? modelResult.value.buckets : null);
  const perMSection = el('div', { style: 'margin-top:16px' }, el('h2', {}, t('efficiency.perMTitle')));
  if (!source) {
    perMSection.appendChild(el('div', { class: 'empty' }, t('efficiency.perMFailed')));
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

/* ------------------------------------------------------- card 6: model mix */

function modelMixCard(result, ctx) {
  if (result.status === 'rejected') return errCard(t('modelMix.title'), result);
  const { gran, sel } = ctx;
  const data = result.value;
  const stackModels = data.stack_models || [];
  const norm = normalizeSeries(data.series, gran, stackModels);
  const inSel = norm.filter((n) => n.ms >= sel.from && n.ms < sel.to);

  const card = el('div', { class: 'card' }, el('h2', {}, t('modelMix.title')),
    el('p', { class: 'hint' }, t('modelMix.hint')));
  if (!inSel.length) {
    card.appendChild(el('div', { class: 'empty' }, t('common.noUsagePeriod')));
    return card;
  }

  const areaSeries = inSel.map((n) => ({ key: n.key, stack: n.stack || {} }));
  const chart = C.stackedArea(areaSeries, stackModels);

  const totals = {};
  for (const n of inSel) {
    (n.raw.stack || []).forEach((b, i) => {
      const name = stackModels[i];
      if (!name) return;
      const t = totals[name] || (totals[name] = { key: name, events: 0, tokens: 0, cost: [], unpriced_events: 0 });
      t.events += b.events || 0; t.tokens += b.tokens || 0;
      addCost(t.cost, b);
      t.unpriced_events += b.unpriced_events || 0;
    });
  }
  const table = C.bucketTable(Object.values(totals), t('modelMix.model'));
  const wrap = el('div', {});
  C.withTable(wrap, chart, table, 'review-model-mix');
  card.appendChild(wrap);
  return card;
}

/* -------------------------------------------------------------- card 7: when */

function whenCard(result, ctx) {
  if (result.status === 'rejected') return errCard(t('when.title'), result);
  const { sel } = ctx;
  const data = result.value;
  const series = data.series || [];

  const card = el('div', { class: 'card' }, el('h2', {}, t('when.title')),
    el('p', { class: 'hint' }, t('when.hint')));
  if (!series.length) {
    card.appendChild(el('div', { class: 'empty' }, t('common.noUsagePeriod')));
    return card;
  }

  let chart;
  if (sel.to - sel.from < 48 * 3600e3) {
    chart = C.bars(series, 'hour');
  } else {
    const { grid, events } = foldHourly(series);
    chart = el('div', {}, C.heatmap(grid, events), el('p', { class: 'hint', style: 'margin-top:10px' }, sentence(grid)));
  }
  const table = C.bucketTable(series, t('when.hour'));
  const wrap = el('div', {});
  C.withTable(wrap, chart, table, 'review-when');
  card.appendChild(wrap);
  return card;
}

/* -------------------------------------------------------- card 8: wall history */

function wallHistoryCard(result, ctx) {
  const card = el('div', { class: 'card', id: 'wall-history' }, el('h2', {}, t('wallHistory.title')),
    el('p', { class: 'hint' }, t('wallHistory.hint')));
  if (result.status === 'rejected') {
    card.appendChild(el('div', { class: 'empty' }, t('common.queryFailed', { error: errMsg(result.reason) })));
    return card;
  }
  const { sel } = ctx;
  const data = result.value;
  const accounts = [...(data.accounts || []), ...(data.quota_series || []).map((s) => ({ ...s,
    points: s.points.map((p) => ({ t: p.t, five_hour_pct: p.utilization })) }))];
  const totalPoints = accounts.reduce((a, x) => a + ((x.points || []).length), 0);
  if (!totalPoints) {
    // Not "snapshots exist from <date>": that hardcoded a date true only of
    // the author's hub, and every other hub would show it verbatim and
    // wrongly. No response field gives an actual earliest-snapshot date to
    // derive it from, so say plainly that this period has none.
    card.appendChild(el('div', { class: 'empty' }, t('wallHistory.empty')));
    return card;
  }

  const lineAccounts = accounts.map((a) => ({
    label: a.label,
    points: (a.points || []).map((p) => ({ ts: Date.parse(p.t), five_hour_pct: p.five_hour_pct, seven_day_pct: p.seven_day_pct })),
  }));
  const chart = C.lines(lineAccounts, { start: sel.from, end: sel.to });

  const notes = el('div', { style: 'margin-top:10px' }, accounts.map((a) => el('p', { class: 'hint' },
    t(a.critical_episodes === 1 ? 'wallHistory.note.one' : 'wallHistory.note.other', {
      label: a.label,
      n: fmtFull(a.critical_episodes || 0),
      time: fmtDur((a.critical_seconds || 0) * 1000),
      prev: fmtDur((a.prev_critical_seconds || 0) * 1000),
    }))));

  const table = el('div', { class: 'scroll' }, el('table', {},
    el('thead', {}, el('tr', {}, el('th', {}, t('wallHistory.col.subscription')), el('th', { class: 'num' }, t('wallHistory.col.episodes')),
      el('th', { class: 'num' }, t('wallHistory.col.time')), el('th', { class: 'num' }, t('wallHistory.col.prev')))),
    el('tbody', {}, accounts.map((a) => el('tr', {},
      el('td', {}, a.label), el('td', { class: 'num' }, fmtFull(a.critical_episodes || 0)),
      el('td', { class: 'num' }, fmtDur((a.critical_seconds || 0) * 1000)),
      el('td', { class: 'num' }, fmtDur((a.prev_critical_seconds || 0) * 1000)))))));

  const wrap = el('div', {});
  C.withTable(wrap, chart, table, 'review-wall-history');
  card.appendChild(wrap);
  card.appendChild(notes);
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
  const [historyExtR, summaryR, findingsR, g1R, g2R, modelR, hourR, wallR, sessionsR] = results;
  // Cached by now.js after its own /v1/endpoints fetch (Review issues no
  // endpoints request of its own — see task-12-report.md). Empty until the
  // Now view has loaded at least once, which just means "team" starts out
  // hidden from the group-by control rather than crashing.
  const hasTeam = (app.endpoints || []).some((e) => e.team);

  section(root, 'r-timeline').replaceChildren(timelineCard(historyExtR, ctx, state, app));
  section(root, 'r-kpis').replaceChildren(kpisCard(summaryR));
  // findings / when+wall / sessions answer operational questions, so they mount
  // in the folded operations tier rather than beside the money. Falling back to
  // `root` keeps this working if the ops block is ever absent (an embedded or
  // cut-down page), rather than dropping the cards on the floor.
  const ops = document.querySelector('#ops-analysis') || root;
  section(ops, 'r-findings').replaceChildren(findingsCard(findingsR, state, app));
  section(root, 'r-breakdowns').replaceChildren(el('div', { class: 'grid2' },
    breakdownCard(1, state.g1, g1R, state, app, hasTeam),
    breakdownCard(2, state.g2, g2R, state, app, hasTeam)));
  section(root, 'r-effmix').replaceChildren(el('div', { class: 'grid2' },
    efficiencyCard(summaryR, modelR, g2R, state),
    modelMixCard(historyExtR, ctx)));
  section(ops, 'r-whenwall').replaceChildren(el('div', { class: 'grid2' },
    whenCard(hourR, ctx), wallHistoryCard(wallR, ctx)));
  section(ops, 'r-sessions').replaceChildren(sessionsCard(sessionsR, state, app, ctx.sel));
}

/** SUMMARY_INDEX is where /v1/summary lands in the fetcher list above. It is
 *  exported so app.js can read that one result for the spend headline without
 *  hard-coding a position that a later edit would silently shift. */
export const SUMMARY_INDEX = 1;

export function renderReview(root, state, app) {
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
    get(`/v1/history?${apiQuery(state, { from: ext.start, to: ext.end, extra: { granularity: gran, stack: 'model' } })}`),
    // SUMMARY_INDEX names this one: app.js reads the same result to draw the
    // spend headline, rather than fetching /v1/summary a second time. Two
    // fetches of one figure can land at different moments and disagree on
    // screen, which is worse than the coupling.
    get(`/v1/summary?${q({ extra: { compare: 1 } })}`),
    get(`/v1/findings?${q()}`),
    get(`/v1/usage?${q({ omitDim: state.g1, extra: { by: DIM_TO_API[state.g1], limit: 50, compare: 1 } })}`),
    get(`/v1/usage?${q({ omitDim: state.g2, extra: { by: DIM_TO_API[state.g2], limit: 50, compare: 1 } })}`),
    get(`/v1/usage?${q({ extra: { by: 'model', limit: 8 } })}`),
    get(`/v1/history?${q({ extra: { granularity: 'hour' } })}`),
    get(`/v1/limits/history?${q({ extra: { points: 400 } })}`),
    get(`/v1/sessions?${q({ extra: { sort: state.sort, limit: 50 } })}`),
  ];

  const ctx = { ext, sel, gran };
  return { fetchers, apply: (results) => applyAll(root, state, app, ctx, results) };
}
