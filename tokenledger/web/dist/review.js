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
import { fmtInt, fmtUSD, fmtCost, fmtFull, fmtPct, fmtDur, delta, shortProject, DELTA_CAP_PCT } from './lib/format.js';
import { el, escapeHTML } from './lib/dom.js';
import { createScopeControls } from './scope.js';
import * as C from './charts.js';
import { pricingCoverage } from './lib/providers.js';

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
const DIM_LABEL = { project: 'Project', login: 'Login', machine: 'Machine', model: 'Model', branch: 'Branch', team: 'Team', source: 'Source' };
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
    el('div', { class: 'empty' }, 'Query failed: ' + errMsg(result.reason)));
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
      key: iso, ms: Date.parse(iso), events: s.events, tokens: s.tokens, cost_usd: s.cost_usd,
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
  const card = el('div', { class: 'card' }, el('h2', {}, 'Timeline'),
    el('p', { class: 'hint' },
      'Tokens per bucket across the current span, stacked by model (top 6 + other). Drag the ' +
      'body to move the selection every other card reports on, an edge to resize it, or ' +
      'double-click to reset to the whole span.'),
    reviewScope.el);

  if (result.status === 'rejected') {
    card.appendChild(el('div', { class: 'empty' }, 'Query failed: ' + errMsg(result.reason)));
    return card;
  }

  const { ext, sel, gran } = ctx;
  const data = result.value;
  const topModels = (data.stack_models || []).filter((m) => m !== 'other');
  const norm = normalizeSeries(data.series, gran, data.stack_models || []);
  const tSeries = norm.map((n) => ({ key: n.key, tokens: n.tokens, events: n.events, cost_usd: n.cost_usd, unpriced_events: n.unpriced_events, stack: n.stack }));

  const captionText = (s) => {
    const to = s.to == null ? ext.end : s.to;
    const len = to - s.from;
    return `selected ${fmtMD(s.from)} → ${fmtMD(to)} (${fmtDur(len)}) · compared with the ${fmtDur(len)} before`;
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

  const table = C.bucketTable(data.series || [], 'Bucket');
  const wrap = el('div', {});
  C.withTable(wrap, chart, table, 'review-timeline');
  card.appendChild(wrap);
  return card;
}

/* -------------------------------------------------------------- card 2: kpis */

function kpisCard(result) {
  if (result.status === 'rejected') return errCard('KPIs', result);
  const d = result.value, p = d.prev || {};

  const cacheHit = ratio(d.cache_read_tokens, d.cache_read_tokens + d.input_tokens + d.cache_create_tokens);
  const prevCacheHit = ratio(p.cache_read_tokens || 0, (p.cache_read_tokens || 0) + (p.input_tokens || 0) + (p.cache_create_tokens || 0));
  const perM = d.output_tokens > 0 && !d.unpriced_events ? (d.cost_usd / d.output_tokens) * 1e6 : null;
  const prevPerM = p.output_tokens > 0 && !p.unpriced_events ? (p.cost_usd / p.output_tokens) * 1e6 : null;
  const subShare = ratio(d.sidechain_tokens, d.tokens);
  const prevSubShare = ratio(p.sidechain_tokens || 0, p.tokens || 0);

  const spendTile = C.kpiTile({
    id: 'kpi-spend', label: 'spend (notional)',
    value: fmtCost(d),
    delta: d.unpriced_events || p.unpriced_events ? null : delta(d.cost_usd, p.cost_usd),
    tone: TONE_MORE_IS_WORSE,
  });
  if (d.unpriced_events > 0) {
    spendTile.title = `${fmtFull(d.unpriced_events)} event(s) in this period have no price data — spend is a lower bound.`;
  }

  const card = el('div', { class: 'card' }, el('h2', {}, 'KPIs'),
    el('p', { class: 'hint' }, 'Selection totals, each compared with the equal-length period right before it.'));
  if (d.pricing_note) card.appendChild(el('p', {class:'hint'}, d.pricing_note));
  const coverage = pricingCoverage(d);
  card.appendChild(el('div', {class:'pricing-coverage'},
    el('p', {}, el('b', {}, `Request pricing coverage · 计价覆盖率: ${coverage.percent}`)),
    el('p', {class:'hint'}, `${fmtFull(coverage.priced)} priced / ${fmtFull(coverage.total)} collected model requests. ${fmtFull(coverage.unpriced)} unpriced requests still count toward token totals. This measures pricing coverage by request count, not collection completeness or remaining quota. API-equivalent cost is not your subscription bill.`)));
  if (d.unpriced_reasons?.length) card.appendChild(el('details', {class:'unpriced-reasons'},
    el('summary', {}, `Why ${fmtFull(coverage.unpriced)} requests have no price · 未计价原因`),
    el('table', {}, el('thead', {}, el('tr', {}, el('th', {}, 'Source / model'), el('th', {}, 'Reason'), el('th', {}, 'Requests'))),
      el('tbody', {}, d.unpriced_reasons.map((r) => el('tr', {}, el('td', {}, `${r.source} / ${r.model || 'unknown'}`), el('td', {}, r.reason), el('td', {}, fmtFull(r.events))))))));
  if (d.cache_write_known_events > 0) card.appendChild(el('p', {class:'hint'}, `Codex cache writes: ${fmtInt(d.cache_write_tokens)} tokens · breakdown available for ${fmtInt(d.cache_write_known_events)} requests. Included in input totals.`));
  card.appendChild(el('div', { class: 'kpis' },
    C.kpiTile({ id: 'kpi-tokens', label: 'tokens', value: fmtInt(d.tokens), delta: delta(d.tokens, p.tokens), tone: TONE_MORE_IS_WORSE }),
    spendTile,
    C.kpiTile({ id: 'kpi-turns', label: 'model requests', value: fmtInt(d.events), delta: delta(d.events, p.events), tone: TONE_MORE_IS_WORSE }),
    C.kpiTile({ id: 'kpi-sessions', label: 'sessions', value: fmtInt(d.sessions), delta: delta(d.sessions, p.sessions), tone: TONE_MORE_IS_WORSE }),
    C.kpiTile({ id: 'kpi-cachehit', label: 'cache hit', value: fmtPct(cacheHit), delta: delta(cacheHit, prevCacheHit), tone: 'neutral' }),
    C.kpiTile({
      id: 'kpi-perm', label: '$ per 1M output',
      value: perM == null ? '—' : fmtUSD(perM),
      delta: perM == null || prevPerM == null ? null : delta(perM, prevPerM),
      tone: TONE_MORE_IS_WORSE,
    }),
    C.kpiTile({ id: 'kpi-subagent', label: 'subagent share', value: fmtPct(subShare), delta: delta(subShare, prevSubShare), tone: 'neutral' })));
  return card;
}

