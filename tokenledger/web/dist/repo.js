// web/dist/repo.js — the progress tier: what the spend bought.
//
// Every other section on this page answers "what did it cost". This one
// answers "what landed", from rows a shipper pushes into the same hub under
// the same key. It is deliberately NOT a second dashboard: it sits in the
// same surface, under the same shell, reading the same binary — two
// dashboards sharing a process would be the thing this feature exists not to
// be.
//
// The one rule every card here obeys: a threshold is never a constant. Ages
// are read against the repository's OWN close-time percentiles, and when a
// shipper has not computed them the card says the scale is unknown instead of
// picking one. A confident "12 stale issues" derived from a number nobody
// measured is worse than no card, because a reader cannot tell it from a
// measured one.
import { el, escapeHTML, showTip, hideTip } from './lib/dom.js';
import { t } from './lib/i18n.js';
import { fmtInt, fmtPct } from './lib/format.js';
import { rankedBars } from './charts.js';
import { seriesPalette, OTHER_COLOR } from './lib/palette.js';
import { costLine } from './lib/cost.js';
import { fmtAge, weeklyFlow, net, ageHistogram, stalled, pickRepo,
         labelFacets, filterStalled, sortStalled,
         healthRows, healthAge,
         issueSpendRows, issueShare, concentration } from './lib/repo.js';
import { groupByOwner, untold, weeklyHuman, windowRatio, trend, pct, trimLeadingEmpty,
         OWNER_NOT_A_PERSON, OWNER_UNRESOLVED } from './lib/human.js';

/** renderRepo mounts the progress tier. It returns the {fetchers, apply} pair
 *  app.js's loader expects, or null when this hub holds no repo data at all —
 *  a hub with no shipper must look exactly as it did before this landed, not
 *  grow an empty card explaining a feature nobody turned on. */
export function renderRepo(root, state, app, repos) {
  if (!repos || !repos.length) {
    root.replaceChildren();
    return null;
  }
  const repo = pickRepo(state.repo, repos);
  const q = (extra) => new URLSearchParams({ repo, ...extra }).toString();
  return {
    fetchers: [
      (signal) => app.api('/v1/repo/flow?' + q({}), signal),
      // Open issues only, and generously capped: the age histogram needs the
      // whole open backlog to be a distribution rather than a sample, and the
      // stalled list is drawn from the same rows so the two can never
      // disagree about what is open.
      (signal) => app.api('/v1/repo/issues?' + q({ state: 'open', limit: '1000', cost: '1' }), signal),
      // The issue axis. Its own request rather than a field on the one above,
      // because it answers about a WINDOW ("where did this period's money
      // go") while the backlog answers about now, and the two ranges are not
      // the same question wearing one URL.
      (signal) => app.api('/v1/repo/cost?' + q({}), signal),
      // Open manual steps plus the daily ratio behind them. A hub whose
      // shipper does not parse release fragments gets an empty pair back and
      // the card renders as nothing — same rule as the section itself.
      (signal) => app.api('/v1/repo/human-debt?' + q({}), signal),
    ],
    apply: (results) => apply(root, results, repo, repos, state, app),
  };
}

function apply(root, results, repo, repos, state, app) {
  const [flowR, issuesR, costR, humanR] = results;
  // Three slots, and which card goes where is fixed rather than positional:
  // the picker is full width above the pair, flow and age share the two-up
  // row, and the stalled table runs full width beneath them. Slicing a flat
  // list instead put the picker in the grid and pushed the age card out of
  // it the moment a second repository appeared.
  const head = repos.length > 1 ? repoPicker(repo, repos, state, app) : null;
  const scale = flowR.status === 'fulfilled' ? flowR.value.scale : null;
  const flow = flowR.status === 'rejected'
    ? errCard(t('repo.flow.title'), flowR.reason)
    : flowCard(flowR.value);
  const issues = issuesR.status === 'fulfilled' ? (issuesR.value.issues || []) : null;
  const age = issues === null
    ? errCard(t('repo.backlog.title'), issuesR.reason)
    : ageCard(issues, scale);
  const below = issues === null
    ? []
    : [stalledCard(issues, scale, state, app,
        issuesR.status === 'fulfilled' ? issuesR.value.cost_unavailable : null)];
  // Money on the issue axis, directly under the two-up row: it reads against
  // the flow above it, and it is the card that says how much of the window
  // nobody could attribute at all.
  const cost = costR && costR.status === 'fulfilled' ? costCard(costR.value)
    : costR && costR.status === 'rejected' ? costUnavailableCard(costR.reason)
    : null;
  if (cost) below.unshift(cost);
  // Above the pair, not below the table. These three figures say whether the
  // checks behind every other number on this page still work, and they landed
  // here because the surface they used to live on was one nobody opened. Put
  // them where the last one was buried and they are buried again.
  const health = flowR.status === 'fulfilled'
    ? healthCard(flowR.value.verify_health)
    : null;
  // The manual-step card goes FIRST when there is anything in it. Everything
  // below says how fast the machine half is moving; this says whether the
  // release is moving at all — and a batch with an unfinished manual step
  // does not ship, however green every check above it is.
  const human = humanR.status === 'rejected'
    ? errCard(t('repo.human.title'), humanR.reason)
    : humanCard(humanR.value);
  // Health before the manual steps: it is the card that says whether the
  // verification behind every other figure here -- including this one --
  // still works, so it qualifies the page rather than competing with it.
  // Both sit ABOVE the two-up row for the same reason: what is below says
  // how fast the machine half moves, and neither of these is about that.
  root.replaceChildren(...(head ? [head] : []), ...(health ? [health] : []),
    ...(human ? [human] : []),
    el('div', { class: 'grid2' }, flow, age), ...below);
}

