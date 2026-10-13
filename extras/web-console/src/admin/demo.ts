// demo.ts — the prototype's hub (EPIC #3923 rule 14): the real reads' shapes
// with made-up people, answering in memory. Only a VITE_DEMO=1 build reaches
// it; a real build drops it (api.ts's DEMO is a build-time constant).
import type { ApiInit, Credential, HubUser, Invite, PersonBudget, PolicyView } from "./api";

const now = Date.now();
const ago = (min: number) => new Date(now - min * 60_000).toISOString();
const ahead = (days: number) => new Date(now + days * 86_400_000).toISOString();
const ZERO = "0001-01-01T00:00:00Z";

const users: HubUser[] = [
  { principal_id: "gh:1001", principal: "gh:1001", github_id: 1001, login: "zhouning", role: "admin", deploy: true, added_by: "deploy", added_at: ago(60 * 24 * 90), last_seen: ago(0.5),
    logins: [{ hostname: "mac-mini", login: "zhouning", state: "active", home: true, kind: "node" }, { hostname: "macbook-air", login: "zhouning", state: "active", kind: "client" }], via: ["wechat", "email", "github"] },
  { principal_id: "p:7c1e", principal: "p:7c1e", github_id: 0, login: "林晓", role: "user", added_by: "invite inv_3fa1", added_at: ago(60 * 24 * 30), last_seen: ago(5),
    logins: [{ hostname: "mac-mini", login: "linxiao", state: "active", home: true, kind: "node" }], via: ["wechat"] },
  { principal_id: "p:9a2d", principal: "p:9a2d", github_id: 0, login: "阿梅", role: "user", added_by: "zhouning (gh:1001)", added_at: ago(60 * 24 * 12), last_seen: ago(62),
    logins: [{ hostname: "mac-studio", login: "amei", state: "active", home: true, kind: "node" }], via: ["email"] },
  { principal_id: "gh:2002", principal: "gh:2002", github_id: 2002, login: "chenyu-dev", role: "user", added_by: "zhouning (gh:1001)", added_at: ago(60 * 24 * 40), last_seen: ago(60 * 26),
    logins: [{ hostname: "linux-01", login: "chenyu", state: "active", home: true, kind: "node" }, { hostname: "mac-studio", login: "chenyu", state: "failed", kind: "node" }], via: ["github"] },
  { principal_id: "gh:3003", principal: "gh:3003", github_id: 3003, login: "test-drill-07", role: "user", added_by: "zhouning (gh:1001)", added_at: ago(60 * 24 * 3), logins: [], via: ["github"] },
];

let invites: Invite[] = [
  { id: "inv_8c2b41", email: "designer@example.com", created_by: "zhouning (gh:1001)", created_at: ago(60 * 20), expires_at: ahead(6), used_at: ZERO, revoked_at: ZERO, state: "active" },
  { id: "inv_3fa1d0", created_by: "zhouning (gh:1001)", created_at: ago(60 * 24 * 30), expires_at: ago(60 * 24 * 23), used_at: ago(60 * 24 * 30), used_by: "p:7c1e", revoked_at: ZERO, state: "used" },
];

const budgets: PersonBudget[] = [
  { principal: "gh:1001", limit_week: 6_000_000, used_week: 2_460_000 },
  { principal: "p:7c1e", limit_week: 6_000_000, used_week: 2_280_000 },
  { principal: "p:9a2d", limit_week: 4_000_000, used_week: 3_680_000 },
  { principal: "gh:2002", limit_week: 6_000_000, used_week: 720_000 },
];

const policy: PolicyView = { mode: "strict", users: [{ id: "p:7c1e", allow: ["5b0e8c1a-1111-4a2b-9c3d-0123456789ab"] }, { id: "gh:1001", allow: [], all: true }] };
const creds: Credential[] = [
  { provider: "claude", account: "pool-max-1", account_uuid: "5b0e8c1a-1111-4a2b-9c3d-0123456789ab", principal_id: "pool" },
  { provider: "claude", account: "pool-max-2", account_uuid: "6c1f9d2b-2222-4b3c-8d4e-123456789abc", principal_id: "pool" },
  { provider: "codex", account: "team-codex", account_uuid: "codex:account:0123456789abcdef0123456789abcdef", principal_id: "pool" },
];
const limits = {
  per_account: [
    { account_uuid: "5b0e8c1a-1111-4a2b-9c3d-0123456789ab", limits: { five_hour: { utilization: 0.31 }, seven_day: { utilization: 0.58 } } },
    { account_uuid: "6c1f9d2b-2222-4b3c-8d4e-123456789abc", limits: { five_hour: { utilization: 0.08 }, seven_day: { utilization: 0.22 } } },
  ],
};

