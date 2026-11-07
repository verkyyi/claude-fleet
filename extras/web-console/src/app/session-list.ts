// Task-list presentation: one status slot, PIN/ordinary/history ordered by recent conversation activity.
// Native facts stay in the shared board; old-hub fallbacks never invent a request.
import { tr } from "../shared/i18n.ts"; // .ts: the test runs this file as it is
import { taskStatus, writtenCode } from "./task-state.ts";
import type { Glyph, Row, Tone } from "./work.ts";

// What a list row draws — exactly this, the test holds it to these keys.
export type ListItem = { ref: string; glyph: Glyph; tone: Tone; title: string; bold: boolean };

// Pinned rows stay first; each section uses the last completed native turn.
// Status and inventory changes never advance conversation order.
export type ListGroups = { pin: Row[]; open: Row[]; gone: Row[] };
export function listRows(rows: Row[], _previous?: ListGroups): ListGroups {
  const activity = (r: Row) => r.board ? (r.board.activity_at || 0) * 1000 : r.at;
  const recent = [...rows].sort((a, b) => activity(b) - activity(a) || a.id.localeCompare(b.id));
  const older = (r: Row) => r.group === "gone" && !r.live && !listStatus(r).kind && !listStatus(r).unknown;
  return { pin: recent.filter((r) => r.group === "pin"),
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
// Who opened a session (task DDBQ, the hub's board.source): a person's and a
// session's (agent — it hangs under the session that opened it, the tree below)
// are the main list; one a schedule or an API caller opened has its own folded
// group, newest completed turn first, whatever its state. PIN stays on top.
export type RowSource = "agent" | "schedule" | "api";
export type GroupSource = "schedule" | "api";
export const ROW_SOURCES: GroupSource[] = ["schedule", "api"];
export const rowSource = (r: Row): RowSource | "" => {
  const s = r.board?.source;
  return s === "agent" || s === "schedule" || s === "api" ? s : "";
};
const groupSource = (r: Row): GroupSource | "" => {
  const s = rowSource(r);
  return s === "schedule" || s === "api" ? s : "";
};
export const sourceLabel = (s: GroupSource) => s === "schedule" ? tr("定时任务", "Scheduled") : tr("API 派发", "Via API");

// The session tree (子会话挂在发起会话下面): a row the hub nests — `parent` set
// beside the new `from` relation, the parent in the same rows — draws under the
// session that opened it, whatever its own group or state. Never under a
// schedule run (those live in the ⏰ card, not this list). An older hub's
// parent (an EPIC's members) carries no `from`: flat, as before.
// Duplicates fold (同名会话): siblings opened by the same session (nested under
// the same row, or both top level with the same `from`), same title, same
// source, are ONE line — the newest — with ×N; the rest leave the list (a
// search still finds them). Never a row without `from`, a pinned one, or one
// that has sessions of its own under it. `dupes`: each shown row's cluster,
// newest first; `dupOf`: every clustered row → the one shown.
export type Tree = { up: Map<string, Row>; kids: Map<string, Row[]>; dupes: Map<string, Row[]>; dupOf: Map<string, string> };
const activityOf = (r: Row) => r.board ? (r.board.activity_at || 0) * 1000 : r.at;
const ownAt = (r: Row) => r.board?.tree_at ? Math.max(r.board.tree_at * 1000, activityOf(r)) : activityOf(r);
const sameTitle = (t: string) => t.trim().replace(/\s+/g, " ").toLowerCase();
export function sessionTree(rows: Row[]): Tree {
  const byID = new Map(rows.map((r) => [r.id, r]));
  const up = new Map<string, Row>();
  for (const r of rows) {
    const p = r.board?.from && r.board.parent ? byID.get(r.board.parent) : undefined;
    if (p && p !== r && rowSource(p) !== "schedule") up.set(r.id, p);
  }
  // a cycle (never the hub's, but a cached board may be mid-change) is cut where found
  for (const r of rows) {
    for (let p = up.get(r.id), n = 0; p && n <= rows.length; p = up.get(p.id), n++)
      if (p === r) { up.delete(r.id); break; }
  }
  const parents = new Set([...up.values()].map((p) => p.id));
  const clusters = new Map<string, Row[]>();
  for (const r of rows) {
    if (!r.board?.from || r.group === "pin" || parents.has(r.id)) continue;
    const key = [up.get(r.id)?.id ?? "", r.board.from, sameTitle(r.title), rowSource(r)].join("\t");
    (clusters.get(key) ?? clusters.set(key, []).get(key)!).push(r);
  }
  const dupes = new Map<string, Row[]>();
  const dupOf = new Map<string, string>();
  for (const c of clusters.values()) {
    if (c.length < 2) continue;
    c.sort((a, b) => ownAt(b) - ownAt(a) || a.id.localeCompare(b.id));
    dupes.set(c[0].id, c);
    for (const r of c) dupOf.set(r.id, c[0].id);
  }
  const kids = new Map<string, Row[]>();
  for (const r of rows) {
    const p = up.get(r.id);
    if (p && (dupOf.get(r.id) ?? r.id) === r.id) (kids.get(p.id) ?? kids.set(p.id, []).get(p.id)!).push(r);
  }
  const tree = { up, kids, dupes, dupOf };
  const at = treeAt(tree);
  for (const k of kids.values()) k.sort((a, b) => at(b) - at(a) || a.id.localeCompare(b.id));
  return tree;
}
const NO_TREE: Tree = { up: new Map(), kids: new Map(), dupes: new Map(), dupOf: new Map() };
// A duplicate folded into another line: off the list, still searched.
export const foldedDup = (tree: Tree, r: Row) => (tree.dupOf.get(r.id) ?? r.id) !== r.id;
// The rows a line stands for: itself, or its whole cluster.
export const members = (tree: Tree, r: Row) => tree.dupes.get(r.id) || [r];
// The status a folded line draws: the most urgent of its cluster — asking >
// working > the line's own.
export function urgentOf(tree: Tree, r: Row): Row {
  const c = members(tree, r);
  return c.find((x) => listStatus(x).kind === "ask") || c.find((x) => listStatus(x).kind === "work") || r;
}
// A tree's activity (epoch ms): the hub's tree_at, else the row's own; never
// older than anything nested under it.
export function treeAt(tree: Tree): (r: Row) => number {
  const memo = new Map<string, number>();
  const at = (r: Row): number => {
    const m = memo.get(r.id);
    if (m !== undefined) return m;
    memo.set(r.id, activityOf(r)); // a guard while it is worked out
    const v = Math.max(ownAt(r), ...(tree.kids.get(r.id) || []).map(at));
    memo.set(r.id, v);
    return v;
  };
  return at;
}
// Shared by ordering, the five-character column and the narrow-screen detail.
export function activityLabel(at: number, now = Date.now(), detail = false): string {
  if (!at || !Number.isFinite(at)) return detail ? "" : "—";
  const age = Math.max(0, Math.floor((now - at) / 1000));
  if (age < 60) return tr("刚刚", "now");
  if (detail) {
    if (age < 3600) return tr(`${Math.floor(age / 60)}分钟前`, `${Math.floor(age / 60)} min ago`);
    if (age < 86400) return tr(`${Math.floor(age / 3600)}小时前`, `${Math.floor(age / 3600)} h ago`);
    return tr(`${Math.floor(age / 86400)}天前`, `${Math.floor(age / 86400)} d ago`);
  }
  if (age < 3600) return tr(`${Math.floor(age / 60)}分`, `${Math.floor(age / 60)}m`);
  if (age < 86400) return tr(`${Math.floor(age / 3600)}时`, `${Math.floor(age / 3600)}h`);
  const d = new Date(at), n = new Date(now);
  const day = (x: Date) => Date.UTC(x.getFullYear(), x.getMonth(), x.getDate()) / 86400000;
  const days = day(n) - day(d);
  if (days === 1) return tr("昨天", "Yest");
  if (days < 7) return tr(`周${"日一二三四五六"[d.getDay()]}`, ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d.getDay()]);
  return `${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}
export const lastActive = (at: number, now = Date.now()) => {
  const age = activityLabel(at, now, true);
  return age ? tr(`最后活跃 ${age}`, `Last active ${age}`) : "";
};

// Archives are flat, ordered by the same tree activity as the main list.
export function archivedRows(rows: Row[]): Row[] {
  const at = treeAt(sessionTree(rows));
  return [...rows].sort((a, b) => at(b) - at(a) || a.id.localeCompare(b.id));
}
// Everything nested under r, depth first, siblings newest first (a folded
// duplicate is its line's, not a row of its own).
export function descendants(tree: Tree, r: Row): Row[] {
  return (tree.kids.get(r.id) || []).flatMap((k) => [k, ...descendants(tree, k)]);
}
// Roots with their subtrees, depth first: the order a group's rows are drawn in.
export const withKids = (tree: Tree, roots: Row[]) => roots.flatMap((r) => [r, ...descendants(tree, r)]);
const depthIn = (tree: Tree, r: Row) => { let d = 0; for (let p = tree.up.get(r.id); p; p = tree.up.get(p.id)) d++; return d; };

// What a set of hidden rows says on the line that hides them — asking the
// person over working over nothing: the ▸ / chevron's colour, the (N)'s.
export type Signal = "ask" | "work" | "";
export const signalOf = (tree: Tree, rows: Row[]): Signal => {
  const all = rows.flatMap((x) => members(tree, x));
  return all.some(needsAttention) ? "ask" : all.some((x) => listStatus(x).kind === "work") ? "work" : "";
};

// One drawn line of the tree: at most two steps in (deeper drawn at two).
// `kids` its direct children; collapsed, `hidden` how many under it are not
// drawn and `signal` what the hidden ones say (the ▸ in clay or green).
export type TreeLine = { r: Row; depth: number; kids: number; open: boolean; hidden: number; signal: Signal };
// Folded unless the person opened it (`opened`, kept in this browser):
// collapsed hides everything under it — asking too; the line says so by
// colour. Only the session open now stays drawn (待处理 · N reaches a hidden
// ask that way), at its own depth.
export function treeLines(roots: Row[], tree: Tree, opened: Record<string, boolean> = {}, current = ""): TreeLine[] {
  const out: TreeLine[] = [];
  const visit = (r: Row, depth: number) => {
    const kids = tree.kids.get(r.id) || [];
    const open = kids.length ? opened[r.id] ?? false : false;
    const line: TreeLine = { r, depth: Math.min(depth, 2), kids: kids.length, open, hidden: 0, signal: "" };
    out.push(line);
    if (!kids.length) return;
    if (open) { for (const k of kids) visit(k, depth + 1); return; }
    const all = descendants(tree, r);
    const from = out.length;
    const cur = current ? all.find((x) => members(tree, x).some((m) => rowRef(m) === current)) : undefined;
    if (cur) visit(cur, depth + depthIn(tree, cur) - depthIn(tree, r));
    const drawn = new Set(out.slice(from).map((l) => l.r.id));
    const hidden = all.filter((x) => !drawn.has(x.id));
    line.hidden = hidden.length;
    line.signal = signalOf(tree, hidden);
  };
  for (const r of roots) visit(r, 0);
  return out;
}
// The session that opened r, when the console has a row for it (the detail
// pane's 来自 …).
export function fromRow(rows: Row[], r: Row): Row | undefined {
  const f = r.board?.from;
  if (!f) return undefined;
  return rows.find((x) => x !== r && (x.id === f || x.live?.ident === f || x.board?.history?.id === f || x.ended?.ident === f));
}
// A search hit nested under another: 父标题 › 子标题.
export const treeContext = (tree: Tree, r: Row) => tree.up.get(r.id)?.title || "";
// One schedule, one line (task X24T): inside 定时任务 a schedule's runs fold
// under their schedule — the hub's schedule_id, else (a node `fleet task`, an
// older run) the title without its day. `shown` is the newest run plus any run
// still working or asking the person; `older` folds behind 「N 次更早运行」.
// The input is already newest first; so is each schedule, and the schedules
// keep the order of their newest run.
export type ScheduleRuns = { key: string; label: string; shown: Row[]; older: Row[] };
export const scheduleLabel = (title: string) =>
  title.replace(/(?:[\s_-]+\d{4}-\d{2}-\d{2}|\s+\d{2}-\d{2})(?:(?:\s+#|-)\d+)?$/, "").trim() || title;
export function scheduleRuns(rows: Row[]): ScheduleRuns[] {
  const out = new Map<string, ScheduleRuns>();
  for (const r of rows) {
    const label = scheduleLabel(r.title);
    const key = r.board?.schedule_id || `title:${label}`;
    let g = out.get(key);
    if (!g) out.set(key, g = { key, label, shown: [], older: [] });
    const st = listStatus(r).kind;
    (!g.shown.length || needsAttention(r) || st === "work" || st === "pending" ? g.shown : g.older).push(r);
  }
  return [...out.values()];
}
// 定时任务 · N, a section of the list (task PV5W): one line per schedule, drawn
// like a session row — its runs (the sessions carrying its schedule_id, newest
// first) nest under it like a tree's children, folded until the person opens
// it. The main list never draws a run (Y8XY). The line's dot is its most urgent
// run's (asking > working > waiting to start); a schedule whose last run failed
// reads red. The right side: the last result and its time (✓ 13:17 / ✗ 13:17 —
// HH:MM today, else MM-DD), or 下次 07:10 when it never ran. Runs of a schedule
// the list does not have (deleted, an older run with no schedule_id) gather on
// one more line, `other`, so they stay reachable.
export type ScheduleSpecLike = { spec: { id: string; name: string; timezone: string; enabled?: boolean };
  observed: { status?: string; last_run?: number | string; next_run?: number | string; last_result?: string } };
export type ScheduleLine = { id: string; name: string; runs: Row[]; urgent?: Row; failed: boolean; result: string };
export type ScheduleLines = { lines: ScheduleLine[]; other: Row[] };
export const scheduleFailed = (s: ScheduleSpecLike) => s.observed.status === "failed" || s.observed.last_result === "failed";
// a schedule time as the hub sends it — epoch seconds or an ISO string — in ms; 0 unreadable
export const scheduleMs = (t: number | string | undefined): number => {
  const ms = typeof t === "number" ? t * 1000 : typeof t === "string" && t ? Date.parse(t) : NaN;
  return Number.isFinite(ms) && ms > 0 ? ms : 0;
};
// HH:MM on `now`'s day (in the schedule's zone), else MM-DD; "" when unreadable — never throws
export function clockOrDay(t: number | string | undefined, zone: string, now = Date.now()): string {
  const ms = scheduleMs(t);
  if (!ms) return "";
  const parts = (ms: number) => {
    let p: Intl.DateTimeFormatPart[];
    try { p = new Intl.DateTimeFormat("en-CA", { timeZone: zone || undefined, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(ms); }
    catch { p = new Intl.DateTimeFormat("en-CA", { year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(ms); }
    return Object.fromEntries(p.map((x) => [x.type, x.value])) as Record<string, string>;
  };
  const a = parts(ms), b = parts(now);
  return a.year === b.year && a.month === b.month && a.day === b.day ? `${a.hour}:${a.minute}` : `${a.month}-${a.day}`;
}
export function scheduleResult(s: ScheduleSpecLike, now = Date.now()): string {
  const zone = s.spec.timezone;
  const last = clockOrDay(s.observed.last_run, zone, now);
  if (last) return `${scheduleFailed(s) ? "✗" : "✓"} ${last}`;
  const next = s.spec.enabled === false ? "" : clockOrDay(s.observed.next_run, zone, now);
  return next ? tr(`下次 ${next}`, `Next ${next}`) : "";
}
const urgentRun = (runs: Row[]) => runs.find(needsAttention)
  || runs.find((r) => listStatus(r).kind === "work") || runs.find((r) => listStatus(r).kind === "pending");
export function scheduleLines(schedules: ScheduleSpecLike[], rows: Row[], now = Date.now()): ScheduleLines {
  const at = (r: Row) => r.board ? (r.board.activity_at || 0) * 1000 : r.at;
  const runs = rows.filter((r) => !r.board?.archived && r.group !== "pin" && rowSource(r) === "schedule")
    .sort((a, b) => at(b) - at(a) || a.id.localeCompare(b.id));
  const by = new Map<string, Row[]>();
  const known = new Set(schedules.map((s) => s.spec.id));
  const other: Row[] = [];
  for (const r of runs) {
    const id = r.board?.schedule_id || "";
    if (known.has(id)) (by.get(id) ?? by.set(id, []).get(id)!).push(r); else other.push(r);
  }
  return { other, lines: schedules.map((s) => {
    const mine = by.get(s.spec.id) || [];
    return { id: s.spec.id, name: s.spec.name, runs: mine, urgent: urgentRun(mine), failed: scheduleFailed(s), result: scheduleResult(s, now) };
  }) };
}
// What a set of rows says on the line that folds them: asking > working > nothing.
export const rowsSignal = (rows: Row[]): Signal => signalOf(NO_TREE, rows);
export type SourceGroups = Record<GroupSource, Row[]>;
// Each group holds the ROOTS of the session tree; what is nested under a root
// goes with it (`tree`), into PIN too.
export type CompactGroups = ListGroups & { sources: SourceGroups; tree: Tree };
// One order: PIN, then everything by recent activity (task DDBQ) — a tree's,
// its newest row's. A row that needs the person is not lifted into a group of
// its own — entering needs is itself activity — but it is never folded into
// More either, nor the tree holding it.
export function compactRows(rows: Row[], options: { current?: string; preferences?: Partial<SessionListPreferences>;
  now?: number; previous?: CompactGroups; interacting?: boolean } = {}): CompactGroups {
  const { current = "", now = Date.now(), previous, interacting = false } = options;
  const prefs = listPreferences(options.preferences);
  const tree = sessionTree(rows);
  const at = treeAt(tree);
  const whole = (r: Row) => [r, ...descendants(tree, r)].flatMap((x) => members(tree, x));
  const roots = rows.filter((r) => !tree.up.has(r.id) && !foldedDup(tree, r));
  const byAt = (a: Row, b: Row) => at(b) - at(a) || a.id.localeCompare(b.id);
  const grouped = (s: GroupSource) => roots.filter((r) => r.group !== "pin" && groupSource(r) === s).sort(byAt);
  const sources = { schedule: grouped("schedule"), api: grouped("api") };
  const base = listRows(roots.filter((r) => r.group === "pin" || !groupSource(r)), previous);
  const isCurrent = (r: Row) => rowRef(r) === current;
  const pin = [...base.pin].sort(byAt);
  const recent = [...base.open, ...base.gone].sort(byAt);
  const historical = new Set(base.gone.map((r) => r.id));
  const kept = recent.filter((r) => whole(r).some((x) => isCurrent(x) || needsAttention(x)));
  let room = Math.max(0, prefs.max_visible - pin.length);
  const visible = new Set(kept.map((r) => r.id));
  for (const r of recent) {
    if (visible.has(r.id) || room <= 0) continue;
    const t = at(r);
    const busy = whole(r).some((x) => { const k = listStatus(x).kind; return k === "work" || k === "pending"; });
    if (!t && historical.has(r.id)) continue; // unknown turn clock does not revive old history
    if (!prefs.idle_hours || !t || busy || now - t < prefs.idle_hours * 3600000) {
      visible.add(r.id); room--;
    }
  }
  const next: CompactGroups = { pin, open: recent.filter((r) => visible.has(r.id)), gone: recent.filter((r) => !visible.has(r.id)), sources, tree };
  // Keep row positions and membership while someone is pointing or navigating.
  // Refresh facts by identity, including removals; new rows wait in More. A
  // subtree moves with its root; a row nested since leaves the top level.
  if (interacting && previous && (!current || withKids(previous.tree || NO_TREE, [...previous.pin, ...previous.open]).some(isCurrent))) {
    const byID = new Map(rows.map((r) => [r.id, r]));
    const used = new Set<string>();
    const refresh = (before: Row[] = []) => before.flatMap((r) => {
      const fresh = byID.get(r.id);
      if (!fresh || tree.up.has(r.id) || foldedDup(tree, r)) return [];
      used.add(r.id); return [fresh];
    });
    const stable: CompactGroups = { pin: refresh(previous.pin), open: refresh(previous.open), gone: refresh(previous.gone),
      sources: { schedule: refresh(previous.sources.schedule), api: refresh(previous.sources.api) }, tree };
    for (const r of roots.filter((r) => !used.has(r.id))) {
      const src = r.group === "pin" ? "" : groupSource(r);
      (src ? stable.sources[src] : stable.gone).push(r);
    }
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
  return [r.code, machines > 1 ? rowMachine(r) : "", rowAgent(r), r.board?.context ? tr(...r.board.context) : "", where, r.live ? openFor(r.live.born * 1000, now) : "", lastActive(ownAt(r), now)].filter(Boolean).join(" · ");
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
  const at = treeAt(sessionTree(rows));
  return rows.filter((r) => matchRow(r, q)).sort((a, b) => at(b) - at(a) || a.id.localeCompare(b.id));
}

// New to the person: a row is bold until they open it, and again once its
// state moves on. `seen` maps a row to the mark it had when last opened.
export const seenMark = (r: Row) => `${r.tag[1]}@${r.at}`;
export const isUnread = (r: Row, seen: Record<string, string>) => seen[r.id] !== seenMark(r);

export const listItem = (r: Row, seen: Record<string, string>): ListItem =>
  ({ ref: rowRef(r), glyph: r.glyph, tone: r.tone, title: r.title, bold: isUnread(r, seen) });
