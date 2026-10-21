#!/usr/bin/env node
// server.mjs — talk to a Claude session from a browser, the smallest version
// (issue #3567). Run by bin/fleet-webchat.sh as THIS login, never anyone else's.
//
//   * Two ways in, one at a time (issue #3643, EPIC #3642 C1):
//     - `--socket` (the default road — `fleet-webchat.sh serve`, a registered
//       service): listens ONLY on <state>/chat.sock — the socket 0600 in the
//       login's 0700 state dir, so no other login on the machine can connect —
//       and trusts what comes in on it: no cookie, no login link, no admin.token,
//       no TCP port at all. What reaches it is the node program's relay (C2),
//       which checks the person's signed X-Fleet-Person before it dials; here
//       that header is read for the log only, never as a credential.
//     - the local mode (FLEET_WEBCHAT_LOCAL=1 only — off by default, D3: a
//       developer's / a debugger's road): 127.0.0.1 only, no option to widen it
//       (CLAUDE.md: a temp server binds loopback), reached over the person's own
//       ssh forward (fleet-open) or the tailnet name in front of it. Only this
//       login's person comes in: a ONE-TIME login link (10 min) minted by
//       `fleet-webchat.sh link`, which proves itself with admin.token — a 0600
//       file in the 0700 state dir. The link sets an HttpOnly SameSite=Strict
//       cookie; everything else without it is 403. A Host the server does not
//       know is refused (rebinding).
//   * The pool's per-person budget (fleet.person_budget): the credential proxy
//     refuses a turn 403 person_budget_exceeded; the page gets that as ONE
//     stream line {t:"error", code:"budget", msg, until?} — never the raw API
//     error as the assistant's words — and /api/conversation says `budget`
//     (blocked or not) until a turn goes through again.
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
//   * On demand (issue #3647, EPIC #3642 D1): the node starts the service when a
//     person opens the chat (`fleet-node-supervisor.py service ensure`); after
//     FLEET_WEBCHAT_IDLE_SECS (2 h) with no turn running and no page connected it
//     exits 75 — the daemon's idle code: kept off, the entry kept, started again on
//     the next open.
//   * It follows its person (C5): `fleet service move webchat --to <login>` carries
//     the state dir (its paths[]) but not ~/.claude, so every session of the
//     conversation is copied into <state>/transcripts/ after each turn and on the
//     way out; a server that starts under another home puts them back under its
//     own projects dir, the cwd rehomed, and the conversation goes on there.
import http from "node:http";
import { gzipSync } from "node:zlib";
import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { promises as fsp, readFileSync, writeFileSync, mkdirSync, chmodSync, existsSync, realpathSync, renameSync, unlinkSync,
  statSync, copyFileSync } from "node:fs";
import { join, dirname, extname, normalize, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import net from "node:net";
import { COOKIE, CODE_TTL_MS, COOKIE_TTL_S, newSecret, sha, sameSecret, parseCookies,
  hostAllowed, redact, agentEnv, parseMint, toolSummary, MODELS, DEFAULT_MODEL, modelAllowed,
  budgetRefusal, personName, PERMISSIONS, cleanBrowser, parseClient, contextLine, contextBlock, contextDetails,
  CTX_RE, imageBlockBytes, imageSize, MEDIA_REF_RE, IMAGE_EXT_MIME, linkTargets, fileDenied, linkedType } from "./lib.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const E = process.env;
const STATE = E.FLEET_WEBCHAT_STATE;
if (!STATE) { console.error("fleet-webchat: FLEET_WEBCHAT_STATE is not set"); process.exit(2); }
mkdirSync(STATE, { recursive: true, mode: 0o700 });
chmodSync(STATE, 0o700);
const SOCKET = process.argv.includes("--socket");
const SOCK = join(STATE, "chat.sock");
if (!SOCKET && E.FLEET_WEBCHAT_LOCAL !== "1") {
  console.error("fleet-webchat: the local mode (127.0.0.1 + a login link) is off — FLEET_WEBCHAT_LOCAL=1 turns it on; the service runs `server.mjs --socket`");
  process.exit(2);
}
const BIND = "127.0.0.1";                              // never configurable
const HOSTS = (E.FLEET_WEBCHAT_HOSTS || "").split(",").map((s) => s.trim()).filter(Boolean);
const CWD = E.FLEET_WEBCHAT_CWD || E.HOME;
const CLAUDE = E.FLEET_WEBCHAT_CLAUDE || "";
const SESSION_CRED = E.FLEET_WEBCHAT_SESSION_CRED || join(HERE, "../../bin/fleet-session-cred.sh");
const SDK_PATH = E.FLEET_WEBCHAT_SDK || "";
const ASK_TIMEOUT_MS = Number(E.FLEET_WEBCHAT_ASK_SECS || 1800) * 1000;
const COMPACT_AT = Number(E.FLEET_WEBCHAT_COMPACT_AT || 0.8);  // the context share that triggers a compact
const PROJECTS = join(E.CLAUDE_CONFIG_DIR || join(E.HOME || "", ".claude"), "projects");
// socket mode: exit idle after this long with nothing to do (0 = never); 75 is the
// daemon's word for "done for now" (fleet-node-supervisor.py SVC_IDLE_RC)
const IDLE_SECS = Number(E.FLEET_WEBCHAT_IDLE_SECS ?? 7200);
const IDLE_RC = 75;
const CARRY = join(STATE, "transcripts");
// The page is the built UI (issue #3637): ui/dist, made by `npm run build` in
// extras/web-chat/ui and committed — served from here, every byte local.
const UI = E.FLEET_WEBCHAT_UI || join(HERE, "ui", "dist");
const MIME = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".svg": "image/svg+xml", ".woff2": "font/woff2", ".woff": "font/woff", ".json": "application/json", ".png": "image/png" };
// nothing from another origin, ever: no CDN, no font service, no beacon
const CSP = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; " +
  "font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'";
const staticCache = new Map();                           // path → { body, gz, type }
function uiFile(rel) {
  const full = normalize(join(UI, rel));
  if (full !== UI && !full.startsWith(UI + sep)) return null;
  let f = staticCache.get(full);
  if (!f) {
    let body;
    try { body = readFileSync(full); } catch { return null; }
    const type = MIME[extname(full)] || "application/octet-stream";
    f = { body, type, gz: /^(text|application\/json|image\/svg)/.test(type) && body.length > 1024 ? gzipSync(body) : null };
    staticCache.set(full, f);
  }
  return f;
}
function sendFile(req, res, f, cache) {
  const gz = f.gz && /\bgzip\b/.test(req.headers["accept-encoding"] || "");
  res.writeHead(200, { "Content-Type": f.type, "Cache-Control": cache, "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer", "X-Frame-Options": "DENY", "Content-Security-Policy": CSP,
    ...(gz ? { "Content-Encoding": "gzip", Vary: "Accept-Encoding" } : {}) });
  res.end(gz ? f.gz : f.body);
}

