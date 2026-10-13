// api.ts — the console's reads (EPIC #3923 rule 7): only the entry's existing
// /v1/*, same origin, the person's own ccq_sess cookie, nothing else.
import { useEffect, useState } from "react";

// GET a JSON read; a 401 means the session ended — to the sign-in, which
// brings the person back.
export async function getJSON<T>(url: string): Promise<T | null> {
  const r = await fetch(url, { headers: { Accept: "application/json" } }).catch(() => null);
  if (r?.status === 401) { location.assign("/app/signin"); return null; }
  return r && r.ok ? ((await r.json().catch(() => null)) as T | null) : null;
}

// /v1/me: who the gate admitted — role (admin | user | operator), the pages
// the menu shows them, how they signed in, whether a sign-out has a cookie to clear.
export type Me = {
  via?: string; role?: string; person?: string; name?: string; login?: string;
  pages?: string[]; entry?: boolean; can_logout?: boolean;
};
export type MeState = { me: Me | null; loading: boolean };
let meCache: Promise<Me | null> | null = null;
export function useMe(): MeState {
  const [s, set] = useState<MeState>({ me: null, loading: true });
  useEffect(() => {
    meCache ??= getJSON<Me>("/v1/me");
    let live = true;
    meCache.then((me) => live && set({ me, loading: false }));
    return () => { live = false; };
  }, []);
  return s;
}
export const isAdmin = (me: Me | null) => !!me && me.role !== undefined && me.role !== "user" && me.role !== "";

// The person's own limit (fleet.person_budget) off /v1/me/usage — the one the
// proxies hold their sessions to and the conversation too. Null = no limit set.
export type Quota = { pct: number; window: "week" | "5h"; over: boolean; reset?: string };
export function quotaOf(limit: Record<string, unknown> | undefined): Quota | null {
  if (!limit || !limit.set) return null;
  const rows: Quota[] = [];
  for (const w of ["week", "5h"] as const) {
    const lim = Number(limit[`limit_${w}`]), left = Number(limit[`remaining_${w}`]);
    if (lim > 0 && Number.isFinite(left)) {
      const reset = limit[`reset_${w}`] ? String(limit[`reset_${w}`]) : undefined;
      rows.push({ pct: Math.max(0, Math.min(100, Math.round((left / lim) * 100))), window: w, over: left <= 0, ...(reset ? { reset } : {}) });
    }
  }
  if (!rows.length) return null;
  // the binding window is the one with the least left; the hub's own word on which one is over wins
  rows.sort((a, b) => a.pct - b.pct);
  const over = limit.over ? rows.find((r) => r.window === limit.window) : undefined;
  return over ? { ...over, over: true, pct: 0 } : rows[0];
}
export function useQuota(key: unknown = 0) {
  const [q, setQ] = useState<Quota | null>(null);
  useEffect(() => {
    getJSON<{ limit?: Record<string, unknown> }>("/v1/me/usage?range=today").then((j) => setQ(quotaOf(j?.limit)));
  }, [key]);
  return q;
}

// /v1/fleet/devices: the person's own registered computers (a revoked one, or
// a hosting machine's own login, is not one of their devices).
export type Device = { fingerprint: string; name: string; revoked_at?: string; host?: boolean };
export function useDeviceCount() {
  const [n, setN] = useState<number | null>(null);
  useEffect(() => {
    getJSON<{ devices?: Device[] }>("/v1/fleet/devices").then((j) =>
      setN(j?.devices ? j.devices.filter((d) => !d.revoked_at && !d.host).length : null));
  }, []);
  return n;
}
