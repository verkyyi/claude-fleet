// web/dist/lib/human.js — the arithmetic behind "what is waiting on a person".
// No DOM, so node can test it.
//
// One rule runs through every function here: this hub cannot tell two viewers
// apart. Its SSO ticket carries one fixed subject per (app, tenant), so there
// is no honest way to compute "mine" — and the moment a function here took a
// viewer argument, every surface above it would start claiming it. So the
// grouping is by OWNER and the caller says "everyone's" out loud.

import { isoWeekStart } from './repo.js';

/** Owner resolutions, mirroring the server's closed set. A fourth spelling
 *  would quietly become a fourth group nothing counts. */
export const OWNER_PERSON = 'person';
export const OWNER_NOT_A_PERSON = 'not-a-person';
export const OWNER_UNRESOLVED = 'unresolved';

/** groupByOwner folds steps into one group per owner, longest wait first —
 *  both within a group and between them.
 *
 *  The group key is owner_id when there is one, and the raw owner string
 *  otherwise. That matters: the same person is written "发起人" in one
 *  fragment and "Verky Yi" in the next, and two groups for one human would
 *  understate how much any single person is holding. The DISPLAY name stays
 *  the one from the longest-waiting step, so the group is labelled with the
 *  spelling of the thing that has been stuck longest.
 *
 *  Steps nobody can be reminded about (`not-a-person`, `unresolved`) are
 *  groups like any other. They are the most stuck rows on the page — nobody
 *  is ever going to be told about them — so hiding them would invert the
 *  page's whole point. */
export function groupByOwner(steps) {
  const groups = new Map();
  for (const s of steps || []) {
    const key = (s.owner_kind === OWNER_PERSON && s.owner_id) ? `id:${s.owner_id}` : `raw:${s.owner_kind}:${s.owner}`;
    let g = groups.get(key);
    if (!g) {
      g = { key, owner: s.owner, ownerId: s.owner_id || '', kind: s.owner_kind, steps: [], waiting: 0, untold: 0 };
      groups.set(key, g);
    }
    g.steps.push(s);
    const w = Number(s.waiting_seconds) || 0;
    if (w > g.waiting) { g.waiting = w; g.owner = s.owner; }
    if (!s.todo_at) g.untold++;
  }
  for (const g of groups.values()) {
    g.steps.sort((a, b) => (Number(b.waiting_seconds) || 0) - (Number(a.waiting_seconds) || 0));
  }
  return [...groups.values()].sort((a, b) => b.waiting - a.waiting);
}

/** untold counts steps nobody has been told about yet.
 *
 *  It is tracked separately from "waiting" because the two have different
 *  culprits: a step nobody was told about is the SYSTEM failing to deliver it,
 *  not a person failing to do it, and a page that shows only the total blames
 *  the wrong party — silently. */
export const untold = (steps) => (steps || []).filter((s) => !s.todo_at).length;

/** weeklyHuman folds the daily rows into weeks and computes the share of
 *  release fragments that needed a person.
 *
 *  ratio is null — never 0 — for a week with no fragments at all. A quiet week
 *  and a week where nothing needed a human are opposite facts, and a chart
 *  that draws both as a zero teaches a reader to believe the wrong one. */
export function weeklyHuman(days) {
  const weeks = new Map();
  for (const d of days || []) {
    const wk = isoWeekStart(d.day);
    if (!wk) continue;
    let w = weeks.get(wk);
    if (!w) { w = { week: wk, fragments: 0, withHuman: 0, steps: 0, stepsDone: 0, ratio: null }; weeks.set(wk, w); }
    w.fragments += d.fragments || 0;
    w.withHuman += d.with_human || 0;
    w.steps += d.steps || 0;
    w.stepsDone += d.steps_done || 0;
  }
  for (const w of weeks.values()) {
    w.ratio = w.fragments > 0 ? w.withHuman / w.fragments : null;
  }
  return [...weeks.values()].sort((a, b) => (a.week < b.week ? -1 : 1));
}

/** trimLeadingEmpty drops the weeks BEFORE the first one that had any
 *  fragment at all.
 *
 *  Those weeks are not a quiet period — they are before this repository
 *  started writing release fragments, so there is nothing there to be quiet
 *  about. Keeping them spends most of the chart on blank space and, worse,
 *  makes "across the last 14 weeks" count eleven weeks that never existed.
 *
 *  ⚠️ Only LEADING ones. A gap in the middle is a real quiet week and must
 *  stay a gap: closing it up would slide the bars along the axis and make two
 *  weeks that are a month apart look adjacent. */
export function trimLeadingEmpty(weeks) {
  const i = (weeks || []).findIndex((w) => (w.fragments || 0) > 0);
  return i <= 0 ? (weeks || []) : weeks.slice(i);
}

/** windowRatio is the share across the whole window: the numerators and
 *  denominators summed, never the mean of the weekly ratios.
 *
 *  Averaging ratios weights a week with four fragments the same as a week with
 *  four hundred, which is how a single quiet week with one manual fragment
 *  turns into "25% of our work is manual". Returns null when the window holds
 *  no fragments at all. */
export function windowRatio(weeks) {
  let f = 0, h = 0;
  for (const w of weeks || []) { f += w.fragments || 0; h += w.withHuman || 0; }
  return f > 0 ? h / f : null;
}

/** trend compares the latest week that has a ratio against everything before
 *  it in the window, and reports which way it moved.
 *
 *  It deliberately refuses to answer from a single week: "the ratio is
 *  falling" needs something to fall from, and one point with a direction
 *  attached is the most confident-looking wrong sentence a dashboard can
 *  print. `{ direction: 'unknown' }` is the honest output until then.
 *
 *  ⚠️ The latest week is usually PARTIAL (the shipper runs daily), so it is
 *  compared on ratio and never on counts — a half-week always has fewer
 *  fragments, which would read as a collapse every Monday. */
export function trend(weeks) {
  const withRatio = (weeks || []).filter((w) => w.ratio != null);
  if (withRatio.length === 0) return { direction: 'unknown', latest: null, before: null };
  const latest = withRatio[withRatio.length - 1];
  const earlier = withRatio.slice(0, -1);
  if (!earlier.length) return { direction: 'unknown', latest, before: null };
  const before = windowRatio(earlier);
  // A tenth of a percentage point is not a direction. The band keeps a page
  // that redraws daily from announcing a reversal every morning.
  const delta = latest.ratio - before;
  const dir = Math.abs(delta) < 0.005 ? 'level' : (delta < 0 ? 'down' : 'up');
  return { direction: dir, latest, before, delta };
}

/** pct renders a share as a percentage with one decimal below 10%, because
 *  the numbers this metric lives in are small: "2%" and "2.4%" are the
 *  difference between two weeks, and rounding them together hides the trend
 *  the metric exists to show. */
export function pct(ratio) {
  if (ratio == null) return null;
  const p = ratio * 100;
  return (p < 10 ? Math.round(p * 10) / 10 : Math.round(p)) + '%';
}
