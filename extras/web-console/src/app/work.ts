// work.ts — 会话's one list (T769): the person's task records (/v1/fleet/tasks)
// and their sessions (/v1/fleet/sessions, live and the last 14 days' ended)
// joined into rows, a task and its session ONE row — by the session's identity
// (worker_id), never a name or a key; a session no record names is a row of
// its own. Grouped as ⌘P's panel groups them (bin/fleet_view.py group_of):
// 等你 · 在干活 · 排队中 · 已收起. A task's state is the hub's authority
// (taskStatus), its session's word only what the session says now — neither is
// inferred from the other (claude-fleet T644/C4: a session done is not a task
// succeeded). Pure: no React, so test/work.mjs runs it as it is.
import type { Board, BoardRow, SessionRow } from "@/shared/sessions";
import { displayCodes, taskOpen, taskPR, taskStatus, writtenCode, type Task } from "./task-state.ts"; // .ts: test/work.mjs runs this file as it is

export type Group = "pin" | "ask" | "work" | "queue" | "gone";
export type Tone = "ask" | "fail" | "ok" | "muted";
export type WhyTone = "grey" | "orange" | "red";
export type Glyph = "ask" | "fail" | "work" | "pr" | "done" | "idle" | "wait";

export type Row = {
  id: string;             // the task's ID, else the session's identity
  code: string;           // the task's display code ("" = a session with no record)
  title: string;
  group: Group;
  tag: [string, string];  // the state, 中文 / English
  glyph: Glyph;
  tone: Tone;
  line: string;           // the last word: what it asks, what it is doing, its report
  quote: boolean;         // line is its own words to you (shown in quotes)
  task?: Task;
  live?: SessionRow;
  ended?: SessionRow;
  parent?: string;        // the parent task's ID
  parentTitle?: string;
  kids: Row[];            // an EPIC's members (every one, whatever their group)
  at: number;             // epoch ms: newest first within a group
  board?: BoardRow;       // the hub's row this one draws (A4G2)
  why?: [string, string]; // why it is still open, 中文 / English (E101 — the hub's words)
  whyTone?: WhyTone;
  // 会话合一 (Y01K): web = a chat session the web opened, terminal = a terminal's
  // (an older hub says neither); canTalk: the web may talk to it (absent: unknown)
  origin?: "web" | "terminal";
  canTalk?: boolean;
};

export const GROUPS: { g: Group; label: [string, string] }[] = [
  { g: "pin", label: ["置顶", "Pinned"] },
  { g: "ask", label: ["等你", "Needs you"] },
  { g: "work", label: ["在干活", "Working"] },
  { g: "queue", label: ["待派发 / 保留", "Pending / retained"] },
  { g: "gone", label: ["已收起", "Put away"] },
];

const ms = (iso?: string) => { const t = iso ? Date.parse(iso) : NaN; return Number.isFinite(t) ? t : 0; };

// The person's own words for a task: a dispatch's request (title / body, as the
// write door accepted it), else its title.
export function taskWords(t: Task): string {
  try {
    const p = JSON.parse(t.request_payload || "{}")?.params || {};
    const body = typeof p.body === "string" ? p.body.trim() : "";
    const title = typeof p.title === "string" ? p.title.trim() : "";
    if (body) return title && !body.startsWith(title) ? `${title}\n\n${body}` : body;
    if (title) return title;
  } catch { /* the title below */ }
  return t.title;
}

