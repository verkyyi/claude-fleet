// pool.ts — what the subscription pool page computes from the hub's answers,
// with no DOM (EPIC #3923 C12): the old console's join, carried over as it was
// (tokenledger/web/dist/lib/admin.js · subscriptions / poolRows / leaseRows /
// switchRows, lib/cred-policy.js · who may use one), so the new page shows the
// same subscriptions with the same numbers.
import type { Credential, HubUser, PolicyEntry, PolicyView } from "./api";

export type Window = { p: number | null; resets: string | null };

export type LimitsBody = {
  five_hour?: any;
  seven_day?: any;
  windows?: any[];
  available?: boolean;
  reason?: string;
  plan?: string;
  source?: string;
  observed_at?: string;
  read_via?: string;
  read_note?: string;
};
export type AccountLimits = { account_uuid: string; label?: string; limits?: LimitsBody };
export type Account = { account_uuid: string; label?: string; display_name?: string; email?: string; source?: string; subscription_type?: string };
export type PoolCredential = Credential & {
  reauth_required?: boolean;
  refresh_error?: string;
  secret_expires_at?: string;
  created_at?: string;
};
export type LiveSession = {
  account?: string;
  session_id?: string;
  worktree?: string;
  cwd?: string;
  hostname?: string;
  os_user?: string;
  started_at?: string;
  observed_at?: string;
};
export type AccountSwitch = { from_account?: string; to_account?: string; observed_at?: string; endpoint_id?: string };
// /v1/admin/overview's pool rows (claude-fleet#3231)
export type OverviewPool = {
  owner: string;
  provider: string;
  account: string;
  label?: string;
  used_5h_pct?: number | null;
  used_7d_pct?: number | null;
  resets_5h_at?: string;
  resets_at?: string;
  people?: string[];
  sessions?: number;
  state?: string;
  limited?: string;
};

export type Prov = "claude" | "codex";

export type Sub = {
  id: string; // the account uuid, or cred:<provider>/<account> for a credential no usage names yet
  label: string;
  prov: Prov;
  plan: string;
  h5: Window | null;
  h7: Window | null;
  available: boolean;
  reason: string;
  sessions: number;
  cred: PoolCredential | null;
  paused: boolean;
  managed: boolean;
  readAt: string;
  readVia: string;
  readNote: string;
  // a member's own subscription (claude-fleet#4035): its owner's principal; "" = the pool's
  owner: string;
  // from /v1/admin/overview when it answers
  people: string[];
  limited: boolean;
  reauth: boolean;
};

const toMs = (v: unknown) => (typeof v === "number" ? v : Date.parse(String(v || "")));
const norm = (s: unknown) => String(s || "").trim().toLowerCase();

// pct is a utilization (0–1 or 0–100, the hub has sent both) as 0–100.
export function pct(u: unknown): number | null {
  if (u == null || u === "") return null;
  const n = Number(u);
  if (!Number.isFinite(n) || n < 0) return null;
  return Math.min(100, Math.round(n <= 1 ? n * 100 : n));
}

// windowsOf is a LimitsView's 5-hour and weekly windows, Codex's included.
export function windowsOf(lim?: LimitsBody): { h5: Window | null; h7: Window | null } {
  if (!lim || lim.available === false) return { h5: null, h7: null };
  let h5 = lim.five_hour || null;
  let h7 = lim.seven_day || null;
  for (const w of Array.isArray(lim.windows) ? lim.windows : []) {
    const mins = Number(w.minutes) || 0;
    if (!h5 && (mins === 300 || /5h|five|primary/i.test(w.id || w.label || ""))) h5 = w;
    else if (!h7 && (mins === 10080 || /week|seven|secondary/i.test(w.id || w.label || ""))) h7 = w;
  }
  const v = (w: any): Window | null => (w ? { p: pct(w.utilization), resets: w.resets_at || null } : null);
  return { h5: v(h5), h7: v(h7) };
}

