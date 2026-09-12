// web/dist/charts.js — chart + table primitives. DOM-producing, no fetching.
//
// `rankedBars`, `bucketTable`, `bars` (the old page's `timeSeries`), `gauge`,
// `tile` and `tween` are ported from the old <script> block of
// web/dist/index.html (pre-Task-11) — unchanged except where the Task 11
// brief calls for it (rankedBars gains onClick/selectedKey, bucketTable gains
// extraCols, `timeSeries` is renamed `bars`). Everything else here
// (withTable, kpiTile, timeline, stackedArea, heatmap, lines, composition,
// turnBars) is new: the Review view (task 12) and session detail (task 13)
// consume these, but neither was wired up when Task 11 landed, so their
// input shapes came from those tasks' briefs rather than a running backend.
// See the task-11-report.md "assumptions" section for the field names
// guessed at that point.
//
// Task 12 (review.js) additionally gives `rankedBars` an optional `r.label`
// (display text, falling back to `r.key`) so a breakdown row can show a
// friendly name — an endpoint's label — while `r.key`, used for onClick and
// selectedKey, stays the raw filter value the chip actually needs. Every
// other helper here matched review.js's real backend responses as read from
// internal/api/{review,query}.go and internal/store/rollup_query.go, with
// two adapter-layer gaps worth knowing about (both handled in review.js, not
// here): `timeline`/`stackedArea` want `series[i].stack` as a name→tokens
// MAP, but the backend's `Series.Stack` is an ARRAY of Bucket in
// `stack_models` order; and `timeline`'s internal bucket-key parsing has no
// case for the `6h` granularity's 13-char keys (`YYYY-MM-DDTHH`, which
// `Date.parse` cannot read) — review.js normalizes every bucket key to a
// full RFC3339 string before handing series to either function, which
// sidesteps both.

import { el, escapeHTML, showTip, hideTip } from './lib/dom.js';
import { fmtInt, fmtUSD, fmtCost, fmtFull, relTime } from './lib/format.js';
import { snap, clamp } from './lib/brush.js';

const SERIES = ['--s1', '--s2', '--s3', '--s4', '--s5', '--s6', '--s7', '--s8'];
/** seriesColor assigns hues in FIXED order and never cycles. A ninth series
 *  folds into "Other" rather than reusing slot 1 and implying a relationship
 *  that is not there. */
export const seriesColor = (i) => `var(${SERIES[Math.min(i, SERIES.length - 1)]})`;
const OTHER_COLOR = 'var(--ink-3)';

/** Utilization -> status. Four named bands so the label, not the hue, is what
 *  carries the meaning. */
const band = (pct) =>
  pct >= 90 ? { key: 'critical', label: 'critical' }
  : pct >= 75 ? { key: 'serious', label: 'high' }
  : pct >= 50 ? { key: 'warning', label: 'moderate' }
  : { key: 'good', label: 'healthy' };

/* ------------------------------------------------------------- ranked bars */

/** rankedBars renders one row per item, longest bar first is the caller's
 *  job (rows are drawn in the order given). `onClick`/`selectedKey` make a
 *  row a facet: clicking it drills in, and the current facet value (if any)
 *  is highlighted via the `sel` class. `r.key` is the row's IDENTITY (what
 *  `onClick`/`selectedKey` compare against — a raw filter value such as an
 *  endpoint id); `r.label` (optional) is what is actually shown, falling
 *  back to `r.key` when absent. Task 12's breakdown cards need this split:
 *  a machine's chip value is its endpoint id, not its display name, and
 *  bucketTable already draws the same `label || key` distinction for its
 *  own key column — this brings rankedBars in line with it. `r.title`
 *  (optional) overrides the row's tooltip text, defaulting to the same
 *  display text otherwise — a shortened project path (breakdown-by-project
 *  rows) wants its tooltip to still carry the full raw path, not the
 *  shortened label. */
