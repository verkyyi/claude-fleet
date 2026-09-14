// web/dist/lib/repo.js — repo-progress arithmetic. No DOM, so node can test it.
//
// Every function here obeys one rule: a threshold is never a constant. The
// scale an age is judged against comes from the repository's own close-time
// distribution, shipped with the data, and when it is missing these functions
// say so rather than substituting one. Measured on one real repo — 2,688
// issues in 82 days — the median issue closed in 0.13 days and p95 was 10.9;
// "stale after 30 days" would have found nothing there and would find
// everything in a repo that works in quarters.

const DAY = 86400;
const HOUR = 3600;

/** fmtAge renders a duration in seconds at the coarsest unit that still says
 *  something. A backlog whose rows read "1123200s" is a backlog nobody reads. */
export function fmtAge(seconds, t = (k, v) => `${v.n}${k.slice(-1)}`) {
  const s = Math.max(0, Number(seconds) || 0);
  if (s < HOUR) return t('repo.unit.m', { n: Math.round(s / 60) });
  if (s < DAY) return t('repo.unit.h', { n: round1(s / HOUR) });
  if (s < 90 * DAY) return t('repo.unit.d', { n: round1(s / DAY) });
  return t('repo.unit.mo', { n: round1(s / (30 * DAY)) });
}

const round1 = (n) => Math.round(n * 10) / 10;

/** isoWeekStart returns the Monday of the UTC week containing a YYYY-MM-DD
 *  key, as another YYYY-MM-DD key. Weeks, not days, because issue flow at day
 *  resolution over 90 days is noise with a trend hidden inside it. */
export function isoWeekStart(day) {
  const d = new Date(day + 'T00:00:00Z');
  if (Number.isNaN(d.getTime())) return null;
  // getUTCDay: 0=Sunday. Shift so Monday is the start of the week.
  const back = (d.getUTCDay() + 6) % 7;
  d.setUTCDate(d.getUTCDate() - back);
  return d.toISOString().slice(0, 10);
}

/** weeklyFlow folds daily rows into weeks.
 *
 *  opened and closed SUM across the week; open_at_end does not — it is a
 *  level, not a rate, and adding seven levels together would produce a number
 *  seven times the backlog that nothing in the repo ever reached. The week's
 *  level is the last day in it that reported one. */
export function weeklyFlow(days) {
  const weeks = new Map();
  for (const d of days || []) {
    const wk = isoWeekStart(d.day);
    if (!wk) continue;
    let w = weeks.get(wk);
    if (!w) { w = { week: wk, opened: 0, closed: 0, openAtEnd: null, merged: null, lastDay: '' }; weeks.set(wk, w); }
    w.opened += d.opened || 0;
    w.closed += d.closed || 0;
    if (typeof d.merged_prs === 'number') w.merged = (w.merged || 0) + d.merged_prs;
    if (d.day >= w.lastDay) { w.lastDay = d.day; w.openAtEnd = d.open_at_end ?? null; }
  }
  return [...weeks.values()].sort((a, b) => (a.week < b.week ? -1 : 1));
}

/** net is opened minus closed: positive means the backlog grew that week.
 *  It is the one number in the flow card that answers "are we keeping up". */
export const net = (w) => (w.opened || 0) - (w.closed || 0);

/** scaleBands turns a close-time distribution into the age bands a backlog is
 *  read in. Returns [] when the shipper computed no percentiles — the caller
 *  must then say the scale is unknown, never fall back to a constant.
 *
 *  Each band carries `from`/`to` in seconds (to === null means open-ended) and
 *  the percentile name it came from, so the legend can say WHERE the edge came
 *  from rather than printing a bare number a reader would take for a policy. */
export function scaleBands(scale) {
  if (!scale) return [];
  const edges = [];
  const add = (name, v) => { if (typeof v === 'number' && v > 0) edges.push({ name, at: v }); };
  add('p50', scale.p50_seconds);
  add('p90', scale.p90_seconds);
  add('p95', scale.p95_seconds);
  // A shipper that computed only some of them still gives a usable ladder, but
  // only if the ones present are ordered; out-of-order input is a shipper bug
  // and sorting it silently would hide that from whoever has to fix it.
  for (let i = 1; i < edges.length; i++) {
    if (edges[i].at < edges[i - 1].at) return [];
  }
  if (!edges.length) return [];
  const bands = [];
  let from = 0;
  for (const e of edges) {
    bands.push({ key: 'le-' + e.name, from, to: e.at, edge: e.name });
    from = e.at;
  }
  bands.push({ key: 'gt-' + edges[edges.length - 1].name, from, to: null, edge: edges[edges.length - 1].name });
  return bands;
}

/** ageHistogram counts issues into the bands scaleBands produced.
 *
 *  Returns null — not an empty histogram — when there is no scale. The two are
 *  different answers ("no issues" vs "no way to judge them") and a card that
 *  rendered them the same would be the exact failure this feature exists to
 *  prevent. */
export function ageHistogram(issues, scale) {
  const bands = scaleBands(scale);
  if (!bands.length) return null;
  const counts = bands.map((b) => ({ ...b, count: 0 }));
  for (const i of issues || []) {
    const age = Number(i.age_seconds) || 0;
    // Last band is open-ended, so a linear scan lands everything.
    const hit = counts.find((b) => b.to === null || age < b.to);
    if (hit) hit.count++;
  }
  return counts;
}

/** stalled keeps the issues past the repo's own p95, worst first.
 *
 *  Without a p95 it returns [] and `reason: 'no-scale'`, because there is no
 *  honest stalled list on a repo nobody has measured. */
export function stalled(issues, scale) {
  const p95 = scale && typeof scale.p95_seconds === 'number' ? scale.p95_seconds : null;
  if (p95 == null) return { rows: [], reason: 'no-scale' };
  const rows = (issues || [])
    .filter((i) => i.state === 'open' && (Number(i.age_seconds) || 0) >= p95)
    .sort((a, b) => (Number(b.age_seconds) || 0) - (Number(a.age_seconds) || 0));
  return { rows, reason: rows.length ? '' : 'none' };
}

/** shippedButOpen are the issues whose work already landed in a merged commit
 *  while the issue stayed open. They are the actionable half of a stalled
 *  list: a close, not an investigation. */
export const shippedButOpen = (issues) =>
  (issues || []).filter((i) => i.state === 'open' && i.shipped_at);

/** pickRepo resolves which repository to show: the URL's choice when it names
 *  one this hub actually holds, otherwise the most recently observed.
 *
 *  An unknown name falls back rather than rendering an empty page. A link
 *  outliving the repository it names should still open on something. */
export function pickRepo(wanted, repos) {
  const names = (repos || []).map((r) => r.repo);
  return names.includes(wanted) ? wanted : names[0];
}
