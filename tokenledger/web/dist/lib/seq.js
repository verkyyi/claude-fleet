// web/dist/lib/seq.js — one loader, one sequence number. A response is applied
// only if no newer load started meanwhile; superseded fetches are aborted.
export function createLoader() {
  let seq = 0, ctrl = null, running = 0;
  return {
    async run(fetchers, apply) {
      const mine = ++seq;
      if (ctrl) ctrl.abort();
      ctrl = new AbortController();
      const signal = ctrl.signal;
      running++;
      try {
        const results = await Promise.allSettled(fetchers.map((f) => f(signal)));
        if (mine !== seq) return false;
        apply(results);
        return true;
      } finally {
        running--;
      }
    },
    get inFlight() { return running > 0; },
  };
}
