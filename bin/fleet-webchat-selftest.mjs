// fleet-webchat-selftest.mjs — the browser chat (issue #3567), driven for real
// with a stub Agent SDK, a stub fleet-session-cred.sh and a stub credential proxy
// (no network, no claude): extras/web-chat/server.mjs as bin/fleet-webchat.sh
// starts it.
//   A  it listens on 127.0.0.1 only; its state dir is 0700, admin.token 0600
//   B  nobody without the one-time link comes in: no cookie / a made-up cookie /
//      a used or wrong code / a wrong admin token / a foreign Host / a POST
//      without the page's header — all refused
//   C  a turn: a model off the allowlist is refused by the SERVER; an allowed one
//      streams text, a folded tool step, a question answered by a button, done
//   D  the pool: the turn's agent ran with ANTHROPIC_BASE_URL = the proxy's port
//      and the minted SESSION credential, its request reached the proxy under
//      that credential (= the pool's usage record), and the sid was revoked
//   E  the credential and the admin token appear in no response, no log, no file
//   F  one conversation: a restart resumes the same session; the stop key stops
//   G  the page (issue #3637) is the built UI in extras/web-chat/ui/dist: served only
//      with the cookie, its own files only (CSP self, no other origin in it), gzip when
//      asked, nothing outside dist; a question names the tool step it gates
//   A–G run in the local mode, FLEET_WEBCHAT_LOCAL=1 (issue #3643: off by default).
//   H  the socket mode (issue #3643, EPIC #3642 C1): <state>/chat.sock 0600 in a 0700
//      dir — even a socket planted 0666 in a 0755 dir comes back so; another uid
//      cannot connect (when `sudo -n -u nobody` works here); no admin.token, no port,
//      no TCP listener; with neither --socket nor FLEET_WEBCHAT_LOCAL=1 it does not
//      start; a second server on a live socket refuses (BREAK-IT chat-socket-other-login)
//   I  the budget: the credential proxy's 403 person_budget_exceeded is ONE stream line
//      {t:"error", code:"budget", until}, never the raw API error as the assistant's
//      words; /api/conversation says blocked until a turn goes through
//      (BREAK-IT chat-budget-bypass)
//   J  the home moved (issue #3647, EPIC #3642 C5): a conversation under login A, the
//      service stopped and its state dir carried to login B's home the way
//      `fleet service move webchat --to B` does (paths[]; ~/.claude stays behind):
//      under B it is the same conversation — same session, its history, the next
//      turn resumes it, the transcript back under B's projects dir with B's cwd —
//      and nothing of the service is left under A (BREAK-IT chat-home-moved)
//   K  idle (C5): with FLEET_WEBCHAT_IDLE_SECS it stays while a page holds a
//      connection, exits 75 (the daemon's idle code) once nothing is open, its
//      socket gone; started again it is the same conversation
//   L  permissions (issue #4031): the agent runs bypassPermissions (+ the SDK's
//      allowDangerouslySkipPermissions) with the login's settings loaded
//      (settingSources user/project/local), so a tool step runs with no 允许 card;
//      the fleet's bash-guard (hooks/settings-hooks.json's Bash entry) still denies
//      `rm -rf x/.git` as a PreToolUse hook, outside tmux too — a hook's deny holds in
//      bypass; AskUserQuestion still comes out as the question card (part C)
//   M  the browser's context (issue #4034), in the socket mode: a phone's turn and a
//      computer's turn each put ONE <fleet-webchat-context> line before the person's
//      words (device · system · browser · language · width · local time · city from
//      the entry's X-Fleet-Client) — never the IP — and only when it changed (same
//      browser again: none; another city: again); the page never shows it; the
//      browser_context tool answers the full IP and UA; neither is in server.log
//   N  a trial's conversation leaves with its person (issue #4060): GET /api/export on
//      login A gives every session's transcript + home; POST /api/import on a clean
//      login B puts it back — the page reads the same history under B's home, the next
//      turn is a NEW session seeded with the last words — and an import onto a login
//      that already has a conversation is refused 409 (BREAK-IT trial-transcript-cross)
//   P  images (task T773), in the socket mode: a tool result's image, a reply's image and the
//      person's own picture come out as {t:"image"} items (live and read back) — never their
//      bytes in the JSON; /api/file serves each by its ref (its type, a sandbox CSP, kept
//      0600 under a 0700 media/), a ref that is not one 404s; one over the size bound is
//      {big:true}; past the per-reply bound the rest are counted on one image_more
//   Q  the home's files a reply links to (task T773 ②): a file under $HOME / the session's dir
//      gets an opaque ref ({t:"files"} after the text, live and read back) — never its path
//      on the wire; ~/.ssh, a secret's name, a link out of $HOME, a missing file get none;
//      /api/file serves an image as itself, HTML as a download under a sandbox CSP; an
//      expired ref says so (410); a file that became a link out is refused at the read
//   R  pictures from the page (task T773 ③): a turn's images reach the agent as image
//      blocks before the words (and with no words at all); read back they ride on the
//      person's line; a fifth picture, a non-image, a request past the bound are refused
//   S  the agent's web pages (task T773 ④): the turn's agent has page_target / show_page; a
//      show_page call becomes a {t:"page"} card (live and read back) with its link, state,
//      version and a preview kept as an image; a link that is not https is dropped;
//      pages.json remembers the folder and the file's page, which page_target answers
//   V  只读 (task F481): /api/view?fid= follows a terminal session's record as SSE — the
//      state, the newest stretch in place (at = the byte read to), a line added after in
//      under 3 s; ?at= sends nothing twice; a long record's first answer is its newest 200,
//      ?before= the page before, a step's output its start (?tool= the whole) (task YP39);
//      busy and a closed window are said; a Codex
//      rollout reads too
//   X  接管 / 交回 (task VV8F): /api/takeover · /api/giveback by a window's fid — refused
//      while the terminal answers, one of two at once (409 taking), to-web without a page,
//      give-back by the window; done twice is 200 already
//   Y  the session gate (task HHV0): /api/say hands the words to bin/fleet_session_gate.py on
//      stdin (pictures as media/ files), stop / answer with the body's fid are the gate's, a
//      session not here is 404 with a code, /api/open opens a no-repo origin-web session with the
//      words as its first turn, the view's state line says can_talk + the queue (no holder)
//   --only=socket|budget|context|home|idle|trial|view|handover|gate|media|links|send|pages|local (comma list) runs those parts only — the drills' road.
import { spawn, spawnSync } from "node:child_process";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import { appendFileSync, mkdtempSync, writeFileSync, readFileSync, readdirSync, statSync, existsSync, rmSync, chmodSync, unlinkSync, mkdirSync,
  renameSync, realpathSync, symlinkSync } from "node:fs";
import { join, dirname } from "node:path";
import { gunzipSync } from "node:zlib";
import { fileURLToPath } from "node:url";

const BIN = dirname(fileURLToPath(import.meta.url));
const APP = join(BIN, "../extras/web-chat/server.mjs");
const T = mkdtempSync(join(os.tmpdir(), "fleet-webchat-selftest-"));
const STATE = join(T, "state");
const CFG = join(T, "claude");
const SECRET = "fcp1.SELFTEST-SECRET-" + Math.random().toString(36).slice(2);
const SID = "11111111-2222-4333-8444-555555555555";
const ONLY = ((process.argv.find((a) => a.startsWith("--only=")) || "").slice(7) || "socket,budget,context,home,idle,trial,handoff,view,handover,gate,legacy-migration,media,links,send,pages,aside,release,probe-contract,local").split(",");
const part = (x) => ONLY.includes(x);
let fails = 0, server = null;
const seen = [];                                           // every response body the test read
process.on("exit", () => { try { server?.kill("SIGKILL"); } catch { /* gone */ } rmSync(T, { recursive: true, force: true }); });
// a timeout names the last line that passed: where it hung (task PQ41)
let lastOk = "(none)";
setTimeout(() => { console.log(`FAIL timed out after «${lastOk}»`); process.exit(1); }, 90000).unref();
const ok = (c, m) => { console.log(`${c ? "ok  " : "FAIL"} ${m}`); if (!c) fails++; else lastOk = m; };

// ---- the stub credential proxy: what reaches it is the pool's usage record ----
const proxyHits = [];
let spaceEligible = false;                                   // S: the proxy's /space/status (task XA4R)
const proxy = http.createServer((req, res) => {
  if (req.url === "/space/status") {
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end(JSON.stringify(spaceEligible && req.headers.authorization === "Bearer " + SECRET ? { eligible: true, ready: false } : { eligible: false }));
  }
  proxyHits.push({ auth: req.headers.authorization || "", path: req.url });
  res.writeHead(200, { "Content-Type": "application/json" }); res.end('{"usage":{"input_tokens":7,"output_tokens":3}}');
});
await new Promise((r) => proxy.listen(0, "127.0.0.1", r));
const PPORT = proxy.address().port;

// ---- the stub fleet-session-cred.sh (on · mint · revoke), its calls logged ------
const CREDLOG = join(T, "cred.log");
const credSh = join(T, "fleet-session-cred.sh");
writeFileSync(credSh, `#!/bin/bash
echo "$*" >>"${CREDLOG}"
case "$1" in
  on) exit 0 ;;
  mint) printf 'direct\\t${PPORT}\\t${SECRET}\\n' ;;
  revoke) exit 0 ;;
esac
`, { mode: 0o755 });

// ---- the stub Agent SDK: query() asks the proxy, asks a question, writes a transcript
const ENVLOG = join(T, "env.json");
const PROMPTLOG = join(T, "prompts.ndjson");                  // every prompt the agent got, and its MCP servers (M)
const TOOLLOG = join(T, "tool.txt");                          // what browser_context answered (M)
const SPACELOG = join(T, "space.ndjson");                     // the space server a trial's agent got (S, task XA4R)
const QUERYLOG = join(T, "queries.log");                     // one line per query() — a started agent (C2)
const HOLDFLAG = join(T, "hold.go");                          // a "hold" turn answers once this is there (U, task WD8F)
const sdk = join(T, "sdk.mjs");
writeFileSync(sdk, `
import { writeFileSync, appendFileSync, mkdirSync, realpathSync, existsSync } from "node:fs";
import { join } from "node:path";
const SID = ${JSON.stringify(SID)};
export const tool = (name, description, shape, handler) => ({ name, handler });
export const createSdkMcpServer = (o) => ({ type: "sdk", name: o.name, tools: o.tools });
// a streamed prompt (the warm agent, task V9DJ C2) is one process taking turn after
// turn: every message runs the same body; a string prompt is one turn, as before
export function query({ prompt, options }) {
  appendFileSync(${JSON.stringify(QUERYLOG)}, "query\\n");
  const g = (async function* () {
    if (typeof prompt === "string") { yield* one(prompt, options); return; }
    for await (const m of prompt) yield* one(m.message.content, options);
  })();
  g.setModel = async (model) => { options.model = model; };
  return g;
}
async function* one(prompt, options) {
  const env = options.env;
  appendFileSync(${JSON.stringify(PROMPTLOG)}, JSON.stringify({ prompt, mcp: Object.keys(options.mcpServers || {}) }) + "\\n");
  if (options.mcpServers?.space) appendFileSync(${JSON.stringify(SPACELOG)}, JSON.stringify(options.mcpServers.space) + "\\n");
  // the once-a-session note (task T773) says nothing a stub turn branches on
  if (typeof prompt === "string") prompt = prompt.replace(/<fleet-webchat-note>[\\s\\S]*?<\\/fleet-webchat-note>\\s*/, "");
  if (/ctxtool$/.test(prompt) && options.mcpServers?.fleet_browser) {
    const t = options.mcpServers.fleet_browser.tools.find((x) => x.name === "browser_context");
    writeFileSync(${JSON.stringify(TOOLLOG)}, (await t.handler({})).content[0].text);
  }
  writeFileSync(${JSON.stringify(ENVLOG)}, JSON.stringify({ base: env.ANTHROPIC_BASE_URL, token: env.CLAUDE_CODE_OAUTH_TOKEN,
    tmux: env.TMUX || "", resume: options.resume || "", model: options.model,
    mode: options.permissionMode, skip: options.allowDangerouslySkipPermissions, sources: options.settingSources }));
  await fetch(env.ANTHROPIC_BASE_URL + "/v1/messages", { method: "POST", headers: { authorization: "Bearer " + env.CLAUDE_CODE_OAUTH_TOKEN } });
  const dir = join(env.CLAUDE_CONFIG_DIR || join(env.HOME, ".claude"), "projects", realpathSync(options.cwd).replace(/[^A-Za-z0-9]/g, "-"));
  mkdirSync(dir, { recursive: true });
  const tr = join(dir, SID + ".jsonl");
  appendFileSync(tr, JSON.stringify({ type: "user", message: { role: "user", content: prompt } }) + "\\n");
  yield { type: "system", subtype: "init", session_id: SID };
  if (prompt === "budget") {          // what Claude Code hands on from the proxy's 403
    const api = 'API Error: 403 {"type":"error","error":{"type":"permission_error","message":"cred-proxy: 已达个人额度：近 5 小时已用 250k / 上限 200k token（person_budget_exceeded）","code":"person_budget_exceeded","reset_at":"2030-01-01T05:00:00Z"}}';
    yield { type: "assistant", session_id: SID, message: { content: [{ type: "text", text: api }] } };
    yield { type: "result", subtype: "success", is_error: true, result: api, session_id: SID, duration_ms: 1 };
    return;
  }
  if (prompt === "pic") {                // images (P): a tool result's, the reply's, one too big, one past the bound
    const png = (tail) => ({ type: "image", source: { type: "base64", media_type: "image/png", data: Buffer.concat([Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64"), Buffer.from(tail)]).toString("base64") } });
    const tr1 = { type: "assistant", message: { content: [{ type: "tool_use", id: "tu-pic", name: "Read", input: { file_path: "/x/a.png" } }] } };
    const tr2 = { type: "user", message: { content: [{ type: "tool_result", tool_use_id: "tu-pic", content: [{ type: "text", text: "读了" }, png("one")] }] } };
    const tr3 = { type: "assistant", message: { content: [{ type: "text", text: "看图" }, png("two"), png("x".repeat(400)), png("one")] } };
    for (const m of [tr1, tr2, tr3]) { appendFileSync(tr, JSON.stringify(m) + "\\n"); yield { ...m, session_id: SID }; }
    yield { type: "result", subtype: "success", session_id: SID, duration_ms: 1 };
    return;
  }
  if (prompt === "link") {               // links (Q): the reply names files on this machine
    const H = env.HOME;
    const text = "改好了：[form.css](" + H + "/proj/form.css)、![shot](~/proj/shot.png)、[页面](proj/page.html)、" +
      "[钥匙](" + H + "/.ssh/id_rsa)、[密](" + H + "/proj/.env)、[外](" + H + "/proj/out.txt)、[无](" + H + "/proj/none.txt)、[网](https://example.com/a)";
    const m = { type: "assistant", message: { content: [{ type: "text", text }] } };
    appendFileSync(tr, JSON.stringify(m) + "\\n");
    yield { ...m, session_id: SID };
    yield { type: "result", subtype: "success", session_id: SID, duration_ms: 1 };
    return;
  }
  if (prompt === "page3" || prompt === "page4") {  // a trial's page (S, task XA4R): opened · pushed, or not open yet
    const tools = options.mcpServers?.fleet_chat?.tools || [];
    const call = async (n, a) => (await tools.find((t) => t.name === n).handler(a)).content[0].text;
    appendFileSync(${JSON.stringify(TOOLLOG)}, (await call("page_target", { file: env.HOME + "/proj/list.html" })) + "\\n");
    const input = prompt === "page3"
      ? { title: "周末露营清单", url: "https://pages.example.com/s/camp", status: "ready", proposal_id: "P3", version: 1, account_new: true, pushed: true }
      : { title: "周末露营清单", status: "account", note: "活页暂时不可用" };
    await call("show_page", input);
    const m = { type: "assistant", message: { content: [{ type: "tool_use", id: "tu-" + prompt, name: "mcp__fleet_chat__show_page", input }] } };
    appendFileSync(tr, JSON.stringify(m) + "\\n");
    yield { ...m, session_id: SID };
    yield { type: "result", subtype: "success", session_id: SID, duration_ms: 1 };
    return;
  }
  if (prompt === "page" || prompt === "page2") {   // pages (S): publish, then the card
    const H = env.HOME;
    const tools = options.mcpServers?.fleet_chat?.tools || [];
    const call = async (n, a) => (await tools.find((t) => t.name === n).handler(a)).content[0].text;
    const target = JSON.parse(await call("page_target", { file: H + "/proj/weekly.html" }));
    appendFileSync(${JSON.stringify(TOOLLOG)}, JSON.stringify(target) + "\\n");
    const input = prompt === "page"
      ? { title: "销售周报 · 第 41 周", url: "https://pages.example.com/s/demo", status: "review", proposal_id: "P1", version: 1,
          file: H + "/proj/weekly.html", folder_id: "F1", preview: H + "/proj/weekly.png",
          embed_url: "https://space.example.com/embed/V1/TICKET", embed_expires: new Date(Date.now() + 3600e3).toISOString() }
      : { title: "坏链接", url: "javascript:alert(1)", status: "ready", proposal_id: "P1", version: 2, file: H + "/proj/weekly.html" };
    await call("show_page", input);
    const m = { type: "assistant", message: { content: [{ type: "tool_use", id: "tu-" + prompt, name: "mcp__fleet_chat__show_page", input }] } };
    appendFileSync(tr, JSON.stringify(m) + "\\n");
    yield { ...m, session_id: SID };
    yield { type: "result", subtype: "success", session_id: SID, duration_ms: 1 };
    return;
  }
  if (prompt === "hold") {                 // a turn that answers only when told (U): 新对话 must not cut it
    const sig = options.abortController.signal;
    while (!existsSync(${JSON.stringify(HOLDFLAG)})) {
      if (sig.aborted) throw new Error("aborted");
      await new Promise((r) => setTimeout(r, 50));
    }
    const m = { type: "assistant", message: { content: [{ type: "text", text: "答完了" }] } };
    appendFileSync(tr, JSON.stringify(m) + "\\n");
    yield { ...m, session_id: SID };
    yield { type: "result", subtype: "success", session_id: SID, duration_ms: 1 };
    return;
  }
  if (prompt === "notice") {               // a background task's notice + Claude Code's filler (U)
    const lines = [
      { type: "user", origin: { kind: "task-notification" }, message: { role: "user", content: "<task-notification>\\n<task-id>b1</task-id>\\n<status>stopped</status>\\n<summary>Background shell command didn't finish before the previous session ended</summary>\\n</task-notification>" } },
      { type: "assistant", message: { model: "<synthetic>", content: [{ type: "text", text: "No response requested." }] } },
      { type: "assistant", message: { content: [{ type: "text", text: "接着说" }] } },
    ];
    for (const m of lines) appendFileSync(tr, JSON.stringify(m) + "\\n");
    yield { type: "assistant", session_id: SID, message: { model: "<synthetic>", content: [{ type: "text", text: "No response requested." }] } };
    yield { type: "assistant", session_id: SID, message: { content: [{ type: "text", text: "接着说" }] } };
    yield { type: "result", subtype: "success", session_id: SID, duration_ms: 1 };
    return;
  }
  if (prompt === "slow") {
    const sig = options.abortController.signal;
    await new Promise((res, rej) => { if (sig.aborted) rej(new Error("aborted")); sig.addEventListener("abort", () => rej(new Error("aborted"))); });
  }
  yield { type: "stream_event", session_id: SID, event: { type: "content_block_delta", delta: { type: "text_delta", text: "你好，" + ${JSON.stringify(SECRET)} } } };
  yield { type: "assistant", session_id: SID, message: { content: [{ type: "tool_use", id: "tu1", name: "Bash", input: { command: "date" } }], usage: { input_tokens: 5 } } };
  yield { type: "user", session_id: SID, message: { content: [{ type: "tool_result", tool_use_id: "tu1", content: "Mon" }] } };
  const r = await options.canUseTool("AskUserQuestion", { questions: [{ question: "猫还是狗？", options: [{ label: "猫" }, { label: "狗" }] }] }, { toolUseID: "tu-ask" });
  yield { type: "assistant", session_id: SID, message: { content: [{ type: "text", text: "你选了" + (r.updatedInput?.answers?.["猫还是狗？"] || "?") }] } };
  appendFileSync(tr, JSON.stringify({ type: "assistant", message: { content: [{ type: "text", text: "你选了" }] } }) + "\\n");
  yield { type: "result", subtype: "success", session_id: SID, duration_ms: 1, modelUsage: { m: { contextWindow: 1000000 } } };
}
`);

