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
  logins?: { machine: string; login: string }[]; // the (machine, login) pairs that are theirs
  reach?: { wechat: boolean }; // can the notices find them (claude-fleet#4057); absent = the service account's road is off
  view_as?: { person: string; name: string; by: string }; // an admin looking through their eyes, read-only (claude-fleet#3944)
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
export type Quota = { pct: number; window: "week" | "5h" | "trial"; over: boolean; reset?: string };
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
// A trial member's own limits off /v1/me/usage's `trial` (claude-fleet T796,
// me_trial.go): when it ends, the tokens used against its ceiling (counted as
// every limit counts them), the session count — and one state the bar colours
// by. Absent = not on a trial.
export type Trial = {
  state: "ok" | "soon" | "expired" | "spent";
  since?: string; until?: string; days_left?: number;
  tokens?: number; used_tokens: number;
  usd?: number; spent_usd?: number; // a ceiling written before T796
  sessions?: number; sessions_now: number;
  upgrade_asked?: string;
};
// A trial's tokens as a Quota (claude-fleet T796), so the pill and 用量 read
// one limit: the stricter of the trial's and the weekly budget's.
export function trialQuota(t: Trial | null | undefined): Quota | null {
  if (!t) return null;
  const over = t.state === "expired" || t.state === "spent";
  const lim = Number(t.tokens) || 0;
  if (!lim && !over) return null;
  const left = lim ? Math.max(0, Math.min(100, Math.round(((lim - (Number(t.used_tokens) || 0)) / lim) * 100))) : 100;
  return { pct: over ? 0 : left, window: "trial", over, ...(t.until ? { reset: t.until } : {}) };
}
const stricter = (a: Quota | null, b: Quota | null) => (!a ? b : !b ? a : b.over || b.pct < a.pct ? b : a);
export type UsageHead = { quota: Quota | null; trial: Trial | null };
export function useUsageHead(key: unknown = 0): UsageHead & { setTrial: (t: Trial | null) => void } {
  const [h, setH] = useState<UsageHead>({ quota: null, trial: null });
  useEffect(() => {
    getJSON<{ limit?: Record<string, unknown>; trial?: Trial }>("/v1/me/usage?range=today")
      .then((j) => setH({ quota: stricter(quotaOf(j?.limit), trialQuota(j?.trial)), trial: j?.trial ?? null }));
  }, [key]);
  return { ...h, setTrial: (trial) => setH((x) => ({ ...x, trial })) };
}
export function useQuota(key: unknown = 0) {
  return useUsageHead(key).quota;
}

// /v1/fleet/devices: the person's own registered computers (a revoked one, or
// a hosting machine's own login, is not one of their devices).
export type Device = {
  fingerprint: string; name: string; revoked_at?: string; host?: boolean;
  registered_at?: string; last_used_at?: string; last_machine?: string;
};
export function useDeviceCount() {
  const [n, setN] = useState<number | null>(null);
  useEffect(() => {
    getJSON<{ devices?: Device[] }>("/v1/fleet/devices").then((j) =>
      setN(j?.devices ? j.devices.filter((d) => !d.revoked_at && !d.host).length : null));
  }, []);
  return n;
}

// useLoad(url): one read a page draws from — loading, failed (the entry did
// not answer, or answered no), retry. reload() re-reads in place, keeping
// what is on screen until the answer comes.
export type Load<T> = { data: T | null; loading: boolean; failed: boolean; reload: () => void };
export function useLoad<T>(url: string): Load<T> {
  const [s, set] = useState<{ data: T | null; loading: boolean; failed: boolean }>({ data: null, loading: true, failed: false });
  const [n, setN] = useState(0);
  useEffect(() => {
    let live = true;
    getJSON<T>(url).then((data) => live && set({ data, loading: false, failed: data === null }));
    return () => { live = false; };
  }, [url, n]);
  return { ...s, reload: () => setN((x) => x + 1) };
}

// sendJSON: one write — the answer's body, or the entry's own sentence when
// it says no ({error: "…"} or {error: {message}}); status is the answer's
// (0 = none), for a page whose words depend on it (设置: 202 · 409 · 429).
export async function sendJSON<T>(method: string, url: string, body?: unknown): Promise<{ ok: true; data: T; status: number } | { ok: false; error: string; status: number }> {
  const r = await fetch(url, {
    method, headers: { Accept: "application/json", ...(body === undefined ? {} : { "Content-Type": "application/json" }) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  }).catch(() => null);
  if (r?.status === 401) { location.assign("/app/signin"); return { ok: false, error: "", status: 401 }; }
  const j = r ? await r.json().catch(() => null) : null;
  const status = r?.status ?? 0;
  if (r?.ok) return { ok: true, data: j as T, status };
  const e = j?.error;
  return { ok: false, error: typeof e === "string" ? e : typeof e?.message === "string" ? e.message : "", status };
}
