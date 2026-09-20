// web/dist/charts.js — chart + table primitives. DOM-producing, no fetching.
//
// `rankedBars`, `bucketTable`, `bars` (the old page's `timeSeries`), `gauge`,
// `tile` and `tween` are ported from the old <script> block of
// web/dist/index.html (pre-Task-11) — unchanged except where the Task 11
// brief calls for it (rankedBars gains onClick/selectedKey, bucketTable gains
// extraCols, `timeSeries` is renamed `bars`). Everything else here
// (withTable, kpiTile, timeline, stackedArea, heatmap, composition,
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
// one adapter-layer gap worth knowing about (handled in review.js, not
// here): `timeline`/`stackedArea` want `series[i].stack` as a name→tokens
// MAP, but the backend's `Series.Stack` is an ARRAY of Bucket in
// `stack_models` order. Bucket KEYS, by contrast, are read here — every
// shape the rollup emits, by lib/buckets.js's `bucketMs` — so a caller that
// has not normalized (review.js has, for its own reasons) is still safe.
//
// Issue #52: `stackedArea` gained the axes, the hover readout and the
// shared "other" grey it never had. What the two time charts have in
// common now lives in one place each — bucket arithmetic in
// lib/buckets.js, the y scale in `yTicks` below — because the duplication
// is what let them drift into disagreeing about the same data.
//
// Issue #55: two things every chart here used to get wrong on its own, both
// now decided in one place. COLOUR comes from the series' name (lib/
// palette.js) instead of its array index, so a model keeps its hue when the
// ranking moves. SIZE is settled by `chartSvg` below plus the "charts" block
// in styles.css: no pixel height, no `font-size` attribute, because both are
// measured inside a viewBox that scales — which is how the same declared
// `10.5` rendered as ~4px on a phone.
//
// Issue #56: every chart this file returns now carries `role="img"` and an
// `aria-label` that states what the picture is, the span it covers and its
// scale. The rule this encodes, and the reason it is worth stating: a chart
// element with no role is not "partly readable" to a screen reader, it is
// ABSENT — a `<div>` of coloured `<i>`s and an `<svg>` of `<rect>`s announce
// nothing at all. `role="img"` is also deliberately a WALL: it takes the
// drawing's internals out of the accessibility tree, because 168 unlabelled
// heatmap cells or 900 bars were never the data, they were the rendering of
// it. The DATA equivalent is the table the ⊞ toggle swaps in — which is why
// that toggle (`withTable`) now reports its own state, and why the labels
// here summarise rather than enumerate.

import { el, escapeHTML, showTip, hideTip } from './lib/dom.js';
import { fmtInt, fmtUSD, fmtFull, relTime } from './lib/format.js';
import { KIND_LABEL, kindOf, activeSourcesAcross, costLine, fmtSourceCost } from './lib/cost.js';
import { snap, clamp } from './lib/brush.js';
import { bucketMs, densify, inferBucket } from './lib/buckets.js';
import { busiest } from './lib/fold.js';
import { t } from './lib/i18n.js';
import { seriesPalette, OTHER_COLOR } from './lib/palette.js';

// Issue #55: which hue a series gets — and the reason it is the same hue
// after the next refresh — now lives in lib/palette.js, because it is pure
// arithmetic worth testing and because the rule it encodes ("colour follows
// the NAME, never the array index") is the whole point. Re-exported so
// review.js keeps importing its colours from one place.
export { slotColor } from './lib/palette.js';

/** yTicks draws the three-tick y scale every token chart here uses — a
 *  gridline plus a right-aligned number at 0, half and max. `bars`,
 *  `timeline` and `stackedArea` had (or, in stackedArea's case before issue
 *  #52, lacked) byte-identical copies of this; one copy means a chart cannot
 *  quietly ship without a readable scale again. */
function yTicks(g, { max, y, PAD, W }) {
  for (const v of [0, max / 2, max]) {
    g.appendChild(el('line', { x1: PAD.l, x2: W - PAD.r, y1: y(v), y2: y(v), stroke: 'var(--grid)' }));
    g.appendChild(el('text', { x: PAD.l - 8, y: y(v) + 3.5, 'text-anchor': 'end', fill: 'var(--ink-3)' },
      fmtInt(v)));
  }
}

/** axisLabel is what an x-axis tick says for a bucket key: the date, plus
 *  the time when the buckets are finer than a day. Slices the KEY rather
 *  than formatting a Date so it stays in the same (UTC) frame the keys and
 *  every other label on the page are already in — `bars` slices the same
 *  way, and a local-time rendering here would disagree with the table
 *  underneath the chart. */
function axisLabel(key, granularity) {
  const k = String(key);
  return granularity === 'day' || k.length === 10 ? k.slice(5, 10) : k.slice(5, 10) + ' ' + k.slice(11, 16);
}

/** dayLabel is `axisLabel` for a chart whose extent is milliseconds rather
 *  than bucket keys (`timeline`). Same UTC frame and same MM-DD
 *  shape as `axisLabel` and review.js's caption, so an aria-label and the
 *  x-axis under it cannot name different days for the same edge. */
const dayLabel = (ms) => (Number.isFinite(ms) ? new Date(ms).toISOString().slice(5, 10) : '—');