// ---- the server, as bin/fleet-webchat.sh starts it ------------------------------
function start() {
  return new Promise((resolve, reject) => {
    const env = { ...process.env, FLEET_WEBCHAT_LOCAL: "1", FLEET_WEBCHAT_STATE: STATE, FLEET_WEBCHAT_PORT: "0", FLEET_WEBCHAT_SDK: sdk,
      FLEET_WEBCHAT_SESSION_CRED: credSh, FLEET_WEBCHAT_CWD: T, CLAUDE_CONFIG_DIR: CFG, TMUX: "/tmp/should-not-pass,1,1" };
    server = spawn(process.execPath, [APP], { env, stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    server.stdout.on("data", (d) => { out += d; const m = out.match(/127\.0\.0\.1:(\d+)/); if (m) resolve(Number(m[1])); });
    server.stderr.on("data", (d) => process.stderr.write(d));
    server.on("exit", (c) => reject(new Error("server exited " + c)));
    setTimeout(() => reject(new Error("server did not start")), 10000);
  });
}
function stop() { return new Promise((r) => { if (!server || server.exitCode !== null) return r(); server.removeAllListeners("exit"); server.on("exit", r); server.kill("SIGTERM"); }); }

// ---- H + I: the socket mode ---------------------------------------------------------
// under /tmp, not $TMPDIR: on macOS $TMPDIR is /var/folders/…/T, whose ancestors are 0700,
// so another uid could not even reach the socket and H's "another uid" checks proved nothing
const HS = mkdtempSync("/tmp/fws-");
process.on("exit", () => rmSync(HS, { recursive: true, force: true }));
let SSTATE = join(HS, "sstate");
let SOCK = join(SSTATE, "chat.sock");
let sserver = null;
process.on("exit", () => { try { sserver?.kill("SIGKILL"); } catch { /* gone */ } });
function sstart(args = ["--socket"], extra = {}, entry = APP) {
  return new Promise((resolve, reject) => {
    const env = { ...process.env, FLEET_WEBCHAT_STATE: SSTATE, FLEET_WEBCHAT_SDK: sdk, FLEET_WEBCHAT_SESSION_CRED: credSh,
      FLEET_WEBCHAT_CWD: T, CLAUDE_CONFIG_DIR: CFG, FLEET_WEBCHAT_PORT: "0", FLEET_WEBCHAT_IDLE_SECS: "0", ...extra };
    delete env.FLEET_WEBCHAT_LOCAL;
    for (const k of Object.keys(extra)) if (extra[k] === undefined) delete env[k];
    const p = spawn(process.execPath, [entry, ...args], { env, stdio: ["ignore", "pipe", "pipe"] });
    let out = "", err = "";
    p.stdout.on("data", (d) => { out += d; if (/listening on/.test(out)) resolve({ p, out }); });
    p.stderr.on("data", (d) => { err += d; });
    p.on("exit", (c) => resolve({ p, code: c, out, err }));
    setTimeout(() => reject(new Error("socket server did not start")), 10000).unref();
  });
}
function sstop(p) { return new Promise((r) => { if (!p || p.exitCode !== null) return r(); p.removeAllListeners("exit"); p.on("exit", r); p.kill("SIGTERM"); }); }
function sreq(path, { method = "GET", headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const r = http.request({ socketPath: SOCK, path, method, headers: { Host: "webchat", ...headers } }, (res) => {
      let b = ""; res.on("data", (d) => (b += d)); res.on("end", () => { seen.push(b); resolve({ status: res.statusCode, body: b }); });
    });
    r.on("error", reject);
    if (body != null) r.write(typeof body === "string" ? body : JSON.stringify(body));
    r.end();
  });
}
function sturn(text) {
  return new Promise((resolve, reject) => {
    const lines = [];
    const r = http.request({ socketPath: SOCK, path: "/api/turn", method: "POST",
      headers: { Host: "webchat", "X-Fleet-Webchat": "1", "X-Fleet-Person": "alice@example.com", "Content-Type": "application/json" } }, (res) => {
      let buf = "", all = "";
      res.on("data", (d) => { buf += d; all += d; let i; while ((i = buf.indexOf("\n")) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1); if (l) {
        const o = JSON.parse(l); lines.push(o);
        if (o.t === "ask") sreq("/api/answer", { method: "POST", headers: { "X-Fleet-Webchat": "1", "Content-Type": "application/json" }, body: { rid: o.rid, answers: { "猫还是狗？": "狗" } } });
      } } });
      // a stream the server dropped mid-turn (U: stopped while it answers) ends
      // on "close" with no "end" — settle then too, never hang (task PQ41 CI)
      let done = false;
      const fin = () => { if (done) return; done = true; seen.push(all); resolve({ status: res.statusCode, lines }); };
      res.on("end", fin); res.on("close", fin); res.on("error", fin);
    });
    r.on("error", reject); r.end(JSON.stringify({ text }));
  });
}
const mode = (f) => statSync(f).mode & 0o777;
// can another uid connect? → true / false, or null when this box cannot say (no sudo, or root)
function otherUidConnects() {
  if (process.getuid?.() === 0) return null;
  if (spawnSync("sudo", ["-n", "-u", "nobody", "true"], { stdio: "ignore" }).status !== 0) return null;
  const r = spawnSync("sudo", ["-n", "-u", "nobody", process.execPath, "-e",
    `const s=require("net").connect(${JSON.stringify(SOCK)});s.on("connect",()=>{console.log("CONNECTED");process.exit(0)});s.on("error",(e)=>{console.log(e.code);process.exit(0)})`],
  { encoding: "utf8", timeout: 10000 });
  if (/CONNECTED/.test(r.stdout || "")) return true;
  return /EACCES|EPERM|ENOENT/.test(r.stdout || "") ? false : null;   // anything else: it could not even try
}
// every directory above HS lets another uid pass (o+x)? otherwise "cannot connect" proves nothing
function othersReachHS() {
  for (let d = dirname(realpathSync(HS)); ; d = dirname(d)) {
    if (!(statSync(d).mode & 0o001)) return d;
    if (d === dirname(d)) return null;
  }
}