const wait = (ms = 250) => new Promise((r) => setTimeout(r, ms));
const scenario = () => (window as any).__DEMO_SCENARIO || new URLSearchParams(location.search).get("demo") || "";

export async function demoApi(url: string, init: ApiInit = {}): Promise<unknown> {
  await wait(scenario() === "loading" ? 60_000_000 : 250);
  if (scenario() === "error") throw Object.assign(new Error("502 Bad Gateway"), { status: 502 });
  const u = new URL(url, "http://demo.invalid");
  const method = init.method || (init.json !== undefined ? "POST" : "GET");
  const body = (init.json || {}) as Record<string, any>;
  const empty = scenario() === "empty";
  switch (`${method} ${u.pathname}`) {
    case "GET /v1/me":
      return { role: "admin", person: "gh:1001", name: "周宁", login: "zhouning" };
    case "GET /v1/fleet/users":
      return { users: empty ? users.slice(0, 1) : users, admins: [{ login: "zhouning", github_id: 1001, pinned: true, logins: [] }] };
    case "POST /v1/fleet/users": {
      const login = String(body.login || "").toLowerCase();
      const id = 4000 + users.length;
      users.push({ principal_id: `gh:${id}`, principal: `gh:${id}`, github_id: id, login, role: "user", added_by: "zhouning (gh:1001)", added_at: new Date().toISOString(), logins: [], via: ["github"] });
      return { users, admins: [], added: login, github_id: id, created: true };
    }
    case "DELETE /v1/fleet/users": {
      const login = u.searchParams.get("login") || "";
      const i = users.findIndex((x) => x.login === login || x.principal === login);
      if (i < 0) throw Object.assign(new Error("not on the list"), { status: 404 });
      users.splice(i, 1);
      return { users, admins: [], removed: login, devices_revoked: 1 };
    }
    case "POST /v1/fleet/users/sessions":
      return { cut: true, principal: body.login, before: Math.floor(Date.now() / 1000) };
    case "GET /v1/fleet/invites":
      return { invites: empty ? [] : invites };
    case "POST /v1/fleet/invites": {
      const id = "inv_" + Math.random().toString(16).slice(2, 8);
      const inv: Invite = { id, github_login: body.github_login, email: body.email, created_by: "zhouning (gh:1001)", created_at: new Date().toISOString(), expires_at: ahead(7), used_at: ZERO, revoked_at: ZERO, state: "active" };
      invites = [inv, ...invites];
      const code = Math.random().toString(36).slice(2, 14);
      return { ...inv, code, url: `https://fleet.example.cn/i/${code}`, command: `curl -fsSL https://fleet.example.cn/i/${code} | sh` };
    }
    case "DELETE /v1/fleet/invites": {
      const id = u.searchParams.get("id");
      invites = invites.map((x) => (x.id === id ? { ...x, state: "revoked", revoked_at: new Date().toISOString() } : x));
      return { id, state: "revoked" };
    }
    case "GET /v1/fleet/person-usage":
      return { people: empty ? [] : budgets };
    case "GET /v1/nodes":
      return { machines: [{ hostname: "mac-mini", spare: 3, spare_target: 4 }, { hostname: "mac-studio", spare: 2, spare_target: 2 }] };
    case "GET /v1/fleet/cred-policy":
      return policy;
    case "PUT /v1/fleet/cred-policy": {
      const entry = { id: body.id, allow: body.allow || [], all: !!body.all };
      policy.users = [...(policy.users || []).filter((x) => x.id !== body.id), entry];
      return policy;
    }
    case "GET /v1/fleet/credentials":
      return { credentials: creds };
    case "GET /v1/limits":
      return limits;
  }
  throw Object.assign(new Error(`demo: no ${method} ${u.pathname}`), { status: 404 });
}
