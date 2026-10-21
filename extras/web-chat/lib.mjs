// lib.mjs — the web chat's small pure parts (issue #3567): who may come in, what
// a session's agent gets in its environment, and what never leaves the server.
// server.mjs is the wiring; bin/fleet-webchat-selftest.sh drives both.
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

export const COOKIE = "fwc";
export const CODE_TTL_MS = 10 * 60 * 1000;          // a login link is good for 10 minutes, once
export const COOKIE_TTL_S = 30 * 24 * 3600;         // a browser that came in stays in 30 days

// The models a web chat may run (the 发起人's call on #3567): change this list
// and nothing else. Checked on the server — a model the page hides is not a
// model the server allows. Fable is deliberately not on it.
export const MODELS = [
  { id: "claude-sonnet-5-5", label: "Sonnet 5.5" },
  { id: "claude-opus-5-5", label: "Opus 5.5" },
  { id: "claude-haiku-5-5", label: "Haiku 5.5" },
];
export const DEFAULT_MODEL = "claude-sonnet-5-5";
export const modelAllowed = (m) => MODELS.some((x) => x.id === m);

export const newSecret = (n = 32) => randomBytes(n).toString("base64url");
export const sha = (s) => createHash("sha256").update(String(s)).digest("hex");

export function sameSecret(a, b) {
  const x = Buffer.from(String(a || "")), y = Buffer.from(String(b || ""));
  return x.length === y.length && x.length > 0 && timingSafeEqual(x, y);
}

export function parseCookies(h) {
  const out = {};
  for (const part of String(h || "").split(";")) {
    const i = part.indexOf("=");
    if (i > 0) out[part.slice(0, i).trim()] = part.slice(i + 1).trim();
  }
  return out;
}

// A Host header the server answers to: its own loopback port, or a name the
// person put in front of it (FLEET_WEBCHAT_HOSTS, e.g. the tailnet name). Any
// other name is a DNS-rebinding page asking on someone's behalf — refused.
export function hostAllowed(host, port, extra = []) {
  const h = String(host || "").toLowerCase();
  if (!h) return false;
  const ok = new Set([`127.0.0.1:${port}`, `localhost:${port}`, `[::1]:${port}`]);
  for (const e of extra) if (e) { ok.add(e.toLowerCase()); }
  if (ok.has(h)) return true;
  const bare = h.replace(/:\d+$/, "");
  return extra.some((e) => e && e.toLowerCase() === bare);
}

// The credential shapes that must never be echoed: a proxy session credential
// (fcp1. / fcp-h1. / fcp-h2. / fcpn1.), an Anthropic key or OAuth token, a bearer value.
const SECRET_RE = /\b(?:fcp(?:1|n1|-h[12])\.[A-Za-z0-9._~+/=-]+|sk-ant-[A-Za-z0-9_-]+|Bearer\s+[A-Za-z0-9._~+/=-]{12,})/g;
export function redact(s, extra = []) {
  let out = String(s ?? "").replace(SECRET_RE, "[redacted]");
  for (const x of extra) if (x && x.length >= 8) out = out.split(x).join("[redacted]");
  return out;
}

// The environment the session's `claude` child runs with — the fleet session's
// own road (bin/fleet-claude.sh, issue #1972): through this login's credential
// proxy, ANTHROPIC_BASE_URL + CLAUDE_CODE_OAUTH_TOKEN=<the minted SESSION
// credential> + CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1; the proxy picks the
// pool's account per request and meters it. mint = null ⇒ no proxy here (switched
// off / nothing to bind): the ambient login, exactly as a CLI launch would.
// Never a subscription token, never the fleet's own credentials or a tmux pane.
const DROP = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_SECURESTORAGE_CONFIG_DIR",
  "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
  "FLEET_WORKER_CRED", "FLEET_WORKER_ASSERT", "TMUX", "TMUX_PANE", "FLEET_WEBCHAT_ADMIN"];
export function agentEnv(base, mint) {
  const env = { ...base };
  for (const k of DROP) delete env[k];
  delete env.CLAUDE_CODE_OAUTH_TOKEN;
  delete env.ANTHROPIC_BASE_URL;
  if (mint) {
    env.ANTHROPIC_BASE_URL = `http://127.0.0.1:${mint.port}`;
    env.CLAUDE_CODE_OAUTH_TOKEN = mint.cred;
    env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
  }
  return env;
}

