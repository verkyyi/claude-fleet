// pool/demo — the 订阅池 prototype's hub (EPIC #3923 C12, rule 14): four
// subscriptions in the vault and one account a node reports that the vault
// does not hold (未纳管), answering the pool page's reads and writes in
// memory. demo.ts asks it first; undefined = not the pool's.
import type { Credential, HubUser, PolicyView } from "./api";

const now = Date.now();
const ago = (min: number) => new Date(now - min * 60_000).toISOString();
const ahead = (days: number) => new Date(now + days * 86_400_000).toISOString();

// The pool (EPIC #3923 C12): four subscriptions in the vault and one account
// a node reports that the vault does not hold (未纳管).
const U = {
  a: "5b0e8c1a-1111-4a2b-9c3d-0123456789ab",
  b: "6c1f9d2b-2222-4b3c-8d4e-123456789abc",
  c: "7d2a0e3c-3333-4c4d-9e5f-23456789abcd",
  x: "codex:account:0123456789abcdef0123456789abcdef",
};
const policy: PolicyView = {
  mode: "strict",
  users: [
    { id: "gh:1001", allow: [], all: true },
    { id: "p:7c1e", allow: [U.a, U.b] },
    { id: "p:9a2d", allow: [U.b] },
    { id: "gh:2002", allow: [U.a, U.x] },
    { id: "svc:livepage", allow: [U.a] },
  ],
  services: [
    { id: "svc:livepage", name: "livepage", enabled: true },
    { id: "svc:digest", name: "digest", enabled: true },
  ],
  nodes: [
    { id: "m:mac-a", allow: [], all: true },
    { id: "m:mac-b", allow: [U.b] },
    { id: "m:linux-a", allow: [U.x, U.a] },
  ],
};
let creds: (Credential & Record<string, unknown>)[] = [
  { provider: "claude", account: "max-a", account_uuid: U.a, principal_id: "pool", created_at: ago(60 * 24 * 60) },
  { provider: "claude", account: "max-b", account_uuid: U.b, principal_id: "pool", created_at: ago(60 * 24 * 41) },
  { provider: "claude", account: "max-c", account_uuid: U.c, principal_id: "pool", created_at: ago(60 * 24 * 9), secret_expires_at: ahead(12) },
  // 林晓's own (C21, claude-fleet#4035): connected from her Usage page, hers alone
  { provider: "claude", account: "my-max", account_uuid: "8e3f0c2a-4444-4d5e-8f60-3456789abcde", principal_id: "p:7c1e", created_at: ago(60 * 24 * 6) },
  { provider: "codex", account: "codex-1", account_uuid: U.x, principal_id: "pool", created_at: ago(60 * 24 * 20) },
];
const paused = new Set<string>(["max-c"]);
const labels: Record<string, string> = {};
const reset = (min: number) => new Date(now + min * 60_000).toISOString();
const usage: Record<string, [number, number, number, number]> = {
  // 5-hour %, its reset in minutes, weekly %, its reset in minutes
  [U.a]: [0.44, 132, 0.31, 60 * 70],
  [U.b]: [0.88, 46, 0.7, 60 * 31],
  [U.c]: [0, 0, 0.12, 60 * 98],
  [U.x]: [0.2, 205, 0.15, 60 * 120],
  win_3f9a20c1: [0.09, 260, 0.04, 60 * 140],
};
const limits = () => ({
  per_account: Object.entries(usage).map(([id, [h5, r5, h7, r7]]) => ({
    account_uuid: id,
    label: labels[id],
    limits: {
      available: true,
      source: id.startsWith("codex:") ? "codex" : "claude",
      plan: id.startsWith("codex:") ? "ChatGPT Pro" : id.startsWith("win_") ? "" : "Claude Max",
      five_hour: { utilization: h5, resets_at: r5 ? reset(r5) : null },
      seven_day: { utilization: h7, resets_at: reset(r7) },
      observed_at: ago(2),
      read_via: id.startsWith("win_") ? "node" : "hub",
    },
  })),
});
const accounts = [
  { account_uuid: U.a, label: "max-a", email: "pool-a@example.cn", source: "claude", subscription_type: "Claude Max" },
  { account_uuid: U.b, label: "max-b", email: "pool-b@example.cn", source: "claude", subscription_type: "Claude Max" },
  { account_uuid: U.c, label: "max-c", email: "pool-c@example.cn", source: "claude", subscription_type: "Claude Max" },
  { account_uuid: U.x, label: "codex-1", source: "codex" },
  { account_uuid: "win_3f9a20c1", label: "linxiao-own", source: "claude" },
];
const live = () => ({
  sessions: [
    ...[0, 1, 2, 3, 4, 5, 6].map((i) => ({ account: U.a, hostname: ["mac-a", "mac-b"][i % 2], os_user: ["zhouning", "chenyu", "linxiao"][i % 3], worktree: `/Users/x/projects/fleet-issue-${3900 + i}`, started_at: ago(5 + i * 17) })),
    ...[0, 1, 2, 3, 4].map((i) => ({ account: U.b, hostname: "mac-b", os_user: i % 2 ? "amei" : "linxiao", worktree: `/Users/x/projects/site-issue-${210 + i}`, started_at: ago(3 + i * 11) })),
    { account: U.x, hostname: "linux-a", os_user: "chenyu", worktree: "/home/chenyu/projects/api-scratch-4", started_at: ago(40) },
    { account: U.x, hostname: "linux-a", os_user: "chenyu", worktree: "/home/chenyu/projects/api-issue-88", started_at: ago(12) },
  ],
});
const switches = [
  { from_account: U.b, to_account: U.a, observed_at: ago(18), endpoint_id: "mac-b" },
  { from_account: U.c, to_account: U.b, observed_at: ago(60 * 5), endpoint_id: "mac-a" },
  { from_account: U.a, to_account: U.x, observed_at: ago(60 * 26), endpoint_id: "linux-a" },
];
const settings: Record<string, string> = { "pool.skip_pct": "85", "pool.move_when_full": "on" };
let activated = false;
const audit: { action: string; provider: string; account: string; at: string; hostname?: string }[] = [];