function errCard(title, reason) {
  return el('div', { class: 'card' },
    el('h2', {}, title),
    el('div', { class: 'empty' }, t('common.queryFailed', { error: (reason && reason.message) || String(reason) })));
}

function repoPicker(repo, repos, state, app) {
  const sel = el('select', {
    'aria-label': t('repo.pick'),
    onchange: (e) => app.setState({ ...state, repo: e.target.value }),
  }, repos.map((r) => el('option', { value: r.repo, selected: r.repo === repo || null }, r.repo)));
  return el('div', { class: 'card' },
    el('div', { class: 'controls' }, el('span', { class: 'label' }, t('repo.pick')), sel));
}

/* ------------------------------------------------------------------ flow */

function flowCard(flow) {
  const card = el('div', { class: 'card', id: 'repo-flow' },
    el('h2', {}, t('repo.flow.title')),
    el('p', { class: 'hint' }, t('repo.flow.hint')));
  const weeks = weeklyFlow(flow.days);
  if (!weeks.length) {
    card.appendChild(el('div', { class: 'empty' }, t('repo.flow.empty')));
    return card;
  }
  card.appendChild(flowChart(weeks));

  // The one sentence a reader actually wants: is the backlog growing?
  const recent = weeks.slice(-4);
  const delta = recent.reduce((a, w) => a + net(w), 0);
  const last = [...weeks].reverse().find((w) => w.openAtEnd != null);
  const bits = [t(delta > 0 ? 'repo.flow.growing' : delta < 0 ? 'repo.flow.shrinking' : 'repo.flow.level',
    { n: Math.abs(delta), weeks: recent.length })];
  if (last) bits.push(t('repo.flow.openNow', { n: fmtInt(last.openAtEnd) }));
  card.appendChild(el('p', { class: 'hint' }, bits.join(' ')));
  return card;
}

/** flowChart draws opened above the axis and closed below it, with the
 *  open-issue level as a line on its own scale.
 *
 *  Mirrored bars rather than a stack, because opened and closed are opposing
 *  flows: stacking them would put a tall bar on a week where a lot happened
 *  and nothing changed, which is the opposite of what the reader is looking
 *  for. The level gets its own axis and is drawn as a line, because it is not
 *  a rate and must not be read against the same gridlines. */