export const provOf = (uuid: string, source?: string): Prov =>
  String(source || "").toLowerCase() === "codex" || String(uuid || "").startsWith("codex:") ? "codex" : "claude";
const credProv = (c: Credential): Prov => (c.provider === "codex" ? "codex" : "claude");
export const isStandIn = (uuid: string) => /^win_/.test(String(uuid || "")) || /:local$/.test(String(uuid || ""));
const credKey = (c: Credential) => `${c.provider}/${c.account}`;

// subscriptions joins usage, accounts, the vault's pool credentials, the
// paused list and live sessions into one row per subscription — the old
// page's join, pass for pass (claude-fleet#2104 · #2127): by identity, then
// exactly by label / e-mail / uuid, then a unique e-mail domain, then one
// credential and one real account of a provider. A guess that fits two
// accounts matches neither.
export function subscriptions(p: {
  limits?: { per_account?: AccountLimits[] } | null;
  accounts?: Account[] | null;
  creds?: { credentials?: PoolCredential[]; paused?: string[] } | null;
  paused?: string[];
  live?: { sessions?: LiveSession[] } | null;
}): Sub[] {
  const per = Array.isArray(p.limits?.per_account) ? p.limits!.per_account! : [];
  const accts = new Map((Array.isArray(p.accounts) ? p.accounts : []).map((a) => [a.account_uuid, a]));
  const pool = (p.creds?.credentials || []).filter((c) => c.principal_id === "pool" && c.provider !== "github");
  // members' own (claude-fleet#4035): shown, each with its owner, never matched as the pool's
  const own = (p.creds?.credentials || []).filter((c) => c.principal_id && c.principal_id !== "pool" && c.provider !== "github");
  const pausedSet = new Set((p.creds?.paused || p.paused || []).map(String));
  const n: Record<string, number> = {};
  for (const s of p.live?.sessions || []) if (s.account) n[s.account] = (n[s.account] || 0) + 1;
  const used = new Set<string>();
  type R = { pa: AccountLimits; a: Account | Record<string, never>; label: string; prov: Prov; cred: PoolCredential | null; owner?: string };
  const rows: R[] = per.map((pa) => {
    const a: any = accts.get(pa.account_uuid) || {};
    const label = pa.label || a.label || a.display_name || a.email || pa.account_uuid;
    return { pa, a, label, prov: provOf(pa.account_uuid, pa.limits?.source || a.source), cred: null };
  });
  const take = (r: R, c: PoolCredential) => {
    r.cred = c;
    used.add(credKey(c));
  };
  const free = (prov: Prov) => pool.filter((c) => !used.has(credKey(c)) && credProv(c) === prov);
  for (const r of rows) {
    const c = free(r.prov).find((x) => x.account_uuid && x.account_uuid === r.pa.account_uuid);
    if (c) take(r, c);
  }
  for (const r of rows) {
    if (r.cred) continue;
    const email = (r.a as Account).email;
    const keys = [norm(r.label), norm(email), norm(String(email || "").split("@")[0]), norm(r.pa.account_uuid)];
    const c = free(r.prov).find((x) => keys.includes(norm(x.account)));
    if (c) take(r, c);
  }
  const domainOf = (email?: string) => {
    const d = norm(String(email || "").split("@")[1]);
    return d ? [d, d.split(".")[0]] : [];
  };
  for (const c of pool) {
    if (used.has(credKey(c))) continue;
    const fit = rows.filter((r) => !r.cred && r.prov === credProv(c) && domainOf((r.a as Account).email).includes(norm(c.account)));
    if (fit.length === 1) take(fit[0], c);
  }
  for (const prov of ["claude", "codex"] as const) {
    const cs = pool.filter((c) => credProv(c) === prov);
    const real = rows.filter((r) => r.prov === prov && !isStandIn(r.pa.account_uuid));
    if (cs.length === 1 && real.length === 1 && !used.has(credKey(cs[0])) && !real[0].cred) take(real[0], cs[0]);
  }
  // a member's own credential takes the usage row of its account, when the pool did not
  const ownLeft = own.filter((c) => {
    const r = c.account_uuid ? rows.find((x) => !x.cred && x.pa.account_uuid === c.account_uuid) : undefined;
    if (r) Object.assign(r, { cred: c, owner: c.principal_id, label: c.account });
    return !r;
  });
  const base = { people: [] as string[], limited: false, reauth: false, owner: "" };
  const out: Sub[] = rows.map(({ pa, label, prov, cred, a, owner }) => {
    const w = windowsOf(pa.limits);
    return {
      ...base,
      id: pa.account_uuid,
      label,
      prov,
      plan: pa.limits?.plan || (a as Account).subscription_type || "",
      h5: w.h5,
      h7: w.h7,
      available: !!(pa.limits && pa.limits.available !== false),
      reason: pa.limits?.reason || "",
      sessions: n[pa.account_uuid] || 0,
      cred,
      owner: owner || "",
      paused: !!(cred && !owner && pausedSet.has(cred.account)),
      managed: !!cred,
      readAt: pa.limits?.observed_at || "",
      readVia: pa.limits?.read_via || "",
      readNote: pa.limits?.read_note || "",
    };
  });
  for (const c of [...pool.filter((x) => !used.has(credKey(x))), ...ownLeft]) {
    const mine = c.principal_id !== "pool";
    out.push({
      ...base,
      id: mine ? `own:${c.principal_id}/${credKey(c)}` : "cred:" + credKey(c),
      label: c.account,
      prov: credProv(c),
      plan: "",
      h5: null,
      h7: null,
      available: false,
      reason: "",
      sessions: 0,
      cred: c,
      owner: mine ? c.principal_id || "" : "",
      paused: !mine && pausedSet.has(c.account),
      managed: true,
      readAt: "",
      readVia: "",
      readNote: "",
    });
  }
  // the pool's own first (Claude, then Codex, by name); what it does not manage last
  return out.sort(
    (x, y) => Number(y.managed) - Number(x.managed) || (x.prov === y.prov ? x.label.localeCompare(y.label) : x.prov === "claude" ? -1 : 1),
  );
}

