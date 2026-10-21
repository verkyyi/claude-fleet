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
//   --only=socket|budget|context|home|idle|trial|media|links|local (comma list) runs those parts only — the drills' road.
import { spawn, spawnSync } from "node:child_process";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import { mkdtempSync, writeFileSync, readFileSync, readdirSync, statSync, existsSync, rmSync, chmodSync, unlinkSync, mkdirSync,
  renameSync, realpathSync } from "node:fs";
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
const ONLY = ((process.argv.find((a) => a.startsWith("--only=")) || "").slice(7) || "socket,budget,context,home,idle,trial,media,links,local").split(",");
const part = (x) => ONLY.includes(x);
let fails = 0, server = null;
const seen = [];                                           // every response body the test read
process.on("exit", () => { try { server?.kill("SIGKILL"); } catch { /* gone */ } rmSync(T, { recursive: true, force: true }); });
setTimeout(() => { console.log("FAIL timed out"); process.exit(1); }, 90000).unref();
const ok = (c, m) => { console.log(`${c ? "ok  " : "FAIL"} ${m}`); if (!c) fails++; };

// ---- the stub credential proxy: what reaches it is the pool's usage record ----
const proxyHits = [];
const proxy = http.createServer((req, res) => {
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
const QUERYLOG = join(T, "queries.log");                     // one line per query() — a started agent (C2)
const sdk = join(T, "sdk.mjs");
writeFileSync(sdk, `
import { writeFileSync, appendFileSync, mkdirSync, realpathSync } from "node:fs";
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
function sstart(args = ["--socket"], extra = {}) {
  return new Promise((resolve, reject) => {
    const env = { ...process.env, FLEET_WEBCHAT_STATE: SSTATE, FLEET_WEBCHAT_SDK: sdk, FLEET_WEBCHAT_SESSION_CRED: credSh,
      FLEET_WEBCHAT_CWD: T, CLAUDE_CONFIG_DIR: CFG, FLEET_WEBCHAT_PORT: "0", FLEET_WEBCHAT_IDLE_SECS: "0", ...extra };
    delete env.FLEET_WEBCHAT_LOCAL;
    for (const k of Object.keys(extra)) if (extra[k] === undefined) delete env[k];
    const p = spawn(process.execPath, [APP, ...args], { env, stdio: ["ignore", "pipe", "pipe"] });
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
      res.on("end", () => { seen.push(all); resolve({ status: res.statusCode, lines }); });
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
const st2 = turnStream("slow", async (o) => {
  if (o.t === "turn") seen.push((await req("/api/stop", { method: "POST", headers: { ...me, ...PAGE }, body: { turn: o.id } })).body);
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