function flowChart(weeks) {
  const W = 560, H = 210, PAD = { t: 16, r: 42, b: 24, l: 44 };
  const iw = W - PAD.l - PAD.r, ih = H - PAD.t - PAD.b;
  const mid = PAD.t + ih / 2;
  const half = ih / 2;
  const maxFlow = Math.max(1, ...weeks.map((w) => Math.max(w.opened, w.closed)));
  const maxOpen = Math.max(1, ...weeks.map((w) => w.openAtEnd || 0));
  const n = weeks.length;
  const step = iw / n;
  const bw = Math.max(2, step / 2 - 2);

  const g = el('g', {});
  // Three gridlines only: the zero axis and the two flow extremes.
  for (const [v, y] of [[maxFlow, mid - half], [0, mid], [maxFlow, mid + half]]) {
    g.appendChild(el('line', { x1: PAD.l, x2: W - PAD.r, y1: y, y2: y, stroke: 'var(--grid)' }));
    g.appendChild(el('text', { x: PAD.l - 8, y: y + 3.5, 'text-anchor': 'end', fill: 'var(--ink-3)' }, fmtInt(v)));
  }

  weeks.forEach((w, i) => {
    const x = PAD.l + i * step;
    const tip = `<b>${escapeHTML(w.week)}</b><br>` +
      escapeHTML(t('repo.tip.opened', { n: w.opened })) + '<br>' +
      escapeHTML(t('repo.tip.closed', { n: w.closed })) +
      (w.openAtEnd != null ? '<br>' + escapeHTML(t('repo.tip.open', { n: w.openAtEnd })) : '');
    const hover = { onmousemove: (e) => showTip(e, tip), onmouseleave: hideTip };
    const oh = (w.opened / maxFlow) * half;
    const ch = (w.closed / maxFlow) * half;
    g.appendChild(el('rect', { x, y: mid - oh, width: bw, height: Math.max(w.opened ? 1.5 : 0, oh), rx: 2, fill: 'var(--s2)', ...hover },
      el('title', {}, t('repo.tip.opened', { n: w.opened }))));
    g.appendChild(el('rect', { x: x + bw + 2, y: mid, width: bw, height: Math.max(w.closed ? 1.5 : 0, ch), rx: 2, fill: 'var(--s3)', ...hover },
      el('title', {}, t('repo.tip.closed', { n: w.closed }))));
  });

  // The level line, on the right-hand axis.
  const pts = weeks
    .map((w, i) => (w.openAtEnd == null ? null : `${PAD.l + i * step + step / 2},${PAD.t + ih - (w.openAtEnd / maxOpen) * ih}`))
    .filter(Boolean);
  if (pts.length > 1) {
    g.appendChild(el('polyline', { points: pts.join(' '), fill: 'none', stroke: 'var(--s1)', 'stroke-width': '1.6' }));
  }
  g.appendChild(el('text', { x: W - PAD.r + 6, y: PAD.t + 4, fill: 'var(--ink-3)' }, fmtInt(maxOpen)));

  const label = (i, anchor) => el('text', {
    x: PAD.l + i * step + step / 2, y: H - 6, 'text-anchor': anchor, fill: 'var(--ink-3)',
  }, weeks[i].week.slice(5));
  g.appendChild(label(0, 'start'));
  if (n > 1) g.appendChild(label(n - 1, 'end'));

  // No pixel `height` and no `font-size` attribute, for the reasons
  // charts.js's `chartSvg` spells out (issue #55): the viewBox's own ratio
  // sizes the box, and `--cw` lets styles.css cancel the viewBox scaling out
  // of the tick labels. This chart is drawn by hand rather than through
  // `chartSvg` because repo.js deliberately does not import charts.js.
  return el('svg', {
    viewBox: `0 0 ${W} ${H}`, width: '100%', class: 'chart', style: `--cw:${W}`, role: 'img',
    'aria-label': t('repo.flow.aria', { weeks: n, open: fmtInt(maxOpen) }),
  }, g);
}

/* ------------------------------------------------ verification health */

/** HEALTH_LABEL translates the readings this page knows by name. A key it has
 *  never seen falls back to the producer's own wording — a new figure that
 *  renders as a blank row would be worse than an untranslated one. */
const HEALTH_LABEL = {
  touch: 'repo.health.k.touch',
  rot: 'repo.health.k.rot',
  inflow: 'repo.health.k.inflow',
};

/** healthCard shows what the repository says about its own checks.
 *
 *  Three states, and they are three different sentences on purpose:
 *  nobody ships these (no card content — "nobody looked"), they were shipped
 *  but are old (a warning, because a stale figure and a healthy one look
 *  identical), and a single reading that could not be taken (marked in its own
 *  row, never dropped, never shown as zero). */
function healthCard(health) {
  const card = el('div', { class: 'card', id: 'repo-health' },
    el('h2', {}, t('repo.health.title')),
    el('p', { class: 'hint' }, t('repo.health.hint')));
  if (!health) {
    card.appendChild(el('div', { class: 'empty' }, t('repo.health.none')));
    return card;
  }
  const rows = healthRows(health);
  if (!rows.length) {
    card.appendChild(el('div', { class: 'empty' }, t('repo.health.empty')));
    return card;
  }
  card.appendChild(el('div', { class: 'scroll' }, el('table', {},
    el('tbody', {}, rows.map((r) => el('tr', { class: r.ok ? null : 'unread' },
      el('th', { scope: 'row' }, r.key in HEALTH_LABEL ? t(HEALTH_LABEL[r.key]) : (r.label || r.key)),
      el('td', { class: 'figure' },
        r.ok ? r.value : el('span', { class: 'unread-tag' }, t('repo.health.unread')),
        r.ok ? null : ' ' + r.value),
      el('td', { class: 'note' }, r.note)))))));

  const age = healthAge(health);
  const foot = [];
  if (age) {
    foot.push(t('repo.health.observed', {
      when: String(health.observed_at).slice(0, 10),
      age: fmtAge(age.seconds, t),
    }));
  }
  if (health.source) foot.push(t('repo.health.source', { source: health.source }));
  if (foot.length) card.appendChild(el('p', { class: 'hint' }, foot.join(' ')));

  if (age && age.stale === true) {
    card.appendChild(el('p', { class: 'hint warn' }, t('repo.health.stale', {
      age: fmtAge(age.seconds, t), after: fmtAge(age.after, t),
    })));
  } else if (age && age.stale === null) {
    card.appendChild(el('p', { class: 'hint' }, t('repo.health.noCadence')));
  }
  return card;
}