// withOverview lays /v1/admin/overview's pool over the rows, joined by
// (provider, vault account): its own reading of the windows wins (the old
// pool table's numbers), plus the people on it now and its limited / reauth
// state. A hub without it keeps the rows as they were.
export function withOverview(subs: Sub[], pool: OverviewPool[] | null | undefined): Sub[] {
  if (!Array.isArray(pool)) return subs;
  const by = new Map(pool.filter((s) => s.owner === "pool" && s.provider !== "github").map((s) => [`${s.provider}/${s.account}`, s]));
  return subs.map((s) => {
    const o = s.cred ? by.get(credKey(s.cred)) : undefined;
    if (!o) return s;
    const u5 = pct(o.used_5h_pct);
    const u7 = pct(o.used_7d_pct);
    return {
      ...s,
      h5: u5 == null ? s.h5 : { p: u5, resets: o.resets_5h_at || s.h5?.resets || null },
      h7: u7 == null ? s.h7 : { p: u7, resets: o.resets_at || s.h7?.resets || null },
      sessions: o.sessions ?? s.sessions,
      people: Array.isArray(o.people) ? o.people : [],
      limited: o.state === "limited",
      reauth: o.state === "reauth",
    };
  });
}

export type State = "ok" | "near" | "limited" | "reauth" | "paused" | "unmanaged";

// top is the fuller of a row's two windows.
export const top = (s: Sub) => Math.max(s.h5?.p ?? 0, s.h7?.p ?? 0);