// ---- the state dir: admin token, cookies (hashed), log ----------------------
// the socket mode has no admin token and writes none: nobody mints a link there
const ADMIN = SOCKET ? "" : newSecret();
if (!SOCKET) {
  writeFileSync(join(STATE, "admin.token"), ADMIN + "\n", { mode: 0o600 });
  chmodSync(join(STATE, "admin.token"), 0o600);
}
const COOKIES_FILE = join(STATE, "cookies.json");
let cookies = {};                                        // sha256(cookie) → expiry ms
try { cookies = JSON.parse(readFileSync(COOKIES_FILE, "utf8")) || {}; } catch { cookies = {}; }
const saveCookies = () => writeFileSync(COOKIES_FILE, JSON.stringify(cookies), { mode: 0o600 });
const codes = new Map();                                 // sha256(code) → expiry ms (memory only)
const liveCreds = new Set();                             // what redact() must also catch
const BUDGET_FILE = join(STATE, "budget.json");
let budget = null;                                       // the last refusal: { msg, until, at } — cleared by a turn that goes through
try { budget = JSON.parse(readFileSync(BUDGET_FILE, "utf8")) || null; } catch { budget = null; }
function setBudget(b) {
  budget = b;
  try { if (b) writeFileSync(BUDGET_FILE, JSON.stringify(b), { mode: 0o600 }); else if (existsSync(BUDGET_FILE)) writeFileSync(BUDGET_FILE, "null", { mode: 0o600 }); } catch { /* memory still holds it */ }
}
function budgetView() {
  if (!budget) return { blocked: false };
  if (budget.until && Date.parse(budget.until) <= Date.now()) return { blocked: false };
  return { blocked: true, msg: budget.msg, ...(budget.until ? { until: budget.until } : {}) };
}

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

