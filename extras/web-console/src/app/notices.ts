// notices.ts — 通知, the bell beside search (task PV5W): what the console has to
// tell the person, in one place instead of bars over the page. Pure, so
// test/session-list.mjs runs it as it is; Bell.tsx draws it.
//   在问你   rows that need the person (needsAttention), oldest wait first
//   新结果   rows that finished a reply the person has not opened (work-rows'
//            `replied`, what the 「X」答完了 toast said)
//   定时任务 unread schedule results, merged per schedule: 「<name> · 今天 N 次」
//            and its newest summary, a schedule with a failed one first
// The badge counts what wants the person: asking, new results, and FAILED
// schedule runs — a schedule that did its job is listed, never counted.
import { tr } from "../shared/i18n.ts"; // .ts: the test runs this file as it is
import { needsAttention } from "./session-list.ts";
import type { Row } from "./work.ts";

export type BellRun = { id: string; schedule_id: string; state: string; started: number; ended: number; summary: string; error: string };
export const runFailed = (r: BellRun) => r.state === "failed" || (!!r.error && r.state !== "ok" && r.state !== "succeeded");
export type BellSchedule = { id: string; name: string; runs: BellRun[]; failed: number; label: string; line: string; at: number };
export type BellGroups = { asking: Row[]; results: Row[]; schedules: BellSchedule[]; count: number };

const sameDay = (a: number, b: number) => new Date(a).toDateString() === new Date(b).toDateString();
const activity = (r: Row) => r.board?.activity_at ? r.board.activity_at * 1000 : r.at;

export function bellGroups(rows: Row[] | null, replied: Record<string, string>, unread: BellRun[], names: Record<string, string> = {}, now = Date.now()): BellGroups {
  const listed = (rows || []).filter((r) => !r.board?.archived);
  const asking = listed.filter(needsAttention).sort((a, b) => activity(a) - activity(b) || a.id.localeCompare(b.id));
  const ask = new Set(asking.map((r) => r.id));
  const results = listed.filter((r) => replied[r.id] && !ask.has(r.id)).sort((a, b) => activity(b) - activity(a) || a.id.localeCompare(b.id));
  const by = new Map<string, BellRun[]>();
  for (const r of unread) (by.get(r.schedule_id) ?? by.set(r.schedule_id, []).get(r.schedule_id)!).push(r);
  const schedules = [...by.entries()].map(([id, runs]): BellSchedule => {
    const when = (r: BellRun) => (r.ended || r.started) * 1000;
    runs.sort((a, b) => when(b) - when(a));
    const today = runs.filter((r) => when(r) && sameDay(when(r), now)).length;
    const name = names[id] || id;
    const label = today === runs.length ? tr(`${name} · 今天 ${today} 次`, `${name} · ${today} today`)
      : tr(`${name} · ${runs.length} 次`, `${name} · ${runs.length} runs`);
    return { id, name, runs, failed: runs.filter(runFailed).length, label, line: (runs[0].error || runs[0].summary || "").trim(), at: when(runs[0]) };
  }).sort((a, b) => (b.failed ? 1 : 0) - (a.failed ? 1 : 0) || b.at - a.at || a.id.localeCompare(b.id));
  const count = asking.length + results.length + unread.filter(runFailed).length;
  return { asking, results, schedules, count };
}
