// demo.ts — the prototype's hub (EPIC #3923 rule 14): the real reads' shapes
// with made-up people, answering in memory. Only a VITE_DEMO=1 build reaches
// it; a real build drops it (api.ts's DEMO is a build-time constant).
import type { ApiInit, Credential, FleetSessions, HubUser, Invite, MeUsage, MeUsageLimit, Overview, PersonBudget, PolicyView, ReleaseKeys, ReleaseStats, TeamUsage, TrainRun } from "./api";
import { demoMachines } from "./machines/demo";
import { demoPool, poolSettings } from "./poolDemo";

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

// 发布 (C14): a week of release trains, built from the stages the ledger keeps
const hex = (n: number) => Array.from({ length: 40 }, (_, i) => "0123456789abcdef"[(n * 7 + i * 13 + ((n * i) % 11)) % 16]).join("");
const SUBJECTS = [
  "管理侧的骨架，和成员与开号（#3933）", "doc-preview 不再随会话回收而死（#3988）", "个人 pod 的路由表给门的 entry 路由（#3985）",
  "登录后的骨架，对话做首页（#3926）", "删号时 account forget 等不到就停掉该登录的任务（#3379）", "列车在深圳集群里跑 Linux 半边（#3864）",
  "sidebar：远端会话行同一种样式（#3960）", "fleet-theme：一份颜色字体三处共用（#3924）", "hub：新地址和管理页守门（#3925）",
  "bash32：空数组展开再收一处（#703）", "doctor：channel 行说清 Mac 线落后几趟（#3868）", "webchat：预算 403 一行说清（#3643）",
];
type Shape = { ago: number; merges: number; lin: number; hub: number; rel: number; queue?: number; end?: "failure" | "cancelled" | "superseded"; macAfter?: number; why?: string; stage?: string };
const SHAPES: Shape[] = [
  { ago: 38, merges: 2, lin: 148, hub: 61, rel: 22, queue: 9, macAfter: 1260 },
  { ago: 95, merges: 1, lin: 139, hub: 0, rel: 19, macAfter: 1310 },
  { ago: 160, merges: 3, lin: 236, hub: 74, rel: 25, queue: 41, macAfter: 1180, stage: "Linux", why: "等 fleet-ack 的空位 41 秒，第 7 片 2 分 30 秒" },
  { ago: 300, merges: 1, lin: 151, hub: 58, rel: 0, end: "failure", stage: "Linux", why: "shard 4/14：fleet-pr-merge-selftest 红" },
  { ago: 330, merges: 2, lin: 144, hub: 63, rel: 21, macAfter: 1240 },
  { ago: 60 * 10, merges: 4, lin: 142, hub: 66, rel: 20, end: "superseded" },
  { ago: 60 * 26, merges: 1, lin: 137, hub: 0, rel: 18, macAfter: 1400 },
  { ago: 60 * 30, merges: 2, lin: 161, hub: 152, rel: 23, macAfter: 1290, stage: "hub", why: "入口镜像推送 2 分 32 秒（层缓存没命中）" },
  { ago: 60 * 49, merges: 1, lin: 140, hub: 60, rel: 19, macAfter: 1205 },
  { ago: 60 * 75, merges: 3, lin: 0, hub: 0, rel: 0, end: "cancelled", why: "红灯即停：board 之后 master 又红了" },
  { ago: 60 * 98, merges: 2, lin: 146, hub: 64, rel: 21, macAfter: 1330 },
  { ago: 60 * 122, merges: 1, lin: 138, hub: 0, rel: 20, macAfter: 1260 },
  { ago: 60 * 147, merges: 2, lin: 150, hub: 59, rel: 22, macAfter: 1190 },
];
let subj = 0;
const runs: TrainRun[] = SHAPES.map((x, i) => {
  const board = 14;
  const plan = { name: "hub plan", offset_secs: board, secs: 11, budget_secs: 30, result: "success" };
  const stages = [
    { name: "board", offset_secs: 0, secs: board, budget_secs: 20, result: "success" },
    { ...plan, offset_secs: board },
    { name: "Linux", offset_secs: board + 4, secs: x.lin, budget_secs: 150, queue_secs: x.queue, result: x.end === "failure" ? "failure" : x.lin ? "success" : "" },
    { name: "hub", offset_secs: board + 4 + x.lin, secs: x.hub, budget_secs: 90, result: x.hub ? "success" : "skipped" },
    { name: "release", offset_secs: board + 4 + x.lin + x.hub, secs: x.rel, budget_secs: 30, result: x.rel ? "success" : "" },
    { name: "红灯即停", offset_secs: 0, secs: board + 4 + x.lin + x.hub + x.rel, budget_secs: 0, result: "success" },
  ];
  if (x.macAfter) stages.push({ name: "mac follow", offset_secs: board + 4 + x.lin + x.hub + x.rel + 20, secs: x.macAfter, budget_secs: 0, result: "success", off_path: true } as any);
  const total = x.end === "cancelled" ? 31 : board + 4 + x.lin + x.hub + x.rel + 3;
  const start = new Date(now - x.ago * 60_000);
  const merges = Array.from({ length: x.merges }, (_, k) => ({ sha: hex(i * 10 + k + 1), merged_at: new Date(start.getTime() - (k + 1) * 240_000).toISOString(), subject: SUBJECTS[subj++ % SUBJECTS.length] }));
  return {
    run_id: String(18_840_000_000 + 7_431_207 - i * 211_337),
    run_url: `https://github.com/verkyyi/claude-fleet/actions/runs/${18_840_000_000 + 7_431_207 - i * 211_337}`,
    sha: hex(i * 10 + 1),
    conclusion: x.end || "success",
    started_at: start.toISOString(),
    ended_at: new Date(start.getTime() + total * 1000).toISOString(),
    total_secs: total,
    merges,
    stages: stages.filter((st) => st.secs > 0 || st.name === "hub"),
    bottleneck: x.why ? { stage: x.stage || "", secs: x.stage === "hub" ? x.hub : x.stage === "Linux" ? x.lin : 0, why: x.why } : null,
    ...(x.macAfter ? { mac: { conclusion: "success", secs: x.macAfter, after_secs: x.macAfter + 20 } } : {}),
  };
});
const shipped = runs.filter((r) => r.conclusion === "success" || r.conclusion === "superseded");
const stats = (empty: boolean): ReleaseStats => ({
  days: 7,
  merge_to_stable_n: empty ? 0 : 25,
  merge_to_stable_p50: empty ? null : 468,
  merge_to_stable_p95: empty ? null : 1104,
  runs_started: empty ? 0 : runs.length,
  runs_shipped: empty ? 0 : shipped.length,
  run_p50_secs: empty ? null : 241,
  runs_slow: empty ? 0 : runs.filter((r) => r.conclusion === "failure" || r.conclusion === "cancelled" || r.total_secs > 300).length,
  runs_slow_said: empty ? 0 : runs.filter((r) => (r.conclusion === "failure" || r.conclusion === "cancelled" || r.total_secs > 300) && r.bottleneck).length,
  lanes: { stable: runs[0].sha, stable_macos: runs[2].sha },
  runs: empty ? [] : runs,
});
// key ids are hex fingerprints (release.KeyID); made here, never written as literals
const [ROOT_ID, SIGN_ID, NEXT_ID] = [101, 202, 303].map((n) => hex(n).slice(0, 16));
const keys = (bad: boolean): ReleaseKeys => ({
  repo: "verkyyi/claude-fleet",
  signer: "train",
  anchor: ROOT_ID,
  root: true,
  stable: runs[0].sha,
  stable_key: SIGN_ID,
  stable_key_trusted: !bad,
  stable_key_revoked: bad,
  trusted: [
    { id: ROOT_ID, role: "root" },
    { id: SIGN_ID, role: "sign", by: ROOT_ID },
    { id: NEXT_ID, role: "sign", by: ROOT_ID },
  ],
  revoked: bad ? 2 : 1,
  revoked_version: bad ? 3 : 2,
  overlap: false,
});
// 全队用量 (C13): each person as their own /v1/me/usage says them.
const resetIn = (h: number) => new Date(now + h * 3_600_000).toISOString();
const lim = (week?: number, used = 0, h5?: number, used5 = 0): MeUsageLimit =>
  week || h5
    ? { set: true, limit_week: week, used_week: used, remaining_week: week ? Math.max(0, week - used) : undefined, reset_week: week ? resetIn(31) : undefined,
        limit_5h: h5, used_5h: used5, remaining_5h: h5 ? Math.max(0, h5 - used5) : undefined, reset_5h: h5 ? resetIn(2) : undefined,
        over: (!!week && used >= week) || (!!h5 && used5 >= h5), window: h5 && used5 >= h5 ? "5h" : week && used >= week ? "week" : undefined }
    : { set: false, used_week: used, used_5h: used5 };
