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
//   --only=socket|budget|local (comma list) runs those parts only — the drills' road.
import { spawn, spawnSync } from "node:child_process";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import { mkdtempSync, writeFileSync, readFileSync, readdirSync, statSync, existsSync, rmSync, chmodSync, unlinkSync, mkdirSync } from "node:fs";
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
const ONLY = ((process.argv.find((a) => a.startsWith("--only=")) || "").slice(7) || "socket,budget,local").split(",");
const part = (x) => ONLY.includes(x);
let fails = 0, server = null;
const seen = [];                                           // every response body the test read
process.on("exit", () => { try { server?.kill("SIGKILL"); } catch { /* gone */ } rmSync(T, { recursive: true, force: true }); });
setTimeout(() => { console.log("FAIL timed out"); process.exit(1); }, 60000).unref();
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
const sdk = join(T, "sdk.mjs");
writeFileSync(sdk, `
import { writeFileSync, appendFileSync, mkdirSync, realpathSync } from "node:fs";
import { join } from "node:path";
const SID = ${JSON.stringify(SID)};
export async function* query({ prompt, options }) {
  const env = options.env;
  writeFileSync(${JSON.stringify(ENVLOG)}, JSON.stringify({ base: env.ANTHROPIC_BASE_URL, token: env.CLAUDE_CODE_OAUTH_TOKEN,
    tmux: env.TMUX || "", resume: options.resume || "", model: options.model }));
  await fetch(env.ANTHROPIC_BASE_URL + "/v1/messages", { method: "POST", headers: { authorization: "Bearer " + env.CLAUDE_CODE_OAUTH_TOKEN } });
  const dir = join(${JSON.stringify(CFG)}, "projects", realpathSync(options.cwd).replace(/[^A-Za-z0-9]/g, "-"));
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
const SSTATE = join(T, "sstate");
const SOCK = join(SSTATE, "chat.sock");
let sserver = null;
process.on("exit", () => { try { sserver?.kill("SIGKILL"); } catch { /* gone */ } });
function sstart(args = ["--socket"], extra = {}) {
  return new Promise((resolve, reject) => {
    const env = { ...process.env, FLEET_WEBCHAT_STATE: SSTATE, FLEET_WEBCHAT_SDK: sdk, FLEET_WEBCHAT_SESSION_CRED: credSh,
      FLEET_WEBCHAT_CWD: T, CLAUDE_CONFIG_DIR: CFG, FLEET_WEBCHAT_PORT: "0", ...extra };
    delete env.FLEET_WEBCHAT_LOCAL;
    const p = spawn(process.execPath, [APP, ...args], { env, stdio: ["ignore", "pipe", "pipe"] });
    let out = "", err = "";
    p.stdout.on("data", (d) => { out += d; if (/listening on/.test(out)) resolve({ p, out }); });
    p.stderr.on("data", (d) => { err += d; });
    p.on("exit", (c) => resolve({ p, code: c, out, err }));
    setTimeout(() => reject(new Error("socket server did not start")), 10000);
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

if (part("socket") || part("budget")) {
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
  const other = otherUidConnects();
  if (other === null) console.log("note H: cannot try another uid here (no passwordless sudo, or root)");
  else {
    ok(other === false, "H another uid cannot connect (dir 0700)");
    chmodSync(SSTATE, 0o711); chmodSync(T, 0o711);           // only the socket's own mode left in the way
    ok(otherUidConnects() === false, "H another uid cannot connect even through an open dir (socket 0600)");
    chmodSync(SOCK, 0o666);                                   // the break, for real: the probe is not vacuous
    ok(otherUidConnects() === true, "H (control) a 0666 socket in an open dir: another uid DOES connect");
    chmodSync(SOCK, 0o600);
    chmodSync(SSTATE, 0o700); chmodSync(T, 0o700);
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
if (sserver) await sstop(sserver);
if (part("budget")) {
  const log = existsSync(join(SSTATE, "server.log")) ? readFileSync(join(SSTATE, "server.log"), "utf8") : "";
  ok(/"ev":"budget"/.test(log) && /"person":"alice@example.com"/.test(log), "I the log says budget, and whose (X-Fleet-Person, for the log only)");
  ok(!log.includes(SECRET), "I the credential is not in the socket server's log");
}
if (!part("local")) {
  proxy.close();
  console.log(fails ? `FAIL ${fails}` : "PASS fleet-webchat-selftest");
  process.exit(fails ? 1 : 0);
}

proxyHits.length = 0;                                     // A–G count their own
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
ok(envSeen.base === `http://127.0.0.1:${PPORT}` && envSeen.token === SECRET, "D the agent ran on the proxy's port with the minted session credential");
ok(envSeen.tmux === "", "D no tmux pane leaks into the agent's environment");
ok(envSeen.model === "claude-haiku-5-5", "D the chosen model reached the agent");
ok(proxyHits.length === 1 && proxyHits[0].auth === "Bearer " + SECRET, "D the session's request reached the credential proxy (the pool meters it there)");
const credCalls = readFileSync(CREDLOG, "utf8");
const mintSid = (credCalls.match(/mint --provider claude --sid (web-\d+-\d+)/) || [])[1];
ok(!!mintSid && credCalls.includes(`revoke --sid ${mintSid}`), `D the turn's sid (${mintSid}) was minted and revoked`);

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