/* --------------------------------------------------------- card 3: findings */

function findingsCard(result, state, app) {
  const card = el('div', { class: 'card findings' }, el('h2', {}, 'Findings'));
  if (result.status === 'rejected') {
    card.appendChild(el('div', { class: 'empty' }, 'Query failed: ' + errMsg(result.reason)));
    return card;
  }
  const data = result.value;
  const list = (Array.isArray(data) ? data : (data.findings || [])).slice(0, 8);
  if (!list.length) {
    card.appendChild(el('div', { class: 'empty' }, 'Nothing unusual in this period.'));
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
        }, 'apply →') : null)));
  }
  return card;
}

/* ------------------------------------------------------- card 4: breakdowns */

function breakdownCard(n, dim, result, state, app, hasTeam) {
  const stateKey = n === 1 ? 'g1' : 'g2';
  const groups = GROUPS.filter((g) => g !== 'team' || hasTeam || g === dim);
  const seg = el('div', { class: 'seg', role: 'group', 'aria-label': `group by (breakdown ${n})` },
    groups.map((g) => el('button', {
      type: 'button', 'aria-pressed': String(g === dim),
      onclick: () => app.setState({ ...state, [stateKey]: g }, { push: false }),
    }, DIM_LABEL[g])));

  const card = el('div', { class: 'card' }, el('h2', {}, `Breakdown ${n}`),
    el('p', { class: 'hint' }, `Grouped by ${DIM_LABEL[dim].toLowerCase()}, 50 rows requested, compared with the period before.`),
    seg);
  if (result.status === 'rejected') {
    card.appendChild(el('div', { class: 'empty' }, 'Query failed: ' + errMsg(result.reason)));
    return card;
  }

  const buckets = result.value.buckets || [];
  const selectedKey = state.chips[dim];
  const body = el('div', {});
  let expanded = false;

  const draw = () => {
    body.replaceChildren();
    if (!buckets.length) {
      body.appendChild(el('div', { class: 'empty' }, 'No usage in this period.'));
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
    const displayLabel = (b) => (dim === 'project' ? shortProject(b.key) : (b.label || b.key || '(unknown)'));
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
        right: `${fmtFull(b.tokens)} · ${fmtCost(b)} · ${d.text}`,
        tip: capped
          ? `<b>${escapeHTML(displayLabel(b))}</b><br>${fmtFull(b.tokens)} tokens (was ${fmtFull(b.prev_tokens || 0)})` +
            `<br>exact change: ${d.pct > 0 ? '+' : ''}${d.pct.toFixed(1)}%`
          : null,
      };
    });
    const chart = C.rankedBars(rows, { selectedKey, onClick: (r) => app.setState(withChip(state, dim, r.key)) });
    // Same shortening for the table fallback — bucketTable draws the
    // identical `b.label || b.key` off the RAW bucket objects, so the fix
    // has to travel with the data, not just the rankedBars view.
    const tableBuckets = dim === 'project' ? buckets.map((b) => ({ ...b, label: shortProject(b.key) })) : buckets;
    const table = C.bucketTable(tableBuckets, DIM_LABEL[dim], [
      { label: 'Prev tokens', value: (b) => fmtFull(b.prev_tokens || 0) },
      { label: 'Prev cost', value: (b) => fmtCost({cost_usd:b.prev_cost_usd || 0, events:b.prev_events, unpriced_events:b.prev_unpriced_events}) },
    ]);
    C.withTable(body, chart, table, `review-breakdown-${n}`);
    if (!expanded && buckets.length > 12) {
      body.appendChild(el('a', {
        href: '#', style: 'display:inline-block;margin-top:10px',
        onclick: (e) => { e.preventDefault(); expanded = true; draw(); },
      }, `show all ${buckets.length}`));
    }
  };
  draw();
  card.appendChild(body);
  return card;
}