export function rankedBars(rows, { onClick, selectedKey } = {}) {
  const max = Math.max(...rows.map((r) => r.value), 1);
  return el('div', { class: 'bars' }, rows.map((r) => {
    const sel = selectedKey != null && r.key === selectedKey;
    const display = r.label || r.key;
    // FIX (execution review, Finding 4): a display label can differ from
    // the raw identity enough that the identity is worth keeping visible
    // somewhere (a shortened project path is not the full path) — `r.title`
    // lets a caller say so explicitly; every existing caller leaves it unset
    // and gets exactly the old title (the display text itself).
    const tipTitle = r.title || display;
    return el('div', {
        class: 'bar-row' + (sel ? ' sel' : ''),
        role: onClick ? 'button' : null,
        tabindex: onClick ? '0' : null,
        onmousemove: r.tip ? (e) => showTip(e, r.tip) : null,
        onmouseleave: r.tip ? hideTip : null,
        onclick: onClick ? () => onClick(r) : null,
        onkeydown: onClick ? (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onClick(r); } } : null,
      },
      el('div', { class: 'k', title: tipTitle }, display),
      el('div', { class: 'bar-track' },
        el('div', { class: 'bar-fill',
          style: `width:${Math.max(1.5, (r.value / max) * 100)}%${r.color ? ';background:' + r.color : ''}` })),
      el('div', { class: 'v' }, r.right));
  }));
}

/** bucketTable is the relief the palette validator requires in light mode, and
 *  the accessible fallback for anyone who cannot read the charts. `extraCols`
 *  (Review's compare-with-previous-period columns) is `[{label, value(b)}]`,
 *  appended after Unpriced; omitted it behaves exactly as before. */
export function bucketTable(buckets, keyLabel, extraCols = []) {
  return el('div', { class: 'scroll' }, el('table', {},
    el('thead', {}, el('tr', {},
      el('th', {}, keyLabel),
      el('th', { class: 'num' }, 'Turns'),
      el('th', { class: 'num' }, 'Tokens'),
      el('th', { class: 'num' }, 'Cost'),
      el('th', { class: 'num' }, 'Unpriced'),
      ...extraCols.map((c) => el('th', { class: 'num' }, c.label)))),
    el('tbody', {}, buckets.map((b) => el('tr', {},
      el('td', { title: b.key }, b.label || b.key || '(unknown)'),
      el('td', { class: 'num' }, fmtFull(b.events)),
      el('td', { class: 'num' }, fmtFull(b.tokens)),
      el('td', { class: 'num' }, fmtCost(b)),
      el('td', { class: 'num' }, b.unpriced_events ? fmtFull(b.unpriced_events) : '—'),
      ...extraCols.map((c) => el('td', { class: 'num' }, c.value(b))))))));
}

/** withTable pairs a chart element with its table fallback under one card,
 *  toggled by a ⊞ button whose state is remembered per card id. */
export function withTable(card, chartEl, tableEl, cardId) {
  const key = 'ccquota-table:' + cardId;
  let showingTable = false;
  try { showingTable = localStorage.getItem(key) === '1'; } catch {}
  chartEl.hidden = showingTable;
  tableEl.hidden = !showingTable;
  const btn = el('button', {
    class: 'tbl', type: 'button', title: 'Toggle table view',
    onclick: () => {
      showingTable = !showingTable;
      chartEl.hidden = showingTable;
      tableEl.hidden = !showingTable;
      try { localStorage.setItem(key, showingTable ? '1' : '0'); } catch {}
    },
  }, '⊞');
  card.append(chartEl, tableEl, btn);
  return card;
}

/* ------------------------------------------------------------------ gauge */

export function gauge(name, w) {
  const pct = Math.max(0, Math.min(100, Number(w.utilization) || 0));
  const b = band(pct);
  const burn = w.burn || {};

  let note = '';
  if (burn.exhausted_at) {
    note = `At the current rate (${burn.percent_per_hour.toFixed(1)}%/h) this window fills around ` +
           new Date(burn.exhausted_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) + '.';
  } else if (burn.percent_per_hour > 0) {
    note = `Burning ${burn.percent_per_hour.toFixed(1)}%/h — it resets before it fills.`;
  }

  return el('div', { class: 'gauge' },
    el('div', { class: 'top' },
      el('span', { class: 'name' }, name),
      el('span', { class: 'pct' }, pct.toFixed(1) + '%'),
      el('span', { class: 'state st-' + b.key }, b.label),
      el('span', { class: 'reset' }, relTime(w.resets_at))),
    el('div', { class: 'track' }, el('div', { class: 'fill bg-' + b.key, style: `width:${pct}%` })),
    note ? el('div', { class: 'note' }, note) : null);
}

/* ------------------------------------------------------------------- tile */

export function tile(id, label) {
  return el('div', { class: 'tile' },
    el('div', { class: 'n', id }, '—'),
    el('div', { class: 'l' }, label));
}