// built on first use only: a top-level call would ride into the real build
let usageDemoMemo: ReturnType<typeof makeUsageDemo> | null = null;
const usageDemo = () => (usageDemoMemo ||= makeUsageDemo());
function makeUsageDemo() {
const teamUsage: TeamUsage = {
  people: [
    { principal: "p:9a2d", name: "阿梅", today: 612_400, week: 3_684_200, limit: lim(4_000_000, 3_680_000) },
    { principal: "gh:1001", name: "周宁", today: 418_900, week: 2_461_700, limit: lim(6_000_000, 2_460_000) },
    { principal: "p:7c1e", name: "林晓", today: 233_100, week: 2_279_400, limit: lim(6_000_000, 2_280_000, 900_000, 412_000) },
    { principal: "gh:2002", name: "chenyu-dev", today: 0, week: 721_300, limit: lim(6_000_000, 720_000) },
    { principal: "gh:3003", name: "test-drill-07", today: 0, week: 0, limit: lim() },
  ],
  models: [
    { name: "Opus 5.5", provider: "claude", tokens: 5_902_300 },
    { name: "Sonnet 5.5", provider: "claude", tokens: 2_081_400 },
    { name: "GPT-5.4 Codex", provider: "codex", tokens: 802_700 },
    { name: "Haiku 5.5", provider: "claude", tokens: 360_200 },
  ],
  machines: [
    { node: "mac-mini", today: 652_000, week: 4_741_100, people: 2 },
    { node: "mac-studio", today: 612_400, week: 3_684_200, people: 1 },
    { node: "linux-01", today: 0, week: 721_300, people: 1 },
  ],
};
const overview: Overview = {
  people: [
    { principal: "p:9a2d", name: "阿梅", today: 612_400, week: 3_684_200, doing: { repo: "acme/shop-web", issue: 418, tokens: 2_100_000 }, sessions: 3, running: 2, logins: [["mac-studio", "amei"]], subs: ["pool-max-1"] },
    { principal: "gh:1001", name: "周宁", today: 418_900, week: 2_461_700, doing: { repo: "verkyyi/claude-fleet", issue: 3923, tokens: 1_400_000 }, sessions: 2, running: 1, logins: [["mac-mini", "zhouning"]], subs: ["pool-max-1", "pool-max-2"] },
    { principal: "p:7c1e", name: "林晓", today: 233_100, week: 2_279_400, doing: { repo: "acme/data-pipe", tokens: 900_000 }, sessions: 2, running: 1, logins: [["mac-mini", "linxiao"]], subs: ["pool-max-2"] },
    { principal: "gh:2002", name: "chenyu-dev", today: 0, week: 721_300, doing: { repo: "acme/infra", issue: 77, tokens: 600_000 }, sessions: 1, running: 0, logins: [["linux-01", "chenyu"]], subs: [] },
  ],
  pool: [{ account: "pool-max-1", label: "Max · 团队 1" }, { account: "pool-max-2", label: "Max · 团队 2" }, { account: "team-codex", label: "Codex · 团队" }],
  nodes: [{ machine_name: "mac-mini", availability: "online" }, { machine_name: "mac-studio", availability: "online" }, { machine_name: "linux-01", availability: "maintenance" }],
  totals: { tokens: 9_146_600, tokens_today: 1_264_400, sessions: 8, running: 4, machines: 3, machines_online: 2 },
};
const born = (min: number) => Math.floor((now - min * 60_000) / 1000);
const sessions: FleetSessions = {
  sessions: [
    { machine_name: "mac-studio", os_user: "amei", availability: "online", tokens_today: 288_000, worker: { worker_id: "w-1", key: "issue-418", repo: "acme/shop-web", title: "结算页在手机上横着滚", state: "working", agent: "claude", worktree: "/Users/amei/projects/shop-web-issue-418", born: born(95) } },
    { machine_name: "mac-studio", os_user: "amei", availability: "online", tokens_today: 201_500, worker: { worker_id: "w-2", key: "issue-421", repo: "acme/shop-web", title: "优惠券叠加规则", state: "waiting", needs: "perm", status_kind: "permission", status_msg: "要运行 npm run migrate:prod，允许吗？", agent: "claude", worktree: "/Users/amei/projects/shop-web-issue-421", born: born(52) } },
    { machine_name: "mac-studio", os_user: "amei", availability: "online", tokens_today: 122_900, worker: { worker_id: "w-3", key: "scratch-4", repo: "", title: "", state: "idle", agent: "claude", born: born(60 * 5) } },
    { machine_name: "mac-mini", os_user: "zhouning", availability: "online", tokens_today: 301_200, worker: { worker_id: "w-4", key: "issue-3936", repo: "verkyyi/claude-fleet", title: "全队用量和全部会话", state: "working", agent: "claude", worktree: "/Users/zhouning/projects/claude-fleet-issue-3936", born: born(40) } },
    { machine_name: "mac-mini", os_user: "zhouning", availability: "online", tokens_today: 117_700, worker: { worker_id: "w-5", key: "scratch-30", repo: "", title: "", state: "done", agent: "claude", born: born(60 * 3) } },
    { machine_name: "mac-mini", os_user: "linxiao", availability: "online", tokens_today: 233_100, worker: { worker_id: "w-6", key: "issue-52", repo: "acme/data-pipe", title: "夜间导入偶尔重复一行", state: "blocked", needs: "ask", status_kind: "question", status_msg: "重复行要删掉还是只做标记？", agent: "codex", worktree: "/Users/linxiao/projects/data-pipe-issue-52", born: born(130) } },
    { machine_name: "mac-mini", os_user: "linxiao", availability: "online", worker: { worker_id: "w-7", key: "scratch-9", state: "idle", agent: "claude", born: born(60 * 26) } },
    { machine_name: "linux-01", os_user: "chenyu", availability: "maintenance", worker: { worker_id: "w-8", key: "issue-77", repo: "acme/infra", title: "证书续期改成自动", state: "idle", agent: "claude", worktree: "/home/chenyu/projects/infra-issue-77", born: born(60 * 30) } },
  ],
  nodes: overview.nodes,
};
const personUsage = (p: string): MeUsage => {
  const u = teamUsage.people.find((x) => x.principal === p)!;
  const share = u.week / 9_146_600;
  return {
    range: "7d", today: u.today, week: u.week, total: u.week, limit: u.limit,
    models: teamUsage.models.map((m) => ({ ...m, tokens: Math.round(m.tokens * share) })).filter((m) => m.tokens > 0),
    by_session: sessions.sessions.filter((s) => overview.people.find((o) => o.principal === p)?.logins.some(([h, l]) => h === s.machine_name && l === s.os_user))
      .map((s, i, a) => ({ key: s.worker.key, worker_id: s.worker.worker_id, today: s.tokens_today || 0, week: Math.round(u.week * (a.length - i) / ((a.length * (a.length + 1)) / 2) * 0.9) }))
      .concat(u.week ? [{ kind: "none", today: 0, week: Math.round(u.week * 0.1) } as any] : []),
  };
};
  return { teamUsage, overview, sessions, personUsage };
}

