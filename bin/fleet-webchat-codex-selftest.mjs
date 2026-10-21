// fleet-webchat-codex-selftest.mjs — the conversation's Codex side (task R9A2,
// issue #4370 B), driven for real: extras/web-chat/server.mjs (+ codex.mjs) in the
// socket mode, a stub fleet-session-cred.sh and a FAKE `codex app-server` — a
// script speaking its JSON-RPC over stdio the way codex 0.162 does (recorded
// against the real one) — so no network and no codex.
//   A  the two sides: ?provider=codex reads its own (empty) conversation and names
//      the providers; the Claude side says the Codex side's state; an unknown
//      provider is 400; no codex on the machine ⇒ the Claude side answers as before
//      (no providers) and ?provider=codex is 404
//   B  a turn: the app-server starts with the pool's credential in its environment
//      only (CODEX_HOME = the credential-free home, model_provider fleet at the
//      proxy's port); thread/start asks workspace-write + on-request with the page
//      tools; the stream is the Claude side's vocabulary — turn · session · text
//      (deltas) · tool / tool_result (a command, a file change) · page (show_page) ·
//      image (view_image) · done
//   C  read back: the same steps from codex/<thread>.ndjson, the person's line first;
//      `last` names the turn; the Claude side's `others.codex.last` too
//   D  an approval: the command's ask card (id = the item); 允许 → accept,
//      拒绝 → decline (or cancel when decline is not offered)
//   E  a question: request_user_input → a question card; the answer reaches the
//      app-server under each question's id
//   F  the stop key: turn/interrupt reaches the app-server, the stream says stopped
//   G  the budget: the proxy's 403 person_budget_exceeded is ONE line
//      {t:"error", code:"budget"}; the conversation says blocked (both sides)
//   H  新对话: the Codex thread put away (its record kept), the Claude side untouched;
//      the next turn starts a new thread
//      — and 新对话 on the Claude side leaves the Codex thread as it is
//   I  a restart resumes the same thread (thread/resume, no new thread)
//   L  在 WebChat 里继续 (task T810) for a Codex thread: /api/adopt {agent:"codex"} makes a
//      terminal's thread this side's conversation — its directory and history read off
//      Codex's own rollout, the old thread put away; with the lock record saying
//      terminal a turn is refused 409 and the conversation names the owner;
//      /api/take, /api/state, /api/release ?provider=codex are the Codex side's
//   J  the credential appears in no response, no log, no file of the state dir
import { spawn } from "node:child_process";
import http from "node:http";
import os from "node:os";
import { mkdtempSync, writeFileSync, readFileSync, readdirSync, existsSync, rmSync, mkdirSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const BIN = dirname(fileURLToPath(import.meta.url));
const APP = join(BIN, "../extras/web-chat/server.mjs");
const T = mkdtempSync("/tmp/fwcx-");
const STATE = join(T, "state");
const SOCK = join(STATE, "chat.sock");
const SECRET = "fcp1.CODEX-SELFTEST-SECRET-" + Math.random().toString(36).slice(2);
let fails = 0, srv = null;
const seen = [];
process.on("exit", () => { try { srv?.kill("SIGKILL"); } catch { /* gone */ } rmSync(T, { recursive: true, force: true }); });
setTimeout(() => { console.log("FAIL timed out"); process.exit(1); }, 90000).unref();
const ok = (c, m) => { console.log(`${c ? "ok  " : "FAIL"} ${m}`); if (!c) fails++; };

// ---- the stub fleet-session-cred.sh (on · mint · codex-home · revoke) ----------------
const CREDLOG = join(T, "cred.log");
const HOMEDIR = join(T, "codex-home");
mkdirSync(HOMEDIR);
const credSh = join(T, "fleet-session-cred.sh");
writeFileSync(credSh, `#!/bin/bash
echo "$*" >>"${CREDLOG}"
case "$1" in
  on) exit 0 ;;
  mint) printf 'direct\\t4711\\t${SECRET}\\n' ;;
  codex-home) printf '%s\\n' "${HOMEDIR}" ;;
  revoke) exit 0 ;;
esac
`, { mode: 0o755 });

// ---- the terminal ⇄ page stubs (task T810): a lock dir, a handoff that logs its calls, a rollout
const CXHOME = join(T, "codexhome");
const LOCKS = join(T, "locks");
mkdirSync(LOCKS);
const HANDLOG = join(T, "handoff.log");
const handoff = join(T, "fleet-webchat-handoff.sh");
writeFileSync(handoff, `#!/bin/bash
echo "$*" >>"${HANDLOG}"
case "$1" in
  owner) printf '{"holder":"terminal","busy":false,"label":"scratch-9","machine":"mini2"}\\n' ;;
  to-webchat-take) rm -f "${LOCKS}/codex-$5.json" ;;
esac
`, { mode: 0o755 });
const TERM_THREAD = "01a15e99-0000-7000-8000-00000000abcd";
mkdirSync(join(T, "signup"));
mkdirSync(join(CXHOME, "sessions", "2026", "10", "21"), { recursive: true });
writeFileSync(join(CXHOME, "sessions", "2026", "10", "21", `rollout-2026-10-21T08-00-00-${TERM_THREAD}.jsonl`), [
  { type: "session_meta", payload: { id: TERM_THREAD, cwd: join(T, "signup") } },
  { type: "event_msg", payload: { type: "item_completed", item: { type: "UserMessage", id: "u1", content: [{ type: "text", text: "终端里问的" }] } } },
  { type: "event_msg", payload: { type: "item_completed", item: { type: "CommandExecution", id: "x1", command: ["/bin/zsh", "-lc", "ls"], status: "completed", aggregated_output: "a.txt\n", exit_code: 0 } } },
  { type: "event_msg", payload: { type: "item_completed", item: { type: "AgentMessage", id: "a1", content: [{ type: "Text", text: "终端里答的" }] } } },
].map((x) => JSON.stringify(x)).join("\n") + "\n");

// ---- the fake codex app-server -----------------------------------------------------------
const RPCLOG = join(T, "rpc.ndjson");         // every request the server sent, and every answer it gave
const ENVLOG = join(T, "codex-env.json");
const PNG = join(T, "chart.png");
// a 1×1 png
writeFileSync(PNG, Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64"));
const fake = join(T, "codex");
writeFileSync(fake, `#!${process.execPath}
const fs = require("fs");
const log = (o) => fs.appendFileSync(${JSON.stringify(RPCLOG)}, JSON.stringify(o) + "\\n");
fs.writeFileSync(${JSON.stringify(ENVLOG)}, JSON.stringify({ args: process.argv.slice(2), CODEX_HOME: process.env.CODEX_HOME || "",
  cred: process.env.FLEET_CODEX_SESSION_CRED === ${JSON.stringify(SECRET)}, tmux: !!process.env.TMUX }));
const out = (m) => process.stdout.write(JSON.stringify(m) + "\\n");
let threads = 0, reqId = 0, turn = null;
const waiting = new Map();
const ask = (method, params) => new Promise((r) => { const id = ++reqId; waiting.set(id, r); out({ id, method, params }); });
const note = (method, params) => out({ method, params });
async function play(thr, tid, text) {
  const item = (type, o) => ({ type, ...o });
  note("turn/started", { threadId: thr, turn: { id: tid, items: [], status: "inProgress", error: null } });
  const done = (status, error = null) => note("turn/completed", { threadId: thr, turn: { id: tid, items: [], status, error, durationMs: 1200 } });
  if (text.startsWith("tools")) {
    note("item/started", { threadId: thr, turnId: tid, item: item("agentMessage", { id: "m1", text: "" }) });
    for (const d of ["改好", "了。"]) note("item/agentMessage/delta", { threadId: thr, turnId: tid, itemId: "m1", delta: d });
    note("item/completed", { threadId: thr, turnId: tid, item: item("agentMessage", { id: "m1", text: "改好了。" }) });
    note("item/started", { threadId: thr, turnId: tid, item: item("commandExecution", { id: "c1", command: "/bin/zsh -lc 'npm test'", status: "inProgress" }) });
    note("item/completed", { threadId: thr, turnId: tid, item: item("commandExecution", { id: "c1", command: "/bin/zsh -lc 'npm test'", status: "failed", aggregatedOutput: "1 failed", exitCode: 1 }) });
    note("item/started", { threadId: thr, turnId: tid, item: item("fileChange", { id: "f1", changes: [{ path: "src/phone.ts", kind: "update", diff: "+a" }], status: "inProgress" }) });
    note("item/completed", { threadId: thr, turnId: tid, item: item("fileChange", { id: "f1", changes: [{ path: "src/phone.ts", kind: "update", diff: "+a" }], status: "completed" }) });
    const args = { title: "报名页", status: "ready", url: "https://example.com/s/abc", proposal_id: "P1", version: 2 };
    note("item/started", { threadId: thr, turnId: tid, item: item("dynamicToolCall", { id: "d1", tool: "show_page", arguments: args, status: "inProgress" }) });
    const r = await ask("item/tool/call", { threadId: thr, turnId: tid, callId: "d1", tool: "show_page", arguments: args });
    log({ answered: "item/tool/call", result: r });
    note("item/completed", { threadId: thr, turnId: tid, item: item("dynamicToolCall", { id: "d1", tool: "show_page", arguments: args, status: "completed", contentItems: r.contentItems, success: r.success }) });
    note("item/completed", { threadId: thr, turnId: tid, item: item("imageView", { id: "v1", path: ${JSON.stringify(PNG)} }) });
    note("item/started", { threadId: thr, turnId: tid, item: item("agentMessage", { id: "m2", text: "" }) });
    note("item/completed", { threadId: thr, turnId: tid, item: item("agentMessage", { id: "m2", text: "图在上面。" }) });
    return done("completed");
  }
  if (text.startsWith("ask")) {
    note("item/started", { threadId: thr, turnId: tid, item: item("commandExecution", { id: "c9", command: "/bin/zsh -lc 'git push'", status: "inProgress" }) });
    const params = { kind: "command", threadId: thr, turnId: tid, itemId: "c9", reason: "推代码", command: "/bin/zsh -lc 'git push'",
      ...(text.includes("nodecline") ? { availableDecisions: ["accept", "cancel"] } : {}) };
    const r = await ask("item/commandExecution/requestApproval", params);
    log({ answered: "approval", result: r });
    note("item/completed", { threadId: thr, turnId: tid, item: item("commandExecution", { id: "c9", command: "/bin/zsh -lc 'git push'", status: r.decision === "accept" ? "completed" : "declined", aggregatedOutput: "", exitCode: r.decision === "accept" ? 0 : null }) });
    return done("completed");
  }
  if (text.startsWith("question")) {
    const r = await ask("item/tool/requestUserInput", { threadId: thr, turnId: tid, itemId: "q1", isBlocking: true,
      questions: [{ id: "pet", header: "选一个", question: "猫还是狗？", isOther: false, isSecret: false, options: [{ label: "猫", description: "" }, { label: "狗", description: "" }] }] });
    log({ answered: "question", result: r });
    return done("completed");
  }
  if (text.startsWith("budget")) {
    const error = { message: 'unexpected status 403 Forbidden: {"error":{"code":"person_budget_exceeded","message":"cred-proxy: 已达个人额度","reset_at":"2031-01-01T00:00:00Z"}}', codexErrorInfo: null };
    note("error", { threadId: thr, turnId: tid, willRetry: false, error });
    return done("failed", error);
  }
  if (text.startsWith("long")) { turn = { thr, tid, done }; return; }
  return done("completed");
}
let buf = "";
process.stdin.on("data", (d) => {
  buf += d; let i;
  while ((i = buf.indexOf("\\n")) >= 0) {
    const m = JSON.parse(buf.slice(0, i)); buf = buf.slice(i + 1);
    if (m.id != null && !m.method) { const r = waiting.get(m.id); waiting.delete(m.id); r && r(m.result); continue; }
    log({ method: m.method, params: m.params });
    const reply = (result) => m.id != null && out({ id: m.id, result });
    switch (m.method) {
      case "initialize": reply({ userAgent: "fake" }); break;
      case "model/list": reply({ data: [{ id: "gpt-x", model: "gpt-x", displayName: "GPT-X Codex", hidden: false, isDefault: true },
        { id: "gpt-y", model: "gpt-y", displayName: "GPT-Y", hidden: false, isDefault: false }], nextCursor: null }); break;
      case "thread/start": reply({ thread: { id: "thr-" + (++threads) + "-" + process.pid } }); break;
      case "thread/resume": reply({ thread: { id: m.params.threadId } }); break;
      case "turn/start": { const tid = "turn-" + Date.now(); reply({ turn: { id: tid, items: [], status: "inProgress" } });
        const t = (m.params.input || []).find((x) => x.type === "text");
        setTimeout(() => play(m.params.threadId, tid, t ? t.text : ""), 20); break; }
      case "turn/interrupt": reply({}); if (turn) { turn.done("interrupted"); turn = null; } break;
      default: if (m.id != null) reply({});
    }
  }
});
`, { mode: 0o755 });

// ---- the server in the socket mode ------------------------------------------------------
function start(extra = {}) {
  return new Promise((resolve, reject) => {
    const env = { ...process.env, FLEET_WEBCHAT_STATE: STATE, FLEET_WEBCHAT_SESSION_CRED: credSh, FLEET_WEBCHAT_CWD: T,
      CLAUDE_CONFIG_DIR: join(T, "claude"), FLEET_WEBCHAT_IDLE_SECS: "0", FLEET_WEBCHAT_CODEX_BIN: fake,
      CODEX_HOME: CXHOME, FLEET_WEBCHAT_HANDOFF: handoff, FLEET_WEBCHAT_LOCKDIR: LOCKS, ...extra };
    delete env.FLEET_WEBCHAT_LOCAL; delete env.FLEET_WEBCHAT_SDK;
    for (const k of Object.keys(extra)) if (extra[k] === undefined) delete env[k];
    srv = spawn(process.execPath, [APP, "--socket"], { env, stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    srv.stdout.on("data", (d) => { out += d; if (/listening on/.test(out)) resolve(); });
    srv.stderr.on("data", (d) => process.stderr.write(d));
    srv.on("exit", (c) => reject(new Error("server exited " + c)));
    setTimeout(() => reject(new Error("server did not start")), 10000).unref();
  });
}
function stop() { return new Promise((r) => { if (!srv || srv.exitCode !== null) return r(); srv.removeAllListeners("exit"); srv.on("exit", r); srv.kill("SIGTERM"); }); }
const H = { "X-Fleet-Webchat": "1", "Content-Type": "application/json" };
function req(path, { method = "GET", body } = {}) {
  return new Promise((resolve, reject) => {
    const r = http.request({ socketPath: SOCK, path, method, headers: { Host: "webchat", ...H } }, (res) => {
      let b = ""; res.on("data", (d) => (b += d)); res.on("end", () => { seen.push(b); let j = null; try { j = JSON.parse(b); } catch { /* not json */ } resolve({ status: res.statusCode, body: b, j }); });
    });
    r.on("error", reject);
    if (body != null) r.write(JSON.stringify(body));
    r.end();
  });
}
// a Codex turn: every line; onLine may answer an ask or press stop
function turn(text, onLine = () => {}, body = {}) {
  return new Promise((resolve, reject) => {
    const lines = [];
    const r = http.request({ socketPath: SOCK, path: "/api/turn?provider=codex", method: "POST", headers: { Host: "webchat", ...H, "X-Fleet-Person": "alice@example.com" } }, (res) => {
      let buf = "", all = "";
      res.on("data", (d) => { buf += d; all += d; let i; while ((i = buf.indexOf("\n")) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1); if (l) { const o = JSON.parse(l); lines.push(o); onLine(o); } } });
      res.on("end", () => { seen.push(all); resolve({ status: res.statusCode, lines }); });
    });
    r.on("error", reject); r.end(JSON.stringify({ text, ...body }));
  });
}
const rpc = () => (existsSync(RPCLOG) ? readFileSync(RPCLOG, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []);
const kinds = (lines) => lines.map((o) => o.t);

// ---- A ----------------------------------------------------------------------------------
await start();
{
  const c = await req("/api/conversation?provider=codex");
  ok(c.status === 200 && Array.isArray(c.j.items) && c.j.items.length === 0 && c.j.provider === "codex", "A codex side reads its own empty conversation");
  ok(JSON.stringify(c.j.providers) === '["claude","codex"]', "A the providers are named");
  const cl = await req("/api/conversation");
  ok(cl.status === 200 && cl.j.others?.codex && cl.j.others.codex.busy === false, "A the Claude side says the Codex side's state");
  ok((await req("/api/conversation?provider=gemini")).status === 400, "A an unknown provider is 400");
}

// ---- B ----------------------------------------------------------------------------------
let thread1 = "";
{
  const t = await turn("tools please");
  const k = kinds(t.lines);
  ok(t.status === 200 && k[0] === "turn" && k.includes("session") && k.at(-1) === "done", `B the stream starts with turn, ends with done (${k.join(",")})`);
  ok(t.lines.filter((o) => o.t === "text").map((o) => o.d).join("").startsWith("改好了。"), "B the reply streams as text deltas");
  const sh = t.lines.find((o) => o.t === "tool" && o.id === "c1");
  ok(sh && sh.summary === "Shell · npm test", "B a command is a folded Shell step");
  ok(t.lines.some((o) => o.t === "tool_result" && o.id === "c1" && o.error === true && o.text === "1 failed"), "B its failed result");
  ok(t.lines.some((o) => o.t === "tool" && o.id === "f1" && o.summary === "Edit · src/phone.ts"), "B a file change is an Edit step");
  const pg = t.lines.find((o) => o.t === "page");
  ok(pg && pg.url === "https://example.com/s/abc" && pg.status === "ready" && pg.version === 2, "B show_page becomes a page card");
  ok(t.lines.some((o) => o.t === "image" && /^[0-9a-f]{32}\.png$/.test(o.ref || "")), "B view_image becomes an image item (a ref, no bytes)");
  const ses = t.lines.find((o) => o.t === "session");
  thread1 = ses?.id || "";
  const env = JSON.parse(readFileSync(ENVLOG, "utf8"));
  ok(env.CODEX_HOME === HOMEDIR && env.cred && !env.tmux, "B the app-server has the credential-free home and the credential, no tmux");
  ok(env.args.includes('model_provider="fleet"') && env.args.some((a) => a.includes("127.0.0.1:4711/codex")) && env.args.at(-1) === "app-server",
    "B model_provider fleet at the proxy's port");
  ok(!env.args.some((a) => a.includes(SECRET)), "B the credential is not in its argv");
  const st = rpc().find((m) => m.method === "thread/start");
  ok(st && st.params.approvalPolicy === "on-request" && st.params.sandbox === "workspace-write", "B workspace-write + on-request");
  ok(st && (st.params.dynamicTools || []).map((x) => x.name).sort().join() === "page_target,show_page", "B the page tools are given");
  const ini = rpc().find((m) => m.method === "initialize");
  ok(ini?.params?.capabilities?.experimentalApi === true, "B initialize opts into the experimental API (dynamic tools)");
  ok(rpc().some((m) => m.answered === "item/tool/call" && m.result.success === true), "B show_page is answered");
}

// ---- C ----------------------------------------------------------------------------------
{
  const c = await req("/api/conversation?provider=codex");
  const k = kinds(c.j.items);
  ok(k[0] === "user" && c.j.items[0].text === "tools please", "C read back: the person's line first");
  ok(["tool", "tool_result", "page", "image", "text"].every((x) => k.includes(x)), `C read back: the steps (${k.join(",")})`);
  ok(c.j.items.filter((o) => o.t === "text").map((o) => o.d).join("|").includes("改好了。"), "C read back: the reply's words");
  ok(c.j.session === thread1 && /^thr-1-/.test(thread1), "C the session is the thread");
  ok(!!c.j.last, "C last names the finished turn");
  ok(existsSync(join(STATE, "codex", `${thread1}.ndjson`)) && (statSync(join(STATE, "codex", `${thread1}.ndjson`)).mode & 0o777) === 0o600, "C the thread's record is kept 0600");
  ok(c.j.models.map((m) => m.id).join() === "gpt-x,gpt-y" && c.j.default === "gpt-x", "C the models are the app-server's list, its default first");
  const cl = await req("/api/conversation");
  ok(cl.j.others.codex.last === c.j.last, "C the Claude side knows the Codex side's last turn");
}

// ---- D ----------------------------------------------------------------------------------
for (const [text, allow, want] of [["ask a", true, "accept"], ["ask b", false, "decline"], ["ask nodecline", false, "cancel"]]) {
  const before = rpc().filter((m) => m.answered === "approval").length;
  let card = null;
  const t = await turn(text, (o) => { if (o.t === "ask") { card = o; req("/api/answer?provider=codex", { method: "POST", body: { rid: o.rid, allow } }); } });
  const got = rpc().filter((m) => m.answered === "approval")[before];
  ok(card && card.kind === "permission" && card.id === "c9" && card.summary.startsWith("Shell · git push"), `D ${text}: the approval is a card on the step`);
  ok(got && got.result.decision === want && kinds(t.lines).at(-1) === "done", `D ${text}: ${allow ? "允许" : "拒绝"} → ${want}`);
}

// ---- E ----------------------------------------------------------------------------------
{
  let card = null;
  await turn("question", (o) => { if (o.t === "ask") { card = o; req("/api/answer?provider=codex", { method: "POST", body: { rid: o.rid, answers: { "猫还是狗？": "狗" } } }); } });
  const got = rpc().find((m) => m.answered === "question");
  ok(card && card.kind === "question" && card.questions[0].question === "猫还是狗？" && card.questions[0].options.length === 2, "E request_user_input is a question card");
  ok(got && JSON.stringify(got.result.answers) === '{"pet":{"answers":["狗"]}}', "E the answer goes back under the question's id");
}

// ---- F ----------------------------------------------------------------------------------
{
  let pressed = false, turnId = "";
  const t = await turn("long", (o) => {
    if (o.t === "turn") turnId = o.id;
    if (o.t === "session" && !pressed) { pressed = true; setTimeout(() => req("/api/stop?provider=codex", { method: "POST", body: { turn: turnId } }), 200); }
  });
  ok(rpc().some((m) => m.method === "turn/interrupt"), "F the stop key reaches the app-server (turn/interrupt)");
  ok(kinds(t.lines).at(-1) === "stopped", "F the stream says stopped");
}

// ---- G ----------------------------------------------------------------------------------
{
  const t = await turn("budget");
  const e = t.lines.filter((o) => o.t === "error");
  ok(e.length === 1 && e[0].code === "budget" && e[0].until === "2031-01-01T00:00:00Z" && !/person_budget_exceeded/.test(JSON.stringify(t.lines)), "G the budget refusal is ONE budget line");
  const c = await req("/api/conversation?provider=codex");
  const cl = await req("/api/conversation");
  ok(c.j.budget?.blocked === true && cl.j.budget?.blocked === true, "G both sides say blocked");
}

// ---- H ----------------------------------------------------------------------------------
{
  const claudeBefore = (await req("/api/conversation")).j.items.length;
  const n = await req("/api/new?provider=codex", { method: "POST", body: {} });
  const c = await req("/api/conversation?provider=codex");
  ok(n.status === 200 && c.j.items.length === 0 && !c.j.session, "H 新对话 empties the Codex side");
  ok(existsSync(join(STATE, "codex", `${thread1}.ndjson`)), "H the old thread's record is kept");
  ok((await req("/api/conversation")).j.items.length === claudeBefore, "H the Claude side is untouched");
  const t = await turn("hello again");
  const ses = t.lines.find((o) => o.t === "session");
  ok(ses && ses.id !== thread1 && /^thr-2-/.test(ses.id), "H the next turn starts a new thread");
}

// ---- H2: 新对话 on the Claude side leaves the Codex side alone ------------------------------
{
  const before = await req("/api/conversation?provider=codex");
  const n = await req("/api/new", { method: "POST", body: {} });
  const after = await req("/api/conversation?provider=codex");
  ok(n.status === 200 && after.j.session === before.j.session && after.j.items.length === before.j.items.length, "H 新对话 on the Claude side: the Codex side untouched");
}

// ---- I ----------------------------------------------------------------------------------
{
  const thr = (await req("/api/conversation?provider=codex")).j.session;
  await stop();
  await start();
  const starts = rpc().filter((m) => m.method === "thread/start").length;
  const t = await turn("after restart");
  ok(rpc().some((m) => m.method === "thread/resume" && m.params.threadId === thr), "I a restart resumes the same thread");
  ok(rpc().filter((m) => m.method === "thread/start").length === starts && t.lines.find((o) => o.t === "session")?.id === thr, "I no new thread");
}

// ---- L: a terminal's Codex thread handed to the page (T810) --------------------------------
{
  const before = (await req("/api/conversation?provider=codex")).j.session;
  const a = await req("/api/adopt", { method: "POST", body: { agent: "codex", session: TERM_THREAD, label: "scratch-9", machine: "mini2" } });
  ok(a.status === 200, `L adopt a Codex thread (${a.status} ${a.body})`);
  const c = await req("/api/conversation?provider=codex");
  ok(c.j.session === TERM_THREAD && c.j.cwd === join(T, "signup") && c.j.handed?.from === "terminal", "L it is the Codex side's conversation, in its own directory, said handed");
  const k = c.j.items.map((o) => o.t).join(",");
  ok(k === "user,tool,tool_result,text" && c.j.items[0].text === "终端里问的" && c.j.items[1].summary === "Shell · ls", `L its history is Codex's own rollout (${k})`);
  const conf = JSON.parse(readFileSync(join(STATE, "conversation-codex.json"), "utf8"));
  ok(conf.put_away.some((x) => x.thread === before), "L the thread it had is put away");
  ok((await req("/api/adopt", { method: "POST", body: { agent: "codex", session: "no-such-thread" } })).status === 404, "L a thread with no rollout here is 404");
  writeFileSync(join(LOCKS, `codex-${TERM_THREAD}.json`), JSON.stringify({ holder: "terminal" }));
  const t = await turn("while the terminal holds it");
  ok(t.status === 409, "L the terminal holds it: a turn is refused 409");
  const o = await req("/api/conversation?provider=codex");
  ok(o.j.owner?.where === "terminal" && o.j.owner.agent === "codex" && o.j.owner.label === "scratch-9", "L the conversation names the owner");
  const st = await req("/api/state?provider=codex");
  ok(st.j.session === TERM_THREAD && st.j.busy === false, "L /api/state?provider=codex is the Codex side's");
  const tk = await req("/api/take?provider=codex", { method: "POST", body: {} });
  ok(tk.status === 200 && readFileSync(HANDLOG, "utf8").includes(`to-webchat-take --agent codex --sid ${TERM_THREAD}`), "L 在这里继续 takes the Codex thread back");
  ok((await req("/api/release?provider=codex", { method: "POST", body: { session: TERM_THREAD } })).status === 200, "L /api/release?provider=codex answers");
  const t2 = await turn("now here");
  ok(t2.status === 200 && rpc().some((m) => m.method === "thread/resume" && m.params.threadId === TERM_THREAD), "L the next turn resumes the terminal's thread");
}

// ---- K: no codex here ---------------------------------------------------------------------
{
  await stop();
  await start({ FLEET_WEBCHAT_CODEX_BIN: "" });
  const cx = await req("/api/adopt", { method: "POST", body: { agent: "codex", session: TERM_THREAD } });
  ok(cx.status === 409 && cx.j.code === "no_codex", "K no codex: adopting a Codex thread is 409 no_codex");
  const cl = await req("/api/conversation");
  ok(cl.status === 200 && cl.j.providers === undefined && cl.j.others === undefined, "K no codex: the Claude side answers as before");
  ok((await req("/api/conversation?provider=codex")).status === 404, "K no codex: the Codex side is 404");
  await stop();
}

// ---- J ----------------------------------------------------------------------------------
{
  const files = [];
  const walk = (d) => { for (const f of readdirSync(d, { withFileTypes: true })) { const p = join(d, f.name); if (f.isDirectory()) walk(p); else if (f.isFile()) files.push(p); } };
  walk(STATE);
  const leaked = files.filter((f) => readFileSync(f).includes(SECRET));
  ok(!seen.some((b) => b.includes(SECRET)), "J the credential is in no response");
  ok(leaked.length === 0, `J the credential is in no file of the state dir${leaked.length ? " (" + leaked.join(", ") + ")" : ""}`);
  ok(/mint --provider codex/.test(readFileSync(CREDLOG, "utf8")) && /revoke --sid web-codex-/.test(readFileSync(CREDLOG, "utf8")), "J minted for codex, revoked when the service stopped");
}

console.log(fails ? `FAIL fleet-webchat-codex-selftest: ${fails} failed` : "PASS fleet-webchat-codex-selftest");
process.exit(fails ? 1 : 0);