/** chartSvg builds the `<svg>` element every chart in this file returns, and
 *  exists so that the two things issue #55 had to unlearn are unlearnable in
 *  one place:
 *
 *  - **No pixel `height`.** A `viewBox` plus `width:100%` plus a hard
 *    `height` gives `preserveAspectRatio` two dimensions to satisfy, so it
 *    scales to fit the tighter one and centres the rest. A 900x190 chart in
 *    a 1104px card drew at 900px with ~100px of white on each side; the same
 *    chart on a 340px phone drew 72px of content inside a 190px box, i.e.
 *    118px of dead white. Leaving the height out lets `height:auto` (in
 *    styles.css) take the ratio from the viewBox, so the drawing simply
 *    fills its slot at every width.
 *  - **No `font-size` attribute on the tick labels.** Text inside a viewBox
 *    is measured in USER UNITS, so a declared `10.5` is 10.5px only when the
 *    chart happens to render at its design width — it was ~4px on a phone,
 *    and two charts in one row disagreed whenever their `W` did. `--cw`
 *    hands the design width to styles.css, which divides it out. See the
 *    "charts" block there.
 *
 *  `extra` carries whatever the individual chart adds (role / aria-label). */
const chartSvg = (W, H, extra, g) =>
  el('svg', { viewBox: `0 0 ${W} ${H}`, width: '100%', class: 'chart', style: `--cw:${W}`, ...extra }, g);

/** Utilization -> status. Four named bands so the label, not the hue, is what
 *  carries the meaning. */
// `key` drives the CSS class and never changes; `label` is what a reader sees.
const band = (pct) =>
  pct >= 90 ? { key: 'critical', label: t('gauge.critical') }
  : pct >= 75 ? { key: 'serious', label: t('gauge.high') }
  : pct >= 50 ? { key: 'warning', label: t('gauge.moderate') }
  : { key: 'good', label: t('gauge.healthy') };

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
 *  shortened label.
 *
 *  Issue #51 adds the three things a SIDE-BY-SIDE pair of these needs:
 *    - `max` (option): the scale to draw at, instead of this list's own
 *      largest row. Two lists of the same quantity drawn at one `max` are
 *      comparable by eye — without it each normalized to its own first row,
 *      so a full-width bar here and a full-width bar there were different
 *      numbers. Compute it with format.js's `scaleMax` over BOTH lists.
 *    - `r.prev` (row): the previous period, drawn as a thin marker on the
 *      track at the same scale, with `r.prevTitle` as its hover text. The
 *      change stops being a string at the end of the line.
 *    - `r.rightTitle` (row): hover text for the clipped `.v` column.
 *
 *  Issue #99 adds the two a row needs to stop being a dead end:
 *    - `r.cells` (row): the right-hand column as SEPARATE, aligned figures —
 *      `[{text, class, title}]` — instead of one `r.right` string. `.v` is a
 *      narrow column with `text-overflow: ellipsis`, so a caller packing
 *      three facts into one string got the last one eaten on every row and
 *      the ones that survived did not line up down the list. Cells are laid
 *      out right to left with their own widths, so a column of figures reads
 *      as a column. `r.right` still works and is unchanged for every caller
 *      that passes it.
 *    - `r.href` (row): a real link at the end of the row, a SECOND and
 *      explicit way in that does not replace `onClick`. The two do different
 *      things — on the breakdown cards `onClick` adds a filter chip and the
 *      link opens that key's own page — so the link stops the click at
 *      itself rather than letting the row's handler also fire. It is an
 *      `<a href>`, not a button, because the point is that it behaves like a
 *      link: middle-click, cmd-click and "open in new tab" all work.
 *      `r.hrefLabel` is its accessible name (it renders as a glyph, which is
 *      not one) and `r.hrefText` overrides the glyph. */