// stateOf is a row's one chip: unmanaged (no vault credential) · paused ·
// reauth · limited (used up for now) · near (快满: a window at or past the
// pool's skip threshold) · ok.
export function stateOf(s: Sub, skip: number): State {
  if (!s.managed) return "unmanaged";
  if (s.paused) return "paused";
  if (s.reauth || s.cred?.reauth_required) return "reauth";
  if (s.limited || top(s) >= 100) return "limited";
  if (top(s) >= skip) return "near";
  return "ok";
}

export type CredTone = "ok" | "warn" | "bad";
// credState is the credential line: none · reauth · refresh error · expired ·
// ending within 30 days · stored on <date>.
export function credState(c: PoolCredential | null, now = Date.now()): { tone: CredTone; key: "none" | "reauth" | "error" | "expired" | "ends" | "ok"; at?: string } {
  if (!c) return { tone: "warn", key: "none" };
  if (c.reauth_required) return { tone: "bad", key: "reauth" };
  if (c.refresh_error) return { tone: "bad", key: "error" };
  const end = toMs(c.secret_expires_at);
  if (Number.isFinite(end) && end > 0) {
    if (end <= now) return { tone: "bad", key: "expired" };
    if (end - now < 30 * 86_400_000) return { tone: "warn", key: "ends", at: c.secret_expires_at };
  }
  return { tone: "ok", key: "ok", at: c.created_at };
}

// room is the pool's mean room left in a window over the managed, unpaused
// rows that report it, and the soonest reset after now; null when none does.
export function room(subs: Sub[], which: "h5" | "h7", now = Date.now()): { left: number; next: number | null } | null {
  const ws = subs.filter((s) => s.managed && !s.paused && s[which]?.p != null).map((s) => s[which]!);
  if (!ws.length) return null;
  const left = Math.round(ws.reduce((a, w) => a + (100 - (w.p as number)), 0) / ws.length);
  const next = ws.map((w) => toMs(w.resets)).filter((ms) => Number.isFinite(ms) && ms > now).sort((a, b) => a - b)[0];
  return { left, next: next || null };
}

const hostKey = (h?: string) => String(h || "").split(".")[0].toLowerCase();

// loginOwners answers who holds a (machine, login) pair (claude-fleet#3302).
export function loginOwners(users: HubUser[]) {
  const pair = new Map<string, string>();
  const byLogin = new Map<string, Set<string>>();
  const legacy = new Map<string, string>();
  for (const u of users) {
    if (u.machine_login) legacy.set(u.machine_login, u.login);
    for (const l of u.logins || []) {
      pair.set(hostKey(l.hostname) + "\0" + l.login, u.login);
      const s = byLogin.get(l.login) || new Set<string>();
      s.add(u.login);
      byLogin.set(l.login, s);
    }
  }
  return (host?: string, login?: string) => {
    if (!login) return "";
    const k = hostKey(host) + "\0" + login;
    if (host && pair.has(k)) return pair.get(k)!;
    const s = byLogin.get(login);
    if (s && s.size === 1) return [...s][0];
    return legacy.get(login) || "";
  };
}

export type Lease = { session: string; person: string; host: string; since: string };

// leasesOf are the live sessions on one subscription, newest first.
export function leasesOf(live: LiveSession[], id: string, users: HubUser[]): Lease[] {
  const who = loginOwners(users);
  return live
    .filter((s) => s.account === id)
    .map((s) => ({
      session: (s.worktree || s.cwd || "").split("/").filter(Boolean).pop() || String(s.session_id || "").slice(0, 8),
      person: who(s.hostname, s.os_user) || s.os_user || "—",
      host: hostKey(s.hostname),
      since: s.started_at || s.observed_at || "",
    }))
    .sort((a, b) => toMs(b.since) - toMs(a.since));
}

// ---- who may use a subscription (cred-policy, claude-fleet#3713) ----

export type Target = { scope: "user" | "node"; id: string; label: string; error?: string };
export type Grant = Target & {
  entry?: PolicyEntry;
  allowed: boolean;
  // why: viaAll · viaSelected · notIncluded · revoked · notConfigured · legacy · invalid · unknown
  why: "viaAll" | "viaSelected" | "notIncluded" | "revoked" | "notConfigured" | "legacy" | "invalid" | "unknown";
};

