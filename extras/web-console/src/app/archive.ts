// Archiving a session stops it too (task DDBQ): an archived session is one the
// person is done with. Ask first only while it is still doing something —
// working, asking, a Loop, a start not confirmed yet; an idle one just goes.
import type { Row } from './work';
import { canStopRow } from './task-stop.ts';
import { listStatus } from './session-list.ts';

export type ArchivePlan = { stop: boolean; confirm: boolean };
export function archivePlan(r: Row): ArchivePlan {
  if (r.board?.archived) return { stop: false, confirm: false }; // unarchive: show it again, nothing else
  // a machine out of reach cannot be stopped from here: archived as it is
  const stop = !r.board?.lost && canStopRow(r);
  return { stop, confirm: stop && !!listStatus(r).kind };
}

// A session and the sessions it opened go together (`from`, down the tree):
// archiving the opener archives the family, unarchiving it shows the family
// again — only those on the same side, so one archived before stays as it is.
export function archiveFamily(rows: Row[], root: Row): Row[] {
  const kids = new Map<string, Row[]>();
  for (const r of rows) {
    const f = r.board?.from;
    if (f && r.board?.id) kids.set(f, [...(kids.get(f) ?? []), r]);
  }
  const want = !!root.board?.archived;
  const out: Row[] = [];
  const seen = new Set<string>([root.board?.id ?? ""]);
  const todo = [...(kids.get(root.board?.id ?? "") ?? [])];
  while (todo.length) {
    const x = todo.shift()!;
    const id = x.board!.id;
    if (seen.has(id)) continue;
    seen.add(id);
    if (!!x.board?.archived === want) out.push(x);
    todo.push(...(kids.get(id) ?? []));
  }
  return out;
}

export type TreePlan = { ids: string[]; stop: Row[]; confirm: Row[] };
// What one press does: the IDs written in one call (every one or none), the
// sessions stopped first, and the ones still at work the person is asked about.
export function archiveTreePlan(rows: Row[], root: Row): TreePlan {
  const family = [root, ...archiveFamily(rows, root)];
  const plans = family.map((r) => [r, archivePlan(r)] as const);
  return { ids: family.map((r) => r.board!.id),
    stop: plans.filter(([, p]) => p.stop).map(([r]) => r),
    confirm: plans.filter(([, p]) => p.confirm).map(([r]) => r) };
}