export function rankedBars(rows, { onClick, selectedKey, max: fixedMax } = {}) {
  // An EXPLICIT max wins outright — it is not merged with this list's own
  // largest row. That is the entire contract: two lists drawn at the same
  // `max` can be compared by eye, and quietly widening one of them to fit
  // its own tallest row would silently break exactly the promise the caller
  // passed it to make. A value past the scale clamps to full width instead
  // (see `Math.min(100, …)` below) — callers compute the shared max with
  // format.js's `scaleMax` over EVERY list, so in practice nothing clamps.
  const max = Number.isFinite(fixedMax) && fixedMax > 0
    ? fixedMax
    : Math.max(...rows.map((r) => r.value), 1);
  return el('div', { class: 'bars' }, rows.map((r) => {
    const sel = selectedKey != null && r.key === selectedKey;
    const display = r.label || r.key;
    // The previous period, ON the track at the same scale as the fill: a
    // reader sees which way a row moved without reading a number, and the
    // marker's distance from the bar's end IS the change. `r.prev` absent
    // (or zero — the API sends no previous bucket for a key that did not
    // exist) means there is nothing to mark, which is different from
    // marking zero.
    const prevPct = r.prev > 0 ? Math.min(100, (r.prev / max) * 100) : null;
    // FIX (execution review, Finding 4): a display label can differ from
    // the raw identity enough that the identity is worth keeping visible
    // somewhere (a shortened project path is not the full path) — `r.title`
    // lets a caller say so explicitly; every existing caller leaves it unset
    // and gets exactly the old title (the display text itself).
    const tipTitle = r.title || display;
    return el('div', {
        class: 'bar-row' + (sel ? ' sel' : ''),
        role: onClick ? 'button' : null,
        // Issue #56: focusable when the row is a BUTTON, and also when it
        // merely carries a `tip` — because the tip is where the figures the
        // row does not print live: the untruncated share (review.js's
        // breakdown rows clip `.v` to an ellipsis) and now.js's "this is an
        // estimate" caveat, which appears nowhere else on the page. Hover was
        // the only way in, so a keyboard or switch user could not reach it at
        // all. A tabstop plus the two handlers below is the whole fix: `#tip`
        // is already a `role="status"` live region, so filling it on focus is
        // what makes it spoken.
        tabindex: onClick || r.tip ? '0' : null,
        onmousemove: r.tip ? (e) => showTip(e, r.tip) : null,
        onmouseleave: r.tip ? hideTip : null,
        onfocus: r.tip ? (e) => showTip(e, r.tip) : null,
        onblur: r.tip ? hideTip : null,
        onclick: onClick ? () => onClick(r) : null,
        onkeydown: onClick ? (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onClick(r); } } : null,
      },
      el('div', { class: 'k', title: tipTitle }, display),
      el('div', { class: 'bar-track' },
        el('div', { class: 'bar-fill',
          style: `width:${Math.min(100, Math.max(1.5, (r.value / max) * 100))}%${r.color ? ';background:' + r.color : ''}` }),
        prevPct == null ? null
          : el('i', { class: 'bar-prev', style: `left:${prevPct}%`, title: r.prevTitle || null })),
      // FIX (issue #51): `.v` is clipped by CSS in a narrow `.grid2` column
      // (styles.css `overflow:hidden; text-overflow:ellipsis`), and with no
      // title the clipped half — cost, share, change — was unrecoverable.
      // `r.rightTitle` lets a caller put the LONGER form here (absolute
      // change, exact figures); otherwise the hover simply restores the
      // string that was cut — unless the row already carries a floating
      // `r.tip` saying more than the clipped line did, in which case a
      // native tooltip would only fight with it for the same hover.
      // `r.cells` (issue #99) draws the same column as a row of figures that
      // keep their own widths, so tokens sit under tokens and shares under
      // shares. `r.right` is the original single string and is untouched.
      el('div', { class: 'v', title: r.rightTitle || (r.tip || typeof r.right !== 'string' ? null : r.right) },
        Array.isArray(r.cells)
          ? r.cells.map((c) => el('span', { class: 'vc' + (c.class ? ' ' + c.class : ''), title: c.title || null }, c.text))
          : r.right,
        // INSIDE `.v`, not in a fourth grid column. A fourth column comes out
        // of the `1fr` the TRACK is drawn in, so a card with links would draw
        // a shorter bar for the same number than a card without — which is
        // precisely the promise `max` exists to make (issue #51: two lists on
        // one scale are comparable by eye). Measured while building this: 22px
        // of link column plus its gap took ~60px off the track, and a
        // side-by-side pair disagreed about how long 717,858 tokens is.
        //
        // It survives `.v`'s ellipsis anyway: `.v` packs from the right, so
        // overflow falls off the LEFT, and the link is `flex: none` while the
        // figure cells shrink. The thing that clips is a number the tip still
        // carries; the way out of the card is not.
        r.href
          ? el('a', {
              class: 'drill-in', href: r.href,
              'aria-label': r.hrefLabel || null, title: r.hrefLabel || null,
              // The row is a button that filters; this link opens a page. A
              // click that did both would filter the list the reader is
              // leaving, and that state change would be waiting for them on
              // the way back.
              onclick: (e) => e.stopPropagation(),
              onkeydown: (e) => e.stopPropagation(),
            }, r.hrefText || '↗')
          : null));
  }));
}

/** bucketTable is the relief the palette validator requires in light mode, and
 *  the accessible fallback for anyone who cannot read the charts. `extraCols`
 *  (Review's compare-with-previous-period columns) is
 *  `[{label, value(b), at}]`, appended after Unpriced; omitted it behaves
 *  exactly as before.
 *
 *  `at: 'tokens'` instead puts a column immediately after the tokens column
 *  (issue #51). Comparison is a reading distance: "tokens" and "prev tokens"
 *  landing at opposite ends of the row, with two or more cost columns
 *  between them, made the table's one job — read the two numbers, subtract —
 *  a scroll. Columns keep their given order within each position.
 *
 *  Cost is ONE COLUMN PER SOURCE, headed with the kind of money it is, and
 *  there is no total column. The three figures the hub holds are not addable —
 *  a Claude column is an API-equivalent estimate for work billed by
 *  subscription, a gateway column is an actual per-call charge — so a "Cost"
 *  column summing whichever of them a scope happened to contain was a number
 *  with no meaning and no way to notice. Only sources with usage in these
 *  buckets get a column, so a single-source hub still shows exactly one.
 *
 *  `keyHref(b)` (issue #99) makes the key cell a link to that row's own page.
 *  It travels with the table rather than being left to the chart, because
 *  this table IS the chart for anyone the drawing does not serve — a drill-in
 *  that only exists in the bars is a door behind a picture. Returning a falsy
 *  value for a row leaves that cell as plain text. */
const keyCell = (b, keyHref) => {
  const text = b.label || b.key || t('common.unknown');
  const href = typeof keyHref === 'function' ? keyHref(b) : null;
  return href ? el('a', { href }, text) : text;
};

