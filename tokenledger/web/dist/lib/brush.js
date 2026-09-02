// web/dist/lib/brush.js — timeline extent and selection arithmetic. No DOM.
export const SPANS = {
  '7d':  { ms: 7 * 864e5,  bucket: 36e5 },
  '30d': { ms: 30 * 864e5, bucket: 6 * 36e5 },
  '90d': { ms: 90 * 864e5, bucket: 864e5 },
};
const SEVEN_DAYS = 7 * 864e5;

export function snap(ms, bucket, mode = 'round') {
  const q = ms / bucket;
  const k = mode === 'floor' ? Math.floor(q) : mode === 'ceil' ? Math.ceil(q) : Math.round(q);
  return k * bucket;
}

export function extent(span, now) {
  const { ms, bucket } = SPANS[span] || SPANS['30d'];
  const end = snap(now, bucket, 'ceil');
  const n = Math.round(ms / bucket);
  return { start: end - n * bucket, end, bucket, n };
}

export function defaultSelection(span, now) {
  const e = extent(span, now);
  if ((SPANS[span] || SPANS['30d']).ms <= SEVEN_DAYS) return { from: e.start, to: null };
  return { from: e.end - SEVEN_DAYS, to: null };
}

export function clamp(sel, e) {
  let from = Math.max(e.start, Math.min(sel.from, e.end - e.bucket));
  let to = sel.to == null ? null : Math.min(e.end, Math.max(sel.to, from + e.bucket));
  if (to != null && to - from < e.bucket) to = from + e.bucket;
  if (to != null && to > e.end) { to = e.end; from = Math.min(from, to - e.bucket); }
  return { from, to };
}

export function fit(sel, span, now) {
  if (!sel || !sel.from) return defaultSelection(span, now);
  const e = extent(span, now);
  const to = sel.to == null ? e.end : sel.to;
  if (sel.from < e.start || to > e.end || to <= sel.from) return defaultSelection(span, now);
  return sel;
}

export function resolve(sel, span, now) {
  const e = extent(span, now);
  const s = fit(sel, span, now);
  return { from: s.from, to: s.to == null ? e.end : s.to, live: s.to == null };
}
