import type { Row } from './work';
import { stopTaskRef } from './task-stop.ts';

export type ContinueAgent = 'claude' | 'codex';
const uuid = (value: unknown): value is string => typeof value === 'string'
  && /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(value);

// A stopped, explicitly controlled binding is required. Opening history or
// observing an idle native session never creates a new execution.
export function canContinueRow(r: Row): boolean {
  const t = r.task;
  return !!t && !!stopTaskRef(r) && t.authority_version === 1
    && t.execution_owner === '' && !r.live && uuid(t.cancel_request)
    && Number.isSafeInteger(t.generation) && t.generation! >= 2;
}

type ContinueReply = {
  task?: string; agent?: string; authorized_generation?: number;
  exit_operation_id?: string; stop_operation_id?: string;
  operation?: { operation_id?: string; action?: string };
};
export type ContinueResult = { ok: boolean; error?: string; status?: number };
export type ContinueIO = {
  post: (url: string, body: unknown) => Promise<ContinueResult & { data?: ContinueReply }>;
};

export async function requestRowContinue(r: Row, io: ContinueIO, agent?: ContinueAgent): Promise<ContinueResult> {
  if (!canContinueRow(r) || (agent !== undefined && agent !== 'claude' && agent !== 'codex'))
    return { ok: false, error: 'Refresh the task before continuing.' };
  const t = r.task!, ref = stopTaskRef(r), generation = t.generation!, stop = t.cancel_request!;
  // The same visible intention uses the same key across lost responses,
  // repeated clicks and page reloads. The Hub owns proof checks and the CAS;
  // a stale view cannot authorize a different generation or fall back to spawn.
  const body = {
    idempotency_key: `web-continue:${t.id}:${generation}:${stop}:${agent || 'same'}`,
    expected_stop_operation_id: stop, expected_generation: generation,
    ...(agent ? { agent } : {}),
  };
  try {
    const answer = await io.post(`/v1/fleet/tasks/${encodeURIComponent(ref)}/continue`, body);
    if (!answer.ok) return { ok: false, status: answer.status, error: answer.error || 'Continue request not confirmed.' };
    const d = answer.data;
    const exit = uuid(d?.exit_operation_id), unclaimed = uuid(d?.stop_operation_id);
    if (!d || d.task !== t.id || d.authorized_generation !== generation + 1
      || !uuid(d.operation?.operation_id) || d.operation?.action !== 'worker_start'
      || !['claude', 'codex'].includes(d.agent || '') || (agent && d.agent !== agent)
      || exit === unclaimed || (exit && 'stop_operation_id' in d)
      || (unclaimed && ('exit_operation_id' in d || d.stop_operation_id !== stop)))
      return { ok: false, error: 'Continue acceptance is not confirmed; refresh before retrying.' };
    return { ok: true };
  } catch {
    return { ok: false, error: 'Continue request not confirmed; retry uses the same request.' };
  }
}
