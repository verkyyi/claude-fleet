import { useEffect, useRef } from "react";

// One read at a time, the next one scheduled only after it settles: a slow home never
// stacks requests into the entry's per-person limit (429). Failures back off (×2 up to
// maxMs) and the first success returns to baseMs; focus / online / a visible tab read
// at once. `fails` counts consecutive failures, so a page can ignore a single blip.
export function usePoll(read: () => Promise<void>, baseMs: number, maxMs = 60_000, onFail?: (fails: number, e: unknown) => void) {
  const fn = useRef(read); fn.current = read;
  const fail = useRef(onFail); fail.current = onFail;
  useEffect(() => {
    let live = true, busy = false, fails = 0, timer: ReturnType<typeof setTimeout> | undefined;
    const run = async () => {
      if (!live || busy) return;
      clearTimeout(timer);
      if (document.visibilityState !== "visible") { timer = setTimeout(run, baseMs); return; }
      busy = true;
      try { await fn.current(); fails = 0; }
      catch (e) { fails++; fail.current?.(fails, e); }
      finally { busy = false; if (live) timer = setTimeout(run, Math.min(maxMs, baseMs * 2 ** Math.min(fails, 6))); }
    };
    const wake = () => { if (document.visibilityState === "visible") void run(); };
    void run();
    window.addEventListener("online", wake); window.addEventListener("focus", wake); document.addEventListener("visibilitychange", wake);
    return () => { live = false; clearTimeout(timer); window.removeEventListener("online", wake); window.removeEventListener("focus", wake); document.removeEventListener("visibilitychange", wake); };
  }, [baseMs, maxMs]);
}
