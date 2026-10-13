// try.ts — the 60-second trial's clock (issue #3590). /app/try writes when the
// person pressed 「60 秒试用」 into sessionStorage (fleet.try.t0); the chat shows
// the clock running and stops it at the first text of the first reply: 「你用了
// 0:47」, and the hub keeps the time once, anonymously (/v1/try/timing).
import { useCallback, useEffect, useState } from "react";

const KEY = "fleet.try.t0";

export const fmtClock = (ms: number) => {
  const s = Math.max(0, Math.floor(ms / 1000));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
};

export function useTryClock() {
  const [t0] = useState(() => Number(sessionStorage.getItem(KEY)) || 0);
  const [now, setNow] = useState(() => Date.now());
  const [took, setTook] = useState<number | null>(null);
  useEffect(() => {
    if (!t0 || took !== null) return;
    const t = window.setInterval(() => setNow(Date.now()), 250);
    return () => clearInterval(t);
  }, [t0, took]);
  const stop = useCallback(() => {
    if (!t0 || took !== null) return;
    const ms = Date.now() - t0;
    sessionStorage.removeItem(KEY);
    setTook(ms);
    void fetch("/v1/try/timing", {
      method: "POST",
      headers: { "X-Fleet-Try": "1", "Content-Type": "application/json" },
      body: JSON.stringify({ ms }),
    }).catch(() => {});
  }, [t0, took]);
  return { running: !!t0 && took === null, elapsed: now - t0, took, stop };
}