/** kpiTile is Review's KPI-strip building block (`.kpi`): a value, an
 *  optional delta (`{pct, text}` from lib/format.js's `delta`), a label.
 *  `tone: 'neutral'` (ratios, where "up" is not inherently good or bad)
 *  renders the delta without directional colour; any other tone (e.g.
 *  'spend', where up is bad) colours it via the existing .d.up/.d.down rules. */
export function kpiTile({ id, label, value, delta, tone = 'neutral' }) {
  const kids = [el('div', { class: 'v', id }, value)];
  if (delta && delta.text) {
    const dir = tone === 'neutral' || delta.pct == null ? '' : (delta.pct > 0 ? ' up' : delta.pct < 0 ? ' down' : '');
    kids.push(el('span', { class: 'd' + dir }, delta.text));
  }
  return el('div', { class: 'kpi' }, ...kids, el('div', { class: 'l' }, label));
}

/* ------------------------------------------------------------------ tween */

/** tween animates a number toward its target so a jump reads as movement
 *  rather than a flicker. Honours reduced-motion by snapping instead. */
export function tween(node, to, fmt) {
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const from = Number(node.dataset.v || 0);
  node.dataset.v = String(to);
  if (reduce || !isFinite(from) || from === to) { node.textContent = fmt(to); return; }

  const t0 = performance.now(), dur = 600;
  cancelAnimationFrame(Number(node.dataset.raf || 0));
  const step = (t) => {
    const p = Math.min(1, (t - t0) / dur);
    // ease-out: fast to start, settles gently on the final value
    const v = from + (to - from) * (1 - Math.pow(1 - p, 3));
    node.textContent = fmt(v);
    if (p < 1) node.dataset.raf = String(requestAnimationFrame(step));
  };
  node.dataset.raf = String(requestAnimationFrame(step));
}

/* ------------------------------------------------------------------- bars */

/** bars draws one measure over time as bars: a single series, so no legend
 *  box — the card title names it. 2px gaps between bars, recessive
 *  gridlines, labels only at the ends and the peak. (This is the old page's
 *  `timeSeries`, renamed per the Task 11 brief.) */
export function bars(series, granularity) {
  const W = 560, H = 190, PAD = { t: 14, r: 8, b: 26, l: 46 };
  const iw = W - PAD.l - PAD.r, ih = H - PAD.t - PAD.b;
  const max = Math.max(...series.map((s) => s.tokens), 1);
  const n = series.length;
  const gap = n > 60 ? 1 : 2;
  const bw = Math.max(1, iw / n - gap);

  const ticks = [0, max / 2, max];
  const y = (v) => PAD.t + ih - (v / max) * ih;

  const g = el('g', {});
  for (const t of ticks) {
    g.appendChild(el('line', { x1: PAD.l, x2: W - PAD.r, y1: y(t), y2: y(t), stroke: 'var(--grid)' }));
    g.appendChild(el('text', { x: PAD.l - 8, y: y(t) + 3.5, 'text-anchor': 'end', fill: 'var(--ink-3)',
      'font-size': '10.5' }, fmtInt(t)));
  }

  const peak = series.reduce((a, b) => (b.tokens > a.tokens ? b : a), series[0]);
  series.forEach((s, i) => {
    const h = Math.max(s.tokens > 0 ? 1.5 : 0, (s.tokens / max) * ih);
    const x = PAD.l + i * (iw / n);
    const label = `<b>${escapeHTML(s.key)}</b><br>${fmtFull(s.tokens)} tokens<br>` +
      `${fmtFull(s.events)} turns · ${fmtCost(s)} notional`;
    g.appendChild(el('rect', {
      x, y: y(s.tokens), width: bw, height: h, rx: 2, fill: 'var(--s1)',
      onmousemove: (e) => showTip(e, label),
      onmouseleave: hideTip,
    }, el('title', {}, `${s.key}: ${fmtFull(s.tokens)} tokens`)));
  });

  // Selective labels: first, last and the peak — never a number on every bar.
  const labelAt = (s, i, anchor) => {
    const x = PAD.l + i * (iw / n) + bw / 2;
    return el('text', { x, y: H - 8, 'text-anchor': anchor, fill: 'var(--ink-3)', 'font-size': '10.5' },
      granularity === 'hour' ? s.key.slice(11, 16) : s.key.slice(5));
  };
  g.appendChild(labelAt(series[0], 0, 'start'));
  if (n > 1) g.appendChild(labelAt(series[n - 1], n - 1, 'end'));
  const pi = series.indexOf(peak);
  if (n > 4 && pi > 1 && pi < n - 2) g.appendChild(labelAt(peak, pi, 'middle'));

  return el('svg', { viewBox: `0 0 ${W} ${H}`, width: '100%', height: H,
    role: 'img', 'aria-label': `Tokens per ${granularity}, peak ${fmtInt(max)}` }, g);
}

