// web/dist/lib/format.js — pure number/time formatting. No DOM.
// fmtInt, fmtUSD, fmtFull, shortProject, relTime, ago are copied verbatim from
// the <script> block of the original web/dist/index.html — they were already
// pure, just inlined there.
export const fmtInt = (n) => {
  n = Number(n) || 0;
  if (n >= 1e9) return (n / 1e9).toFixed(1) + "B";
  if (n >= 1e6) return (n / 1e6).toFixed(1) + "M";
  if (n >= 1e3) return (n / 1e3).toFixed(1) + "k";
  return String(Math.round(n));
};
export const fmtUSD = (n) => "$" + (Number(n) || 0).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
// Aggregates retain the known subtotal and a separate missing-price count.
// A wholly unpriced bucket is unknown; a partial subtotal is a lower bound.
export const fmtCost = (b) => {
  if (b.cost_usd == null) return '—';
  if (b.unpriced_events > 0) {
    const count = b.events ?? b.turns;
    if (count > 0 && b.unpriced_events >= count) return '—';
    return '≥ ' + fmtUSD(b.cost_usd);
  }
  return fmtUSD(b.cost_usd);
};
export const fmtFull = (n) => (Number(n) || 0).toLocaleString();

/** shortProject trims a working directory to its last two segments. Full paths
 *  are long, and on a shared hub they leak more than they inform. */
export const shortProject = (p) => {
  if (!p) return "(unknown)";
  const parts = p.replace(/\\/g, "/").replace(/\/+$/, "").split("/").filter(Boolean);
  if (parts.length <= 2) return p;
  // Two segments where they fit, one where they do not. What distinguishes
  // sibling worktrees is the LAST segment, so it must never be the part that
  // gets clipped — otherwise every row reads "…/projects/24haowan-monorepo…".
  const two = parts.slice(-2).join("/");
  return "…/" + (two.length <= 30 ? two : parts[parts.length - 1]);
};

export const relTime = (iso) => {
  if (!iso) return "reset time unknown";
  const ms = new Date(iso) - Date.now();
  if (ms <= 0) return "resetting now";
  const m = Math.round(ms / 60000);
  if (m < 60) return `resets in ${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `resets in ${h}h ${m % 60}m`;
  return `resets in ${Math.floor(h / 24)}d ${h % 24}h`;
};

export const ago = (secs) => {
  if (secs == null) return "";
  if (secs < 90) return `${Math.round(secs)}s ago`;
  if (secs < 5400) return `${Math.round(secs / 60)}m ago`;
  return `${Math.round(secs / 3600)}h ago`;
};

export const fmtPct = (x, digits = 1) => (Number(x) * 100).toFixed(digits) + '%';
export function fmtDur(ms) {
  const m = Math.round(ms / 60000);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ${m % 60}m`;
  return `${Math.floor(h / 24)}d ${h % 24}h`;
}
// A delta against a near-zero (but not exactly zero, which `delta` below
// already renders as "no previous data") baseline is technically defined
// but carries no information beyond "there was almost nothing before" — and
// on real data has been wide enough (measured: "+295242%") to force its own
// layout wider than the column it lives in. DELTA_CAP_PCT is the magnitude
// past which the exact number stops being worth rendering; `pct` on the
// returned object is always the real, uncapped value (its SIGN still drives
// kpiTile's up/down colouring either way), only `text` is capped.
export const DELTA_CAP_PCT = 999;

// delta compares two additive values. null pct means "no previous data".
export function delta(cur, prev) {
  if (!prev || !Number.isFinite(prev)) return { pct: null, text: '—' };
  const pct = ((cur - prev) / prev) * 100;
  const sign = pct > 0 ? '+' : '';
  if (Math.abs(pct) >= DELTA_CAP_PCT) return { pct, text: `${sign}≫${DELTA_CAP_PCT}%` };
  return { pct, text: `${sign}${Math.abs(pct) >= 10 ? Math.round(pct) : pct.toFixed(1)}%` };
}
