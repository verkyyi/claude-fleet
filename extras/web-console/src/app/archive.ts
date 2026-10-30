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
