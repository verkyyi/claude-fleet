// mock.ts — the review build's API (EPIC #3923 rule 14): the entry's real
// response shapes (/v1/me, /v1/me/usage, /v1/fleet/devices, /v1/chat/*,
// /v1/fleet/tasks, 我自己的订阅's /v1/me/subscriptions*,
// and 设备's /v1/fleet/connect,
// /v1/fleet/entry/*, /v1/nodes; 设置's /v1/me/identities and
// /v1/fleet/person-bundle, kept in memory so binding and importing can be clicked) with
// made-up people and numbers. Only `vite build --mode proto` imports it; the
// scenario comes from the review page in window.name.
type Scenario = { role?: "user" | "admin" | "view"; // view = an admin looking through 林晓's eyes (claude-fleet#3944)
  state?: "normal" | "empty" | "no_home" | "over" | "unlimited" | "error" | "loading" | "entry_off" | "ask"; page?: string;
  // 我自己的订阅 (C21): none = the empty state; login = the dialog open at the sign-in; error = the read fails
  sub?: "none" | "login" | "connected" | "paused" | "reauth" | "error";
  // unbound = a GitHub member the notices cannot find yet (claude-fleet#4057)
  wx?: "unbound";
  // 试用中 (claude-fleet#4059): a trial person — running, its last line, spent
  trial?: "running" | "last" | "capped";
  // 试用成员 (claude-fleet T796): an approved member's trial limits on /v1/me/usage
  member?: "ok" | "soon" | "spent" | "expired";
  // 终端 ⇄ WebChat (claude-fleet T810): a terminal session holds the conversation, answering or idle; or it was just handed here
  own?: "term_busy" | "term_idle" | "handed" };

const SALES_REPLY =
  "看板做好了，按 **华东 / 华南 / 华北** 三块分开：\n\n| 区域 | 总额 | 订单 |\n|---|--:|--:|\n| 华东 | ¥1,284,300 | 412 |\n| 华南 | ¥906,120 | 318 |\n| 华北 | ¥655,480 | 247 |\n\n链接：dash-w41（团队可见）。要我顺便写一页周报发到群里吗？";

// the terminal's last turns (T810): what a session there said before it came over
const termItems: Record<string, unknown>[] = [
  { t: "user", text: "顺便把华南那块按城市再拆一下" },
  { t: "tool", id: "tt1", name: "Bash", summary: "python3 split_cities.py sales-w41.xlsx" },
  { t: "tool_result", id: "tt1", text: "广州 ¥402,110 · 深圳 ¥351,870 · 佛山 ¥152,140" },
  { t: "text", d: "华南拆好了：**广州 ¥402,110 · 深圳 ¥351,870 · 佛山 ¥152,140**，已加到看板第二页。" },
];

const ok = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