// One task (or a session no record names) → its row.
export function rowOf(t: Task | undefined, live: SessionRow | undefined, ended: SessionRow | undefined, code: string): Row {
  const st = t ? taskStatus(t) : "";
  const s = live?.state || "";
  const pr = t ? taskPR(t) : null;
  const at = live?.born ? live.born * 1000 : ended?.ended ? ms(ended.ended) : ms(t?.created_at);
  const base = { id: t?.fid || t?.id || live?.id || ended?.wid || ended?.id || "", code, title: t?.title || live?.title || ended?.title || "",
    task: t, live, ended, parent: t?.parent_task || undefined, kids: [] as Row[], quote: false, at,
    ...(live?.origin ? { origin: live.origin } : {}), ...(typeof live?.canTalk === "boolean" ? { canTalk: live.canTalk } : {}) };
  const say = (x?: string) => (x || "").trim();
  // A live session's current native observation stands independently of a
  // previous task outcome. Keep the outcome on the task for history/details.
  if (s === "needs" || s === "blocked")
    return { ...base, group: "ask", tag: ["在问你", "Asking you"], glyph: "ask", tone: "ask", line: say(live?.ask?.msg), quote: true };
  if (s === "working" || s === "looping")
    return { ...base, group: "work", tag: ["在干活", "Working"], glyph: "work", tone: "ok", line: say(live?.say) };
  // 排队中: open, waiting on something that is not you
  if (live) {
    if (pr && t?.pr_state === "waiting") return { ...base, group: "queue", tag: ["等合并", "Awaiting merge"], glyph: "pr", tone: "muted", line: say(t.evidence) };
    if (s === "done") return { ...base, group: "queue", tag: ["本轮结束", "Turn ended"], glyph: "done", tone: "muted", line: say(t?.evidence) };
    if (s === "idle") return { ...base, group: "queue", tag: ["空闲", "Idle"], glyph: "idle", tone: "muted", line: "" };
    return { ...base, group: "queue", tag: ["状态未知", "Unknown"], glyph: "idle", tone: "muted", line: "" };
  }
  if (st === "failed" || st === "refused")
    return { ...base, group: "ask", tag: st === "failed" ? ["没做成", "Failed"] : ["没开成", "Didn't start"], glyph: "fail", tone: "fail", line: say(t?.evidence) };
  if (t && t.asked && taskOpen(t))
    return { ...base, group: "ask", tag: ["在等你", "Waiting on you"], glyph: "ask", tone: "ask", line: say(t.asked), quote: true };
  if (t && taskOpen(t)) {
    const tag: [string, string] = st === "starting" ? ["正在开", "Starting"] : st === "accepted" && !t.operation_id && !t.worker_id ? ["未派发", "Not dispatched"]
      : st === "running" || st === "waiting" || !!t.operation_id || !!t.worker_id ? ["看不到会话", "Session not seen"] : ["还不清楚", "Unknown"];
    return { ...base, group: "queue", tag, glyph: "wait", tone: "muted", line: say(t.evidence) };
  }
  // 已收起: the record closed, or a session put away
  const tag: [string, string] = st === "succeeded" ? ["已完成", "Completed"] : st === "cancelled" ? ["已取消", "Cancelled"] : ["已收起", "Put away"];
  return { ...base, group: "gone", tag, glyph: st === "succeeded" ? "done" : "idle", tone: st === "succeeded" ? "ok" : "muted", line: say(t?.evidence) };
}

// The one list: every task joined to its session by identity, every session no
// record names a row of its own; an EPIC's members listed under it (`kids`),
// and shown nested while they sit in the parent's group — in their own group
// otherwise, naming the parent (rowsIn).
export function buildRows(tasks: Task[], live: SessionRow[], ended: SessionRow[]): Row[] {
  const codes = displayCodes(tasks);
  const liveBy = new Map(live.map((r) => [r.id, r]));
  const endedBy = new Map(ended.filter((r) => r.wid).map((r) => [r.wid!, r]));
  const used = new Set<string>();
  const rows: Row[] = tasks.map((t) => {
    const l = t.worker_id ? liveBy.get(t.worker_id) : undefined;
    const e = !l && t.worker_id ? endedBy.get(t.worker_id) : undefined;
    if (t.worker_id) used.add(t.worker_id);
    return rowOf(t, l, e, codes.get(t) || writtenCode(t));
  });
  for (const l of live) if (!used.has(l.id)) rows.push(rowOf(undefined, l, undefined, ""));
  for (const e of ended) if (!used.has(e.wid || "")) rows.push(rowOf(undefined, undefined, e, ""));
  const byID = new Map(rows.filter((r) => r.task?.fid).map((r) => [r.task!.fid!, r]));
  for (const r of rows) {
    const p = r.parent ? byID.get(r.parent) : undefined;
    if (p && p !== r) { r.parentTitle = p.title; p.kids.push(r); }
    else r.parent = undefined;
  }
  return rows.sort((a, b) => b.at - a.at);
}

