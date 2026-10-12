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
// (fcp1. / fcp-h1. / fcpn1.), an Anthropic key or OAuth token, a bearer value.
const SECRET_RE = /\b(?:fcp(?:-h|n)?1\.[A-Za-z0-9._~+/=-]+|sk-ant-[A-Za-z0-9_-]+|Bearer\s+[A-Za-z0-9._~+/=-]{12,})/g;
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
  const pick = i.command ?? i.file_path ?? i.path ?? i.pattern ?? i.url ?? i.query ?? i.description ?? i.prompt;
  const s = typeof pick === "string" ? pick : JSON.stringify(i);
  return `${name}${s ? " · " + s.replace(/\s+/g, " ").slice(0, 160) : ""}`;
}