/* ------------------------------------------------------------------- age */

function ageCard(issues, scale) {
  const card = el('div', { class: 'card', id: 'repo-age' },
    el('h2', {}, t('repo.age.title')),
    el('p', { class: 'hint' }, t('repo.age.hint')));
  const hist = ageHistogram(issues, scale);
  if (!hist) {
    // Not an empty chart: "no scale" and "no issues" are different answers,
    // and rendering them the same would let a reader take one for the other.
    card.appendChild(el('div', { class: 'empty' }, t('repo.age.noScale')));
    return card;
  }
  const rows = hist.map((b, i) => ({
    key: b.key,
    label: b.to === null ? t('repo.age.over', { edge: b.edge }) : t('repo.age.upTo', { age: fmtAge(b.to, t), edge: b.edge }),
    value: b.count,
    right: fmtInt(b.count),
    color: i === hist.length - 1 ? 'var(--s2)' : 'var(--s1)',
    tip: escapeHTML(t('repo.age.tip', { n: b.count })),
  }));
  card.appendChild(rankedBars(rows));
  card.appendChild(el('p', { class: 'hint' }, scaleLine(scale)));
  return card;
}

/** scaleLine states the distribution every band above was cut from, and how
 *  many closes it was measured over. A reader who cannot see the sample size
 *  cannot tell a distribution from an anecdote. */
function scaleLine(scale) {
  const parts = [];
  for (const [name, key] of [['p50', 'p50_seconds'], ['p90', 'p90_seconds'], ['p95', 'p95_seconds']]) {
    if (typeof scale[key] === 'number') parts.push(`${name} ${fmtAge(scale[key], t)}`);
  }
  const line = t('repo.age.scale', { parts: parts.join(' · '), day: scale.day });
  return scale.closed_sample ? line + ' ' + t('repo.age.sample', { n: fmtInt(scale.closed_sample) }) : line;
}

/* --------------------------------------------------------------- stalled */

/** SORT_LABEL names each axis for the hint line and for the column header a
 *  reader clicks. Read through t() at call time, not at module eval: the
 *  language switcher re-renders, it does not reload. */
const SORT_LABEL = { age: 'repo.sort.age', comments: 'repo.sort.comments' };

function stalledCard(issues, scale, state, app, costUnavailable) {
  const card = el('div', { class: 'card', id: 'repo-stalled' },
    el('h2', {}, t('repo.stalled.title')),
    el('p', { class: 'hint' }, t('repo.stalled.hint')));
  const { rows, reason } = stalled(issues, scale);
  if (reason === 'no-scale') {
    card.appendChild(el('div', { class: 'empty' }, t('repo.stalled.noScale')));
    return card;
  }
  if (!rows.length) {
    card.appendChild(el('div', { class: 'empty' }, t('repo.stalled.none')));
    return card;
  }

  card.appendChild(stalledControls(rows, state, app));

  const shown = sortStalled(
    filterStalled(rows, { label: state.rlabel, shippedOnly: Boolean(state.rshipped) }),
    state.rsort);
  if (!shown.length) {
    // Not the same sentence as "nothing is stalled". The reader narrowed this
    // themselves and the controls above still say how, so the card says the
    // filter came up empty rather than implying the backlog is clean.
    card.appendChild(el('div', { class: 'empty' }, t('repo.stalled.noMatch')));
    return card;
  }
  // The money column exists only when the hub could bind these numbers to
  // this repository. When it could not, the reason is printed instead of the
  // column -- a blank column would read as "nothing was spent".
  const priced = !costUnavailable && shown.some((i) => i.lifetime);
  card.appendChild(el('div', { class: 'scroll' }, stalledTable(shown, state, app, priced)));
  if (costUnavailable) {
    card.appendChild(el('p', { class: 'hint' },
      t('repo.stalled.noCost') + ' ' + costUnavailable));
  }
  card.appendChild(el('p', { class: 'hint' },
    t('repo.stalled.count', { shown: fmtInt(shown.length), total: fmtInt(rows.length) })
    + ' ' + t('repo.stalled.sortedBy', { what: t(SORT_LABEL[state.rsort] || SORT_LABEL.age) })));
  return card;
}

