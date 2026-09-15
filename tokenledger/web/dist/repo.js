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
import { fmtInt } from './lib/format.js';
import { rankedBars } from './charts.js';
import { fmtAge, weeklyFlow, net, ageHistogram, stalled, pickRepo,
         labelFacets, filterStalled, sortStalled,
         healthRows, healthAge } from './lib/repo.js';

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
      (signal) => app.api('/v1/repo/issues?' + q({ state: 'open', limit: '1000' }), signal),
    ],
    apply: (results) => apply(root, results, repo, repos, state, app),
  };
}

function apply(root, results, repo, repos, state, app) {
  const [flowR, issuesR] = results;
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
  const below = issues === null ? [] : [stalledCard(issues, scale, state, app)];
  // Above the pair, not below the table. These three figures say whether the
  // checks behind every other number on this page still work, and they landed
  // here because the surface they used to live on was one nobody opened. Put
  // them where the last one was buried and they are buried again.
  const health = flowR.status === 'fulfilled'
    ? healthCard(flowR.value.verify_health)
    : null;
  root.replaceChildren(...(head ? [head] : []), ...(health ? [health] : []),
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
    g.appendChild(el('text', { x: PAD.l - 8, y: y + 3.5, 'text-anchor': 'end', fill: 'var(--ink-3)', 'font-size': '10.5' }, fmtInt(v)));
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
  g.appendChild(el('text', { x: W - PAD.r + 6, y: PAD.t + 4, fill: 'var(--ink-3)', 'font-size': '10.5' }, fmtInt(maxOpen)));

  const label = (i, anchor) => el('text', {
    x: PAD.l + i * step + step / 2, y: H - 6, 'text-anchor': anchor, fill: 'var(--ink-3)', 'font-size': '10.5',
  }, weeks[i].week.slice(5));
  g.appendChild(label(0, 'start'));
  if (n > 1) g.appendChild(label(n - 1, 'end'));

  return el('svg', {
    viewBox: `0 0 ${W} ${H}`, width: '100%', height: H, role: 'img',
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

function stalledCard(issues, scale, state, app) {
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
  card.appendChild(el('div', { class: 'scroll' }, stalledTable(shown, state, app)));
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
  { key: 'comments', label: 'repo.col.comments', sort: 'comments', num: true },
  { key: 'shipped', label: 'repo.col.shipped' },
];

function stalledTable(shown, state, app) {
  const setSort = (s) => () => app.setState({ ...state, rsort: s }, { push: false });
  const head = el('tr', {}, STALLED_COLS.map((c) => el('th', {
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
    el('td', { class: 'num' }, fmtInt(i.comments || 0)),
    // The actionable half: the work already landed and nobody closed it.
    // That is a close, not an investigation, so it is called out rather than
    // left for a reader to notice.
    el('td', {}, i.shipped_at
      ? el('span', { class: 'warn', title: i.shipped_ref || '' }, t('repo.stalled.shipped'))
      : '')));

  return el('table', {}, el('thead', {}, head), el('tbody', {}, body));
}
