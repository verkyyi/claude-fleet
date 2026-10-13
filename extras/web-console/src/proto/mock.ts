// mock.ts — the review build's API (EPIC #3923 rule 14): the entry's real
// response shapes (/v1/me, /v1/me/usage, /v1/fleet/devices, /v1/chat/*,
// /v1/fleet/tasks, /v1/fleet/tickets*) with
// made-up people and numbers. Only `vite build --mode proto` imports it; the
// scenario comes from the review page in window.name.
type Scenario = { role?: "user" | "admin"; state?: "normal" | "empty" | "no_home" | "over" | "error"; page?: string };

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
  const limit = { set: true, limit_week: 100, remaining_week: state === "over" ? 0 : 62, reset_week: reset.toISOString(), over: state === "over", window: "week" };
  const items: Record<string, string>[] = state === "normal" ? [
    { t: "user", text: "把 sales-w41.xlsx 做成看板，按区域分，发给团队" },
    { t: "tool", id: "t1", name: "Read", summary: "Read · sales-w41.xlsx" },
    { t: "tool_result", id: "t1", text: "1,024 行 · 7 列" },
    { t: "tool", id: "t2", name: "Bash", summary: "Bash · fleet dash publish dash-w41" },
    { t: "tool_result", id: "t2", text: "published dash-w41" },
    { t: "text", d: SALES_REPLY },
  ] : [];
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
  const real = window.fetch.bind(window);
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    const p = url.replace(/^https?:\/\/[^/]+/, "").split("?")[0];
    await new Promise((r) => setTimeout(r, 120));
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
      case "/v1/me/usage": return ok({ limit });
      case "/v1/fleet/devices": return ok({ mine: true, idle_sec: 0, devices: [{ fingerprint: "SHA256:a", name: "MacBook-Air", registered_at: "", last_used_at: "", renewals: 3 }], audit: [] });
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