/** stalledControls is the whole "can be narrowed" half.
 *
 *  Both settings live in the URL rather than in this card, and that is the
 *  point rather than an implementation detail: the tier re-renders on the
 *  page's 60-second timer, so a picker holding its own value would silently
 *  reset itself every minute — and a narrowed list nobody can paste to a
 *  colleague is half a view on a page whose reason to exist is being the one
 *  everybody looks at. */
function stalledControls(rows, state, app) {
  // No history entry per keystroke: narrowing a table is not a navigation,
  // and pushing one would make Back mean "undo one filter" for as many
  // presses as the reader fiddled. Same call shape review.js's sort uses.
  const set = (patch) => app.setState({ ...state, ...patch }, { push: false });

  const facets = labelFacets(rows, state.rlabel);
  const sel = el('select', {
    'aria-label': t('repo.stalled.byLabel'),
    onchange: (e) => set({ rlabel: e.target.value || null }),
  },
    el('option', { value: '', selected: state.rlabel ? null : true }, t('repo.stalled.allLabels', { n: fmtInt(rows.length) })),
    facets.map((f) => el('option', { value: f.label, selected: f.label === state.rlabel || null },
      `${f.label} (${fmtInt(f.count)})`)));

  const shippedN = rows.filter((r) => r.shipped_at).length;
  const ship = el('button', {
    type: 'button',
    'aria-pressed': String(Boolean(state.rshipped)),
    // Disabled rather than hidden when the subset is empty: a control that
    // comes and goes with the data reads as a bug, and its absence would also
    // hide the fact that nothing stalled has shipped -- which is itself worth
    // knowing.
    disabled: shippedN ? null : true,
    onclick: () => set({ rshipped: state.rshipped ? null : '1' }),
  }, t('repo.stalled.onlyShipped', { n: fmtInt(shippedN) }));

  return el('div', { class: 'controls' },
    el('span', { class: 'label' }, t('repo.stalled.byLabel')), sel, ship);
}

const STALLED_COLS = [
  { key: 'issue', label: 'repo.col.issue' },
  { key: 'age', label: 'repo.col.age', sort: 'age', num: true },
  { key: 'burned', label: 'repo.col.burned', cost: true },
  { key: 'comments', label: 'repo.col.comments', sort: 'comments', num: true },
  { key: 'shipped', label: 'repo.col.shipped' },
];

function stalledTable(shown, state, app, priced) {
  const setSort = (s) => () => app.setState({ ...state, rsort: s }, { push: false });
  const cols = STALLED_COLS.filter((c) => !c.cost || priced);
  const head = el('tr', {}, cols.map((c) => el('th', {
    class: c.num ? 'num' : null,
    role: c.sort ? 'button' : null,
    tabindex: c.sort ? '0' : null,
    'aria-sort': c.sort && state.rsort === c.sort ? 'descending' : null,
    onclick: c.sort ? setSort(c.sort) : null,
    onkeydown: c.sort ? (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); setSort(c.sort)(); } } : null,
  }, t(c.label))));

  const body = shown.map((i) => el('tr', {},
    el('td', {}, i.url
      ? el('a', { href: i.url, target: '_blank', rel: 'noopener noreferrer' }, `#${i.number} ${i.title || ''}`.trim())
      : `#${i.number} ${i.title || ''}`.trim()),
    el('td', { class: 'num' }, fmtAge(i.age_seconds, t)),
    // Per source, never a sum -- and "no cost" rather than a zero when no
    // branch ever named this issue, because a zero would claim the work was
    // free instead of unattributed.
    ...(priced ? [el('td', { title: costLine(i.lifetime || {}) }, costLine(i.lifetime || {}))] : []),
    el('td', { class: 'num' }, fmtInt(i.comments || 0)),
    // The actionable half: the work already landed and nobody closed it.
    // That is a close, not an investigation, so it is called out rather than
    // left for a reader to notice.
    el('td', {}, i.shipped_at
      ? el('span', { class: 'warn', title: i.shipped_ref || '' }, t('repo.stalled.shipped'))
      : '')));

  return el('table', {}, el('thead', {}, head), el('tbody', {}, body));
}

/* ------------------------------------------------ cost on the issue axis */

/** costCard puts the window's money on the issue axis, with the part nobody
 *  could attribute sitting on the same chart rather than in a footnote.
 *
 *  Three rules, and none of them is a rendering preference:
 *
 *  - The bars are TOKENS. Cost comes back split by source because the three
 *    kinds of money this hub holds mean nothing added together, so there is
 *    no single cost figure to draw a bar from. Every money figure here is a
 *    per-source line, never a sum.
 *  - The unattributed bucket is a bar, pinned last. On the corpus the
 *    attribution rule was measured against it is 63.5% of events — a chart
 *    that drops it is not slightly optimistic, it is wrong by a factor of
 *    three in the flattering direction.
 *  - `stale` comes from the repository's own p95 or not at all. A null verdict
 *    renders as nothing, never as "fine".
 */