// ---- the session credential: one per conversation, reused by every turn --------
// (task V9DJ C1: minting one took p50 8 s / p90 18 s on a busy home — a route
// probe and a mint, each its own shell + python — and revoking another 2 s, on
// every turn before the model was even asked). Minted on the first need (or when
// the page reads the conversation, ahead of a turn), dropped when a turn fails
// on something else than a budget or the stop key, revoked when the service exits.
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
let credP = null;
function credFor() {
  if (!credP) credP = mintCred().catch((e) => { credP = null; throw e; });
  return credP;
}
async function dropCred(why) {
  const p = credP;
  credP = null;
  if (!p) return;
  const c = await p.catch(() => null);
  if (c?.mint) log("cred_drop", { cred_sid: c.sid, why });
  await revokeCred(c);
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


// ---- images (task T773) -----------------------------------------------------------
// An image in a reply, a tool's result or the person's own message is kept once
// under <state>/media/<sha256[:32]>.<ext> (0600) and travels to the page as an
// item {t:"image", ref, w, h} — the page fetches the bytes by ref (/api/file), so
// the conversation's JSON never carries them. A small preview (thumb, a data URL,
// ≤ THUMB_MAX) rides on the newest THUMBS_SHOWN items: the entry's copy beside it
// keeps only those (chat_mirror.go). Bigger than IMAGE_MAX: shown as too big.
const MEDIA = join(STATE, "media");
const IMAGE_MAX = Number(E.FLEET_WEBCHAT_IMAGE_MAX || 10 * 1024 * 1024);
const IMAGES_PER_REPLY = Number(E.FLEET_WEBCHAT_IMAGES_PER_REPLY || 20);
// what a person may send with one line: PICS_PER_TURN pictures, the whole request
// within the chat transport's one-request bound (the page shrinks them to fit)
const PICS_PER_TURN = 4;
const TURN_MAX = 1024 * 1024 + 64 * 1024;
const THUMB_MAX = 24 * 1024;
const THUMBS_SHOWN = 60;
const mediaSize = new Map();                              // ref → {w, h}
function keepImage(b) {
  const img = imageBlockBytes(b);
  if (!img) return null;
  if (img.buf.length > IMAGE_MAX) return { big: true };
  const ref = createHash("sha256").update(img.buf).digest("hex").slice(0, 32) + "." + img.ext;
  let size = mediaSize.get(ref);
  if (!size) {
    const f = join(MEDIA, ref);
    if (!existsSync(f)) {
      try {
        mkdirSync(MEDIA, { recursive: true, mode: 0o700 });
        writeFileSync(f + ".tmp", img.buf, { mode: 0o600 });
        renameSync(f + ".tmp", f);
      } catch (e) { log("media_failed", { msg: String(e?.message || e).slice(0, 200) }); return null; }
    }
    size = imageSize(img.buf, img.ext);
    mediaSize.set(ref, size);
  }
  return { ref, ...size };
}
// the image items of a block list (a reply's, a tool result's), `extra` on each
function imageItems(list, extra = {}) {
  const out = [];
  for (const b of blocks(list)) {
    const k = keepImage(b);
    if (k) out.push(k.big ? { t: "image", big: true, ...extra } : { t: "image", ...extra, ...k });
  }
  return out;
}
// The previews: made in the background by whatever this machine has (macOS sips,
// else ImageMagick); none ⇒ no thumb, the page still shows the image itself.
let thumbTool;
const thumbBusy = new Set();
function thumbCmd(src, dst) {
  if (thumbTool === undefined) {
    thumbTool = null;
    for (const [bin, mk] of [["/usr/bin/sips", (a, b) => ["-Z", "320", "-s", "format", "jpeg", "-s", "formatOptions", "60", a, "--out", b]],
      ...["/opt/homebrew/bin/magick", "/usr/local/bin/magick", "/usr/bin/magick", "/usr/bin/convert"].map((x) => [x, (a, b) => [a + "[0]", "-thumbnail", "320x320", "-quality", "60", "jpeg:" + b]])]) {
      if (existsSync(bin)) { thumbTool = { bin, mk }; break; }
    }
  }
  return thumbTool && [thumbTool.bin, thumbTool.mk(src, dst)];
}
function thumbOf(ref) {
  const f = join(MEDIA, ref.replace(/\.\w+$/, ".thumb.jpg"));
  try {
    const b = readFileSync(f);
    return b.length && b.length <= THUMB_MAX ? "data:image/jpeg;base64," + b.toString("base64") : "";
  } catch { /* not made yet */ }
  const cmd = thumbCmd(join(MEDIA, ref), f + ".tmp");
  if (cmd && !thumbBusy.has(ref)) {
    thumbBusy.add(ref);
    execFile(cmd[0], cmd[1], { timeout: 20000 }, (err) => {
      thumbBusy.delete(ref);
      try { if (!err) { chmodSync(f + ".tmp", 0o600); renameSync(f + ".tmp", f); } else unlinkSync(f + ".tmp"); } catch { /* none written */ }
    });
  }
  return "";
}
// at most IMAGES_PER_REPLY images between two of the person's lines; the rest
// are counted on one {t:"image_more", n} item; the newest carry their thumb
function capImages(items) {
  const out = [];
  let n = 0;
  for (const it of items) {
    if (it.t === "user") n = 0;
    if (it.t === "image" && ++n > IMAGES_PER_REPLY) {
      const last = out[out.length - 1];
      if (last?.t === "image_more") last.n++; else out.push({ t: "image_more", n: 1 });
      continue;
    }
    out.push(it);
  }
  let left = THUMBS_SHOWN;
  for (let i = out.length - 1; i >= 0 && left > 0; i--) {
    const it = out[i];
    for (const g of it.t === "image" ? [it] : it.t === "user" ? it.images || [] : []) {
      if (!g.ref || left <= 0) continue;
      left--;
      const th = thumbOf(g.ref);
      if (th) g.thumb = th;
    }
  }
  return out;
}
async function sendMedia(req, res, ref) {
  if (!MEDIA_REF_RE.test(ref || "")) return send(res, 404, { error: "not found" });
  let body;
  try { body = await fsp.readFile(join(MEDIA, ref)); } catch { return send(res, 404, { error: "not found" }); }
  // an image only, never run: its own type, no sniffing, a sandbox with nothing allowed
  res.writeHead(200, { "Content-Type": IMAGE_EXT_MIME[ref.split(".").pop()], "Content-Length": body.length,
    "Cache-Control": "private, max-age=604800, immutable", "X-Content-Type-Options": "nosniff",
    "Content-Security-Policy": "default-src 'none'; sandbox", "Content-Disposition": `inline; filename="${ref}"`,
    "Referrer-Policy": "no-referrer", "X-Frame-Options": "DENY" });
  res.end(body);
}

// ---- the files a reply links to (task T773 ②) ---------------------------------------
// A reply's Markdown link to a file on this machine ("改动在 [form.css](/Users/…)")
// points nowhere in a browser. Each such file under $HOME or the session's
// directory — a regular file, ≤ LINK_MAX, never a key / configuration / secret
// (lib.mjs fileDenied) — gets an opaque ref (f + 32 hex, kept in <state>/refs.json
// for LINK_DAYS) and the page gets {t:"files", files: {<target as written>: ref}}
// after the reply's text; it rewrites those link targets to /v1/chat/file?ref=.
// The entry never sees a path. Served: an image as itself, anything else (HTML and
// SVG included) as a download — under a sandbox CSP, so nothing the agent wrote
// ever runs on the entry's site.
const LINK_MAX = Number(E.FLEET_WEBCHAT_LINK_MAX || 20 * 1024 * 1024);
const LINK_DAYS = Number(E.FLEET_WEBCHAT_LINK_DAYS || 7);
const REFS_FILE = join(STATE, "refs.json");
const LINK_REF_RE = /^f[0-9a-f]{32}$/;
let fileRefs = {};                                       // ref → { path, exp }
try { fileRefs = JSON.parse(readFileSync(REFS_FILE, "utf8")) || {}; } catch { fileRefs = {}; }
let refsDirty = false;
function saveRefs() {
  if (!refsDirty) return;
  refsDirty = false;
  const now = Date.now();
  for (const [k, v] of Object.entries(fileRefs)) if (!(v.exp + 30 * 864e5 > now)) delete fileRefs[k];   // an expired one still says so for 30 days
  try { writeFileSync(REFS_FILE + ".tmp", JSON.stringify(fileRefs), { mode: 0o600 }); renameSync(REFS_FILE + ".tmp", REFS_FILE); }
  catch (e) { log("refs_failed", { msg: String(e?.message || e).slice(0, 200) }); }
}
// the real path of a file the page may open, or "" (outside the roots, denied, not a file, too big)
function linkable(target, cwd) {
  let p = target;
  if (/^file:\/\//i.test(p)) { try { p = fileURLToPath(p); } catch { return ""; } }
  else if (p.startsWith("~/")) p = join(E.HOME || "", p.slice(2));
  else if (!p.startsWith("/")) p = join(cwd || CWD, p);
  try { p = decodeURIComponent(p); } catch { /* as written */ }
  let real;
  try { real = realpathSync(p); } catch { return ""; }
  const roots = [E.HOME, cwd].filter(Boolean).map((r) => { try { return realpathSync(r); } catch { return ""; } }).filter(Boolean);
  const root = roots.find((r) => real.startsWith(r + sep));
  if (!root) return "";
  const home = roots[0] && real.startsWith(roots[0] + sep) ? roots[0] : root;
  if (fileDenied(real.slice(home.length + 1))) return "";
  let st;
  try { st = statSync(real); } catch { return ""; }
  return st.isFile() && st.size <= LINK_MAX ? real : "";
}
// {target: ref} for every linkable file a text names
function filesOf(text, cwd) {
  const out = {};
  const now = Date.now();
  for (const t of linkTargets(text)) {
    const real = linkable(t, cwd);
    if (!real) continue;
    let ref = Object.keys(fileRefs).find((k) => fileRefs[k].path === real && fileRefs[k].exp > now + 864e5);
    if (!ref) { ref = "f" + randomHex(); fileRefs[ref] = { path: real, exp: now + LINK_DAYS * 864e5 }; refsDirty = true; }
    out[t] = ref;
  }
  return Object.keys(out).length ? out : null;
}
const randomHex = () => createHash("sha256").update(newSecret(32)).digest("hex").slice(0, 32);
async function sendLinked(req, res, ref) {
  const r = fileRefs[ref];
  const head = { "X-Content-Type-Options": "nosniff", "Content-Security-Policy": "default-src 'none'; sandbox",
    "Referrer-Policy": "no-referrer", "X-Frame-Options": "DENY", "Cache-Control": "private, no-store" };
  if (!r) return send(res, 404, { error: "not found" });
  if (!(r.exp > Date.now())) {
    res.writeHead(410, { ...head, "Content-Type": "text/plain; charset=utf-8" });
    return res.end("这个文件链接已过期（7 天）。让 Agent 再给一次。\nThis file link has expired; ask the agent for it again.\n");
  }
  // checked again at the read: the path may have become a link out, a secret's name, a directory
  const real = linkable(r.path, conv.cwd);
  if (real !== r.path) return send(res, 404, { error: "not found" });
  let body;
  try { body = await fsp.readFile(real); } catch { return send(res, 404, { error: "not found" }); }
  const name = real.split(sep).pop();
  const t = linkedType(name);
  res.writeHead(200, { ...head, "Content-Type": t.type, "Content-Length": body.length,
    "Content-Disposition": `${t.inline ? "inline" : "attachment"}; filename*=UTF-8''${encodeURIComponent(name)}` });
  res.end(body);
}

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
    // the person's own pictures ride on their line (the first text of the message)
    let pics = m.type === "user" ? imageItems(m.message?.content).filter((g) => g.ref).map(({ ref, w, h }) => ({ ref, w, h })) : [];
    for (const b of blocks(m.message?.content)) {
      if (m.type === "user" && b.type === "text" && b.text && !/^\s*<(command|local-command|system-reminder)/.test(b.text)) {
        const text = b.text.replace(SEED_RE, "").replace(CTX_RE, "");
        if (text || pics.length) out.push({ t: "user", text, ...(pics.length ? { images: pics } : {}) });
        pics = [];
      } else if (m.type === "assistant" && b.type === "text" && b.text) {
        out.push({ t: "text", d: b.text });
        const files = filesOf(b.text, cwd);
        if (files) out.push({ t: "files", files });
      }
      else if (m.type === "assistant" && b.type === "image") out.push(...imageItems([b]));
      else if (m.type === "assistant" && b.type === "tool_use") out.push({ t: "tool", id: b.id, name: b.name, summary: toolSummary(b.name, b.input) });
      else if (m.type === "user" && b.type === "tool_result") {
        out.push({ t: "tool_result", id: b.tool_use_id, text: resultText(b.content), error: !!b.is_error });
        out.push(...imageItems(b.content, { id: b.tool_use_id }));
      }
    }
    if (pics.length) out.push({ t: "user", text: "", images: pics });
  }
  return out;
}
async function conversationItems() {
  const out = [];
  for (const s of conv.chain) out.push(...await readItems(s.id, s.cwd));
  if (conv.session) out.push(...await readItems(conv.session, conv.cwd));
  saveRefs();
  return capImages(out);
}

