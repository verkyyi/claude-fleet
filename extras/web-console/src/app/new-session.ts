// new-session.ts — the new-session screen's rules (GR5E C3): what a person
// picks (对话 | 终端 · Claude Code | Codex | 只开 Shell · a machine · a line),
// what is remembered of it, which machines a start can go to, why it cannot
// start now, the one write a terminal start is, and the row it became. Pure:
// no React, so test/new-session.mjs runs it as it is.
import { tr } from "../shared/i18n.ts"; // .ts: the test runs this file as it is
import type { Row } from "./work.ts";

export type Mode = "chat" | "term";
export type Agent = "claude" | "codex" | "shell";
export type Choice = { mode: Mode; agent: Agent; machine: string }; // machine "" = the home

// startSession's one shape (the design page's interface): what the screen hands on.
export type Start = Choice & { words: string };

export const AGENTS: Record<Mode, Agent[]> = { chat: ["claude", "codex"], term: ["claude", "codex", "shell"] };

// A choice that holds: 只开 Shell is the terminal's only; a chat runs on the home only.
export function fixChoice(c: Partial<Choice> | null | undefined, defaultAgent: Agent = "claude"): Choice {
  const mode: Mode = c?.mode === "term" ? "term" : "chat";
  const agent: Agent = AGENTS[mode].includes(c?.agent as Agent) ? (c!.agent as Agent) : defaultAgent === "codex" ? "codex" : "claude";
  const machine = mode === "term" && agent !== "shell" && typeof c?.machine === "string" ? c.machine : "";
  return { mode, agent, machine };
}

// What is remembered of the last start (this browser): the choice, never the words.
export const CHOICE_KEY = "fleet.console.new";
export function readChoice(raw: string | null, defaultAgent?: Agent): Choice {
  let saved: Partial<Choice> | null = null;
  try { saved = JSON.parse(raw || "null"); } catch { /* use the default */ }
  // A changed team default applies to the next start, including browsers that
  // remember the old default. A choice made in this open form still wins.
  const agent = defaultAgent === "claude" || defaultAgent === "codex" ? defaultAgent : undefined;
  return fixChoice(agent ? { ...saved, agent } : saved);
}

// The home, as /v1/chat/home answers it.
export type Home = { machine?: string; login?: string; state: string; why?: string; models?: ChatModel[] };

// A model a chat may ask for besides its agent's own (task J7BN): DeepSeek,
// the mainland region's — offered only when /v1/chat/home lists it (the person
// on the trial list, a cn cluster up). A DeepSeek session is Claude Code with
// that model, placed by the hub on a mainland machine, never on the home.
export type ChatModel = { id: string; label: string };
const CHAT_MODEL_IDS = new Set(["deepseek", "deepseek-pro"]);
export function modelsOf(home: Home | null): ChatModel[] {
  return (home?.models || []).filter((m) => !!m && CHAT_MODEL_IDS.has(m.id) && typeof m.label === "string" && !!m.label);
}
// The model a choice holds: one the home offers, else "" (the agent's own).
export const fixModel = (model: string, home: Home | null) => modelsOf(home).some((m) => m.id === model) ? model : "";
// /v1/chat/open's body: a model goes with agent claude; none is the agent's own, as before.
export function openBody(agent: "claude" | "codex", model: string, words: string): Record<string, string> {
  const w = words.trim();
  return { ...(model ? { agent: "claude", model } : { agent }), ...(w ? { text: w } : {}) };
}
export const hasHome = (h: Home | null): h is Home & { machine: string } => !!h?.machine && h.state !== "no_home";

// The person's machines a session can open on (/v1/nodes): their own logins
// on it, never a client computer or a machine's link row; the home first. A
// machine is shown by its own name (its hostname) — the roster's alias is the
// operator's ssh shorthand (h1, h2), a word the person never chose (task WD8F).
export const machineName = (hostname: string) => hostname.split(".")[0] || hostname;
type Node = { hostname: string; os_user: string; status: string; machine_link?: boolean; compute_off?: boolean };
type Nodes = { nodes?: Node[]; machines?: { hostname: string; alias?: string; role?: string }[] };
export type Machine = { hostname: string; label: string; state: "on" | "maint" | "lost"; home: boolean };
const same = (a: string, b: string) => a.toLowerCase().split(".")[0] === b.toLowerCase().split(".")[0];

export function machinesOf(snap: Nodes | null, logins: { machine: string; login: string }[] | undefined, home: Home | null): Machine[] {
  const client = new Set((snap?.machines || []).filter((m) => m.role === "client").map((m) => m.hostname));
  const by = new Map<string, Node[]>();
  for (const n of snap?.nodes || []) {
    if (n.machine_link || n.compute_off || client.has(n.hostname)) continue;
    if (logins?.length && !logins.some((p) => p.machine === n.hostname && p.login === n.os_user)) continue;
    by.set(n.hostname, [...(by.get(n.hostname) || []), n]);
  }
  const out: Machine[] = [...by.entries()].map(([hostname, ns]) => ({
    hostname, label: machineName(hostname),
    state: ns.some((n) => n.status !== "lost" && n.status !== "maintenance") ? "on" : ns.some((n) => n.status === "maintenance") ? "maint" : "lost",
    home: hasHome(home) && same(hostname, home.machine),
  }));
  if (hasHome(home) && !out.some((m) => m.home)) {
    out.push({ hostname: home.machine, label: machineName(home.machine), state: home.state === "ok" ? "on" : home.state === "maintenance" ? "maint" : "lost", home: true });
  }
  return out.sort((a, b) => Number(b.home) - Number(a.home) || a.label.localeCompare(b.label));
}

