// web/dist/lib/trains.js — the /trains page's computations (claude-fleet#3870,
// EPIC #3863 C7): each release-train run as one time bar off the ledger's
// stages (GET /v1/fleet/release/stats — 共同约定 7, the one source), the
// 5-minute line, and the hub's own 「卡在哪段」 line. Pure: no DOM, no fetch.
import { t } from './i18n.js';

/** The 5-minute budget a train is held to (the hub's trainSlowSecs). */
export const SLOW_SECS = 300;

/** fmtSecs: 2 分 05 秒 / 45 秒 — null and NaN are a dash. */
export function fmtSecs(s) {
  if (s == null || !Number.isFinite(Number(s))) return '—';
  const n = Math.max(0, Math.round(Number(s)));
  const m = Math.floor(n / 60);
  const r = n % 60;
  return m ? t('ui.tr.ms', { m, s: String(r).padStart(2, '0') }) : t('ui.tr.s', { s: r });
}

/** stageKind is a stage's colour family. */
export function stageKind(name) {
  const n = String(name || '');
  if (n === 'board') return 'board';
  if (n === 'Linux') return 'lin';
  if (n === 'hub' || n === 'hub plan') return 'hub';
  if (n === 'release') return 'rel';
  if (n === 'mac follow') return 'mac';
  return 'other';
}

/** scaleOf is the seconds the bars share: at least a little past 5 minutes,
 *  else the longest on-path end — the Mac half and the node image beside the
 *  release never stretch it (they are drawn clipped). */
export function scaleOf(runs) {
  let max = SLOW_SECS * 1.1;
  for (const r of runs || []) {
    max = Math.max(max, Number(r.total_secs) || 0);
    for (const s of r.stages || []) if (!s.off_path) max = Math.max(max, (s.offset_secs || 0) + (s.secs || 0));
  }
  return max;
}

const pct = (x, max) => Math.max(0, Math.min(100, (x / max) * 100));

// a watcher spanning the run and the ledger itself: in the table, never a bar
const HIDDEN = new Set(['红灯即停', 'ledger']);

/** bars is one run's segments, as percentages of max: the runner wait at the
 *  front of a stage its own (queue) piece. A stage of 0 s, the watcher and the
 *  ledger are left out; off-path stages come first, so the path draws on top. */
export function bars(run, max) {
  const out = [];
  for (const s of (run && run.stages) || []) {
    if (!(s.secs > 0) || HIDDEN.has(s.name)) continue;
    const left = pct(s.offset_secs || 0, max);
    const width = Math.max(0.6, Math.min(100 - left, pct(s.secs, max)));
    const q = s.queue_secs > 0 ? Math.min(width, pct(s.queue_secs, max)) : 0;
    out.push({ name: s.name, kind: stageKind(s.name), left, width, queue: q, off: !!s.off_path,
      red: s.result === 'failure', title: `${s.name} · ${fmtSecs(s.secs)}` });
  }
  return out.sort((a, b) => Number(b.off) - Number(a.off));
}

/** state is a run's pill: [chip class, words]. */
export function state(run) {
  const c = run && run.conclusion;
  if (c === 'failure' || c === 'cancelled') return ['bad', t('ui.tr.notShipped')];
  if ((run.total_secs || 0) > SLOW_SECS) return ['warn', t('ui.tr.slow')];
  if (c === 'superseded') return ['', t('ui.tr.superseded')];
  return ['ok', t('ui.tr.shipped')];
}

/** whyLine is the hub's bottleneck in one sentence, or '' when there is none. */
export function whyLine(run) {
  const b = run && run.bottleneck;
  if (!b) return '';
  if (!b.stage) return t('ui.tr.whyNoStage', { why: b.why || '' });
  return t('ui.tr.why', { stage: b.stage, secs: fmtSecs(b.secs), why: b.why || '' });
}

/** kpis are the four cells: merge → stable p50 (and p95), shipped of started,
 *  a run's median, and the slow / unshipped ones the board names a stage for. */
export function kpis(st) {
  const s = st || {};
  const over = (v) => (v == null ? '' : v > SLOW_SECS ? 'bad' : 'ok');
  return [
    { key: 'p50', label: t('ui.tr.k.p50'), value: fmtSecs(s.merge_to_stable_p50), cls: over(s.merge_to_stable_p50),
      sub: t('ui.tr.k.p95', { v: fmtSecs(s.merge_to_stable_p95), n: s.merge_to_stable_n || 0 }) },
    { key: 'shipped', label: t('ui.tr.k.shipped'), value: `${s.runs_shipped || 0}/${s.runs_started || 0}`,
      cls: s.runs_started ? (s.runs_shipped / s.runs_started >= 0.9 ? 'ok' : 'warn') : '', sub: '' },
    { key: 'run', label: t('ui.tr.k.run'), value: fmtSecs(s.run_p50_secs), cls: over(s.run_p50_secs), sub: '' },
    { key: 'slow', label: t('ui.tr.k.slow'), value: String(s.runs_slow || 0), cls: s.runs_slow ? 'warn' : 'ok',
      sub: t('ui.tr.k.said', { n: s.runs_slow_said || 0, of: s.runs_slow || 0 }) },
  ];
}

/** lanes are the two channels: what Linux machines run (stable) and Macs
 *  (stable-macos), and how far the Mac lane trails. */
export function lanes(st) {
  const l = (st && st.lanes) || {};
  const short = (x) => (x ? String(x).slice(0, 7) : '—');
  const linux = { label: t('ui.tr.lane.linux'), sha: short(l.stable), cls: l.stable ? 'ok' : '' };
  let mac;
  if (!l.stable_macos) mac = { label: t('ui.tr.lane.mac'), sha: short(l.stable), cls: l.stable ? 'ok' : '', note: t('ui.tr.lane.same') };
  else if (l.stable_macos === l.stable) mac = { label: t('ui.tr.lane.mac'), sha: short(l.stable_macos), cls: 'ok', note: t('ui.tr.lane.same') };
  else mac = { label: t('ui.tr.lane.mac'), sha: short(l.stable_macos), cls: 'warn', note: t('ui.tr.lane.behind') };
  return [linux, mac];
}