/* ------------------------------------------------------- card 5: efficiency */

function efficiencyCard(summaryResult, modelResult, breakdown2Result, state) {
  const card = el('div', { class: 'card' }, el('h2', {}, 'Efficiency'),
    el('p', { class: 'hint' }, 'Token composition, how work was invoked, and notional cost per million output tokens by model.'));
  if (summaryResult.status === 'rejected') {
    card.appendChild(el('div', { class: 'empty' }, 'Query failed: ' + errMsg(summaryResult.reason)));
    return card;
  }
  const d = summaryResult.value;

  const parts = [
    { key: 'cache read', tokens: d.cache_read_tokens, color: C.seriesColor(0) },
    { key: 'cache create', tokens: d.cache_create_tokens, color: C.seriesColor(1) },
    { key: 'output (non-thinking)', tokens: Math.max(0, (d.output_tokens || 0) - (d.thinking_tokens || 0)), color: C.seriesColor(2) },
    { key: 'input', tokens: d.input_tokens, color: C.seriesColor(3) },
    { key: 'thinking', tokens: d.thinking_tokens, color: C.seriesColor(4) },
  ];
  const compTotal = parts.reduce((a, p) => a + (p.tokens || 0), 0) || 1;
  const compChart = C.composition(parts);
  const compTable = el('div', { class: 'scroll' }, el('table', {},
    el('thead', {}, el('tr', {}, el('th', {}, 'Part'), el('th', { class: 'num' }, 'Tokens'), el('th', { class: 'num' }, 'Share'))),
    el('tbody', {}, parts.map((p) => el('tr', {},
      el('td', {}, p.key), el('td', { class: 'num' }, fmtFull(p.tokens)),
      el('td', { class: 'num' }, ((p.tokens / compTotal) * 100).toFixed(1) + '%'))))));
  const compWrap = el('div', {});
  C.withTable(compWrap, compChart, compTable, 'review-efficiency');
  card.appendChild(compWrap);

  const miniList = (title, rows) => el('div', {},
    el('h2', { style: 'margin-top:16px' }, title),
    rows.length ? C.rankedBars(rows) : el('div', { class: 'empty' }, 'No data.'));
  const effortRows = (d.effort || []).map((e) => ({
    key: e.key || 'default', value: e.tokens, right: `${fmtFull(e.tokens)} · ${fmtFull(e.events)} turns`,
  }));
  const entryRows = (d.entrypoint || []).map((e) => ({
    key: e.key || '(unknown)', value: e.tokens, right: `${fmtFull(e.tokens)} · ${fmtFull(e.events)} turns`,
  }));
  const mainEvents = Math.max(0, (d.events || 0) - (d.sidechain_events || 0));
  const subRows = [
    { key: 'main thread', value: mainEvents, right: `${fmtFull(mainEvents)} turns` },
    { key: 'subagent', value: d.sidechain_events || 0, right: `${fmtFull(d.sidechain_events || 0)} turns` },
  ];
  card.appendChild(el('div', { class: 'eff-lists' },
    miniList('Effort', effortRows), miniList('Entrypoint', entryRows), miniList('Turns: main vs. subagent', subRows)));

  // $ per 1M output by model: prefer breakdown 2's fuller (limit 50) list
  // when it is already grouped by model, otherwise fall back to the
  // dedicated limit-8 fetch (fetcher index 5) — either way the source can
  // independently fail without taking the rest of this card down.
  const source = state.g2 === 'model' && breakdown2Result.status === 'fulfilled'
    ? breakdown2Result.value.buckets
    : (modelResult.status === 'fulfilled' ? modelResult.value.buckets : null);
  const perMSection = el('div', { style: 'margin-top:16px' }, el('h2', {}, '$ per 1M output tokens, by model'));
  if (!source) {
    perMSection.appendChild(el('div', { class: 'empty' }, 'Query failed: model breakdown unavailable.'));
  } else {
    const rows = source
      .filter((b) => (b.output_tokens || 0) > 0 && !b.unpriced_events)
      .map((b) => {
        const v = (b.cost_usd / b.output_tokens) * 1e6;
        return { key: b.key, label: b.label || b.key, value: v, right: fmtUSD(v) };
      })
      .sort((a, c) => c.value - a.value);
    perMSection.appendChild(rows.length ? C.rankedBars(rows) : el('div', { class: 'empty' }, 'No priced model with output tokens in this period.'));
  }
  card.appendChild(perMSection);
  return card;
}