// How a turn's agent is allowed to act (issue #4031): like a fleet CLI session,
// bypassPermissions — no tool waits for a 允许 on the page. The guards still hold:
// the login's settings (settingSources "user") carry the fleet's PreToolUse hooks
// (bash-guard, base-readonly-guard, …), and a hook's deny stops a tool in bypass
// too. AskUserQuestion is not a permission: Claude Code still hands it to
// canUseTool in bypass, so the question card still reaches the page.
export const PERMISSIONS = Object.freeze({
  permissionMode: "bypassPermissions", allowDangerouslySkipPermissions: true,
  settingSources: Object.freeze(["user", "project", "local"]),
});

// `fleet-session-cred.sh mint` prints `<route> TAB <port> TAB <credential>`.
export function parseMint(stdout) {
  const [route, port, cred] = String(stdout || "").trim().split("\t");
  if (!route || !/^\d+$/.test(port || "") || !cred) return null;
  return { route, port: Number(port), cred };
}

// One line for a tool step, folded in the page: the tool and its gist.
export function toolSummary(name, input) {
  const i = input || {};
  if (name === "AskUserQuestion" && Array.isArray(i.questions)) {
    return `提问 · ${i.questions.map((q) => q.question).join(" / ").slice(0, 160)}`;
  }
  if (name === "mcp__fleet_chat__show_page") return `发到活页 · ${String(i.title || "网页").slice(0, 120)}`;
  if (name === "mcp__fleet_chat__page_target") return "活页 · 查这一页放哪";
  const pick = i.command ?? i.file_path ?? i.path ?? i.pattern ?? i.url ?? i.query ?? i.description ?? i.prompt;
  const s = typeof pick === "string" ? pick : JSON.stringify(i);
  return `${name}${s ? " · " + s.replace(/\s+/g, " ").slice(0, 160) : ""}`;
}

// The pool's per-person budget refusal (fleet.person_budget, issue #1977): the
// credential proxy answers 403 {"error":{"code":"person_budget_exceeded",
// "message":"cred-proxy: 已达个人额度…", "reset_at"?}} and Claude Code hands it on
// as its own "API Error: 403 …" text. -> { msg, until? } when <x> (a string, an
// SDK content array, or a list of either) carries it, else null.
export const BUDGET_CODE = "person_budget_exceeded";
export function budgetRefusal(x) {
  const flat = (v) => typeof v === "string" ? v : Array.isArray(v) ? v.map(flat).join("\n")
    : v && typeof v === "object" ? (typeof v.text === "string" ? v.text : JSON.stringify(v)) : "";
  const s = flat(x);
  if (!s.includes(BUDGET_CODE)) return null;
  let msg = "", until = "";
  const j = s.indexOf("{");
  if (j >= 0) {
    try {
      const err = JSON.parse(s.slice(j, s.lastIndexOf("}") + 1)).error || {};
      msg = String(err.message || "");
      until = String(err.reset_at || "");
    } catch { /* not the proxy's JSON — fall back to the text */ }
  }
  if (!until) until = (s.match(/"reset_at"\s*:\s*"([^"]+)"/) || [])[1] || "";
  if (until && Number.isNaN(Date.parse(until))) until = "";
  msg = (msg.replace(/^cred-proxy:\s*/, "") || "已达个人额度").slice(0, 300);
  return until ? { msg, until } : { msg };
}

// X-Fleet-Person, for the log only (the relay verified it before it dialled the
// socket — C2): its first field, and only when it is name-shaped (≤ 64 of
// [A-Za-z0-9@._+:-] — the entry sends the principal, gh:<id> / p:<uuid>, #3645)
// — a signature-length value is never written down.
export function personName(h) {
  const v = String(h || "").split(/[;,\s]/)[0];
  return /^[A-Za-z0-9@._+:-]{1,64}$/.test(v) ? v : "";
}

