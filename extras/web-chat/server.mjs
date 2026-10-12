#!/usr/bin/env node
// server.mjs — talk to a Claude session from a browser, the smallest version
// (issue #3567). Run by bin/fleet-webchat.sh as THIS login, never anyone else's.
//
//   * Binds 127.0.0.1 only — there is no option to widen it (CLAUDE.md: a temp
//     server binds loopback). The person reaches it over their own ssh forward
//     (fleet-open) or the tailnet name they put in front of it (tailscale serve).
//   * Only this login's person comes in: a ONE-TIME login link (10 min) minted by
//     `fleet-webchat.sh link`, which proves itself with admin.token — a 0600 file
//     in this login's 0700 state dir, so another login on the machine cannot mint
//     one. The link sets an HttpOnly SameSite=Strict cookie; everything else
//     without it is 403. A Host the server does not know is refused (rebinding).
//   * Each turn runs the Agent SDK's query() on this login's own `claude`, with a
//     SESSION credential minted for that turn by bin/fleet-session-cred.sh — the
//     pool's credential proxy picks the account and meters the usage, the same
//     road a fleet session's claude takes (bin/fleet-claude.sh). The credential
//     lives in the child's environment only: never a response, a log or a file.
//   * ONE conversation per person, no list (the 发起人's call on #3567): the page
//     is always that conversation, history above. Its session id lives in
//     conversation.json here; every turn resumes it. When its context nears full
//     the server compacts it (Claude Code's own /compact) between turns; if that
//     fails it relays to a new session seeded with the old one's tail and keeps
//     the old id in `chain`, so the page still reads as one conversation. A
//     restart or a dropped page resumes the same one.
//   * It is Claude Code's own transcript (~/.claude/projects/…): the terminal can
//     read it — `claude --resume <id>` from its directory.
import http from "node:http";
import { execFile } from "node:child_process";
import { promises as fsp, readFileSync, writeFileSync, mkdirSync, chmodSync, existsSync, realpathSync, renameSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { COOKIE, CODE_TTL_MS, COOKIE_TTL_S, newSecret, sha, sameSecret, parseCookies,
  hostAllowed, redact, agentEnv, parseMint, toolSummary, MODELS, DEFAULT_MODEL, modelAllowed } from "./lib.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const E = process.env;
const STATE = E.FLEET_WEBCHAT_STATE;
if (!STATE) { console.error("fleet-webchat: FLEET_WEBCHAT_STATE is not set"); process.exit(2); }
mkdirSync(STATE, { recursive: true, mode: 0o700 });
chmodSync(STATE, 0o700);
const BIND = "127.0.0.1";                              // never configurable
const HOSTS = (E.FLEET_WEBCHAT_HOSTS || "").split(",").map((s) => s.trim()).filter(Boolean);
const CWD = E.FLEET_WEBCHAT_CWD || E.HOME;
const CLAUDE = E.FLEET_WEBCHAT_CLAUDE || "";
const SESSION_CRED = E.FLEET_WEBCHAT_SESSION_CRED || join(HERE, "../../bin/fleet-session-cred.sh");
const SDK_PATH = E.FLEET_WEBCHAT_SDK || "";
const ASK_TIMEOUT_MS = Number(E.FLEET_WEBCHAT_ASK_SECS || 1800) * 1000;
const COMPACT_AT = Number(E.FLEET_WEBCHAT_COMPACT_AT || 0.8);  // the context share that triggers a compact
const PROJECTS = join(E.CLAUDE_CONFIG_DIR || join(E.HOME || "", ".claude"), "projects");
const PAGE = readFileSync(join(HERE, "index.html"));

// ---- the state dir: admin token, cookies (hashed), log ----------------------
const ADMIN = newSecret();
writeFileSync(join(STATE, "admin.token"), ADMIN + "\n", { mode: 0o600 });
chmodSync(join(STATE, "admin.token"), 0o600);
const COOKIES_FILE = join(STATE, "cookies.json");
let cookies = {};                                        // sha256(cookie) → expiry ms
try { cookies = JSON.parse(readFileSync(COOKIES_FILE, "utf8")) || {}; } catch { cookies = {}; }
const saveCookies = () => writeFileSync(COOKIES_FILE, JSON.stringify(cookies), { mode: 0o600 });
const codes = new Map();                                 // sha256(code) → expiry ms (memory only)
const liveCreds = new Set();                             // what redact() must also catch

function log(ev, f = {}) {
  const line = redact(JSON.stringify({ ts: new Date().toISOString(), ev, ...f }), [...liveCreds, ADMIN]);
  fsp.appendFile(join(STATE, "server.log"), line + "\n", { mode: 0o600 }).catch(() => {});
}

// ---- the SDK, loaded on the first turn (the page and the gate need none) -----
let sdkP = null;
function sdk() {
  if (!sdkP) {
    if (!SDK_PATH || !existsSync(SDK_PATH)) {
      return Promise.reject(new Error("Agent SDK not installed (fleet-webchat.sh start installs it)"));
    }
    sdkP = import(pathToFileURL(SDK_PATH).href);
  }
  return sdkP;
}

// ---- the session credential: one per turn, revoked when the turn ends -------
let turnSeq = 0;
function run(cmd, args, extraEnv = {}) {
  return new Promise((resolve) => {
    execFile("bash", [cmd, ...args], { env: { ...E, ...extraEnv }, timeout: 30000 },
      (err, stdout, stderr) => resolve({ rc: err ? (typeof err.code === "number" ? err.code : 1) : 0, stdout, stderr }));
  });
}
async function mintCred() {
  const sid = `web-${process.pid}-${++turnSeq}`;
  const on = await run(SESSION_CRED, ["on"]);
  if (on.rc !== 0) return { sid, mint: null, route: "off" };
  const m = await run(SESSION_CRED, ["mint", "--provider", "claude", "--sid", sid],
    { FLEET_SESSION_WRAP: String(process.pid) });
  if (m.rc === 4 || m.rc === 3) return { sid, mint: null, route: "ambient" };
  const mint = m.rc === 0 ? parseMint(m.stdout) : null;
  if (!mint) throw new Error(`no session credential from the proxy (rc ${m.rc}) — fleet-cred-proxy.sh status`);
  liveCreds.add(mint.cred);
  return { sid, mint, route: mint.route };
}
async function revokeCred(c) {
  if (!c?.mint) return;
  await run(SESSION_CRED, ["revoke", "--sid", c.sid]);
  liveCreds.delete(c.mint.cred);
}

// ---- http helpers -----------------------------------------------------------
function send(res, code, body, type = "application/json; charset=utf-8", headers = {}) {
  const b = typeof body === "string" || Buffer.isBuffer(body) ? body : JSON.stringify(body);
  res.writeHead(code, { "Content-Type": type, "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer", "X-Frame-Options": "DENY", ...headers });
  res.end(redact(b, [...liveCreds, ADMIN]));
}
async function readJson(req, max = 256 * 1024) {
  let n = 0; const parts = [];
  for await (const c of req) { n += c.length; if (n > max) throw new Error("too large"); parts.push(c); }
  return parts.length ? JSON.parse(Buffer.concat(parts).toString("utf8")) : {};
}
function authed(req) {
  const c = parseCookies(req.headers.cookie)[COOKIE];
  if (!c) return false;
  const exp = cookies[sha(c)];
  return typeof exp === "number" && exp > Date.now();
}
const DENY_PAGE = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>fleet 对话</title><body style="font:16px -apple-system,sans-serif;padding:2em;max-width:30em">
<h2>需要登录链接</h2><p>这个页面只给本机这个登录的人用。在你自己的终端里运行
<code>fleet-webchat.sh link</code>，用它给的一次性链接进入。</p></body>`;


// ---- transcripts → the page's items ------------------------------------------
const SEED_RE = /^<fleet-webchat-relay>[\s\S]*?<\/fleet-webchat-relay>\s*/;
function blocks(content) { return typeof content === "string" ? [{ type: "text", text: content }] : Array.isArray(content) ? content : []; }
function resultText(c) {
  const t = typeof c === "string" ? c : blocks(c).map((b) => b.text || "").join("\n");
  return t.length > 4000 ? t.slice(0, 4000) + "\n…" : t;
}
const mangle = (p) => p.replace(/[^A-Za-z0-9]/g, "-");      // fleet_mangle_path's rule
function transcriptPath(id, cwd) {
  let real = cwd;
  try { real = realpathSync(cwd); } catch { /* keep it */ }
  return join(PROJECTS, mangle(real), `${id}.jsonl`);
}
// every user/assistant entry in file order — the whole file, so what came before a
// compact stays on the page (the SDK's reader follows the post-compact chain only)
async function readItems(id, cwd) {
  let raw = "";
  try { raw = await fsp.readFile(transcriptPath(id, cwd), "utf8"); } catch { return []; }
  const out = [];
  for (const line of raw.split("\n")) {
    if (!line) continue;
    let m; try { m = JSON.parse(line); } catch { continue; }
    if ((m.type !== "user" && m.type !== "assistant") || m.isSidechain || m.isMeta || m.isCompactSummary) continue;
    for (const b of blocks(m.message?.content)) {
      if (m.type === "user" && b.type === "text" && b.text && !/^\s*<(command|local-command|system-reminder)/.test(b.text)) {
        const text = b.text.replace(SEED_RE, "");
        if (text) out.push({ t: "user", text });
      } else if (m.type === "assistant" && b.type === "text" && b.text) out.push({ t: "text", d: b.text });
      else if (m.type === "assistant" && b.type === "tool_use") out.push({ t: "tool", id: b.id, name: b.name, summary: toolSummary(b.name, b.input) });
      else if (m.type === "user" && b.type === "tool_result") out.push({ t: "tool_result", id: b.tool_use_id, text: resultText(b.content), error: !!b.is_error });
    }
  }
  return out;
}
async function conversationItems() {
  const out = [];
  for (const s of conv.chain) out.push(...await readItems(s.id, s.cwd));
  if (conv.session) out.push(...await readItems(conv.session, conv.cwd));
  return out;
}

// ---- the one conversation ------------------------------------------------------
const CONV_FILE = join(STATE, "conversation.json");
let conv = { session: "", cwd: CWD, chain: [], seed: "", ctx: { used: 0, window: 0 } };
try { conv = { ...conv, ...JSON.parse(readFileSync(CONV_FILE, "utf8")) }; } catch { /* a first start */ }
function saveConv() {
  writeFileSync(CONV_FILE + ".tmp", JSON.stringify(conv), { mode: 0o600 });
  renameSync(CONV_FILE + ".tmp", CONV_FILE);
}
let live = null;          // the running turn: { tid, ac, listeners, asks, model }
let maint = null;         // a compact / relay between turns (the next turn waits for it)
let ridSeq = 0;

// One query() through a fresh session credential; onMsg sees every SDK message.
async function runQuery(prompt, { model, resume, cwd, ac, canUseTool }, onMsg) {
  const S = await sdk();
  const cred = await mintCred();
  log("query", { cred_sid: cred.sid, route: cred.route, model, resume: !!resume });
  try {
    const q = S.query({ prompt, options: {
      cwd, resume: resume || undefined, model, env: agentEnv(E, cred.mint), includePartialMessages: true,
      permissionMode: "default", settingSources: ["user", "project", "local"], canUseTool,
      abortController: ac, ...(CLAUDE ? { pathToClaudeCodeExecutable: CLAUDE } : {}),
      stderr: () => {},                    // the child's stderr is never relayed or logged
    } });
    for await (const m of q) {
      if (m.session_id && !resume && !conv.session) { conv.session = m.session_id; conv.cwd = cwd; saveConv(); }
      if (m.type === "assistant" && m.message?.usage) {
        const u = m.message.usage;
        conv.ctx.used = (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0);
      }
      if (m.type === "result") {
        for (const mu of Object.values(m.modelUsage || {})) if (mu?.contextWindow) conv.ctx.window = mu.contextWindow;
      }
      if (m.type === "system" && m.subtype === "compact_boundary") {
        conv.ctx.used = m.compact_metadata?.post_tokens || 0;
        log("compacted", { trigger: m.compact_metadata?.trigger, pre: m.compact_metadata?.pre_tokens });
      }
      onMsg(m);
    }
  } finally {
    await revokeCred(cred);
    saveConv();
  }
}

// Between turns, out of sight: compact the conversation; failing that, relay to a
// new session seeded with the old one's tail. The page never sees either.
function maintain(why) {
  if (maint) return maint;
  maint = (async () => {
    log("maintain", { why, used: conv.ctx.used, window: conv.ctx.window });
    let ok = false;
    try {
      await runQuery("/compact", { model: DEFAULT_MODEL, resume: conv.session, cwd: conv.cwd, ac: new AbortController() },
        (m) => { if (m.type === "system" && m.subtype === "compact_boundary") ok = true; });
    } catch (e) { log("compact_failed", { msg: String(e?.message || e).slice(0, 200) }); }
    if (!ok) await relay();
  })().finally(() => { maint = null; });
  return maint;
}
async function relay() {
  const items = await readItems(conv.session, conv.cwd);
  let tail = "";
  for (const it of items.slice().reverse()) {
    const line = it.t === "user" ? `用户：${it.text}` : it.t === "text" ? `助手：${it.d}` : "";
    if (!line) continue;
    if (tail.length + line.length > 8000) break;
    tail = line + "\n" + tail;
  }
  log("relay", { from: conv.session });
  if (conv.session) conv.chain.push({ id: conv.session, cwd: conv.cwd });
  conv.session = "";
  conv.seed = `<fleet-webchat-relay>\n（这是同一段对话的接续：之前的会话太长，下面是它最后的部分，请接着它继续，不必提起这次接续。）\n${tail}</fleet-webchat-relay>\n\n`;
  conv.ctx = { used: 0, window: conv.ctx.window };
  saveConv();
}
const TOO_LONG = /prompt is too long|context (?:window|length)|too many tokens/i;

// ---- a turn: NDJSON lines to every page that is watching ----------------------
function emitAll(o) {
  if (!live) return;
  const line = redact(JSON.stringify(o), [...liveCreds, ADMIN]) + "\n";
  for (const res of live.listeners) if (!res.writableEnded) res.write(line);
}
function askEvent(rid, a) {
  return a.name === "AskUserQuestion"
    ? { t: "ask", rid, kind: "question", questions: a.input.questions || [] }
    : { t: "ask", rid, kind: "permission", tool: a.name, summary: toolSummary(a.name, a.input) };
}

async function turn(req, res) {
  const body = await readJson(req);
  const text = String(body.text || "").trim();
  const model = body.model == null || body.model === "" ? DEFAULT_MODEL : String(body.model);
  if (!modelAllowed(model)) { log("model_refused", { model: model.slice(0, 64) }); return send(res, 400, { error: "model not allowed" }); }
  if (!text) return send(res, 400, { error: "empty" });
  if (live) return send(res, 409, { error: "还在回复上一句" });
  const S = await sdk().catch((e) => e);
  if (S instanceof Error) return send(res, 503, { error: S.message });

  const tid = newSecret(9);
  live = { tid, ac: new AbortController(), listeners: new Set([res]), asks: new Map(), model };
  res.writeHead(200, { "Content-Type": "application/x-ndjson; charset=utf-8", "Cache-Control": "no-store",
    "X-Accel-Buffering": "no", "X-Content-Type-Options": "nosniff" });
  // a page that goes away (a phone in a pocket) does not stop the turn — only the stop key does
  res.on("close", () => live?.listeners.delete(res));
  emitAll({ t: "turn", id: tid, model });

  const canUseTool = (name, input, opts = {}) => new Promise((resolve) => {
    const rid = `r${++ridSeq}-${newSecret(6)}`;
    const t = live;
    const done = (v) => { clearTimeout(timer); t.asks.delete(rid); resolve(v); };
    const timer = setTimeout(() => done({ behavior: "deny", message: "no answer from the web page in time" }), ASK_TIMEOUT_MS);
    t.asks.set(rid, { name, input, done });
    opts.signal?.addEventListener?.("abort", () => done({ behavior: "deny", message: "aborted" }));
    emitAll(askEvent(rid, t.asks.get(rid)));
  });

  let sawDelta = false;
  const onMsg = (m) => {
    if (m.type === "system" && m.subtype === "init") return emitAll({ t: "session", id: m.session_id, cwd: conv.cwd });
    if (m.type === "stream_event") {
      const ev = m.event || {};
      if (ev.type === "content_block_delta" && ev.delta?.type === "text_delta") { sawDelta = true; emitAll({ t: "text", d: ev.delta.text }); }
      return;
    }
    if (m.type === "assistant") {
      // its text already went out as deltas when the partial stream carried them
      for (const b of blocks(m.message?.content)) {
        if (b.type === "text" && b.text && !sawDelta) emitAll({ t: "text", d: b.text });
        if (b.type === "tool_use") emitAll({ t: "tool", id: b.id, name: b.name, summary: toolSummary(b.name, b.input) });
      }
      sawDelta = false;
      return;
    }
    if (m.type === "user") {
      for (const b of blocks(m.message?.content)) {
        if (b.type === "tool_result") emitAll({ t: "tool_result", id: b.tool_use_id, text: resultText(b.content), error: !!b.is_error });
      }
      return;
    }
    if (m.type === "result") {
      if (m.subtype !== "success" && TOO_LONG.test(JSON.stringify(m.errors || m.result || ""))) throw Object.assign(new Error("too long"), { tooLong: true });
      emitAll({ t: "done", subtype: m.subtype, ms: m.duration_ms });
    }
  };

  try {
    if (maint) await maint;
    for (let attempt = 0; ; attempt++) {
      const seed = conv.session ? "" : conv.seed;
      try {
        await runQuery(seed + text, { model, resume: conv.session, cwd: conv.session ? conv.cwd : CWD, ac: live.ac, canUseTool }, onMsg);
        if (seed) { conv.seed = ""; saveConv(); }
        break;
      } catch (e) {
        if (attempt === 0 && !live.ac.signal.aborted && (e.tooLong || TOO_LONG.test(String(e?.message || e)))) {
          await maintain("too long");
          continue;
        }
        throw e;
      }
    }
  } catch (e) {
    emitAll(live.ac.signal.aborted ? { t: "stopped" } : { t: "error", msg: String(e?.message || e).slice(0, 500) });
    log("turn_error", { msg: String(e?.message || e).slice(0, 300) });
  } finally {
    for (const a of [...live.asks.values()]) a.done({ behavior: "deny", message: "turn ended" });
    const ls = live.listeners;
    live = null;
    for (const r of ls) if (!r.writableEnded) r.end();
    log("turn_end", { session: conv.session, used: conv.ctx.used, window: conv.ctx.window });
    if (conv.session && conv.ctx.window && conv.ctx.used >= COMPACT_AT * conv.ctx.window) maintain("near full");
  }
}

function answer(body) {
  const a = live?.asks.get(String(body.rid || ""));
  if (!a) return false;
  if (a.name === "AskUserQuestion") {
    const answers = {};
    for (const [k, v] of Object.entries(body.answers || {})) answers[String(k)] = String(v);
    a.done({ behavior: "allow", updatedInput: { ...a.input, answers } });
  } else if (body.allow) {
    a.done({ behavior: "allow", updatedInput: a.input });
  } else {
    a.done({ behavior: "deny", message: "the person said no on the web page" });
  }
  return true;
}

// ---- routes -------------------------------------------------------------------
async function handle(req, res) {
  const port = server.address().port;
  if (!hostAllowed(req.headers.host, port, HOSTS)) return send(res, 421, { error: "unknown host" });
  const u = new URL(req.url, `http://${BIND}:${port}`);
  const p = u.pathname;

  if (p === "/api/link" && req.method === "POST") {
    if (!sameSecret(req.headers["x-fleet-webchat-admin"], ADMIN)) { log("link_refused"); return send(res, 403, { error: "forbidden" }); }
    const code = newSecret(24);
    codes.set(sha(code), Date.now() + CODE_TTL_MS);
    log("link");
    return send(res, 200, { path: `/login?c=${code}`, ttl_s: CODE_TTL_MS / 1000 });
  }
  if (p === "/login" && req.method === "GET") {
    const k = sha(u.searchParams.get("c") || "");
    const exp = codes.get(k);
    codes.delete(k);                                      // once, right or wrong
    if (!exp || exp < Date.now()) { log("login_refused"); return send(res, 403, DENY_PAGE, "text/html; charset=utf-8"); }
    const c = newSecret();
    cookies[sha(c)] = Date.now() + COOKIE_TTL_S * 1000;
    for (const [h, e] of Object.entries(cookies)) if (e < Date.now()) delete cookies[h];
    saveCookies();
    log("login");
    const secure = req.headers["x-forwarded-proto"] === "https" ? "; Secure" : "";
    return send(res, 302, "", "text/plain", { Location: "/",
      "Set-Cookie": `${COOKIE}=${c}; HttpOnly; SameSite=Strict; Path=/; Max-Age=${COOKIE_TTL_S}${secure}` });
  }
  if (p === "/healthz") return send(res, 200, { ok: true });

  if (!authed(req)) {
    log("refused", { path: p });
    return p === "/" ? send(res, 403, DENY_PAGE, "text/html; charset=utf-8") : send(res, 403, { error: "forbidden" });
  }
  // a state-changing call must come from the page itself (fetch sets this; a form cannot)
  if (req.method === "POST" && req.headers["x-fleet-webchat"] !== "1") return send(res, 403, { error: "forbidden" });

  if (p === "/" && req.method === "GET") return send(res, 200, PAGE, "text/html; charset=utf-8");
  if (p === "/api/conversation" && req.method === "GET") {
    const items = await conversationItems();
    return send(res, 200, { session: conv.session, cwd: conv.cwd, busy: !!live, turn: live?.tid || "",
      asks: live ? [...live.asks.entries()].map(([rid, a]) => askEvent(rid, a)) : [],
      models: MODELS, default: DEFAULT_MODEL, items: items.slice(-600) });
  }
  if (p === "/api/turn" && req.method === "POST") return turn(req, res);
  if (p === "/api/stop" && req.method === "POST") {
    const ok = !!live && String((await readJson(req)).turn || "") === live.tid;
    if (ok) live.ac.abort();
    return send(res, ok ? 200 : 404, { ok });
  }
  if (p === "/api/answer" && req.method === "POST") {
    const ok = answer(await readJson(req));
    return send(res, ok ? 200 : 404, { ok });
  }
  return send(res, 404, { error: "not found" });
}

const server = http.createServer((req, res) => {
  handle(req, res).catch((e) => {
    log("error", { msg: String(e?.message || e).slice(0, 300) });
    if (!res.headersSent) send(res, 500, { error: "internal error" }); else res.end();
  });
});
server.listen(Number(E.FLEET_WEBCHAT_PORT || 0), BIND, () => {
  const { port } = server.address();
  writeFileSync(join(STATE, "port"), `${port}\n`);
  writeFileSync(join(STATE, "pid"), `${process.pid}\n`);
  log("listen", { bind: BIND, port });
  console.log(`fleet-webchat: listening on http://${BIND}:${port}/`);
});
for (const sig of ["SIGTERM", "SIGINT"]) process.on(sig, () => { log("stop"); server.close(); process.exit(0); });
