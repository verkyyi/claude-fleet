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
  const a = r.task?.actual_agent || r.task?.resolved_agent || r.task?.agent || "";
  return AGENT[a] || a;
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

// rowMeta: the one line of detail a hover, a long-press and the session's own
// top share — code · machine · agent · where it runs · how long.
export function rowMeta(r: Row, now = Date.now()): string {
  const where = r.live ? tr("在终端里", "in a terminal") : r.group === "gone" ? tr("已结束", "ended") : "";
  return [r.code, rowMachine(r), rowAgent(r), where, r.live ? openFor(r.live.born * 1000, now) : ""].filter(Boolean).join(" · ");
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
