// session-list.ts — the session list's rules (GR5E C2): which rows the list
// draws, in what order, what a row draws (a status glyph and a title — nothing
// else), what a search finds, the one line of detail a hover / long-press /
// the session's top shows, and which rows are new to the person. The rows are
// work.ts's (the hub's one list, A4G2) as they are: no second filter, group or
// count. Pure: no React, so test/session-list.mjs runs it as it is.
import { tr } from "../shared/i18n.ts"; // .ts: the test runs this file as it is
import { writtenCode } from "./task-state.ts";
import type { Glyph, Row, Tone } from "./work.ts";

// What a list row draws — exactly this, the test holds it to these keys.
export type ListItem = { ref: string; glyph: Glyph; tone: Tone; title: string; bold: boolean };

// The list's rows: ⌘P's top-level entries in ⌘P's order (the hub's board order
// already is), an EPIC's members only inside their parent, the put-away rows
// apart — under 「已结束的会话」 at the foot.
// (A stable sort by group: a no-op on the board, the panel's order on an older
// hub's own join, which is newest first.)
const ORDER: Record<string, number> = { pin: 0, ask: 1, work: 2, queue: 3, gone: 4 };
export function listRows(rows: Row[]): { open: Row[]; gone: Row[] } {
  const top = rows.filter((r) => !r.parent).sort((a, b) => ORDER[a.group] - ORDER[b.group]);
  return { open: top.filter((r) => r.group !== "gone"), gone: top.filter((r) => r.group === "gone") };
}

// The stable name a row goes by in an address (/app/s/<ref>): its task's code,
// else its own code, else the session's identity.
export const rowRef = (r: Row) => (r.task ? writtenCode(r.task) : r.code || r.id);

export const rowMachine = (r: Row) => r.board?.machine || r.live?.machine || r.ended?.machine || r.task?.machine || "";

const AGENT: Record<string, string> = { claude: "Claude Code", codex: "Codex" };
export const rowAgent = (r: Row) => {
  if (r.board?.agent_words) return tr(...r.board.agent_words);
  // An older hub's choice is not proof of the engine that actually ran.
  const a = r.task?.actual_agent || "";
  if (a) return AGENT[a] || a;
  return tr("未知", "Unknown");
};

// How long it has been open: 开了 5 分钟 · 开了 3 小时 · 开了 2 天.
export function openFor(born: number, now = Date.now()): string {
  if (!born) return "";
  const m = Math.floor(Math.max(0, now - born) / 60000);
  if (m < 1) return tr("刚开", "just opened");
  if (m < 60) return tr(`开了 ${m} 分钟`, `open ${m} min`);
  const h = Math.floor(m / 60);
  if (h < 24) return tr(`开了 ${h} 小时`, `open ${h} h`);
  return tr(`开了 ${Math.floor(h / 24)} 天`, `open ${Math.floor(h / 24)} d`);
}

// rowMeta: the one line of detail a hover and a long-press share — code · agent
// · how long; the machine only for a person with more than one (会话合一 Y01K:
// nearly everyone has one home, and its name said nothing).
export function rowMeta(r: Row, now = Date.now(), machines = 1): string {
  const where = r.group === "gone" ? tr("已结束", "ended") : "";
  return [r.code, machines > 1 ? rowMachine(r) : "", rowAgent(r), r.board?.context ? tr(...r.board.context) : "", where, r.live ? openFor(r.live.born * 1000, now) : ""].filter(Boolean).join(" · ");
}

// How many machines the person's sessions run on: a name is shown only past one.
export function machineCount(rows: Row[] | null): number {
  return new Set((rows || []).map((r) => rowMachine(r).toLowerCase().split(".")[0]).filter(Boolean)).size;
}

// A terminal's session (>_ after its title): the hub says where it was opened;
// an older hub says nothing, and a running session there is a terminal's (the
// web's one conversation is apart). A record with no session is neither.
export const isTerminal = (r: Row) => (r.origin ? r.origin === "terminal" : !!r.live);

// The state a row says in words, beside its title and under a session's own:
// 回答中 while it answers, 新回复 when a reply came that the person has not
// opened, its ask while it waits on them, 空闲 for any open one at rest (a
// parked one too). `null`: the list says nothing for it.
export function rowState(r: Row, replied = false): [string, string] {
  if (r.board && r.group === "queue") return r.tag;
  if (r.glyph === "work") return ["回答中", "Replying"];
  if (replied) return ["新回复", "New reply"];
  if (r.group === "ask" || r.group === "gone" || r.glyph === "wait" || r.glyph === "pr") return r.tag;
  return ["空闲", "Idle"];
}
// what the list prints at a row's end: only what asks to be looked at
export function listWord(r: Row, replied = false): [string, string] | null {
  if (r.glyph === "work" || replied || r.group === "ask" || (r.board && r.group === "queue")) return rowState(r, replied);
  return null;
}

// A session's own head: its code and its state (no machine, no agent). `busy`:
// what its own stream says now, over the list's word.
export function headMeta(r: Row, busy?: boolean): string {
  const st: [string, string] = busy ? ["回答中", "Replying"] : busy === false && r.glyph === "work" ? ["空闲", "Idle"] : rowState(r);
  return [r.code, tr(...st)].filter(Boolean).join(" · ");
}

// The line that opens it in a terminal (fleet-session-cli.py `fleet open <会话>`).
export const openLine = (r: Row) => `fleet open ${r.code || r.live?.key || rowRef(r)}`;

// 新回复 (会话合一; WD8F ②): a row that was answering and is not any more — the
// ones in `next` whose glyph left "work" since `prev` (id → glyph).
export function repliesDone(prev: Record<string, string>, next: Row[]): Row[] {
  return next.filter((r) => prev[r.id] === "work" && r.glyph !== "work" && r.group !== "gone");
}

// A search finds what the row does not show: its code (shown or written), its
// title, its machine. An EPIC member that matches is listed on its own then.
export function matchRow(r: Row, q: string): boolean {
  const s = q.trim().toLowerCase().replace(/^#/, "");
  if (!s) return true;
  return [r.code, r.task ? writtenCode(r.task) : "", r.title, rowMachine(r)].join(" ").toLowerCase().includes(s);
}

export function searchRows(rows: Row[], q: string): Row[] {
  return rows.filter((r) => matchRow(r, q));
}

// New to the person: a row is bold until they open it, and again once its
// state moves on. `seen` maps a row to the mark it had when last opened.
export const seenMark = (r: Row) => `${r.tag[1]}@${r.at}`;
export const isUnread = (r: Row, seen: Record<string, string>) => seen[r.id] !== seenMark(r);

export const listItem = (r: Row, seen: Record<string, string>): ListItem =>
  ({ ref: rowRef(r), glyph: r.glyph, tone: r.tone, title: r.title, bold: isUnread(r, seen) });
