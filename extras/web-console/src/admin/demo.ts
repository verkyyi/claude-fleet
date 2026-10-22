// demo.ts — the prototype's hub (EPIC #3923 rule 14): the real reads' shapes
// with made-up people, answering in memory. Only a VITE_DEMO=1 build reaches
// it; a real build drops it (api.ts's DEMO is a build-time constant).
import type { AccessRequest, ApiInit, Credential, FleetSessions, HubUser, Invite, MeUsage, MeUsageLimit, NoticeMember, Overview, PersonBudget, PolicyView, ReleaseKeys, ReleaseStats, RequestDetail, ServiceNotice, TeamUsage, TrainRun, TrialCode, TrialCodeDetail, TrialFunnel, TrialSpend, TrialSpendPerson } from "./api";
import { demoMachines } from "./machines/demo";
import { demoPool, poolSettings } from "./poolDemo";
import { entryDemo } from "./demo-entry";

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
  "管理侧的骨架，和成员与开号（#3933）", "会话回收不再带走它起的服务（#3988）", "个人 pod 的路由表给门的 entry 路由（#3985）",
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
// 试用用量 (WACK C6): the design page's people — 14 in their trial, 6 new, every
// token on their own subscriptions, one past the per-person line.
function trialSpendDemo(day: string, empty: boolean): TrialSpend {
  const yesterday = new Date(now + 8 * 3_600_000 - 86_400_000).toISOString().slice(0, 10);
  const line = { person_day: 1_000_000, all_day: 30_000_000, daily: true };
  const base = { day: day || yesterday, line, machines: [{ node: "macmini", load_pct: 52 }, { node: "mini2", load_pct: 61 }] };
  if (empty) return { ...base, new: 0, active: 0, tokens: 0, pool: 0, byo: 0, by_source: { subscription: 0, api: 0, byo: 0 }, over: 0, all_over: false, people: [] };
  const names = ["小林", "阿杰", "Mia", "王小雨", "kevin.z", "陈默", "Lucy", "周周", "老高", "sam", "李想", "Nora", "小鹿", "Tom"];
  const tokens = [1_420_000, 960_000, 940_000, 910_000, 880_000, 850_000, 820_000, 790_000, 760_000, 730_000, 700_000, 680_000, 650_000, 610_000];
  const people: TrialSpendPerson[] = names.map((name, i) => ({
    principal: `wx:demo${i + 1}`,
    name,
    kind: i % 4 === 2 ? "email" : "wechat",
    trial_day: i < 6 ? 1 : (i % 6) + 2,
    tokens: tokens[i],
    pool: 0,
    byo: tokens[i],
    new: i < 6,
    active: true,
    over: tokens[i] > line.person_day,
  }));
  const total = tokens.reduce((a, n) => a + n, 0);
  return { ...base, new: 6, active: 14, tokens: total, pool: 0, byo: total, by_source: { subscription: 0, api: 0, byo: total }, over: people.filter((p) => p.over).length, all_over: false,
    people: people.sort((a, b) => Number(b.over) - Number(a.over) || b.tokens - a.tokens) };
}

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