// ---- the one conversation ------------------------------------------------------
const CONV_FILE = join(STATE, "conversation.json");
let conv = { session: "", cwd: CWD, chain: [], seed: "", ctx: { used: 0, window: 0 }, home: E.HOME || "", ctxKey: "" };
try { conv = { ...conv, home: "", ...JSON.parse(readFileSync(CONV_FILE, "utf8")) }; } catch { /* a first start */ }
function saveConv() {
  writeFileSync(CONV_FILE + ".tmp", JSON.stringify(conv), { mode: 0o600 });
  renameSync(CONV_FILE + ".tmp", CONV_FILE);
}

// ---- the conversation follows its person (issue #3647) -------------------------
const sessions = () => [...conv.chain, ...(conv.session ? [{ id: conv.session, cwd: conv.cwd }] : [])];
// a copy of each session's transcript in the state dir, the part `service move` carries
function carryOut() {
  try {
    mkdirSync(CARRY, { recursive: true, mode: 0o700 });
    for (const s of sessions()) {
      const src = transcriptPath(s.id, s.cwd), dst = join(CARRY, `${s.id}.jsonl`);
      let a; try { a = statSync(src); } catch { continue; }
      let b = null; try { b = statSync(dst); } catch { /* none yet */ }
      if (b && b.size === a.size && b.mtimeMs >= a.mtimeMs) continue;
      copyFileSync(src, dst + ".tmp");
      chmodSync(dst + ".tmp", 0o600);
      renameSync(dst + ".tmp", dst);
    }
  } catch (e) { log("carry_failed", { msg: String(e?.message || e).slice(0, 200) }); }
}
// started under another home than the conversation last ran in: its transcripts
// back under this home's projects dir, every cwd rehomed (inside the lines too)
function carryIn() {
  const home = E.HOME || "", old = conv.home;
  if (!old || old === home || !home) {
    if (!old && home && sessions().length) { conv.home = home; saveConv(); }
    return;
  }
  const n = restoreSessions(old, home);
  saveConv();
  log("home_moved", { from: old, to: home, restored: n });
}
// each session's carried copy put back under home's projects dir where it is
// missing, its cwd moved from old to home (the lines' too); how many written
function restoreSessions(old, home) {
  const rehome = (c) => c === old ? home : c.startsWith(old + "/") ? home + c.slice(old.length) : c;
  let n = 0;
  const all = sessions();
  for (const s of all) {
    const was = s.cwd, now = rehome(was);
    const src = join(CARRY, `${s.id}.jsonl`), dst = transcriptPath(s.id, now);
    if (existsSync(src) && !existsSync(dst)) {
      const lines = readFileSync(src, "utf8").split("\n").map((l) => {
        if (!l) return l;
        try { const m = JSON.parse(l); if (m && m.cwd === was) { m.cwd = now; return JSON.stringify(m); } } catch { /* as is */ }
        return l;
      });
      mkdirSync(dirname(dst), { recursive: true, mode: 0o700 });
      writeFileSync(dst, lines.join("\n"), { mode: 0o600 });
      n++;
    }
    s.cwd = now;
  }
  if (conv.session) conv.cwd = all.at(-1).cwd;          // the chain's entries are conv's own, rehomed in place
  conv.home = home;
  return n;
}
carryIn();
let live = null;          // the running turn: { tid, ac, listeners, asks, model }
let maint = null;         // a compact / relay between turns (the next turn waits for it)
let ridSeq = 0;

// the context's size, off every message of a query
function account(m) {
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
}

// One query() through the conversation's session credential; onMsg sees every SDK message.
// A prompt that is content blocks (pictures with the words, task T773 ③) goes in as
// the one user message of an input stream — query() takes a string or a stream.
async function runQuery(prompt, { model, resume, cwd, ac, canUseTool, mcpServers }, onMsg) {
  if (Array.isArray(prompt)) {
    const one = inputStream();
    one.push({ type: "user", message: { role: "user", content: prompt }, parent_tool_use_id: null, session_id: resume || "" });
    one.end();
    prompt = one;
  }
  const S = await sdk();
  const cred = await credFor();
  log("query", { cred_sid: cred.sid, route: cred.route, model, resume: !!resume });
  try {
    const q = S.query({ prompt, options: {
      cwd, resume: resume || undefined, model, env: agentEnv(E, cred.mint), includePartialMessages: true,
      ...PERMISSIONS, settingSources: [...PERMISSIONS.settingSources], canUseTool,
      ...(mcpServers ? { mcpServers } : {}),
      abortController: ac, ...(CLAUDE ? { pathToClaudeCodeExecutable: CLAUDE } : {}),
      stderr: () => {},                    // the child's stderr is never relayed or logged
    } });
    for await (const m of q) {
      if (m.session_id && !resume && !conv.session) { conv.session = m.session_id; conv.cwd = cwd; saveConv(); }
      account(m);
      onMsg(m);
    }
  } catch (e) {
    // a failed turn may be the credential's (the proxy forgot it, a rebind): the
    // next turn mints a fresh one. A budget refusal or the stop key is not.
    if (!ac?.signal?.aborted && !e?.budget && !e?.tooLong && !budgetRefusal([String(e?.message || "")]) && !TOO_LONG.test(String(e?.message || ""))) await dropCred("turn failed");
    throw e;
  } finally {
    saveConv();
  }
}

