// web/dist/lib/buckets.js — bucket-key arithmetic for the time charts. No DOM.
//
// Two things a chart with a real time axis needs, and which neither brush.js
// (selection arithmetic, already in ms) nor format.js (display strings) owns:
//
//   bucketMs — one bucket KEY, in any shape the rollup emits, as epoch ms.
//   densify  — the buckets the API never sent, put back as zeroes.
//
// The second is what makes a time axis honest here. /v1/history's FoldHours
// (internal/api/history.go) only ever emits a bucket that HAD rows, so a
// quiet stretch is not a run of zeroes in the response — it is absent. Draw
// such a series by array index (what `stackedArea` did before issue #52) and
// time is silently compressed; draw it by timestamp without filling the
// holes and it is worse, because an area then interpolates straight across
// the gap and paints usage that never happened. Zero-filling first is what
// lets "x is time" and "the height is what was spent" both be true.

/** bucketMs reads a bucket key in any of the three raw shapes the rollup
 *  emits (day 'YYYY-MM-DD' — 10 chars, 6h 'YYYY-MM-DDTHH' — 13, hour
 *  'YYYY-MM-DDTHH:00' — 16; see internal/api/history.go's bucketKey) or an
 *  already-normalized full timestamp, and returns epoch ms.
 *
 *  The three raw lengths are mutually exclusive, so branching on length
 *  alone is sufficient. Deliberately granularity-free: a caller's series can
 *  mix in an already-full ISO key (review.js's `bucketISO` normalizes
 *  upstream for its own reasons) and this still has to accept that too. A
 *  number passes through, so a caller that already resolved the key can. */
export function bucketMs(key) {
  if (typeof key === 'number') return key;
  const k = String(key);
  if (k.length === 10) return Date.parse(k + 'T00:00:00Z');
  if (k.length === 13) return Date.parse(k + ':00:00Z');
  if (k.length === 16) return Date.parse(k + ':00Z');
  return Date.parse(k);
}

/** inferBucket guesses the bucket width from the data: the smallest positive
 *  gap between consecutive (sorted) timestamps. With holes in the series the
 *  smallest gap is the only one that can be a single bucket — a mean or a
 *  max would be inflated by exactly the gaps we are trying to fill. Returns
 *  0 when there is nothing to infer from (0 or 1 points, or all identical). */
export function inferBucket(msList) {
  let b = Infinity;
  for (let i = 1; i < msList.length; i++) {
    const d = msList[i] - msList[i - 1];
    if (d > 0 && d < b) b = d;
  }
  return Number.isFinite(b) ? b : 0;
}

/** MAX_POINTS caps what densify will build. A bad `bucket` (a caller passing
 *  seconds where ms were meant, say) would otherwise ask for millions of
 *  synthetic points and hang the tab. 2000 is far past any real span/bucket
 *  pair the dashboard offers — 90d at 1h is 2160, and 90d snaps to a 1d
 *  bucket (lib/brush.js's SPANS), so the real worst case is 720. */
const MAX_POINTS = 2000;

/** densify returns `points` sorted oldest-first with one zero entry inserted
 *  per bucket the series skipped, so consecutive entries are always exactly
 *  `bucket` apart. Real points are passed through BY REFERENCE (whatever
 *  payload they carry survives); a filled one is `{ms, key, empty: true}`
 *  with an ISO `key`, and carries no `stack`/`tokens` — every caller here
 *  already reads those as "absent means 0".
 *
 *  `bucket` is inferred from the data when not given. Bails out (returns the
 *  sorted input untouched) when there is nothing to infer, when the input is
 *  shorter than 2, or when the fill would exceed MAX_POINTS — a chart that
 *  interpolates one gap is a smaller wrong than a tab that stops
 *  responding. */
export function densify(points, bucket) {
  const sorted = [...points].sort((a, b) => a.ms - b.ms);
  if (sorted.length < 2) return sorted;
  const b = bucket > 0 ? bucket : inferBucket(sorted.map((p) => p.ms));
  if (!(b > 0)) return sorted;
  const span = sorted[sorted.length - 1].ms - sorted[0].ms;
  if (span / b + 1 > MAX_POINTS) return sorted;

  const out = [sorted[0]];
  for (let i = 1; i < sorted.length; i++) {
    const prev = sorted[i - 1].ms;
    // Round, not floor: an hour bucket is 3600000ms but a DAY bucket is not
    // a constant number of hours across a DST boundary in every timezone the
    // rollup could be keyed in, so a gap is "about k buckets", not exactly.
    const k = Math.round((sorted[i].ms - prev) / b);
    for (let j = 1; j < k; j++) {
      const ms = prev + j * b;
      out.push({ ms, key: new Date(ms).toISOString(), empty: true });
    }
    out.push(sorted[i]);
  }
  return out;
}