// 申请 (claude-fleet#4052): the prototype's six requests
const rq = (id: string, kind: string, subject: string, display: string, mins: number, x: Partial<AccessRequest> = {}): AccessRequest => ({
  id, kind, subject, display, use: "", team: "", referrer: "", notify_channel: kind.startsWith("wechat") ? "wechat" : "email", notify_addr: "",
  state: "pending", reason: "", cooldown_until: ZERO, decided_by: "", created_at: ago(mins), decided_at: ZERO, trial: false, ...x,
});
let requests: AccessRequest[] = [
  rq("rq-r1", "wechat", "oU7Q", "林小满", 120, { use: "给 5 个人的运营小组做每周销售看板，现在每周一手工拼 Excel 要半天。", team: "杭州一家电商公司 · 运营", trial: true, person: "p:51aa" }),
  rq("rq-r2", "github", "93817402", "zhouyu-dev", 300, { use: "想让会话帮我维护两个开源小工具的 issue 和文档，晚上睡觉时它接着跑。", team: "独立开发者", notify_addr: "zhouyu@example.com" }),
  rq("rq-r3", "email", "chen.ran@qq.com", "chen.ran@qq.com", 60 * 26, { use: "试试看能不能帮我整理论文的参考文献。", notify_addr: "chen.ran@qq.com" }),
  rq("rq-r4", "wechat", "oK2m", "何以宁", 60 * 48, { use: "做活动落地页和每周的投放周报；同组的林思远在用，推荐我来。", team: "24好玩 · 市场部", referrer: "林思远（成员）" }),
  rq("rq-r5", "github", "5521", "tomlee", 60 * 30, { use: "Evaluate it for a 3-person design team.", team: "Acme Studio", state: "approved", decided_by: "gh:1001", decided_at: ago(60 * 27) }),
  rq("rq-r6", "wechat", "oZ9c", "阿杰", 60 * 24 * 5, { use: "看看这个东西到底能干什么用。", state: "rejected", reason: "用途写得还不够具体，可以补充你打算用它做什么后再申请。", cooldown_until: ahead(25), decided_by: "gh:1001", decided_at: ago(60 * 24 * 4) }),
];
const requestDetail = (r: AccessRequest): RequestDetail => ({
  ...r,
  signins: { count: r.trial ? 3 : 1, first: new Date(Date.parse(r.created_at) - 2 * 60_000).toISOString(), last: r.created_at },
  ...(r.trial ? { trial_of: { state: "reclaimed", started_at: new Date(Date.parse(r.created_at) + 2 * 60_000).toISOString(), minutes: 15, messages: 14, ended: "reclaimed" }, convo_until: ahead(1) } : {}),
  earlier: [],
});

// 发通知 (claude-fleet#4063): the members a notice can reach, and two sent
const noticeMembers: NoticeMember[] = [
  { principal_id: "gh:1001", login: "zhouning", role: "admin", reach: "wechat" },
  { principal_id: "p:51aa", login: "林小满", role: "user", reach: "wechat" },
  { principal_id: "gh:93817402", login: "zhouyu-dev", role: "user", reach: "email" },
  { principal_id: "p:7c02", login: "何以宁", role: "user", reach: "wechat" },
  { principal_id: "gh:5521", login: "tomlee", role: "user", reach: "none" },
];
let notices: ServiceNotice[] = [
  { id: "nc-2", body: "本周六 14:00 起维护 30 分钟，期间会话暂停，结束后自动恢复。", link: "", audience: "all",
    recipients: noticeMembers.map((m) => m.principal_id), created_by: "gh:1001", created_at: ago(90),
    delivery: { pending: 0, sent: 4, undelivered: 1, via: { "wechat-tpl": 3, email: 1 } } },
  { id: "nc-1", body: "每人每天的用量上限从下周一起调整为 8 小时。", link: "", audience: "some",
    recipients: ["p:51aa", "gh:93817402"], created_by: "gh:1001", created_at: ago(60 * 24 * 6),
    delivery: { pending: 0, sent: 2, undelivered: 0, via: { "wechat-tpl": 1, email: 1 } } },
];