// ---- the warm agent (task V9DJ C2) ---------------------------------------------
// Starting Claude Code and resuming the conversation took ~6 s of every turn
// (p50, a busy home) before the model was asked. One query() is kept open on
// the conversation instead, fed by an input stream: a turn pushes its words and
// ends on that turn's result. It closes on the stop key, before a compact or a
// relay, on a model the SDK cannot switch, on any error, and after
// FLEET_WEBCHAT_WARM_SECS idle (default 600; 0 = off: every turn starts its own,
// as before) — the next turn opens it again. A page reading the conversation
// opens it ahead of the turn.
const WARM_IDLE_MS = Number(E.FLEET_WEBCHAT_WARM_SECS ?? 600) * 1000;
let warm = null;          // { q, input, ac, cwd, resume, session, model, cur, details, canUse, idle, closed }
let warmOpening = null;
let lastModel = DEFAULT_MODEL;
function inputStream() {
  const buf = [];
  let wake = null, ended = false;
  return {
    push(m) { buf.push(m); wake?.(); wake = null; },
    end() { ended = true; wake?.(); wake = null; },
    async *[Symbol.asyncIterator]() {
      for (;;) {
        while (buf.length) yield buf.shift();
        if (ended) return;
        await new Promise((r) => { wake = r; });
      }
    },
  };
}
function closeWarm(why) {
  const w = warm;
  warm = null;
  if (!w || w.closed) return;
  w.closed = true;
  clearTimeout(w.idle);
  log("warm_close", { why });
  w.input.end();
  w.ac.abort();
}
async function openWarm({ model, cwd, resume }) {
  const S = await sdk();
  const cred = await credFor();
  const w = { input: inputStream(), ac: new AbortController(), cwd, resume: resume || "", session: resume || "", model,
    cur: null, details: null, canUse: null, idle: null, closed: false };
  w.q = S.query({ prompt: w.input, options: {
    cwd, resume: resume || undefined, model, env: agentEnv(E, cred.mint), includePartialMessages: true,
    ...PERMISSIONS, settingSources: [...PERMISSIONS.settingSources],
    canUseTool: (n, i, o) => (w.canUse ? w.canUse(n, i, o) : Promise.resolve({ behavior: "deny", message: "no turn is running" })),
    mcpServers: browserTools(S, () => w.details),
    abortController: w.ac, ...(CLAUDE ? { pathToClaudeCodeExecutable: CLAUDE } : {}),
    stderr: () => {},
  } });
  log("warm_open", { cred_sid: cred.sid, route: cred.route, model, resume: !!resume });
  (async () => {
    try {
      for await (const m of w.q) {
        if (m.session_id && !w.session) {
          w.session = m.session_id;
          if (!conv.session) { conv.session = m.session_id; conv.cwd = cwd; saveConv(); }
        }
        account(m);
        const c = w.cur;
        if (!c) continue;
        try { c.onMsg(m); } catch (e) { w.cur = null; c.reject(e); closeWarm("turn error"); return; }
        if (m.type === "result") { w.cur = null; c.resolve(); w.idle = setTimeout(() => { if (warm === w && !w.cur) closeWarm("idle"); }, WARM_IDLE_MS); }
      }
      throw new Error("the agent ended");
    } catch (e) {
      const c = w.cur;
      w.cur = null;
      c?.reject(e);
    } finally {
      if (warm === w) closeWarm("ended");
    }
  })();
  return w;
}
// a page is about to talk: have the agent ready (never while a turn or a compact runs)
function prewarm() {
  if (!WARM_IDLE_MS || !SDK_PATH || live || maint || warm || warmOpening || !conv.session) return;
  warmOpening = openWarm({ model: lastModel, cwd: conv.cwd, resume: conv.session })
    // a turn that came in meanwhile waits on this and takes it; a compact does not
    .then((w) => { warm = w; if (maint) closeWarm("busy"); })
    .catch((e) => log("warm_failed", { msg: String(e?.message || e).slice(0, 200) }))
    .finally(() => { warmOpening = null; });
}
// One turn on the warm agent (runQuery's contract: onMsg sees every message of
// this turn; resolves on its result, throws on an error or the stop key).
async function warmQuery(prompt, { model, resume, cwd, ac, canUseTool, details }, onMsg) {
  lastModel = model;
  if (!WARM_IDLE_MS) return runQuery(prompt, { model, resume, cwd, ac, canUseTool, mcpServers: details ? browserTools(await sdk(), details) : undefined }, onMsg);
  if (warmOpening) await warmOpening;
  let w = warm;
  if (w && (w.closed || w.cur || w.cwd !== cwd || w.session !== (resume || ""))) { closeWarm("other session"); w = null; }
  if (w && w.model !== model) {
    if (typeof w.q.setModel === "function") {
      try { await w.q.setModel(model); w.model = model; } catch { closeWarm("model"); w = null; }
    } else { closeWarm("model"); w = null; }
  }
  try {
    if (!w) warm = w = await openWarm({ model, cwd, resume });
  } catch (e) {
    if (!e?.budget) await dropCred("agent failed to start");
    throw e;
  }
  clearTimeout(w.idle);
  w.details = details || null;
  w.canUse = canUseTool;
  const stop = () => { if (warm === w) closeWarm("stopped"); };
  ac.signal.addEventListener("abort", stop, { once: true });
  try {
    await new Promise((resolve, reject) => {
      w.cur = { onMsg, resolve, reject };
      if (w.session) onMsg({ type: "system", subtype: "init", session_id: w.session });
      w.input.push({ type: "user", message: { role: "user", content: prompt }, parent_tool_use_id: null, session_id: w.session });
    });
  } catch (e) {
    if (!ac.signal.aborted && !e?.budget && !e?.tooLong && !budgetRefusal([String(e?.message || "")]) && !TOO_LONG.test(String(e?.message || ""))) await dropCred("turn failed");
    throw e;
  } finally {
    ac.signal.removeEventListener("abort", stop);
    w.canUse = null;
    saveConv();
  }
}