export async function install(): Promise<string> {
  let sc: Scenario = {};
  try { sc = JSON.parse(window.name || "{}"); } catch { /* defaults */ }
  const admin = sc.role === "admin";
  const state = sc.state || "normal";
  const reset = new Date(Date.now() + 3 * 864e5); reset.setHours(8, 0, 0, 0);
  const me = admin
    ? { via: "wechat", role: "admin", person: "p:zhouning", name: "周宁", login: "zhouning", pages: ["overview", "sessions", "tasks", "usage", "chat"], can_logout: true }
    : { via: "wechat", role: "user", person: "p:linxiao", name: "林晓", login: "linxiao", pages: ["overview", "sessions", "tasks", "usage", "chat"], can_logout: true };
  // 只读预览: the entry answers as 林晓, says who looks, and has nothing to sign out
  if (sc.role === "view") Object.assign(me, { view_as: { person: "p:linxiao", name: "林晓", by: "周宁" }, can_logout: false });
  const wxBind = { unbound: sc.wx === "unbound", polls: 0 };
  const m = sc.member, D = 864e5;
  const memberTrial: Record<string, unknown> = {
    state: m || "ok", sessions: 1, sessions_now: 1, tokens: 3_000_000,
    used_tokens: m === "spent" ? 3_012_000 : m === "soon" ? 2_520_000 : 120_000,
    until: new Date(Date.now() + (m === "expired" ? -D / 3 : m === "soon" ? D / 2 : 6 * D - 3600e3)).toISOString(),
    days_left: m === "expired" ? 0 : m === "soon" ? 1 : 6,
  };
  if (sc.trial) Object.assign(me, { role: "trial", pages: ["chat"] });
  const trialState = () => ({ state: sc.trial === "capped" ? "ended" : "running", secs_left: sc.trial === "capped" ? 0 : 680,
    msgs_left: sc.trial === "last" ? 0 : sc.trial === "capped" ? 4 : 16, max_secs: 900, max_msgs: 20,
    ...(sc.trial === "capped" ? { ended: "time" } : {}), apply: "/apply?from=trial" });
  if (wxBind.unbound) Object.assign(me, { via: "github", reach: { wechat: false } });
  const limit = state === "unlimited" ? { set: false, used_week: 0, used_5h: 412000 } : {
    set: true, limit_week: 6_000_000, used_week: state === "over" ? 6_000_000 : state === "empty" ? 0 : 2_284_000,
    remaining_week: state === "over" ? 0 : state === "empty" ? 6_000_000 : 3_716_000, reset_week: reset.toISOString(),
    limit_5h: 1_200_000, used_5h: state === "over" ? 1_200_000 : state === "empty" ? 0 : 312_400,
    remaining_5h: state === "over" ? 0 : state === "empty" ? 1_200_000 : 887_600,
    ...(state === "empty" ? {} : { reset_5h: new Date(Date.now() + 2.4 * 36e5).toISOString() }),
    over: state === "over", ...(state === "over" ? { window: "week" } : {}),
  };
  const usage = (range: string) => {
    const n = range === "30d" ? 30 : range === "14d" ? 14 : 7, today = Date.UTC(new Date().getUTCFullYear(), new Date().getUTCMonth(), new Date().getUTCDate());
    const per = [212, 380, 96, 455, 610, 288, 40, 0, 520, 702, 395, 468, 233, 421];
    const quiet = state === "empty";
    const days = Array.from({ length: n }, (_, i) => {
      const t = per[(per.length - n + i + 28) % per.length] * 1000;
      return { day: new Date(today - (n - 1 - i) * 864e5).toISOString().slice(0, 10), claude: quiet ? 0 : Math.round(t * 0.86), codex: quiet ? 0 : Math.round(t * 0.14) };
    });
    const k = range === "today" ? 1 : range === "30d" ? 3.6 : range === "14d" ? 1.9 : 1;
    const w = (x: number) => (quiet ? 0 : Math.round(x * (range === "today" ? 0.19 : k)));
    const item = (o: Record<string, unknown>, tokens: number) => ({ title: "", ...o, tokens: w(tokens) });
    const issue = [
      item({ kind: "issue", title: "销售周报看板", repo: "linxiao/sales-dash", issue: 42, epic: "linxiao/sales-dash#40", epic_title: "十月报表", sessions: ["issue-42 · 林晓的 MacBook-Air"], models: [["Opus 5.5", 802000], ["Sonnet 5.5", 100000]], node: "mac-mini", login: "linxiao" }, 902000),
      item({ kind: "issue", title: "活动报名页", repo: "linxiao/event-signup", issue: 7, sessions: ["scratch-14"], models: [["Opus 5.5", 610000], ["GPT-5.4 Codex", 334000]], node: "mac-mini", login: "linxiao" }, 944000),
      item({ kind: "none", title: "", sessions: ["对话"], models: [["Sonnet 5.5", 340000]] }, 340000),
    ];
    const total = issue.reduce((a, r) => a + (r.tokens as number), 0);
    return {
      range, since: new Date(today).toISOString(), limit, since_first: "2026-08-01T00:00:00Z",
      today: quiet ? 0 : 421_800, today_prev: quiet ? 0 : 388_200, week: quiet ? 0 : 2_284_000, week_prev: quiet ? 0 : 1_962_000, total,
      days, by_session: [],
      models: quiet ? [] : [{ name: "Opus 5.5", provider: "claude", tokens: w(1_412_000) }, { name: "Sonnet 5.5", provider: "claude", tokens: w(538_000) }, { name: "GPT-5.4 Codex", provider: "codex", tokens: w(334_000) }],
      work: quiet ? { issue: [{ kind: "none", title: "", tokens: 0 }], repo: [{ kind: "none", title: "", tokens: 0 }], epic: [{ kind: "none", title: "", tokens: 0 }] } : {
        issue,
        repo: [item({ kind: "repo", title: "linxiao/sales-dash", repo: "linxiao/sales-dash" }, 902000), item({ kind: "repo", title: "linxiao/event-signup", repo: "linxiao/event-signup" }, 944000), item({ kind: "none" }, 438000)],
        epic: [item({ kind: "epic", title: "十月报表", epic: "linxiao/sales-dash#40", epic_title: "十月报表" }, 902000), item({ kind: "none" }, 1_382_000)],
      },
    };
  };
  const items: Record<string, string>[] = state === "normal" ? [
    { t: "user", text: "把 sales-w41.xlsx 做成看板，按区域分，发给团队" },
    { t: "tool", id: "t1", name: "Read", summary: "Read · sales-w41.xlsx" },
    { t: "tool_result", id: "t1", text: "1,024 行 · 7 列" },
    { t: "tool", id: "t2", name: "Bash", summary: "Bash · fleet dash publish dash-w41" },
    { t: "tool_result", id: "t2", text: "published dash-w41" },
    { t: "text", d: SALES_REPLY },
  ] : [];
  const ids = wxBind.unbound ? [{ kind: "github", subject: "4242", label: me.login, verified_at: "2026-09-02T08:00:00Z" }]
    : [{ kind: "wechat", subject: "o-wx-" + me.login, label: "o-wx-" + me.login, verified_at: "2026-09-02T08:00:00Z" }];
  // 新来的: one way in, no configuration written yet (the hub answers version 0)
  let bundle = state === "empty" ? { version: 0, bundle: {} as Record<string, unknown> } as { version: number; created?: string; bundle: Record<string, unknown> } : { version: 3, created: "2026-10-09T10:12:00Z", bundle: { mcp: { context7: { command: "npx", args: ["-y", "@upstash/context7-mcp"] } }, ui_lang: "zh" } as Record<string, unknown> };
  const idView = () => ({ person: me.person, identities: ids, can_add: ["email"] });
  const models = [{ id: "opus", label: "Opus 5.5" }, { id: "sonnet", label: "Sonnet 5.5" }];
  // 任务 (C5): /v1/fleet/tasks
  const ago = (min: number) => new Date(Date.now() - min * 60000).toISOString();
  const task = (id: string, title: string, via: string, device: string, min: number, x: Record<string, unknown>) =>
    ({ id, owner: me.person, title, via, device, repo: "", agent: "claude", machine: "mac-mini", login: me.login, worker_id: "",
      session_key: "", operation_id: "", state: "open", note: "", issue: "", pr: "", asked: "", parked: "", created_at: ago(min), updated_at: ago(min), ...x });
  const W1 = "5b1e0000-0000-4000-8000-00000000f001", W2 = "5b1e0000-0000-4000-8000-00000000f002";
  const v1 = (x: Record<string, unknown>) => ({ authority_version: 1, generation: 1, ...x });
  const words = (w: string) => JSON.stringify({ action: "worker_start", node: "auto", params: { body: w } });
  const tasks = state === "normal" ? [
    task("T121", "活动报名页：收集姓名、公司、手机号，发布后给我链接", "⌘P", "iPhone", 39, v1({ fid: "3f2a9c10-1b2c-4d3e-8f40-1a2b3c4d5e01", short: "D7KQ", task_state: "running", repo: "linxiao/event-signup", worker_id: `${W1}/a91f`, session_key: "scratch-14", request_payload: words("活动报名页：收集姓名、公司、手机号，发布后给我链接。配色跟官网一致，手机上好填。"), live: { key: "scratch-14", state: "needs", needs: "ask", status_kind: "question" } })),
    task("T119", "十月报表", "⌘P", "MacBook Air", 300, v1({ fid: "7c11d2e3-aaaa-4bbb-8ccc-0d1e2f3a4b02", short: "P3MX", task_state: "running", repo: "linxiao/sales-dash", worker_id: `${W1}/e001`, session_key: "scratch-30", request_payload: words("十月的三份报表：销售周报看板、月报导出 PDF、渠道对比。一份一个任务，做完一份合一份。"), live: { key: "scratch-30", state: "working" } })),
    task("T120", "销售周报看板：按区域分，发给团队", "批次", "", 240, v1({ fid: "7c22e3f4-bbbb-4ccc-8ddd-1e2f3a4b5c03", short: "P3NA", task_state: "running", repo: "linxiao/sales-dash", parent_task: "7c11d2e3-aaaa-4bbb-8ccc-0d1e2f3a4b02", worker_id: `${W1}/77c0`, session_key: "task-p3na", request_payload: words("把 sales-w41.xlsx 做成看板，按华东 / 华南 / 华北分，发给团队。"), live: { key: "task-p3na", state: "working" } })),
    task("T122", "月报导出 PDF，每月 1 号自动发", "批次", "", 230, v1({ fid: "7c33f4a5-cccc-4ddd-8eee-2f3a4b5c6d04", short: "P3RT", task_state: "accepted", repo: "linxiao/sales-dash", parent_task: "7c11d2e3-aaaa-4bbb-8ccc-0d1e2f3a4b02", request_payload: words("月报导出成 PDF，每月 1 号早上 9 点自动发到群里。") })),
    task("T112", "十月培训幻灯片，12 页，配讲稿", "⌘P", "MacBook Air", 1440, v1({ fid: "9e44a5b6-dddd-4eee-8fff-3a4b5c6d7e05", short: "W8GE", task_state: "running", repo: "linxiao/training-deck", worker_id: `${W2}/0d3e`, session_key: "task-w8ge", pr: "linxiao/training-deck#12", pr_state: "waiting", evidence: "12 页做完，讲稿在每页备注里；PR #12 等合并。", request_payload: words("十月培训幻灯片，12 页，配讲稿，风格简洁。"), live: { key: "task-w8ge", state: "done" } })),
    task("T109", "官网首屏改写三版给我挑", "⌘P", "iPhone", 4320, v1({ fid: "b155b6c7-eeee-4fff-8aaa-4b5c6d7e8f06", short: "H2VB", task_state: "waiting", asked: "三版写好了，等你挑一版（A 稳 · B 活泼 · C 短）", request_payload: words("官网首屏的标题和副题改写三版给我挑。") })),
    task("T107", "客户名单去重", "对话", "MacBook Air", 5760, v1({ fid: "c266c7d8-ffff-4aaa-8bbb-5c6d7e8f9a07", short: "M5TC", outcome: "failed", repo: "linxiao/crm-clean", worker_id: `${W2}/3e02`, session_key: "task-m5tc", evidence: "表里 1,204 行有 37 行手机号格式不一，没敢自动合并。", request_payload: words("客户名单去重，同一个手机号只留一行。") })),
    task("T104", "新品发布 · 预告短片", "⌘P", "iPhone", 8640, v1({ fid: "d377d8e9-aaaa-4bbb-8ccc-6d7e8f9a0b08", short: "R9QD", outcome: "succeeded", repo: "linxiao/launch-video", worker_id: `${W1}/9c01`, session_key: "scratch-9", pr: "linxiao/launch-video#4", pr_state: "merged", evidence: "30 秒预告片已导出，链接发到群里了。", request_payload: words("新品发布的 30 秒预告短片。") })),
    task("T123", "新品发布季", "⌘P", "MacBook Air", 20, v1({ fid: "e488e9fa-bbbb-4ccc-8ddd-7e8f9a0b1c09", short: "F6JS", task_state: "accepted", request_payload: words("新品发布季的几件事，先开个批次，成员晚点加。") })),
  ] : [];
  // 设备 (C7): one computer, one phone key, two machines, the home on the first
  const day = (n: number) => new Date(Date.now() - n * 864e5).toISOString();
  const devices: { fingerprint: string; name: string; registered_at: string; last_used_at: string; renewals: number; revoked_at?: string }[] = state === "empty" ? [] : [
    { fingerprint: "SHA256:a", name: "MacBook-Air", registered_at: day(9), last_used_at: day(0.02), renewals: 3 }];
  const keys: { id: string; fp: string; type: string; name: string; created: string; last_used?: string }[] = state === "empty" ? [] : [
    { id: "k_1", fp: "SHA256:q3VtR8mWfJ0aZpLx2Nc9xKc", type: "ssh-ed25519", name: "iPhone", created: day(6), last_used: day(0.1) }];
  let home = { machine: "mac-mini", login: me.login, set_by: "auto", set_at: day(9) };
  // a QR-shaped picture for the review: the three finder squares and a scatter, 29 modules
  const qr = Array.from({ length: 29 }, (_, y) => Array.from({ length: 29 }, (_, x) => {
    const f = (a: number, b: number) => x >= a && x < a + 7 && y >= b && y < b + 7 && (x === a || x === a + 6 || y === b || y === b + 6 || (x > a + 1 && x < a + 5 && y > b + 1 && y < b + 5));
    const inF = (x < 8 && y < 8) || (x > 20 && y < 8) || (x < 8 && y > 20);
    return f(0, 0) || f(22, 0) || f(0, 22) || (!inF && (x * 7 + y * 13 + x * y) % 5 < 2) ? "#" : ".";
  }).join(""));
  const entryView = () => ({
    person: me.person, name: me.login, home, version: 4, keys,
    home_choices: [{ machine: "mac-mini", login: me.login, online: true, name: "mac-mini" }, { machine: "studio-2", login: me.login, online: true, name: "studio-2" }],
    door: { domain: "fleet.example.cn", address: `${me.login}.fleet.example.cn`, port: 22022, login: home.login, home_name: home.machine,
      state: keys.length ? "ok" : "nokey", qr },
  });
  // 我自己的订阅 (C21): the person's own vault rows, with the two windows
  const subSc = sc.sub || "none";
  const hrs = (h: number) => new Date(Date.now() + h * 36e5).toISOString();
  type Sub = Record<string, unknown> & { provider: string; account: string; state: string; paused?: boolean };
  const subs: Sub[] = subSc === "none" || subSc === "login" ? [] : [
    { provider: "claude", account: "my-max", account_uuid: "8e3f0c2a-4444-4d5e-8f60-3456789abcde", plan: "Max 5x",
      state: subSc === "reauth" ? "reauth" : subSc === "paused" ? "paused" : "ok", paused: subSc === "paused",
      five_hour: { used_pct: 46, resets_at: hrs(2.3) }, seven_day: { used_pct: 71, resets_at: hrs(80) }, observed_at: ago(2), created_at: ago(60 * 24 * 6), sessions: subSc === "connected" ? 2 : 0 },
  ];
  const flows: Record<string, { provider: string; account: string; again: boolean }> = {};
  const subsAt = (b: { provider?: string; account?: string }) => subs.find((x) => x.provider === b.provider && x.account === b.account);
  if (subSc === "login") sc.page = (sc.page || "/usage") + (String(sc.page || "").includes("?") ? "&" : "?") + "connect=claude";
  // 我的会话 (#3927): three live sessions on two machines, two ended ones
  const H = 36e5, FLEET = "5b1e0000-0000-4000-8000-00000000f001", FLEET2 = "5b1e0000-0000-4000-8000-00000000f002";
  const before = (ms: number) => new Date(Date.now() - ms).toISOString();
  const asking = state === "ask";
  const sess = (machine: string, fleet: string, w: Record<string, unknown>, tokens = 0) =>
    ({ worker_id: w.worker_id, machine_name: machine, os_user: me.login, fleet_id: fleet, fleet_name: "fleet", availability: "online", worker: w, observed_at: before(2e4), age_sec: 20, ...(tokens ? { tokens_today: tokens } : {}) });
  let live = state === "empty" ? [] : [
    sess("office-mac", FLEET, { worker_id: `${FLEET}/a91f`, key: "scratch-14", repo: "linxiao/event-signup", title: "活动报名页", state: "needs", agent: "claude", born: (Date.now() - 38 * 6e4) / 1e3,
      status_kind: "question", status_msg: "报名页用哪套配色？陶土橙（和官网一致）还是墨蓝（更正式）" }, 169200),
    sess("office-mac", FLEET, { worker_id: `${FLEET}/e001`, key: "scratch-30", repo: "linxiao/sales-dash", title: "十月报表", state: "working", agent: "claude", born: (Date.now() - 5 * H) / 1e3, status_msg: "第 1 份在做，第 2 份排着" }, 21800),
    sess("office-mac", FLEET, { worker_id: `${FLEET}/77c0`, key: "task-p3na", repo: "linxiao/sales-dash", title: "销售周报看板", state: "working", agent: "claude", born: (Date.now() - 2.2 * H) / 1e3, status_msg: "正在画华南的柱状图" }, 186200),
    sess("build-box", FLEET2, { worker_id: `${FLEET2}/0d3e`, key: "task-w8ge", repo: "linxiao/training-deck", title: "十月培训幻灯片", state: "done", agent: "codex", born: (Date.now() - 5 * H) / 1e3 }, 66400),
    sess("office-mac", FLEET, { worker_id: `${FLEET}/5aa0`, key: "scratch-20", repo: "", title: "试一段 Python 脚本", state: "idle", agent: "claude", born: (Date.now() - 50 * 6e4) / 1e3 }, 8200),
  ];
  let ended = state === "empty" ? [] : [
    { worker_id: `${FLEET2}/3e02`, resume_id: `${FLEET2}/task-m5tc`, key: "task-m5tc", title: "客户名单去重", repo: "linxiao/crm-clean", machine_name: "build-box", fleet_id: FLEET2, state: "closed", ended_at: before(3.9 * 864e5) },
    { worker_id: `${FLEET}/9c01`, resume_id: `${FLEET}/scratch-9`, key: "scratch-9", title: "新品发布 · 预告短片", repo: "linxiao/launch-video", machine_name: "office-mac", fleet_id: FLEET, state: "landed", ended_at: before(5.8 * 864e5) },
    { worker_id: `${FLEET}/4b07`, resume_id: `${FLEET}/scratch-5`, key: "scratch-5", title: "周报模板", repo: "", machine_name: "office-mac", fleet_id: FLEET, state: "closed", ended_at: before(8 * 864e5) },
  ];
  const write = (tool: string, wid: string, args: Record<string, unknown> = {}) => {
    // 新建 (T769): a dispatched task — its record first, a session on its way
    if (tool === "worker_start") {
      const body = String(args.body || "");
      tasks.unshift(task(`T${200 + tasks.length}`, String(args.title || body.split("\n")[0]).slice(0, 120), "网页", "", 0,
        v1({ fid: crypto.randomUUID(), task_state: "starting", repo: String(args.repo || ""), request_payload: JSON.stringify({ action: "worker_start", node: "auto", params: args }) })));
      return ok({ operation_id: "op-2", action: tool, status: "pending" });
    }
    if (tool === "worker_reap") {
      const s = live.find((x) => x.worker_id === wid);
      if (!s) return ok({ error: { code: "NOT_FOUND", message: "no such session" } }, 404);
      live = live.filter((x) => x !== s);
      const w = s.worker as Record<string, string>;
      ended = [{ worker_id: wid, resume_id: `${s.fleet_id}/${w.key}`, key: w.key, title: w.title, repo: w.repo, machine_name: s.machine_name, fleet_id: s.fleet_id, state: "closed", ended_at: new Date().toISOString() }, ...ended];
    } else {
      const e = ended.find((x) => x.resume_id === wid);
      if (!e) return ok({ error: { code: "NOT_FOUND", message: "no such session" } }, 404);
      ended = ended.filter((x) => x !== e);
      live = [sess(e.machine_name, e.fleet_id, { worker_id: e.worker_id, key: e.key, repo: e.repo, title: e.title, state: "working", agent: "claude", born: Date.now() / 1e3 }), ...live];
    }
    return ok({ operation_id: "op-1", action: tool, status: "succeeded" });
  };
  // no push channel in review: the sessions page reads by its 10 s poll
  (window as { EventSource?: unknown }).EventSource = undefined;
  const real = window.fetch.bind(window);
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    const p = url.replace(/^https?:\/\/[^/]+/, "").split("?")[0];
    await new Promise((r) => setTimeout(r, 120));
    // 只读预览: every change is the entry's 403 (view_as.go), the conversation too
    const method = (init?.method || (input instanceof Request ? input.method : "GET")).toUpperCase();
    if (sc.role === "view" && (method !== "GET" || (p.startsWith("/v1/chat/") && p !== "/v1/chat/home")))
      return ok({ error: "只读预览，不能改动（read-only preview: nothing can be changed）" }, 403);
    if (p === "/v1/fleet/sessions") {
      if (state === "loading") return new Promise<Response>(() => {});
      if (state === "error") return ok({ error: { code: "UNAVAILABLE", message: "演示：入口出错" } }, 503);
      return url.includes("state=ended") ? ok({ sessions: ended, days: 14 }) : ok({ sessions: live, count: live.length, machines: [], nodes: [] });
    }
    if (p === "/v1/fleet/write") {
      const b = JSON.parse(String(init?.body || "{}"));
      const args = JSON.parse(b.args_json || "{}");
      return write(b.tool, args.worker_id, args);
    }
    // 加载中: the page's own reads never answer, so its loading state stays on screen
    if (state === "loading" && (/^\/v1\/fleet\/tasks/.test(p) || (sc.page === "/usage" && p === "/v1/me/usage"))) return new Promise<Response>(() => {});
    // 设备's reads in the review's loading / error / door-off states
    const devRead = /^\/v1\/(fleet\/(connect|devices|entry\/)|nodes)/.test(p);
    if (devRead && state === "loading") return new Promise<Response>(() => {});
    if (devRead && state === "error") return ok({ error: "演示：入口出错" }, 502);
    // 设置's reads (#3931): the same two states
    if ((p === "/v1/me/identities" || p === "/v1/fleet/person-bundle") && sc.page === "/settings") {
      if (state === "loading") return new Promise<Response>(() => {});
      if (state === "error") return ok({ error: "演示：入口出错" }, 502);
    }
    if (p.startsWith("/v1/fleet/entry/") && state === "entry_off") return ok({ error: "the direct door is off on this hub (fleet.entry)" }, 404);
    if (p.startsWith("/v1/fleet/entry/keys/")) {
      const id = decodeURIComponent(p.slice("/v1/fleet/entry/keys/".length));
      const i = keys.findIndex((k) => k.id === id);
      if (i >= 0) keys.splice(i, 1);
      return ok({ id });
    }
    if (p.startsWith("/v1/me/subscriptions")) {
      const b = JSON.parse(String(init?.body || "{}"));
      if (p === "/v1/me/subscriptions") return subSc === "error" ? ok({ error: "演示：入口出错" }, 502) : ok({ subscriptions: subs, login: true });
      if (p === "/v1/me/subscriptions/login") {
        const flow = "fl_" + Math.random().toString(36).slice(2, 10);
        flows[flow] = { provider: b.provider, account: b.account, again: !!b.again };
        return b.provider === "codex"
          ? ok({ flow, paste: "url", expires_at: hrs(1 / 6), authorize_url: "https://auth.openai.com/oauth/authorize?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&scope=openid+profile+email+offline_access&code_challenge=demo&code_challenge_method=S256&state=" + flow })
          : ok({ flow, paste: "code", expires_at: hrs(1 / 6), authorize_url: "https://claude.ai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&code_challenge=demo&code_challenge_method=S256&state=" + flow });
      }
      if (p === "/v1/me/subscriptions/login/finish") {
        const f = flows[b.flow];
        await new Promise((r) => setTimeout(r, 900));
        if (!f) return ok({ error: "这次登录过期了，重新打开登录页再来一次" }, 410);
        if (String(b.paste).trim().length < 6) return ok({ error: "没接上：贴的不像登录页给的代码。重新打开登录页，整串复制过来。" }, 422);
        delete flows[b.flow];
        const row = subsAt(f);
        if (row) Object.assign(row, { state: "ok", paused: false, five_hour: { used_pct: 0 }, seven_day: { used_pct: 12, resets_at: hrs(120) } });
        else subs.push({ provider: f.provider, account: f.account, plan: f.provider === "codex" ? "ChatGPT Plus" : "Pro", state: "unread",
          five_hour: { used_pct: null }, seven_day: { used_pct: null }, created_at: new Date().toISOString(), sessions: 0 });
        return ok({ provider: f.provider, account: f.account });
      }
      const row = subsAt(b);
      if (!row) return ok({ error: "no such subscription of yours" }, 404);
      if (p === "/v1/me/subscriptions/pause") { Object.assign(row, { paused: !!b.paused, state: b.paused ? "paused" : "ok", sessions: b.paused ? 0 : row.sessions }); return ok(row); }
      if (p === "/v1/me/subscriptions/delete") { subs.splice(subs.indexOf(row), 1); return ok({ deleted: true }); }
    }
    switch (p) {
      case "/v1/fleet/tasks": return state === "error" ? ok({ error: "down" }, 502) : ok({ tasks, observed_at: new Date().toISOString() });
      case "/v1/me": return ok(me);
      case "/v1/try/state": return sc.trial ? ok(trialState()) : ok({ error: "not found" }, 404);
      // 绑微信 (claude-fleet#4057): the third ask finds it scanned
      case "/v1/me/wechat/bind-qr":
        wxBind.polls = 0;
        return ok({ s: 3000042, expires_at: Math.floor(Date.now() / 1000) + 600,
          qr: `<svg class="qr" viewBox="0 0 37 37" shape-rendering="crispEdges"><path d="${qr.flatMap((row, y) => [...row].map((c, x) => (c === "#" ? `M${x + 4} ${y + 4}h1v1h-1z` : ""))).join("")}"/></svg>` });
      case "/v1/me/wechat/bind-poll":
        if (++wxBind.polls < 3) return ok({ s: "wait" });
        Object.assign(me, { reach: { wechat: true } });
        ids.push({ kind: "wechat-mp", subject: "o-mp-" + me.login, label: "o-mp-" + me.login, verified_at: new Date().toISOString() });
        return ok({ s: "bound" });
      case "/v1/me/usage":
        if (state === "error" && sc.page === "/usage") return ok({ error: "unavailable" }, 503);
        return ok({ ...usage(/[?&]range=([^&]+)/.exec(url)?.[1] || "7d"), ...(sc.member ? { trial: memberTrial } : {}) });
      case "/v1/me/trial/upgrade":
        memberTrial.upgrade_asked = new Date().toISOString();
        return ok({ upgrade_asked: memberTrial.upgrade_asked });
      case "/v1/fleet/devices": return ok({ mine: true, idle_sec: 0, devices: devices.filter((d) => !d.revoked_at), audit: [] });
      case "/v1/fleet/devices/revoke": {
        const fp = JSON.parse(String(init?.body || "{}")).fingerprint;
        devices.forEach((d) => { if (d.fingerprint === fp) d.revoked_at = new Date().toISOString(); });
        return ok({ changed: true, fingerprint: fp });
      }
      case "/v1/fleet/connect": return ok({
        hub: "https://fleet.example.cn", ca_enabled: true, cert_ttl_sec: 43200, signed_in: true, login: me.login,
        install_command: "curl -fsSL https://fleet.example.cn/install | sh", install_ready: true,
        config_path: "~/.ssh/fleet-ssh-config", machines: [], recent_certs: [],
        ssh_config: `Host mac-mini fleet-mac-mini\n  HostName 203.0.113.5\n  Port 22022\n  User ${me.login}\n  IdentityFile ~/.ssh/fleet-cert\n  CertificateFile ~/.ssh/fleet-cert-cert.pub\n`,
      });
      case "/v1/fleet/entry/keys": {
        if ((init?.method || "GET").toUpperCase() === "POST") {
          const line = String(JSON.parse(String(init?.body || "{}")).public_key || "").trim().split(/\s+/);
          if (!/^(ssh-ed25519|ecdsa-sha2-|ssh-rsa)/.test(line[0] || "")) return ok({ error: "看不懂这一行：贴 ssh-ed25519 / ecdsa-sha2-… / ssh-rsa 开头的一整行公钥" }, 422);
          const k = { id: `k_${keys.length + 2}`, fp: "SHA256:" + (line[1] || "x").slice(-20), type: line[0], name: line.slice(2).join(" "), created: new Date().toISOString() };
          keys.push(k);
          return ok(k, 201);
        }
        return ok(entryView());
      }
      case "/v1/fleet/entry/home": {
        const b = JSON.parse(String(init?.body || "{}"));
        home = { ...home, machine: b.machine, login: b.login || home.login, set_by: "person" };
        return ok({ home, version: 5 });
      }
      case "/v1/fleet/entry/name": return ok({ name: JSON.parse(String(init?.body || "{}")).name, version: 5 });
      case "/v1/nodes": return ok({ nodes: [
        { endpoint_id: "e1", hostname: "mac-mini", os_user: me.login, status: "online", load1: 1.9, ncpu: 8, sessions: 3, fleet_version: "b9276c61a", last_heartbeat: new Date().toISOString() },
        { endpoint_id: "e2", hostname: "studio-2", os_user: me.login, status: "online", load1: 0.6, ncpu: 12, sessions: 0, fleet_version: "b9276c61a", last_heartbeat: new Date().toISOString() },
      ], machines: [{ hostname: "mac-mini", alias: "mac-mini" }, { hostname: "studio-2", alias: "studio-2" }] });
      case "/v1/me/identities": {
        const m = (init?.method || "GET").toUpperCase();
        if (m === "POST") {
          const subject = JSON.parse(String(init?.body || "{}")).subject || "";
          ids.push({ kind: "email", subject, label: subject, verified_at: new Date().toISOString() });
          return ok({ mail_sent: true }, 202);
        }
        if (m === "DELETE") {
          const q = new URL(url, location.href).searchParams;
          if (ids.length <= 1) return ok({ error: "this is your only way of signing in — add another first" }, 409);
          ids.splice(ids.findIndex((i) => i.kind === q.get("kind") && i.subject === q.get("subject")), 1);
        }
        return ok(idView());
      }
      case "/v1/fleet/person-bundle": {
        if ((init?.method || "GET").toUpperCase() === "PUT") {
          const req = JSON.parse(String(init?.body || "{}"));
          if (req.base !== bundle.version) return ok({ error: "your personal configuration changed since that version — read it again" }, 409);
          bundle = { version: bundle.version + 1, created: new Date().toISOString(), bundle: req.bundle };
        }
        return ok(bundle);
      }
      case "/v1/chat/home": return ok({ machine: "mac-mini", login: me.login, state: "ok" });
      case "/v1/chat/conversation":
        if (state === "no_home") return ok({ code: "no_home", error: "no home" }, 409);
        return ok({ items: sc.own ? [...items, ...termItems] : items, asks: [], models, default: "opus", busy: false, ...(state === "over" ? { budget: { blocked: true, until: reset.toISOString() } } : {}),
          ...(sc.own === "term_busy" || sc.own === "term_idle" ? { owner: { where: "terminal", busy: sc.own === "term_busy", label: "scratch-20", machine: "mac-mini", agent: "claude" } } : {}),
          ...(sc.own === "handed" ? { handed: { from: "terminal", label: "scratch-20", at: new Date().toISOString() } } : {}) });
      case "/v1/chat/turn": {
        const text = JSON.parse(String(init?.body || "{}")).text || "";
        const words = `收到：「${text}」。这是原型里的演示回复——上线后是你家机器上的 Claude 在答。`;
        items.push({ t: "user", text }, { t: "text", d: words });
        const enc = new TextEncoder();
        const stream = new ReadableStream({
          async start(c) {
            c.enqueue(enc.encode(JSON.stringify({ t: "turn", id: "turn-1" }) + "\n"));
            for (const ch of words.match(/.{1,4}/gu) || []) {
              await new Promise((r) => setTimeout(r, 40));
              c.enqueue(enc.encode(JSON.stringify({ t: "text", d: ch }) + "\n"));
            }
            c.enqueue(enc.encode(JSON.stringify({ t: "done" }) + "\n"));
            c.close();
          },
        });
        return new Response(stream, { headers: { "Content-Type": "application/x-ndjson" } });
      }
      case "/v1/chat/stop": case "/v1/chat/answer": case "/v1/chat/take": return ok({ ok: true });
    }
    return real(input, init);
  };
  return sc.page || "/";
}