// 试用二维码 (claude-fleet MRGB): four codes, their funnels and people
// a code's picture: one made-up QR pattern (the hub draws the real one, qr.png)
const QR_DEMO = "data:image/svg+xml;utf8,%3Csvg%20xmlns%3D%22http%3A//www.w3.org/2000/svg%22%20viewBox%3D%22-1%20-1%2023%2023%22%20shape-rendering%3D%22crispEdges%22%3E%3Crect%20x%3D%22-1%22%20y%3D%22-1%22%20width%3D%2223%22%20height%3D%2223%22%20fill%3D%22%23fff%22/%3E%3Cg%20fill%3D%22%231d1b26%22%3E%3Crect%20x%3D%228%22%20y%3D%220%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%229%22%20y%3D%220%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2211%22%20y%3D%220%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%228%22%20y%3D%221%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%229%22%20y%3D%221%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2211%22%20y%3D%221%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2212%22%20y%3D%221%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%228%22%20y%3D%222%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%229%22%20y%3D%222%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2210%22%20y%3D%222%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2212%22%20y%3D%222%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%228%22%20y%3D%223%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2212%22%20y%3D%223%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%229%22%20y%3D%224%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2211%22%20y%3D%224%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2212%22%20y%3D%224%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%228%22%20y%3D%225%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%229%22%20y%3D%225%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2211%22%20y%3D%225%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%229%22%20y%3D%226%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2211%22%20y%3D%226%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2212%22%20y%3D%226%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%228%22%20y%3D%227%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2210%22%20y%3D%227%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2211%22%20y%3D%227%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%220%22%20y%3D%228%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%221%22%20y%3D%228%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%224%22%20y%3D%228%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%229%22%20y%3D%228%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2211%22%20y%3D%228%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2212%22%20y%3D%228%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2214%22%20y%3D%228%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2215%22%20y%3D%228%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2216%22%20y%3D%228%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%220%22%20y%3D%229%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%224%22%20y%3D%229%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%227%22%20y%3D%229%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%229%22%20y%3D%229%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2214%22%20y%3D%229%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2215%22%20y%3D%229%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2217%22%20y%3D%229%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2218%22%20y%3D%229%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2219%22%20y%3D%229%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2220%22%20y%3D%229%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%220%22%20y%3D%2210%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%222%22%20y%3D%2210%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%223%22%20y%3D%2210%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%224%22%20y%3D%2210%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%226%22%20y%3D%2210%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%227%22%20y%3D%2210%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2212%22%20y%3D%2210%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2213%22%20y%3D%2210%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2214%22%20y%3D%2210%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2217%22%20y%3D%2210%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2218%22%20y%3D%2210%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2219%22%20y%3D%2210%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2220%22%20y%3D%2210%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%220%22%20y%3D%2211%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%222%22%20y%3D%2211%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%223%22%20y%3D%2211%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%224%22%20y%3D%2211%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%225%22%20y%3D%2211%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2212%22%20y%3D%2211%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2217%22%20y%3D%2211%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2218%22%20y%3D%2211%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2219%22%20y%3D%2211%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%220%22%20y%3D%2212%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%221%22%20y%3D%2212%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%222%22%20y%3D%2212%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%223%22%20y%3D%2212%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%224%22%20y%3D%2212%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%225%22%20y%3D%2212%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%226%22%20y%3D%2212%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%227%22%20y%3D%2212%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%228%22%20y%3D%2212%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%229%22%20y%3D%2212%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2210%22%20y%3D%2212%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2213%22%20y%3D%2212%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2214%22%20y%3D%2212%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2215%22%20y%3D%2212%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2216%22%20y%3D%2212%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2217%22%20y%3D%2212%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2220%22%20y%3D%2212%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%228%22%20y%3D%2213%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%229%22%20y%3D%2213%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2210%22%20y%3D%2213%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2211%22%20y%3D%2213%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2212%22%20y%3D%2213%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2214%22%20y%3D%2213%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2215%22%20y%3D%2213%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2218%22%20y%3D%2213%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2220%22%20y%3D%2213%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2212%22%20y%3D%2214%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2213%22%20y%3D%2214%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2214%22%20y%3D%2214%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2218%22%20y%3D%2214%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2219%22%20y%3D%2214%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2213%22%20y%3D%2215%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2215%22%20y%3D%2215%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2216%22%20y%3D%2215%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2217%22%20y%3D%2215%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2218%22%20y%3D%2215%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2219%22%20y%3D%2215%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%229%22%20y%3D%2216%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2213%22%20y%3D%2216%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2214%22%20y%3D%2216%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2215%22%20y%3D%2216%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2216%22%20y%3D%2216%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2217%22%20y%3D%2216%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%228%22%20y%3D%2217%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2211%22%20y%3D%2217%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2216%22%20y%3D%2217%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2217%22%20y%3D%2217%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2219%22%20y%3D%2217%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%229%22%20y%3D%2218%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2210%22%20y%3D%2218%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2213%22%20y%3D%2218%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2214%22%20y%3D%2218%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2215%22%20y%3D%2218%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2218%22%20y%3D%2218%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%229%22%20y%3D%2219%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2211%22%20y%3D%2219%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2212%22%20y%3D%2219%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2217%22%20y%3D%2219%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2220%22%20y%3D%2219%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%228%22%20y%3D%2220%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%229%22%20y%3D%2220%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2210%22%20y%3D%2220%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2212%22%20y%3D%2220%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2213%22%20y%3D%2220%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2214%22%20y%3D%2220%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2216%22%20y%3D%2220%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2217%22%20y%3D%2220%22%20width%3D%221%22%20height%3D%221%22/%3E%3Crect%20x%3D%2220%22%20y%3D%2220%22%20width%3D%221%22%20height%3D%221%22/%3E%3C/g%3E%3Crect%20x%3D%220%22%20y%3D%220%22%20width%3D%227%22%20height%3D%227%22%20fill%3D%22%231d1b26%22/%3E%3Crect%20x%3D%221%22%20y%3D%221%22%20width%3D%225%22%20height%3D%225%22%20fill%3D%22%23fff%22/%3E%3Crect%20x%3D%222%22%20y%3D%222%22%20width%3D%223%22%20height%3D%223%22%20fill%3D%22%231d1b26%22/%3E%3Crect%20x%3D%2214%22%20y%3D%220%22%20width%3D%227%22%20height%3D%227%22%20fill%3D%22%231d1b26%22/%3E%3Crect%20x%3D%2215%22%20y%3D%221%22%20width%3D%225%22%20height%3D%225%22%20fill%3D%22%23fff%22/%3E%3Crect%20x%3D%2216%22%20y%3D%222%22%20width%3D%223%22%20height%3D%223%22%20fill%3D%22%231d1b26%22/%3E%3Crect%20x%3D%220%22%20y%3D%2214%22%20width%3D%227%22%20height%3D%227%22%20fill%3D%22%231d1b26%22/%3E%3Crect%20x%3D%221%22%20y%3D%2215%22%20width%3D%225%22%20height%3D%225%22%20fill%3D%22%23fff%22/%3E%3Crect%20x%3D%222%22%20y%3D%2216%22%20width%3D%223%22%20height%3D%223%22%20fill%3D%22%231d1b26%22/%3E%3C/svg%3E";
const qrSvg = (_seed: number) => QR_DEMO;
const tf = (scans: number, follows: number, granted: number, first: number, converted: number, p50: number, queued = 0, pending = 0): TrialFunnel =>
  ({ scans, follows, granted, first, converted, p50_secs: p50, queued, pending });
