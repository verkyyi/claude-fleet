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

/** covers asks whether a kept result set can answer THIS round's fetcher list:
 *  every question the list actually asks (a non-null slot) must have been asked
 *  last time too (a slot that did not come back SKIPPED).
 *
 *  Positional, for the same reason SKIPPED is, and it is the entire rule behind
 *  replay(). It needs to know nothing about what the holes MEAN: results
 *  fetched while the operations fold was closed carry holes exactly where the
 *  open fold's cards read, so replaying those into an open fold would draw
 *  eight cards reporting no readings. The other direction is safe and is the
 *  common one -- the fold closed, the extra results simply go unread.
 */
const covers = (results, fetchers) =>
  results.length === fetchers.length &&
  fetchers.every((f, i) => !f || results[i].status !== SKIPPED);

export function createLoader() {
  let seq = 0, ctrl = null, running = 0, last = null;
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
        last = results;
        apply(results);
        return true;
      } finally {
        running--;
      }
    },
    /** replay redraws from the results this loader last APPLIED and sends
     *  nothing. It is how a change that only narrows or reorders rows the page
     *  already has costs zero requests, rather than the full round trip that
     *  re-asks the hub the identical question. Returns false — meaning "you
     *  have to fetch" — when nothing is kept yet, or when this round asks
     *  something the kept set never asked (see covers above).
     *
     *  A replay SUPERSEDES whatever is in flight, exactly as a run does. That
     *  is not tidiness: the 60-second refresh may have gone out 200ms ago, and
     *  its apply() closes over the state as it stood then. Left running, it
     *  lands after this redraw and puts the table back in the order the reader
     *  just clicked away from. The click wins, and the rows it is drawn from
     *  are the same rows that response would have carried. */
    replay(fetchers, apply) {
      if (!last || !covers(last, fetchers)) return false;
      seq++;
      if (ctrl) { ctrl.abort(); ctrl = null; }
      apply(last);
      return true;
    },
    get inFlight() { return running > 0; },
  };
}