export function bucketTable(buckets, keyLabel, extraCols = [], { keyHref } = {}) {
  // Only BILLED sources get a money column. A subscription source's column was
  // an API-equivalent estimate of money nobody was charged; now that the page
  // does not print that figure, the column would be dashes all the way down —
  // worse than absent, because an empty column reads as missing data.
  const sources = activeSourcesAcross(buckets).filter((s) => kindOf(s) === 'billed');
  const besideTokens = extraCols.filter((c) => c.at === 'tokens');
  const trailing = extraCols.filter((c) => c.at !== 'tokens');
  return el('div', { class: 'scroll' }, el('table', {},
    el('thead', {}, el('tr', {},
      el('th', {}, keyLabel),
      el('th', { class: 'num' }, t('chart.turns')),
      el('th', { class: 'num' }, t('chart.tokens')),
      ...besideTokens.map((c) => el('th', { class: 'num', title: c.title || null }, c.label)),
      ...sources.map((s) => el('th', { class: 'num', title: t('chart.sourceCostTip', { source: s, kind: KIND_LABEL[kindOf(s)] }) },
        `${s} $`, el('span', { class: 'kind' }, ` ${KIND_LABEL[kindOf(s)]}`))),
      el('th', { class: 'num' }, t('chart.unpriced')),
      ...trailing.map((c) => el('th', { class: 'num', title: c.title || null }, c.label)))),
    el('tbody', {}, buckets.map((b) => el('tr', {},
      el('td', { title: b.key }, keyCell(b, keyHref)),
      el('td', { class: 'num' }, fmtFull(b.events)),
      el('td', { class: 'num' }, fmtFull(b.tokens)),
      ...besideTokens.map((c) => el('td', { class: 'num' }, c.value(b))),
      ...sources.map((s) => el('td', { class: 'num' }, fmtSourceCost(b, s))),
      el('td', { class: 'num' }, b.unpriced_events ? fmtFull(b.unpriced_events) : '—'),
      ...trailing.map((c) => el('td', { class: 'num' }, c.value(b))))))));
}

/** withTable pairs a chart element with its table fallback under one card,
 *  toggled by a ⊞ button whose state is remembered per card id.
 *
 *  Issue #56: this button is the page's designated way out of every chart
 *  above — the data as a table, for anyone the drawing does not serve — and
 *  it was a bare glyph with a `title`. That gave it no name in the
 *  accessibility tree (a `title` on a button is a last-resort name at best,
 *  and `⊞` itself announces as a box-drawing character), no way to tell
 *  which of its two states it was in, and nothing connecting it to the thing
 *  it swaps in. All three are now stated: `aria-label` names it,
 *  `aria-expanded` reports whether the table is showing AND is rewritten on
 *  every click (a state attribute that is only correct on first render is
 *  worse than none — it asserts something false), and `aria-controls` points
 *  at the table, which takes an id derived from `cardId` since that is
 *  already unique per card. */
export function withTable(card, chartEl, tableEl, cardId) {
  const key = 'ccquota-table:' + cardId;
  let showingTable = false;
  try { showingTable = localStorage.getItem(key) === '1'; } catch {}
  chartEl.hidden = showingTable;
  tableEl.hidden = !showingTable;
  if (!tableEl.id) tableEl.id = 'tbl-' + cardId;
  const btn = el('button', {
    class: 'tbl', type: 'button', title: t('chart.toggleTable'),
    'aria-label': t('chart.toggleTable'),
    'aria-expanded': String(showingTable),
    'aria-controls': tableEl.id,
    onclick: () => {
      showingTable = !showingTable;
      chartEl.hidden = showingTable;
      tableEl.hidden = !showingTable;
      btn.setAttribute('aria-expanded', String(showingTable));
      try { localStorage.setItem(key, showingTable ? '1' : '0'); } catch {}
    },
  }, '⊞');
  // The toggle goes FIRST in the DOM. It is `position:absolute` (styles.css),
  // so nothing about the rendering changes — but in reading and tab order it
  // used to come after the entire chart AND the entire table, and a fallback
  // you only reach by tabbing past the thing you could not read is not one.
  card.append(btn, chartEl, tableEl);
  return card;
}

/* ------------------------------------------------------------------ gauge */

/** gauge is ONE window's reading: what share of it is spent, on a bar, and when
 *  it resets.
 *
 *  #95 rewrote its SHAPE — it used to be a name/percent/state/reset row, a bar,
 *  and then a full sentence of its own ("At the current rate (22.6%/h) this
 *  window fills around 03:25 AM."), about 75px per window. The brief for this
 *  card is "make the current utilization the biggest number, and let everything
 *  else fall back to second place", and the old layout could not do that however
 *  large the percent was set: a sentence on its own line reads as a peer of the
 *  thing above it, and there were two windows per subscription and up to five
 *  subscriptions on the card.
 *
 *  So the row is one line with one trailing `.meta` string. The percent keeps
 *  its size and everything else shrank around it, which is the only way one
 *  number becomes the big one on a card where every row wants to be read.
 *
 *  The state LABEL stays, and is not the hue's spare tyre: styles.css's rule is
 *  that status colour is always reinforced by the word beside it, never carried
 *  alone, which is what makes this legible to a reader who cannot separate the
 *  four band colours. Shrinking it was allowed; dropping it was not.
 *
 *  The row's own element is `display: contents` (styles.css), so the cells land
 *  in the ENCLOSING grid and the five columns line up across every subscription
 *  in a group rather than each row measuring itself. That is why this returns a
 *  flat row and not a self-contained box. */
