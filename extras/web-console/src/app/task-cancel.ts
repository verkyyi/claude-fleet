import type { Row } from "./work";

// Only an explicit pending request on a task can be cancelled here. A quiet,
// historical or temporarily missing session is not a queued start.
export function pendingStartRef(r: Row): string {
  if (r.live || !r.board || r.board.pending_start !== true
    || !["queued", "starting", "not_seen"].includes(r.board.tag)) return "";
  return r.task?.fid || r.task?.id || r.board.task_id || r.board.task || "";
}

// The Hub proves this request has never acquired an execution binding.
export function retryStartRef(r: Row): string {
  if (r.live || r.board?.start_retry !== true || !["queued", "start_failed"].includes(r.board.tag)) return "";
  return r.task?.fid || r.task?.id || r.board.task_id || r.board.task || "";
}
