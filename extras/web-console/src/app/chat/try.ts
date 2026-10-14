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

// 试用中 (issue #4059): a trial person's budget — 15 minutes on a machine or 20
// lines, whichever comes first. GET /v1/try/state says what is left; read on
// open, every 15 seconds and after each line (refresh), the seconds counted
// down here in between. null for anyone who is not on a trial.
export type TrialState = {
  state: "running" | "waiting" | "ended" | "member";
  secs_left: number;
  msgs_left: number;
  max_secs: number;
  max_msgs: number;
  ended?: string; // time · msgs
  applied?: string; // their request's state, "" for none
  apply: string; // where 「申请正式使用」 goes
};

export function useTrial(on: boolean) {
  const [st, setSt] = useState<TrialState | null>(null);
  const [at, setAt] = useState(0);
  const [now, setNow] = useState(() => Date.now());
  const refresh = useCallback(async () => {
    try {
      const r = await fetch("/v1/try/state", { credentials: "same-origin", headers: { Accept: "application/json" } });
      if (!r.ok) return;
      setSt(await r.json());
      setAt(Date.now());
    } catch { /* the next read */ }
  }, []);
  useEffect(() => {
    if (!on) return;
    void refresh();
    const t = window.setInterval(refresh, 15000);
    return () => clearInterval(t);
  }, [on, refresh]);
  const running = on && st?.state === "running";
  useEffect(() => {
    if (!running) return;
    const t = window.setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [running]);
  if (!on || !st || st.state === "member") return { trial: null, secsLeft: 0, refresh };
  const secsLeft = running ? Math.max(0, st.secs_left - Math.floor(Math.max(0, now - at) / 1000)) : st.secs_left;
  return { trial: st, secsLeft, refresh };
}
