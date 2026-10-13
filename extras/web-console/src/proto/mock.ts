// mock.ts — the review build's API (EPIC #3923 rule 14): the entry's real
// response shapes (/v1/me, /v1/me/usage, /v1/fleet/devices, /v1/chat/*,
// /v1/fleet/tasks, /v1/fleet/tickets*, and 设备's /v1/fleet/connect,
// /v1/fleet/entry/*, /v1/nodes; 设置's /v1/me/identities and
// /v1/fleet/person-bundle, kept in memory so binding and importing can be clicked) with
// made-up people and numbers. Only `vite build --mode proto` imports it; the
// scenario comes from the review page in window.name.
type Scenario = { role?: "user" | "admin"; state?: "normal" | "empty" | "no_home" | "over" | "unlimited" | "error" | "loading" | "entry_off"; page?: string };

const SALES_REPLY =
  "看板做好了，按 **华东 / 华南 / 华北** 三块分开：\n\n| 区域 | 总额 | 订单 |\n|---|--:|--:|\n| 华东 | ¥1,284,300 | 412 |\n| 华南 | ¥906,120 | 318 |\n| 华北 | ¥655,480 | 247 |\n\n链接：dash-w41（团队可见）。要我顺便写一页周报发到群里吗？";

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
      item({ kind: "orch", title: "" }, 98000),
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
  const ids = [{ kind: "wechat", subject: "o-wx-" + me.login, label: "o-wx-" + me.login, verified_at: "2026-09-02T08:00:00Z" }];
  let bundle = { version: 3, created: "2026-10-09T10:12:00Z", bundle: { mcp: { context7: { command: "npx", args: ["-y", "@upstash/context7-mcp"] } }, ui_lang: "zh" } as Record<string, unknown> };
  const idView = () => ({ person: me.person, identities: ids, can_add: ["email"] });
  const models = [{ id: "opus", label: "Opus 5.5" }, { id: "sonnet", label: "Sonnet 5.5" }];
  // 任务 and 单子 (C5): /v1/fleet/tasks, /v1/fleet/tickets
  const ago = (min: number) => new Date(Date.now() - min * 60000).toISOString();
  const task = (id: string, title: string, via: string, device: string, min: number, x: Record<string, unknown>) =>
    ({ id, owner: me.person, title, via, device, repo: "", agent: "claude", machine: "mac-mini", login: me.login, worker_id: "",
      session_key: "", operation_id: "", state: "open", note: "", issue: "", pr: "", asked: "", parked: "", created_at: ago(min), updated_at: ago(min), ...x });
  const tasks = state === "normal" ? [
    task("T118", "活动报名页：收集姓名、公司、手机号，发布后给我链接", "⌘P", "iPhone", 39, { session_key: "scratch-14", live: { key: "scratch-14", state: "working" } }),
    task("T117", "把 sales-w41.xlsx 做成看板，按区域分，发给团队", "对话", "MacBook Air", 120, { repo: "linxiao/reports", issue: "linxiao/reports#42", session_key: "scratch-12", live: { key: "scratch-12", state: "needs", needs: "ask" } }),
    task("T112", "十月培训幻灯片，12 页，配讲稿", "⌘P", "MacBook Air", 1440, { repo: "linxiao/training", issue: "linxiao/training#7", session_key: "issue-7" }),
    task("T109", "官网首屏改写三版给我挑", "⌘P", "iPhone", 4320, { parked: "等你挑一版" }),
  ] : [];
  const ticket = (repo: string, number: number, title: string, body: string, st: string, min: number, x: Record<string, unknown> = {}) =>
    ({ id: `hub:${repo}#${number}`, repo, number, owner: me.person, backend: "hub", title, body, state: st, labels: [],
      created_at: ago(min + 600), updated_at: ago(min), ...x });
  const tickets = state === "normal" ? [
    ticket("linxiao/reports", 42, "周报看板：华东数据缺 10 月第二周，补上后再发", "华东的 10 月第二周（10/6–10/12）在 sales-w41.xlsx 里是空的。\n\n补上以后重新出看板，再发到团队群。", "open", 26, { assignee: "scratch-12" }),
    ticket("linxiao/training", 7, "培训幻灯片加一页考勤规则", "在第 3 页后面加一页：迟到、请假、补课怎么算。", "closed", 180, { state_reason: "completed" }),
  ] : [];
  const comments: Record<string, Record<string, unknown>[]> = {
    "linxiao/reports#42": [
      { id: 1, author: "scratch-12 (node:linxiao@mac-mini)", body: "已找到原始表：华东第二周在另一张 sheet 里，正在合并。", source: "fleet", created_at: ago(90) },
      { id: 2, author: me.person, body: "合并好先给我看一眼，别直接发群。", source: "hub", created_at: ago(60) },
      { id: 3, author: "scratch-12 (node:linxiao@mac-mini)", body: "好的，合并完会在对话里先发给你。", source: "fleet", created_at: ago(26) },
    ],
    "linxiao/training#7": [1, 2, 3, 4, 5].map((i) => ({ id: 10 + i, author: i % 2 ? "issue-7 (node:linxiao@mac-mini)" : me.person, body: i % 2 ? `第 ${i} 版改好了。` : "再短一点。", source: i % 2 ? "fleet" : "hub", created_at: ago(400 - i * 40) })),
  };
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
  const real = window.fetch.bind(window);
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    const p = url.replace(/^https?:\/\/[^/]+/, "").split("?")[0];
    await new Promise((r) => setTimeout(r, 120));
    // 加载中: the page's own reads never answer, so its loading state stays on screen
    if (state === "loading" && (/^\/v1\/fleet\/(tasks|tickets)/.test(p) || (sc.page === "/usage" && p === "/v1/me/usage"))) return new Promise<Response>(() => {});
    // 设备's reads in the review's loading / error / door-off states
    const devRead = /^\/v1\/(fleet\/(connect|devices|entry\/)|nodes)/.test(p);
    if (devRead && state === "loading") return new Promise<Response>(() => {});
    if (devRead && state === "error") return ok({ error: "演示：入口出错" }, 502);
    if (p.startsWith("/v1/fleet/entry/") && state === "entry_off") return ok({ error: "the direct door is off on this hub (fleet.entry)" }, 404);
    if (p.startsWith("/v1/fleet/entry/keys/")) {
      const id = decodeURIComponent(p.slice("/v1/fleet/entry/keys/".length));
      const i = keys.findIndex((k) => k.id === id);
      if (i >= 0) keys.splice(i, 1);
      return ok({ id });
    }
    const tk = /^\/v1\/fleet\/tickets\/([^/]+)\/([^/]+)\/(\d+)(\/comments)?$/.exec(p);
    if (tk) {
      const t = tickets.find((x) => x.repo === `${tk[1]}/${tk[2]}` && x.number === Number(tk[3]));
      if (!t) return ok({ error: "no such ticket of yours" }, 404);
      const key = `${t.repo}#${t.number}`;
      const body = JSON.parse(String(init?.body || "{}"));
      if (tk[4] && init?.method === "POST") {
        const c = { id: Date.now(), author: me.person, body: body.body, source: "hub", created_at: new Date().toISOString() };
        (comments[key] ||= []).push(c);
        return ok(c, 201);
      }
      if (init?.method === "PATCH") return ok(Object.assign(t, { state: body.state, state_reason: body.state_reason, updated_at: new Date().toISOString() }));
      return ok({ ticket: t, comments: comments[key] || [] });
    }
    const ti = /^\/v1\/fleet\/tasks\/(T\d+)\/issue$/.exec(p);
    if (ti) {
      const t = tasks.find((x) => x.id === ti[1])!;
      const repo = JSON.parse(String(init?.body || "{}")).repo;
      const n = tickets.length + 50;
      tickets.unshift(ticket(repo, n, t.title, `${t.title}\n\nhub 任务 ${t.id} 补建的单。`, "open", 0));
      Object.assign(t, { repo, issue: `${repo}#${n}` });
      return ok(t);
    }
    switch (p) {
      case "/v1/fleet/tasks": return state === "error" ? ok({ error: "down" }, 502) : ok({ tasks, observed_at: new Date().toISOString() });
      case "/v1/fleet/tickets": return state === "error" ? ok({ error: "down" }, 502) : ok({ tickets: tickets.map((t) => ({ ...t, comments: (comments[`${t.repo}#${t.number}`] || []).length })) });
      case "/v1/me": return ok(me);
      case "/v1/me/usage":
        if (state === "error" && sc.page === "/usage") return ok({ error: "unavailable" }, 503);
        return ok(usage(/[?&]range=([^&]+)/.exec(url)?.[1] || "7d"));
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
        return ok({ items, asks: [], models, default: "opus", busy: false, ...(state === "over" ? { budget: { blocked: true, until: reset.toISOString() } } : {}) });
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
      case "/v1/chat/stop": case "/v1/chat/answer": return ok({ ok: true });
    }
    return real(input, init);
  };
  return sc.page || "/";
}