// The hub's one list (A4G2) → the page's rows: the hub's rows, groups, order
// and words as they are — the same the ⌘P panel draws; each joined to its
// record (by the record's ID) and its live session (by worker_id) only for the
// detail beside it. An EPIC's members sit under their parent (the hub's parent).
// E101: parked (停放, waiting on you, its window closed) is a clock in the ask
// colour; stopped (its agent's error stopped it) a red cross.
const GLYPH_OF: Record<string, Glyph> = {
  asking: "ask", waiting_you: "ask", failed: "fail", refused: "fail", working: "work", looping: "work",
  retained_completed: "done", completed: "done", turn_done: "done", ended: "done", starting: "wait", queued: "wait", not_seen: "wait",
  parked: "wait", stopped: "fail",
};
const TONE_OF: Record<string, Tone> = {
  asking: "ask", waiting_you: "ask", failed: "fail", refused: "fail", working: "ok", looping: "ok", completed: "ok",
  parked: "ask", stopped: "fail",
};
export function boardRows(board: Board, tasks: Task[], live: SessionRow[], _ended: SessionRow[] = []): Row[] {
  const codes = displayCodes(tasks);
  const byFID = new Map(tasks.filter((t) => t.fid).map((t) => [t.fid!, t]));
  const byRef = new Map(tasks.map((t) => [t.id, t]));
  const liveBy = new Map(live.map((l) => [l.id, l]));
  const rows: Row[] = board.rows.map((b: BoardRow) => {
    const t = (b.task_id && byFID.get(b.task_id)) || (b.task && byRef.get(b.task)) || undefined;
    const l = b.worker_id ? liveBy.get(b.worker_id) : undefined;
    // The hub resolves the closed generation by FID, never by a recycled key.
    const h = !l ? b.history : undefined;
    const e: SessionRow | undefined = h?.resume_id ? {
      id: h.resume_id, ident: h.id, wid: `fid:${h.id}`, key: "", title: b.title,
      repo: b.repo || "", machine: b.machine || "", state: "ended", group: "ended",
      ask: null, born: 0, ended: new Date(b.at * 1000).toISOString(), tokens: 0,
    } : undefined;
    const asking = b.tag === "asking" || b.tag === "waiting_you";
    const line = asking ? (l?.ask?.msg || t?.asked || "").trim() : b.group === "work" ? (l?.say || "").trim() : (t?.evidence || "").trim();
    const why = Array.isArray(b.why) && b.why.length === 2 ? b.why : undefined;
    const origin = b.origin || l?.origin;
    const canTalk = typeof b.can_talk === "boolean" ? b.can_talk : l?.canTalk;
    // a web session parked (会话合一: idle 5 minutes, its process put away) reads as
    // any idle one — no mark of its own; a word to it brings it back
    const quiet = b.tag === "parked" && origin === "web";
    return {
      id: b.id, code: t ? codes.get(t) || writtenCode(t) : b.code || "", title: b.title, group: b.group,
      tag: quiet ? ["空闲", "Idle"] : b.words, glyph: quiet ? "idle" : GLYPH_OF[b.tag] || "idle", tone: quiet ? "muted" : TONE_OF[b.tag] || "muted",
      line, quote: asking && !!line,
      task: t, live: l, ended: e, parent: b.parent || undefined, kids: [], at: b.at * 1000, board: b,
      why: quiet ? undefined : why, whyTone: why && !quiet ? b.why_tone || "grey" : undefined,
      ...(origin ? { origin } : {}), ...(typeof canTalk === "boolean" ? { canTalk } : {}),
    };
  });
  const byID = new Map(rows.map((r) => [r.id, r]));
  for (const r of rows) {
    const p = r.parent ? byID.get(r.parent) : undefined;
    if (p && p !== r) { r.parentTitle = p.title; p.kids.push(r); } else r.parent = undefined;
  }
  return rows;
}

// A group's rows, top level: a member nested under its parent leaves the top.
export function rowsIn(rows: Row[], g: Group): Row[] {
  const byID = new Map(rows.map((r) => [r.id, r]));
  return rows.filter((r) => r.group === g && !(r.parent && byID.get(r.parent)?.group === g));
}

// The members shown under a parent: those in its own group.
export const nestedKids = (r: Row) => r.kids.filter((k) => k.group === r.group);

// Finds a row by what a link names: its code (display or written), the task's
// ID or old T<n>, or a session's identity.
export function findRow(rows: Row[], ref: string): Row | undefined {
  const q = ref.trim().replace(/^#/, "");
  if (!q) return undefined;
  const up = q.toUpperCase();
  return rows.find((r) => r.id === q || r.code.toUpperCase() === up || (r.task && (writtenCode(r.task).toUpperCase() === up || r.task.id === q))
    || r.live?.id === q || r.live?.ident === q || r.ended?.wid === q || (!!r.board?.worker_id && r.board.worker_id === q));
}

// ✦ 消息: what this page holds for the person to hear — asks, failures, and
// what finished in the last day (the panel's one book is not on the hub yet).
export type Message = { row: Row; kind: "ask" | "fail" | "done" };
export function messagesOf(rows: Row[], now = Date.now()): Message[] {
  const out: Message[] = [];
  for (const r of rows) {
    if (r.group === "ask") out.push({ row: r, kind: r.tone === "fail" ? "fail" : "ask" });
    // a record that failed with no session left sits in 已收起 (A4G2): said for a day
    else if (r.tone === "fail" && now - r.at < 864e5) out.push({ row: r, kind: "fail" });
    else if (r.task && taskStatus(r.task) === "succeeded" && now - ms(r.task.updated_at || r.task.created_at) < 864e5) out.push({ row: r, kind: "done" });
  }
  return out;
}
