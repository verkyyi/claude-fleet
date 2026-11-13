// agents.ts — what 我的 · Agent and the OAuth consent page (T4DN) share: the
// permission words a person can grant an outside agent (Claude Code, Codex,
// Gemini CLI, claude.ai…) over Tokenman's MCP door, their labels, the ones
// ticked by default, the expiry choices, and the snippet each agent is given.
// Pure: no React, no fetch — test/agents.mjs reads it as is.
import { tr } from "../shared/i18n.ts"; // .ts: test/agents.mjs runs this file as it is

export type Perm = "read" | "talk" | "start" | "stop" | "answer";

// The hub's order (GET /v1/me/agents → permissions); an unknown word the hub
// adds later is still shown, by its own name.
export const PERMS: Perm[] = ["read", "talk", "start", "stop", "answer"];

const LABEL: Record<Perm, [string, string]> = {
  read: ["查看会话和任务", "See your sessions and tasks"],
  talk: ["给会话发消息", "Message your sessions"],
  start: ["新建会话", "Start new sessions"],
  stop: ["停止和恢复会话", "Stop and resume sessions"],
  answer: ["替你回答权限提问", "Answer permission prompts for you"],
};
export const permLabel = (p: string) => (p in LABEL ? tr(...LABEL[p as Perm]) : p);

// read is always granted: an agent that can see nothing can do nothing.
export const LOCKED: Perm = "read";
// answer is the one that acts in the person's place: never ticked unless asked.
export const RISKY: Perm = "answer";
export const riskyWarning = () =>
  tr("勾上后，这个 Agent 可以替你批准会话里的命令和改动。只给你完全信任的 Agent。",
    "With this on, the agent can approve commands and edits in your sessions for you. Only give it to an agent you fully trust.");

export const DEFAULT_PERMS: Perm[] = ["read", "talk"];

// perms(asked, all): the ticks a list starts with — what was asked, in the
// hub's order, read always in; answer only when asked by name.
export function initialPerms(asked: readonly string[] | undefined, all: readonly string[] = PERMS): string[] {
  const want = new Set(asked && asked.length ? asked : DEFAULT_PERMS);
  want.add(LOCKED);
  return all.filter((p) => want.has(p));
}

// toggle: one box flipped — read cannot be unticked; order stays the hub's.
export function togglePerm(cur: readonly string[], p: string, on: boolean, all: readonly string[] = PERMS): string[] {
  if (p === LOCKED) return all.filter((x) => cur.includes(x) || x === LOCKED);
  const next = new Set(cur);
  if (on) next.add(p); else next.delete(p);
  next.add(LOCKED);
  return all.filter((x) => next.has(x));
}

// consentPerms(asked, verified, all): the ticks the consent page starts with.
// A verified client (a metadata document at its own address) starts with what
// it asked; an unverified one (registered with a name of its own choosing)
// starts with read alone — what it asked is shown beside each box, and the
// person ticks the rest.
export function consentPerms(asked: readonly string[] | undefined, verified: boolean, all: readonly string[] = PERMS): string[] {
  return verified ? initialPerms(asked, all) : all.filter((p) => p === LOCKED);
}

// redirectHost: where the consent sends the person back to, for the page to
// lead with; a loopback address is a program on the person's own computer.
export function redirectHost(uri: string): { host: string; local: boolean } {
  try {
    const u = new URL(uri);
    const h = u.hostname.replace(/^\[|\]$/g, "");
    return { host: u.host, local: h === "localhost" || h === "::1" || /^127\./.test(h) };
  } catch {
    return { host: "", local: false };
  }
}

export const DAYS = [1, 7, 30, 90, 365] as const;
export const DEFAULT_DAYS = 30;
export const daysLabel = (d: number) => (d === 365 ? tr("1 年", "1 year") : tr(`${d} 天`, d === 1 ? "1 day" : `${d} days`));
// a server default that is not one of the choices is still a choice
// (and none past max, when the hub caps this connection)
export const dayChoices = (d: number, max?: number) =>
  ((DAYS as readonly number[]).includes(d) ? [...DAYS] : [...DAYS, d].sort((a, b) => a - b)).filter((x) => !max || x <= max);

export type Client = "claude-code" | "codex" | "gemini" | "claude-ai" | "other";
export const CLIENTS: { id: Client; name: string }[] = [
  { id: "claude-code", name: "Claude Code" },
  { id: "codex", name: "Codex" },
  { id: "gemini", name: "Gemini CLI" },
  { id: "claude-ai", name: "claude.ai" },
  { id: "other", name: tr("其他", "Other") },
];
export const clientName = (c: string) => CLIENTS.find((x) => x.id === c)?.name || c || tr("其他", "Other");

// Which of the hub's snippets an agent is shown: its own, else the generic one.
export function snippetFor(client: string, snippets: Record<string, string> | undefined): string {
  if (!snippets) return "";
  return snippets[client] || snippets.generic || "";
}

// The agents that can skip the key entirely: add the URL, sign in in a browser (OAuth).
export const OAUTH_CLIENTS: Client[] = ["claude-ai", "claude-code", "gemini"];

export type Agent = {
  id: string; name: string; client: string; kind: "pat" | "oauth"; permissions: string[]; scopes?: string[];
  created_at: string; expires_at: string; last_call_at: string | null; calls: number;
};
export type AgentList = { agents?: Agent[]; permissions?: string[]; mcp_url?: string };
export type AgentCreated = { agent: Agent; key: string; mcp_url: string; snippets?: Record<string, string> };

// expiresText: 「30 天后到期」 / 「已过期」 — whole days, never a negative one.
export function expiresText(iso: string | undefined, now = Date.now()): string {
  const t = iso ? Date.parse(iso) : NaN;
  if (!Number.isFinite(t)) return "";
  if (t <= now) return tr("已过期", "expired");
  const d = Math.ceil((t - now) / 86400000);
  return d <= 1 ? tr("1 天内到期", "expires within a day") : tr(`${d} 天后到期`, `expires in ${d} days`);
}

// The consent page's query: the hub's /oauth/authorize sent the browser here
// with the whole OAuth request; it is read back and approved VERBATIM — never
// re-encoded, so the hub checks the very string it handed out.
export const rawQuery = (search: string) => search.replace(/^\?/, "");