// Between turns, out of sight: compact the conversation; failing that, relay to a
// new session seeded with the old one's tail. The page never sees either.
function maintain(why) {
  if (maint) return maint;
  maint = (async () => {
    log("maintain", { why, used: conv.ctx.used, window: conv.ctx.window });
    if (warmOpening) await warmOpening.catch(() => {});
    closeWarm("maintain");
    let ok = false;
    try {
      await runQuery("/compact", { model: DEFAULT_MODEL, resume: conv.session, cwd: conv.cwd, ac: new AbortController() },
        (m) => { if (m.type === "system" && m.subtype === "compact_boundary") ok = true; });
    } catch (e) { log("compact_failed", { msg: String(e?.message || e).slice(0, 200) }); }
    if (!ok) await relay();
    carryOut();
  })().finally(() => { maint = null; touch(); });
  return maint;
}
// the conversation's last words, newest kept, at most 8000 characters
function tailOf(items) {
  let tail = "";
  for (const it of items.slice().reverse()) {
    const line = it.t === "user" ? `用户：${it.text}` : it.t === "text" ? `助手：${it.d}` : "";
    if (!line) continue;
    if (tail.length + line.length > 8000) break;
    tail = line + "\n" + tail;
  }
  return tail;
}
async function relay() {
  const tail = tailOf(await readItems(conv.session, conv.cwd));
  log("relay", { from: conv.session });
  if (conv.session) conv.chain.push({ id: conv.session, cwd: conv.cwd });
  conv.session = "";
  conv.seed = `<fleet-webchat-relay>\n（这是同一段对话的接续：之前的会话太长，下面是它最后的部分，请接着它继续，不必提起这次接续。）\n${tail}</fleet-webchat-relay>\n\n`;
  conv.ctx = { used: 0, window: conv.ctx.window };
  saveConv();
}
// The browser_context tool (issue #4034): an in-process MCP server made for ONE
// turn, holding only that turn's browser — the person's own, nobody else's.
function browserTools(S, details) {
  if (typeof S.createSdkMcpServer !== "function" || typeof S.tool !== "function") return undefined;
  const now = () => (typeof details === "function" ? details() : details) || {};
  const t = S.tool("browser_context",
    "The browser the person is talking from right now: full IP address, approximate place, full user agent and " +
    "client hints, languages, time zone, screen and viewport, touch, network type. Call it only when the answer needs a detail " +
    "the one-line browser summary at the start of the conversation does not give.",
    {}, async () => ({ content: [{ type: "text", text: JSON.stringify(now()) }] }));
  return { fleet_browser: S.createSdkMcpServer({ name: "fleet_browser", version: "1.0.0", tools: [t] }) };
}
const TOO_LONG = /prompt is too long|context (?:window|length)|too many tokens/i;

// ---- a turn: NDJSON lines to every page that is watching ----------------------
function emitAll(o) {
  if (!live) return;
  const line = redact(JSON.stringify(o), [...liveCreds, ADMIN]) + "\n";
  for (const res of live.listeners) if (!res.writableEnded) res.write(line);
}
function askEvent(rid, a) {
  const id = a.toolUseID ? { id: a.toolUseID } : {};      // the tool step it gates (the page hangs it there)
  return a.name === "AskUserQuestion"
    ? { t: "ask", rid, ...id, kind: "question", questions: a.input.questions || [] }
    : { t: "ask", rid, ...id, kind: "permission", tool: a.name, summary: toolSummary(a.name, a.input) };
}