const tc = (id: string, scene: number, channel: string, f: TrialFunnel, x: Partial<TrialCode> = {}): TrialCode => ({
  id, scene, channel, terms: "", terms_words: "7 天 · 300 万 tokens · 同时 1 个会话", terms_words_en: "7 days · 3M tokens · 1 at a time",
  cap: 200, until: ZERO, approval: false, kind: "limit", state: "live", url: "http://weixin.qq.com/q/demo" + scene, image: qrSvg(scene),
  created_by: "gh:1001", created_at: ago(60 * 24 * 9), funnel: f, ...x,
});
let trialCodes: TrialCode[] = [
  tc("tc-salon", 2800004, "线下沙龙 · 深圳 10/25", tf(140, 121, 86, 71, 6, 48), { until: ahead(40) }),
  tc("tc-article", 2800003, "公众号文章 · 十月", tf(512, 388, 200, 152, 19, 55), { until: ahead(71) }),
  tc("tc-partner", 2800002, "合作方 · 灵声客户", tf(61, 40, 37, 30, 9, 62, 0, 2), { cap: 50, approval: true, terms: "days=14,tokens=8000000,sessions=2",
    terms_words: "14 天 · 800 万 tokens · 同时 2 个会话", terms_words_en: "14 days · 8M tokens · 2 at a time", until: ahead(86) }),
  tc("tc-moments", 2800001, "朋友圈海报 · 测试", tf(96, 80, 34, 12, 0, 71), { state: "paused", until: ahead(20),
    paused_why: "34/30" }),
];
const trialTotals = (list: TrialCode[]): TrialFunnel =>
  list.reduce((a, c) => ({ scans: a.scans + c.funnel.scans, follows: a.follows + c.funnel.follows, granted: a.granted + c.funnel.granted,
    first: a.first + c.funnel.first, converted: a.converted + c.funnel.converted, queued: a.queued + c.funnel.queued, pending: a.pending + c.funnel.pending,
    p50_secs: 52 }), tf(0, 0, 0, 0, 0, 0));