/* --------------------------------------------------------------- timeline */

/** timeline draws a stacked bar per bucket over `opts.extent` and an
 *  interactive `.brush` selection div on top of it. `series` items are
 *  expected as `{key, tokens, stack?}` where `stack` (present when the
 *  request asked for `stack=model`) maps a name in `opts.stackNames` to its
 *  share of that bucket; a bucket with no `stack` falls back to one solid
 *  bar of `tokens`. A stack name not in `opts.stackNames` (never emitted by
 *  the current design, but defensive) folds into "other".
 *
 *  Pointer model: pointerdown on the brush body starts a move, on a handle
 *  starts a resize; pointermove recomputes the selection from the pointer's
 *  x (via `opts.extent`, `snap`ped to `opts.bucket`, `clamp`ed to the
 *  extent) and calls `opts.onBrush(sel, {final:false})`; pointerup finalizes
 *  with `{final:true}`. Double-click resets to "from extent.start, live".
 *  Arrow keys on the focused brush nudge by one bucket; Shift+arrow resizes
 *  the right edge only. */
export function timeline(series, opts) {
  const { bucket, extent: ext, selection, stackNames = [], onBrush } = opts;
  const W = 900, H = 190, PAD = { t: 14, r: 8, b: 26, l: 46 };
  const iw = W - PAD.l - PAD.r, ih = H - PAD.t - PAD.b;
  const span = Math.max(1, ext.end - ext.start);
  const n = Math.max(1, ext.n || Math.round(span / bucket));
  const gap = n > 90 ? 1 : 2;
  const bw = Math.max(1, iw / n - gap);

  // keyMs accepts a bucket key in any of the three raw shapes the rollup
  // emits (internal/api/history.go's bucketKey: day 'YYYY-MM-DD' — 10
  // chars, 6h 'YYYY-MM-DDTHH' — 13 chars, hour 'YYYY-MM-DDTHH:00' — 16
  // chars) or an already-normalized full timestamp. The three raw lengths
  // are mutually exclusive, so branching on length alone is sufficient —
  // the previous version of this only had a branch for 16, so every 6h
  // (30d-span) bucket silently mis-dated. Kept granularity-free (no
  // `gran`/`bucket`-derived signal) on purpose: a caller's series can mix
  // in an already-full ISO key (review.js normalizes upstream for its own,
  // unrelated reasons — see its `bucketISO`) and this still has to accept
  // that too.
  const keyMs = (s) => {
    if (typeof s.key === 'number') return s.key;
    const k = s.key;
    if (k.length === 10) return Date.parse(k + 'T00:00:00Z');
    if (k.length === 13) return Date.parse(k + ':00:00Z');
    if (k.length === 16) return Date.parse(k + ':00Z');
    return Date.parse(k);
  };
  const xOf = (ms) => PAD.l + ((ms - ext.start) / span) * iw;

  // Stack heights per bucket, in the fixed palette order (+ "other" last).
  const names = [...stackNames];
  let max = 1;
  const built = series.map((s) => {
    const ms = keyMs(s);
    if (s.stack && names.length) {
      let acc = 0, other = 0;
      const parts = names.map((name) => {
        const v = s.stack[name] || 0;
        acc += v;
        return v;
      });
      for (const [k, v] of Object.entries(s.stack)) if (!names.includes(k)) other += v || 0;
      max = Math.max(max, acc + other);
      return { ms, parts, other, total: acc + other, s };
    }
    max = Math.max(max, s.tokens || 0);
    return { ms, parts: [s.tokens || 0], other: 0, total: s.tokens || 0, s };
  });

  const g = el('g', {});
  const y = (v) => PAD.t + ih - (v / max) * ih;
  for (const t of [0, max / 2, max]) {
    g.appendChild(el('line', { x1: PAD.l, x2: W - PAD.r, y1: y(t), y2: y(t), stroke: 'var(--grid)' }));
    g.appendChild(el('text', { x: PAD.l - 8, y: y(t) + 3.5, 'text-anchor': 'end', fill: 'var(--ink-3)', 'font-size': '10.5' }, fmtInt(t)));
  }
  built.forEach(({ ms, parts, other, total, s }) => {
    const x = xOf(ms);
    let base = 0;
    const label = `<b>${escapeHTML(String(s.key))}</b><br>${fmtFull(total)} tokens`;
    const segs = other ? [...parts, other] : parts;
    segs.forEach((v, i) => {
      if (!v) return;
      const h = Math.max(0, (v / max) * ih);
      g.appendChild(el('rect', {
        x, y: y(base + v), width: bw, height: h,
        fill: i < names.length ? seriesColor(i) : OTHER_COLOR,
        onmousemove: (e) => showTip(e, label), onmouseleave: hideTip,
      }));
      base += v;
    });
  });

  const svg = el('svg', { viewBox: `0 0 ${W} ${H}`, width: '100%', height: H }, g);
  const container = el('div', { class: 'timeline', tabindex: '-1' }, svg);

  const brush = el('div', { class: 'brush', tabindex: '0' },
    el('div', { class: 'h l' }), el('div', { class: 'h r' }));
  container.appendChild(brush);

  // A stack of up to 7 series (6 top models + "other") with no legend is
  // unreadable — every other multi-series chart here (stackedArea, lines,
  // composition) builds one; this one didn't. Same palette order the stack
  // itself is drawn in (built.forEach above: `i < names.length ?
  // seriesColor(i) : OTHER_COLOR`), so the mapping is actually correct.
  if (names.length) {
    const hasOther = built.some((b) => b.other > 0);
    const legend = el('div', { class: 'legend' },
      names.map((name, i) => el('span', {}, el('i', { style: `background:${seriesColor(i)}` }), name)),
      hasOther ? el('span', {}, el('i', { style: `background:${OTHER_COLOR}` }), 'Other') : null);
    container.appendChild(legend);
  }

  // FIX (execution review, Finding 1): paint() used to convert xOf()'s
  // viewBox-space (0..W=900) coordinates to pixels via
  // `container.getBoundingClientRect().width / W`, falling back to a scale
  // of 1 — i.e. drawing the brush AT viewBox coordinates, in raw pixels —
  // whenever that rect wasn't available yet. On a narrow (phone-width)
  // viewport the rendered track is far narrower than 900px, so a scale-1
  // fallback (or any measurement race) put the brush hundreds of pixels
  // past the track's right edge and widened the whole page's scrollWidth.
  // Desktop tracks happened to render close enough to 900px wide that the
  // same bug read as "correct" by eye. Percentages sidestep the whole
  // problem: `.brush` is `position:absolute` inside `.timeline`
  // (`position:relative`), so a percentage of ITS width is exactly the
  // fraction of `W` the SVG's own `viewBox`/`width:100%` already scales
  // by — computed natively by the layout engine on first paint AND on
  // every subsequent resize, with no JS measurement, no race, and no
  // separate resize listener required.
  const paint = (sel) => {
    const x1 = xOf(sel.from), x2 = xOf(sel.to == null ? ext.end : sel.to);
    brush.style.left = ((x1 / W) * 100) + '%';
    brush.style.width = (Math.max(0.4, ((x2 - x1) / W) * 100)) + '%';
  };
  let sel = selection || { from: ext.start, to: null };
  paint(sel);

  const msAt = (clientX) => {
    const r = container.getBoundingClientRect();
    if (!r.width) return ext.start;
    const px = (clientX - r.left) * (W / r.width);
    return ext.start + ((px - PAD.l) / iw) * span;
  };

  // FIX (execution review, Finding 2): a "live" selection (touches "now")
  // encodes its right edge as `to: null` so it keeps tracking "now" until
  // something pins it. Sliding such a selection used to write only `from`
  // (`to` stayed null, i.e. pinned at `ext.end`), so dragging the body left
  // GREW the window instead of moving it. moveSel materialises a concrete
  // `to` (defaulting to `ext.end`) before applying the same delta to both
  // edges, so a move always keeps the width constant; it only re-collapses
  // to `to: null` when the shifted window still ends exactly at `ext.end`
  // — the same "live" case, not a new one.
  const moveSel = (base, deltaMs) => {
    const to0 = base.to == null ? ext.end : base.to;
    const c = clamp({ from: base.from + deltaMs, to: to0 + deltaMs }, ext);
    return { from: c.from, to: c.to === ext.end ? null : c.to };
  };

  let mode = null, startMs = 0, startSel = null;
  const compute = (clientX) => {
    const ms = snap(msAt(clientX), bucket);
    if (mode === 'move') return moveSel(startSel, ms - startMs);
    if (mode === 'resize-l') return clamp({ from: ms, to: startSel.to == null ? ext.end : startSel.to }, ext);
    if (mode === 'resize-r') return clamp({ from: startSel.from, to: ms }, ext);
    return sel;
  };
  const onMove = (e) => { sel = compute(e.clientX); paint(sel); onBrush && onBrush(sel, { final: false }); };
  const onUp = (e) => {
    removeEventListener('pointermove', onMove);
    sel = compute(e.clientX); paint(sel); mode = null;
    onBrush && onBrush(sel, { final: true });
  };
  const down = (m) => (e) => {
    mode = m;
    // FIX (execution review, Finding 3): this used to be the RAW,
    // sub-bucket pointer position. `compute()`'s move branch derived its
    // delta as `snap(current) - startMs` — a snapped value minus an
    // unsnapped one, which is not itself a multiple of `bucket` — so a
    // move corrupted an otherwise bucket-aligned `from`/`to` with
    // fractional-millisecond noise (visible as `from=1787292020087.2688`
    // in the URL after a drag). Snapping the anchor here keeps every delta
    // computed from it an exact multiple of `bucket`.
    startMs = snap(msAt(e.clientX), bucket);
    startSel = { ...sel };
    e.preventDefault();
    addEventListener('pointermove', onMove);
    addEventListener('pointerup', onUp, { once: true });
  };
  brush.addEventListener('pointerdown', down('move'));
  brush.querySelector('.h.l').addEventListener('pointerdown', (e) => { e.stopPropagation(); down('resize-l')(e); });
  brush.querySelector('.h.r').addEventListener('pointerdown', (e) => { e.stopPropagation(); down('resize-r')(e); });

  container.addEventListener('dblclick', () => {
    sel = { from: ext.start, to: null };
    paint(sel);
    onBrush && onBrush(sel, { final: true });
  });

  brush.addEventListener('keydown', (e) => {
    if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
    const dir = e.key === 'ArrowLeft' ? -1 : 1;
    if (e.shiftKey) {
      // Shift+arrow resizes the right edge only — unaffected by Finding 2,
      // kept as-is.
      sel = clamp({ from: sel.from, to: (sel.to == null ? ext.end : sel.to) + dir * bucket }, ext);
    } else {
      // Plain arrow moves the whole window (Finding 2's keyboard
      // reproduction: ArrowLeft on a live selection used to widen it by
      // one bucket instead of sliding it — same root cause as the pointer
      // path, same fix).
      sel = moveSel(sel, dir * bucket);
    }
    e.preventDefault();
    paint(sel);
    onBrush && onBrush(sel, { final: true });
  });

  return container;
}

