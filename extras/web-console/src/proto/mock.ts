// mock.ts — the review build's API (EPIC #3923 rule 14): the entry's real
// response shapes (/v1/me, /v1/me/usage, /v1/fleet/devices, /v1/chat/*) with
// made-up people and numbers. Only `vite build --mode proto` imports it; the
// scenario comes from the review page in window.name.
type Scenario = { role?: "user" | "admin"; state?: "normal" | "empty" | "no_home" | "over"; page?: string };

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
  const real = window.fetch.bind(window);
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    const p = url.replace(/^https?:\/\/[^/]+/, "").split("?")[0];
    await new Promise((r) => setTimeout(r, 120));
    switch (p) {
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
