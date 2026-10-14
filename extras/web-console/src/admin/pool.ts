// pool.ts — what the subscription pool page computes from the hub's answers,
// with no DOM (EPIC #3923 C12): the old console's join, carried over as it was
// (tokenledger/web/dist/lib/admin.js · subscriptions / poolRows / leaseRows /
// switchRows, lib/cred-policy.js · who may use one), so the new page shows the
// same subscriptions with the same numbers.
import type { Credential, HubUser, PolicyEntry, PolicyView } from "./api";

export type Window = { p: number | null; resets: string | null };
export type PlanSource = "provider" | "legacy" | "admin";

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
  read_status?: string;
  read_attempt_at?: string;
};
export type AccountLimits = { account_uuid: string; label?: string; limits?: LimitsBody };
export type Account = { account_uuid: string; label?: string; display_name?: string; email?: string; source?: string; subscription_type?: string; rate_limit_tier?: string };
export type PoolCredential = Credential & {
  limits?: LimitsBody;
  plan?: string;
  plan_source?: PlanSource;
  plan_at?: string;
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
  credential_id?: string;
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
  planSource?: PlanSource;
  planAt?: string;
  planTier?: string;
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
  readStatus?: string;
  readAttemptAt?: string;
  // a member's own subscription (claude-fleet#4035): its owner's principal; "" = the pool's
  owner: string;
  // from /v1/admin/overview when it answers
  people: string[];
  limited: boolean;
  reauth: boolean;
};

const toMs = (v: unknown) => (typeof v === "number" ? v : Date.parse(String(v || "")));

// pct is a utilization (0–1 or 0–100, the hub has sent both) as 0–100.
export function pct(u: unknown): number | null {
  if (u == null || u === "") return null;
  const n = Number(u);
  if (!Number.isFinite(n) || n < 0) return null;
  return Math.min(100, Math.round(n <= 1 ? n * 100 : n));
}

// windowsOf is a LimitsView's 5-hour and weekly windows, Codex's included.
export function windowsOf(lim?: LimitsBody, percent = false): { h5: Window | null; h7: Window | null } {
  if (!lim || lim.available === false) return { h5: null, h7: null };
  let h5 = lim.five_hour || null;
  let h7 = lim.seven_day || null;
  for (const w of Array.isArray(lim.windows) ? lim.windows : []) {
    const mins = Number(w.minutes) || 0;
    if (!h5 && (mins === 300 || /5h|five|primary/i.test(w.id || w.label || ""))) h5 = w;
    else if (!h7 && (mins === 10080 || /week|seven|secondary/i.test(w.id || w.label || ""))) h7 = w;
  }
  const v = (w: any): Window | null => (w ? { p: percent && w.utilization != null ? Math.min(100, Math.max(0, Number(w.utilization))) : pct(w.utilization), resets: w.resets_at || null } : null);
  return { h5: v(h5), h7: v(h7) };
}

export const provOf = (uuid: string, source?: string): Prov =>
  String(source || "").toLowerCase() === "codex" || String(uuid || "").startsWith("codex:") ? "codex" : "claude";
const credProv = (c: Credential): Prov => (c.provider === "codex" ? "codex" : "claude");
export const isStandIn = (uuid: string) => /^win_/.test(String(uuid || "")) || /:local$/.test(String(uuid || ""));
const credKey = (c: Credential) => `${c.principal_id || "pool"}/${c.provider}/${c.account}`;