/* ------------------------------------------------------------- stackedArea */

/** stackedArea: one cumulative SVG path per stack name (palette order) plus a
 *  legend. `series` items are `{key, stack: {name: value, ...}}`. */
export function stackedArea(series, stackNames) {
  const W = 560, H = 170, PAD = { t: 10, r: 8, b: 8, l: 8 };
  const iw = W - PAD.l - PAD.r, ih = H - PAD.t - PAD.b;
  const n = Math.max(1, series.length);
  const totals = series.map((s) => stackNames.reduce((a, name) => a + ((s.stack && s.stack[name]) || 0), 0));
  const max = Math.max(1, ...totals);
  const x = (i) => PAD.l + (n > 1 ? (i / (n - 1)) * iw : 0);
  const y = (v) => PAD.t + ih - (v / max) * ih;

  const g = el('g', {});
  let base = new Array(n).fill(0);
  stackNames.forEach((name, si) => {
    const top = series.map((s, i) => base[i] + ((s.stack && s.stack[name]) || 0));
    const points = top.map((v, i) => [x(i), y(v)]);
    const floor = base.map((v, i) => [x(i), y(v)]).reverse();
    const d = 'M' + points.map((p) => p.join(',')).join('L') + 'L' + floor.map((p) => p.join(',')).join('L') + 'Z';
    g.appendChild(el('path', { d, fill: seriesColor(si), 'fill-opacity': '0.85' }));
    base = top;
  });

  const svg = el('svg', { viewBox: `0 0 ${W} ${H}`, width: '100%', height: H }, g);
  const legend = el('div', { class: 'legend' }, stackNames.map((name, i) =>
    el('span', {}, el('i', { style: `background:${seriesColor(i)}` }), name)));
  return el('div', {}, svg, legend);
}

