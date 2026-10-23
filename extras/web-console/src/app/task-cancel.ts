import type { Row } from "./work";

// Only an explicit pending request on a task can be cancelled here. A quiet,
// historical or temporarily missing session is not a queued start.
export function pendingStartRef(r: Row): string {
  if (r.live || !r.board || r.board.pending_start !== true
    || !["queued", "starting", "not_seen"].includes(r.board.tag)) return "";
  return r.task?.fid || r.task?.id || r.board.task_id || r.board.task || "";
}