export function demoPool(method: string, u: URL, body: Record<string, any>, empty: boolean, scenario: string, users: HubUser[]): unknown | undefined {
  const p = u.pathname;
  const loginNames = (ss: { hostname: string; os_user: string }[]) => {
    const out = new Set<string>();
    for (const s of ss) {
      const who = users.find((x) => x.logins.some((l) => l.hostname === s.hostname && l.login === s.os_user)) || users.find((x) => x.logins.some((l) => l.login === s.os_user));
      out.add(who ? who.login : s.os_user);
    }
    return [...out];
  };
  if (method === "GET" && p === "/v1/fleet/cred-policy" && !u.searchParams.get("endpoint_id")) {
    // the 旧规则 scenario: legacy mode with its one-time migration review
    if (scenario === "legacy" && !activated)
      return {
        ...policy,
        mode: "legacy",
        migration: {
          revision: 7,
          objects: [
            { key: "user:gh:3003", scope: "user", id: "gh:3003", label: "test-drill-07" },
            { key: "node:m:linux-b", scope: "node", id: "m:linux-b", label: "linux-b" },
          ],
        },
      };
    return policy;
  }
  if (method === "PUT" && p === "/v1/fleet/cred-policy") {
    if (body.action === "activate") {
      activated = true;
      return policy;
    }
    const list = body.scope === "node" ? (policy.nodes ||= []) : (policy.users ||= []);
    const entry = { id: body.id, allow: body.allow || [], all: !!body.all };
    const i = list.findIndex((x) => x.id === body.id);
    if (i < 0) list.push(entry);
    else list[i] = entry;
    return policy;
  }
  if (method === "GET" && p === "/v1/fleet/credentials") return { credentials: empty ? [] : creds, paused: [...paused] };
  if (method === "POST" && p === "/v1/fleet/credentials") {
    creds = creds.filter((c) => !(c.provider === body.provider && c.account === body.account));
    return { deleted: true };
  }
  if (method === "GET" && p === "/v1/fleet/credentials/audit") {
    // the prototype's node "arrives" a few seconds after the add starts
    const pending = (window as any).__DEMO_ADD as { prov: string; label: string; at: number } | undefined;
    if (pending && Date.now() - pending.at > 4000) {
      audit.unshift({ action: "put", provider: pending.prov, account: pending.label, at: new Date().toISOString(), hostname: "mac-a" });
      creds.push({ provider: pending.prov, account: pending.label, principal_id: "pool", created_at: new Date().toISOString() });
      (window as any).__DEMO_ADD = undefined;
    }
    return { audit };
  }
  if (method === "GET" && p === "/v1/limits") return empty ? { per_account: [] } : limits();
  if (method === "GET" && p === "/v1/accounts") return empty ? [] : accounts;
  if (method === "POST" && p === "/v1/accounts/label") {
    labels[body.account] = body.label;
    return { account: body.account, label: body.label, locked: !!body.label };
  }
  if (method === "GET" && p === "/v1/live") return empty ? { sessions: [] } : live();
  if (method === "GET" && p === "/v1/account-switches") return switches;
  if (method === "PUT" && p === "/v1/fleet/settings" && String(body.key || "").startsWith("pool.")) {
    const key = String(body.key);
    if (key.startsWith("pool.paused.")) {
      const a = key.slice("pool.paused.".length);
      if (body.value) paused.add(a);
      else paused.delete(a);
    } else settings[key] = String(body.value);
    return { key, value: body.value };
  }
  if (method === "GET" && p === "/v1/admin/overview")
    return {
      pool: (empty ? [] : creds).map((c) => {
        const [h5, , h7] = usage[String(c.account_uuid)] || [];
        const ss = live().sessions.filter((s) => s.account === c.account_uuid);
        return { owner: "pool", provider: c.provider, account: c.account, used_5h_pct: h5 ?? null, used_7d_pct: h7 ?? null, people: loginNames(ss), sessions: ss.length, state: "ok" };
      }),
    };
  return undefined;
}

// poolSettings are the pool's rows of GET /v1/fleet/settings (demo.ts adds them to the rest).
export const poolSettings = () =>
  Object.entries(settings)
    .map(([key, value]) => ({ key, value }))
    .concat([...paused].map((a) => ({ key: `pool.paused.${a}`, value: "on" })));