/* ------------------------------------------------------- card 6: model mix */

function modelMixCard(result, ctx) {
  if (result.status === 'rejected') return errCard('Model mix over time', result);
  const { gran, sel } = ctx;
  const data = result.value;
  const stackModels = data.stack_models || [];
  const norm = normalizeSeries(data.series, gran, stackModels);
  const inSel = norm.filter((n) => n.ms >= sel.from && n.ms < sel.to);

  const card = el('div', { class: 'card' }, el('h2', {}, 'Model mix over time'),
    el('p', { class: 'hint' }, 'Tokens per bucket by model, over the selected window (same buckets as the timeline).'));
  if (!inSel.length) {
    card.appendChild(el('div', { class: 'empty' }, 'No usage in this period.'));
    return card;
  }

  const areaSeries = inSel.map((n) => ({ key: n.key, stack: n.stack || {} }));
  const chart = C.stackedArea(areaSeries, stackModels);

  const totals = {};
  for (const n of inSel) {
    (n.raw.stack || []).forEach((b, i) => {
      const name = stackModels[i];
      if (!name) return;
      const t = totals[name] || (totals[name] = { key: name, events: 0, tokens: 0, cost_usd: 0, unpriced_events: 0 });
      t.events += b.events || 0; t.tokens += b.tokens || 0; t.cost_usd += b.cost_usd || 0;
      t.unpriced_events += b.unpriced_events || 0;
    });
  }
  const table = C.bucketTable(Object.values(totals), 'Model');
  const wrap = el('div', {});
  C.withTable(wrap, chart, table, 'review-model-mix');
  card.appendChild(wrap);
  return card;
}

/* -------------------------------------------------------------- card 7: when */

function whenCard(result, ctx) {
  if (result.status === 'rejected') return errCard('When', result);
  const { sel } = ctx;
  const data = result.value;
  const series = data.series || [];

  const card = el('div', { class: 'card' }, el('h2', {}, 'When'),
    el('p', { class: 'hint' }, 'Hour × weekday, in your local time zone, folded from the selected window.'));
  if (!series.length) {
    card.appendChild(el('div', { class: 'empty' }, 'No usage in this period.'));
    return card;
  }

  let chart;
  if (sel.to - sel.from < 48 * 3600e3) {
    chart = C.bars(series, 'hour');
  } else {
    const { grid, events } = foldHourly(series);
    chart = el('div', {}, C.heatmap(grid, events), el('p', { class: 'hint', style: 'margin-top:10px' }, sentence(grid)));
  }
  const table = C.bucketTable(series, 'Hour');
  const wrap = el('div', {});
  C.withTable(wrap, chart, table, 'review-when');
  card.appendChild(wrap);
  return card;
}

/* -------------------------------------------------------- card 8: wall history */

