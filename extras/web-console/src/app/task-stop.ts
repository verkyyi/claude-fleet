import type { Row } from './work';
import type { Task } from './task-state';
import { pendingStartRef } from './task-cancel.ts';

const operationID = (value: string | undefined) => !!value && /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(value);
const taskID = (value: string | undefined) => value && (/^T[1-9][0-9]*$/.test(value)
  || /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(value)) ? value : '';

export function stopTaskRef(r: Row): string {
  if (r.task && r.board && ((r.board.task && r.task.id !== r.board.task)
    || (r.board.task_id && r.task.fid && r.board.task_id !== r.task.fid))) return '';
  return taskID(r.board?.task) || taskID(r.task?.task) || taskID(r.task?.id)
    || taskID(r.board?.task_id) || taskID(r.task?.fid);
}

export const controlledStop = (r: Row) => !!(r.board?.execution_endpoint || r.task?.execution_endpoint);
export const canStopRow = (r: Row) => !pendingStartRef(r) && (!!r.live?.id || (controlledStop(r) && !!stopTaskRef(r)));

type StopReply = { stop_requested?: boolean; execution_exit_confirmed?: boolean; execution_never_started?: boolean;
  scope?: string; operation?: { operation_id?: string; action?: string } };
export type StopResult = { ok: boolean; error?: string; exitConfirmed?: boolean; neverStarted?: boolean; legacy?: boolean };
export type StopIO = {
  read: (url: string) => Promise<Task | null>;
  post: (url: string, body: unknown) => Promise<{ ok: boolean; data?: StopReply; error?: string }>;
  legacy: (worker: string) => Promise<string | null>;
};

// Task authority may outlive every observed window. An unavailable read or
// refused Task stop never falls through to ordinary worker_stop.
async function routeRowStop(r: Row, io: StopIO): Promise<StopResult> {
  if (pendingStartRef(r)) return { ok: false, error: 'Use cancel start for this pending request.' };
  const ref = stopTaskRef(r);
  let controlled = controlledStop(r);
  if (controlled && !ref) return { ok: false, error: 'Task identity changed; refresh before stopping.' };
  if (ref) {
    if (!controlled) {
      // Browser GET returns a flat taskView; only the node endpoint wraps {task}.
      const task = await io.read(`/v1/fleet/tasks/${encodeURIComponent(ref)}`);
      if (!task || ![task.id, task.task, task.fid].includes(ref))
        return { ok: false, error: 'Task authority unavailable; stop was not sent.' };
      controlled = !!(task.execution_endpoint || task.cancel_request);
    }
    if (controlled) {
      const key = `task-stop:${crypto.randomUUID?.() || `${Date.now()}-${Math.random()}`}`;
      const answer = await io.post(`/v1/fleet/tasks/${encodeURIComponent(ref)}/stop`,
        { idempotency_key: key, evidence: 'operator requested Task stop from Web' });
      if (!answer.ok) return { ok: false, error: answer.error || 'Task stop not confirmed.' };
      const data = answer.data;
      if (data?.stop_requested !== true || typeof data.execution_exit_confirmed !== 'boolean'
        || !operationID(data.operation?.operation_id) || data.operation?.action !== 'worker_stop'
        || (data.execution_exit_confirmed && data.scope !== 'native_session'))
        return { ok: false, error: 'Task stop acceptance is not confirmed.' };
      return { ok: true, exitConfirmed: data.execution_exit_confirmed, neverStarted: data.execution_never_started === true };
    }
  } else if (r.task || r.board?.task || r.board?.task_id) {
    return { ok: false, error: 'Task identity is inconsistent; refresh before stopping.' };
  }
  if (!r.live?.id) return { ok: false, error: 'No legacy session is available to stop.' };
  const error = await io.legacy(r.live.id);
  return error ? { ok: false, error } : { ok: true, exitConfirmed: false, legacy: true };
}

export async function requestRowStop(r: Row, io: StopIO): Promise<StopResult> {
  try { return await routeRowStop(r, io); }
  catch { return { ok: false, error: "Stop not confirmed; refresh before retrying." }; }
}