export const entryOf = (view: PolicyView, scope: "user" | "node", id: string) => (view[scope === "node" ? "nodes" : "users"] || []).find((x) => x.id === id);

// userTargets is everyone the policy or the users list knows, by principal.
export function userTargets(view: PolicyView, users: HubUser[], admins: { login: string; github_id?: number }[] = []): Target[] {
  const out = new Map<string, Target>((view.users || []).map((u) => [u.id, { scope: "user", id: u.id, label: u.id }]));
  for (const u of users) {
    const id = u.principal || (u.github_id ? `gh:${u.github_id}` : "");
    if (id) out.set(id, { scope: "user", id, label: u.login || id });
  }
  for (const a of admins) {
    const id = a.github_id ? `gh:${a.github_id}` : "";
    if (id && !out.has(id)) out.set(id, { scope: "user", id, label: a.login || id });
  }
  return [...out.values()];
}

// grantOf says whether one target may use the subscription uuid, and why —
// the old page's verdict, word for word: the hub owns the real one.
export function grantOf(view: PolicyView, t: Target, uuid: string): Grant {
  if (t.error) return { ...t, allowed: false, why: "unknown" };
  const entry = entryOf(view, t.scope, t.id);
  if (!entry) return view.mode === "legacy" ? { ...t, allowed: true, why: "legacy" } : { ...t, allowed: false, why: "notConfigured" };
  if (entry.error) return { ...t, entry, allowed: false, why: "invalid" };
  if (entry.all) return { ...t, entry, allowed: true, why: "viaAll" };
  if (uuid && entry.allow.includes(uuid)) return { ...t, entry, allowed: true, why: "viaSelected" };
  return { ...t, entry, allowed: false, why: entry.allow.length ? "notIncluded" : "revoked" };
}

// togglePayload is the one PUT that lets (on) or stops (off) one target using
// uuid, keeping the rest of its list; null when a switch cannot say it: an
// "all" rule or a legacy grant is changed on the target's own page, where
// the whole list is chosen.
export function togglePayload(g: Grant, uuid: string, on: boolean): { scope: string; id: string; allow: string[] } | null {
  if (g.why === "viaAll" || g.why === "legacy" || g.why === "invalid" || g.why === "unknown") return null;
  const now = g.entry?.allow || [];
  const allow = on ? [...new Set([...now, uuid])].sort() : now.filter((x) => x !== uuid);
  return { scope: g.scope, id: g.id, allow };
}

// fingerprint is a rule as compared before a write (no revision token).
export const fingerprint = (e?: PolicyEntry) => JSON.stringify(e ? { all: !!e.all, allow: [...e.allow].sort(), error: e.error || "" } : null);

export const LABEL_RE = /^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$/;

// addCommand is what to run on a fleet machine to hand the hub a new
// subscription — ONE command (claude-fleet#2084).
export const addCommand = (prov: Prov, label: string) => `~/.claude/fleet/bin/fleet account add --provider ${prov} --label ${label}`;

export type AuditRow = { action: string; provider: string; account: string; at: string; hostname?: string; detail?: string };
// arrived is the credential audit's put that answers an add started at since.
export function arrived(audit: { audit?: AuditRow[] } | null, prov: Prov, label: string, since: number): AuditRow | null {
  const rows = Array.isArray(audit?.audit) ? audit!.audit! : [];
  return rows.find((r) => r.action === "put" && r.provider === prov && norm(r.account) === norm(label) && toMs(r.at) >= since - 1000) || null;
}

// settingOf reads one key of /v1/fleet/settings.
export function settingOf(answer: any, key: string): string {
  const row = (answer?.hub || []).find((h: any) => h.key === key);
  if (row) return String(row.value ?? "");
  const v = answer?.settings?.[key];
  return v == null ? "" : String(v);
}
