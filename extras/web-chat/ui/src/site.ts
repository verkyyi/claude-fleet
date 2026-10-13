// site.ts — what the website's /chat build adds (issue #3646, EPIC #3642 C4).
// The same page, two homes: ../server.mjs serves it at / with its API at /api
// (the local build); the entry serves it at /chat/ with the API at /v1/chat
// (`vite build --mode site`). Everything here reads the entry the person is
// already signed in to — same origin, their own ccq_sess cookie, nothing else.
import { useEffect, useState } from "react";

export const SITE = import.meta.env.MODE === "site";
export const API = SITE ? "/v1/chat" : "/api";

const get = async (url: string) => {
  const r = await fetch(url, { headers: { Accept: "application/json" } }).catch(() => null);
  if (r?.status === 401) { location.assign("/app/signin"); return null; }
  return r && r.ok ? r.json().catch(() => null) : null;
};

// /v1/me: the name for the avatar, the pages for the nav.
export type Me = { name?: string; login?: string; person?: string; pages?: string[]; can_logout?: boolean };
export function useMe() {
  const [me, setMe] = useState<Me | null>(null);
  useEffect(() => { if (SITE) get("/v1/me").then(setMe); }, []);
  return me;
}

// The person's own limit (fleet.person_budget) off /v1/me/usage — the one the
// proxies hold their sessions to and this conversation too. Null = no limit set.
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
export function useQuota(turns: number) {
  const [q, setQ] = useState<Quota | null>(null);
  useEffect(() => {
    if (!SITE) return;
    get("/v1/me/usage?range=today").then((j) => setQ(quotaOf(j?.limit)));
  }, [turns]);
  return q;
}

// /v1/chat/home: where this conversation runs — the entry's own answer, no relay.
export type Home = { machine: string; login: string; state: "ok" | "offline" | "maintenance" | "old_agent" };
export function useHome(key: unknown) {
  const [h, setH] = useState<Home | null>(null);
  useEffect(() => { if (SITE) get(`${API}/home`).then((j) => setH(j && j.machine ? j : null)); }, [key]);
  return h;
}

// "周一 08:00", "今天 08:00", "明天 08:00" — when a window frees up, in the reader's own time.
export function whenLocal(iso: string | undefined, now = new Date()): string {
  const t = iso ? new Date(iso) : null;
  if (!t || Number.isNaN(t.getTime())) return "";
  const hm = `${String(t.getHours()).padStart(2, "0")}:${String(t.getMinutes()).padStart(2, "0")}`;
  const day = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const days = Math.round((day(t) - day(now)) / 86400000);
  if (days === 0) return `今天 ${hm}`;
  if (days === 1) return `明天 ${hm}`;
  if (days > 1 && days < 7) return `周${"日一二三四五六"[t.getDay()]} ${hm}`;
  return `${t.getMonth() + 1}月${t.getDate()}日 ${hm}`;
}