// ---- the browser's context (issue #4034) -------------------------------------
// What the page says of itself (browser.ts) + where the entry saw it come from
// (X-Fleet-Client, written by the entry — tokenledger/hub/api/chat_client.go)
// → ONE short line for the model, put before the person's words on the first
// turn and again only when it changes (another device, city or day) — never in
// the system prompt, which would break its cache — and the full details for
// the browser_context tool. Nothing of it is logged.
const str = (v, n = 200) => (typeof v === "string" ? v.slice(0, n) : "");
const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);

// the page's report, bounded and typed — whatever else it carries is dropped
export function cleanBrowser(o) {
  if (!o || typeof o !== "object") return null;
  const u = o.uaData && typeof o.uaData === "object" ? o.uaData : null;
  const n = o.net && typeof o.net === "object" ? o.net : null;
  const box = (b, ...k) => b && typeof b === "object" ? Object.fromEntries(k.map((x) => [x, num(b[x])])) : null;
  return {
    ua: str(o.ua, 512),
    uaData: u ? { brands: (Array.isArray(u.brands) ? u.brands : []).slice(0, 8).map((b) => str(b, 64)),
      mobile: u.mobile === true, platform: str(u.platform, 32), platformVersion: str(u.platformVersion, 32),
      model: str(u.model, 64), architecture: str(u.architecture, 16) } : null,
    lang: str(o.lang, 35),
    langs: (Array.isArray(o.langs) ? o.langs : []).slice(0, 5).map((l) => str(l, 35)),
    tz: str(o.tz, 64),
    tzOffset: num(o.tzOffset),
    screen: box(o.screen, "w", "h", "dpr"),
    viewport: box(o.viewport, "w", "h"),
    touch: num(o.touch),
    net: n ? { type: str(n.type, 16), effectiveType: str(n.effectiveType, 16), downlink: num(n.downlink), rtt: num(n.rtt),
      saveData: n.saveData === true } : null,
    dark: o.dark === true,
  };
}

// X-Fleet-Client: base64url JSON {ip, country, province, city}; {} when absent or bad
export function parseClient(h) {
  try {
    const o = JSON.parse(Buffer.from(String(h || ""), "base64url").toString("utf8"));
    if (!o || typeof o !== "object") return {};
    return { ip: str(o.ip, 64), country: str(o.country, 32), province: str(o.province, 32), city: str(o.city, 32) };
  } catch { return {}; }
}