const usageOverview = (empty: boolean) => {
  const { overview } = usageDemo();
  return empty ? { ...overview, people: [], totals: { ...overview.totals, running: 0, sessions: 0 } } : overview;
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
  const pool = demoPool(method, u, body, empty, scenario(), users); // 订阅池 (C12)
  // /v1/admin/overview is both pages' read: 订阅池 lays its pool rows over 全队用量's people (C13)
  if (pool !== undefined && method === "GET" && u.pathname === "/v1/admin/overview")
    return { ...(usageOverview(empty) as object), pool: (pool as { pool: unknown[] }).pool };
  if (pool !== undefined) return pool;
  const machines = demoMachines(method, u, body, empty, init); // 机器与 pod (C11)
  if (method === "GET" && u.pathname === "/v1/fleet/settings") return { hub: [...((machines as any)?.hub || []), ...poolSettings()] };
  if (machines !== undefined) return machines;
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
    case "GET /v1/fleet/release/stats":
      return stats(empty);
    case "GET /version":
      return {
        version: `prod-${runs[0].sha.slice(0, 7)}`, commit: runs[0].sha.slice(0, 7), stable: runs[0].sha, client_version: runs[0].sha,
        ...(empty ? {} : { client_version_macos: runs[2].sha, stable_macos_behind: 2, stable_macos_behind_since: runs[1].started_at }),
      };
    case "GET /v1/fleet/release/keys":
      if (scenario() === "keys_off") throw Object.assign(new Error("404 Not Found"), { status: 404 });
      return keys(scenario() === "keys_bad");
    case "GET /v1/admin/usage": {
      const { teamUsage, personUsage } = usageDemo();
      const p = u.searchParams.get("principal");
      if (p) return personUsage(p);
      return empty ? { people: [], models: [], machines: [] } : teamUsage;
    }
    case "GET /v1/admin/overview":
      return usageOverview(empty);
    case "GET /v1/admin/sessions": {
      const { overview, sessions } = usageDemo();
      return empty ? { sessions: [], nodes: overview.nodes } : sessions;
    }
  }
  throw Object.assign(new Error(`demo: no ${method} ${u.pathname}`), { status: 404 });
}
