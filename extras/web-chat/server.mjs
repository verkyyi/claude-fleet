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
  statSync, copyFileSync, readdirSync } from "node:fs";
import { join, dirname, extname, normalize, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createRequire } from "node:module";
import net from "node:net";
import { COOKIE, CODE_TTL_MS, COOKIE_TTL_S, newSecret, sha, sameSecret, parseCookies,
  hostAllowed, redact, agentEnv, parseMint, toolSummary, MODELS, DEFAULT_MODEL, modelAllowed,
  budgetRefusal, personName, PERMISSIONS, cleanBrowser, parseClient, contextLine, contextBlock, contextDetails,
  CTX_RE, imageBlockBytes, imageSize, MEDIA_REF_RE, IMAGE_EXT_MIME, linkTargets, fileDenied, linkedType, WEB_NOTE_V, webNoteBlock, NOTE_RE } from "./lib.mjs";
import { codexSide } from "./codex.mjs";

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
// the login's own codex (task R9A2): the conversation's Codex side; none ⇒ Claude only, as before
const CODEX = E.FLEET_WEBCHAT_CODEX_BIN || "";
const SESSION_CRED = E.FLEET_WEBCHAT_SESSION_CRED || join(HERE, "../../bin/fleet-session-cred.sh");
// a trial person's `space` (活页) bridge to the credential proxy (task XA4R)
const MCP_SPACE = E.FLEET_WEBCHAT_MCP_SPACE || join(HERE, "../../bin/mcp-space.py");
const SDK_PATH = E.FLEET_WEBCHAT_SDK || "";
const ASK_TIMEOUT_MS = Number(E.FLEET_WEBCHAT_ASK_SECS || 1800) * 1000;
const COMPACT_AT = Number(E.FLEET_WEBCHAT_COMPACT_AT || 0.8);  // the context share that triggers a compact
const PROJECTS = join(E.CLAUDE_CONFIG_DIR || join(E.HOME || "", ".claude"), "projects");
// socket mode: exit idle after this long with nothing to do (0 = never); 75 is the
// daemon's word for "done for now" (fleet-node-supervisor.py SVC_IDLE_RC)
const IDLE_SECS = Number(E.FLEET_WEBCHAT_IDLE_SECS ?? 7200);
const IDLE_RC = 75;
const CARRY = join(STATE, "transcripts");
// The terminal and this page taking turns on one conversation (task T810): who
// holds it is bin/fleet-convo-lock.py's record, <dir>/<agent>-<sid>.json (read
// here, written only by that script and bin/fleet-webchat-handoff.sh, which also
// reads whether the terminal is answering). No record = never handed over.
const HANDOFF = E.FLEET_WEBCHAT_HANDOFF || join(HERE, "../../bin/fleet-webchat-handoff.sh");
const LOCK_DIR = E.FLEET_WEBCHAT_LOCKDIR || join(E.FLEET_CONF_DIR || join(E.XDG_CONFIG_HOME || join(E.HOME || "", ".config"), "claude-fleet"), "convo-lock");
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
  if (req._json !== undefined) return req._json;            // read once: a route may look before it hands on
  let n = 0; const parts = [];
  for await (const c of req) { n += c.length; if (n > max) throw new Error("too large"); parts.push(c); }
  req._json = parts.length ? JSON.parse(Buffer.concat(parts).toString("utf8")) : {};
  return req._json;
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
// Claude Code tells the agent about a background task with a user line of its own
// (<task-notification>…, origin.kind task-notification) and answers some of them
// with a synthetic «No response requested.» — neither is the person's or the
// assistant's words (task WD8F): the notice is one quiet line, the filler none.
const TASK_NOTE_RE = /^\s*<task-notification>/;
const noReply = (m) => m.message?.model === "<synthetic>" && blocks(m.message?.content).every((b) => b.type === "text" && /^\s*No response requested\.?\s*$/.test(b.text || ""));
function taskNote(text) {
  const tag = (k) => (text.match(new RegExp(`<${k}>([\\s\\S]*?)</${k}>`)) || [])[1]?.trim() || "";
  const status = tag("status"), summary = tag("summary");
  const say = /previous session ended/i.test(summary) ? "后台命令没跑完：上一轮回复中途被打断了"
    : status === "completed" ? "后台任务跑完了"
    : status === "failed" ? "后台任务失败了"
    : status === "killed" || status === "stopped" ? "后台任务停了"
    : "后台任务有了新进展";
  return { t: "note", kind: "task", text: say };
}
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
  return linesItems(raw.split("\n"), cwd);
}
// one transcript line at a time: what 只读 view (task F481) reads as the file grows
function linesItems(lines, cwd) {
  const out = [];
  for (const line of lines) {
    if (!line) continue;
    let m; try { m = JSON.parse(line); } catch { continue; }
    if ((m.type !== "user" && m.type !== "assistant") || m.isSidechain || m.isMeta || m.isCompactSummary) continue;
    // the person's own pictures ride on their line (the first text of the message)
    let pics = m.type === "user" ? imageItems(m.message?.content).filter((g) => g.ref).map(({ ref, w, h }) => ({ ref, w, h })) : [];
    for (const b of blocks(m.message?.content)) {
      if (m.type === "user" && b.type === "text" && b.text && TASK_NOTE_RE.test(b.text)) { out.push(taskNote(b.text)); continue; }
      if (m.type === "assistant" && noReply(m)) break;
      if (m.type === "user" && b.type === "text" && b.text && !/^\s*<(command|local-command|system-reminder)/.test(b.text)) {
        const text = b.text.replace(SEED_RE, "").replace(CTX_RE, "").replace(NOTE_RE, "");
        if (text || pics.length) out.push({ t: "user", text, ...(pics.length ? { images: pics } : {}) });
        pics = [];
      } else if (m.type === "assistant" && b.type === "text" && b.text) {
        out.push({ t: "text", d: b.text });
        const files = filesOf(b.text, cwd);
        if (files) out.push({ t: "files", files });
      }
      else if (m.type === "assistant" && b.type === "image") out.push(...imageItems([b]));
      else if (m.type === "assistant" && b.type === "tool_use") {
        out.push({ t: "tool", id: b.id, name: b.name, summary: toolSummary(b.name, b.input) });
        if (b.name === SHOW_PAGE) out.push(pageItem(b.id, b.input, cwd));
      }
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

// ---- the terminal ⇄ this page (task T810) --------------------------------------
// the record's holder of one agent's session (the Claude side: conv.session;
// the Codex side, task R9A2: its thread)
function lockHolder(agent = "claude", sid = conv.session) {
  if (!sid) return "";
  try { return JSON.parse(readFileSync(join(LOCK_DIR, `${agent}-${sid}.json`), "utf8")).holder || ""; } catch { return ""; }
}
let ownerSeen = {};                                      // agent → { at, sid, v }
// the terminal holds it: where, and whether it is answering (read live, ≤ 1 s old)
async function ownerNow(agent = "claude", sid = conv.session) {
  if (lockHolder(agent, sid) !== "terminal") return null;
  const seen = ownerSeen[agent];
  if (seen && seen.sid === sid && Date.now() - seen.at < 1000) return seen.v;
  const r = await run(HANDOFF, ["owner", "--agent", agent, "--sid", sid]);
  let o = null;
  try { const j = JSON.parse(r.stdout); if (j.holder === "terminal") o = { where: "terminal", busy: !!j.busy, label: j.label || "", machine: j.machine || "", agent }; } catch { /* none */ }
  ownerSeen[agent] = { at: Date.now(), sid, v: o };
  return o;
}
// a session's transcript wherever Claude Code put it, and the cwd it ran in.
// Every project dir is asked at once (a stat, not a read: 699 dirs took 160–220
// ms read one by one — task YP39); the cwd is the first line that names one,
// looked for in the head before the whole file.
async function findTranscript(id) {
  let dirs = [];
  try { dirs = await fsp.readdir(PROJECTS); } catch { return null; }
  const hits = await Promise.all(dirs.map((d) => fsp.stat(join(PROJECTS, d, `${id}.jsonl`)).then((st) => st.isFile(), () => false)));
  for (let i = 0; i < dirs.length; i++) {
    if (!hits[i]) continue;
    const f = join(PROJECTS, dirs[i], `${id}.jsonl`);
    const cwd = await headCwd(f, (line) => { const m = JSON.parse(line); return typeof m.cwd === "string" ? m.cwd : ""; }, '"cwd"');
    if (cwd) return { file: f, cwd };
  }
  return null;
}
// the first value `pick` finds on a line of the file's head (256 KB), else of the whole
async function headCwd(file, pick, needle = "") {
  const scan = (text) => {
    for (const line of text.split("\n")) {
      if (!line || (needle && !line.includes(needle))) continue;
      try { const v = pick(line); if (v) return v; } catch { /* next */ }
    }
    return "";
  };
  let fh;
  try {
    fh = await fsp.open(file, "r");
    const buf = Buffer.alloc(256 * 1024);
    const { bytesRead } = await fh.read(buf, 0, buf.length, 0);
    const head = buf.subarray(0, bytesRead);
    const nl = head.lastIndexOf(10);
    const v = scan(head.subarray(0, nl >= 0 ? nl : 0).toString("utf8"));
    if (v || bytesRead < buf.length) return v;
  } catch { return ""; } finally { await fh?.close().catch(() => {}); }
  try { return scan(await fsp.readFile(file, "utf8")); } catch { return ""; }
}
// 在 WebChat 里继续: the terminal's session becomes this page's Claude conversation;
// the one it had is put away and kept, the same rule as 新对话
async function adoptConv(body) {
  const agent = String(body?.agent || "claude"), id = String(body?.session || "");
  if (agent === "codex") return codex.available() ? codex.adopt(body) : [409, "WebChat has no Codex here", "no_codex"];
  if (agent !== "claude") return [400, "unknown agent"];
  if (!SID_RE.test(id)) return [400, "not a session id"];
  if (live || maint) return [409, "还在回复上一句", "busy"];
  if (id === conv.session) return [200, "already"];
  const t = await findTranscript(id);
  if (!t) return [404, "no transcript for this session here"];
  if (warmOpening) await warmOpening.catch(() => {});
  closeWarm("adopt");
  // put away and kept — 新对话's own rule (R9A2's newClaude): never lost
  const putAway = [...(conv.put_away || []), ...(conv.session || conv.chain.length
    ? [{ session: conv.session, cwd: conv.cwd, chain: conv.chain, at: new Date().toISOString() }] : [])].slice(-200);
  const label = String(body?.label || "").slice(0, 80);
  conv = { session: id, cwd: t.cwd, chain: [], seed: "", ctx: { used: 0, window: conv.ctx.window }, home: E.HOME || "", ctxKey: "",
    note: "", last: "", put_away: putAway, handed: { from: "terminal", label, at: new Date().toISOString() } };
  saveConv();
  carryOut();
  log("adopted", { label, machine: String(body?.machine || "").slice(0, 60) });
  return [200, "adopted"];
}

// ---- 只读: a terminal session's conversation, read along (task F481) -------------
// The page names a session by its window's @fleet_id (the entry resolved it to
// this login and the person's own); fleet-webchat-handoff.sh view-of says which
// agent and conversation it runs and whether it is answering. Its record — Claude
// Code's transcript, Codex's rollout — is read as it grows and sent as Server-Sent
// Events: {t:"state"} when that changes, {t:"items", from, items} with id = the
// count so far, so a page that comes back asks ?from=<id> and gets nothing twice.
// Nothing here writes to the session; it never takes the conversation.
const FID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const VIEW_POLL_MS = Number(E.FLEET_WEBCHAT_VIEW_POLL_MS || 500);
const VIEW_STATE_MS = Number(E.FLEET_WEBCHAT_VIEW_STATE_MS || 2000);
const VIEW_PING_MS = 15000;
// The first answer (task YP39): the newest items only, read from the record's
// end — the whole record was read and parsed before, 0.1–0.4 s and 136–400 KB
// on a long one. Older ones come a page at a time (?before=).
const VIEW_FIRST = Number(E.FLEET_WEBCHAT_VIEW_FIRST || 200);
const VIEW_TAIL = 512 * 1024;                              // the first read's reach back, ×4 until it holds VIEW_FIRST
const VIEW_TAIL_MAX = 64 * 1024 * 1024;
const VIEW_READ_MAX = 8 * 1024 * 1024;                     // one read of a growing record
// A step's output is the bulk of a record (60–75% of a first answer): read along,
// a step carries its start only, and the rest when it is opened (?tool=<id>).
const VIEW_RESULT_MAX = 160;
const TOOL_ID_RE = /^[A-Za-z0-9_.:-]{1,120}$/;
const VIEW_LOOK_MS = 3000;                                 // a record not found yet, looked for again
const VIEW_KNOWN_MS = 10 * 60 * 1000;                      // a window's last answer, used at once while this fresh
const viewKnown = new Map();                               // fid → { w, at }
const viewFiles = new Map();                               // agent:sid → { file, cwd }
// null: no such window here; undefined: could not tell
async function viewOf(fid) {
  const r = await run(HANDOFF, ["view-of", `fid:${fid}`]);
  if (r.rc === 2) { viewKnown.delete(fid); return null; }
  try {
    const j = JSON.parse(r.stdout);
    if (!j || typeof j !== "object") return undefined;
    viewKnown.set(fid, { w: j, at: Date.now() });
    if (viewKnown.size > 500) viewKnown.delete(viewKnown.keys().next().value);
    return j;
  } catch { return undefined; }
}
async function viewSource(agent, sid) {
  if (!sid || !SID_RE.test(sid)) return null;
  const key = `${agent}:${sid}`, known = viewFiles.get(key);
  if (known) { try { await fsp.stat(known.file); return known; } catch { viewFiles.delete(key); } }
  let src = null;
  if (agent === "codex") {
    const f = codex.viewFile(sid);
    if (f) src = { file: f.file, cwd: await headCwd(f.file, (line) => codex.viewItems([line], "").cwd || "", "cwd") };
  } else src = await findTranscript(sid);
  if (src) { viewFiles.set(key, src); if (viewFiles.size > 500) viewFiles.delete(viewFiles.keys().next().value); }
  return src;
}
// one stretch of the record → the page's items
function viewParse(agent, lines, cwd) {
  const out = agent === "codex" ? codex.viewItems(lines, cwd).items : linesItems(lines, cwd || CWD);
  if (agent !== "codex") saveRefs();
  return out.map((i) => i.t === "tool_result" && typeof i.text === "string" && i.text.length > VIEW_RESULT_MAX
    ? { ...i, text: i.text.slice(0, VIEW_RESULT_MAX) + "…", more: true } : i);
}
async function viewRead(file, start, end) {
  const buf = Buffer.alloc(Math.max(0, end - start));
  if (!buf.length) return buf;
  const fh = await fsp.open(file, "r");
  try { await fh.read(buf, 0, buf.length, start); } finally { await fh.close(); }
  return buf;
}
// The newest VIEW_FIRST items before byte `end`, whole lines only: { items,
// older } — older is where the oldest line read begins (0: the record's start),
// the next ?before=. A Claude transcript is cut line by line to just enough; a
// Codex rollout is read as one stretch (its reader pairs lines).
async function viewTail(agent, src, end) {
  for (let span = VIEW_TAIL; ; span *= 4) {
    let start = Math.max(0, end - span);
    const buf = await viewRead(src.file, start, end);
    let from = 0;
    if (start > 0) {
      const nl = buf.indexOf(10);
      if (nl < 0) { if (span < VIEW_TAIL_MAX) continue; return { items: [], older: 0 }; }
      from = nl + 1;
      start += from;
    }
    const stop = buf.lastIndexOf(10);
    const text = stop >= from ? buf.subarray(from, stop).toString("utf8") : "";
    const whole = start === 0 || span >= VIEW_TAIL_MAX;
    if (agent === "codex") {
      const items = viewParse(agent, text.split("\n"), src.cwd);
      if (items.length >= VIEW_FIRST || whole) return { items, older: start };
      continue;
    }
    // per line, newest first, until there are enough
    const lines = text.split("\n");
    const offs = [];
    let o = start;
    for (const l of lines) { offs.push(o); o += Buffer.byteLength(l) + 1; }
    const parts = [];
    let n = 0, i = lines.length - 1;
    for (; i >= 0 && n < VIEW_FIRST; i--) { const it = viewParse(agent, [lines[i]], src.cwd); parts.push(it); n += it.length; }
    if (n >= VIEW_FIRST || whole) return { items: parts.reverse().flat(), older: i >= 0 ? offs[i + 1] : start };
  }
}
// ?tool=<id>: one step's whole output (as the chat shows it), the record read
// back from its end until the line that carries it
async function viewTool(res, fid, id) {
  const k = viewKnown.get(fid);
  const w = k ? k.w : await viewOf(fid);
  if (w === null) return send(res, 404, { error: "这个会话不在这台机器上了", code: "no_session" });
  if (!w) return send(res, 503, { error: "could not read the session", code: "unreadable" });
  const src = await viewSource(w.agent, w.sid);
  if (!src) return send(res, 404, { error: "no such step", code: "no_step" });
  const find = (items) => items.find((i) => i.t === "tool_result" && i.id === id);
  if (w.agent === "codex") {
    const it = find(codex.viewItems((await fsp.readFile(src.file, "utf8")).split("\n"), src.cwd).items);
    return it ? send(res, 200, { id, text: it.text || "", error: !!it.error }) : send(res, 404, { error: "no such step", code: "no_step" });
  }
  const needle = JSON.stringify(id);
  let end = 0;
  try { end = (await fsp.stat(src.file)).size; } catch { /* gone */ }
  let carry = Buffer.alloc(0);
  while (end > 0) {
    const start = Math.max(0, end - 1024 * 1024);
    const buf = Buffer.concat([await viewRead(src.file, start, end), carry]);
    const nl = start > 0 ? buf.indexOf(10) : -1;
    carry = nl >= 0 ? buf.subarray(0, nl) : Buffer.alloc(0);
    const lines = buf.subarray(nl + 1).toString("utf8").split("\n");
    for (let i = lines.length - 1; i >= 0; i--) {
      if (!lines[i].includes(needle) || !lines[i].includes("tool_result")) continue;
      const it = find(linesItems([lines[i]], src.cwd || CWD));
      if (it) return send(res, 200, { id, text: it.text || "", error: !!it.error });
    }
    end = start;
  }
  return send(res, 404, { error: "no such step", code: "no_step" });
}
// ?before=<byte>: one page further back, as JSON
async function viewOlder(res, fid, before) {
  const k = viewKnown.get(fid);
  const w = k ? k.w : await viewOf(fid);
  if (w === null) return send(res, 404, { error: "这个会话不在这台机器上了", code: "no_session" });
  if (!w) return send(res, 503, { error: "could not read the session", code: "unreadable" });
  const src = await viewSource(w.agent, w.sid);
  if (!src) return send(res, 200, { items: [], older: 0, session: w.sid || "" });
  let size = 0;
  try { size = (await fsp.stat(src.file)).size; } catch { /* gone: nothing older */ }
  const r = await viewTail(w.agent, src, Math.min(before, size));
  return send(res, 200, { ...r, session: w.sid || "" });
}
// 接管 / 交回 (task VV8F, EPIC GR5E C6): the session workspace hands a terminal
// session's conversation to this page and back, by its window — the same roads
// as ⌘P's 在 WebChat 里继续 (to-web) and the end page's ↵ (give-back presses it).
// One handover per window at a time: a second, here or from the terminal, is 409
// taking. Neither side is ever cut off mid-answer: 409 terminal_busy / web_busy.
const handing = new Set();
const sideBusy = (agent) => agent === "codex" ? !!codex.state().busy : !!live || !!maint;
async function handover(req, res, person, how) {
  const fid = String((await readJson(req)).fid || "");
  if (!FID_RE.test(fid)) return send(res, 400, { error: "not a session", code: "bad_target" });
  if (handing.has(fid)) return send(res, 409, { error: "另一处正在接管这个会话", code: "taking" });
  handing.add(fid);
  try {
    const w = await viewOf(fid);
    if (w === null) return send(res, 404, { error: "这个会话不在这台机器上了", code: "no_session" });
    if (!w) return send(res, 503, { error: "could not read the session", code: "unreadable" });
    if (w.agent !== "claude" && w.agent !== "codex") return send(res, 409, { error: "this agent cannot be taken over here", code: "agent" });
    if (w.agent === "codex" && !codex.available()) return send(res, 409, { error: "这台机器上没有 Codex", code: "no_codex" });
    const ok = (extra = {}) => send(res, 200, { ok: true, agent: w.agent, session: w.sid || "", ...extra });
    if (how === "take") {
      if (w.holder === "webchat") return ok({ already: true });
      if (w.busy) return send(res, 409, { error: "正在终端里回答，等它说完", code: "terminal_busy" });
    } else if (w.holder !== "webchat") return ok({ already: true });
    if (sideBusy(w.agent)) return send(res, 409, { error: "网页正在回答，等它说完", code: "web_busy" });
    const r = await run(HANDOFF, how === "take" ? ["to-web", `fid:${fid}`, "--no-open"] : ["give-back", `fid:${fid}`]);
    ownerSeen = {};
    const said = (r.stderr || r.stdout || "").trim().split("\n").pop();
    if (r.rc === 0) { log(how === "take" ? "took over" : "gave back", { agent: w.agent, person }); return ok(); }
    if (r.rc === 3) return send(res, 409, { error: said, code: how === "take" ? (/接管|taking/i.test(said) ? "taking" : "terminal_busy") : "web_busy" });
    return send(res, r.rc === 2 ? 409 : 500, { error: said || "could not hand it over", code: "cannot" });
  } finally { handing.delete(fid); }
}
async function viewStream(req, res, u, person) {
  const fid = u.searchParams.get("fid") || "";
  if (!FID_RE.test(fid)) return send(res, 400, { error: "not a session", code: "bad_target" });
  const num = (k) => { const v = u.searchParams.get(k); if (v == null || v === "") return null; const n = Number(v); return Number.isSafeInteger(n) && n >= 0 ? n : NaN; };
  const before = num("before");
  if (Number.isNaN(before)) return send(res, 400, { error: "before is a byte offset", code: "bad_from" });
  if (before != null) return viewOlder(res, fid, before);
  const tool = u.searchParams.get("tool");
  if (tool != null) return TOOL_ID_RE.test(tool) ? viewTool(res, fid, tool) : send(res, 400, { error: "not a step", code: "bad_target" });
  // ?at=<byte> (and the conversation it was in): a page back from a drop carries on there
  let at = num("at");
  if (Number.isNaN(at)) return send(res, 400, { error: "at is a byte offset", code: "bad_from" });
  const atSid = u.searchParams.get("s") || "";
  // the window's last answer, when there is a fresh one: the first frame does not
  // wait the second it takes to ask again (task YP39) — asked again at once below
  const k = viewKnown.get(fid);
  const knew = !!k && Date.now() - k.at < VIEW_KNOWN_MS;
  let w = knew ? k.w : await viewOf(fid);
  if (w === null) return send(res, 404, { error: "这个会话不在这台机器上了", code: "no_session" });
  if (!w) return send(res, 503, { error: "could not read the session", code: "unreadable" });
  if (w.agent !== "claude" && w.agent !== "codex") return send(res, 409, { error: "this agent's conversation cannot be read here", code: "agent" });
  res.writeHead(200, { "Content-Type": "text/event-stream; charset=utf-8", "Cache-Control": "no-store", "X-Accel-Buffering": "no" });
  let closed = false;
  res.on("close", () => { closed = true; });
  const ev = (o, id) => { if (!closed) { touch(); res.write(`${id != null ? `id: ${id}\n` : ""}data: ${JSON.stringify(o)}\n\n`); } };
  // the gate's word on it (task HHV0): may the page talk, and what still waits
  let gs = gateKnown.get(fid)?.j || null;
  const stateOf = () => JSON.stringify({ t: "state", agent: w.agent, session: w.sid || "", busy: !!w.busy, state: w.state || "",
    label: w.label || "", can_talk: gs ? !!gs.can_talk : false, queue: (gs?.queue || []).map(({ delivery, text, why }) => ({ delivery, text, why })),
    ...(gs?.ask ? { ask: gs.ask } : {}) });
  let said = stateOf();
  res.write(`data: ${said}\n\n`);
  log("view", { agent: w.agent, person, known: knew });
  if (at != null && atSid !== (w.sid || "")) at = null;      // another conversation now: from its end
  let src = null, off = 0, first = true, lookedAt = 0, nothingYet = false;
  let asking = null, askedAt = knew ? 0 : Date.now(), pinged = Date.now(), next = null;
  let gasking = null, gaskedAt = 0;
  const restart = () => { src = null; off = 0; at = null; first = true; lookedAt = 0; nothingYet = false; ev({ t: "reset" }); };
  while (!closed) {
    // another conversation in that window now (a /clear, a resume): from its end
    if (next) {
      const x = next; next = null;
      if ((x.sid || "") !== (w.sid || "") || x.agent !== w.agent) restart();
      w = x;
      const now = stateOf();
      if (now !== said) { said = now; ev(JSON.parse(now)); }
    }
    // the record, once it is there (a session that has said nothing has none):
    // looked for again every few seconds, never on every poll
    if (!src && w.sid && Date.now() - lookedAt >= VIEW_LOOK_MS) { lookedAt = Date.now(); src = await viewSource(w.agent, w.sid); }
    if (nothingYet && src) { nothingYet = false; first = true; at = null; }    // there now: its newest stretch
    let size = -1;
    if (src) { try { size = (await fsp.stat(src.file)).size; } catch { src = null; } }
    let more = false;
    if (src && size >= 0) {
      if (first && (at == null || at > size)) {
        // the newest stretch, whole lines: the page draws it in place of what it had
        off = await viewLastLine(src.file, size);
        const r = await viewTail(w.agent, src, off);
        ev({ t: "items", replace: true, items: r.items, at: off, older: r.older, session: w.sid || "" }, off);
        first = false;
      } else {
        if (first) { off = at; first = false; }
        if (size < off) { restart(); continue; }            // rewritten
        const add = [];
        if (size > off) {
          const len = Math.min(size - off, VIEW_READ_MAX);
          const buf = await viewRead(src.file, off, off + len);
          const end = buf.lastIndexOf(10);
          if (end >= 0) {
            off += end + 1;
            more = off < size && len === VIEW_READ_MAX;
            add.push(...viewParse(w.agent, buf.subarray(0, end).toString("utf8").split("\n"), src.cwd));
          }
        }
        // the first frame of a page come back says so even with nothing new
        if (add.length || at != null) { ev({ t: "items", items: add, at: off, session: w.sid || "" }, off); at = null; }
      }
    } else if (first) {
      // nothing to read yet: the page says so instead of waiting
      ev({ t: "items", replace: true, items: [], at: 0, older: 0, session: w.sid || "" }, 0);
      first = false; nothingYet = true;
    }
    // the window's state, asked in the background (the script takes ~1 s)
    // the gate's word, asked on its own clock: a slow one never holds the record's state back
    if (!gasking && Date.now() - gaskedAt >= GATE_STATE_MS) {
      gasking = gateStatus(fid).catch(() => null).then((g) => {
        gasking = null; gaskedAt = Date.now();
        if (closed || !g) return;
        gs = g;
        const now = stateOf();
        if (now !== said) { said = now; ev(JSON.parse(now)); }
      });
    }
    if (!asking && Date.now() - askedAt >= VIEW_STATE_MS) {
      asking = viewOf(fid).then((x) => { asking = null; askedAt = Date.now(); return x; });
      asking.then((x) => {
        if (closed) return;
        if (x === null) { ev({ t: "gone" }); closed = true; res.end(); return; }
        if (x) next = x;
      });
    }
    if (Date.now() - pinged >= VIEW_PING_MS) { pinged = Date.now(); if (!closed) res.write(": ping\n\n"); }
    if (!more) await new Promise((r) => setTimeout(r, VIEW_POLL_MS));
  }
  if (!res.writableEnded) res.end();
}
// where the last whole line before `end` ends (a line still being written stays unread)
async function viewLastLine(file, end) {
  for (let span = 64 * 1024; ; span *= 4) {
    const start = Math.max(0, end - span);
    const buf = await viewRead(file, start, end);
    const nl = buf.lastIndexOf(10);
    if (nl >= 0) return start + nl + 1;
    if (start === 0) return 0;
  }
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
const aside = new Set();  // turns 新对话 put aside mid-answer, answering on (task WD8F)
let maint = null;         // a compact / relay between turns (the next turn waits for it)
// a turn left open in the file is one the service did not see end — it was
// stopped mid-answer (a takeover, a restart, task WD8F): said once on the page
if (conv.open) { conv.interrupted = { ...conv.open }; delete conv.open; saveConv(); }
let ridSeq = 0;

// the context's size, off every message of a query — on the conversation the
// query belongs to (a turn left running by 新对话 keeps its own, task WD8F)
function account(m, c = conv) {
  if (m.type === "assistant" && m.message?.usage) {
    const u = m.message.usage;
    c.ctx.used = (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0);
  }
  if (m.type === "result") {
    for (const mu of Object.values(m.modelUsage || {})) if (mu?.contextWindow) c.ctx.window = mu.contextWindow;
  }
  if (m.type === "system" && m.subtype === "compact_boundary") {
    c.ctx.used = m.compact_metadata?.post_tokens || 0;
    log("compacted", { trigger: m.compact_metadata?.trigger, pre: m.compact_metadata?.pre_tokens });
  }
}

// One query() through the conversation's session credential; onMsg sees every SDK message.
// A prompt that is content blocks (pictures with the words, task T773 ③) goes in as
// the one user message of an input stream — query() takes a string or a stream.
async function runQuery(prompt, { model, resume, cwd, ac, canUseTool, mcpServers, c = conv }, onMsg) {
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
      ...(mcpServers ? { mcpServers: { ...await spaceServers(cred, "CLAUDE_CODE_OAUTH_TOKEN"), ...mcpServers } } : {}),
      abortController: ac, ...(CLAUDE ? { pathToClaudeCodeExecutable: CLAUDE } : {}),
      stderr: () => {},                    // the child's stderr is never relayed or logged
    } });
    for await (const m of q) {
      if (m.session_id && !resume && !c.session) { c.session = m.session_id; c.cwd = cwd; saveConv(); }
      account(m, c);
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
function closeWarm(why, w = warm) {
  if (warm === w) warm = null;
  if (!w || w.closed) return;
  w.closed = true;
  clearTimeout(w.idle);
  log("warm_close", { why });
  w.input.end();
  w.ac.abort();
}
async function openWarm({ model, cwd, resume, c = conv }) {
  const S = await sdk();
  const cred = await credFor();
  const w = { input: inputStream(), ac: new AbortController(), cwd, resume: resume || "", session: resume || "", model,
    cur: null, details: null, canUse: null, idle: null, closed: false, conv: c };
  w.q = S.query({ prompt: w.input, options: {
    cwd, resume: resume || undefined, model, env: agentEnv(E, cred.mint), includePartialMessages: true,
    ...PERMISSIONS, settingSources: [...PERMISSIONS.settingSources],
    canUseTool: (n, i, o) => (w.canUse ? w.canUse(n, i, o) : Promise.resolve({ behavior: "deny", message: "no turn is running" })),
    mcpServers: { ...await spaceServers(cred, "CLAUDE_CODE_OAUTH_TOKEN"), ...browserTools(S, () => w.details), ...await pageTools(S) },
    abortController: w.ac, ...(CLAUDE ? { pathToClaudeCodeExecutable: CLAUDE } : {}),
    stderr: () => {},
  } });
  log("warm_open", { cred_sid: cred.sid, route: cred.route, model, resume: !!resume });
  (async () => {
    try {
      for await (const m of w.q) {
        if (m.session_id && !w.session) {
          w.session = m.session_id;
          if (!w.conv.session) { w.conv.session = m.session_id; w.conv.cwd = cwd; saveConv(); }
        }
        account(m, w.conv);
        const c = w.cur;
        if (!c) continue;
        try { c.onMsg(m); } catch (e) { w.cur = null; c.reject(e); closeWarm("turn error", w); return; }
        if (m.type === "result") {
          w.cur = null; c.resolve();
          // a turn 新对话 left running (task WD8F) has no next turn here: it goes with its answer
          if (warm !== w) { closeWarm("left running, done", w); return; }
          w.idle = setTimeout(() => { if (warm === w && !w.cur) closeWarm("idle"); }, WARM_IDLE_MS);
        }
      }
      throw new Error("the agent ended");
    } catch (e) {
      const c = w.cur;
      w.cur = null;
      c?.reject(e);
    } finally {
      closeWarm("ended", w);
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
async function warmQuery(prompt, { model, resume, cwd, ac, canUseTool, details, c = conv }, onMsg) {
  lastModel = model;
  if (!WARM_IDLE_MS) return runQuery(prompt, { model, resume, cwd, ac, canUseTool, mcpServers: await chatTools(await sdk(), details), c }, onMsg);
  if (warmOpening) await warmOpening;
  let w = warm;
  if (w && (w.closed || w.cur || w.cwd !== cwd || w.session !== (resume || ""))) { closeWarm("other session"); w = null; }
  if (w && w.model !== model) {
    if (typeof w.q.setModel === "function") {
      try { await w.q.setModel(model); w.model = model; } catch { closeWarm("model"); w = null; }
    } else { closeWarm("model"); w = null; }
  }
  try {
    if (!w) {
      w = await openWarm({ model, cwd, resume, c });
      if (c === conv) warm = w;                          // put aside while it opened: it is that turn's alone
    }
  } catch (e) {
    if (!e?.budget) await dropCred("agent failed to start");
    throw e;
  }
  clearTimeout(w.idle);
  w.details = details || null;
  w.canUse = canUseTool;
  const stop = () => closeWarm("stopped", w);
  ac.signal.addEventListener("abort", stop, { once: true });
  // the stop key pressed while the agent was still opening: its abort came before this listener
  if (ac.signal.aborted) { ac.signal.removeEventListener("abort", stop); stop(); throw new Error("aborted"); }
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
// ---- the agent's web pages (task T773 ④) ---------------------------------------------------
// A page the agent makes goes to the person's own 活页 (LivePage) workspace — the
// login's `space` MCP server, its credential Claude Code's own, never in this
// process or a transcript — private, in one folder 「WebChat 产物」. The agent then
// calls show_page and the conversation shows a card: the title, its state, 「打开」
// in a new window (活页 refuses to be framed until it allows the entry: a later
// change). <state>/pages.json remembers the folder and each file's page, so a
// change is a new version at the same link. A preview is a picture file the agent
// names, kept as an image (media/), shown on the card.
const PAGES_FILE = join(STATE, "pages.json");
const PAGE_FOLDER = "WebChat 产物";
let pages = { folder_id: "", files: {} };                // files: local path → proposal_id
try { pages = { folder_id: "", files: {}, ...JSON.parse(readFileSync(PAGES_FILE, "utf8")) }; } catch { /* none yet */ }
function savePages() {
  try { writeFileSync(PAGES_FILE + ".tmp", JSON.stringify(pages), { mode: 0o600 }); renameSync(PAGES_FILE + ".tmp", PAGES_FILE); }
  catch (e) { log("pages_failed", { msg: String(e?.message || e).slice(0, 200) }); }
}
const PAGE_STATES = new Set(["publishing", "review", "ready", "failed", "unavailable", "account"]);
// the page's origin, as the last turn said it: an embed link is minted for it
const ORIGIN_RE = /^https:\/\/[a-z0-9-]+(?:\.[a-z0-9-]+)+(?::\d{1,5})?$/;
let pageOrigin = "";
// the card a show_page call makes, from its input — the same off a transcript and live
function pageItem(id, i, cwd) {
  const o = i || {};
  const url = /^https:\/\/[^\s"<>]+$/.test(String(o.url || "")) ? String(o.url) : "";
  const status = PAGE_STATES.has(o.status) ? o.status : url ? "ready" : "unavailable";
  const it = { t: "page", id, title: String(o.title || "网页").slice(0, 120), status, ...(url ? { url } : {}),
    ...(o.proposal_id ? { proposal: String(o.proposal_id).slice(0, 64) } : {}),
    ...(Number(o.version) > 0 ? { version: Math.floor(Number(o.version)) } : {}),
    ...(o.note ? { note: String(o.note).slice(0, 200) } : {}),
    // task XA4R: 活页 was opened for them by this publish (said once), and the page went to their WeChat
    ...(o.account_new === true ? { fresh: true } : {}), ...(o.pushed === true ? { pushed: true } : {}) };
  // an embed link (活页 preview_version with embed_origin): the card previews it in place until it expires
  const exp = Date.parse(String(o.embed_expires || ""));
  if (/^https:\/\/[^\s"<>]+$/.test(String(o.embed_url || "")) && exp > 0) { it.embed = String(o.embed_url); it.embed_exp = new Date(exp).toISOString(); }
  if (o.preview) {
    const real = linkable(String(o.preview), cwd);
    const ext = real ? real.toLowerCase().split(".").pop().replace("jpeg", "jpg") : "";
    if (real && IMAGE_EXT_MIME[ext]) {
      try {
        const k = keepImage({ type: "image", source: { type: "base64", media_type: IMAGE_EXT_MIME[ext], data: readFileSync(real).toString("base64") } });
        if (k?.ref) it.preview = k.ref;
      } catch { /* no preview */ }
    }
  }
  return it;
}
const SHOW_PAGE = "mcp__fleet_chat__show_page";
// page_target's answer and show_page's bookkeeping — both sides' (the Codex side calls them as its own tools)
function pageTarget(file) {
  const real = (() => { try { return realpathSync(String(file || "")); } catch { return String(file || ""); } })();
  return { folder: PAGE_FOLDER, folder_id: pages.folder_id || null, proposal_id: pages.files[real] || null,
    visibility: spaceTrial ? "private until the person says otherwise" : "private (never change it)",
    embed_origin: pageOrigin || null, ...(spaceTrial ? { trial: TRIAL_PAGE_RULES } : {}) };
}
// ---- a trial person's 活页, through the proxy (task XA4R) ----------------------
// A trial's login has no `space` of its own: its 活页 account is opened by the hub
// the first time a page is published, and the key never comes here — the
// session's `space` is bin/mcp-space.py, talking to the credential proxy with the
// session's own credential. Attached only when the proxy says this login's person
// may (GET /space/status: a trial, the hub's switch on); anyone else keeps
// whatever `space` their login has, byte for byte.
let spaceTrial = false;
const TRIAL_PAGE_RULES = "This person is on a trial: their 活页 account is opened for them by the first publish (a tool result says so " +
  "once: then pass account_new: true to show_page). Once a page is ready: call space push_to_wechat(proposal_id, to: self) and " +
  "show_page with pushed: true — they open it in WeChat, only they can. Never make a page visible to others unless they ask: then " +
  "ask first — 「要让别人也能打开吗？① 凭口令打开（推荐） ② 先不分享」 — and only on ① call set_visibility passcode and give them the " +
  "passcode. A trial page is never public. If the account is not ready yet, show_page status account (the file stays here; " +
  "publish again when they say retry).";
// the same bridge for the Codex side: one -c table, its credential passed by NAME (env_vars)
async function spaceCodexArgs(mint) {
  const sv = (await spaceServers({ mint }, "FLEET_CODEX_SESSION_CRED")).space;
  if (!sv) return [];
  const q = (v) => JSON.stringify(String(v));
  return ["-c", `mcp_servers.space={command=${q(sv.command)},args=[${sv.args.map(q).join(",")}],env_vars=["FLEET_CODEX_SESSION_CRED"]}`];
}
async function spaceServers(cred, credEnv) {
  spaceTrial = false;
  if (!cred?.mint?.port || !cred.mint.cred) return {};
  const base = `http://127.0.0.1:${cred.mint.port}`;
  try {
    const r = await fetch(base + "/space/status", { headers: { authorization: `Bearer ${cred.mint.cred}` }, signal: AbortSignal.timeout(8000) });
    const a = r.ok ? await r.json() : null;
    if (!a?.eligible) return {};
  } catch { return {}; }
  spaceTrial = true;
  return { space: { type: "stdio", command: "python3", args: ["-I", MCP_SPACE, "--base", base, "--cred-env", credEnv] } };
}
function pageShown(a) {
  if (a?.folder_id && !pages.folder_id) pages.folder_id = String(a.folder_id).slice(0, 64);
  if (a?.file && a?.proposal_id) { try { pages.files[realpathSync(String(a.file))] = String(a.proposal_id).slice(0, 64); } catch { /* gone */ } }
  savePages();
}
let zodP = null;
// zod, the SDK's own (its tool() takes a zod shape); null where it is not beside it
function zod() {
  if (!zodP) zodP = (async () => {
    try { return (await import(pathToFileURL(createRequire(SDK_PATH).resolve("zod")).href)).z; } catch { return null; }
  })();
  return zodP;
}
async function pageTools(S) {
  if (typeof S.createSdkMcpServer !== "function" || typeof S.tool !== "function") return {};
  const z = await zod();
  const shape = (f) => (z ? f(z) : {});
  const info = S.tool("page_target",
    "Before publishing a web page you made for the person (an HTML file), ask where it goes. Answers the 活页 (LivePage) " +
    `folder for this conversation's pages (「${PAGE_FOLDER}」, its folder_id once made) and, for this file, the proposal_id it was ` +
    "published as before. The rules: publish with the `space` tools (publish_file; files over 2 MB through its CLI). FIRST " +
    `time: create_folder 「${PAGE_FOLDER}」 and pass its folder_id to show_page. A file published before: publish to the SAME ` +
    "proposal_id (a new version, the same link). Never change a page's visibility — it stays private, only the person sees it " +
    "(unless the answer carries `trial`: then follow those rules). " +
    "If the publish is held for review, call show_page with status review, poll get_version, then show_page again with ready. " +
    "No `space` tools here: tell the person this machine is not connected to 活页 and call show_page with status unavailable. " +
    "Once it is ready and embed_origin is answered: call space preview_version(version_id, embed_origin) and pass its " +
    "embed.url and embed.expires_at to show_page as embed_url / embed_expires — the card previews the page in place.",
    shape((z) => ({ file: z.string().describe("absolute path of the HTML file") })),
    async (a) => ({ content: [{ type: "text", text: JSON.stringify(pageTarget(a?.file)) }] }));
  const show = S.tool("show_page",
    "Show the person a card for a web page you published to their 活页: they tap it to open the page. Call it after " +
    "publish_file (status ready, or review while it waits), with the page's link (its default_url / url), the proposal_id and " +
    "version, the HTML file it came from, and the folder_id when you just made the folder. A picture of the page (a screenshot " +
    "file) may go in preview. Status account: the person's 活页 account is not open yet (the file stays here).",
    shape((z) => ({
      title: z.string(), url: z.string().optional(), status: z.enum(["publishing", "review", "ready", "failed", "unavailable", "account"]),
      proposal_id: z.string().optional(), version: z.number().optional(), file: z.string().optional(),
      folder_id: z.string().optional(), preview: z.string().optional(), note: z.string().optional(),
      embed_url: z.string().optional(), embed_expires: z.string().optional(),
      account_new: z.boolean().optional(), pushed: z.boolean().optional(),
    })),
    async (a) => { pageShown(a); return { content: [{ type: "text", text: "shown to the person as a card" }] }; });
  return { fleet_chat: S.createSdkMcpServer({ name: "fleet_chat", version: "1.0.0", tools: [info, show] }) };
}
async function chatTools(S, details) {
  return { ...(details ? browserTools(S, details) || {} : {}), ...await pageTools(S) };
}
const TOO_LONG = /prompt is too long|context (?:window|length)|too many tokens/i;

// ---- a turn: NDJSON lines to every page that is watching ----------------------
function emitAll(o, t = live) {
  if (!t) return;
  const line = redact(JSON.stringify(o), [...liveCreds, ADMIN]) + "\n";
  for (const res of t.listeners) if (!res.writableEnded) res.write(line);
}
function askEvent(rid, a) {
  const id = a.toolUseID ? { id: a.toolUseID } : {};      // the tool step it gates (the page hangs it there)
  return a.name === "AskUserQuestion"
    ? { t: "ask", rid, ...id, kind: "question", questions: a.input.questions || [] }
    : { t: "ask", rid, ...id, kind: "permission", tool: a.name, summary: toolSummary(a.name, a.input) };
}

// a turn's request: its words, the person's pictures (task T773 ③: a few, of a
// type the page shows, each a real image) — or the refusal already sent
async function turnBody(req, res) {
  let body;
  try { body = await readJson(req, TURN_MAX); } catch { send(res, 413, { error: "图太大：一条消息连图带字最多 1 MB" }); return null; }
  const text = String(body.text || "").trim();
  const pics = Array.isArray(body.images) ? body.images : [];
  if (pics.length > PICS_PER_TURN) { send(res, 400, { error: `一条消息最多 ${PICS_PER_TURN} 张图` }); return null; }
  const images = [];
  for (const g of pics) {
    const b = { type: "image", source: { type: "base64", media_type: String(g?.media_type || ""), data: String(g?.data || "") } };
    const img = imageBlockBytes(b);
    if (!img || !imageSize(img.buf, img.ext).w) { send(res, 400, { error: "不是能看的图片（png / jpeg / gif / webp）" }); return null; }
    images.push(b);
  }
  if (!text && !images.length) { send(res, 400, { error: "empty" }); return null; }
  // the page's own origin: the one a 活页 embed link is minted for (task T773 ④)
  if (typeof body.origin === "string" && ORIGIN_RE.test(body.origin)) pageOrigin = body.origin;
  return { body, text, images };
}

async function turn(req, res, person) {
  const tb = await turnBody(req, res);
  if (!tb) return;
  const { body, text, images } = tb;
  const model = body.model == null || body.model === "" ? DEFAULT_MODEL : String(body.model);
  if (!modelAllowed(model)) { log("model_refused", { model: model.slice(0, 64) }); return send(res, 400, { error: "model not allowed" }); }
  if (live) return send(res, 409, { error: "还在回复上一句" });
  if (lockHolder() === "terminal") return send(res, 409, { error: "这段对话在终端里", code: "terminal" });
  const S = await sdk().catch((e) => e);
  if (S instanceof Error) return send(res, 503, { error: S.message });
  // where the person is talking from (issue #4034): the page's own report + the
  // address and city the entry saw (socket mode: the relay is the only way in)
  const browser = cleanBrowser(body.client);
  const place = SOCKET ? parseClient(req.headers["x-fleet-client"]) : {};
  const where = contextLine(browser, place);
  const details = browser || place.ip ? contextDetails(browser, place) : null;

  const tid = newSecret(9);
  // t / c: this turn and its conversation — 新对话 may put both aside while the
  // turn runs (task WD8F): it then answers on into the conversation put away
  const t = live = { tid, ac: new AbortController(), listeners: new Set([res]), asks: new Map(), model };
  const c = conv;
  const emit = (o) => emitAll(o, t);
  // a turn the service did not see end (stopped mid-answer: a takeover, a
  // restart) is said on the next start, with its words for 重试 (task WD8F)
  delete c.interrupted;
  c.open = { tid, text: text.slice(0, 4000), pics: images.length, at: new Date().toISOString() };
  saveConv();
  res.writeHead(200, { "Content-Type": "application/x-ndjson; charset=utf-8", "Cache-Control": "no-store",
    "X-Accel-Buffering": "no", "X-Content-Type-Options": "nosniff" });
  // a page that goes away (a phone in a pocket) does not stop the turn — only the stop key does
  res.on("close", () => t.listeners.delete(res));
  emit({ t: "turn", id: tid, model });
  log("turn", { person, model });

  // In bypass (lib.mjs PERMISSIONS) this is reached for AskUserQuestion — the
  // card the person picks from; any other tool runs without asking.
  const canUseTool = (name, input, opts = {}) => new Promise((resolve) => {
    const rid = `r${++ridSeq}-${newSecret(6)}`;
    // nobody is left to answer a turn put aside by 新对话
    if (t.aside) return resolve({ behavior: "deny", message: "the person started a new conversation" });
    const done = (v) => { clearTimeout(timer); t.asks.delete(rid); resolve(v); };
    const timer = setTimeout(() => done({ behavior: "deny", message: "no answer from the web page in time" }), ASK_TIMEOUT_MS);
    t.asks.set(rid, { name, input, done, toolUseID: typeof opts.toolUseID === "string" ? opts.toolUseID : "" });
    opts.signal?.addEventListener?.("abort", () => done({ behavior: "deny", message: "aborted" }));
    emit(askEvent(rid, t.asks.get(rid)));
  });

  let sawDelta = false;
  let shown = 0;                                          // this turn's images, IMAGES_PER_REPLY at most
  const emitImages = (list, extra) => {
    for (const it of imageItems(list, extra)) emit(++shown > IMAGES_PER_REPLY ? { t: "image_more", n: 1 } : it);
  };
  const onMsg = (m) => {
    if (m.type === "system" && m.subtype === "init") return emit({ t: "session", id: m.session_id, cwd: c.cwd });
    if (m.type === "stream_event") {
      const ev = m.event || {};
      if (ev.type === "content_block_delta" && ev.delta?.type === "text_delta") { sawDelta = true; emit({ t: "text", d: ev.delta.text }); }
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
      // Claude Code's own filler for a background task's notice is no reply (task WD8F)
      if (noReply(m)) return;
      for (const b of blocks(m.message?.content)) {
        if (b.type === "text" && b.text && !sawDelta) emit({ t: "text", d: b.text });
        if (b.type === "tool_use") {
          emit({ t: "tool", id: b.id, name: b.name, summary: toolSummary(b.name, b.input) });
          if (b.name === SHOW_PAGE) emit(pageItem(b.id, b.input, c.cwd || CWD));
        }
        if (b.type === "image") emitImages([b]);
        if (b.type === "text" && b.text) {
          const files = filesOf(b.text, c.cwd || CWD);
          if (files) { emit({ t: "files", files }); saveRefs(); }
        }
      }
      sawDelta = false;
      return;
    }
    if (m.type === "user") {
      for (const b of blocks(m.message?.content)) {
        if (b.type === "tool_result") {
          emit({ t: "tool_result", id: b.tool_use_id, text: resultText(b.content), error: !!b.is_error });
          emitImages(b.content, { id: b.tool_use_id });
        }
      }
      return;
    }
    if (m.type === "result") {
      if (m.subtype !== "success" && TOO_LONG.test(JSON.stringify(m.errors || m.result || ""))) throw Object.assign(new Error("too long"), { tooLong: true });
      if (m.subtype === "success" && !m.is_error && budget) setBudget(null);
      emit({ t: "done", subtype: m.subtype, ms: m.duration_ms });
    }
  };

  try {
    if (maint) await maint;
    for (let attempt = 0; ; attempt++) {
      const seed = c.session ? "" : c.seed;
      // the one-line context goes in on a session's first turn and again only when it changed
      const head = where && (!c.session || c.ctxKey !== where.key) ? contextBlock(where.line) : "";
      try {
        // how a web page's person sees things (task T773): once in each session
        const note = c.note !== WEB_NOTE_V || !c.session ? webNoteBlock() : "";
        const words = seed + head + note + text;
        await warmQuery(images.length ? [...images, ...(words ? [{ type: "text", text: words }] : [])] : words, { model, resume: c.session, cwd: c.session ? c.cwd : CWD, ac: t.ac,
          canUseTool, details, c }, onMsg);
        if (seed) c.seed = "";
        if (head) c.ctxKey = where.key;
        if (note) c.note = WEB_NOTE_V;
        const handed = !!c.handed;                        // said once: the first turn here ends it
        if (handed) delete c.handed;
        if (seed || head || note || handed) saveConv();
        break;
      } catch (e) {
        if (attempt === 0 && !t.ac.signal.aborted && !t.aside && (e.tooLong || TOO_LONG.test(String(e?.message || e)))) {
          await maintain("too long");
          continue;
        }
        throw e;
      }
    }
  } catch (e) {
    const b = e?.budget || budgetRefusal([String(e?.message || "")]);
    if (b && !t.ac.signal.aborted) {
      setBudget({ msg: b.msg, ...(b.until ? { until: b.until } : {}), at: new Date().toISOString() });
      emit({ t: "error", code: "budget", msg: b.msg, ...(b.until ? { until: b.until } : {}) });
      log("budget", { person, until: b.until || "" });
    } else {
      emit(t.ac.signal.aborted ? { t: "stopped" } : { t: "error", msg: String(e?.message || e).slice(0, 500) });
      log("turn_error", { msg: String(e?.message || e).slice(0, 300) });
    }
  } finally {
    for (const a of [...t.asks.values()]) a.done({ behavior: "deny", message: "turn ended" });
    if (live === t) live = null;
    aside.delete(t);
    for (const r of t.listeners) if (!r.writableEnded) r.end();
    if (!stopping) delete c.open;                        // the service going: the next start says so
    if (t.aside) {
      // put away mid-answer: its entry in put_away learns the session it ended in
      if (t.aside.entry) Object.assign(t.aside.entry, { session: c.session, cwd: c.cwd, chain: c.chain });
      saveConv();
      log("turn_end", { session: c.session, aside: true });
    } else {
      c.last = tid;                                      // the page's 「new reply」 mark (task R9A2)
      saveConv();
      log("turn_end", { session: c.session, used: c.ctx.used, window: c.ctx.window });
      carryOut();
      if (c === conv && c.session && c.ctx.window && c.ctx.used >= COMPACT_AT * c.ctx.window) maintain("near full");
    }
    touch();
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
// ---- the Codex side (task R9A2): its own conversation on the same home ------------
const codex = codexSide({ E, STATE, CWD, CODEX, SESSION_CRED, MEDIA, IMAGE_EXT_MIME, IMAGES_PER_REPLY, ASK_TIMEOUT_MS, WARM_IDLE_MS,
  run, log, parseMint, liveCreds, newSecret, send, touch,
  redactLine: (o) => redact(JSON.stringify(o), [...liveCreds, ADMIN]),
  keepImage, imageItems, capImages, filesOf, saveRefs, pageItem, pageTarget, pageShown, spaceCodexArgs,
  budgetRefusal, setBudget, budgetView, budget: () => budget,
  holder: (sid) => lockHolder("codex", sid), owner: (sid) => ownerNow("codex", sid) });
const PROVIDERS_RE = /^(claude|codex)$/;
// what a side's page shows of the other one: running now · its last finished turn
const sides = () => ({ providers: codex.available() ? ["claude", "codex"] : ["claude"],
  claude: { busy: !!live, last: conv.last || "" }, codex: codex.side() });
async function codexTurn(req, res, person) {
  const tb = await turnBody(req, res);
  if (!tb) return;
  const model = tb.body.model == null ? "" : String(tb.body.model).slice(0, 80);
  return codex.turn(res, { text: tb.text, model, images: tb.images, person });
}
// 新对话 on the Claude side: the session (and its chain) put away, kept; the next
// turn starts a new one. The Codex side is not touched. A turn still answering
// is put aside, not stopped (task WD8F): it answers on into the conversation put
// away (its own warm agent, closed after its answer) and the new one is free at once.
function newClaude() {
  if (maint) return false;
  const old = conv, t = live;
  const entry = old.session || old.chain.length || t ? { session: old.session, cwd: old.cwd, chain: old.chain, at: new Date().toISOString() } : null;
  conv = { ...old, session: "", chain: [], seed: "", ctx: { used: 0, window: 0 }, ctxKey: "", note: "", last: "",
    put_away: entry ? [...(old.put_away || []), entry].slice(-200) : old.put_away || [] };
  delete conv.open;
  delete conv.interrupted;
  if (t) {
    t.aside = { entry };
    aside.add(t);
    live = null;
    for (const a of [...t.asks.values()]) a.done({ behavior: "deny", message: "the person started a new conversation" });
    if (warm) warm = null;                               // its agent goes on carrying that turn, then closes
    log("turn_aside", { session: old.session });
  } else closeWarm("new conversation");
  saveConv();
  log("new_conversation", { provider: "claude", aside: !!t });
  return true;
}

// ---- the session gate (task HHV0, 会话合一 ①) ---------------------------------
// The page talks to SESSIONS — a window on this login, by its fleet_id — the way
// a terminal does: one sentence is the session's next turn. This service only
// keeps the door: bin/fleet_session_gate.py holds the words on disk (each its own
// delivery id, never sent twice), hands them to the session (the mod's idle.v2
// accept for Claude, its own queue for Codex), queues what cannot go in yet and
// retries; a parked session is woken with the sentence as its first turn. A turn
// runs in its window, not here: restarting this service cuts nothing (WD8F ①),
// and the queue goes on from disk. The SDK conversation below stays for the old
// page until the entry's fleet.chat.unified switch; a migrated one answers 410.
const GATE = E.FLEET_WEBCHAT_GATE || join(HERE, "../../bin/fleet_session_gate.py");
const RAW = E.FLEET_WEBCHAT_RAW || join(HERE, "../../bin/dash-raw-session.sh");
const GATE_DIR = E.FLEET_GATE_DIR || join(E.FLEET_CONF_DIR || join(E.XDG_CONFIG_HOME || join(E.HOME || "", ".config"), "claude-fleet"), "session-gate");
const GATE_TICK_MS = Number(E.FLEET_WEBCHAT_GATE_TICK_MS || 1500);
const GATE_STATE_MS = Number(E.FLEET_WEBCHAT_GATE_STATE_MS || 3000);   // the view asks the gate this often
const GATE_LIVE = new Set(["queued", "trying", "native", "waking"]);
function gate(args, input = "", timeout = 90000) {
  return new Promise((resolve) => {
    const c = execFile("python3", [GATE, ...args], { env: E, timeout, maxBuffer: 4 * 1024 * 1024 }, (err, stdout) => {
      let j = null;
      try { j = JSON.parse(String(stdout).trim().split("\n").pop() || "null"); } catch { /* no answer */ }
      resolve({ rc: err ? (typeof err.code === "number" ? err.code : 1) : 0, j });
    });
    if (input) c.stdin.end(input); else c.stdin.end();
  });
}
// the fleet a new session opens in: this login's one fleet (its first socket)
function firstFleet() {
  if (E.FLEET_WEBCHAT_FLEET) return Promise.resolve(E.FLEET_WEBCHAT_FLEET);
  return new Promise((resolve) => execFile("bash", ["-c", '. "$1/fleet-lib.sh" >/dev/null 2>&1; fleet_sockets 2>/dev/null | head -n 1',
    "first-fleet", join(HERE, "../../bin")], { env: E, timeout: 20000 }, (err, stdout) => resolve(err ? "" : String(stdout).trim())));
}
const fidOf = (u, body) => String(u.searchParams.get("fid") || body?.fid || "");
// words still waiting anywhere on this login: read off the files, no process
function gateWaiting() {
  let dirs = [];
  try { dirs = readdirSync(GATE_DIR); } catch { return false; }
  for (const d of dirs) {
    if (!FID_RE.test(d)) continue;
    let fs = [];
    try { fs = readdirSync(join(GATE_DIR, d)); } catch { continue; }
    for (const f of fs) {
      if (!f.endsWith(".json") || f.startsWith(".")) continue;
      try { if (GATE_LIVE.has(JSON.parse(readFileSync(join(GATE_DIR, d, f), "utf8")).state)) return true; } catch { /* half written */ }
    }
  }
  return false;
}
let gateTicking = false, gatePending = false;
function gateTick() {
  if (gateTicking) return;
  gatePending = gateWaiting();
  if (!gatePending) return;
  gateTicking = true;
  gate(["tick"]).finally(() => { gateTicking = false; });
}
setInterval(gateTick, GATE_TICK_MS).unref();
// one sentence (+ at most 4 pictures, kept in media/ and named in the turn)
async function gateSay(req, res, u, person) {
  const tb = await turnBody(req, res);
  if (!tb) return;
  const fid = fidOf(u, tb.body);
  if (!FID_RE.test(fid)) return send(res, 400, { error: "not a session", code: "bad_target" });
  const delivery = String(tb.body.delivery || tb.body.id || "");
  if (delivery && !FID_RE.test(delivery)) return send(res, 400, { error: "not a delivery id", code: "bad_delivery" });
  const args = ["say", "--fid", fid];
  if (delivery) args.push("--delivery", delivery);
  for (const b of tb.images) {
    const k = keepImage(b);
    if (!k || k.big) return send(res, 400, { error: "图太大或不是图", code: "bad_image" });
    args.push("--image", join(MEDIA, k.ref));
  }
  const r = await gate(args, tb.text);
  if (!r.j) return send(res, 503, { state: "refused", reason: "gate_unavailable" });
  log("say", { person, state: r.j.state, reason: r.j.reason || "" });
  gatePending = true;
  return send(res, 200, r.j);
}
// a NEW session opened from the web: a no-repo session of this login, its first
// sentence the start's own first turn; the agent chosen here stays its agent
async function gateOpen(req, res, person) {
  const tb = await turnBody(req, res);
  if (!tb) return;
  const agent = String(tb.body.agent || "claude");
  if (!PROVIDERS_RE.test(agent)) return send(res, 400, { error: "unknown agent", code: "agent" });
  let text = tb.text;
  for (const b of tb.images) {
    const k = keepImage(b);
    if (!k || k.big) return send(res, 400, { error: "图太大或不是图", code: "bad_image" });
    text += `\n\n[附图] ${join(MEDIA, k.ref)}`;
  }
  const target = await firstFleet();
  const pf = join(STATE, `open-${process.pid}-${Date.now()}.txt`);
  writeFileSync(pf, text, { mode: 0o600 });
  const args = [...(target ? [target] : []), "--origin", "hub", "--print", "--no-repo", "--node", "local",
    "--reap-origin", "web", "--agent", agent, `--prompt-file=${pf}`];
  const r = await run(RAW, args);
  try { unlinkSync(pf); } catch { /* read by the spawn */ }
  const line = (r.stdout || "").trim().split("\n").filter((l) => l.includes("\t")).pop() || "";
  const fid = line.split("\t")[3] || "";
  if (r.rc !== 0 || !FID_RE.test(fid)) {
    const said = (r.stderr || "").trim().split("\n").pop() || "";
    log("open_failed", { person, rc: r.rc, said: said.slice(0, 200) });
    return send(res, 503, { state: "refused", reason: "open_failed", error: said || "没能开一个新会话" });
  }
  log("open", { person, agent });
  return send(res, 200, { fid, agent, delivery: randomUUIDish(), state: "sent" });
}
const randomUUIDish = () => { const h = randomHex(); return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`; };
async function gatePost(req, res, u, what) {
  const body = await readJson(req);
  const fid = fidOf(u, body);
  if (!FID_RE.test(fid)) return send(res, 400, { error: "not a session", code: "bad_target" });
  let args;
  if (what === "stop") args = ["stop", "--fid", fid];
  else if (what === "ack") {
    if (!FID_RE.test(String(body.delivery || ""))) return send(res, 400, { error: "not a delivery id" });
    args = ["ack", "--fid", fid, "--delivery", String(body.delivery)];
  } else {
    // the question's fingerprint and the option's own words (the entry hands the page's body on as is)
    // {fp, answers: {<question>: <label>}} · {fp, picks: [<label>]} · {fp, allow: true|false} (a permission)
    const fp = String(body.fp || body.fingerprint || "");
    if (!/^[0-9a-f]{16}$/.test(fp)) return send(res, 400, { error: "a question's fingerprint and its option, verbatim", code: "bad_answer" });
    args = ["answer", "--fid", fid, "--fp", fp];
    if (typeof body.allow === "boolean") args.push("--allow", body.allow ? "1" : "0");
    else if (body.answers && typeof body.answers === "object" && !Array.isArray(body.answers)) args.push("--answers-json", JSON.stringify(body.answers));
    else {
      const raw = body.picks ?? body.labels ?? body.options ?? (body.pick ?? body.label ?? body.option);
      const picks = (Array.isArray(raw) ? raw : raw != null ? [raw] : []).map(String).filter(Boolean);
      if (!picks.length || picks.length > 8) return send(res, 400, { error: "a question's fingerprint and its option, verbatim", code: "bad_answer" });
      args.push(...picks.flatMap((x) => ["--pick", x]));
    }
  }
  const r = await gate(args);
  if (!r.j) return send(res, 503, { ok: false, why: "gate_unavailable" });
  if (r.j.ok === false && r.j.why === "no_session") return send(res, 404, { ...r.j, code: "no_session", error: "这个会话不在这台机器上了" });
  return send(res, 200, r.j);
}
// what the gate knows of one session, for the view's state line
const gateKnown = new Map();                               // fid → { j, at }
async function gateStatus(fid) {
  const r = await gate(["status", "--fid", fid], "", 30000);
  if (r.j) { gateKnown.set(fid, { j: r.j, at: Date.now() }); if (gateKnown.size > 500) gateKnown.delete(gateKnown.keys().next().value); }
  return r.j;
}

// 旧「我的对话」 (task HHV0): the one conversation becomes a session of this login
// (the same conversation resumed in a window, origin web); everything 新对话 put
// away — at most 200 — is listed as 已结束的会话 (ended.json, read by /api/ended).
// Asked by the entry once fleet.chat.unified is on (POST /api/migrate) — before
// that the old page still talks to it here. A failure leaves conversation.json as
// it is and marks it pending: the next start tries again.
const ENDED_FILE = join(STATE, "ended.json");
let migrating = null;
async function migrateConv() {
  if (conv.migrated?.fid) return { ok: true, fid: conv.migrated.fid, already: true };
  if (live || maint || aside.size) return { ok: false, why: "busy" };
  const ended = [];
  for (const e of conv.put_away || []) {
    const ids = [...(e.chain || []), ...(e.session ? [{ id: e.session, cwd: e.cwd }] : [])];
    if (ids.length) ended.push({ agent: "claude", session: ids.at(-1).id, cwd: ids.at(-1).cwd, chain: ids.slice(0, -1), at: e.at || "" });
  }
  let fid = "";
  if (conv.session) {
    const target = await firstFleet();
    const seed = join(STATE, `migrate-${process.pid}.txt`);
    writeFileSync(seed, "", { mode: 0o600 });
    const r = await run(RAW, [...(target ? [target] : []), "--origin", "hub", "--print", "--no-repo", "--node", "local",
      "--reap-origin", "web", "--agent", "claude", "--resume", conv.session, "--seed-file", seed, "--name", "我的对话"]);
    try { unlinkSync(seed); } catch { /* gone */ }
    const line = (r.stdout || "").trim().split("\n").filter((l) => l.includes("\t")).pop() || "";
    fid = line.split("\t")[3] || "";
    if (r.rc !== 0 || !FID_RE.test(fid)) {
      conv.migrate_pending = true; saveConv();
      log("migrate_failed", { rc: r.rc });
      return { ok: false, why: "open_failed" };
    }
    await gate(["name", "--fid", fid, "--name", "我的对话"]);   // the title the page finds it by
    if (conv.chain.length) ended.unshift({ agent: "claude", session: conv.chain.at(-1).id, cwd: conv.chain.at(-1).cwd, chain: conv.chain.slice(0, -1), at: "", relayed_into: fid });
  }
  try {
    let old = [];
    try { old = JSON.parse(readFileSync(ENDED_FILE, "utf8")); } catch { /* first */ }
    writeFileSync(ENDED_FILE + ".tmp", JSON.stringify([...old, ...ended].slice(-400)), { mode: 0o600 });
    renameSync(ENDED_FILE + ".tmp", ENDED_FILE);
  } catch (e) { conv.migrate_pending = true; saveConv(); return { ok: false, why: "write_failed" }; }
  closeWarm("migrated");
  conv.migrated = { fid, at: new Date().toISOString(), ended: ended.length };
  delete conv.migrate_pending;
  saveConv();
  log("migrated", { fid: !!fid, ended: ended.length });
  return { ok: true, fid, ended: ended.length };
}
function migrate() { if (!migrating) migrating = migrateConv().finally(() => { migrating = null; }); return migrating; }
if (conv.migrate_pending) setTimeout(() => migrate().catch(() => {}), 5000).unref();
async function endedList(res, u) {
  let list = [];
  try { list = JSON.parse(readFileSync(ENDED_FILE, "utf8")); } catch { /* none */ }
  const sid = u.searchParams.get("session") || "";
  if (!sid) return send(res, 200, { ended: list.map(({ agent, session, at, relayed_into }) => ({ agent, session, at, relayed_into })).reverse() });
  const e = list.find((x) => x.session === sid);
  if (!e || !SID_RE.test(sid)) return send(res, 404, { error: "no such session", code: "no_session" });
  const items = [];
  for (const s of [...(e.chain || []), { id: e.session, cwd: e.cwd }]) items.push(...await readItems(s.id, s.cwd));
  return send(res, 200, { session: sid, items });
}

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
  // 只读 (task F481): a terminal session of this login, read along
  if (p === "/api/view" && req.method === "GET") return viewStream(req, res, u, person);
  // 接管 / 交回 (task VV8F): the same session, this page ⇄ its terminal
  if (p === "/api/takeover" && req.method === "POST") return handover(req, res, person, "take");
  if (p === "/api/giveback" && req.method === "POST") return handover(req, res, person, "give");
  // the session gate (task HHV0): say · open · answer · stop by fid
  if (p === "/api/say" && req.method === "POST") return gateSay(req, res, u, person);
  if (p === "/api/open" && req.method === "POST") return gateOpen(req, res, person);
  if (p === "/api/ack" && req.method === "POST") return gatePost(req, res, u, "ack");
  // stop / answer with a session's fid (the entry writes it into the body, PQ41):
  // the gate's; without one: the old conversation's, below
  if ((p === "/api/stop" || p === "/api/answer") && req.method === "POST") {
    let b = {};
    try { b = await readJson(req); } catch { return send(res, 413, { error: "too large" }); }
    if (FID_RE.test(fidOf(u, b))) return gatePost(req, res, u, p === "/api/stop" ? "stop" : "answer");
  }
  if (p === "/api/session" && req.method === "GET" && FID_RE.test(u.searchParams.get("fid") || "")) {
    const j = await gateStatus(u.searchParams.get("fid"));
    return j ? send(res, 200, j) : send(res, 503, { error: "gate_unavailable" });
  }
  if (SOCKET && p === "/api/migrate" && req.method === "POST") return send(res, 200, await migrate());
  if (p === "/api/ended" && req.method === "GET") return endedList(res, u);
  // a migrated conversation is a session now: the old roads say where it went
  if (conv.migrated?.fid && (u.searchParams.get("provider") || "claude") === "claude"
      && ["/api/turn", "/api/new", "/api/take"].includes(p) && req.method === "POST") {
    return send(res, 410, { error: "这个对话已经是一个会话了", code: "moved", fid: conv.migrated.fid });
  }
  // the Codex side (task R9A2): ?provider=codex; none or claude = the Claude side, as before
  const provider = u.searchParams.get("provider") || "claude";
  if (p.startsWith("/api/") && !PROVIDERS_RE.test(provider)) return send(res, 400, { error: "unknown provider" });
  if (provider === "codex") {
    const sd = sides();
    if (!codex.available() && p !== "/api/file") return send(res, 404, { error: "这台机器上没有 Codex" });
    if (p === "/api/conversation" && req.method === "GET") return send(res, 200, { ...await codex.conversation(), providers: sd.providers, others: { claude: sd.claude } });
    if (p === "/api/turn" && req.method === "POST") return codexTurn(req, res, person);
    if (p === "/api/stop" && req.method === "POST") { const ok = await codex.stop(String((await readJson(req)).turn || "")); return send(res, ok ? 200 : 404, { ok }); }
    if (p === "/api/answer" && req.method === "POST") { const ok = codex.answer(await readJson(req)); return send(res, ok ? 200 : 404, { ok }); }
    if (p === "/api/new" && req.method === "POST") { const ok = codex.newConversation(); return send(res, ok ? 200 : 409, ok ? { ok } : { error: "还在回复上一句" }); }
    // the terminal ⇄ this page (task T810), the Codex side's thread
    if (SOCKET && p === "/api/state" && req.method === "GET") return send(res, 200, codex.state());
    if (SOCKET && p === "/api/release" && req.method === "POST") { codex.release(String((await readJson(req)).session || "")); ownerSeen = {}; return send(res, 200, { ok: true }); }
    if (p === "/api/take" && req.method === "POST") {
      const sid = codex.state().session;
      if (!sid) return send(res, 404, { error: "no conversation" });
      const r = await run(HANDOFF, ["to-webchat-take", "--agent", "codex", "--sid", sid]);
      ownerSeen = {};
      const said = (r.stderr || r.stdout || "").trim().split("\n").pop();
      if (r.rc === 0) { log("taken", { provider: "codex" }); return send(res, 200, { ok: true }); }
      return send(res, r.rc === 3 ? 409 : 500, { error: said || "could not take it over", ...(r.rc === 3 ? { code: "terminal_busy" } : {}) });
    }
  }
  if (p === "/api/new" && req.method === "POST") { const ok = newClaude(); return send(res, ok ? 200 : 409, ok ? { ok } : { error: "正在整理上一段对话，过几秒再开" }); }
  if (p === "/api/conversation" && req.method === "GET") {
    // a page reading the conversation is about to talk: have the credential ready
    const owner = await ownerNow();
    if (SDK_PATH && !live && !owner) { credFor().catch(() => {}); prewarm(); }
    const items = await conversationItems();
    return send(res, 200, { session: conv.session, cwd: conv.cwd, busy: !!live, turn: live?.tid || "",
      ...(owner ? { owner } : {}), ...(conv.handed && !owner ? { handed: conv.handed } : {}),
      asks: live ? [...live.asks.entries()].map(([rid, a]) => askEvent(rid, a)) : [],
      models: MODELS, default: DEFAULT_MODEL, budget: budgetView(), items: items.slice(-600),
      last: conv.last || "", ...(conv.interrupted && !live ? { interrupted: conv.interrupted } : {}),
      ...(codex.available() ? { providers: sides().providers, others: { codex: codex.side() } } : {}) });
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
  // the terminal ⇄ this page (task T810): adopt / state / release are this
  // machine's own (fleet-webchat-handoff.sh over the socket); take is the page's
  if (SOCKET && p === "/api/state" && req.method === "GET") return send(res, 200, { busy: !!live || !!maint, session: conv.session });
  // anything answering on either side: the next copy's takeover waits for none (task WD8F)
  if (SOCKET && p === "/api/busy" && req.method === "GET") return send(res, 200, { busy: busyAny() });
  if (SOCKET && p === "/api/adopt" && req.method === "POST") {
    const [code, msg, why] = await adoptConv(await readJson(req));
    return send(res, code, code === 200 ? { ok: true, msg } : { error: msg, ...(why ? { code: why } : {}) });
  }
  if (SOCKET && p === "/api/release" && req.method === "POST") {
    const b = await readJson(req);
    if (String(b.session || "") === conv.session) { closeWarm("terminal took it"); ownerSeen = {}; }
    return send(res, 200, { ok: true });
  }
  if (p === "/api/take" && req.method === "POST") {
    if (!conv.session) return send(res, 404, { error: "no conversation" });
    const r = await run(HANDOFF, ["to-webchat-take", "--agent", "claude", "--sid", conv.session]);
    ownerSeen = {};
    const said = (r.stderr || r.stdout || "").trim().split("\n").pop();
    if (r.rc === 0) { log("taken"); return send(res, 200, { ok: true }); }
    return send(res, r.rc === 3 ? 409 : 500, { error: said || "could not take it over", ...(r.rc === 3 ? { code: "terminal_busy" } : {}) });
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
const busyAny = () => !!live || aside.size > 0 || !!maint || codex.busy() || gatePending || !!migrating;
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
  await Promise.race([Promise.all([dropCred(ev), codex.close()]), new Promise((r) => setTimeout(r, 5000))]);
  process.exit(code);
}
if (SOCKET && IDLE_SECS > 0) {
  setInterval(() => {
    if (busyAny() || Date.now() - lastBusy < IDLE_SECS * 1000) return;
    server.getConnections((err, n) => { if (!err && n === 0 && !busyAny()) shutdown(IDLE_RC, "idle_exit"); });
  }, Math.min(60, Math.max(0.2, IDLE_SECS / 4)) * 1000).unref();
}
for (const sig of ["SIGTERM", "SIGINT"]) process.on(sig, () => shutdown(0, "stop"));
