// codex.mjs — the conversation's Codex side (task R9A2, issue #4370 B): the page
// shows two assistants, Claude Code and Codex, one conversation each on the same
// home. This is the Codex one, driven through `codex app-server` (JSON-RPC over
// stdio) — the one road where a turn can stop half-way and ask the person
// (an approval, a question) on the page.
//
//   * The app-server starts on the first turn (or a page reading the models)
//     and closes WARM_IDLE after the last turn: no resident process.
//   * Its credential is the pool's, minted for this server's lifetime of the
//     app-server (`fleet-session-cred.sh mint --provider codex`) into a
//     credential-free CODEX_HOME (`codex-home`), the same road bin/fleet-codex.sh
//     takes; the credential lives in the child's environment only. No proxy here
//     (rc 3/4) ⇒ the login's own Codex as it is (the Claude side's "ambient").
//   * The page's stream is the Claude side's, item for item: text · tool ·
//     tool_result · image · page · files · ask · done · stopped · error
//     (code budget). What a turn showed is also appended to this thread's own
//     record, codex/<thread>.ndjson in the state dir — the history the page reads
//     back, and what `service move` carries.
//   * Approvals and questions: sandbox workspace-write, approval on-request — it
//     works in the home freely and asks before it leaves it (the 发起人's call on
//     the design page). An unanswered ask is declined after ASK_TIMEOUT.
//   * 新对话: the thread is put away (kept, never deleted) and the next turn
//     starts a new one; the Claude side is not touched.
import { spawn } from "node:child_process";
import { promises as fsp, readFileSync, writeFileSync, mkdirSync, renameSync, existsSync, realpathSync, readdirSync } from "node:fs";
import { join } from "node:path";

export const CODEX_SHOW_PAGE = "mcp__fleet_chat__show_page"; // the name toolSummary / the page already know
const THREAD_RE = /^[A-Za-z0-9_-]{1,80}$/;

// the note a new thread is started with: how a web page's person sees things
export const CODEX_NOTE = "你在一个网页里和这个人对话，他看不到这台机器的屏幕和文件。" +
  "要给他看的图片、截图：用 view_image 看一下，网页上就会显示。提到本机文件时写成 Markdown 链接（[名字](绝对路径)），网页上点得开。" +
  "给他做的网页（HTML）发到他的活页后，调 show_page 给他一张能点开的卡片（先调 page_target 问放哪）；" +
  "这台机器上没有活页工具时，show_page 的 status 填 unavailable，并告诉他。";

const PAGE_TOOLS = [
  { type: "function", name: "page_target",
    description: "Before publishing a web page you made for the person (an HTML file), ask where it goes: the LivePage folder and, for this file, the proposal_id it was published as before.",
    inputSchema: { type: "object", properties: { file: { type: "string", description: "absolute path of the HTML file" } }, required: ["file"] } },
  { type: "function", name: "show_page",
    description: "Show the person a card for a web page you published to their LivePage: they tap it to open the page.",
    inputSchema: { type: "object", required: ["title", "status"], properties: {
      title: { type: "string" }, url: { type: "string" }, status: { type: "string", enum: ["publishing", "review", "ready", "failed", "unavailable"] },
      proposal_id: { type: "string" }, version: { type: "number" }, file: { type: "string" }, folder_id: { type: "string" },
      preview: { type: "string" }, note: { type: "string" }, embed_url: { type: "string" }, embed_expires: { type: "string" } } } },
];