export function gauge(name, w) {
  const pct = Math.max(0, Math.min(100, Number(w.utilization) || 0));
  const b = band(pct);

  // The reset time, and nothing else. This line has now been argued both ways,
  // so both are on the record.
  //
  // #124 removed the reset countdown and kept the burn rate, on this reasoning,
  // which is quoted rather than paraphrased because reversing a decision is not
  // a licence to rewrite what it said: "a window that resets in two hours and
  // one that resets in five behave identically to a reader who is at 17%, and
  // the number that DOES change what they do next is the burn rate already
  // sitting beside it."
  //
  // #129 reverses it on the operator's direction: the burn rate goes, the reset
  // time comes back on EVERY window. The rate answers "how fast is this
  // filling", which is a question about the past five minutes and swings with
  // them; the reset answers "when do I get this back", which is a fact about
  // the window and is the one a reader plans around. Where the two conflict,
  // the operator's call stands — so this is the fourth reversal this batch has
  // had to write down rather than quietly re-decide.
  //
  // `relTime` came back verbatim from fd1d888 (lib/format.js), not rewritten:
  // the removed version is the one the five `reset.*` keys were written for.
  //
  // What did NOT change either time: `w.resets_at` on the wire. It still drives
  // the burn forecast (recon.go) even though that forecast is no longer
  // printed, plus the endpoint-share window, the contradiction check and the
  // account fingerprint. `w.burn` is likewise still computed and still sent;
  // this row simply stopped reading it.
  const meta = relTime(w.resets_at);

  return el('div', { class: 'gauge' },
    el('span', { class: 'name' }, name),
    // Whole percent. A tenth of a percent of a five-hour window is under two
    // minutes of work — below what anyone acts on — and `.pct` is tabular-nums,
    // so dropping the decimal narrows the column for every row at once.
    el('span', { class: 'pct' }, Math.round(pct) + '%'),
    el('span', { class: 'state st-' + b.key }, b.label),
    el('div', { class: 'track' }, el('div', { class: 'fill bg-' + b.key, style: `width:${pct}%` })),
    el('span', { class: 'meta' }, meta));
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

  const y = (v) => PAD.t + ih - (v / max) * ih;

  const g = el('g', {});
  yTicks(g, { max, y, PAD, W });

  const peak = series.reduce((a, b) => (b.tokens > a.tokens ? b : a), series[0]);
  series.forEach((s, i) => {
    const h = Math.max(s.tokens > 0 ? 1.5 : 0, (s.tokens / max) * ih);
    const x = PAD.l + i * (iw / n);
    const label = `<b>${escapeHTML(s.key)}</b><br>` +
      `${escapeHTML(t('chart.tip.tokens', { tokens: fmtFull(s.tokens) }))}<br>` +
      `${escapeHTML(t('chart.tip.turnsCost', { turns: fmtFull(s.events), cost: costLine(s) }))}`;
    g.appendChild(el('rect', {
      x, y: y(s.tokens), width: bw, height: h, rx: 2, fill: 'var(--s1)',
      onmousemove: (e) => showTip(e, label),
      onmouseleave: hideTip,
    }, el('title', {}, t('chart.tip.barTitle', { key: s.key, tokens: fmtFull(s.tokens) }))));
  });

  // Selective labels: first, last and the peak — never a number on every bar.
  const labelAt = (s, i, anchor) => {
    const x = PAD.l + i * (iw / n) + bw / 2;
    return el('text', { x, y: H - 8, 'text-anchor': anchor, fill: 'var(--ink-3)' },
      granularity === 'hour' ? s.key.slice(11, 16) : s.key.slice(5));
  };
  g.appendChild(labelAt(series[0], 0, 'start'));
  if (n > 1) g.appendChild(labelAt(series[n - 1], n - 1, 'end'));
  const pi = series.indexOf(peak);
  if (n > 4 && pi > 1 && pi < n - 2) g.appendChild(labelAt(peak, pi, 'middle'));

  return chartSvg(W, H, {
    role: 'img', 'aria-label': t('chart.ariaTokensPer', { granularity, peak: fmtInt(max) }) }, g);
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

  // Bucket keys arrive in any of the shapes the rollup emits; lib/buckets.js
  // owns that parsing now (issue #52 gave stackedArea a real time axis and
  // needed the identical reader — one copy, so the two charts on this page
  // cannot date the same bucket differently).
  const keyMs = (s) => bucketMs(s.key);
  const xOf = (ms) => PAD.l + ((ms - ext.start) / span) * iw;

  // Stack heights per bucket, in the order the caller ranked them (+ "other"
  // last). The COLOURS do not follow that order — `stack_models` is ranked by
  // tokens in the current window, so following it is what made a model change
  // hue whenever the span moved (issue #55). seriesPalette keys off the name.
  const names = [...stackNames];
  const colors = seriesPalette(names);
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
      return { ms, parts, other, total: acc + other, s, stacked: true };
    }
    max = Math.max(max, s.tokens || 0);
    return { ms, parts: [s.tokens || 0], other: 0, total: s.tokens || 0, s, stacked: false };
  });

  const g = el('g', {});
  const y = (v) => PAD.t + ih - (v / max) * ih;
  yTicks(g, { max, y, PAD, W });
  built.forEach(({ ms, parts, other, total, s }) => {
    const x = xOf(ms);
    let base = 0;
    const label = `<b>${escapeHTML(String(s.key))}</b><br>${escapeHTML(t('chart.tip.tokens', { tokens: fmtFull(total) }))}`;
    const segs = other ? [...parts, other] : parts;
    segs.forEach((v, i) => {
      if (!v) return;
      const h = Math.max(0, (v / max) * ih);
      g.appendChild(el('rect', {
        x, y: y(base + v), width: bw, height: h,
        fill: i < names.length ? colors[i] : OTHER_COLOR,
        onmousemove: (e) => showTip(e, label), onmouseleave: hideTip,
      }));
      base += v;
    });
  });

  // The span comes from `ext`, not from the first and last buckets: the chart
  // is DRAWN over the extent, and a quiet stretch at either end means the
  // buckets stop short of it. Naming the buckets' own edges would tell a
  // reader the chart covers less time than the axis under it does.
  //
  // Two labels, picked by what was actually DRAWN rather than by what this
  // helper CAN draw (issue #103). The label said "stacked by model"
  // unconditionally, which was true of the only caller until that caller
  // stopped stacking -- at which point a sighted reader saw plain bars while a
  // screen reader was told about a breakdown that was not there. A chart's
  // name has to be a fact about its pixels, so `built` decides it: the flag is
  // set on the branch that actually laid out segments, not inferred from the
  // segment count (a one-model stack draws one band and is still a stack).
  const stacked = built.some((b) => b.stacked);
  const svg = chartSvg(W, H, {
    role: 'img',
    'aria-label': t(stacked ? 'chart.ariaTimelineStacked' : 'chart.ariaTimeline', {
      from: dayLabel(ext.start), to: dayLabel(ext.end), peak: fmtInt(max) }),
  }, g);
  const container = el('div', { class: 'timeline', tabindex: '-1' });

  // The brush is positioned against the PLOT, not against `.timeline`: the
  // legend and the caption are appended to the container below, and a
  // `bottom` measured from the container's own edge therefore moved every
  // time one of them appeared. `--axis-band` is the x-axis strip as a share
  // of the plot's height, so the brush stops exactly at the axis at any
  // width — the same reason `paint()` below works in percentages (issue #55
  // dropped the pixel `height` that used to make one of those two a
  // constant).
  const plot = el('div', { class: 'plot', style: `--axis-band:${(PAD.b / H) * 100}%` }, svg);
  container.appendChild(plot);

  // The brush sits OUTSIDE the svg (it is an overlay div), so `role="img"`
  // above does not hide it — which matters, because it is a `tabindex="0"`
  // element that had no name at all: focus landed on it and a screen reader
  // said nothing, on the one control that changes what every other card is
  // showing. The label says what it is and what the arrow keys do; the
  // selected range itself is printed as text in the caption below.
  const brush = el('div', {
      class: 'brush', tabindex: '0', role: 'group', 'aria-label': t('chart.ariaBrush') },
    el('div', { class: 'h l' }), el('div', { class: 'h r' }));
  plot.appendChild(brush);

  // A stack of up to 7 series (6 top models + "other") with no legend is
  // unreadable — every other multi-series chart here (stackedArea,
  // composition) builds one; this one didn't. Same palette order the stack
  // itself is drawn in (built.forEach above: `i < names.length ?
  // colors[i] : OTHER_COLOR`), so the mapping is actually correct.
  if (names.length) {
    const hasOther = built.some((b) => b.other > 0);
    const legend = el('div', { class: 'legend' },
      names.map((name, i) => el('span', {}, el('i', { style: `background:${colors[i]}` }), name)),
      hasOther ? el('span', {}, el('i', { style: `background:${OTHER_COLOR}` }), t('chart.other')) : null);
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

/** stackedArea: one cumulative SVG path per stack name (palette order) over
 *  a real TIME axis, with the y scale, the x labels, the hover readout and
 *  the grey "other" the timeline directly above it already had. Before issue
 *  #52 it had none of them: no tick anywhere (`PAD` was 8 on every side, so
 *  there was nowhere to put one), x by ARRAY INDEX over a series whose empty
 *  buckets the API never sends — so the axis was neither time nor labelled —
 *  zero hover, and "other" drawn in a palette hue while the chart above it
 *  drew the same word grey.
 *
 *  `series` items are `{key, stack: {name: value, ...}}`, `key` in any shape
 *  lib/buckets.js's `bucketMs` reads. `stackNames` must be the TOP names
 *  only: anything in a bucket's `stack` that is NOT in it folds into "other"
 *  and is drawn in OTHER_COLOR — the same rule `timeline` applies, which is
 *  what keeps one word one colour down the page. Pass 'other' inside
 *  `stackNames` and it takes a palette hue instead, which was exactly the
 *  bug. Options:
 *    - `bucket` (ms): the bucket width. Used to put back the buckets
 *      /v1/history omitted (lib/buckets.js's `densify`) so a gap reads as
 *      the zero it is instead of the area interpolating across it, and to
 *      give the last bucket its own width on the axis. Inferred from the
 *      data when absent.
 *    - `granularity`: picks how much of the key the two x labels show.
 *
 *  Why this is not simply `timeline` with a different fill: timeline exists
 *  to own the BRUSH — pointer capture, snapping, an absolutely-positioned
 *  `.brush` overlay, keyboard nudging — and it draws discrete bars because
 *  each bar is a brush target. This is a continuous area with no selection
 *  model at all, and it lives in a half-width card. Merging them would mean
 *  carrying that whole interaction layer behind a flag. What is genuinely
 *  shared is the bucket arithmetic (now lib/buckets.js) and the y scale
 *  (now `yTicks`) — so those are shared, and the duplication that let the
 *  two drift apart is gone. */
export function stackedArea(series, stackNames, opts = {}) {
  const W = 560, H = 190, PAD = { t: 14, r: 8, b: 26, l: 46 };
  const iw = W - PAD.l - PAD.r, ih = H - PAD.t - PAD.b;
  const names = stackNames || [];
  const colors = seriesPalette(names);
  const { granularity } = opts;

  const raw = (series || [])
    .map((s) => ({ ms: bucketMs(s.key), key: String(s.key), stack: s.stack || {} }))
    .filter((p) => Number.isFinite(p.ms))
    .sort((a, b) => a.ms - b.ms);
  if (!raw.length) return el('div', { class: 'empty' }, t('common.noUsagePeriod'));

  const bw = opts.bucket > 0 ? opts.bucket : (inferBucket(raw.map((p) => p.ms)) || 36e5);
  const pts = densify(raw, bw);

  // Anything the caller did not name is "other" — one grey band, exactly as
  // timeline folds it, rather than a series that quietly vanishes.
  const otherOf = (p) => Object.entries(p.stack || {})
    .reduce((a, [k, v]) => a + (names.includes(k) ? 0 : (v || 0)), 0);
  const valueOf = (p, name) => (p.stack && p.stack[name]) || 0;
  const totals = pts.map((p) => names.reduce((a, n) => a + valueOf(p, n), 0) + otherOf(p));
  const max = Math.max(1, ...totals);

  // The axis spans the time the buckets COVER: the last bucket owns [t1,
  // t1+bw), so the domain ends there and every bucket gets an equal slot.
  const t0 = pts[0].ms, t1 = pts[pts.length - 1].ms + bw;
  const span = Math.max(1, t1 - t0);
  const x = (ms) => PAD.l + ((ms - t0) / span) * iw;
  const y = (v) => PAD.t + ih - (v / max) * ih;
  const slot = Math.max(1, (bw / span) * iw);

  const g = el('g', {});
  yTicks(g, { max, y, PAD, W });

  // A bucket's value is plotted at its own CENTRE, then held flat out to
  // each edge of the plot. Anchoring at the left edge instead would shift
  // every reading half a bucket earlier than the tooltip and the table say
  // it happened, and stopping at the last centre would leave a bucket of
  // blank canvas that reads as "no data" rather than "the axis ended".
  const along = (vals) => [
    [PAD.l, y(vals[0])],
    ...vals.map((v, i) => [x(pts[i].ms + bw / 2), y(v)]),
    [PAD.l + iw, y(vals[vals.length - 1])],
  ];
  const bands = [...names, null];   // null = the folded "other" band, drawn last
  let base = new Array(pts.length).fill(0);
  bands.forEach((name, si) => {
    const add = pts.map((p) => (name == null ? otherOf(p) : valueOf(p, name)));
    if (!add.some((v) => v > 0)) { return; }
    const top = base.map((v, i) => v + add[i]);
    const d = 'M' + along(top).map((p) => p.join(',')).join('L')
            + 'L' + along(base).reverse().map((p) => p.join(',')).join('L') + 'Z';
    g.appendChild(el('path', { d, fill: name == null ? OTHER_COLOR : colors[si], 'fill-opacity': '0.85' }));
    base = top;
  });

  // One transparent full-height band per bucket: hovering anywhere in a
  // column reads out THAT bucket, which is the question this card exists to
  // answer ("what was the mix at this moment"), and a per-path hover could
  // not answer it at all. Each band also carries a native <title>, so a
  // touch device or a pointer-less environment still gets the total — the
  // same fallback `bars` gives its rects.
  pts.forEach((p, i) => {
    const total = totals[i];
    const rows = [...names.map((n) => [n, valueOf(p, n)]), [t('chart.other'), otherOf(p)]]
      .filter(([, v]) => v > 0)
      .sort((a, b) => b[1] - a[1]);
    const label = `<b>${escapeHTML(axisLabel(p.key, granularity))}</b><br>`
      + escapeHTML(t('chart.tip.tokens', { tokens: fmtFull(total) }))
      + rows.map(([n, v]) => '<br>' + escapeHTML(t('chart.tip.mixRow', {
          name: n, tokens: fmtFull(v), pct: ((v / total) * 100).toFixed(0) + '%' }))).join('');
    g.appendChild(el('rect', {
      x: x(p.ms), y: PAD.t, width: slot, height: ih, fill: 'transparent',
      onmousemove: (e) => showTip(e, label), onmouseleave: hideTip,
    }, el('title', {}, t('chart.tip.barTitle', {
      key: axisLabel(p.key, granularity), tokens: fmtFull(total) }))));
  });

  // Ends only, like `bars` — a label per bucket would be unreadable at this
  // width, and the hover readout names every bucket in between.
  const tick = (key, at, anchor) => el('text', { x: at, y: H - 8, 'text-anchor': anchor,
    fill: 'var(--ink-3)' }, axisLabel(key, granularity));
  g.appendChild(tick(pts[0].key, PAD.l, 'start'));
  if (pts.length > 1) g.appendChild(tick(pts[pts.length - 1].key, PAD.l + iw, 'end'));

  const svg = chartSvg(W, H, {
    role: 'img', 'aria-label': t('chart.ariaModelMix', {
      from: axisLabel(pts[0].key, granularity),
      to: axisLabel(pts[pts.length - 1].key, granularity),
      peak: fmtInt(max) }) }, g);
  const hasOther = pts.some((p) => otherOf(p) > 0);
  const legend = el('div', { class: 'legend' },
    names.map((name, i) => el('span', {}, el('i', { style: `background:${colors[i]}` }), name)),
    hasOther ? el('span', {}, el('i', { style: `background:${OTHER_COLOR}` }), t('chart.other')) : null);
  return el('div', {}, svg, legend);
}

/* ------------------------------------------------------------------ heatmap */

const DOW = [0, 1, 2, 3, 4, 5, 6].map((d) => t('day.' + d));

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
      const label = `<b>${escapeHTML(DOW[dow])} ${String(hour).padStart(2, '0')}:00</b><br>`
        + escapeHTML(t('chart.tip.tokensTurns', { tokens: fmtFull(tokens), turns: fmtFull(turns) }));
      cells.push(el('i', {
        style: tokens > 0 ? `background:color-mix(in srgb, var(--s1) ${pct}%, var(--grid))` : null,
        title: t('chart.tip.heatCell', {
          day: DOW[dow], hour: String(hour).padStart(2, '0') + ':00',
          tokens: fmtFull(tokens), turns: fmtFull(turns) }),
        onmousemove: tokens > 0 ? (e) => showTip(e, label) : null,
        onmouseleave: tokens > 0 ? hideTip : null,
      }));
    });
  });
  // One summary, not 168 labelled cells. Each `<i>` keeps its `title` for a
  // pointer, but under `role="img"` they leave the accessibility tree on
  // purpose: walking 168 unlabelled `<i>`s taught a screen reader nothing,
  // and the honest equivalent of this grid is the table the ⊞ toggle swaps in
  // (review.js's `when` card) plus fold.js's `sentence()` printed under it.
  // Giving the grid real row/column semantics is its own issue — this is the
  // label, which is what the grid was missing entirely.
  const b = busiest(grid);
  return el('div', {
    class: 'heat', role: 'img',
    'aria-label': b.tokens > 0
      ? t('chart.ariaHeatmap', {
          day: DOW[b.dow], hour: String(b.hour).padStart(2, '0') + ':00', tokens: fmtFull(b.tokens) })
      : t('chart.ariaHeatmapEmpty'),
  }, cells);
}