// UA (+ Client Hints) → device · system · browser, in the person's words
export function uaKind(b) {
  const ua = b?.ua || "", h = b?.uaData || {};
  const has = (re) => re.test(ua);
  let os = "", device = "";
  if (has(/iPhone|iPod/)) { os = "iPhone"; device = "手机"; }
  else if (has(/iPad/) || (has(/Macintosh/) && (b?.touch || 0) > 1)) { os = "iPad"; device = "平板"; }
  else if (has(/HarmonyOS|OpenHarmony/)) { os = "鸿蒙"; device = has(/Mobile|Phone/) ? "手机" : "平板"; }
  else if (has(/Android/) || h.platform === "Android") { os = "安卓"; device = has(/Mobile/) || h.mobile ? "手机" : "平板"; }
  else if (has(/Macintosh|Mac OS X/) || h.platform === "macOS") { os = "Mac"; device = "电脑"; }
  else if (has(/Windows/) || h.platform === "Windows") { os = "Windows"; device = "电脑"; }
  else if (has(/CrOS/) || h.platform === "Chrome OS") { os = "ChromeOS"; device = "电脑"; }
  else if (has(/Linux/) || h.platform === "Linux") { os = "Linux"; device = "电脑"; }
  if (h.mobile === true && device === "电脑") device = "手机";
  const browser = has(/MicroMessenger/) ? "微信内置浏览器" : has(/DingTalk/) ? "钉钉内置浏览器"
    : has(/Edg(?:A|iOS)?\//) ? "Edge" : has(/OPR\//) ? "Opera" : has(/SamsungBrowser/) ? "三星浏览器"
    : has(/UCBrowser/) ? "UC" : has(/Quark/) ? "夸克" : has(/Firefox|FxiOS/) ? "Firefox"
    : has(/CriOS|Chrome\//) ? "Chrome" : has(/Safari\//) ? "Safari" : "";
  return { device, os, browser };
}

const WEEK = ["日", "一", "二", "三", "四", "五", "六"];
function localTime(tz, now) {
  let p;
  try {
    p = Object.fromEntries(new Intl.DateTimeFormat("en-CA", { timeZone: tz || undefined, year: "numeric", month: "2-digit",
      day: "2-digit", hour: "2-digit", minute: "2-digit", weekday: "short", hourCycle: "h23" }).formatToParts(now).map((x) => [x.type, x.value]));
  } catch { return null; }                                // a zone Intl does not know
  const wd = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].indexOf(p.weekday);
  const day = `${p.year}-${p.month}-${p.day}`;
  return { day, text: `${day} 周${WEEK[wd] ?? "?"} ${p.hour}:${p.minute}` };
}

// → { key, line } — key is what a change is judged by (never the minute); null
// when there is nothing to say
export function contextLine(b, place = {}, now = new Date()) {
  if (!b && !place.ip) return null;
  const { device, os, browser } = uaKind(b);
  const w = b?.viewport?.w || b?.screen?.w || 0;
  const width = !w ? "" : w < 600 ? "窄屏" : w < 1024 ? "中屏" : "宽屏";
  const t = localTime(b?.tz, now);
  const pv = place.province || "", ct = place.city || "";
  const where = (ct && pv && !ct.startsWith(pv.replace(/[省市]$/, "")) ? pv + ct : ct || pv) || place.country || "";
  const parts = [
    [device, os].filter(Boolean).join(" · "), browser, b?.lang || "", width,
    t ? `本地时间 ${t.text}${b?.tz ? `（${b.tz}）` : ""}` : "",
    where ? `大致位置 ${where}` : "",
  ].filter(Boolean);
  if (!parts.length) return null;
  const key = [device, os, browser, b?.lang || "", width, b?.tz || "", where, t?.day || ""].join("|");
  return { key, line: `${parts.join(" · ")}（更多细节可调用 browser_context）` };
}

export const CTX_OPEN = "<fleet-webchat-context>";
export const CTX_RE = /^<fleet-webchat-context>[\s\S]*?<\/fleet-webchat-context>\s*/;
export const contextBlock = (line) => `${CTX_OPEN}\n用户此刻的浏览器：${line}\n</fleet-webchat-context>\n\n`;

// the browser_context tool's answer: everything known of this turn's browser
export function contextDetails(b, place = {}) {
  return { ip: place.ip || "", place: { country: place.country || "", province: place.province || "", city: place.city || "" },
    ...uaKind(b), ...(b || {}) };
}

// ---- images (task T773) ---------------------------------------------------------
// The types the page shows, by MIME → the file extension they are kept under.
export const IMAGE_TYPES = Object.freeze({ "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp" });
export const IMAGE_EXT_MIME = Object.freeze(Object.fromEntries(Object.entries(IMAGE_TYPES).map(([m, x]) => [x, m])));
// a kept image's name: the first 32 hex of its bytes' sha256 + its extension
export const MEDIA_REF_RE = /^[0-9a-f]{32}\.(?:png|jpg|gif|webp)$/;
// The bytes of an image block (a transcript's / the SDK's {type:"image", source}),
// or null when it is not one the page shows: base64 only, a known type.
export function imageBlockBytes(b) {
  const src = b && b.type === "image" ? b.source : null;
  if (!src || src.type !== "base64" || typeof src.data !== "string") return null;
  const ext = IMAGE_TYPES[String(src.media_type || "").toLowerCase()];
  if (!ext) return null;
  const buf = Buffer.from(src.data, "base64");
  return buf.length ? { buf, ext, mime: IMAGE_EXT_MIME[ext] } : null;
}
// width × height off the header (PNG · JPEG · GIF · WebP), or {} when unread
export function imageSize(buf, ext) {
  try {
    if (ext === "png" && buf.length >= 24) return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20) };
    if (ext === "gif" && buf.length >= 10) return { w: buf.readUInt16LE(6), h: buf.readUInt16LE(8) };
    if (ext === "webp" && buf.length >= 30) {
      const kind = buf.toString("ascii", 12, 16);
      if (kind === "VP8X") return { w: 1 + buf.readUIntLE(24, 3), h: 1 + buf.readUIntLE(27, 3) };
      if (kind === "VP8 ") return { w: buf.readUInt16LE(26) & 0x3fff, h: buf.readUInt16LE(28) & 0x3fff };
      if (kind === "VP8L") { const b = buf.readUInt32LE(21); return { w: 1 + (b & 0x3fff), h: 1 + ((b >> 14) & 0x3fff) }; }
    }
    if (ext === "jpg") {
      for (let i = 2; i + 9 < buf.length;) {
        if (buf[i] !== 0xff) { i++; continue; }
        const m = buf[i + 1];
        if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) return { w: buf.readUInt16BE(i + 7), h: buf.readUInt16BE(i + 5) };
        i += 2 + buf.readUInt16BE(i + 2);
      }
    }
  } catch { /* a short or odd header */ }
  return {};
}