// The vault's credential identity is the only metering join. An upstream UUID
// remains optional; labels, e-mail domains and reset schedules are display data.
export function subscriptions(p: {
  limits?: { per_account?: AccountLimits[] } | null;
  accounts?: Account[] | null;
  creds?: { credentials?: PoolCredential[]; paused?: string[] } | null;
  paused?: string[];
  live?: { sessions?: LiveSession[] } | null;
}): Sub[] {
  const per = p.limits?.per_account || [];
  const accounts = new Map((p.accounts || []).map(a => [a.account_uuid, a]));
  const paused = new Set(p.creds?.paused || p.paused || []);
  const seen = new Set<string>();
  const out: Sub[] = [];
  const make = (id: string, label: string, prov: Prov, lim: LimitsBody | undefined, c: PoolCredential | null): Sub => {
    const w = windowsOf(lim, !!c?.credential_id);
    const owner = c && c.principal_id !== "pool" ? c.principal_id || "" : "";
    const meta = c?.account_uuid ? accounts.get(c.account_uuid) : undefined;
    return { id, label, prov, plan: lim?.plan || c?.plan || meta?.subscription_type || "",
      planSource: lim?.plan ? "provider" : c?.plan_source || "legacy",
      planAt: lim?.plan ? lim.observed_at || "" : c?.plan_at || "",
      planTier: meta?.rate_limit_tier || "", h5: w.h5, h7: w.h7,
      available: !!lim && lim.available !== false, reason: lim?.reason || "",
      sessions: (p.live?.sessions || []).filter(s => s.account === id).length,
      cred: c, paused: !!c && !owner && paused.has(c.account), managed: !!c,
      readAt: lim?.observed_at || "", readVia: lim?.read_via || "",
      readNote: lim?.read_note || (lim?.read_status === "unknown" ? "No quota reading yet" : lim?.read_status === "stale" ? "Quota reading is stale" : ""),
      readStatus: lim?.read_status, readAttemptAt: lim?.read_attempt_at,
      owner, people: [], limited: false, reauth: false };
  };
  for (const c of p.creds?.credentials || []) {
    if (c.provider === "github") continue;
    const id = c.credential_id || c.account_uuid || "cred:" + credKey(c);
    // Scope even legacy identities: two owners never borrow each other's row.
    const key = `${c.principal_id}/${c.provider}/${id}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const old = !c.credential_id && c.account_uuid ? per.find(a => a.account_uuid === c.account_uuid) : undefined;
    out.push(make(id, c.account, credProv(c), c.limits || old?.limits, c));
  }
  return out.sort((x,y) => Number(y.managed)-Number(x.managed) || (x.prov === y.prov ? x.label.localeCompare(y.label) : x.prov === "claude" ? -1 : 1));
}

// withOverview lays /v1/admin/overview's pool over the rows, joined by
// (provider, vault account): its own reading of the windows wins (the old
// pool table's numbers), plus the people on it now and its limited / reauth
// state. A hub without it keeps the rows as they were.
export function withOverview(subs: Sub[], pool: OverviewPool[] | null | undefined): Sub[] {
  if (!Array.isArray(pool)) return subs;
  const by = new Map(pool.filter(s => s.provider !== "github").map(s => [s.credential_id || `${s.owner}/${s.provider}/${s.account}`, s]));
  return subs.map((s) => {
    const o = s.cred ? by.get(s.cred.credential_id || credKey(s.cred)) : undefined;
    if (!o) return s;
    const u5 = pct(o.used_5h_pct);
    const u7 = pct(o.used_7d_pct);
    return {
      ...s,
      h5: s.cred?.credential_id || u5 == null ? s.h5 : { p: u5, resets: o.resets_5h_at || s.h5?.resets || null },
      h7: s.cred?.credential_id || u7 == null ? s.h7 : { p: u7, resets: o.resets_at || s.h7?.resets || null },
      sessions: o.sessions ?? s.sessions,
      people: Array.isArray(o.people) ? o.people : [],
      limited: o.state === "limited",
      reauth: o.state === "reauth",
    };
  });
}

export type State = "ok" | "near" | "limited" | "reauth" | "paused" | "unmanaged" | "unread";

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
  if (s.h5?.p == null && s.h7?.p == null) return "unread";
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
  const ws = subs.filter((s) => s.managed && !s.owner && !s.paused && s[which]?.p != null).map((s) => s[which]!);
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

// service: a service principal (svc:<name>) — written as a user scope, shown apart (claude-fleet#4085).
export type Target = { scope: "user" | "node"; id: string; label: string; error?: string; service?: boolean };
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
  // a service's list is a users entry too: it is listed as a service, not a person
  for (const s of view.services || []) out.set(s.id, { scope: "user", id: s.id, label: s.name, service: true });
  for (const [id, x] of out) if (id.startsWith("svc:") && !x.service) out.set(id, { ...x, label: id.slice(4), service: true });
  return [...out.values()];
}

// grantOf says whether one target may use the subscription uuid, and why —
// the old page's verdict, word for word: the hub owns the real one.
export function grantOf(view: PolicyView, t: Target, uuid: string): Grant {
  if (t.error) return { ...t, allowed: false, why: "unknown" };
  const entry = entryOf(view, t.scope, t.id);
  // a service has no legacy grant: with no list it may use nothing, in every mode
  if (!entry) return view.mode === "legacy" && !t.service ? { ...t, allowed: true, why: "legacy" } : { ...t, allowed: false, why: "notConfigured" };
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

// settingOf reads one key of /v1/fleet/settings.
export function settingOf(answer: any, key: string): string {
  const row = (answer?.hub || []).find((h: any) => h.key === key);
  if (row) return String(row.value ?? "");
  const v = answer?.settings?.[key];
  return v == null ? "" : String(v);
}