const trialPeople = (c: TrialCode): TrialCodeDetail["people"] =>
  ["林小满", "何以宁", "chen.ran", "微信用户·8a2f", "微信用户·19c0"].slice(0, Math.min(5, c.funnel.granted)).map((login, i) => ({
    principal: `p:demo${i}`, login, state: "granted", member: i < Math.min(2, c.funnel.converted), scanned_at: ago(60 * (i + 1) * 7),
    granted_at: ago(60 * (i + 1) * 7), first_at: i < 4 ? new Date(Date.parse(ago(60 * (i + 1) * 7)) + (40 + i * 9) * 1000).toISOString() : ZERO,
  }));

const wait = (ms = 250) => new Promise((r) => setTimeout(r, ms));
const scenario = () => (window as any).__DEMO_SCENARIO || new URLSearchParams(location.search).get("demo") || "";

export async function demoApi(url: string, init: ApiInit = {}): Promise<unknown> {
  await wait(scenario() === "loading" ? 60_000_000 : 250);
  if (scenario() === "error") throw Object.assign(new Error("502 Bad Gateway"), { status: 502 });
  const u = new URL(url, "http://demo.invalid");
  const method = init.method || (init.json !== undefined ? "POST" : "GET");
  const body = (init.json || {}) as Record<string, any>;
  const empty = scenario() === "empty";
  if (u.pathname === "/v1/fleet/settings") {
    // one settings table, three pages' rows: 入口设置 (C15) keeps the audit and
    // its own rows; 订阅池 (C12) and 机器 (C11) keep theirs and win on a key
    const mine = entryDemo(method, u, body) as { settings?: Record<string, string>; hub?: { key: string; value: string; source?: string }[] };
    const pool = demoPool(method, u, body, empty, scenario(), users);
    const machines = demoMachines(method, u, body, empty, init) as { hub?: { key: string; value: string }[] } | undefined;
    if (method !== "GET") return pool ?? machines ?? mine;
    const hub = new Map((mine.hub || []).map((h) => [h.key, h]));
    for (const h of [...(machines?.hub || []), ...poolSettings()]) hub.set(h.key, { ...hub.get(h.key), ...h, source: hub.get(h.key)?.source || "set" });
    return { settings: mine.settings, hub: [...hub.values()] };
  }
  const pool = demoPool(method, u, body, empty, scenario(), users); // 订阅池 (C12)
  // /v1/admin/overview is both pages' read: 订阅池 lays its pool rows over 全队用量's people (C13)
  if (pool !== undefined && method === "GET" && u.pathname === "/v1/admin/overview")
    return { ...(usageOverview(empty) as object), pool: (pool as { pool: unknown[] }).pool };
  if (pool !== undefined) return pool;
  const machines = demoMachines(method, u, body, empty, init); // 机器与 pod (C11)
  if (machines !== undefined) return machines;
  const entry = entryDemo(method, u, body);
  if (entry !== undefined) return entry;
  if (u.pathname.startsWith("/v1/admin/requests")) {
    if (u.pathname === "/v1/admin/requests") {
      const list = empty ? [] : requests;
      const pending = list.filter((r) => r.state === "pending");
      if (u.searchParams.get("count") === "1") return { pending: pending.length };
      const decided = list.filter((r) => r.state === "approved" || r.state === "rejected");
      return {
        requests: list, pending: pending.length, oldest_pending: pending.map((r) => r.created_at).sort()[0],
        decided_7d: decided.length + 7, approved_7d: decided.filter((r) => r.state === "approved").length + 5, cooldown_days: 30,
      };
    }
    const [id, verb] = u.pathname.slice("/v1/admin/requests/".length).split("/");
    const r = requests.find((x) => x.id === id);
    if (!r) throw Object.assign(new Error("no such request"), { status: 404 });
    if (verb === "approve" || verb === "reject") {
      const done: AccessRequest = { ...r, state: verb === "approve" ? "approved" : "rejected", decided_by: "gh:1001", decided_at: new Date().toISOString(),
        reason: verb === "reject" ? String(body.reason || "") : "", cooldown_until: verb === "reject" && body.cooldown_days ? ahead(Number(body.cooldown_days)) : ZERO };
      requests = requests.map((x) => (x.id === id ? done : x));
      return requestDetail(done);
    }
    return requestDetail(r);
  }
  if (u.pathname.startsWith("/v1/admin/trial-codes")) {
    if (u.pathname === "/v1/admin/trial-codes") {
      if (method === "POST") {
        const scene = 2800000 + trialCodes.length + 1;
        const c = tc(`tc-new${scene}`, scene, String(body.channel || ""), tf(0, 0, 0, 0, 0, 0), {
          cap: Number(body.cap ?? 200), approval: !!body.approval, kind: body.kind === "temp" ? "temp" : "limit", created_at: new Date().toISOString(),
          until: body.until ? new Date(String(body.until) + "T23:59:59+08:00").toISOString() : body.kind === "temp" ? ahead(Number(body.days || 14)) : ZERO,
        });
        trialCodes = [c, ...trialCodes];
        return { ...c, people: [] };
      }
      const list = empty ? [] : trialCodes;
      return { codes: list, totals: trialTotals(list), days: 7, ready: scenario() !== "noreach", terms: "days=7,tokens=3000000,sessions=1",
        terms_words: "7 天 · 300 万 tokens · 同时 1 个会话", terms_words_en: "7 days · 3M tokens · 1 at a time", cap: 200, daily: 100, today: 23, burst: 30, temp_days_max: 30 };
    }
    const [id, verb] = u.pathname.slice("/v1/admin/trial-codes/".length).split("/");
    const c = trialCodes.find((x) => x.id === id);
    if (!c) throw Object.assign(new Error("no such trial code"), { status: 404 });
    if (verb === "stop" || verb === "resume") {
      const done: TrialCode = { ...c, state: verb === "stop" ? "stopped" : "live", paused_why: "" };
      trialCodes = trialCodes.map((x) => (x.id === id ? done : x));
      return { ...done, people: trialPeople(done) };
    }
    return { ...c, people: trialPeople(c) };
  }
  if (u.pathname === "/v1/admin/notices") {
    const today = notices.filter((n) => Date.now() - Date.parse(n.created_at) < 86400_000).length;
    if (method === "POST") {
      if (today >= 3) throw Object.assign(new Error("at most 3 notices in 24 hours"), { status: 429 });
      const to: string[] = body.to === "all" ? noticeMembers.map((m) => m.principal_id) : body.to;
      const n: ServiceNotice = { id: `nc-${notices.length + 1}`, body: String(body.body || ""), link: String(body.link || ""),
        audience: body.to === "all" ? "all" : "some", recipients: to, created_by: "gh:1001", created_at: new Date().toISOString(),
        delivery: { pending: to.length, sent: 0, undelivered: 0, via: {} } };
      notices = [n, ...notices];
      return n;
    }
    return { notices: empty ? [] : notices, today: empty ? 0 : today, limit: 3, members: noticeMembers };
  }
  switch (`${method} ${u.pathname}`) {
    case "GET /v1/me":
      return { role: "admin", person: "gh:1001", name: "周宁", login: "zhouning", ...(scenario() === "noreach" ? { reach: { wechat: false } } : {}) };
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
      if (p?.startsWith("wx:demo")) {
        // a trial person from 试用用量's demo: their day is their week
        const n = trialSpendDemo("", false).people.find((x) => x.principal === p)?.tokens || 0;
        return { range: "7d", today: 0, week: n, total: n, limit: lim(), models: [{ provider: "claude", name: "claude-sonnet-5-5", tokens: n }], by_session: [] };
      }
      if (p) return personUsage(p);
      return empty ? { people: [], models: [], machines: [] } : teamUsage;
    }
    case "GET /v1/admin/usage/trial":
      return trialSpendDemo(u.searchParams.get("day") || "", empty);
    case "GET /v1/admin/overview":
      return usageOverview(empty);
    case "GET /v1/admin/sessions": {
      const { overview, sessions } = usageDemo();
      return empty ? { sessions: [], nodes: overview.nodes } : sessions;
    }
  }
  throw Object.assign(new Error(`demo: no ${method} ${u.pathname}`), { status: 404 });
}