/* ------------------------------------------------------------------ heatmap */

const DOW = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/** heatmap renders lib/fold.js's 7x24 `grid` (tokens) / `events` (turns) as a
 *  weekday × hour grid, cell intensity `8 + 92 * tokens/max`. */
export function heatmap(grid, events) {
  const max = Math.max(1, ...grid.flat());
  const cells = [];
  grid.forEach((row, dow) => {
    cells.push(el('span', {}, DOW[dow]));
    row.forEach((tokens, hour) => {
      const pct = 8 + 92 * (tokens / max);
      const turns = (events && events[dow] && events[dow][hour]) || 0;
      const label = `<b>${DOW[dow]} ${String(hour).padStart(2, '0')}:00</b><br>${fmtFull(tokens)} tokens · ${fmtFull(turns)} turns`;
      cells.push(el('i', {
        style: tokens > 0 ? `background:color-mix(in srgb, var(--s1) ${pct}%, var(--grid))` : null,
        title: `${DOW[dow]} ${String(hour).padStart(2, '0')}:00 — ${fmtFull(tokens)} tokens, ${fmtFull(turns)} turns`,
        onmousemove: tokens > 0 ? (e) => showTip(e, label) : null,
        onmouseleave: tokens > 0 ? hideTip : null,
      }));
    });
  });
  return el('div', { class: 'heat' }, cells);
}