// "/bin/zsh -lc 'npm test'" → "npm test"
export function bareCommand(c) {
  const s = String(c || "");
  const m = s.match(/^\/bin\/(?:ba|z)?sh -l?c (?:'([\s\S]*)'|"([\s\S]*)")$/);
  return (m ? (m[1] != null ? m[1].replace(/'\\''/g, "'") : m[2].replace(/\\(["\\$`])/g, "$1")) : s).replace(/\s+/g, " ").trim();
}
const cut = (s, n) => (s.length > n ? s.slice(0, n) + "\n…" : s);

// one app-server item → the page's step, or null for what the page does not show
export function itemStep(it) {
  switch (it?.type) {
    case "commandExecution": return { name: "Shell", summary: `Shell · ${bareCommand(it.command).slice(0, 160)}` };
    case "fileChange": return { name: "Edit", summary: `Edit · ${(it.changes || []).map((c) => c.path).join(", ").slice(0, 160)}` };
    case "mcpToolCall": return { name: `${it.server}.${it.tool}`, summary: `${it.server} · ${it.tool}` };
    case "dynamicToolCall": return it.tool === "show_page"
      ? { name: CODEX_SHOW_PAGE, summary: `发到活页 · ${String(it.arguments?.title || "网页").slice(0, 120)}` }
      : { name: it.tool, summary: it.tool === "page_target" ? "活页 · 查这一页放哪" : String(it.tool) };
    case "webSearch": return { name: "WebSearch", summary: `WebSearch · ${String(it.query || "").slice(0, 160)}` };
    default: return null;
  }
}
// a finished item's result line: its output, and whether it failed
export function itemResult(it) {
  switch (it?.type) {
    case "commandExecution":
      return { text: cut(String(it.aggregatedOutput || ""), 4000) || (it.exitCode != null ? `exit ${it.exitCode}` : ""),
        error: it.status === "failed" || it.status === "declined" || (it.exitCode != null && it.exitCode !== 0) };
    case "fileChange":
      return { text: cut((it.changes || []).map((c) => `${c.path}\n${c.diff || ""}`).join("\n"), 4000), error: it.status !== "completed" };
    case "mcpToolCall":
      return { text: cut(it.error ? String(it.error.message || JSON.stringify(it.error))
        : (it.result?.content || []).map((b) => (b?.type === "text" ? b.text : "")).filter(Boolean).join("\n"), 4000), error: !!it.error };
    case "dynamicToolCall":
      return { text: (it.contentItems || []).map((b) => b?.text || "").join("\n").slice(0, 4000), error: it.success === false };
    case "webSearch": return { text: "", error: false };
    default: return null;
  }
}

// the pending JSON-RPC answers a person's choice becomes
export function approvalResponse(method, params, allow) {
  if (method === "item/permissions/requestApproval") {
    return allow ? { permissions: { ...(params.permissions?.network ? { network: params.permissions.network } : {}),
      ...(params.permissions?.fileSystem ? { fileSystem: params.permissions.fileSystem } : {}) }, scope: "turn" } : { permissions: {}, scope: "turn" };
  }
  if (allow) return { decision: "accept" };
  const avail = params.availableDecisions;
  return { decision: !Array.isArray(avail) || avail.includes("decline") ? "decline" : "cancel" };
}
export function askOf(method, params) {
  const id = String(params.itemId || "");
  if (method === "item/tool/requestUserInput") {
    return { kind: "question", id, questions: (params.questions || []).map((q) => ({ question: String(q.question || ""), header: q.header || undefined,
      options: (q.options || []).map((o) => ({ label: String(o.label || ""), ...(o.description ? { description: String(o.description) } : {}) })) })) };
  }
  const why = params.reason ? ` — ${String(params.reason).slice(0, 160)}` : "";
  if (method === "item/commandExecution/requestApproval") {
    return { kind: "permission", id, tool: "Shell", summary: `Shell · ${bareCommand(params.command).slice(0, 160)}${why}` };
  }
  if (method === "item/fileChange/requestApproval") {
    return { kind: "permission", id, tool: "Edit", summary: `Edit · ${params.grantRoot || ""}${why}`.replace(/ · $/, "") };
  }
  return { kind: "permission", id, tool: "Permissions", summary: `权限${why}` };
}
// a TurnError's words, where the proxy's 403 body rides (its message, its details)
const errorText = (e) => [String(e?.message || ""), String(e?.additionalDetails || "")];
const ASK_METHODS = new Set(["item/commandExecution/requestApproval", "item/fileChange/requestApproval",
  "item/permissions/requestApproval", "item/tool/requestUserInput"]);

// ---- Codex's own record of a thread (its rollout): the history a thread started in
// a terminal brings with it (task T810 「在 WebChat 里继续」), read the way the page
// shows a turn. <home>/sessions/YYYY/MM/DD/rollout-<ts>-<thread>.jsonl
export function findRollout(home, thread) {
  if (!THREAD_RE.test(thread)) return "";
  const root = join(home, "sessions");
  const dirs = (d) => { try { return readdirSync(d).filter((x) => /^\d+$/.test(x)).sort().reverse(); } catch { return []; } };
  for (const y of dirs(root)) for (const m of dirs(join(root, y))) for (const day of dirs(join(root, y, m))) {
    const dir = join(root, y, m, day);
    let names = []; try { names = readdirSync(dir); } catch { continue; }
    const hit = names.find((n) => n.startsWith("rollout-") && n.endsWith(`-${thread}.jsonl`));
    if (hit) return join(dir, hit);
  }
  return "";
}
const textOf = (c) => (Array.isArray(c) ? c.map((b) => (typeof b?.text === "string" ? b.text : "")).join("") : typeof c === "string" ? c : "");
const pathOf = (p) => String(p || "").replace(/^file:\/\//, "");
// its session_meta's cwd, and its items as the page's steps (images: their paths, kept by the caller)
export function rolloutRead(raw) {
  let cwd = "";
  const out = [];
  for (const l of String(raw).split("\n")) {
    if (!l) continue;
    let m; try { m = JSON.parse(l); } catch { continue; }
    const p = m.payload || {};
    if (m.type === "session_meta" && !cwd) cwd = String(p.cwd || "");
    if (m.type !== "event_msg" || p.type !== "item_completed" || !p.item) continue;
    const it = p.item;
    switch (it.type) {
      case "UserMessage": {
        const text = textOf((it.content || []).filter((b) => /^text$/i.test(b?.type || "")));
        const pics = (it.content || []).filter((b) => /image/i.test(b?.type || "") && (b.path || b.image_url || b.url)).map((b) => ({ path: pathOf(b.path || ""), url: b.image_url || b.url || "" }));
        if (text || pics.length) out.push({ t: "user", text, pics });
        break;
      }
      case "AgentMessage": { const d = textOf(it.content); if (d) out.push({ t: "text", d }); break; }
      case "CommandExecution": {
        const cmd = Array.isArray(it.command) ? it.command.at(-1) : String(it.command || "");
        out.push({ t: "tool", id: it.id, name: "Shell", summary: `Shell · ${bareCommand(cmd).slice(0, 160)}` });
        out.push({ t: "tool_result", id: it.id, text: cut(String(it.aggregated_output || ""), 4000) || (it.exit_code != null ? `exit ${it.exit_code}` : ""),
          error: it.status === "failed" || it.status === "declined" || (it.exit_code != null && it.exit_code !== 0) });
        break;
      }
      case "FileChange": {
        const ch = it.changes || {};
        const paths = Array.isArray(ch) ? ch.map((c) => c?.path).filter(Boolean) : Object.keys(ch);
        out.push({ t: "tool", id: it.id, name: "Edit", summary: `Edit · ${paths.join(", ").slice(0, 160)}` });
        out.push({ t: "tool_result", id: it.id, text: paths.join("\n"), error: !!it.status && it.status !== "completed" });
        break;
      }
      case "DynamicToolCall": {
        const st = itemStep({ type: "dynamicToolCall", tool: it.tool, arguments: it.arguments });
        out.push({ t: "tool", id: it.id, ...st });
        if (it.tool === "show_page") out.push({ t: "page_args", id: it.id, args: it.arguments || {} });
        out.push({ t: "tool_result", id: it.id, text: textOf(it.content_items), error: it.success === false });
        break;
      }
      case "McpToolCall": out.push({ t: "tool", id: it.id, name: `${it.server}.${it.tool}`, summary: `${it.server} · ${it.tool}` }); break;
      case "ImageView": out.push({ t: "image_path", path: pathOf(it.path) }); break;
      case "ImageGeneration": if (it.saved_path) out.push({ t: "image_path", path: pathOf(it.saved_path) }); break;
      default: break;
    }
  }
  return { cwd, items: out };
}

// the app-server over stdio: one process, line-delimited JSON-RPC
class AppServer {
  constructor(cmd, args, env, cwd, onMsg, onExit) {
    this.pend = new Map();
    this.seq = 0;
    this.p = spawn(cmd, args, { env, cwd, stdio: ["pipe", "pipe", "pipe"] });
    let buf = "";
    this.p.stdout.on("data", (d) => {
      buf += d;
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i);
        buf = buf.slice(i + 1);
        if (!line.trim()) continue;
        let m; try { m = JSON.parse(line); } catch { continue; }
        if (m.id != null && !m.method) {
          const p = this.pend.get(m.id);
          if (p) { this.pend.delete(m.id); clearTimeout(p.timer); m.error ? p.reject(new Error(m.error.message || "rpc error")) : p.resolve(m.result); }
        } else onMsg(m);
      }
    });
    this.err = "";
    this.p.stderr.on("data", (d) => { this.err = (this.err + d).slice(-2000); });
    this.p.on("error", (e) => { this.err = String(e?.message || e); });
    this.p.on("exit", (code) => {
      this.dead = true;
      for (const p of this.pend.values()) { clearTimeout(p.timer); p.reject(new Error(`codex app-server exited (${code}) ${this.err.trim().split("\n").pop() || ""}`.trim())); }
      this.pend.clear();
      onExit(code);
    });
    this.p.stdin.on("error", () => {});
  }
  write(m) { if (!this.dead) this.p.stdin.write(JSON.stringify(m) + "\n"); }
  call(method, params, ms = 120000) {
    if (this.dead) return Promise.reject(new Error("codex app-server is not running"));
    const id = ++this.seq;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pend.delete(id); reject(new Error(`${method}: no answer`)); }, ms);
      this.pend.set(id, { resolve, reject, timer });
      this.write({ id, method, params });
    });
  }
  reply(id, result) { this.write({ id, result }); }
  fail(id, message) { this.write({ id, error: { code: -32601, message } }); }
  kill() { if (!this.dead) this.p.kill("SIGTERM"); }
}

// d: what the server shares — see server.mjs's codexSide(...) call
export function codexSide(d) {
  const DIR = join(d.STATE, "codex");
  const CONV = join(d.STATE, "conversation-codex.json");
  const MODELS_FILE = join(d.STATE, "codex-models.json");
  let conv = { thread: "", cwd: d.CWD, put_away: [], last: "", model: "" };
  try { conv = { ...conv, ...JSON.parse(readFileSync(CONV, "utf8")) }; } catch { /* a first start */ }
  let models = [];
  try { models = JSON.parse(readFileSync(MODELS_FILE, "utf8")); } catch { /* none read yet */ }
  const save = () => { writeFileSync(CONV + ".tmp", JSON.stringify(conv), { mode: 0o600 }); renameSync(CONV + ".tmp", CONV); };
  let srv = null, srvP = null, cred = null, idleT = null, live = null, ridSeq = 0;

  const available = () => !!d.CODEX && existsSync(d.CODEX);
  const record = (thread) => join(DIR, `${thread}.ndjson`);
  const keep = (thread, items) => {
    if (!thread || !items.length) return;
    try {
      mkdirSync(DIR, { recursive: true, mode: 0o700 });
      writeFileSync(record(thread), items.map((x) => JSON.stringify(x)).join("\n") + "\n", { flag: "a", mode: 0o600 });
    } catch (e) { d.log("codex_record_failed", { msg: String(e?.message || e).slice(0, 200) }); }
  };

  async function mint() {
    const sid = `web-codex-${process.pid}-${Date.now().toString(36)}`;
    const on = await d.run(d.SESSION_CRED, ["on"]);
    if (on.rc !== 0) return { sid, mint: null };
    const m = await d.run(d.SESSION_CRED, ["mint", "--provider", "codex", "--sid", sid], { FLEET_SESSION_WRAP: String(process.pid) });
    if (m.rc === 3 || m.rc === 4) return { sid, mint: null };
    const mint = m.rc === 0 ? d.parseMint(m.stdout) : null;
    if (!mint) throw new Error(`no session credential from the proxy (rc ${m.rc}) — fleet-cred-proxy.sh status`);
    d.liveCreds.add(mint.cred);
    const h = await d.run(d.SESSION_CRED, ["codex-home", "--sid", sid, "--real", d.E.CODEX_HOME || join(d.E.HOME || "", ".codex")]);
    const home = h.stdout.trim();
    if (h.rc !== 0 || !home) { await revoke({ sid, mint }); throw new Error("could not make a credential-free CODEX_HOME"); }
    return { sid, mint, home };
  }
  async function revoke(c) {
    if (!c?.mint) return;
    await d.run(d.SESSION_CRED, ["revoke", "--sid", c.sid]);
    d.liveCreds.delete(c.mint.cred);
  }

  function start() {
    if (srv && !srv.dead) return Promise.resolve(srv);
    if (srvP) return srvP;
    srvP = (async () => {
      if (!available()) throw new Error("Codex is not installed on this machine");
      cred = await mint();
      const env = { ...d.E };
      for (const k of ["FLEET_CODEX_SESSION_CRED", "OPENAI_API_KEY", "TMUX", "TMUX_PANE", "FLEET_WORKER_CRED", "FLEET_WORKER_ASSERT"]) delete env[k];
      const args = ["-c", "features.apps=false", "-c", "analytics.enabled=false"];
      if (cred.mint) {
        env.CODEX_HOME = cred.home;
        env.FLEET_CODEX_SESSION_CRED = cred.mint.cred;
        args.push("-c", 'model_provider="fleet"', "-c",
          `model_providers.fleet={name="fleet",base_url="http://127.0.0.1:${cred.mint.port}/codex",env_key="FLEET_CODEX_SESSION_CRED",wire_api="responses"}`,
          "-c", "features.plugins=false");
      }
      const s = new AppServer(d.CODEX, [...args, "app-server"], env, conv.cwd && existsSync(conv.cwd) ? conv.cwd : d.CWD, onMsg, (code) => {
        d.log("codex_exit", { code });
        if (srv === s) srv = null;
        if (live) endTurn({ t: "error", msg: "Codex 意外退出了，再说一次试试" });
        const c = cred; cred = null; revoke(c).catch(() => {});
      });
      await s.call("initialize", { clientInfo: { name: "fleet_webchat", title: "fleet webchat", version: "1" }, capabilities: { experimentalApi: true } }, 30000);
      s.write({ method: "initialized" });
      srv = s;
      d.log("codex_start", { route: cred.mint ? cred.mint.route : "ambient" });
      readModels(s).catch(() => {});
      return s;
    })().finally(() => { srvP = null; });
    return srvP;
  }
  function idle() {
    clearTimeout(idleT);
    idleT = setTimeout(() => { if (!live && srv) { d.log("codex_idle_close"); srv.kill(); } }, d.WARM_IDLE_MS);
    idleT.unref?.();
  }
  async function readModels(s) {
    const r = await s.call("model/list", {}, 30000);
    const list = (r?.data || []).filter((m) => !m.hidden).map((m) => ({ id: String(m.model || m.id), label: String(m.displayName || m.model), ...(m.isDefault ? { default: true } : {}) }));
    if (!list.length) return;
    models = list;
    try { writeFileSync(MODELS_FILE, JSON.stringify(models), { mode: 0o600 }); } catch { /* next time */ }
  }
  const defaultModel = () => (models.find((m) => m.default) || models[0])?.id || "";

  // ---- one turn's stream ---------------------------------------------------------
  function emit(o) {
    if (!live) return;
    const line = d.redactLine(o) + "\n";
    for (const res of live.listeners) if (!res.writableEnded) res.write(line);
  }
  function show(o, keepIt = true) { emit(o); if (keepIt && live) live.kept.push(o); }
  function endTurn(last) {
    if (!live) return;
    const t = live;
    clearTimeout(t.hardT);
    if (last) show(last, last.t === "stopped" || last.code === "budget");
    for (const a of t.asks.values()) a.done(false);
    keep(t.thread, t.kept);
    if (t.thread) { conv.last = t.tid; save(); }
    live = null;
    for (const r of t.listeners) if (!r.writableEnded) r.end();
    d.log("turn_end", { provider: "codex", thread: t.thread, status: last?.t || "" });
    t.resolve();
    d.touch();
    idle();
  }
  function onImageFile(path, extra = {}) {
    try {
      const real = realpathSync(String(path));
      const ext = real.toLowerCase().split(".").pop().replace("jpeg", "jpg");
      const mime = d.IMAGE_EXT_MIME[ext];
      if (!mime) return;
      for (const it of d.imageItems([{ type: "image", source: { type: "base64", media_type: mime, data: readFileSync(real).toString("base64") } }], extra)) {
        show(++live.images > d.IMAGES_PER_REPLY ? { t: "image_more", n: 1 } : it);
      }
    } catch { /* gone */ }
  }

  function onMsg(m) {
    if (m.id != null && m.method) return onRequest(m);
    const p = m.params || {};
    if (!live || (p.threadId && p.threadId !== live.thread)) return;
    switch (m.method) {
      case "turn/started": live.turnId = p.turn?.id || live.turnId; return;
      case "item/agentMessage/delta":
        if (!live.delta.has(p.itemId)) { live.delta.add(p.itemId); if (live.texted) emit({ t: "text", d: "\n\n" }); }
        if (p.delta) { emit({ t: "text", d: p.delta }); live.texted = true; }
        return;
      case "item/started": {
        const it = p.item || {};
        const st = itemStep(it);
        if (st) {
          show({ t: "tool", id: it.id, ...st });
          if (it.type === "dynamicToolCall" && it.tool === "show_page") show(d.pageItem(it.id, it.arguments, conv.cwd || d.CWD));
        }
        return;
      }
      case "item/completed": {
        const it = p.item || {};
        if (it.type === "agentMessage") {
          const text = String(it.text || "");
          if (!text) return;
          if (!live.delta.has(it.id)) { emit({ t: "text", d: (live.texted ? "\n\n" : "") + text }); live.texted = true; }
          live.kept.push({ t: "text", d: text + "\n\n" });
          const files = d.filesOf(text, conv.cwd || d.CWD);
          if (files) { show({ t: "files", files }); d.saveRefs(); }
          return;
        }
        if (it.type === "imageView") return onImageFile(it.path);
        if (it.type === "imageGeneration") {
          if (it.savedPath) return onImageFile(it.savedPath);
          if (it.result && /^[A-Za-z0-9+/=\s]+$/.test(it.result)) {
            for (const g of d.imageItems([{ type: "image", source: { type: "base64", media_type: "image/png", data: it.result } }])) show(g);
          }
          return;
        }
        const r = itemResult(it);
        if (r) {
          show({ t: "tool_result", id: it.id, ...r });
          if (it.type === "mcpToolCall") for (const b of it.result?.content || []) {
            if (b?.type === "image" && b.data) for (const g of d.imageItems([{ type: "image", source: { type: "base64", media_type: b.mimeType || "image/png", data: b.data } }], { id: it.id })) show(g);
          }
        }
        return;
      }
      case "error": {
        const b = d.budgetRefusal(errorText(p.error));
        if (b) return budgetEnd(b);
        if (!p.willRetry) live.err = String(p.error?.message || "Codex 出错了").slice(0, 500);
        return;
      }
      case "turn/completed": {
        const t = p.turn || {};
        const b = t.error ? d.budgetRefusal(errorText(t.error)) : null;
        if (b) return budgetEnd(b);
        if (t.status === "completed") {
          if (d.budget()) d.setBudget(null);
          return endTurn({ t: "done", subtype: "success", ...(t.durationMs ? { ms: t.durationMs } : {}) });
        }
        if (t.status === "interrupted" || live.stopping) return endTurn({ t: "stopped" });
        return endTurn({ t: "error", msg: String(t.error?.message || live.err || "Codex 没能完成这一轮").slice(0, 500) });
      }
    }
  }
  function budgetEnd(b) {
    d.setBudget({ msg: b.msg, ...(b.until ? { until: b.until } : {}), at: new Date().toISOString() });
    d.log("budget", { provider: "codex", until: b.until || "" });
    const t = live;
    if (t?.turnId && srv) srv.call("turn/interrupt", { threadId: t.thread, turnId: t.turnId }, 10000).catch(() => {});
    endTurn({ t: "error", code: "budget", msg: b.msg, ...(b.until ? { until: b.until } : {}) });
  }

  async function onRequest(m) {
    const s = srv, p = m.params || {};
    if (!s) return;
    if (m.method === "item/tool/call") {
      const args = p.arguments || {};
      if (p.tool === "page_target") {
        return s.reply(m.id, { success: true, contentItems: [{ type: "inputText", text: JSON.stringify(d.pageTarget(args.file)) }] });
      }
      if (p.tool === "show_page") {
        d.pageShown(args);
        return s.reply(m.id, { success: true, contentItems: [{ type: "inputText", text: "shown to the person as a card" }] });
      }
      return s.reply(m.id, { success: false, contentItems: [{ type: "inputText", text: `no tool ${p.tool}` }] });
    }
    if (m.method === "mcpServer/elicitation/request") return s.reply(m.id, { action: "decline", content: null, _meta: null });
    if (!ASK_METHODS.has(m.method)) return s.fail(m.id, `not handled by the web chat: ${m.method}`);
    if (!live) return s.reply(m.id, m.method === "item/tool/requestUserInput" ? { answers: {} } : approvalResponse(m.method, p, false));
    const rid = `c${++ridSeq}-${d.newSecret(6)}`;
    const ask = askOf(m.method, p);
    const t = live;
    await new Promise((resolve) => {
      const done = (v, answers) => {
        clearTimeout(timer);
        if (!t.asks.has(rid)) return;
        t.asks.delete(rid);
        if (m.method === "item/tool/requestUserInput") {
          const out = {};
          for (const q of p.questions || []) {
            const a = answers?.[q.question];
            out[q.id] = { answers: a == null ? [] : String(a).split(", ").filter(Boolean) };
          }
          s.reply(m.id, { answers: out });
        } else s.reply(m.id, approvalResponse(m.method, p, !!v));
        resolve();
      };
      const timer = setTimeout(() => done(false), d.ASK_TIMEOUT_MS);
      t.asks.set(rid, { ask, done });
      emit({ t: "ask", rid, ...ask });
    });
  }

  // ---- what the server's routes call ------------------------------------------------
  const realHome = () => d.E.CODEX_HOME || join(d.E.HOME || "", ".codex");
  const rollouts = new Map();                             // thread → its rollout file
  function rolloutFile(thread) {
    let f = rollouts.get(thread);
    if (!f || !existsSync(f)) { f = findRollout(realHome(), thread); if (f) rollouts.set(thread, f); }
    return f;
  }
  // a rollout's steps for the page: images and page cards made real
  function fromRollout(list, cwd) {
    const out = [];
    const img = (path, extra = {}) => {
      try {
        const real = realpathSync(path);
        const mime = d.IMAGE_EXT_MIME[real.toLowerCase().split(".").pop().replace("jpeg", "jpg")];
        if (mime) out.push(...d.imageItems([{ type: "image", source: { type: "base64", media_type: mime, data: readFileSync(real).toString("base64") } }], extra));
      } catch { /* gone */ }
    };
    for (const o of list) {
      if (o.t === "user") {
        const n = out.length;
        for (const g of o.pics) if (g.path) img(g.path);
        const pics = out.splice(n).filter((g) => g.ref).map(({ ref, w, h }) => ({ ref, w, h }));
        out.push({ t: "user", text: o.text, ...(pics.length ? { images: pics } : {}) });
      } else if (o.t === "image_path") img(o.path);
      else if (o.t === "page_args") out.push(d.pageItem(o.id, o.args, cwd));
      else {
        out.push(o);
        if (o.t === "text") { const files = d.filesOf(o.d, cwd); if (files) out.push({ t: "files", files }); }
      }
    }
    return out;
  }
  async function items() {
    if (!conv.thread) return [];
    // Codex's own record first (it holds what a terminal said too); ours where there is none
    const rf = rolloutFile(conv.thread);
    if (rf) {
      try {
        const r = rolloutRead(await fsp.readFile(rf, "utf8"));
        const out = fromRollout(r.items, conv.cwd || r.cwd || d.CWD);
        d.saveRefs();
        return d.capImages(out);
      } catch { /* fall back to ours */ }
    }
    let raw = "";
    try { raw = await fsp.readFile(record(conv.thread), "utf8"); } catch { return []; }
    const out = [];
    for (const l of raw.split("\n")) {
      if (!l) continue;
      let o; try { o = JSON.parse(l); } catch { continue; }
      if (o.t === "text" && out.at(-1)?.t === "text") out.at(-1).d += o.d; else out.push(o);
    }
    for (const o of out) if (o.t === "text") o.d = o.d.replace(/\n+$/, "");
    return d.capImages(out);
  }
  async function conversation() {
    if (available() && !models.length) start().then(() => idle()).catch(() => {});
    const owner = conv.thread ? await d.owner(conv.thread) : null;
    return { provider: "codex", session: conv.thread, cwd: conv.cwd, busy: !!live, turn: live?.tid || "", last: conv.last,
      ...(owner ? { owner } : {}), ...(conv.handed && !owner ? { handed: conv.handed } : {}),
      asks: live ? [...live.asks.entries()].map(([rid, a]) => ({ t: "ask", rid, ...a.ask })) : [],
      models, default: conv.model && models.some((x) => x.id === conv.model) ? conv.model : defaultModel(),
      budget: d.budgetView(), items: (await items()).slice(-600) };
  }
  // body: the parsed request (text, model, images as Claude's blocks already checked)
  async function turn(res, { text, model, images, person }) {
    if (live) return d.send(res, 409, { error: "还在回复上一句" });
    if (!available()) return d.send(res, 503, { error: "这台机器上没有 Codex" });
    if (conv.thread && d.holder(conv.thread) === "terminal") return d.send(res, 409, { error: "这段对话在终端里", code: "terminal" });
    if (model && models.length && !models.some((m) => m.id === model)) return d.send(res, 400, { error: "model not allowed" });
    const tid = d.newSecret(9);
    let resolve;
    const ended = new Promise((r) => { resolve = r; });
    live = { tid, thread: conv.thread, turnId: "", listeners: new Set([res]), asks: new Map(), kept: [], delta: new Set(), images: 0, resolve };
    clearTimeout(idleT);
    res.writeHead(200, { "Content-Type": "application/x-ndjson; charset=utf-8", "Cache-Control": "no-store",
      "X-Accel-Buffering": "no", "X-Content-Type-Options": "nosniff" });
    res.on("close", () => live?.listeners.delete(res));
    emit({ t: "turn", id: tid, model: model || "" });
    d.log("turn", { provider: "codex", person, model: model || "" });
    // the person's own line, with the pictures they sent (kept as media refs)
    const pics = [];
    const input = [];
    for (const b of images) {
      const k = d.keepImage(b);
      if (k?.ref) { pics.push({ ref: k.ref, w: k.w, h: k.h }); input.push({ type: "localImage", path: join(d.MEDIA, k.ref) }); }
    }
    if (text) input.unshift({ type: "text", text, text_elements: [] });
    live.kept.push({ t: "user", text, ...(pics.length ? { images: pics } : {}) });
    try {
      const s = await start();
      const opts = { approvalPolicy: "on-request", sandbox: "workspace-write", ...(model ? { model } : {}) };
      if (conv.thread && THREAD_RE.test(conv.thread)) {
        try { await s.call("thread/resume", { threadId: conv.thread, ...opts, excludeTurns: true }, 60000); }
        catch (e) { d.log("codex_resume_failed", { msg: String(e?.message || e).slice(0, 200) }); conv.thread = ""; }
      }
      if (!conv.thread) {
        const r = await s.call("thread/start", { cwd: conv.cwd || d.CWD, ...opts, developerInstructions: CODEX_NOTE, dynamicTools: PAGE_TOOLS }, 60000);
        conv.thread = String(r?.thread?.id || "");
        if (!THREAD_RE.test(conv.thread)) throw new Error("codex app-server gave no thread");
        save();
      }
      if (!live) return;
      live.thread = conv.thread;
      emit({ t: "session", id: conv.thread, cwd: conv.cwd });
      if (model) conv.model = model;
      if (conv.handed) delete conv.handed;               // said once: the first turn here ends it
      save();
      const r = await s.call("turn/start", { threadId: conv.thread, input, ...(model ? { model } : {}) }, 60000);
      if (live?.tid === tid) live.turnId = live.turnId || String(r?.turn?.id || "");
      if (live?.tid === tid && live.stopping) s.call("turn/interrupt", { threadId: live.thread, turnId: live.turnId }, 10000).catch(() => {});
    } catch (e) {
      const b = d.budgetRefusal([String(e?.message || "")]);
      if (live?.tid === tid) {
        if (b) budgetEnd(b);
        else endTurn(live.stopping ? { t: "stopped" } : { t: "error", msg: String(e?.message || e).slice(0, 500) });
      }
      d.log("turn_error", { provider: "codex", msg: String(e?.message || e).slice(0, 300) });
    }
    return ended;
  }
  async function stop(turnTid) {
    if (!live || turnTid !== live.tid) return false;
    live.stopping = true;
    for (const a of live.asks.values()) a.done(false);
    if (live.turnId && srv) {
      try { await srv.call("turn/interrupt", { threadId: live.thread, turnId: live.turnId }, 10000); }
      catch { if (live) endTurn({ t: "stopped" }); }
    }
    return true;
  }
  function answer(body) {
    const a = live?.asks.get(String(body.rid || ""));
    if (!a) return false;
    if (a.ask.kind === "question") a.done(true, body.answers || {}); else a.done(!!body.allow);
    return true;
  }
  // 新对话: the thread is put away (its record kept), the next turn starts a new one
  function newConversation() {
    if (live) return false;
    if (conv.thread) conv.put_away = [...(conv.put_away || []), { thread: conv.thread, at: new Date().toISOString() }].slice(-200);
    conv.thread = ""; conv.last = "";
    save();
    d.log("new_conversation", { provider: "codex" });
    return true;
  }
  // the terminal ⇄ this page (task T810)
  const state = () => ({ busy: !!live, session: conv.thread });
  // the terminal took this thread back: let go of the app-server that has it open
  function release(thread) {
    if (thread && thread === conv.thread && !live && srv) { d.log("codex_release"); srv.kill(); }
  }
  // 在 WebChat 里继续: the terminal's thread becomes this side's conversation; the
  // one it had is put away and kept (新对话's rule) → [code, msg, why?]
  function adopt(body) {
    const id = String(body?.session || "");
    if (!THREAD_RE.test(id)) return [400, "not a thread id"];
    if (live) return [409, "还在回复上一句", "busy"];
    if (id === conv.thread) return [200, "already"];
    const rf = rolloutFile(id);
    if (!rf) return [404, "no Codex record for this thread here"];
    let cwd = "";
    try { cwd = rolloutRead(readFileSync(rf, "utf8")).cwd; } catch { /* the home then */ }
    if (conv.thread) conv.put_away = [...(conv.put_away || []), { thread: conv.thread, at: new Date().toISOString() }].slice(-200);
    const label = String(body?.label || "").slice(0, 80);
    conv = { ...conv, thread: id, cwd: cwd || d.CWD, last: "", handed: { from: "terminal", label, at: new Date().toISOString() } };
    save();
    if (srv && !live) srv.kill();                        // the next turn resumes it in its own directory
    d.log("adopted", { provider: "codex", label, machine: String(body?.machine || "").slice(0, 60) });
    return [200, "adopted"];
  }
  // 只读 view of a terminal's Codex session (task F481): its rollout, and its
  // lines read as the page's steps — a chunk at a time, as the file grows
  function viewFile(thread) {
    const f = rolloutFile(thread);
    return f ? { file: f, cwd: "" } : null;
  }
  function viewItems(lines, cwd) {
    const r = rolloutRead(lines.join("\n"));
    const out = fromRollout(r.items, cwd || r.cwd || d.CWD);
    d.saveRefs();
    return { items: out, cwd: r.cwd };
  }
  function close() { clearTimeout(idleT); srv?.kill(); const c = cred; cred = null; return revoke(c); }
  return { available, conversation, turn, stop, answer, newConversation, close, state, release, adopt, viewFile, viewItems,
    busy: () => !!live, last: () => conv.last, side: () => ({ busy: !!live, last: conv.last }) };
}