function costCard(cost) {
  const card = el('div', { class: 'card', id: 'repo-cost' },
    el('h2', {}, t('repo.cost.title')),
    el('p', { class: 'hint' }, t('repo.cost.hint')));

  const page = issueSpendRows(cost);
  if (!page || (!page.rows.length && !(page.unattributed && page.unattributed.events))) {
    card.appendChild(el('div', { class: 'empty' }, t('repo.cost.empty')));
    return card;
  }

  // Colour by NAME, not by position: an issue's rank changes every window,
  // and index colours would repaint the whole chart when two issues swap
  // places. The unattributed bucket is the one bar that never takes a series
  // colour — it is not a series, it is the remainder.
  const colors = seriesPalette(page.rows.map((r) => '#' + r.number));
  const bars = page.rows.map((r, i) => issueBar(r, colors[i], page.total, cost.scale));
  if (page.unattributed) {
    bars.push(issueBar(page.unattributed, OTHER_COLOR, page.total, cost.scale));
  }
  card.appendChild(rankedBars(bars));

  for (const line of costFooter(page, cost)) card.appendChild(line);
  return card;
}

/** issueBar is one row of the ranked list: a number, what it is, how much of
 *  the window it took, and — only in the hover — the money, per source. */
function issueBar(r, color, total, scale) {
  const unattributed = r.kind === 'unattributed';
  const share = issueShare(r, total);
  // A number the hub holds no issue row for keeps its money and says so. Its
  // spend outlived the issue (per-issue rows are bounded by retention), and
  // dropping it would break the sum the card is built on.
  const label = unattributed ? t('repo.cost.unattributed')
    : r.known ? `#${r.number} ${r.title}`
    : t('repo.cost.unknownIssue', { n: r.number });

  const tip = [];
  tip.push(t('repo.cost.tipWindow', { tokens: fmtInt(r.tokens), cost: costLine(r.window || r) }));
  if (!unattributed && r.lifetime && r.lifetime.events) {
    tip.push(t('repo.cost.tipLifetime', { cost: costLine(r.lifetime) }));
  }
  if (!unattributed && r.stale === true && scale && typeof scale.p95_seconds === 'number') {
    tip.push(t('repo.cost.tipStale', {
      age: fmtAge(r.age_seconds, t), after: fmtAge(scale.p95_seconds, t),
    }));
  }
  if (unattributed && Array.isArray(r.branches) && r.branches.length) {
    tip.push(t('repo.cost.tipBranches', {
      branches: r.branches.slice(0, 4).map((b) => b.branch || t('repo.cost.noBranch')).join(', '),
    }));
  }
  return {
    key: unattributed ? 'unattributed' : String(r.number),
    label,
    value: Number(r.tokens) || 0,
    right: share == null ? fmtInt(r.tokens) : fmtPct(share, 0),
    rightTitle: t('repo.cost.tokens', { n: fmtInt(r.tokens) }),
    color,
    tip: escapeHTML(tip.join(' · ')),
  };
}

/** costFooter is the three sentences the bars cannot say themselves: how
 *  concentrated the spend is, how much of it was never attributed, and what
 *  the top-N left out. */
function costFooter(page, cost) {
  const out = [];
  const conc = concentration(page.rows, page.attributed);
  if (conc) {
    // Explicitly "of the attributed", because it is: measuring against the
    // grand total would let the unattributed bucket flatter the figure.
    out.push(el('p', { class: 'hint' },
      t('repo.cost.concentration', { n: conc.n, of: conc.of, share: fmtPct(conc.share, 0) })));
  }
  if (page.hidden > 0) {
    out.push(el('p', { class: 'hint' }, t('repo.cost.hidden', { n: fmtInt(page.hidden) })));
  }

  const un = page.unattributed;
  const unShare = un ? issueShare(un, page.total) : null;
  if (un && unShare != null) {
    // warn, not a neutral hint: this is the number that decides whether every
    // bar above it is a distribution or a sample, and it has to be read.
    const biggest = (un.branches || [])[0];
    const why = biggest
      ? t('repo.cost.unattributedWhy', { branch: biggest.branch || t('repo.cost.noBranch') })
      : '';
    out.push(el('p', { class: unShare >= 0.5 ? 'hint warn' : 'hint' },
      t('repo.cost.unattributedShare', { share: fmtPct(unShare, 0) }) + (why ? ' ' + why : '')));
  }
  if (!cost.scale || typeof cost.scale.p95_seconds !== 'number') {
    out.push(el('p', { class: 'hint' }, t('repo.cost.noScale')));
  }
  return out;
}