// Where a choice opens: a chat and the Shell on the home, always; an agent in
// a terminal on the machine picked, else the home.
export function targetOf(c: Choice, machines: Machine[]): Machine | null {
  if (c.mode === "term" && c.agent !== "shell" && c.machine) {
    const m = machines.find((x) => same(x.hostname, c.machine));
    if (m) return m;
  }
  return machines.find((m) => m.home) || null;
}

// Why it cannot start now — said under the cards — or "" when it can.
export function blocker(c: Choice, machines: Machine[], home: Home | null): string {
  const t = targetOf(c, machines);
  if (!t) {
    if (c.mode === "term" && c.agent !== "shell" && machines.length) return "";
    return home?.why || tr("你还没有家：家是你有登录、上面开着 fleet 的那台机器。先在一台机器上把 fleet 开起来，再回来新建。",
      "You have no home yet: it is a machine with your login and fleet running on it. Start fleet on one, then come back.");
  }
  // the home's own word wins for the home (the chat's service answers there)
  const st = t.home && home?.state ? home.state : t.state === "on" ? "ok" : t.state === "maint" ? "maintenance" : "offline";
  if (st === "maintenance") return t.home
    ? tr(`你的家 ${t.label} 正在维护，维护结束后就能开。`, `Your home ${t.label} is under maintenance; you can start once it is done.`)
    : tr(`${t.label} 正在维护，换一台或等它结束。`, `${t.label} is under maintenance; pick another or wait.`);
  if (st === "offline" || st === "home_down") return t.home
    ? tr(`你的家 ${t.label} 现在连不上。${c.mode === "chat" ? "对话" : c.agent === "shell" ? "Shell" : "会话"}只在它连着时能开，它一上线就行。`,
      `Your home ${t.label} is unreachable. ${c.mode === "chat" ? "A chat" : c.agent === "shell" ? "The shell" : "A session"} opens only while it is connected — as soon as it is back.`)
    : tr(`${t.label} 现在连不上，换一台机器。`, `${t.label} is unreachable; pick another machine.`);
  if (st === "old_agent" && c.mode === "chat") return tr(`你的家 ${t.label} 上的 fleet 太旧，还不能开对话。更新后再来。`,
    `fleet on your home ${t.label} is too old for a chat. Update it, then come back.`);
  return "";
}

// A terminal session with an agent: one task through the write door, the
// same road 会话's 新建 takes (worker_start with a coding agent — the hub writes
// the record first). No words is a plain session that waits for its first line.
export function startArgs(c: Choice, words: string, target: Machine | null, idem: string): Record<string, unknown> {
  const w = words.trim();
  return {
    kind: "scratch", no_repo: true, coding_agent: c.agent, idempotency_key: idem,
    ...(w ? { body: w } : {}),
    ...(target ? { node: target.hostname } : {}),
  };
}

// The row a start became: the task record the hub wrote for this idempotency
// key (its dispatch's request_id — the record is written before the start is
// placed, so it is in the list at once).
export function rowForRequest(rows: Row[] | null, idem: string): Row | null {
  for (const r of rows || []) {
    try {
      const p = JSON.parse(r.task?.request_payload || "{}")?.params || {};
      if (p.dispatch?.request_id === idem) return r;
    } catch { /* not this one */ }
  }
  return null;
}

// The box's Enter (task WD8F): Enter sends and Shift+Enter is a new line, as in
// every chat — but never mid-IME (a pinyin candidate's Enter picks the word), and
// on a phone (a coarse pointer, no fine one) Enter stays a new line: the button sends.
export const TOUCH_PRIMARY = "(pointer: coarse) and (not (any-pointer: fine))";
export function sendsOnEnter(e: { key: string; shiftKey?: boolean; isComposing?: boolean; keyCode?: number }, touch: boolean): boolean {
  if (e.key !== "Enter" || e.shiftKey || touch) return false;
  return !e.isComposing && e.keyCode !== 229;
}

// 会话合一 (Y01K): why a chat cannot start now — the home's own word, never its
// name (nearly everyone has one) — or "" when it can. A DeepSeek model (J7BN)
// never runs on the home: the home's state does not stop it.
export function chatBlocker(home: Home | null, model = ""): string {
  if (model && fixModel(model, home)) return "";
  if (!hasHome(home)) return home?.why || tr("你还没有家：家是你有登录、上面开着 fleet 的那台机器。先在一台机器上把 fleet 开起来，再回来新建。",
    "You have no home yet: it is a machine with your login and fleet running on it. Start fleet on one, then come back.");
  if (home.state === "offline" || home.state === "home_down") return tr("家机器暂时连不上 · 家机器连回来后才能发", "Your machine is out of reach · send once it is back");
  if (home.state === "maintenance") return tr("家机器正在维护，维护结束后就能开。", "Your machine is under maintenance; you can start once it is done.");
  if (home.state === "old_agent") return tr("家机器上的 fleet 太旧，还不能开对话。更新后再来。", "fleet on your machine is too old for a chat. Update it, then come back.");
  return "";
}

// The row a chat opened became (会话合一 Y01K): /v1/chat/open answers its window's
// identity (fid) and its worker id; the list carries either.
export function rowForOpen(rows: Row[] | null, fid: string, worker: string): Row | null {
  return (rows || []).find((r) => (!!worker && (r.live?.id === worker || r.board?.worker_id === worker))
    || (!!fid && (r.live?.ident === fid || r.id === fid || !!r.board?.worker_id?.endsWith(`/${fid}`)))) || null;
}
