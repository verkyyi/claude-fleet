// A projection beside the existing webchat service, not a space client.
import { execFile } from "node:child_process";
import { join } from "node:path";

export function studioHandlers({ helpers, env, readJson, send, spawn, gate, pending, previewFetch = fetch }) {
  const book = (op, body = {}) => new Promise((resolve, reject) => {
    const child = execFile("python3", [join(helpers, "fleet_studio.py"), op],
      { env, timeout: 10000, maxBuffer: 4 * 1024 * 1024 }, (error, stdout) => {
        try {
          const data = JSON.parse(stdout);
          if (error || data.error) reject(new Error(data.error || "工作台暂时不可用")); else resolve(data);
        } catch { reject(new Error("工作台暂时不可用")); }
      });
    child.stdin.end(JSON.stringify(body));
  });
  const renewing = new Map();
  async function renew(a) {
    const id = `${a.fid}:${a.proposal_id}:${a.version_id}`;
    if (renewing.has(id)) return renewing.get(id);
    const job = (async () => {
      const { version: v, embed_origin: origin } = await book("renewal", a);
      const lease = v._renewal;
      if (!lease || !(Date.parse(lease.expires) > Date.now())) return { state: "authorization_required" };
      if (v.retry_at * 1000 > Date.now()) return { state: "retry_later", error: v.preview_error };
      // Only this exact endpoint is callable, never an Agent-supplied arbitrary URL.
      const source = new URL(v.embed);
      if (source.origin !== "https://space.24haowan.com" || !/^[A-Za-z0-9_-]{1,64}$/.test(a.version_id)) {
        throw new Error("unsupported_preview_origin");
      }
      try {
        const response = await previewFetch(`${source.origin}/preview/${a.version_id}/renew`, {
          method: "POST", redirect: "error", signal: AbortSignal.timeout(12000),
          headers: { "Content-Type": "application/json", "User-Agent": "24haowan-probe/fleet-studio-renewal" },
          body: JSON.stringify({ key: lease.key, embed_origin: origin }),
        });
        if (!response.ok) {
          const terminal = response.status === 401 || response.status === 403;
          const error = terminal ? "preview_authorization_expired" : response.status === 429 ? "preview_rate_limit" : "preview_unavailable";
          await book("renewal_failed", { ...a, renewal_key: lease.key, error, terminal });
          return { state: terminal ? "authorization_required" : "retry_later", error };
        }
        const result = await response.json();
        const url = new URL(result.url);
        if (url.origin !== source.origin || !url.pathname.startsWith(`/embed/${a.version_id}/`) || result.version_id !== a.version_id || result.proposal_id !== a.proposal_id || result.origin !== origin || !(Date.parse(result.expires_at) > Date.now())) {
          throw new Error("invalid_preview_response");
        }
        await book("renewed", { ...a, renewal_key: lease.key, embed_url: result.url, embed_expires: result.expires_at });
        return { state: "ready" };
      } catch {
        await book("renewal_failed", { ...a, renewal_key: lease.key, error: "preview_unavailable", terminal: false });
        return { state: "retry_later", error: "preview_unavailable" };
      }
    })().finally(() => renewing.delete(id));
    renewing.set(id, job);
    return job;
  }
  // Serialize opens across tabs. The persistent binding survives reconnects and
  // restarts; a lost response is retried with the same key, never another spawn.
  let opening = Promise.resolve();
  async function open(a) {
    const state = await book("read");
    const key = String(a.key || "catalog");
    if (!/^[A-Za-z0-9_-]{1,100}$/.test(key)) throw new Error("无效项目");
    const proposal = String(a.proposal_id || "");
    const prior = (Object.hasOwn(state.sessions, key) ? state.sessions[key] : null) || Object.values(state.sessions).find(s => proposal && s.proposal_id === proposal);
    if (prior) return { ...prior, reused: true };
    if (proposal && !state.projects.some(p => p.proposal_id === proposal)) throw new Error("请先刷新项目列表");
    if (a.agent !== "claude" && a.agent !== "codex") throw new Error("请选择 Claude Code 或 Codex");
    const origin = new URL(a.embed_origin);
    if (origin.protocol !== "https:" || origin.origin !== a.embed_origin) throw new Error("无效预览来源");
    const instruction = key === "catalog"
      ? "读取本人工作区的全部活页项目（list_proposals，含分页），用 fleet.studio_projects 展示。只读，不修改页面。"
      : proposal ? `打开已绑定活页 ${proposal}，读取当前状态和版本，获取预览并 show_page。不自动发布，不改可见范围。`
        : String(a.text || "请先问我想做什么页面；所有改动先 hold 并给预览。").slice(0, 10000);
    const text = `${instruction}\n\n[增长运营 Agent] 本会话使用 livepage-studio 定义。先 page_target，未绑定时稍后重试。全部改动 hold；只有右栏确认记录可授权上线或推送。`;
    const result = await spawn(text, a.agent, "livepage-studio");
    if (!result.fid) throw new Error(result.error || "没能开一个工作台会话");
    return book("bind", { key, fid: result.fid, agent: a.agent, proposal_id: proposal, embed_origin: origin.origin });
  }
  return async (req, res, path) => {
    try {
      if (path === "/api/studio" && req.method === "GET") {
        const state = await book("read");
        // Approval receipts are for the agent. The UI only needs its projection.
        const sessions = Object.fromEntries(Object.entries(state.sessions).map(([k, { actions, ...s }]) => [k, {
          ...s, operations: (actions || []).map(({ id, action, version_id, state, message, at }) => ({ id, action, version_id, state, message, at })),
        }]));
        return send(res, 200, { ...state, sessions });
      }
      if (req.method !== "POST") return send(res, 405, { error: "POST only" });
      if (req.headers["x-fleet-webchat"] !== "1") return send(res, 403, { error: "forbidden" });
      const a = await readJson(req);
      if (!a) return send(res, 400, { error: "invalid body" });
      if (path === "/api/studio/open") {
        const next = opening.then(() => open(a));
        opening = next.catch(() => {});
        return send(res, 200, await next);
      }
      if (path === "/api/studio/preview") return send(res, 200, await renew(a));
      if (path === "/api/studio/action") {
        const receipt = await book("action", a);
        if (receipt.used || ["queued", "sent", "executing", "succeeded", "unknown"].includes(receipt.state)) return send(res, 200, { state: receipt.state });
        const text = `请执行这条右栏指令，先 page_target 核对确认记录；执行后读取真实结果并 show_page，带 action_id、action_state=succeeded/failed/unknown、action_message。结果不明时只读取核实，不能重做发布或推送。\n${JSON.stringify({ livepage_studio_action: receipt })}`;
        const deliveryArgs = { ...a, id: receipt.id };
        const claim = await book("claim", deliveryArgs);
        if (!claim.claimed) return send(res, 200, { state: claim.state });
        let r;
        try { r = await gate(["say", "--fid", a.fid, "--delivery", receipt.id], text); }
        catch { r = {}; }
        if (!r.j) {
          await book("delivery", { ...deliveryArgs, state: "unknown", message: "送达结果待核实，请在会话中读取实际状态，勿重复操作" });
          return send(res, 200, { state: "unknown" });
        }
        await book("delivery", { ...deliveryArgs, state: r.j.state === "returned" ? "failed" : r.j.state === "queued" ? "queued" : "sent", message: r.j.why || "" });
        if (r.j.state === "returned") return send(res, 409, { error: r.j.why || "指令未送达，请检查会话状态" });
        pending();
        return send(res, 200, r.j);
      }
      return send(res, 404, { error: "not found" });
    } catch (e) { return send(res, 400, { error: String(e.message || e) }); }
  };
}