async function turn(req, res, person) {
  let body;
  try { body = await readJson(req, TURN_MAX); } catch { return send(res, 413, { error: "图太大：一条消息连图带字最多 1 MB" }); }
  const text = String(body.text || "").trim();
  const model = body.model == null || body.model === "" ? DEFAULT_MODEL : String(body.model);
  if (!modelAllowed(model)) { log("model_refused", { model: model.slice(0, 64) }); return send(res, 400, { error: "model not allowed" }); }
  // the person's pictures (task T773 ③): a few, of a type the page shows, each a real image
  const pics = Array.isArray(body.images) ? body.images : [];
  if (pics.length > PICS_PER_TURN) return send(res, 400, { error: `一条消息最多 ${PICS_PER_TURN} 张图` });
  const images = [];
  for (const g of pics) {
    const b = { type: "image", source: { type: "base64", media_type: String(g?.media_type || ""), data: String(g?.data || "") } };
    const img = imageBlockBytes(b);
    if (!img || !imageSize(img.buf, img.ext).w) return send(res, 400, { error: "不是能看的图片（png / jpeg / gif / webp）" });
    images.push(b);
  }
  if (!text && !images.length) return send(res, 400, { error: "empty" });
  if (live) return send(res, 409, { error: "还在回复上一句" });
  const S = await sdk().catch((e) => e);
  if (S instanceof Error) return send(res, 503, { error: S.message });
  // where the person is talking from (issue #4034): the page's own report + the
  // address and city the entry saw (socket mode: the relay is the only way in)
  const browser = cleanBrowser(body.client);
  const place = SOCKET ? parseClient(req.headers["x-fleet-client"]) : {};
  const where = contextLine(browser, place);
  const details = browser || place.ip ? contextDetails(browser, place) : null;

  const tid = newSecret(9);
  live = { tid, ac: new AbortController(), listeners: new Set([res]), asks: new Map(), model };
  res.writeHead(200, { "Content-Type": "application/x-ndjson; charset=utf-8", "Cache-Control": "no-store",
    "X-Accel-Buffering": "no", "X-Content-Type-Options": "nosniff" });
  // a page that goes away (a phone in a pocket) does not stop the turn — only the stop key does
  res.on("close", () => live?.listeners.delete(res));
  emitAll({ t: "turn", id: tid, model });
  log("turn", { person, model });

  // In bypass (lib.mjs PERMISSIONS) this is reached for AskUserQuestion — the
  // card the person picks from; any other tool runs without asking.
  const canUseTool = (name, input, opts = {}) => new Promise((resolve) => {
    const rid = `r${++ridSeq}-${newSecret(6)}`;
    const t = live;
    const done = (v) => { clearTimeout(timer); t.asks.delete(rid); resolve(v); };
    const timer = setTimeout(() => done({ behavior: "deny", message: "no answer from the web page in time" }), ASK_TIMEOUT_MS);
    t.asks.set(rid, { name, input, done, toolUseID: typeof opts.toolUseID === "string" ? opts.toolUseID : "" });
    opts.signal?.addEventListener?.("abort", () => done({ behavior: "deny", message: "aborted" }));
    emitAll(askEvent(rid, t.asks.get(rid)));
  });

  let sawDelta = false;
  let shown = 0;                                          // this turn's images, IMAGES_PER_REPLY at most
  const emitImages = (list, extra) => {
    for (const it of imageItems(list, extra)) emitAll(++shown > IMAGES_PER_REPLY ? { t: "image_more", n: 1 } : it);
  };
  const onMsg = (m) => {
    if (m.type === "system" && m.subtype === "init") return emitAll({ t: "session", id: m.session_id, cwd: conv.cwd });
    if (m.type === "stream_event") {
      const ev = m.event || {};
      if (ev.type === "content_block_delta" && ev.delta?.type === "text_delta") { sawDelta = true; emitAll({ t: "text", d: ev.delta.text }); }
      return;
    }
    if (m.type === "assistant" || m.type === "result") {
      // the credential proxy's 403 comes back as Claude Code's own "API Error: 403 …"
      // line — never the assistant's words on the page; the turn ends on it
      const b = budgetRefusal(m.type === "result" ? [m.result, m.errors] : m.message?.content);
      if (b) throw Object.assign(new Error(b.msg), { budget: b });
    }
    if (m.type === "assistant") {
      // its text already went out as deltas when the partial stream carried them
      for (const b of blocks(m.message?.content)) {
        if (b.type === "text" && b.text && !sawDelta) emitAll({ t: "text", d: b.text });
        if (b.type === "tool_use") emitAll({ t: "tool", id: b.id, name: b.name, summary: toolSummary(b.name, b.input) });
        if (b.type === "image") emitImages([b]);
        if (b.type === "text" && b.text) {
          const files = filesOf(b.text, conv.cwd || CWD);
          if (files) { emitAll({ t: "files", files }); saveRefs(); }
        }
      }
      sawDelta = false;
      return;
    }
    if (m.type === "user") {
      for (const b of blocks(m.message?.content)) {
        if (b.type === "tool_result") {
          emitAll({ t: "tool_result", id: b.tool_use_id, text: resultText(b.content), error: !!b.is_error });
          emitImages(b.content, { id: b.tool_use_id });
        }
      }
      return;
    }
    if (m.type === "result") {
      if (m.subtype !== "success" && TOO_LONG.test(JSON.stringify(m.errors || m.result || ""))) throw Object.assign(new Error("too long"), { tooLong: true });
      if (m.subtype === "success" && !m.is_error && budget) setBudget(null);
      emitAll({ t: "done", subtype: m.subtype, ms: m.duration_ms });
    }
  };

  try {
    if (maint) await maint;
    for (let attempt = 0; ; attempt++) {
      const seed = conv.session ? "" : conv.seed;
      // the one-line context goes in on a session's first turn and again only when it changed
      const head = where && (!conv.session || conv.ctxKey !== where.key) ? contextBlock(where.line) : "";
      try {
        const words = seed + head + text;
        await warmQuery(images.length ? [...images, ...(words ? [{ type: "text", text: words }] : [])] : words, { model, resume: conv.session, cwd: conv.session ? conv.cwd : CWD, ac: live.ac,
          canUseTool, details }, onMsg);
        if (seed) conv.seed = "";
        if (head) conv.ctxKey = where.key;
        if (seed || head) saveConv();
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
    const b = e?.budget || budgetRefusal([String(e?.message || "")]);
    if (b && !live.ac.signal.aborted) {
      setBudget({ msg: b.msg, ...(b.until ? { until: b.until } : {}), at: new Date().toISOString() });
      emitAll({ t: "error", code: "budget", msg: b.msg, ...(b.until ? { until: b.until } : {}) });
      log("budget", { person, until: b.until || "" });
    } else {
      emitAll(live.ac.signal.aborted ? { t: "stopped" } : { t: "error", msg: String(e?.message || e).slice(0, 500) });
      log("turn_error", { msg: String(e?.message || e).slice(0, 300) });
    }
  } finally {
    for (const a of [...live.asks.values()]) a.done({ behavior: "deny", message: "turn ended" });
    const ls = live.listeners;
    live = null;
    for (const r of ls) if (!r.writableEnded) r.end();
    log("turn_end", { session: conv.session, used: conv.ctx.used, window: conv.ctx.window });
    carryOut();
    touch();
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

// ---- a trial's conversation leaves with its person (issue #4060) ---------------
// The entry takes the conversation out before a trial's login is washed
// (GET /api/export) and puts it into the clean login the person is handed next
// (POST /api/import): every session's transcript, its cwd and home, so the page
// reads as the one conversation, and the next turn starts a new session seeded
// with the last words (the same relay as a too-long conversation). Only through
// the socket — the entry is the one way in, and it keeps the export sealed to
// the person. The import lands only on a login with no conversation of its own.
const SID_RE = /^[A-Za-z0-9_-]{1,80}$/;
const EXPORT_MAX = Number(E.FLEET_WEBCHAT_EXPORT_MAX || 16 * 1024 * 1024);
async function exportConv() {
  if (live) await new Promise((r) => { const t = setInterval(() => { if (!live) { clearInterval(t); r(); } }, 200); setTimeout(() => { clearInterval(t); r(); }, 5000); });
  if (maint) await maint;
  const out = [];
  let size = 0;
  for (const s of sessions().slice().reverse()) {           // newest first: the oldest go when it is too big
    let jsonl = "";
    try { jsonl = await fsp.readFile(transcriptPath(s.id, s.cwd), "utf8"); } catch {
      try { jsonl = await fsp.readFile(join(CARRY, `${s.id}.jsonl`), "utf8"); } catch { continue; }
    }
    if (size + jsonl.length > EXPORT_MAX) break;
    size += jsonl.length;
    out.unshift({ id: s.id, cwd: s.cwd, jsonl });
  }
  return { v: 1, home: conv.home || E.HOME || "", sessions: out };
}
async function importConv(body) {
  if (body?.v !== 1 || !Array.isArray(body.sessions) || typeof body.home !== "string" || !body.home) return [400, "not a conversation export"];
  if (live || maint) return [409, "busy"];
  if (conv.session || conv.chain.length) return [409, "this login already has a conversation"];
  const ss = body.sessions.filter((s) => s && SID_RE.test(String(s.id)) && typeof s.cwd === "string" && typeof s.jsonl === "string");
  if (!ss.length) return [200, "nothing to import"];
  mkdirSync(CARRY, { recursive: true, mode: 0o700 });
  for (const s of ss) {
    writeFileSync(join(CARRY, `${s.id}.jsonl`), s.jsonl, { mode: 0o600 });
  }
  conv.chain = ss.map((s) => ({ id: s.id, cwd: s.cwd }));
  conv.session = "";
  const n = restoreSessions(body.home, E.HOME || body.home);
  const tail = tailOf((await conversationItems()).filter((it) => it.t === "user" || it.t === "text"));
  conv.seed = tail ? `<fleet-webchat-relay>\n（这是同一段对话的接续：换了一台机器，下面是它最后的部分，请接着它继续，不必提起这次接续。之前生成的文件不在这台机器上。）\n${tail}</fleet-webchat-relay>\n\n` : "";
  conv.ctx = { used: 0, window: conv.ctx.window };
  saveConv();
  log("imported", { sessions: ss.length, restored: n });
  return [200, "imported"];
}

// ---- routes -------------------------------------------------------------------
async function handle(req, res) {
  const port = SOCKET ? 0 : server.address().port;
  if (!SOCKET && !hostAllowed(req.headers.host, port, HOSTS)) return send(res, 421, { error: "unknown host" });
  const u = new URL(req.url, `http://${BIND}:${port || 80}`);
  const p = u.pathname;
  // who it is, for the log only: the relay (C2) verified it before it dialled
  const person = SOCKET ? personName(req.headers["x-fleet-person"]) : "";

  if (SOCKET) {
    // the socket is the gate: 0600 in a 0700 dir — whoever reached it is this login
    if (p === "/healthz") return send(res, 200, { ok: true });
  } else if (p === "/api/link" && req.method === "POST") {
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
  if (!SOCKET && p === "/healthz") return send(res, 200, { ok: true });

  if (!SOCKET && !authed(req)) {
    log("refused", { path: p });
    return p === "/" ? send(res, 403, DENY_PAGE, "text/html; charset=utf-8") : send(res, 403, { error: "forbidden" });
  }
  // a state-changing call must come from the page itself (fetch sets this; a form cannot)
  if (req.method === "POST" && req.headers["x-fleet-webchat"] !== "1") return send(res, 403, { error: "forbidden" });

  if (req.method === "GET" && (p === "/" || p === "/index.html")) {
    const f = uiFile("index.html");
    return f ? sendFile(req, res, f, "no-store") : send(res, 503, { error: "the page is not built (extras/web-chat/ui: npm run build)" });
  }
  if (req.method === "GET" && (p.startsWith("/assets/") || p === "/logo.svg")) {
    const f = uiFile(decodeURIComponent(p.slice(1)));
    if (f) return sendFile(req, res, f, p.startsWith("/assets/") ? "private, max-age=31536000, immutable" : "private, max-age=3600");
    return send(res, 404, { error: "not found" });
  }
  if (p === "/api/conversation" && req.method === "GET") {
    // a page reading the conversation is about to talk: have the credential ready
    if (SDK_PATH && !live) { credFor().catch(() => {}); prewarm(); }
    const items = await conversationItems();
    return send(res, 200, { session: conv.session, cwd: conv.cwd, busy: !!live, turn: live?.tid || "",
      asks: live ? [...live.asks.entries()].map(([rid, a]) => askEvent(rid, a)) : [],
      models: MODELS, default: DEFAULT_MODEL, budget: budgetView(), items: items.slice(-600) });
  }
  if (p === "/api/turn" && req.method === "POST") return turn(req, res, person);
  if (p === "/api/file" && req.method === "GET") {
    const ref = u.searchParams.get("ref") || "";
    return LINK_REF_RE.test(ref) ? sendLinked(req, res, ref) : sendMedia(req, res, ref);
  }
  if (SOCKET && p === "/api/export" && req.method === "GET") { log("export", { person }); return send(res, 200, await exportConv()); }
  if (SOCKET && p === "/api/import" && req.method === "POST") {
    const [code, msg] = await importConv(await readJson(req, EXPORT_MAX + 1024 * 1024));
    return send(res, code, code === 200 ? { ok: true, msg } : { error: msg });
  }
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

// idle: no turn, no compact, no connection open (a page that is watching holds one)
let lastBusy = Date.now();
function touch() { lastBusy = Date.now(); }
const server = http.createServer((req, res) => {
  touch();
  handle(req, res).catch((e) => {
    log("error", { msg: String(e?.message || e).slice(0, 300) });
    if (!res.headersSent) send(res, 500, { error: "internal error" }); else res.end();
  });
});
// A socket left by a server that is gone is replaced; one a live server answers
// on is not — two servers would share one conversation.json.
function sockLive() {
  return new Promise((resolve) => {
    const c = net.connect(SOCK);
    c.on("connect", () => { c.destroy(); resolve(true); });
    c.on("error", () => resolve(false));
  });
}
if (SOCKET) {
  if (existsSync(SOCK)) {
    if (await sockLive()) {
      let holder = "";
      try { holder = ` (pid ${readFileSync(join(STATE, "pid"), "utf8").trim()})`; } catch { /* no pid file */ }
      console.error(`fleet-webchat: another server already answers on ${SOCK}${holder} — not taken over (fleet-webchat.sh serve stops an orphan of this service first)`);
      process.exit(3);
    }
    unlinkSync(SOCK);
  }
  // born 0600: no window in which another login could connect
  const old = process.umask(0o177);
  server.listen(SOCK, () => {
    process.umask(old);
    chmodSync(SOCK, 0o600);
    try { unlinkSync(join(STATE, "port")); } catch { /* none */ }
    writeFileSync(join(STATE, "pid"), `${process.pid}\n`);
    log("listen", { socket: SOCK });
    console.log(`fleet-webchat: listening on ${SOCK}`);
  });
} else {
  server.listen(Number(E.FLEET_WEBCHAT_PORT || 0), BIND, () => {
    const { port } = server.address();
    writeFileSync(join(STATE, "port"), `${port}\n`);
    writeFileSync(join(STATE, "pid"), `${process.pid}\n`);
    log("listen", { bind: BIND, port });
    console.log(`fleet-webchat: listening on http://${BIND}:${port}/`);
  });
}
server.on("connection", (c) => { touch(); c.on("close", touch); });
let stopping = false;
async function shutdown(code, ev) {
  if (stopping) return;
  stopping = true;
  log(ev);
  closeWarm(ev);
  carryOut();
  server.close();
  if (SOCKET) { try { unlinkSync(SOCK); } catch { /* gone */ } }
  // the conversation's credential goes with the service (bounded: a stuck proxy
  // never holds the exit — the proxy drops it with this pid anyway)
  await Promise.race([dropCred(ev), new Promise((r) => setTimeout(r, 5000))]);
  process.exit(code);
}
if (SOCKET && IDLE_SECS > 0) {
  setInterval(() => {
    if (live || maint || Date.now() - lastBusy < IDLE_SECS * 1000) return;
    server.getConnections((err, n) => { if (!err && n === 0 && !live && !maint) shutdown(IDLE_RC, "idle_exit"); });
  }, Math.min(60, Math.max(0.2, IDLE_SECS / 4)) * 1000).unref();
}
for (const sig of ["SIGTERM", "SIGINT"]) process.on(sig, () => shutdown(0, "stop"));