/* --------------------------------------------------------------- composition */

/** composition: one horizontal stacked bar of `[{key, tokens, color}]`, with
 *  a legend giving each part's share. */
export function composition(parts) {
  const total = parts.reduce((a, p) => a + (p.tokens || 0), 0) || 1;
  const segs = parts.filter((p) => p.tokens > 0).map((p) => {
    const pct = (p.tokens / total) * 100;
    const label = `<b>${escapeHTML(p.key)}</b><br>`
      + escapeHTML(t('chart.tip.tokensPct', { tokens: fmtFull(p.tokens), pct: pct.toFixed(1) + '%' }));
    return el('div', {
      style: `flex:${Math.max(0.6, pct)} 0 0;background:${p.color}`,
      onmousemove: (e) => showTip(e, label), onmouseleave: hideTip,
    });
  });
  // The label names the graphic and its biggest slice, and stops there: the
  // legend directly below is real text that already gives every part and its
  // share, so enumerating them here would make a screen reader read the same
  // five figures twice before reaching anything new.
  const top = parts.reduce((a, p) => ((p.tokens || 0) > (a.tokens || 0) ? p : a), { key: '', tokens: 0 });
  const bar = el('div', {
    role: 'img',
    'aria-label': t('chart.ariaComposition', {
      name: top.key || t('common.unknown'), pct: ((top.tokens || 0) / total * 100).toFixed(1) + '%' }),
    style: 'display:flex;height:16px;border-radius:4px;overflow:hidden',
  }, segs);
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
  const max = Math.max(1, ...turns.map((turn) => turn.tokens || 0));
  const n = Math.max(1, turns.length);
  const bw = Math.max(1, iw / n - 2);
  const models = [];
  for (const turn of turns) if (turn.model && !models.includes(turn.model)) models.push(turn.model);
  // First-seen order decides the DRAWING order of the legend; it used to
  // decide the colours too, so "load more" — which can only ever prepend an
  // earlier turn — repainted the whole session (issue #55).
  const colors = seriesPalette(models);
  const anySidechain = turns.some((turn) => turn.sidechain);

  const defs = el('defs', {}, el('pattern',
    { id: 'ccq-sidechain-hatch', width: '4', height: '4', patternTransform: 'rotate(45)', patternUnits: 'userSpaceOnUse' },
    el('rect', { width: '4', height: '4', fill: 'transparent' }),
    el('line', { x1: '0', y1: '0', x2: '0', y2: '4', stroke: 'var(--surface)', 'stroke-width': '2', 'stroke-opacity': '.6' })));
  const g = el('g', {}, defs);
  turns.forEach((turn, i) => {
    const h = Math.max(1, ((turn.tokens || 0) / max) * ih);
    const x = PAD.l + i * (iw / n);
    const yTop = PAD.t + ih - h;
    const head = turn.ts ? new Date(turn.ts).toLocaleTimeString() : (turn.model || '?');
    const meta = turn.model
      ? `${escapeHTML(turn.model)}${turn.effort ? ' · ' + escapeHTML(turn.effort) : ''}${turn.sidechain ? ' · ' + escapeHTML(t('chart.subagent')) : ''}`
      : '';
    const label = `<b>${escapeHTML(head)}</b>` + (meta ? `<br>${meta}` : '') +
      `<br>${escapeHTML(t('chart.tip.tokens', { tokens: fmtFull(turn.tokens || 0) }))}` +
      (turn.cost_usd != null ? ` · ${escapeHTML(fmtUSD(turn.cost_usd))}` : '');
    g.appendChild(el('rect', {
      x, y: yTop, width: bw, height: h, fill: models.includes(turn.model) ? colors[models.indexOf(turn.model)] : OTHER_COLOR,
      onmousemove: (e) => showTip(e, label), onmouseleave: hideTip,
    }));
    if (turn.sidechain) g.appendChild(el('rect', { x, y: yTop, width: bw, height: h, fill: 'url(#ccq-sidechain-hatch)' }));
  });

  // This one is returned BARE when there is nothing to put in a legend, so
  // the label is the only thing a reader gets from the drawing — hence the
  // turn count and the peak, not just "tokens per turn". The per-turn
  // figures are in the turns table session.js renders directly underneath.
  const svg = chartSvg(W, H, {
    role: 'img',
    'aria-label': t('chart.ariaTurnBars', { turns: fmtInt(turns.length), peak: fmtInt(max) }),
  }, g);
  if (models.length < 2 && !anySidechain) return svg;

  const legend = el('div', { class: 'legend' },
    models.map((name, i) => el('span', {}, el('i', { style: `background:${colors[i]}` }), name)),
    anySidechain ? el('span', {},
      el('i', { style: 'background:repeating-linear-gradient(45deg, var(--ink-3), var(--ink-3) 1px, transparent 1px, transparent 3px)' }),
      t('chart.subagent')) : null);
  return el('div', {}, svg, legend);
}