/* --------------------------------------------------------------------- lines */

/** lines draws one polyline per account for `five_hour_pct` (red where the
 *  point is >= 90%, split into its own segment), a fainter dashed
 *  `seven_day_pct` line, gridlines at 50/90, and a legend. `accounts` is
 *  `[{label, points: [{ts, five_hour_pct, seven_day_pct}]}]`. */
export function lines(accounts, { start, end }) {
  const W = 900, H = 200, PAD = { t: 14, r: 8, b: 22, l: 40 };
  const iw = W - PAD.l - PAD.r, ih = H - PAD.t - PAD.b;
  const span = Math.max(1, end - start);
  const x = (t) => PAD.l + ((t - start) / span) * iw;
  const y = (v) => PAD.t + ih - (Math.max(0, Math.min(100, v)) / 100) * ih;

  const g = el('g', {});
  for (const gl of [50, 90]) {
    g.appendChild(el('line', { x1: PAD.l, x2: W - PAD.r, y1: y(gl), y2: y(gl), stroke: 'var(--grid)' }));
    g.appendChild(el('text', { x: PAD.l - 6, y: y(gl) + 3.5, 'text-anchor': 'end', fill: 'var(--ink-3)', 'font-size': '10.5' }, gl + '%'));
  }

  const legend = [];
  (accounts || []).forEach((a, i) => {
    const color = seriesColor(i);
    const pts = (a.points || []).slice().sort((p, q) => p.ts - q.ts);
    if (pts.length && pts.some((p) => Number.isFinite(p.seven_day_pct))) {
      const d7 = pts.map((p, idx) => `${idx ? 'L' : 'M'}${x(p.ts)},${y(p.seven_day_pct)}`).join(' ');
      g.appendChild(el('path', { d: d7, fill: 'none', stroke: color, 'stroke-width': '1', 'stroke-dasharray': '3,3', opacity: '.55' }));
    }
    // five_hour_pct, split into critical (>=90, red) vs normal segments.
    let seg = [], critical = null;
    const flush = () => {
      if (seg.length >= 2) {
        const d = seg.map((p, idx) => `${idx ? 'L' : 'M'}${x(p.ts)},${y(p.five_hour_pct)}`).join(' ');
        g.appendChild(el('path', { d, fill: 'none', stroke: critical ? 'var(--critical)' : color, 'stroke-width': '1.6' }));
      }
      seg = [];
    };
    for (const p of pts) {
      const c = p.five_hour_pct >= 90;
      if (critical === null) critical = c;
      if (c !== critical) { seg.push(p); flush(); seg.push(p); critical = c; }
      else seg.push(p);
    }
    flush();
    legend.push(el('span', {}, el('i', { style: `background:${color}` }), a.label));
  });

  const svg = el('svg', { viewBox: `0 0 ${W} ${H}`, width: '100%', height: H }, g);
  return el('div', {}, svg, el('div', { class: 'legend' }, legend));
}

/* --------------------------------------------------------------- composition */

/** composition: one horizontal stacked bar of `[{key, tokens, color}]`, with
 *  a legend giving each part's share. */