if (part("socket") || part("budget") || part("context")) {
  // neither --socket nor FLEET_WEBCHAT_LOCAL=1: the local mode is off by default
  const off = await sstart([]);
  ok(off.code === 2 && /FLEET_WEBCHAT_LOCAL=1/.test(off.err) && !existsSync(join(SSTATE, "port")), "H no --socket, no FLEET_WEBCHAT_LOCAL=1: it does not start (no TCP by default)");
  // the break: a stale socket left 0666 in a 0755 dir
  mkdirSync(SSTATE, { recursive: true });
  writeFileSync(SOCK, "");
  chmodSync(SOCK, 0o666); chmodSync(SSTATE, 0o755);
  const st = await sstart();
  sserver = st.p;
  ok(!st.code && existsSync(SOCK) && statSync(SOCK).isSocket(), "H --socket listens on <state>/chat.sock");
  ok(mode(SOCK) === 0o600, `H the socket is 0600 (${mode(SOCK).toString(8)}) — a planted 0666 one was replaced`);
  ok(mode(SSTATE) === 0o700, `H its dir is 0700 (${mode(SSTATE).toString(8)})`);
  ok(!existsSync(join(SSTATE, "admin.token")) && !existsSync(join(SSTATE, "port")), "H no admin.token, no port file");
  const lsof = spawnSync("lsof", ["-nP", "-a", "-p", String(sserver.pid), "-iTCP", "-sTCP:LISTEN"], { encoding: "utf8" });
  if (lsof.error) console.log("note H: no lsof here to list TCP listeners");
  else ok(!/LISTEN/.test(lsof.stdout || ""), "H no TCP listener at all");
  ok((await sreq("/healthz")).status === 200, "H the socket answers");
  const wm = await sreq("/api/warm");
  ok(wm.status === 200 && JSON.parse(wm.body).ok === true, "H /api/warm answers at once (task PNWW: the new-session page warms the relay)");
  ok((await sreq("/api/warm", { method: "POST", headers: { "X-Fleet-Webchat": "1" } })).status !== 200, "H /api/warm is GET only");
  const c0 = await sreq("/api/conversation");
  ok(c0.status === 200 && JSON.parse(c0.body).budget?.blocked === false, "H trusted on the socket: no cookie needed; budget not blocked");
  ok((await sreq("/api/turn", { method: "POST", headers: { "Content-Type": "application/json" }, body: { text: "hi" } })).status === 403, "H a POST without the page's header is still refused");
  const lk = await sreq("/api/link", { method: "POST", headers: { "X-Fleet-Webchat": "1", "X-Fleet-Webchat-Admin": "x" } });
  ok(lk.status === 404 && !/login\?c=/.test(lk.body), "H no login link on the socket");
  const shut = othersReachHS();
  const other = shut ? null : otherUidConnects();
  if (shut) console.log(`note H: cannot try another uid here (${shut} is not o+x, so no other uid reaches the socket)`);
  else if (other === null) console.log("note H: cannot try another uid here (no passwordless sudo, or root)");
  else {
    ok(other === false, "H another uid cannot connect (dir 0700)");
    chmodSync(SSTATE, 0o711); chmodSync(HS, 0o711);          // only the socket's own mode left in the way
    ok(otherUidConnects() === false, "H another uid cannot connect even through an open dir (socket 0600)");
    chmodSync(SOCK, 0o666);                                   // the break, for real: the probe is not vacuous
    ok(otherUidConnects() === true, "H (control) a 0666 socket in an open dir: another uid DOES connect");
    chmodSync(SOCK, 0o600);
    chmodSync(SSTATE, 0o700); chmodSync(HS, 0o700);
  }
  const second = await sstart();
  ok(second.code === 3 && mode(SOCK) === 0o600 && (await sreq("/healthz")).status === 200, "H a second server on a live socket refuses; the first keeps it");
}
if (part("budget")) {
  const b = await sturn("budget");
  const errs = b.lines.filter((o) => o.t === "error");
  ok(b.status === 200 && errs.length === 1 && errs[0].code === "budget" && errs[0].until === "2030-01-01T05:00:00Z" && /已达个人额度/.test(errs[0].msg),
    `I the proxy's 403 is one {t:"error", code:"budget", until} line (${JSON.stringify(errs)})`);
  ok(!b.lines.some((o) => o.t === "text" || o.t === "done") && !JSON.stringify(b.lines).includes("API Error"), "I the raw API error never reaches the page as the assistant's words");
  const cb = JSON.parse((await sreq("/api/conversation")).body).budget;
  ok(cb?.blocked === true && cb.until === "2030-01-01T05:00:00Z", `I /api/conversation says blocked, until (${JSON.stringify(cb)})`);
  await sstop(sserver);
  sserver = (await sstart()).p;
  ok(JSON.parse((await sreq("/api/conversation")).body).budget?.blocked === true, "I still blocked after a restart");
  const g = await sturn("again");
  ok(g.lines.at(-1)?.t === "done", "I a turn under budget goes through");
  ok(JSON.parse((await sreq("/api/conversation")).body).budget?.blocked === false, "I … and the block is lifted");
}
if (part("context")) {
  const IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
  const MAC = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
  const phone = { ua: IPHONE, lang: "zh-CN", langs: ["zh-CN"], tz: "Asia/Shanghai", viewport: { w: 390, h: 844 }, screen: { w: 390, h: 844, dpr: 3 }, touch: 5 };
  const mac = { ua: MAC, uaData: { platform: "macOS", mobile: false, brands: ["Chromium 140"] }, lang: "en-US", tz: "America/Los_Angeles",
    viewport: { w: 1440, h: 900 }, net: { effectiveType: "4g", downlink: 10, rtt: 50 } };
  const where = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const SZ = where({ ip: "203.0.113.9", country: "中国", province: "广东省", city: "深圳市" });
  const SH = where({ ip: "198.51.100.7", country: "中国", province: "上海", city: "上海市" });
  const cturn = (text, client, place) => new Promise((resolve, reject) => {
    const r = http.request({ socketPath: SOCK, path: "/api/turn", method: "POST", headers: { Host: "webchat", "X-Fleet-Webchat": "1",
      "X-Fleet-Person": "alice@example.com", "X-Fleet-Client": place, "Content-Type": "application/json" } }, (res) => {
      let all = "";
      res.on("data", (d) => {
        all += d;
        for (const l of String(d).split("\n")) if (/"t":"ask"/.test(l)) {
          const o = JSON.parse(l);
          sreq("/api/answer", { method: "POST", headers: { "X-Fleet-Webchat": "1", "Content-Type": "application/json" }, body: { rid: o.rid, answers: {} } });
        }
      });
      res.on("end", () => { seen.push(all); resolve(all); });
    });
    r.on("error", reject); r.end(JSON.stringify({ text, client }));
  });
  const last = () => JSON.parse(readFileSync(PROMPTLOG, "utf8").trim().split("\n").at(-1));
  await cturn("从手机问", phone, SZ);
  const p1 = last();
  const head1 = (p1.prompt.match(/^<fleet-webchat-context>[\s\S]*?<\/fleet-webchat-context>/) || [""])[0];
  ok(head1 && /手机 · iPhone/.test(head1) && /Safari/.test(head1) && /zh-CN/.test(head1) && /窄屏/.test(head1) && /Asia\/Shanghai/.test(head1)
    && /广东省深圳市/.test(head1) && p1.prompt.endsWith("从手机问"), `M a phone's turn: one context line before the words (${head1.replace(/\n/g, " ")})`);
  ok(!p1.prompt.includes("203.0.113.9") && !p1.prompt.includes("Mobile/15E148"), "M the line carries no IP and no raw UA");
  ok(head1.length < 260, `M it is one short line (${head1.length} chars)`);
  ok(p1.mcp.includes("fleet_browser"), "M the turn's agent has the browser_context tool");
  await cturn("再问一句", phone, SZ);
  ok(!/<fleet-webchat-context>/.test(last().prompt), "M the same browser again: no line (only when it changes)");
  await cturn("换电脑问", mac, SZ);
  const p3 = last().prompt;
  ok(/^<fleet-webchat-context>/.test(p3) && /电脑 · Mac/.test(p3) && /Chrome/.test(p3) && /en-US/.test(p3) && /宽屏/.test(p3),
    "M a computer's turn: the line again, saying computer · Mac · Chrome");
  await cturn("同一台，换个城市 ctxtool", mac, SH);
  const p4 = last().prompt;
  ok(/^<fleet-webchat-context>/.test(p4) && /上海市/.test(p4) && !/深圳/.test(p4), "M another city: the line again");
  const tl = existsSync(TOOLLOG) ? JSON.parse(readFileSync(TOOLLOG, "utf8")) : {};
  ok(tl.ip === "198.51.100.7" && tl.ua === MAC && tl.net?.effectiveType === "4g" && tl.place?.city === "上海市",
    `M browser_context answers the full IP, UA and network (${JSON.stringify(tl).slice(0, 160)})`);
  const items = JSON.parse((await sreq("/api/conversation")).body).items;
  ok(items.some((i) => i.t === "user" && i.text === "从手机问") && !items.some((i) => i.t === "user" && /fleet-webchat-context/.test(i.text)),
    "M the page shows the person's words, never the context line");
  const slog = readFileSync(join(SSTATE, "server.log"), "utf8");
  ok(!slog.includes("203.0.113.9") && !slog.includes("198.51.100.7") && !slog.includes("Mobile/15E148"), "M neither the IP nor the UA is in server.log");
}
if (sserver) await sstop(sserver);
if (part("budget")) {
  const log = existsSync(join(SSTATE, "server.log")) ? readFileSync(join(SSTATE, "server.log"), "utf8") : "";
  ok(/"ev":"budget"/.test(log) && /"person":"alice@example.com"/.test(log), "I the log says budget, and whose (X-Fleet-Person, for the log only)");
  ok(!log.includes(SECRET), "I the credential is not in the socket server's log");
}
// ---- J: the home moved ------------------------------------------------------------
// short paths: a unix socket path is ≤ 104 bytes, and /tmp keeps it there
const HT = mkdtempSync("/tmp/fwh-");
process.on("exit", () => rmSync(HT, { recursive: true, force: true }));
const homeOf = (h) => join(HT, h), stateOf = (h) => join(HT, h, ".config", "claude-fleet", "webchat");
const asHome = (h) => ({ HOME: homeOf(h), FLEET_WEBCHAT_CWD: undefined, CLAUDE_CONFIG_DIR: undefined });
const mangle = (p) => realpathSync(p).replace(/[^A-Za-z0-9]/g, "-");
if (part("home")) {
  for (const h of ["a", "b"]) mkdirSync(homeOf(h), { recursive: true });
  SSTATE = stateOf("a"); SOCK = join(SSTATE, "chat.sock");
  const a = (await sstart(["--socket"], asHome("a"))).p;
  const t1 = await sturn("记住青蛙");
  ok(t1.lines.at(-1)?.t === "done", "J a turn under login A");
  const ca = JSON.parse((await sreq("/api/conversation")).body);
  ok(ca.session === SID && ca.cwd === homeOf("a"), `J the conversation runs in A's home (${ca.cwd})`);
  ok(existsSync(join(SSTATE, "transcripts", SID + ".jsonl")), "J its transcript is copied into the state dir (what service move carries)");
  // fleet service move webchat --to b: stopped first, then paths[] rehomed; ~/.claude stays with A
  await sstop(a);
  ok(a.exitCode === 0 && !existsSync(SOCK), "J stopped under A: exit 0, its socket gone");
  mkdirSync(dirname(stateOf("b")), { recursive: true });
  renameSync(stateOf("a"), stateOf("b"));
  SSTATE = stateOf("b"); SOCK = join(SSTATE, "chat.sock");
  const b = (await sstart(["--socket"], asHome("b"))).p;
  const cb = JSON.parse((await sreq("/api/conversation")).body);
  ok(cb.session === SID && cb.cwd === homeOf("b"), `J under B: the same session, its cwd B's home (${cb.session} ${cb.cwd})`);
  ok(cb.items.some((i) => i.t === "user" && i.text === "记住青蛙"), "J under B: the history is on the page");
  const trB = join(homeOf("b"), ".claude", "projects", mangle(homeOf("b")), SID + ".jsonl");
  ok(existsSync(trB) && (statSync(trB).mode & 0o777) === 0o600, "J the transcript is back under B's projects dir (0600) — claude --resume finds it there");
  const t2 = await sturn("还记得吗");
  ok(t2.lines.at(-1)?.t === "done" && JSON.parse(readFileSync(ENVLOG, "utf8")).resume === SID, "J the next turn under B resumes the same session");
  ok(!existsSync(stateOf("a")) && !existsSync(join(stateOf("a"), "chat.sock")), "J nothing of the service is left under A (no state dir, no socket)");
  ok(/"ev":"home_moved"/.test(readFileSync(join(SSTATE, "server.log"), "utf8")), "J the log says home_moved");
  await sstop(b);
  // the CLI's two roads go through `fleet service` (its root half: the daemon's ensure / move)
  const svcLog = join(HT, "svc.log"), svcSh = join(HT, "svc.sh");
  writeFileSync(svcSh, `#!/bin/bash\necho "$*" >>${JSON.stringify(svcLog)}\n`, { mode: 0o755 });
  const wc = (...a) => spawnSync("bash", [join(BIN, "fleet-webchat.sh"), ...a], { encoding: "utf8",
    env: { ...process.env, HOME: homeOf("b"), FLEET_CONF_DIR: join(HT, "nowhere"), FLEET_WEBCHAT_SERVICE: svcSh, FLEET_SERVICE_LOGIN: "bee" } });
  wc("ensure"); wc("move", "--to", "cee");
  ok(wc("move").status === 2, "J move without --to <login> is a usage error");
  ok(readFileSync(svcLog, "utf8") === "__root ensure --login bee --name webchat --wait 3\nmove webchat --to cee\n",
    `J fleet-webchat.sh ensure / move: the daemon's service ensure / fleet service move (${readFileSync(svcLog, "utf8").trim()})`);
}
// ---- K: idle -------------------------------------------------------------------------
if (part("idle")) {
  mkdirSync(homeOf("k"), { recursive: true });
  SSTATE = stateOf("k"); SOCK = join(SSTATE, "chat.sock");
  const k = (await sstart(["--socket"], { ...asHome("k"), FLEET_WEBCHAT_IDLE_SECS: "1" })).p;
  const gone = new Promise((r) => k.on("exit", (c) => r(c)));
  ok((await sturn("记住青蛙")).lines.at(-1)?.t === "done", "K a turn");
  const page = net.connect(SOCK);                          // a page that is watching holds a connection
  await new Promise((r) => page.on("connect", r));
  await new Promise((r) => setTimeout(r, 2500));
  ok(k.exitCode === null && existsSync(SOCK), "K a page connected: still up past the idle time");
  page.destroy();
  const code = await Promise.race([gone, new Promise((r) => setTimeout(() => r("timeout"), 5000))]);
  ok(code === 75, `K nothing open: it exits 75, the daemon's idle code (${code})`);
  ok(!existsSync(SOCK), "K its socket is gone");
  const k2 = (await sstart(["--socket"], asHome("k"))).p;
  ok(JSON.parse((await sreq("/api/conversation")).body).session === SID, "K started again: the same conversation");
  await sstop(k2);
}
// ---- N: a trial's conversation leaves with its person ----------------------------
if (part("trial")) {
  for (const h of ["ta", "tb"]) mkdirSync(homeOf(h), { recursive: true });
  SSTATE = stateOf("ta"); SOCK = join(SSTATE, "chat.sock");
  const a = (await sstart(["--socket"], asHome("ta"))).p;
  ok((await sturn("甲的青蛙")).lines.at(-1)?.t === "done", "N a turn on login A");
  const ex = await sreq("/api/export", { headers: { "X-Fleet-Person": "p:alice" } });
  const bundle = JSON.parse(ex.body);
  ok(ex.status === 200 && bundle.v === 1 && bundle.home === homeOf("ta") && bundle.sessions.length === 1 &&
    bundle.sessions[0].id === SID && bundle.sessions[0].jsonl.includes("甲的青蛙"), "N export: every session's transcript and the home");
  ok((await sreq("/api/import", { method: "POST", headers: { "Content-Type": "application/json" }, body: bundle })).status === 403,
    "N an import without the page's header is refused");
  ok((await sreq("/api/import", { method: "POST", headers: { "X-Fleet-Webchat": "1", "Content-Type": "application/json" }, body: bundle })).status === 409,
    "N an import onto a login that has a conversation of its own is refused 409");
  await sstop(a);
  // the clean login B: its own state dir, nothing of A's
  SSTATE = stateOf("tb"); SOCK = join(SSTATE, "chat.sock");
  const b = (await sstart(["--socket"], asHome("tb"))).p;
  ok(JSON.parse((await sreq("/api/conversation")).body).items.length === 0, "N login B starts with no conversation");
  const im = await sreq("/api/import", { method: "POST", headers: { "X-Fleet-Webchat": "1", "Content-Type": "application/json" }, body: bundle });
  ok(im.status === 200, `N import onto B (${im.status} ${im.body})`);
  const cb = JSON.parse((await sreq("/api/conversation")).body);
  ok(cb.session === "" && cb.items.some((i) => i.t === "user" && i.text === "甲的青蛙"), "N under B: the history is on the page");
  const trB = join(homeOf("tb"), ".claude", "projects", mangle(homeOf("tb")), SID + ".jsonl");
  ok(existsSync(trB) && (statSync(trB).mode & 0o777) === 0o600, "N the transcript is under B's projects dir (0600)");
  const before = readFileSync(PROMPTLOG, "utf8").split("\n").filter(Boolean).length;
  ok((await sturn("接着说")).lines.at(-1)?.t === "done", "N the next turn on B");
  const prompts = readFileSync(PROMPTLOG, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)).slice(before);
  ok(JSON.parse(readFileSync(ENVLOG, "utf8")).resume === "" && prompts.length === 1 &&
    /<fleet-webchat-relay>[\s\S]*甲的青蛙[\s\S]*<\/fleet-webchat-relay>/.test(prompts[0].prompt) && prompts[0].prompt.endsWith("接着说"),
    "N it is a new session seeded with the last words");
  ok((await sreq("/api/import", { method: "POST", headers: { "X-Fleet-Webchat": "1", "Content-Type": "application/json" }, body: bundle })).status === 409,
    "N a second import onto B is refused 409");
  ok(/"ev":"imported"/.test(readFileSync(join(SSTATE, "server.log"), "utf8")), "N the log says imported");
  await sstop(b);
}
// ---- T: the terminal ⇄ this page (task T810) -------------------------------------------
if (part("handoff")) {
  mkdirSync(homeOf("h"), { recursive: true });
  SSTATE = stateOf("h"); SOCK = join(SSTATE, "chat.sock");
  const LOCKD = join(HT, "locks"), HLOG = join(HT, "handoff.log"), hsh = join(HT, "handoff.sh");
  const OWNER = join(HT, "owner.json"), TBUSY = join(HT, "tbusy");
  mkdirSync(LOCKD, { recursive: true });
  // bin/fleet-webchat-handoff.sh's two answers the server asks for, stubbed
  writeFileSync(hsh, `#!/bin/bash
echo "$*" >>${JSON.stringify(HLOG)}
case "$1" in
  owner) cat ${JSON.stringify(OWNER)} ;;
  to-webchat-take) [ -f ${JSON.stringify(TBUSY)} ] && { echo "正在终端里回答，答完再试" >&2; exit 3; }; echo ok ;;
esac
`, { mode: 0o755 });
  const hs = (await sstart(["--socket"], { ...asHome("h"), FLEET_CONF_DIR: join(HT, "h-fence"), FLEET_WEBCHAT_HANDOFF: hsh, FLEET_WEBCHAT_LOCKDIR: LOCKD })).p;
  ok((await sturn("网页里先说一句")).lines.at(-1)?.t === "done", "T the page's own conversation first");
  // the terminal's session: its transcript where Claude Code keeps it, cwd on every line
  const TID = "99999999-8888-4777-8666-555555555555", TCWD = join(homeOf("h"), "proj");
  mkdirSync(TCWD, { recursive: true });
  const tdir = join(homeOf("h"), ".claude", "projects", mangle(TCWD));
  mkdirSync(tdir, { recursive: true });
  writeFileSync(join(tdir, TID + ".jsonl"), [
    { type: "user", cwd: TCWD, message: { role: "user", content: "终端里第一句" } },
    { type: "assistant", cwd: TCWD, message: { content: [{ type: "tool_use", id: "tt1", name: "Bash", input: { command: "ls" } }] } },
    { type: "user", cwd: TCWD, message: { content: [{ type: "tool_result", tool_use_id: "tt1", content: "a.txt" }] } },
    { type: "assistant", cwd: TCWD, message: { content: [{ type: "text", text: "终端的回答" }] } },
  ].map((m) => JSON.stringify(m)).join("\n") + "\n");
  const H = { "X-Fleet-Webchat": "1", "Content-Type": "application/json" };
  const adopt = (b, headers = H) => sreq("/api/adopt", { method: "POST", headers, body: b });
  ok((await adopt({ agent: "claude", session: TID }, { "Content-Type": "application/json" })).status === 403, "T adopt without the page's header is refused");
  const cx = await adopt({ agent: "codex", session: TID });
  ok(cx.status === 409 && JSON.parse(cx.body).code === "no_codex", "T a Codex session is refused until the page has Codex");
  ok((await adopt({ agent: "claude", session: "../etc" })).status === 400, "T a bad session id is refused 400");
  ok((await adopt({ agent: "claude", session: "00000000-0000-4000-8000-000000000000" })).status === 404, "T a session with no transcript here is 404");
  const ad = await adopt({ agent: "claude", session: TID, label: "scratch-20", machine: "mm", fid: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" });
  ok(ad.status === 200, `T adopt the terminal's session (${ad.status} ${ad.body})`);
  let c = JSON.parse((await sreq("/api/conversation")).body);
  ok(c.session === TID && c.cwd === TCWD, `T the page's conversation is the terminal's session, in its cwd (${c.session} ${c.cwd})`);
  ok(c.items.some((i) => i.t === "user" && i.text === "终端里第一句") && c.items.some((i) => i.t === "tool" && i.id === "tt1") &&
    c.items.some((i) => i.t === "text" && i.d === "终端的回答") && !c.items.some((i) => i.t === "user" && i.text === "网页里先说一句"),
    "T the whole terminal history is on the page, the old one is not");
  ok(c.handed?.from === "terminal" && c.handed.label === "scratch-20", "T the page says it came over from the terminal");
  const kept = JSON.parse(readFileSync(join(SSTATE, "conversation.json"), "utf8")).put_away || [];
  ok(kept.length === 1 && kept[0].session === SID, "T the page's own conversation is put away and kept (新对话's rule), not lost");
  // the terminal holds it: the page reads along, a turn is refused
  writeFileSync(join(LOCKD, `claude-${TID}.json`), JSON.stringify({ holder: "terminal", window_fid: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" }));
  writeFileSync(OWNER, JSON.stringify({ holder: "terminal", busy: true, label: "scratch-20", machine: "mm" }));
  c = JSON.parse((await sreq("/api/conversation")).body);
  ok(c.owner?.where === "terminal" && c.owner.busy === true && c.owner.label === "scratch-20" && !c.handed,
    `T the terminal holds it and is answering: said on the page (${JSON.stringify(c.owner)})`);
  const tb = await sreq("/api/turn", { method: "POST", headers: H, body: { text: "插一句" } });
  ok(tb.status === 409 && JSON.parse(tb.body).code === "terminal", "T a turn while the terminal holds it is refused 409 terminal");
  writeFileSync(TBUSY, "");
  const t1 = await sreq("/api/take", { method: "POST", headers: H, body: {} });
  ok(t1.status === 409 && JSON.parse(t1.body).code === "terminal_busy" && /终端里回答/.test(JSON.parse(t1.body).error),
    "T 在这里继续 while the terminal answers: refused, saying where");
  unlinkSync(TBUSY);
  ok((await sreq("/api/take", { method: "POST", headers: H, body: {} })).status === 200, "T 在这里继续 once it is idle");
  ok(readFileSync(HLOG, "utf8").includes(`to-webchat-take --agent claude --sid ${TID}`), "T take goes through fleet-webchat-handoff.sh");
  writeFileSync(join(LOCKD, `claude-${TID}.json`), JSON.stringify({ holder: "webchat", window_fid: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" }));
  ok((await sturn("网页接着说")).lines.at(-1)?.t === "done" && JSON.parse(readFileSync(ENVLOG, "utf8")).resume === TID,
    "T the page holds it again: the next turn resumes the terminal's session");
  c = JSON.parse((await sreq("/api/conversation")).body);
  ok(!c.owner && !c.handed, "T after a turn here: no owner line, the 已从终端接过来 line said once");
  const st = JSON.parse((await sreq("/api/state")).body);
  ok(st.busy === false && st.session === TID, "T /api/state: not answering, this session");
  ok(/"ev":"adopted"/.test(readFileSync(join(SSTATE, "server.log"), "utf8")), "T the log says adopted");
  // Existing SDK conversation is not authorization after its native FID gains
  // a Task binding. The check reads SQLite again; no provider restart needed.
  const bind = spawnSync("python3", ["-c", `import sys
sys.path.insert(0, sys.argv[1])
from fleet_task_execution import ExecutionFence
f=ExecutionFence(sys.argv[2])
f.bind(dict(task_ref="T42",task_fid="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",generation=1,
 attempt_id="task:T42:g1",operation_id="start-42",execution_endpoint="node-a",
 execution_owner="11111111-1111-4111-8111-111111111111/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",cancel_request=""),authorized=True)
`, BIN, join(HT, "h-fence")], { encoding: "utf8" });
  ok(bind.status === 0, "T real local Task fence is installed after SDK adoption");
  for (const path of ["/api/turn", "/api/take", "/api/answer"]) {
    const r = await sreq(path, { method: "POST", headers: H, body: { text: "must not run" } });
    ok(r.status === 409 && JSON.parse(r.body).code === "native_session_required", `T existing SDK ${path} refuses controlled Task`);
  }
  const denied = await adopt({ agent: "claude", session: TID, fid: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" });
  ok(denied.status === 409, "T controlled Task cannot be re-adopted into legacy SDK");
  await sstop(hs);
}
// ---- V: 只读 — a terminal session followed from the web (task F481) ------------------------
if (part("view")) {
  mkdirSync(homeOf("v"), { recursive: true });
  SSTATE = stateOf("v"); SOCK = join(SSTATE, "chat.sock");
  const VIEW = join(HT, "view.json"), vsh = join(HT, "view.sh"), FID = "12345678-1234-4234-8234-123456789abc";
  // bin/fleet-webchat-handoff.sh view-of, stubbed: the window's agent and conversation
  writeFileSync(vsh, `#!/bin/bash
[ "$1" = view-of ] && [ "$2" = fid:${FID} ] && [ -f ${JSON.stringify(VIEW)} ] && { cat ${JSON.stringify(VIEW)}; exit 0; }
echo "no such window" >&2; exit 2
`, { mode: 0o755 });
  const VID = "77777777-6666-4555-8444-333333333333", VCWD = join(homeOf("v"), "proj");
  mkdirSync(VCWD, { recursive: true });
  const vdir = join(homeOf("v"), ".claude", "projects", mangle(VCWD));
  mkdirSync(vdir, { recursive: true });
  const line = (m) => JSON.stringify({ cwd: VCWD, ...m }) + "\n";
  writeFileSync(join(vdir, VID + ".jsonl"), line({ type: "user", message: { role: "user", content: "终端里问一句" } }) +
    line({ type: "assistant", message: { content: [{ type: "tool_use", id: "v1", name: "Bash", input: { command: "ls" } }] } }) +
    line({ type: "user", message: { content: [{ type: "tool_result", tool_use_id: "v1", content: "a.txt" }] } }) +
    line({ type: "assistant", message: { content: [{ type: "text", text: "终端答了" }] } }));
  writeFileSync(VIEW, JSON.stringify({ agent: "claude", sid: VID, busy: false, state: "done", label: "scratch-7", holder: "" }));
  const CODEXH = join(HT, "codexhome");
  const v = (await sstart(["--socket"], { ...asHome("v"), FLEET_CONF_DIR: join(homeOf("v"), ".config/claude-fleet"), FLEET_WEBCHAT_HANDOFF: vsh, CODEX_HOME: CODEXH,
    FLEET_WEBCHAT_VIEW_POLL_MS: "100", FLEET_WEBCHAT_VIEW_STATE_MS: "300" })).p;
  // one view: its events as they come, until `until` says enough or it times out
  const follow = (q, until, ms = 5000) => new Promise((resolve, reject) => {
    const evs = [];
    const r = http.request({ socketPath: SOCK, path: "/api/view?" + q, headers: { Host: "webchat" } }, (res) => {
      if (res.statusCode !== 200) { let b = ""; res.on("data", (d) => (b += d)); res.on("end", () => resolve({ status: res.statusCode, body: b, evs })); return; }
      let buf = "";
      const t = setTimeout(() => { r.destroy(); resolve({ status: 200, evs, timedOut: true }); }, ms);
      res.on("data", (d) => {
        buf += d; let i;
        while ((i = buf.indexOf("\n\n")) >= 0) {
          const blk = buf.slice(0, i); buf = buf.slice(i + 2);
          const id = (blk.match(/^id: (\d+)$/m) || [])[1], data = (blk.match(/^data: (.*)$/m) || [])[1];
          if (data) evs.push({ id: id == null ? null : Number(id), ...JSON.parse(data) });
        }
        if (until(evs)) { clearTimeout(t); r.destroy(); resolve({ status: 200, evs }); }
      });
    });
    r.on("error", (e) => (e.code === "ECONNRESET" ? null : reject(e)));
    r.end();
  });
  // Closed FID: the real ledger reader and native parser, no window, no worktree.
  const hf = "12345678-1234-4234-8234-123456789012";
  const hd = join(homeOf("v"), ".config/claude-fleet/ids");
  mkdirSync(hd, { recursive: true });
  const hsid = "12345678-1234-4234-8234-123456789013";
  writeFileSync(join(hd, hf + ".ndjson"), [
    { ev: "opened", worktree: "/removed/worktree", repo: "example/app" },
    { ev: "native", agent: "claude", native: hsid }, { ev: "closed", ts: 1 },
  ].map((x, i) => JSON.stringify({ ...x, id: hf, seq: i + 1 })).join("\n") + "\n");
  writeFileSync(join(vdir, hsid + ".jsonl"), line({ sessionId: hsid, type: "user", message: { role: "user", content: "kept history" } }));
  const queriesBefore = existsSync(QUERYLOG) ? readFileSync(QUERYLOG, "utf8") : "";
  const history = await sreq(`/api/view?fid=${hf}&history=1`);
  ok(history.status === 200 && history.body.includes("kept history") && history.body.includes('"history_status":"readable"') &&
    history.body.includes('"can_talk":false') && history.body.includes('"t":"history_end"'), "V closed native history reads without worktree or worker");
  ok((existsSync(QUERYLOG) ? readFileSync(QUERYLOG, "utf8") : "") === queriesBefore, "V history launched no agent");
  const hs = JSON.parse((await sreq(`/api/view?fid=${hf}&history=1&status=1`)).body);
  ok(hs.readable && !hs.resumable && !hs.transcript, "V read and resume capabilities are distinct; no local path exposed");
  ok((await sreq("/api/view?fid=../x")).status === 400, "V a fid that is not one is 400");
  const nf = await sreq("/api/view?fid=00000000-0000-4000-8000-000000000000");
  ok(nf.status === 404 && JSON.parse(nf.body).code === "no_session", "V a window not on this login is 404 no_session");
  // the record so far, then a line the terminal adds, within the 3 s the page promises
  const items = (evs) => evs.filter((e) => e.t === "items");
  const VFILE = join(vdir, VID + ".jsonl");
  const size0 = statSync(VFILE).size;
  const grow = setTimeout(() => appendFileSync(VFILE,
    line({ type: "assistant", message: { content: [{ type: "text", text: "又说了一句" }] } })), 600);
  const t0 = Date.now();
  let f = await follow(`fid=${FID}`, (evs) => items(evs).some((e) => e.items.some((i) => i.d === "又说了一句")));
  clearTimeout(grow);
  const first = items(f.evs)[0];
  ok(f.evs[0]?.t === "state" && f.evs[0].agent === "claude" && f.evs[0].session === VID && f.evs[0].label === "scratch-7",
    `V first the state: which agent, which conversation (${JSON.stringify(f.evs[0])})`);
  ok(first?.replace === true && first.at === size0 && first.id === size0 && first.older === 0 && first.session === VID &&
    first.items.map((i) => i.t).join(",") === "user,tool,tool_result,text",
    `V then the record so far, in place of what the page had; at = the byte read to (${JSON.stringify(first)})`);
  const size1 = statSync(VFILE).size;
  const added = items(f.evs).find((e) => e.items.some((i) => i.d === "又说了一句"));
  ok(added && !added.replace && added.at === size1 && added.items.length === 1 && Date.now() - t0 < 3000,
    `V a line the terminal adds arrives alone, at its end, in under 3 s (${Date.now() - t0} ms)`);
  // back from a drop with ?at= (same conversation): nothing twice; then it answers — the state says so
  setTimeout(() => writeFileSync(VIEW, JSON.stringify({ agent: "claude", sid: VID, busy: true, state: "working", label: "scratch-7", holder: "" })), 300);
  f = await follow(`fid=${FID}&at=${size1}&s=${VID}`, (evs) => evs.some((e) => e.t === "state" && e.busy));
  ok(items(f.evs).length === 1 && !items(f.evs)[0].replace && items(f.evs)[0].items.length === 0 && items(f.evs)[0].at === size1 && !f.evs.some((e) => e.t === "reset"),
    `V ?at=: no line again (${JSON.stringify(items(f.evs))})`);
  ok(f.evs.some((e) => e.t === "state" && e.busy === true && e.state === "working"), "V the terminal answering: a state with busy");
  // ?at= of another conversation: from this one's end, in place
  f = await follow(`fid=${FID}&at=3&s=99999999-6666-4555-8444-333333333333`, (evs) => items(evs).length > 0);
  ok(items(f.evs)[0]?.replace === true && items(f.evs)[0].items.length === 5, "V ?at= of another conversation: the newest stretch, in place");
  // a long record (task YP39): the first answer is the newest 200 items read from its end; ?before= the page before
  const LID = "77777777-6666-4555-8444-444444444444";
  let long = "";
  for (let i = 0; i < 400; i++) long += line({ type: i % 2 ? "assistant" : "user", message: { content: i % 2 ? [{ type: "text", text: `答 ${i}` }] : `问 ${i}` } });
  writeFileSync(join(vdir, LID + ".jsonl"), long);
  writeFileSync(VIEW, JSON.stringify({ agent: "claude", sid: LID, busy: false, state: "done", label: "scratch-7", holder: "" }));
  f = await follow(`fid=${FID}`, (evs) => items(evs).some((e) => e.session === LID));
  const lf = items(f.evs).find((e) => e.session === LID);
  ok(lf?.replace && lf.items.length === 200 && (lf.items[0].text || lf.items[0].d) === "问 200" && lf.older > 0,
    `V a long record: the newest 200, older from byte ${lf?.older} (${lf?.items.length} · ${JSON.stringify(lf?.items[0])})`);
  const old1 = JSON.parse((await sreq(`/api/view?fid=${FID}&before=${lf.older}`)).body);
  ok(old1.items.length === 200 && (old1.items.at(-1).text || old1.items.at(-1).d) === "答 199" && old1.older === 0 && old1.session === LID,
    `V ?before=: the 200 before, joined end to end, then none older (${old1.items.length} · ${old1.older})`);
  ok((await sreq(`/api/view?fid=${FID}&before=-1`)).status === 400, "V a bad ?before= is 400");
  // a step's output: its start read along, the whole when it is opened (?tool=)
  const TID2 = "77777777-6666-4555-8444-666666666666", big = "x".repeat(1000) + "END";
  writeFileSync(join(vdir, TID2 + ".jsonl"), line({ type: "user", message: { content: "跑一下" } }) +
    line({ type: "assistant", message: { content: [{ type: "tool_use", id: "tb1", name: "Bash", input: { command: "yes" } }] } }) +
    line({ type: "user", message: { content: [{ type: "tool_result", tool_use_id: "tb1", content: big }] } }));
  writeFileSync(VIEW, JSON.stringify({ agent: "claude", sid: TID2, busy: false, state: "done", label: "scratch-7", holder: "" }));
  f = await follow(`fid=${FID}`, (evs) => items(evs).some((e) => e.session === TID2));
  const tr = items(f.evs).find((e) => e.session === TID2)?.items.find((i) => i.t === "tool_result");
  ok(tr?.more === true && tr.text.length < 200 && !tr.text.includes("END"), `V a long step output: its start only, marked more (${tr?.text.length})`);
  const whole = await sreq(`/api/view?fid=${FID}&tool=tb1`);
  ok(whole.status === 200 && JSON.parse(whole.body).text.endsWith("END"), "V ?tool=: the step's whole output");
  ok((await sreq(`/api/view?fid=${FID}&tool=nope`)).status === 404 && (await sreq(`/api/view?fid=${FID}&tool=a%20b`)).status === 400,
    "V ?tool= of no step is 404, of a bad id 400");
  // a session that has said nothing yet: an empty first answer at once, its record once there
  const NID = "77777777-6666-4555-8444-555555555555";
  writeFileSync(VIEW, JSON.stringify({ agent: "claude", sid: NID, busy: false, state: "idle", label: "scratch-7", holder: "" }));
  setTimeout(() => writeFileSync(join(vdir, NID + ".jsonl"), line({ type: "user", message: { content: "第一句" } })), 500);
  f = await follow(`fid=${FID}`, (evs) => items(evs).some((e) => e.items.some((i) => i.text === "第一句")), 8000);
  // (the window's last answer comes first — the conversation it ran a moment ago — then this one's)
  const nr = items(f.evs).filter((e) => e.session === NID);
  ok(nr[0]?.replace && nr[0].items.length === 0 && nr.some((e) => e.replace && e.items.some((i) => i.text === "第一句")),
    `V no record yet: an empty first answer, then its first line in place (${JSON.stringify(nr)})`);
  // the window closed while watched: gone, and the stream ends
  setTimeout(() => unlinkSync(VIEW), 300);
  f = await follow(`fid=${FID}`, (evs) => evs.some((e) => e.t === "gone"));
  ok(f.evs.some((e) => e.t === "gone"), "V the window closed: {t:gone}");
  // a Codex session: its rollout, read the same way (R9A2's reader)
  const THR = "0199aaaa-bbbb-7ccc-8ddd-eeeeffff0001", rdir = join(CODEXH, "sessions", "2026", "10", "21");
  mkdirSync(rdir, { recursive: true });
  const rl = (o) => JSON.stringify(o) + "\n";
  writeFileSync(join(rdir, `rollout-2026-10-21T00-00-00-${THR}.jsonl`), rl({ type: "session_meta", payload: { cwd: VCWD } }) +
    rl({ type: "event_msg", payload: { type: "item_completed", item: { type: "UserMessage", content: [{ type: "text", text: "Codex 里问" }] } } }) +
    rl({ type: "event_msg", payload: { type: "item_completed", item: { type: "AgentMessage", content: [{ type: "text", text: "Codex 答" }] } } }));
  writeFileSync(VIEW, JSON.stringify({ agent: "codex", sid: THR, busy: false, state: "done", label: "scratch-8", holder: "" }));
  f = await follow(`fid=${FID}`, (evs) => items(evs).length > 0);
  ok(f.evs[0]?.agent === "codex" && items(f.evs)[0]?.items.map((i) => i.text || i.d).join("|") === "Codex 里问|Codex 答",
    `V a Codex session: its rollout's lines (${JSON.stringify(items(f.evs)[0])})`);
  ok(/"ev":"view"/.test(readFileSync(join(SSTATE, "server.log"), "utf8")), "V the log says view");
  await sstop(v);
}
// A resident server must follow helper scripts through the stable install entry,
// even though Node resolved import.meta.url to the release that started it.
if (part("release")) {
  SSTATE = stateOf("release"); SOCK = join(SSTATE, "chat.sock");
  const a = join(HT, "release-a"), b = join(HT, "release-b"), current = join(HT, "current");
  const fid = "abcdef12-1234-4234-8234-12345678aaaa", nextFid = "abcdef12-1234-4234-8234-12345678bbbb";
  for (const [dir, version] of [[a, "old"], [b, "new"]]) {
    mkdirSync(join(dir, "bin"), { recursive: true });
    writeFileSync(join(dir, "bin/fleet_session_gate.py"), `import json
print(json.dumps({"can_talk": True, "why": "${version}", "queue": []}))
`);
    writeFileSync(join(dir, "bin/dash-raw-session.sh"), `#!/bin/bash
printf '@9\\t${version}\\t\\t${version === "new" ? nextFid : fid}\\n'
`, { mode: 0o755 });
  }
  symlinkSync(a, current);
  const p = (await sstart(["--socket"], { ...asHome("release"), FLEET_WEBCHAT_BIN: join(current, "bin"),
    FLEET_WEBCHAT_GATE: undefined, FLEET_WEBCHAT_RAW: undefined, FLEET_WEBCHAT_FLEET: "fleet" })).p;
  sserver = p;
  const first = JSON.parse((await sreq(`/api/session?fid=${fid}`)).body);
  ok(first.why === "old", "Z resident service initially calls release A gate");
  symlinkSync(b, current + ".next"); renameSync(current + ".next", current);
  const next = JSON.parse((await sreq(`/api/session?fid=${fid}`)).body);
  ok(next.why === "new" && p.exitCode === null, "Z same process calls release B gate after stable switch");
  const opened = await sreq("/api/open", { method: "POST", headers: { "X-Fleet-Webchat": "1", "Content-Type": "application/json" }, body: { text: "same service after release" } });
  ok(opened.status === 200 && JSON.parse(opened.body).fid === nextFid, "Z new session uses current release launcher after stable switch");
  await sstop(p); sserver = null;
}

// A healthy old resident can ignore new JSON fields. An owned probe needs a
// distinct route: the old API must refuse it without opening an ordinary web.
if (part("probe-contract")) {
  const fid = "abcdef12-1234-4234-8234-12345678aaaa";
  const raw = join(HT, "probe-raw.sh"), calls = join(HT, "probe-calls");
  writeFileSync(raw, `#!/bin/bash
printf '%s\\n' "$*" >> '${calls}'
printf '@9\\tfixture\\t\\t${fid}\\n'
`, { mode: 0o755 });
  const PAGE = { "X-Fleet-Webchat": "1", "Content-Type": "application/json" };
  const open = (path, body) => sreq(path, { method: "POST", headers: PAGE, body });
  // Retain the real server/auth/body parser, remove only the new API dispatch.
  // This models the resident's fixed route table, independent of helper version.
  const oldDir = join(HT, "old-probe-api"); mkdirSync(oldDir);
  for (const f of ["lib.mjs", "codex.mjs", "execution.mjs"]) symlinkSync(join(dirname(APP), f), join(oldDir, f));
  const oldApp = join(oldDir, "server.mjs");
  writeFileSync(oldApp, readFileSync(APP, "utf8").split("\n")
    .filter((l) => !l.includes('if (p === "/api/open/probe"')).join("\n"));
  const env = { ...asHome("probe-contract"), FLEET_WEBCHAT_RAW: raw, FLEET_WEBCHAT_FLEET: "fleet" };
  SSTATE = stateOf("old-probe-api"); SOCK = join(SSTATE, "chat.sock");
  sserver = (await sstart(["--socket"], env, oldApp)).p;
  ok((await sreq("/healthz")).status === 200, "P old resident is healthy without the probe route");
  let r = await open("/api/open/probe", { text: "temporary", parent_fid: fid });
  ok(r.status === 404 && !existsSync(calls), "P old resident refuses probe without spawning ordinary web");
  await sstop(sserver); sserver = null;
  SSTATE = stateOf("new-probe-api"); SOCK = join(SSTATE, "chat.sock");
  sserver = (await sstart(["--socket"], env)).p;
  for (const body of [{ text: "missing owner" }, { text: "bad owner", parent_fid: "scratch-1" },
    { text: "conflicting purpose", parent_fid: fid, purpose: "web" }]) {
    r = await open("/api/open/probe", body);
    ok(r.status === 400 && !existsSync(calls), "P invalid probe is refused before spawn");
  }
  r = await open("/api/open/probe", { text: "temporary", parent_fid: fid });
  const reply = JSON.parse(r.body);
  ok(r.status === 200 && reply.reap_origin === "probe" && reply.origin_fid === fid &&
    existsSync(calls) && readFileSync(calls, "utf8").includes(`--origin ${fid} --print --no-repo --node local --reap-origin probe`),
    "P explicit probe route preserves ownership through the official spawner");
  r = await open("/api/open", { text: "ordinary web" });
  ok(r.status === 200 && readFileSync(calls, "utf8").includes("--origin hub --print --no-repo --node local --reap-origin web"),
    "P ordinary web retains its existing source");
  await sstop(sserver); sserver = null;
}

// ---- Y: the session gate (task HHV0) — /api/say · stop · answer · open · view's state -----
if (part("legacy-migration")) {
  SSTATE = join(HS, "legacy-state"); SOCK = join(SSTATE, "chat.sock");
  mkdirSync(SSTATE, { recursive: true });
  const a = "11111111-1111-4111-8111-111111111111", b = "22222222-2222-4222-8222-222222222222";
  const c = "33333333-3333-4333-8333-333333333333", d = "44444444-4444-4444-8444-444444444444";
  const ids = join(HS, "legacy-ids");
  writeFileSync(join(SSTATE, "conversation.json"), JSON.stringify({ session: b, cwd: T, chain: [], put_away: [{ session: a, cwd: T }] }));
  writeFileSync(join(SSTATE, "conversation-codex.json"), JSON.stringify({ thread: d, cwd: T, put_away: [{ thread: c }] }));
  sserver = (await sstart(["--socket"], { FLEET_WEBCHAT_BIN: BIN, FLEET_ID_DIR: ids, FLEET_ID_PUSH: "0" })).p;
  const opts = { method: "POST", headers: { "X-Fleet-Webchat": "1" } };
  const statusBefore = JSON.parse((await sreq("/api/migration")).body);
  ok(!statusBefore.migrated && !existsSync(ids), "migration status is a read without ledger writes");
  // A turn may still be reading its body, before either backend sets live.
  // Migration must not snapshot that gap and retire the conversation under it.
  const slow = http.request({ socketPath: SOCK, path: "/api/turn", method: "POST", headers: { "X-Fleet-Webchat": "1", "Content-Type": "application/json" } });
  const finished = new Promise((resolve) => slow.on("response", (r) => { r.resume(); r.on("end", resolve); }));
  slow.write('{');
  for (let i = 0; i < 100; i++) {
    if (JSON.parse((await sreq("/api/busy")).body).busy) break;
    await new Promise((r) => setTimeout(r, 20));
  }
  ok(JSON.parse((await sreq("/api/migrate", opts)).body).why === "busy" && !existsSync(ids), "migration waits for a legacy request still reading its body");
  slow.end('}'); await finished;
  const first = await sreq("/api/migrate", opts), j = JSON.parse(first.body);
  ok(first.status === 200 && j.ok && j.fid && j.codex_fid && j.fid !== j.codex_fid, "migration both assistants have distinct ordinary history identities");
  const statusAfter = JSON.parse((await sreq("/api/migration")).body);
  ok(statusAfter.migrated && statusAfter.fid === j.fid && statusAfter.codex_fid === j.codex_fid, "migration status resolves both bookmarks by identity");
  const ledgers = readdirSync(ids).filter((f) => f.endsWith(".ndjson"));
  ok(ledgers.length === 4 && ledgers.every((f) => /"ev":"closed"/.test(readFileSync(join(ids, f), "utf8"))), "migration current and put-away conversations are retained without starting agents");
  const before = ledgers.map((f) => readFileSync(join(ids, f), "utf8")).join("");
  const again = JSON.parse((await sreq("/api/migrate", opts)).body);
  ok(again.already && again.fid === j.fid && again.codex_fid === j.codex_fid && before === ledgers.map((f) => readFileSync(join(ids, f), "utf8")).join(""), "migration retry changes no identity or history");
  ok(JSON.parse(readFileSync(join(SSTATE, "conversation.json"))).session === b && JSON.parse(readFileSync(join(SSTATE, "conversation-codex.json"))).thread === d, "migration original conversation pointers are retained");
  for (const provider of ["claude", "codex"]) {
    ok((await sreq(`/api/turn?provider=${provider}`, { ...opts, body: { text: "must not execute" } })).status === 410, `migration ${provider} old execution route is retired`);
  }
  await sstop(sserver); sserver = null;
}

if (part("gate")) {
  mkdirSync(homeOf("y"), { recursive: true });
  SSTATE = stateOf("y"); SOCK = join(SSTATE, "chat.sock");
  const FID = "abcdef12-1234-4234-8234-12345678aaaa", GONE = "abcdef12-1234-4234-8234-12345678bbbb";
  const GLOG = join(HT, "gate.log"), gpy = join(HT, "gate.py"), rsh = join(HT, "raw.sh"), RLOG = join(HT, "raw.log");
  const GFAIL = join(HT, "first-probe-fails");
  writeFileSync(GFAIL, "1");
  const VID = "77777777-6666-4555-8444-33333333aaaa";
  // bin/fleet_session_gate.py, stubbed: its argv + stdin logged, a fixed answer printed
  writeFileSync(gpy, `import json, sys, os, time
a = sys.argv[1:]
data = sys.stdin.read()
open(${JSON.stringify(GLOG)}, "a").write(json.dumps({"argv": a, "stdin": data}) + "\\n")
fid = a[a.index("--fid") + 1] if "--fid" in a else ""
if fid == ${JSON.stringify(GONE)}:
    print(json.dumps({"ok": False, "why": "no_session", "state": "refused", "reason": "no_session"})); sys.exit(0)
if a[0] == "say":
    print(json.dumps({"delivery": "d1d1d1d1-0000-4000-8000-000000000001", "state": "queued", "reason": "busy"}))
elif a[0] == "status":
    time.sleep(0.2)
    if os.path.exists(${JSON.stringify(GFAIL)}):
        os.unlink(${JSON.stringify(GFAIL)}); time.sleep(5); sys.exit(1)
    print(json.dumps({"can_talk": True, "why": "", "continuation": {"state": "continued", "to": "codex", "message": "已换 Codex 继续。"}, "queue": [{"delivery": "d1", "text": "排着的", "why": "busy", "state": "queued"}]}))
elif a[0] == "stop":
    print(json.dumps({"ok": True, "how": "escape"}))
elif a[0] == "answer":
    print(json.dumps({"ok": True, "why": ""}))
else:
    print(json.dumps({"ok": True}))
`);
  // dash-raw-session.sh, stubbed: the headless receipt (window · name · worktree · fid)
  writeFileSync(rsh, `#!/bin/bash
echo "$*" >> ${JSON.stringify(RLOG)}
for a in "$@"; do case "$a" in --prompt-file=*) cat "\${a#--prompt-file=}" >> ${JSON.stringify(RLOG)}; echo >> ${JSON.stringify(RLOG)} ;; esac; done
printf '@9\\tweb-1\\t\\t%s\\n' ${FID}
`, { mode: 0o755 });
  const vsh = join(HT, "yview.sh");
  writeFileSync(vsh, `#!/bin/bash
[ "$1" = view-of ] && [ "$2" = fid:${FID} ] && { echo '{"agent":"claude","sid":"${VID}","busy":false,"state":"done","label":"web-1","holder":""}'; exit 0; }
exit 2
`, { mode: 0o755 });
  const y = (await sstart(["--socket"], { ...asHome("y"), FLEET_WEBCHAT_GATE: gpy, FLEET_WEBCHAT_RAW: rsh, FLEET_WEBCHAT_HANDOFF: vsh,
    FLEET_WEBCHAT_FLEET: "fleet", FLEET_GATE_DIR: join(HT, "gate-dir"), FLEET_WEBCHAT_GATE_STATUS_TIMEOUT_MS: "1000", FLEET_WEBCHAT_GATE_STATE_MS: "100", FLEET_WEBCHAT_VIEW_STATE_MS: "200", FLEET_WEBCHAT_VIEW_POLL_MS: "100" })).p;
  const PAGE = { "X-Fleet-Webchat": "1", "Content-Type": "application/json" };
  const calls = () => existsSync(GLOG) ? readFileSync(GLOG, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];
  ok((await sreq("/api/say", { method: "POST", headers: { "Content-Type": "application/json" }, body: { fid: FID, text: "x" } })).status === 403,
    "Y a sentence not from the page is 403");
  ok((await sreq("/api/say", { method: "POST", headers: PAGE, body: { fid: "../x", text: "x" } })).status === 400, "Y a fid that is not one is 400");
  let r = await sreq("/api/say", { method: "POST", headers: PAGE, body: { fid: FID, text: "  在吗  " } });
  let j = JSON.parse(r.body);
  ok(r.status === 200 && j.state === "queued" && j.reason === "busy" && j.delivery, `Y say: the gate's answer, verbatim (${r.body})`);
  let c = calls().at(-1);
  ok(c.argv.join(" ") === `say --fid ${FID}` && c.stdin === "在吗", `Y say: the words on the gate's stdin, never its argv (${JSON.stringify(c)})`);
  // a picture rides as a file in media/, named to the gate
  const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
  r = await sreq("/api/say", { method: "POST", headers: PAGE, body: { fid: FID, text: "看图", images: [{ media_type: "image/png", data: PNG }] } });
  c = calls().at(-1);
  ok(r.status === 200 && c.argv.includes("--image") && existsSync(c.argv[c.argv.indexOf("--image") + 1]), `Y a picture is kept in media/ and named to the gate (${JSON.stringify(c.argv)})`);
  r = await sreq("/api/say", { method: "POST", headers: PAGE, body: { fid: FID, text: "x", images: [1, 2, 3, 4, 5].map(() => ({ media_type: "image/png", data: PNG })) } });
  ok(r.status === 400, "Y a fifth picture is refused on the spot");
  // stop / answer with the fid in the body (the entry writes it there) are the gate's
  r = await sreq("/api/stop", { method: "POST", headers: PAGE, body: { fid: FID } });
  ok(r.status === 200 && JSON.parse(r.body).how === "escape" && calls().at(-1).argv.join(" ") === `stop --fid ${FID}`, `Y stop by the body's fid (${r.body})`);
  r = await sreq("/api/answer", { method: "POST", headers: PAGE, body: { fid: FID, fingerprint: "0123456789abcdef", options: ["狗"] } });
  ok(r.status === 200 && calls().at(-1).argv.join(" ") === `answer --fid ${FID} --fp 0123456789abcdef --pick 狗`, `Y answer: the fingerprint and the option's own words (${JSON.stringify(calls().at(-1).argv)})`);
  await sreq("/api/answer", { method: "POST", headers: PAGE, body: { fid: FID, fp: "0123456789abcdef", answers: { "猫还是狗？": "狗" } } });
  ok(calls().at(-1).argv.join(" ") === `answer --fid ${FID} --fp 0123456789abcdef --answers-json {"猫还是狗？":"狗"}`, `Y answer: {question: label} handed on whole (${JSON.stringify(calls().at(-1).argv)})`);
  await sreq("/api/answer", { method: "POST", headers: PAGE, body: { fid: FID, fp: "0123456789abcdef", allow: false } });
  ok(calls().at(-1).argv.join(" ") === `answer --fid ${FID} --fp 0123456789abcdef --allow 0`, "Y answer: a permission's allow / deny");
  ok((await sreq("/api/answer", { method: "POST", headers: PAGE, body: { fid: FID, fp: "nope", picks: ["狗"] } })).status === 400, "Y a malformed fingerprint is 400");
  r = await sreq("/api/stop", { method: "POST", headers: PAGE, body: { fid: GONE } });
  ok(r.status === 404 && JSON.parse(r.body).code === "no_session", `Y a session not here: 404 WITH a code (a bare 404 is an old service) (${r.body})`);
  // a new session from the web: no-repo, origin web, its first words the start's first turn
  r = await sreq("/api/open", { method: "POST", headers: PAGE, body: { agent: "claude", text: "开个新的" } });
  j = JSON.parse(r.body);
  const rl = existsSync(RLOG) ? readFileSync(RLOG, "utf8") : "";
  ok(r.status === 200 && j.fid === FID && j.state === "sent", `Y open: the new session's fid (${r.body})`);
  ok(/^fleet --origin hub --print --no-repo --node local --reap-origin web --agent claude --prompt-file=/m.test(rl) && rl.includes("开个新的"),
    `Y open: a no-repo window of this login, origin web, the words its first turn (${rl})`);
  ok((await sreq("/api/open", { method: "POST", headers: PAGE, body: { agent: "gpt", text: "x" } })).status === 400, "Y open: an unknown agent is 400");
  r = await sreq("/api/open", { method: "POST", headers: PAGE, body: { text: "默认的" } });
  const rl2 = readFileSync(RLOG, "utf8").trim().split("\n").filter((l) => l.startsWith("fleet ")).pop() || "";
  ok(r.status === 200 && !/--agent/.test(rl2), `Y open: no agent chosen ⇒ none passed, the fleet's default decides (${rl2})`);
  // C6 / T965: only an explicitly owned temporary probe gets the probe policy.
  r = await sreq("/api/open", { method: "POST", headers: PAGE,
    body: { purpose: "probe", parent_fid: FID, text: "临时验收" } });
  const probeLine = readFileSync(RLOG, "utf8").trim().split("\n").filter((l) => l.startsWith("fleet ")).pop() || "";
  ok(r.status === 200 && probeLine.startsWith(`fleet --origin ${FID} --print --no-repo --node local --reap-origin probe `),
    `Y probe: formal spawn gets explicit source and parent identity (${probeLine})`);
  ok((await sreq("/api/open", { method: "POST", headers: PAGE,
    body: { purpose: "probe", text: "无归属" } })).status === 400, "Y probe: an owner is required");
  ok((await sreq("/api/open", { method: "POST", headers: PAGE,
    body: { purpose: "probe", parent_fid: "scratch-1", text: "name is not identity" } })).status === 400,
    "Y probe: a name cannot replace the parent identity");
  ok((await sreq("/api/open", { method: "POST", headers: PAGE,
    body: { purpose: "anything", parent_fid: FID, text: "x" } })).status === 400, "Y probe: unknown purpose is refused");
  const probeAt = Date.now();
  const probes = await Promise.all([sreq(`/api/session?fid=${FID}`), sreq(`/api/session?fid=${FID}`)]);
  ok(probes.every((r) => r.status === 503) && Date.now() - probeAt < 3000,
    "Y hung capability probe has a bound and stays unavailable");
  ok(calls().filter(c => c.argv[0] === "status").length === 1,
    "Y simultaneous readers share one capability probe for the same session");
  writeFileSync(GFAIL, "1");
  // the view's state line: can_talk and the queue, no holder
  const st = await new Promise((resolve) => {
    const evs = [];
    let failedAgain = false;
    const q = http.request({ socketPath: SOCK, path: `/api/view?fid=${FID}`, headers: { Host: "webchat" } }, (res) => {
      let buf = "";
      const t = setTimeout(() => { q.destroy(); resolve(evs); }, 5000);
      res.on("data", (d) => {
        buf += d; let i;
        while ((i = buf.indexOf("\n\n")) >= 0) {
          const data = (buf.slice(0, i).match(/^data: (.*)$/m) || [])[1]; buf = buf.slice(i + 2);
          if (data) evs.push(JSON.parse(data));
        }
        const states = evs.filter((e) => e.t === "state");
        const writable = states.findIndex((e) => e.can_talk === true);
        if (writable >= 0 && !failedAgain) { failedAgain = true; writeFileSync(GFAIL, "1"); }
        const lost = states.findIndex((e, i) => i > writable && e.talk_reason === "unreachable");
        if (writable >= 0 && lost > writable && states.slice(lost + 1).some((e) => e.can_talk === true)) { clearTimeout(t); q.destroy(); resolve(evs); }
      });
    });
    q.on("error", () => resolve(evs));
    q.end();
  });
  const last = st.filter((e) => e.t === "state").at(-1) || {};
  ok(st.find((e) => e.t === "state")?.can_talk === null,
    "Y a cold view is checking, never read-only before the gate answers");
  ok(st.some((e) => e.t === "state" && e.can_talk === null && e.talk_reason === "unreachable"),
    "Y a failed capability probe is unavailable, never a read-only verdict");
  const states = st.filter((e) => e.t === "state");
  const writable = states.findIndex((e) => e.can_talk === true);
  const lost = states.findIndex((e, i) => i > writable && e.talk_reason === "unreachable");
  ok(writable >= 0 && lost > writable && states.slice(lost + 1).some((e) => e.can_talk === true),
    "Y capability failure after a writable frame recovers on the same stream");
  ok(calls().filter(c => c.argv[0] === "status").length >= 2,
    "Y a delayed failed probe retries and recovers on the same stream");
  ok(last.can_talk === true && last.continuation?.state === "continued" && last.continuation.to === "codex" && last.queue?.[0]?.text === "排着的" && last.queue[0].why === "busy" && !("holder" in last),
    `Y the view's state says can_talk and what waits, no holder (${JSON.stringify(last)})`);
  await sstop(y);
}
// ---- X: 接管 / 交回 (task VV8F) — /api/takeover · /api/giveback by window -------------
if (part("handover")) {
  mkdirSync(homeOf("x"), { recursive: true });
  SSTATE = stateOf("x"); SOCK = join(SSTATE, "chat.sock");
  const XV = join(HT, "xview.json"), XLOG = join(HT, "xhandoff.log"), xsh = join(HT, "xhandoff.sh"), FID = "abcdef12-1234-4234-8234-123456789abc";
  // bin/fleet-webchat-handoff.sh's view-of · to-web · give-back, stubbed on a state file
  writeFileSync(xsh, `#!/bin/bash
V=${JSON.stringify(XV)}
echo "$*" >> ${JSON.stringify(XLOG)}
case "$1" in
  view-of) [ "$2" = fid:${FID} ] && { cat "$V"; exit 0; }; exit 2 ;;
  to-web) sleep 0.4; sed -i.bak 's/"holder": ""/"holder": "webchat"/' "$V"; echo ok ;;
  give-back) sed -i.bak 's/"holder": "webchat"/"holder": "terminal"/' "$V"; echo ok ;;
esac
`, { mode: 0o755 });
  const put = (o) => writeFileSync(XV, JSON.stringify({ agent: "claude", sid: "77777777-6666-4555-8444-333333333333", busy: false, state: "done", label: "scratch-9", holder: "", ...o }).replace(/":/g, '": '));
  put({ busy: true, state: "working" });
  const x = (await sstart(["--socket"], { ...asHome("x"), FLEET_WEBCHAT_HANDOFF: xsh })).p;
  const post = (p, fid = FID, hdr = { "X-Fleet-Webchat": "1" }) => sreq(p, { method: "POST", headers: { "Content-Type": "application/json", ...hdr }, body: { fid } });
  ok((await post("/api/takeover", FID, {})).status === 403, "X a takeover not from the page is 403");
  ok((await post("/api/takeover", "../x")).status === 400, "X a fid that is not one is 400");
  ok((await post("/api/takeover", "00000000-0000-4000-8000-000000000000")).status === 404, "X a window not here is 404");
  let r = await post("/api/takeover");
  ok(r.status === 409 && JSON.parse(r.body).code === "terminal_busy", `X the terminal answering: 409 terminal_busy (${r.body})`);
  put({});
  const [a, b] = await Promise.all([post("/api/takeover"), post("/api/takeover")]);
  const codes = [a, b].map((q) => q.status).sort().join(",");
  ok(codes === "200,409" && [a, b].some((q) => JSON.parse(q.body).code === "taking"), `X two at once: one taken, the other 409 taking (${a.body} | ${b.body})`);
  ok(readFileSync(XLOG, "utf8").split("\n").filter((l) => l.startsWith("to-web")).length === 1 &&
    readFileSync(XLOG, "utf8").includes(`to-web fid:${FID} --no-open`), "X one to-web, without opening a page");
  r = await post("/api/takeover");
  ok(r.status === 200 && JSON.parse(r.body).already === true, "X taken already: 200 already");
  r = await post("/api/giveback");
  ok(r.status === 200 && JSON.parse(r.body).agent === "claude" && readFileSync(XLOG, "utf8").includes(`give-back fid:${FID}`), `X 交回: give-back by the window (${r.body})`);
  r = await post("/api/giveback");
  ok(r.status === 200 && JSON.parse(r.body).already === true, "X given back already: 200 already");
  ok(/"ev":"took over"/.test(readFileSync(join(SSTATE, "server.log"), "utf8")) && /"ev":"gave back"/.test(readFileSync(join(SSTATE, "server.log"), "utf8")), "X the log says took over / gave back");
  await sstop(x);
}
// ---- P: images (task T773) -------------------------------------------------------------
if (part("media")) {
  mkdirSync(homeOf("m"), { recursive: true });
  SSTATE = stateOf("m"); SOCK = join(SSTATE, "chat.sock");
  const m = (await sstart(["--socket"], { ...asHome("m"), FLEET_WEBCHAT_IMAGE_MAX: "200", FLEET_WEBCHAT_IMAGES_PER_REPLY: "3" })).p;
  const live = (await sturn("pic")).lines;
  const imgs = live.filter((o) => o.t === "image");
  ok(imgs.length === 3 && imgs[0].id === "tu-pic" && imgs[0].w === 1 && imgs[0].h === 1 && /^[0-9a-f]{32}\.png$/.test(imgs[0].ref) &&
    imgs[1].ref && imgs[1].ref !== imgs[0].ref && imgs[2].big === true && !imgs[2].ref, `P live: the tool's image, the reply's, one too big (${JSON.stringify(imgs)})`);
  ok(live.filter((o) => o.t === "image_more").length === 1, "P live: the fourth image is counted, not shown");
  ok(!live.some((o) => JSON.stringify(o).includes("iVBOR")), "P live: no image bytes in the stream");
  const f = await new Promise((resolve, reject) => {
    const r = http.request({ socketPath: SOCK, path: "/api/file?ref=" + imgs[0].ref, headers: { Host: "webchat" } }, (res) => {
      const parts = []; res.on("data", (d) => parts.push(d)); res.on("end", () => resolve({ status: res.statusCode, h: res.headers, body: Buffer.concat(parts) }));
    });
    r.on("error", reject); r.end();
  });
  ok(f.status === 200 && f.h["content-type"] === "image/png" && f.body.subarray(0, 8).toString("hex") === "89504e470d0a1a0a" && f.body.toString().endsWith("one"),
    `P /api/file: the image's own bytes, as image/png (${f.status} ${f.h["content-type"]})`);
  ok(/sandbox/.test(f.h["content-security-policy"] || "") && f.h["x-content-type-options"] === "nosniff" && /immutable/.test(f.h["cache-control"] || ""),
    "P /api/file: a sandbox CSP, nosniff, kept by the browser");
  for (const bad of ["../conversation.json", imgs[0].ref.replace(".png", ".html"), "0".repeat(32) + ".png", ""]) {
    ok((await sreq("/api/file?ref=" + encodeURIComponent(bad))).status === 404, `P /api/file refuses ${JSON.stringify(bad)}`);
  }
  const media = join(SSTATE, "media");
  ok(mode(media) === 0o700 && readdirSync(media).filter((x) => !/thumb/.test(x)).every((x) => mode(join(media, x)) === 0o600), "P media/ is 0700, each image 0600");
  // the person's own picture, as a later turn will write it (C): on their line
  const tr = join(homeOf("m"), ".claude", "projects", mangle(homeOf("m")), SID + ".jsonl");
  const pic = readFileSync(tr, "utf8").match(/"data":"([^"]+)"/)[1];
  writeFileSync(tr, readFileSync(tr, "utf8") + JSON.stringify({ type: "user", message: { role: "user", content: [
    { type: "image", source: { type: "base64", media_type: "image/png", data: pic } }, { type: "text", text: "这张呢" }] } }) + "\n");
  const items = JSON.parse((await sreq("/api/conversation")).body).items;
  const mine = items.find((i) => i.t === "user" && i.text === "这张呢");
  ok(mine?.images?.length === 1 && mine.images[0].ref === imgs[0].ref, "P read back: the person's picture rides on their line");
  ok(items.filter((i) => i.t === "image").length === 3 && items.some((i) => i.t === "image_more") && !JSON.stringify(items).includes("iVBOR"),
    "P read back: the same images, the same count past the bound, no bytes");
  if (["/usr/bin/sips", "/usr/bin/convert", "/usr/bin/magick", "/opt/homebrew/bin/magick", "/usr/local/bin/magick"].some((x) => existsSync(x))) {
    let th = [];
    for (let i = 0; i < 20 && !th.length; i++) {
      await new Promise((r) => setTimeout(r, 300));
      th = JSON.parse((await sreq("/api/conversation")).body).items.filter((i) => i.t === "image" && /^data:image\/jpeg;base64,/.test(i.thumb || ""));
    }
    ok(th.length >= 1, `P a later read carries the small preview (thumb) the entry's copy keeps (${th.length})`);
  } else console.log("note P: no sips / ImageMagick here — no previews to check");
  await sstop(m);
}
// ---- Q: the home's files a reply links to (task T773 ②) ---------------------------------
if (part("links")) {
  const H = homeOf("l");
  for (const d of ["proj", ".ssh"]) mkdirSync(join(H, d), { recursive: true });
  writeFileSync(join(H, "proj", "form.css"), ".row{align-items:center}");
  writeFileSync(join(H, "proj", "shot.png"), Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64"));
  writeFileSync(join(H, "proj", "page.html"), "<script>alert(1)</script>");
  writeFileSync(join(H, ".ssh", "id_rsa"), "KEY");
  writeFileSync(join(H, "proj", ".env"), "TOKEN=x");
  const outside = join(HT, "outside.txt"); writeFileSync(outside, "outside");
  spawnSync("ln", ["-s", outside, join(H, "proj", "out.txt")]);
  SSTATE = stateOf("l"); SOCK = join(SSTATE, "chat.sock");
  const l = (await sstart(["--socket"], { ...asHome("l"), FLEET_WEBCHAT_CWD: H })).p;
  const live = (await sturn("link")).lines;
  const files = live.find((o) => o.t === "files")?.files || {};
  const H2 = realpathSync(H);
  ok(Object.keys(files).sort().join(" ") === [H + "/proj/form.css", "~/proj/shot.png", "proj/page.html"].sort().join(" ") ||
     Object.keys(files).sort().join(" ") === [H2 + "/proj/form.css", "~/proj/shot.png", "proj/page.html"].sort().join(" "),
    `Q live: a ref for the three files under $HOME, none for a key, a secret's name, a link out, a missing file, a URL (${Object.keys(files).join(" ")})`);
  ok(Object.values(files).every((r) => /^f[0-9a-f]{32}$/.test(r)) && !JSON.stringify(live.filter((o) => o.t === "files")).includes("/proj/form.css\":\"/"),
    "Q the refs are opaque");
  const get = (ref) => new Promise((resolve, reject) => {
    const r = http.request({ socketPath: SOCK, path: "/api/file?ref=" + ref, headers: { Host: "webchat" } }, (res) => {
      const parts = []; res.on("data", (d) => parts.push(d)); res.on("end", () => resolve({ status: res.statusCode, h: res.headers, body: Buffer.concat(parts).toString() }));
    });
    r.on("error", reject); r.end();
  });
  const byName = (n) => Object.entries(files).find(([k]) => k.endsWith(n))?.[1];
  const css = await get(byName("form.css"));
  ok(css.status === 200 && css.body === ".row{align-items:center}" && /attachment/.test(css.h["content-disposition"] || ""), "Q a CSS file comes back as a download");
  const png = await get(byName("shot.png"));
  ok(png.status === 200 && png.h["content-type"] === "image/png" && /inline/.test(png.h["content-disposition"] || ""), "Q an image comes back as itself");
  const html = await get(byName("page.html"));
  ok(html.status === 200 && html.h["content-type"] === "application/octet-stream" && /attachment/.test(html.h["content-disposition"] || "") &&
    /sandbox/.test(html.h["content-security-policy"] || ""), "Q an HTML file is only a download, under a sandbox CSP");
  ok((await get("f" + "0".repeat(32))).status === 404, "Q a ref nobody was given: 404");
  const back = JSON.parse((await sreq("/api/conversation")).body).items.find((i) => i.t === "files");
  ok(back && back.files[Object.keys(files)[0]] === files[Object.keys(files)[0]], "Q read back: the same refs");
  // the file turned into a link out of $HOME after it was given: refused at the read
  unlinkSync(join(H, "proj", "form.css")); spawnSync("ln", ["-s", outside, join(H, "proj", "form.css")]);
  ok((await get(byName("form.css"))).status === 404, "Q a file that became a link out of $HOME is refused at the read");
  await sstop(l);
  // expired: the refs written with a date in the past
  const refsF = join(SSTATE, "refs.json");
  const refs = JSON.parse(readFileSync(refsF, "utf8"));
  ok((statSync(refsF).mode & 0o777) === 0o600 && !Object.values(refs).some((v) => /id_rsa|\.env|outside/.test(v.path)), "Q refs.json is 0600 and holds no denied path");
  for (const v of Object.values(refs)) v.exp = Date.now() - 1000;
  writeFileSync(refsF, JSON.stringify(refs));
  const l2 = (await sstart(["--socket"], { ...asHome("l"), FLEET_WEBCHAT_CWD: H })).p;
  const ex = await get(byName("shot.png"));
  ok(ex.status === 410 && /过期/.test(ex.body), `Q an expired ref says so (${ex.status})`);
  await sstop(l2);
}
// ---- R: pictures from the page (task T773 ③) --------------------------------------------
if (part("send")) {
  mkdirSync(homeOf("s"), { recursive: true });
  SSTATE = stateOf("s"); SOCK = join(SSTATE, "chat.sock");
  const sv = (await sstart(["--socket"], asHome("s"))).p;
  const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
  const post = (body) => new Promise((resolve, reject) => {
    const r = http.request({ socketPath: SOCK, path: "/api/turn", method: "POST",
      headers: { Host: "webchat", "X-Fleet-Webchat": "1", "Content-Type": "application/json" } }, (res) => {
      let b = "", buf = "";
      res.on("data", (d) => { b += d; buf += d; let i; while ((i = buf.indexOf("\n")) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1);
        try { const o = JSON.parse(l); if (o.t === "ask") sreq("/api/answer", { method: "POST", headers: { "X-Fleet-Webchat": "1", "Content-Type": "application/json" }, body: { rid: o.rid, answers: { "猫还是狗？": "狗" } } }); } catch { /* not a line */ }
      } });
      res.on("end", () => resolve({ status: res.statusCode, body: b }));
    });
    r.on("socket", (sk) => sk.on("error", () => {}));     // the server answers 413 before it reads the rest
    r.on("error", (e) => (e.code === "EPIPE" || e.code === "ECONNRESET" ? resolve({ status: 413, body: "" }) : reject(e)));
    r.end(typeof body === "string" ? body : JSON.stringify(body));
  });
  const before = existsSync(PROMPTLOG) ? readFileSync(PROMPTLOG, "utf8").split("\n").filter(Boolean).length : 0;
  const a = await post({ text: "看这张", images: [{ media_type: "image/png", data: PNG }] });
  ok(a.status === 200 && /"t":"done"/.test(a.body), `R a turn with a picture streams to done (${a.status})`);
  const got = readFileSync(PROMPTLOG, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)).slice(before);
  const pr = got[0]?.prompt;
  ok(Array.isArray(pr) && pr[0]?.type === "image" && pr[0].source?.data === PNG && pr.at(-1)?.type === "text" && pr.at(-1).text.endsWith("看这张"),
    "R the agent got the picture as an image block, then the words");
  const b = await post({ text: "", images: [{ media_type: "image/png", data: PNG }] });
  const pr2 = readFileSync(PROMPTLOG, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)).at(-1).prompt;
  ok(b.status === 200 && Array.isArray(pr2) && pr2.length === 1 && pr2[0].type === "image", "R a picture with no words goes too");
  const items = JSON.parse((await sreq("/api/conversation")).body).items;
  const mine = items.find((i) => i.t === "user" && i.text === "看这张");
  ok(mine?.images?.length === 1 && /^[0-9a-f]{32}\.png$/.test(mine.images[0].ref) && items.some((i) => i.t === "user" && i.text === "" && i.images?.length === 1),
    "R read back: each picture rides on the person's line");
  ok((await post({ text: "x", images: Array(5).fill({ media_type: "image/png", data: PNG }) })).status === 400, "R a fifth picture is refused");
  ok((await post({ text: "x", images: [{ media_type: "image/png", data: Buffer.from("<script>").toString("base64") }] })).status === 400 &&
    (await post({ text: "x", images: [{ media_type: "image/svg+xml", data: PNG }] })).status === 400, "R a non-image (or an SVG) is refused");
  ok((await post(JSON.stringify({ text: "x".repeat(1200 * 1024) }))).status === 413, "R a request past the bound is refused 413");
  await sstop(sv);
}
// ---- U: 新对话 mid-answer, a turn cut off, a background task's notice (task WD8F) -----------
if (part("aside")) {
  mkdirSync(homeOf("u"), { recursive: true });
  SSTATE = stateOf("u"); SOCK = join(SSTATE, "chat.sock");
  let sv = (await sstart(["--socket"], asHome("u"))).p;
  const conv = async () => JSON.parse((await sreq("/api/conversation")).body);
  const busyNow = async () => JSON.parse((await sreq("/api/busy")).body).busy;
  const until = async (f, ms = 5000) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { if (await f()) return true; await new Promise((r) => setTimeout(r, 50)); } return false; };
  // 新对话 while a turn answers: 200, the new conversation is free, the old turn answers on
  rmSync(HOLDFLAG, { force: true });
  const held = sturn("hold");
  ok(await until(async () => (await conv()).busy), "U a held turn is running");
  const nw = await sreq("/api/new", { method: "POST", headers: { "X-Fleet-Webchat": "1" } });
  ok(nw.status === 200, `U 新对话 mid-answer is not refused (${nw.status})`);
  const fresh = await conv();
  ok(!fresh.busy && fresh.items.length === 0 && !fresh.session, "U …the new conversation is empty and free at once");
  ok(await busyNow(), "U …/api/busy still says busy: the put-aside turn answers on");
  writeFileSync(HOLDFLAG, "go");
  const hr = await held;
  ok(hr.lines.some((o) => o.t === "text" && o.d === "答完了") && hr.lines.some((o) => o.t === "done") && !hr.lines.some((o) => o.t === "stopped"),
    "U …and ends with its answer, never stopped");
  ok(await until(async () => !(await busyNow())), "U …then nothing is busy");
  const saved = JSON.parse(readFileSync(join(SSTATE, "conversation.json"), "utf8"));
  ok(saved.put_away?.at(-1)?.session === SID && !saved.session, "U the put-away entry learned its session; the new one has none yet");
  // a turn the service did not see end: said on the next start, with its words
  rmSync(HOLDFLAG, { force: true });
  const cut = sturn("hold").catch(() => null);
  ok(await until(async () => (await conv()).busy), "U a second held turn is running");
  await sstop(sv);
  await cut;
  sv = (await sstart(["--socket"], asHome("u"))).p;
  const back = await conv();
  ok(back.interrupted?.text === "hold" && !back.busy, `U a turn cut off is said on the next start, with its words (${JSON.stringify(back.interrupted || null)})`);
  // a background task's notice is one quiet line; Claude Code's filler is none
  const nt = await sturn("notice");
  ok(!nt.lines.some((o) => o.t === "text" && /No response requested/.test(o.d)), "U the live stream carries no «No response requested.»");
  const after = await conv();
  ok(!after.interrupted, "U …the next turn clears the cut-off notice");
  ok(after.items.some((i) => i.t === "note" && i.kind === "task" && /上一轮回复中途被打断/.test(i.text)), "U a task notice reads as one note");
  ok(!after.items.some((i) => (i.t === "user" && /task-notification/.test(i.text)) || (i.t === "text" && /No response requested/.test(i.d))),
    "U …never the raw XML as the person's bubble, never the filler");
  ok(after.items.some((i) => i.t === "text" && i.d === "接着说"), "U …the real reply stays");
  await sstop(sv);
}
// ---- S: the agent's web pages (task T773 ④) ------------------------------------------------
if (part("pages")) {
  const H = homeOf("pg");
  mkdirSync(join(H, "proj"), { recursive: true });
  writeFileSync(join(H, "proj", "weekly.html"), "<h1>周报</h1>");
  writeFileSync(join(H, "proj", "weekly.png"), Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64"));
  SSTATE = stateOf("pg"); SOCK = join(SSTATE, "chat.sock");
  const pg = (await sstart(["--socket"], { ...asHome("pg"), FLEET_WEBCHAT_CWD: H })).p;
  const before = existsSync(TOOLLOG) ? readFileSync(TOOLLOG, "utf8") : "";
  const pfrom = existsSync(PROMPTLOG) ? readFileSync(PROMPTLOG, "utf8").split("\n").filter(Boolean).length : 0;
  const live = (await sturn("page")).lines;
  const card = live.find((o) => o.t === "page");
  ok(card && card.title === "销售周报 · 第 41 周" && card.url === "https://pages.example.com/s/demo" && card.status === "review" &&
    card.version === 1 && card.proposal === "P1" && /^[0-9a-f]{32}\.png$/.test(card.preview || ""), `S live: show_page is a card with its link, state, version, preview (${JSON.stringify(card)})`);
  ok(live.some((o) => o.t === "tool" && o.summary === "发到活页 · 销售周报 · 第 41 周"), "S the step reads 发到活页 · <title>");
  const prompts = readFileSync(PROMPTLOG, "utf8").split("\n").filter(Boolean).slice(pfrom).map((l) => JSON.parse(l).prompt);
  const noted = prompts.filter((x) => typeof x === "string" && /^<fleet-webchat-note>[\s\S]*<\/fleet-webchat-note>/.test(x) && /show_page/.test(x) && /WebChat 产物/.test(x));
  const first = JSON.parse(readFileSync(TOOLLOG, "utf8").slice(before.length).trim().split("\n")[0]);
  ok(first.folder === "WebChat 产物" && first.folder_id === null && first.proposal_id === null, "S page_target, the first time: the folder's name, no folder, no page yet");
  const saved = JSON.parse(readFileSync(join(SSTATE, "pages.json"), "utf8"));
  ok(saved.folder_id === "F1" && Object.values(saved.files)[0] === "P1" && (statSync(join(SSTATE, "pages.json")).mode & 0o777) === 0o600,
    "S pages.json (0600) remembers the folder and the file's page");
  ok(card.embed === "https://space.example.com/embed/V1/TICKET" && Date.parse(card.embed_exp) > Date.now(), "S the card carries the page's embed link and when it lapses");
  // the page says its origin with a turn: page_target answers it as embed_origin
  const live2 = await new Promise((resolve, reject) => {
    const lines = [];
    const r = http.request({ socketPath: SOCK, path: "/api/turn", method: "POST",
      headers: { Host: "webchat", "X-Fleet-Webchat": "1", "Content-Type": "application/json" } }, (res) => {
      let buf = "";
      res.on("data", (d) => { buf += d; let i; while ((i = buf.indexOf("\n")) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1); if (l) lines.push(JSON.parse(l)); } });
      res.on("end", () => resolve(lines));
    });
    r.on("error", reject); r.end(JSON.stringify({ text: "page2", origin: "https://ccquota.example.com" }));
  });
  const again = JSON.parse(readFileSync(TOOLLOG, "utf8").slice(before.length).trim().split("\n").at(-1));
  ok(again.folder_id === "F1" && again.proposal_id === "P1", "S page_target the next time: the same folder and page (a new version, the same link)");
  ok(first.embed_origin === null && again.embed_origin === "https://ccquota.example.com", "S page_target answers the page's origin for an embed link once the page said it");
  const bad = live2.find((o) => o.t === "page");
  ok(bad && !bad.url && bad.status === "ready" && bad.version === 2, "S a link that is not https is dropped from the card");
  const items = JSON.parse((await sreq("/api/conversation")).body).items;
  ok(items.filter((i) => i.t === "page").length === 2 && items.find((i) => i.t === "page").url === card.url, "S read back: both cards");
  const allp = readFileSync(PROMPTLOG, "utf8").split("\n").filter(Boolean).slice(pfrom).map((l) => JSON.parse(l).prompt).filter((x) => typeof x === "string");
  ok(noted.length === 1 && allp.filter((x) => x.includes("<fleet-webchat-note>")).length === 1 && !JSON.stringify(items).includes("fleet-webchat-note"),
    "S the agent is told once in the session where a page goes and to show it as a card; the page never shows the note");
  ok(!existsSync(SPACELOG), "S not a trial (the proxy says so): no `space` bridge is attached");
  await sstop(pg);
  // a trial's login (task XA4R): the proxy says eligible ⇒ the bridge, its credential by NAME only
  spaceEligible = true;
  const tg = (await sstart(["--socket"], { ...asHome("pg"), FLEET_WEBCHAT_CWD: H, FLEET_WEBCHAT_WARM_SECS: "0" })).p;
  const t3 = (await sturn("page3")).lines.find((o) => o.t === "page");
  const sp = existsSync(SPACELOG) ? readFileSync(SPACELOG, "utf8").trim().split("\n").map((l) => JSON.parse(l)) : [];
  ok(sp.length >= 1 && sp[0].type === "stdio" && sp[0].args.includes("--cred-env") && sp[0].args.includes("CLAUDE_CODE_OAUTH_TOKEN") &&
    /mcp-space\.py$/.test(sp[0].args.find((a) => a.endsWith("mcp-space.py")) || "") && !JSON.stringify(sp).includes(SECRET),
    `S a trial's agent gets the space bridge to the proxy, its credential by name, never in the config (${JSON.stringify(sp[0] || null)})`);
  const rules = JSON.parse(readFileSync(TOOLLOG, "utf8").trim().split("\n").at(-1));
  ok(typeof rules.trial === "string" && /push_to_wechat/.test(rules.trial) && /passcode/.test(rules.trial) && /never public/.test(rules.trial),
    "S page_target gives a trial its rules: push to their WeChat, ask before sharing, a passcode, never public");
  ok(t3 && t3.status === "ready" && t3.fresh === true && t3.pushed === true, `S the card says the account was opened and the page sent to WeChat (${JSON.stringify(t3)})`);
  const t4 = (await sturn("page4")).lines.find((o) => o.t === "page");
  ok(t4 && t4.status === "account" && !t4.url && !t4.fresh, "S the account not open yet: status account, nothing to open");
  spaceEligible = false;
  await sstop(tg);
}
if (!part("local")) {
  proxy.close();
  console.log(fails ? `FAIL ${fails}` : "PASS fleet-webchat-selftest");
  process.exit(fails ? 1 : 0);
}

proxyHits.length = 0;                                     // A–G count their own
// the cred log is shared with the socket parts above: the local part reads its own lines only
const CREDMARK = existsSync(CREDLOG) ? readFileSync(CREDLOG, "utf8").length : 0;
const localCred = () => readFileSync(CREDLOG, "utf8").slice(CREDMARK);
const QMARK = existsSync(QUERYLOG) ? readFileSync(QUERYLOG, "utf8").length : 0;
const localQueries = () => (readFileSync(QUERYLOG, "utf8").slice(QMARK).match(/^query$/gm) || []).length;
let PORT = await start();
function req(path, { method = "GET", headers = {}, body, host } = {}) {
  return new Promise((resolve, reject) => {
    const r = http.request({ host: "127.0.0.1", port: PORT, path, method,
      headers: { Host: host || `127.0.0.1:${PORT}`, ...headers } }, (res) => {
      let b = ""; res.on("data", (d) => (b += d)); res.on("end", () => { seen.push(b); resolve({ status: res.statusCode, headers: res.headers, body: b }); });
    });
    r.on("error", reject);
    if (body != null) r.write(typeof body === "string" ? body : JSON.stringify(body));
    r.end();
  });
}
const PAGE = { "X-Fleet-Webchat": "1", "Content-Type": "application/json" };

// ---- A ----------------------------------------------------------------------------
ok(readFileSync(join(STATE, "port"), "utf8").trim() === String(PORT), "A port file names the listening port");
const others = Object.values(os.networkInterfaces()).flat().filter((i) => i && i.family === "IPv4" && !i.internal).map((i) => i.address);
for (const ip of others.slice(0, 2)) {
  const refused = await new Promise((r) => { const s = net.connect(PORT, ip); s.on("connect", () => { s.destroy(); r(false); }); s.on("error", () => r(true)); });
  ok(refused, `A not reachable on ${ip}`);
}
if (!others.length) console.log("note A: no non-loopback IPv4 here to try");
ok((statSync(STATE).mode & 0o777) === 0o700, "A state dir is 0700");
ok((statSync(join(STATE, "admin.token")).mode & 0o777) === 0o600, "A admin.token is 0600");
const ADMIN = readFileSync(join(STATE, "admin.token"), "utf8").trim();

// ---- B ----------------------------------------------------------------------------
ok((await req("/")).status === 403, "B no cookie: / refused");
ok((await req("/api/conversation")).status === 403, "B no cookie: /api/conversation refused");
ok((await req("/api/turn", { method: "POST", headers: PAGE, body: { text: "hi" } })).status === 403, "B no cookie: /api/turn refused");
ok((await req("/api/conversation", { headers: { Cookie: "fwc=made-up-by-someone-else" } })).status === 403, "B a made-up cookie refused");
ok((await req("/login?c=guess")).status === 403, "B a guessed login code refused");
ok((await req("/api/link", { method: "POST", headers: { "X-Fleet-Webchat-Admin": "nope" } })).status === 403, "B a wrong admin token cannot mint a link");
ok((await req("/healthz", { host: "evil.example:80" })).status === 421, "B a foreign Host refused (rebinding)");
const link = JSON.parse((await req("/api/link", { method: "POST", headers: { "X-Fleet-Webchat-Admin": ADMIN } })).body);
const login = await req(link.path);
ok(login.status === 302 && /HttpOnly/.test(login.headers["set-cookie"]?.[0] || "") && /SameSite=Strict/.test(login.headers["set-cookie"]?.[0] || ""), "B the one-time link sets an HttpOnly SameSite=Strict cookie");
const COOKIE = (login.headers["set-cookie"]?.[0] || "").split(";")[0];
ok((await req(link.path)).status === 403, "B the same link a second time is refused");
const me = { Cookie: COOKIE };
ok((await req("/", { headers: me })).status === 200, "B with the cookie: the page");
ok((await req("/api/turn", { method: "POST", headers: { ...me, "Content-Type": "application/json" }, body: { text: "hi" } })).status === 403, "B a POST without the page's header refused");

// ---- C + D ------------------------------------------------------------------------
const conv0 = JSON.parse((await req("/api/conversation", { headers: me })).body);
ok(conv0.default === "claude-sonnet-5-5" && conv0.models.map((m) => m.id).join() === "claude-sonnet-5-5,claude-opus-5-5,claude-haiku-5-5", "C allowlist: Sonnet / Opus / Haiku 5.5, Sonnet by default");
const bad = await req("/api/turn", { method: "POST", headers: { ...me, ...PAGE }, body: { text: "hi", model: "claude-fable-5-1" } });
ok(bad.status === 400, "C a model off the allowlist is refused by the server");

async function turnStream(text, onLine) {
  return new Promise((resolve, reject) => {
    const r = http.request({ host: "127.0.0.1", port: PORT, path: "/api/turn", method: "POST",
      headers: { Host: `127.0.0.1:${PORT}`, ...me, ...PAGE } }, (res) => {
      let buf = "", all = "";
      res.on("data", (d) => { buf += d; all += d; let i; while ((i = buf.indexOf("\n")) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1); if (l) onLine(JSON.parse(l)); } });
      res.on("end", () => { seen.push(all); resolve(res.statusCode); });
    });
    r.on("error", reject); r.end(JSON.stringify({ text, model: "claude-haiku-5-5" }));
  });
}
const lines = [];
const st = await turnStream("记住青蛙", async (o) => {
  lines.push(o);
  if (o.t === "ask") seen.push((await req("/api/answer", { method: "POST", headers: { ...me, ...PAGE }, body: { rid: o.rid, answers: { "猫还是狗？": "猫" } } })).body);
});
const kinds = lines.map((o) => o.t);
ok(st === 200 && kinds.includes("text") && kinds.includes("tool") && kinds.includes("tool_result") && kinds.includes("ask") && kinds.at(-1) === "done", `C the turn streams text · tool · ask · done (${kinds.join(",")})`);
ok(lines.some((o) => o.t === "text" && /你选了猫/.test(o.d)), "C the button's answer reached the agent");
ok(lines.find((o) => o.t === "tool")?.summary === "Bash · date", "C the tool step is one folded line");
ok(lines.find((o) => o.t === "ask")?.id === "tu-ask", "G a question names the tool step it gates (the page hangs it there)");
const envSeen = JSON.parse(readFileSync(ENVLOG, "utf8"));
ok(envSeen.mode === "bypassPermissions" && envSeen.skip === true, `L the agent runs bypassPermissions, like a fleet CLI session (${envSeen.mode})`);
ok(["user", "project", "local"].every((x) => envSeen.sources?.includes(x)), "L the login's settings — and their PreToolUse guards — are loaded");
ok(!lines.some((o) => o.t === "ask" && o.kind === "permission") && lines.find((o) => o.t === "ask")?.kind === "question",
  "L the Bash step ran with no 允许 card; AskUserQuestion still came out as the question card");
{
  const HOOKS = join(BIN, "../hooks");
  const reg = JSON.parse(readFileSync(join(HOOKS, "settings-hooks.json"), "utf8")).hooks.PreToolUse || [];
  const onBash = reg.some((e) => e.matcher === "Bash" && e.hooks.some((h) => /bash-guard\.py/.test(h.command)));
  const genv = { ...process.env }; for (const k of Object.keys(genv)) if (/^(TMUX|FLEET_)/.test(k)) delete genv[k];
  const g = spawnSync("python3", [join(HOOKS, "bash-guard.py")], { env: genv, encoding: "utf8",
    input: JSON.stringify({ hook_event_name: "PreToolUse", tool_name: "Bash", permission_mode: "bypassPermissions",
      cwd: T, tool_input: { command: `rm -rf ${join(T, "x", ".git")}` } }) });
  ok(onBash && g.status === 2 && /bypass/.test(g.stderr), `L bash-guard still denies a guarded command in bypass, outside tmux (rc ${g.status})`);
}
ok(envSeen.base === `http://127.0.0.1:${PPORT}` && envSeen.token === SECRET, "D the agent ran on the proxy's port with the minted session credential");
ok(envSeen.tmux === "", "D no tmux pane leaks into the agent's environment");
ok(envSeen.model === "claude-haiku-5-5", "D the chosen model reached the agent");
ok(proxyHits.length === 1 && proxyHits[0].auth === "Bearer " + SECRET, "D the session's request reached the credential proxy (the pool meters it there)");
const credCalls = localCred();
const mintSid = (credCalls.match(/mint --provider claude --sid (web-\d+-\d+)/) || [])[1];
// one credential per conversation (task V9DJ C1): minted once, kept between
// turns, revoked when the service stops (checked in F)
ok(!!mintSid && (credCalls.match(/^mint /gm) || []).length === 1 && !credCalls.includes(`revoke --sid ${mintSid}`),
  `D the conversation's sid (${mintSid}) was minted once and is kept between turns`);

// ---- O: the warm agent (task V9DJ C2): the next turn runs on the agent the first
// one started — no new Claude Code process, no resume — and still answers its card
{
  const more = [];
  const st3 = await turnStream("再说一句", async (o) => {
    more.push(o.t);
    if (o.t === "ask") await req("/api/answer", { method: "POST", headers: { ...me, ...PAGE }, body: { rid: o.rid, answers: { "猫还是狗？": "狗" } } });
  });
  ok(st3 === 200 && more.at(-1) === "done" && more.includes("session"), `O a second turn streams to done (${more.join(",")})`);
  ok(localQueries() === 1, `O both turns ran on one agent (${localQueries()} started)`);
}

// ---- G: the page -------------------------------------------------------------------
const page = await req("/", { headers: me });
const csp = String(page.headers["content-security-policy"] || "");
ok(/default-src 'self'/.test(csp) && /connect-src 'self'/.test(csp) && /font-src 'self'/.test(csp), "G the page says: nothing from another origin (CSP self)");
ok(/<div id="root">/.test(page.body) && !/(src|href)="https?:\/\//.test(page.body), "G the page is the built UI and loads nothing from another origin");
const assets = [...page.body.matchAll(/(?:src|href)="(\/assets\/[^"]+)"/g)].map((m) => m[1]);
ok(assets.some((a) => a.endsWith(".js")) && assets.some((a) => a.endsWith(".css")), `G it names its own script and styles (${assets.join(" ")})`);
const js = assets.find((a) => a.endsWith(".js"));
ok((await req(js)).status === 403, "G an asset without the cookie is refused");
const jsOk = await req(js, { headers: me });
ok(jsOk.status === 200 && /javascript/.test(jsOk.headers["content-type"] || "") && /immutable/.test(jsOk.headers["cache-control"] || ""), "G with the cookie: the script, cached for good (its name is its hash)");
const gz = await new Promise((resolve, reject) => {
  const r = http.request({ host: "127.0.0.1", port: PORT, path: js, headers: { Host: `127.0.0.1:${PORT}`, ...me, "Accept-Encoding": "gzip" } }, (res) => {
    const parts = []; res.on("data", (d) => parts.push(d)); res.on("end", () => resolve({ enc: res.headers["content-encoding"], body: Buffer.concat(parts) }));
  });
  r.on("error", reject); r.end();
});
ok(gz.enc === "gzip" && gunzipSync(gz.body).toString() === jsOk.body, "G gzip when the browser asks for it");
const out = await req("/assets/..%2f..%2fserver.mjs", { headers: me });
ok(out.status === 404 && !/createServer/.test(out.body), "G nothing outside dist is served");
const fonts = readdirSync(join(BIN, "../extras/web-chat/ui/dist/assets")).filter((f) => /\.woff2$/.test(f));
ok(fonts.length >= 3, `G the site's fonts ship with the page (${fonts.length} woff2), no font service`);

// ---- F ----------------------------------------------------------------------------
const conv1 = JSON.parse((await req("/api/conversation", { headers: me })).body);
ok(conv1.session === SID && conv1.items.some((i) => i.t === "user" && i.text === "记住青蛙"), "F the conversation is that session, its history on the page");
await stop();
ok(localCred().includes(`revoke --sid ${mintSid}`), `F the service's stop revoked the conversation's credential (${mintSid})`);
PORT = await start();
const conv2 = JSON.parse((await req("/api/conversation", { headers: me })).body);
ok(conv2.session === SID, "F after a restart the same conversation (and the cookie still holds)");
let stopped = false;
// the stop key once the agent has the turn (its session line): a stop that comes
// earlier, while the agent still opens, ends the turn before the agent sees it (WD8F)
let tid2 = "";
const st2 = turnStream("slow", async (o) => {
  if (o.t === "turn") tid2 = o.id;
  if (o.t === "session") seen.push((await req("/api/stop", { method: "POST", headers: { ...me, ...PAGE }, body: { turn: tid2 } })).body);
  if (o.t === "stopped") stopped = true;
});
await st2;
ok(stopped, "F the stop key stops a running turn");
ok(JSON.parse(readFileSync(ENVLOG, "utf8")).resume === SID, "F the next turn resumed the same session");
{
  // the page's read minted ahead of the turn, and the turn used that one
  const after = localCred().split(`revoke --sid ${mintSid}`)[1] || "";
  ok((after.match(/^mint /gm) || []).length === 1, "F after the restart one mint served the read-ahead and the turn (the stop key keeps it)");
  // the restart's read opened the agent ahead of the turn; the stop key closed it
  ok(localQueries() === 2, `O the page's read opened the agent the next turn used (${localQueries()} started in all)`);
}

// ---- E ----------------------------------------------------------------------------
await stop();
ok(!seen.some((b) => b.includes(SECRET)), "E the credential is in no response");
ok(!seen.some((b) => b.includes(ADMIN)), "E the admin token is in no response");
const leak = [];
for (const f of readdirSync(STATE)) {
  const p = join(STATE, f);
  if (statSync(p).isFile() && f !== "admin.token" && readFileSync(p, "utf8").includes(SECRET)) leak.push(f);
}
ok(leak.length === 0, `E the credential is in no state file (server.log included)${leak.length ? ": " + leak.join(",") : ""}`);
ok(existsSync(join(STATE, "server.log")) && !readFileSync(join(STATE, "server.log"), "utf8").includes(ADMIN), "E the admin token is not in the log");

proxy.close();
console.log(fails ? `FAIL ${fails}` : "PASS fleet-webchat-selftest");
process.exit(fails ? 1 : 0);