// ---- the home's files a reply links to (task T773 ②) ---------------------------------
// A reply's Markdown link / image target that names a file on this machine:
// an absolute path, ~/…, file://…, or one relative to the session's directory —
// never a URL with another scheme, an anchor or a query.
export function linkTargets(text) {
  const out = new Set();
  for (const m of String(text || "").matchAll(/\]\(\s*<?([^)\s<>]+)>?(?:\s+"[^"]*")?\s*\)/g)) {
    const t = m[1];
    if (/^file:\/\//i.test(t) || /^~\//.test(t) || t.startsWith("/") || (!/^[a-z][a-z0-9+.-]*:/i.test(t) && !/^[#?]/.test(t))) out.add(t);
  }
  return [...out];
}
// A path the page may never open, whatever links to it: the login's keys and
// configuration, and any file named like a secret. `rel` is the path under $HOME.
const DENY_DIRS = [".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".config", ".claude", ".codex", ".local/share/keyrings",
  ".password-store", "Library/Keychains", "Library/Cookies", ".netrc", ".npmrc", ".pypirc", ".git-credentials"];
const DENY_NAME = /(^\.env($|\.)|\.(pem|key|p12|pfx|keystore|jks|kdbx)$|^id_(rsa|dsa|ecdsa|ed25519)|(^|[._-])(secrets?|credentials?|tokens?|passwords?|private)([._-]|$))/i;
export function fileDenied(rel) {
  const parts = String(rel).split("/").filter(Boolean);
  if (!parts.length || parts.includes("..")) return true;
  const joined = parts.join("/");
  if (DENY_DIRS.some((d) => joined === d || joined.startsWith(d + "/"))) return true;
  return parts.some((p) => DENY_NAME.test(p));
}
// How a linked file goes back: an image as itself, anything else a download.
export function linkedType(name) {
  const ext = String(name).toLowerCase().split(".").pop();
  const img = IMAGE_EXT_MIME[ext === "jpeg" ? "jpg" : ext];
  if (img) return { type: img, inline: true };
  if (ext === "pdf") return { type: "application/pdf", inline: false };
  return { type: "application/octet-stream", inline: false };
}

// What the web chat's agent is told once in each session (task T773), in a block
// of its own before the person's words — the page never shows it (NOTE_RE): the
// person reads a web page, not this machine, so a file they should see is shown
// or linked, and a page made for them goes to their 活页 as a card.
export const WEB_NOTE_V = "t773.1";
export const WEB_NOTE = "你在一个网页里和这个人对话，他看不到这台机器的屏幕和文件。" +
  "要给他看的图片、截图：用 Read 读一下，网页上就会显示。提到本机文件时写成 Markdown 链接（[名字](绝对路径)），网页上点得开。" +
  "给他做的网页（HTML）：先调 page_target，再用 space 工具 publish_file 发到他活页的「WebChat 产物」文件夹（保持私密），" +
  "然后调 show_page 给他一张能点开的卡片；page_target 答了 embed_origin 时，再用 preview_version(version_id, embed_origin) " +
  "拿嵌入链接一起交给 show_page，他就能在对话里直接预览。同一个网页再改就发到同一个 proposal_id。";
export const webNoteBlock = () => `<fleet-webchat-note>\n${WEB_NOTE}\n</fleet-webchat-note>\n\n`;
export const NOTE_RE = /^<fleet-webchat-note>[\s\S]*?<\/fleet-webchat-note>\s*/;