export function composition(parts) {
  const total = parts.reduce((a, p) => a + (p.tokens || 0), 0) || 1;
  const segs = parts.filter((p) => p.tokens > 0).map((p) => {
    const pct = (p.tokens / total) * 100;
    const label = `<b>${escapeHTML(p.key)}</b><br>${fmtFull(p.tokens)} tokens · ${pct.toFixed(1)}%`;
    return el('div', {
      style: `flex:${Math.max(0.6, pct)} 0 0;background:${p.color}`,
      onmousemove: (e) => showTip(e, label), onmouseleave: hideTip,
    });
  });
  const bar = el('div', { style: 'display:flex;height:16px;border-radius:4px;overflow:hidden' }, segs);
  const legend = el('div', { class: 'legend' }, parts.map((p) =>
    el('span', {}, el('i', { style: `background:${p.color}` }), `${p.key} ${((p.tokens / total) * 100).toFixed(1)}%`)));
  return el('div', {}, bar, legend);
}

/* ------------------------------------------------------------------ turnBars */

/** turnBars: one bar per turn, height = tokens, coloured by model (fixed
 *  palette order of first-seen models); a sidechain (subagent) turn gets a
 *  hatched overlay so it reads apart from a top-level turn even in grayscale.
 *  `turns` items are `{tokens, model, sidechain}`; `ts`/`effort`/`cost_usd`
 *  are optional and, when present, only enrich the hover tooltip. Follows
 *  `bars()`'s own rule one series/no legend — a legend is only added once
 *  there is more than one model to distinguish (or a sidechain turn, whose
 *  hatch needs its own key since colour alone would not show it). */
export function turnBars(turns) {
  const W = 900, H = 160, PAD = { t: 10, r: 8, b: 8, l: 8 };
  const iw = W - PAD.l - PAD.r, ih = H - PAD.t - PAD.b;
  const max = Math.max(1, ...turns.map((t) => t.tokens || 0));
  const n = Math.max(1, turns.length);
  const bw = Math.max(1, iw / n - 2);
  const models = [];
  for (const t of turns) if (t.model && !models.includes(t.model)) models.push(t.model);
  const anySidechain = turns.some((t) => t.sidechain);

  const defs = el('defs', {}, el('pattern',
    { id: 'ccq-sidechain-hatch', width: '4', height: '4', patternTransform: 'rotate(45)', patternUnits: 'userSpaceOnUse' },
    el('rect', { width: '4', height: '4', fill: 'transparent' }),
    el('line', { x1: '0', y1: '0', x2: '0', y2: '4', stroke: 'var(--surface)', 'stroke-width': '2', 'stroke-opacity': '.6' })));
  const g = el('g', {}, defs);
  turns.forEach((t, i) => {
    const h = Math.max(1, ((t.tokens || 0) / max) * ih);
    const x = PAD.l + i * (iw / n);
    const yTop = PAD.t + ih - h;
    const head = t.ts ? new Date(t.ts).toLocaleTimeString() : (t.model || '?');
    const meta = t.model ? `${escapeHTML(t.model)}${t.effort ? ' · ' + escapeHTML(t.effort) : ''}${t.sidechain ? ' · subagent' : ''}` : '';
    const label = `<b>${escapeHTML(head)}</b>` + (meta ? `<br>${meta}` : '') +
      `<br>${fmtFull(t.tokens || 0)} tokens` + (t.cost_usd != null ? ` · ${fmtUSD(t.cost_usd)}` : '');
    g.appendChild(el('rect', {
      x, y: yTop, width: bw, height: h, fill: models.includes(t.model) ? seriesColor(models.indexOf(t.model)) : OTHER_COLOR,
      onmousemove: (e) => showTip(e, label), onmouseleave: hideTip,
    }));
    if (t.sidechain) g.appendChild(el('rect', { x, y: yTop, width: bw, height: h, fill: 'url(#ccq-sidechain-hatch)' }));
  });

  const svg = el('svg', { viewBox: `0 0 ${W} ${H}`, width: '100%', height: H }, g);
  if (models.length < 2 && !anySidechain) return svg;

  const legend = el('div', { class: 'legend' },
    models.map((name, i) => el('span', {}, el('i', { style: `background:${seriesColor(i)}` }), name)),
    anySidechain ? el('span', {},
      el('i', { style: 'background:repeating-linear-gradient(45deg, var(--ink-3), var(--ink-3) 1px, transparent 1px, transparent 3px)' }),
      'subagent') : null);
  return el('div', {}, svg, legend);
}
