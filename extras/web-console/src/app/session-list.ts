// Task-list presentation: one status slot, PIN/ordinary/history ordered by recent conversation activity.
// Native facts stay in the shared board; old-hub fallbacks never invent a request.
import { tr } from "../shared/i18n.ts"; // .ts: the test runs this file as it is
import { taskStatus, writtenCode } from "./task-state.ts";
import type { Glyph, Row, Tone } from "./work.ts";

// What a list row draws — exactly this, the test holds it to these keys.
export type ListItem = { ref: string; glyph: Glyph; tone: Tone; title: string; bold: boolean };

// PIN is the only group heading. Old board group ordering must not move a
// task solely because its status changes. New turn activity reorders ordinary
// rows; older parent/member records are flat too.
export type ListGroups = { pin: Row[]; open: Row[]; gone: Row[] };
export function listRows(rows: Row[], previous?: ListGroups): ListGroups {
  const activity = (r: Row) => r.board?.activity_at ? r.board.activity_at * 1000 : r.at;
  const recent = [...rows].sort((a, b) => activity(b) - activity(a) || a.id.localeCompare(b.id));
  const older = (r: Row) => r.group === "gone" && !r.live && !listStatus(r).kind && !listStatus(r).unknown;
  const keep = (next: Row[], before: Row[] = []) => {
    const byID = new Map(next.map((r) => [r.id, r]));
    const known = new Set(before.map((r) => r.id));
    return [...next.filter((r) => !known.has(r.id)), ...before.flatMap((r) => byID.has(r.id) ? [byID.get(r.id)!] : [])];
  };
  return { pin: keep(rows.filter((r) => r.group === "pin"), previous?.pin),
    open: recent.filter((r) => r.group !== "pin" && !older(r)),
    gone: recent.filter(older) };
}

export type SessionListPreferences = { max_visible: number; idle_hours: number };
export const DEFAULT_LIST_PREFERENCES: SessionListPreferences = { max_visible: 10, idle_hours: 24 };
export function listPreferences(value?: Partial<SessionListPreferences> | null): SessionListPreferences {
  return { max_visible: [5, 10, 15].includes(value?.max_visible ?? 0) ? value!.max_visible! : 10,
    idle_hours: [0, 12, 24, 72].includes(value?.idle_hours ?? -1) ? value!.idle_hours! : 24 };
}
export const needsAttention = (r: Row) => listStatus(r).kind === "ask" ||
  (!listStatus(r).unknown && r.group !== "gone" &&
    ((r.live?.state || r.board?.state) === "failed" || r.board?.why_tone === "red" || r.board?.tag === "failed" || r.board?.tag === "refused"));
export type CompactGroups = ListGroups;
// One order: PIN, then everything by recent activity (task DDBQ). A row that
// needs the person is not lifted into a group of its own — entering needs is
// itself activity — but it is never folded into More either.
export function compactRows(rows: Row[], options: { current?: string; preferences?: Partial<SessionListPreferences>;
  now?: number; previous?: CompactGroups; interacting?: boolean } = {}): CompactGroups {
  const { current = "", now = Date.now(), previous, interacting = false } = options;
  const prefs = listPreferences(options.preferences);
  const base = listRows(rows, previous);
  const isCurrent = (r: Row) => rowRef(r) === current;
  const pin = base.pin;
  const recent = [...base.open, ...base.gone].sort((a, b) =>
    (b.board?.activity_at ? b.board.activity_at * 1000 : b.at) - (a.board?.activity_at ? a.board.activity_at * 1000 : a.at) || a.id.localeCompare(b.id));
  const kept = recent.filter((r) => isCurrent(r) || needsAttention(r));
  let room = Math.max(0, prefs.max_visible - pin.length - kept.length);
  const old = new Set(base.gone.map((r) => r.id));
  const visible = new Set(kept.map((r) => r.id));
  for (const r of recent) {
    if (visible.has(r.id) || old.has(r.id) || room <= 0) continue;
    const at = r.board?.activity_at ? r.board.activity_at * 1000 : r.at;
    const status = listStatus(r);
    if (!prefs.idle_hours || !at || status.kind === "work" || status.kind === "pending" || now - at < prefs.idle_hours * 3600000) {
      visible.add(r.id); room--;
    }
  }
  const next: CompactGroups = { pin, open: recent.filter((r) => visible.has(r.id)), gone: recent.filter((r) => !visible.has(r.id)) };
  // Keep row positions and membership while someone is pointing or navigating.
  // Refresh facts by identity, including removals; new rows wait in More.
  if (interacting && previous && (!current || [...previous.pin, ...previous.open].some(isCurrent))) {
    const byID = new Map(rows.map((r) => [r.id, r]));
    const used = new Set<string>();
    const refresh = (before: Row[]) => before.flatMap((r) => {
      const fresh = byID.get(r.id);
      if (!fresh) return [];
      used.add(r.id); return [fresh];
    });
    const stable = { pin: refresh(previous.pin), open: refresh(previous.open), gone: refresh(previous.gone) };
    stable.gone.push(...rows.filter((r) => !used.has(r.id)));
    return stable;
  }
  return next;
}

export type ListStatus = { kind: "ask" | "pending" | "work" | "loop" | null; words: [string, string][]; unknown: boolean };
// One fixed slot, priority: answer > accepted execution > running > Loop.
// No-session is never evidence of a pending execution request.
export function listStatus(r: Row): ListStatus {
  const tag = r.board?.tag;
  const state = r.live?.state || r.board?.state;
  const unknown = !!r.board?.lost || state === "unknown" || tag === "not_seen";
  const ask = !unknown && (state === "needs" || state === "blocked");
  const status = r.task ? taskStatus(r.task) : "";
  const started = ["working", "looping", "needs", "blocked", "done"].includes(state || "");
  const pending = typeof r.board?.pending_start === "boolean" ? r.board.pending_start
    : !unknown && !started && !r.task?.cancel_request
      && (r.board ? tag === "starting" : status === "starting");
  const work = !unknown && (typeof r.board?.running === "boolean" ? r.board.running
    : state === "working" || tag === "working" || (!r.board && !r.live && r.glyph === "work"));
  const loop = r.board?.loop === true;
  const words: [string, string][] = [];
  if (ask) words.push(["需要回答", "Needs your answer"]);
  if (pending) words.push(["待启动", "Waiting to start"]);
  if (work) words.push(["运行中", "Running"]);
  if (loop) words.push(["Loop 中", "Loop enabled"]);
  if (unknown) words.push(["运行情况未知", "Execution status unknown"]);
  return { kind: unknown ? null : ask ? "ask" : pending ? "pending" : work ? "work" : loop ? "loop" : null, words, unknown };
}
export const listStatusLabel = (r: Row) => listStatus(r).words.map((w) => tr(...w)).join(" · ");

// Task routes use the Task FID (legacy T<n> when absent). Session-only rows
// retain their own code or identity; a continuation never changes the Task URL.
export const rowRef = (r: Row) => (r.task?.fid || r.board?.task_id || r.task?.id || r.board?.task || r.code || r.id);

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
  const where = r.group === "gone" && !r.live ? tr("更早的会话", "Earlier session") : "";
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
// title, its machine, including folded historical records.
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
