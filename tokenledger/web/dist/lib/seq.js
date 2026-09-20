// web/dist/lib/seq.js — one loader, one sequence number. A response is applied
// only if no newer load started meanwhile; superseded fetches are aborted.

/** SKIPPED is the third status a result slot can carry, beside allSettled's
 *  own 'fulfilled' and 'rejected'. A fetcher list is a POSITIONAL CONTRACT --
 *  every apply() destructures it, and app.js reads review's SUMMARY_INDEX by
 *  number -- so a request that is deliberately not sent this round has to
 *  leave a hole rather than close the gap and shift everything after it.
 *
 *  It is a distinct status, not a fulfilled-with-null, because those two mean
 *  opposite things to a card: "the hub says there is nothing" draws an empty
 *  state, and "we did not ask" must draw nothing at all. Collapsing them is
 *  exactly how a deferred request turns into a card reporting no readings.
 */
export const SKIPPED = 'skipped';

export function createLoader() {
  let seq = 0, ctrl = null, running = 0;
  return {
    /** run sends every non-null fetcher and applies the results in the
     *  ORIGINAL positions. A null slot is not fetched and comes back as
     *  `{ status: SKIPPED }` — see SKIPPED above. */
    async run(fetchers, apply) {
      const mine = ++seq;
      if (ctrl) ctrl.abort();
      ctrl = new AbortController();
      const signal = ctrl.signal;
      running++;
      try {
        const sent = [];
        fetchers.forEach((f, i) => { if (f) sent.push(i); });
        const settled = await Promise.allSettled(sent.map((i) => fetchers[i](signal)));
        if (mine !== seq) return false;
        const results = fetchers.map(() => ({ status: SKIPPED }));
        sent.forEach((i, k) => { results[i] = settled[k]; });
        apply(results);
        return true;
      } finally {
        running--;
      }
    },
    get inFlight() { return running > 0; },
  };
}