/** costUnavailableCard renders the refusal as an explanation rather than as a
 *  failed query. The hub is saying it will not guess which repository a spend
 *  row belongs to, which is an answer — and the reader needs to be told what
 *  would make it answerable, not handed a status code. */
function costUnavailableCard(reason) {
  return el('div', { class: 'card', id: 'repo-cost' },
    el('h2', {}, t('repo.cost.title')),
    el('div', { class: 'empty' }, t('repo.cost.unbound')),
    el('p', { class: 'hint' }, (reason && reason.message) || String(reason)));
}

/* ----------------------------------------------------------------- human */

/** humanCard is the release work that is waiting on a PERSON: what is owed
 *  right now, grouped by whose it is, and whether the share of releases that
 *  need a hand is falling.
 *
 *  ★ It shows EVERYONE'S rows, and says so in the first line. This hub's SSO
 *    ticket carries one fixed subject per (app, tenant) — every colleague's
 *    session is byte-identical here — so "yours" is not a question it can
 *    answer. Filtering anyway would put a personal claim on rows picked by a
 *    coin flip, on the one card whose entire job is saying who owes what.
 *
 *  ★ It is a VIEW, never a control. Finishing a step happens on the channel
 *    that told somebody about it; a "done" button here would be a second
 *    writer and therefore a second truth. */
function humanCard(data) {
  const steps = (data && data.steps) || [];
  const weeks = trimLeadingEmpty(weeklyHuman((data && data.days) || []));
  // Nothing shipped at all — not an empty card explaining a feature nobody
  // turned on. (Nothing OWED, with days shipped, is a real and good answer
  // and does get a card.)
  if (!steps.length && !weeks.length) return null;

  const card = el('div', { class: 'card', id: 'repo-human' },
    el('h2', {}, t('repo.human.title')),
    el('p', { class: 'hint' }, t('repo.human.hint')),
    el('p', { class: 'hint' }, t('repo.human.everyone')));

  if (!steps.length) {
    card.appendChild(el('div', { class: 'empty' }, t('repo.human.none')));
  } else {
    const n = untold(steps);
    if (n) {
      // Not a footnote: a step nobody was told about is the system failing to
      // deliver it, and the total above blames the wrong party for it.
      card.appendChild(el('p', { class: 'warn' }, t('repo.human.untold', { n })));
    }
    for (const g of groupByOwner(steps)) card.appendChild(ownerGroup(g));
  }

  card.appendChild(el('h3', {}, t('repo.human.ratio.title')));
  card.appendChild(el('p', { class: 'hint' }, t('repo.human.ratio.hint')));
  if (!weeks.length) {
    card.appendChild(el('div', { class: 'empty' }, t('repo.human.ratio.none')));
  } else {
    card.appendChild(ratioChart(weeks));
    card.appendChild(el('p', { class: 'hint' }, ratioLine(weeks)));
  }
  return card;
}

const clip = (v, n) => (String(v).length <= n ? String(v) : String(v).slice(0, n - 1) + '\u2026');

const KIND_LABEL = {
  [OWNER_NOT_A_PERSON]: 'repo.human.kind.notAPerson',
  [OWNER_UNRESOLVED]: 'repo.human.kind.unresolved',
};

function ownerGroup(g) {
  const label = el('div', { class: 'controls' },
    el('span', { class: 'label' }, g.owner),
    // The two kinds nobody can be reminded about are marked, because "waiting
    // on 发起人" and "waiting on a name nothing could resolve" look identical
    // in a list and are not the same problem at all.
    ...(KIND_LABEL[g.kind] ? [el('span', { class: 'warn' }, t(KIND_LABEL[g.kind]))] : []),
    el('span', { class: 'hint' }, t('repo.human.group', { n: g.steps.length, age: fmtAge(g.waiting, t) })));

  const head = el('tr', {},
    el('th', {}, t('repo.human.col.step')),
    el('th', {}, t('repo.human.col.waiting')),
    el('th', {}, t('repo.human.col.told')));
  const body = g.steps.map((s) => {
    const name = `#${s.fragment}.${s.ord} ${s.title || ''}`.trim();
    // The link goes back to the fragment issue, because that is where the
    // step is WRITTEN — the row here is a copy, and a reader who wants to act
    // needs the original.
    const link = s.fragment_url
      ? el('a', { href: s.fragment_url, target: '_blank', rel: 'noopener noreferrer' }, name)
      : name;
    // "How to do it" travels with the row. Without it the reader has to open
    // the issue to find out whether this is a two-second kubectl or an
    // afternoon — which is the friction this whole page exists to remove.
    // Clipped, with the whole thing (plus what counts as done, and what to do
    // if you can't) in the tooltip. A step whose instructions run to a screen
    // of text would push every other owner's rows below the fold — and the
    // rows below the fold are the ones nobody acts on.
    const how = s.how
      ? el('div', { class: 'hint', title: [s.how, s.pass, s.exit].filter(Boolean).join('\n\n') }, clip(s.how, 180))
      : el('div', { class: 'hint' }, t('repo.human.noHow'));
    return el('tr', {},
      el('td', {}, link, how),
      el('td', { class: 'num' }, fmtAge(s.waiting_seconds, t)),
      el('td', {}, s.todo_at ? '' : el('span', { class: 'warn' }, t('repo.human.notTold'))));
  });
  return el('div', {}, label,
    el('div', { class: 'scroll' }, el('table', {}, el('thead', {}, head), el('tbody', {}, body))));
}