function wallHistoryCard(result, ctx) {
  const card = el('div', { class: 'card', id: 'wall-history' }, el('h2', {}, 'Wall history'),
    el('p', { class: 'hint' }, 'Quota observations for the selected source and accounts. Each Codex window is separate; red marks ≥ 90%.'));
  if (result.status === 'rejected') {
    card.appendChild(el('div', { class: 'empty' }, 'Query failed: ' + errMsg(result.reason)));
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
    card.appendChild(el('div', { class: 'empty' }, 'No limit snapshots in this period.'));
    return card;
  }

  const lineAccounts = accounts.map((a) => ({
    label: a.label,
    points: (a.points || []).map((p) => ({ ts: Date.parse(p.t), five_hour_pct: p.five_hour_pct, seven_day_pct: p.seven_day_pct })),
  }));
  const chart = C.lines(lineAccounts, { start: sel.from, end: sel.to });

  const notes = el('div', { style: 'margin-top:10px' }, accounts.map((a) => el('p', { class: 'hint' },
    `${a.label}: ${fmtFull(a.critical_episodes || 0)} critical episode${a.critical_episodes === 1 ? '' : 's'} · ` +
    `${fmtDur((a.critical_seconds || 0) * 1000)} in critical (prev ${fmtDur((a.prev_critical_seconds || 0) * 1000)})`)));

  const table = el('div', { class: 'scroll' }, el('table', {},
    el('thead', {}, el('tr', {}, el('th', {}, 'Subscription'), el('th', { class: 'num' }, 'Critical episodes'),
      el('th', { class: 'num' }, 'Critical time'), el('th', { class: 'num' }, 'Prev critical time'))),
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
    el('td', { class: 'num' }, fmtCost(r)),
    el('td', { class: 'num' }, fmtPct(r.cache_hit || 0)),
    el('td', { class: 'num' }, fmtPct(r.sidechain_share || 0)));
}

function sessionMobileCard(r, state, app) {
  const open = () => app.setState({ ...state, session: r.session_id });
  return el('div', { class: 'srow', role: 'button', tabindex: '0', onclick: open, onkeydown: (e) => { if (e.key === 'Enter') open(); } },
    el('div', {}, chipLink(state, app, 'project', r.cwd, shortProject(r.cwd)), ' — ', chipLink(state, app, 'login', r.os_user, r.os_user)),
    el('div', {}, `${r.model || '—'} · ${r.endpoint || r.endpoint_id}`),
    el('div', {}, `${new Date(r.started).toLocaleString()} · ${sessionDuration(r)}`),
    el('div', {}, `${fmtInt(r.tokens)} tokens · ${fmtCost(r)} · ${fmtFull(r.turns)} turns`),
    el('div', {}, `cache hit ${fmtPct(r.cache_hit || 0)} · subagent ${fmtPct(r.sidechain_share || 0)}`));
}

const SESSION_COLS = [
  { key: 'started', label: 'Started', sort: 'started' },
  { key: 'project', label: 'Project' },
  { key: 'who', label: 'Login@machine' },
  { key: 'model', label: 'Model' },
  { key: 'duration', label: 'Duration', sort: 'duration', num: true },
  { key: 'turns', label: 'Turns', sort: 'turns', num: true },
  { key: 'tokens', label: 'Tokens', sort: 'tokens', num: true },
  { key: 'cost', label: '$', sort: 'cost', num: true },
  { key: 'cachehit', label: 'Cache hit', num: true },
  { key: 'subagent', label: 'Subagent %', num: true },
];

function sessionsCard(result, state, app, sel) {
  const card = el('div', { class: 'card sessions', id: 'sessions' }, el('h2', {}, 'Sessions'),
    el('p', { class: 'hint' },
      `Sorted by ${state.sort}, 50 at a time. Click a row to open its detail; click the project or login to filter instead.`));
  if (result.status === 'rejected') {
    card.appendChild(el('div', { class: 'empty' }, 'Query failed: ' + errMsg(result.reason)));
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
    card.appendChild(el('div', { class: 'empty' }, 'No sessions in this period.'));
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
    }, 'load more'));
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
  section(root, 'r-findings').replaceChildren(findingsCard(findingsR, state, app));
  section(root, 'r-breakdowns').replaceChildren(el('div', { class: 'grid2' },
    breakdownCard(1, state.g1, g1R, state, app, hasTeam),
    breakdownCard(2, state.g2, g2R, state, app, hasTeam)));
  section(root, 'r-effmix').replaceChildren(el('div', { class: 'grid2' },
    efficiencyCard(summaryR, modelR, g2R, state),
    modelMixCard(historyExtR, ctx)));
  section(root, 'r-whenwall').replaceChildren(el('div', { class: 'grid2' },
    whenCard(hourR, ctx), wallHistoryCard(wallR, ctx)));
  section(root, 'r-sessions').replaceChildren(sessionsCard(sessionsR, state, app, ctx.sel));
}

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