/** ratioChart draws the weekly share as bars, with the week's fragment count
 *  as the tooltip's denominator.
 *
 *  A week with no fragments draws NOTHING rather than a zero-height bar: the
 *  gap is the honest rendering of "nothing to measure", and a flat zero would
 *  read as "nothing needed a human that week", which is the opposite claim. */
function ratioChart(weeks) {
  const W = 560, H = 120, PAD = { t: 12, r: 12, b: 22, l: 40 };
  const iw = W - PAD.l - PAD.r, ih = H - PAD.t - PAD.b;
  const max = Math.max(0.05, ...weeks.map((w) => w.ratio || 0));
  const step = iw / weeks.length;
  // Capped: with three weeks of history a bar sized to its slot is 170px
  // wide, which reads as a block of colour rather than as a measurement. The
  // cap only binds early — it stops mattering the moment there is a quarter
  // of history, which is when this chart starts being worth reading.
  const bw = Math.min(34, Math.max(3, step - 6));
  const g = el('g', {});
  for (const [v, y] of [[max, PAD.t], [0, PAD.t + ih]]) {
    g.appendChild(el('line', { x1: PAD.l, x2: W - PAD.r, y1: y, y2: y, stroke: 'var(--grid)' }));
    g.appendChild(el('text', { x: PAD.l - 8, y: y + 3.5, 'text-anchor': 'end', fill: 'var(--ink-3)' }, pct(v)));
  }
  weeks.forEach((w, i) => {
    const x = PAD.l + i * step;
    if (w.ratio == null) return;
    const h = (w.ratio / max) * ih;
    const tip = `<b>${escapeHTML(w.week)}</b><br>` +
      escapeHTML(t('repo.human.tip', { pct: pct(w.ratio), n: w.withHuman, total: w.fragments }));
    g.appendChild(el('rect', {
      x, y: PAD.t + ih - h, width: bw, height: Math.max(w.withHuman ? 1.5 : 0, h), rx: 2,
      fill: 'var(--s2)', onmousemove: (e) => showTip(e, tip), onmouseleave: hideTip,
    }, el('title', {}, t('repo.human.tip', { pct: pct(w.ratio), n: w.withHuman, total: w.fragments }))));
  });
  const label = (i, anchor) => el('text', {
    x: PAD.l + i * step + bw / 2, y: H - 6, 'text-anchor': anchor, fill: 'var(--ink-3)',
  }, weeks[i].week.slice(5));
  g.appendChild(label(0, 'start'));
  if (weeks.length > 1) g.appendChild(label(weeks.length - 1, 'end'));
  // Same three rules the flow chart above follows (issue #55): no pixel
  // `height`, no `font-size` attribute, and `--cw` handed to styles.css so
  // it can divide the viewBox scaling back out of the tick labels. Drawn by
  // hand rather than through charts.js's `chartSvg` for the same reason the
  // flow chart is -- repo.js deliberately does not import charts.js.
  return el('svg', {
    viewBox: `0 0 ${W} ${H}`, width: '100%', class: 'chart', style: `--cw:${W}`, role: 'img',
    'aria-label': t('repo.human.ratio.aria', { weeks: weeks.length, pct: pct(windowRatio(weeks)) || '—' }),
  }, g);
}

/** ratioLine is the sentence under the chart: where the share stands, and
 *  whether it is moving. It refuses to name a direction from a single week —
 *  see trend(). */
function ratioLine(weeks) {
  const tr = trend(weeks);
  const bits = [];
  const win = windowRatio(weeks);
  if (win != null) bits.push(t('repo.human.ratio.window', { pct: pct(win), weeks: weeks.length }));
  if (tr.direction === 'unknown') {
    bits.push(t('repo.human.ratio.unknown'));
  } else {
    bits.push(t(`repo.human.ratio.${tr.direction}`, {
      pct: pct(tr.latest.ratio), before: pct(tr.before), week: tr.latest.week,
    }));
  }
  return bits.join(' ');
}
