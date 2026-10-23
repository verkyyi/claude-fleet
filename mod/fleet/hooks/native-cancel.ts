// A bounded native-tool adapter, not Task stop orchestration. The read-only
// Python verifier proves the exact persisted stop, launch/root, native session,
// and durable record owner before each deletion. No proof => no tool call.

export const NATIVE_CANCEL = 'native.cancel.v1'
export const NATIVE_CANCEL_SLOT = 'native-cancel'
export const NATIVE_CANCEL_MAX_MS = 3000

type Request = {
  cancel: string
  nonce: string
  execution: Record<string, unknown>
  launch_id: string
  session_id: string
  deadline: number
  cron_ids: string[]
}
type Proof = { evidence: Record<string, string>; present_ids: string[] }
export type CancelIo = {
  now: () => Promise<number> // seconds
  sleep: (milliseconds: number) => Promise<void>
  session: () => Promise<string>
  generation: () => number
  verify: (request: Request, ids: string[], expected: Record<string, string>) => Promise<Proof>
  call: (input: { tool: 'CronList' } | { tool: 'CronDelete'; id: string }) => Promise<Record<string, unknown>>
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const KEYS = ['cancel', 'cron_ids', 'deadline', 'execution', 'launch_id', 'nonce', 'session_id']

function parse(value: Record<string, unknown>, now: number): Request {
  if (Object.keys(value).sort().join(',') !== KEYS.join(',') || value.cancel !== NATIVE_CANCEL
      || typeof value.nonce !== 'string' || !/^[0-9a-f]{32}$/.test(value.nonce)
      || typeof value.session_id !== 'string' || !UUID.test(value.session_id)
      || typeof value.launch_id !== 'string' || !UUID.test(value.launch_id)
      || typeof value.execution !== 'object' || value.execution === null || Array.isArray(value.execution)
      || typeof value.deadline !== 'number' || !Number.isFinite(value.deadline)
      || value.deadline <= now || value.deadline - now > NATIVE_CANCEL_MAX_MS / 1000
      || !Array.isArray(value.cron_ids) || value.cron_ids.length < 1 || value.cron_ids.length > 50
      || value.cron_ids.some(id => typeof id !== 'string' || !/^[0-9a-f]{8}$/.test(id))
      || new Set(value.cron_ids).size !== value.cron_ids.length) {
    throw new Error('invalid or expired durable-plan cancellation')
  }
  return value as Request
}

export async function cancelNative(io: CancelIo, value: Record<string, unknown>): Promise<Record<string, unknown>> {
  let request: Request
  try { request = parse(value, await io.now()) } catch {
    return { ok: false, scope: 'native_durable_plans', state: 'refused', reason: 'invalid_or_expired' }
  }
  const generation = io.generation()
  const cancelled: string[] = []
  let expired = false
  const answer = (state: string, reason = '') => ({
    ok: state === 'observed_absent', scope: 'native_durable_plans', state, reason,
    nonce: request.nonce, session_id: request.session_id, cancelled_ids: [...cancelled],
  })
  async function current(): Promise<void> {
    const session = await io.session()
    if (await io.now() >= request.deadline) expired = true
    if (expired || io.generation() !== generation || session !== request.session_id) {
      throw new Error('identity_or_deadline_changed')
    }
  }
  async function verify(ids: string[], expected: Record<string, string>): Promise<Proof> {
    await current()
    const proof = await io.verify(request, ids, expected)
    await current()
    if (!proof || typeof proof.evidence !== 'object' || !Array.isArray(proof.present_ids)
        || ids.some(id => typeof proof.evidence[id] !== 'string')) throw new Error('ownership_unavailable')
    return proof
  }
  async function run(): Promise<Record<string, unknown>> {
    try {
      const first = await verify(request.cron_ids, {})
      for (const id of request.cron_ids) {
        await verify([id], { [id]: first.evidence[id]! })
        await current()
        const result = await io.call({ tool: 'CronDelete', id })
        await current()
        if (result.deny || result.isError || (result.result as { id?: string } | undefined)?.id !== id) {
          throw new Error('native_cancel_unconfirmed')
        }
        cancelled.push(id)
      }
      const after = await verify([], {})
      const result = await io.call({ tool: 'CronList' })
      await current()
      const jobs = (result.result as { jobs?: unknown } | undefined)?.jobs
      if (result.deny || result.isError || !Array.isArray(jobs)
          || jobs.some(job => !job || typeof job.id !== 'string')
          || jobs.some(job => request.cron_ids.includes(job.id)) || after.present_ids.length > 0) {
        throw new Error('native_absence_unconfirmed')
      }
      return answer('observed_absent')
    } catch (error) {
      return answer(expired ? 'deadline_unknown' : 'refused',
        error instanceof Error ? error.message : 'ownership_or_native_call_unavailable')
    }
  }
  // An already entered native call has no verified cancellation API. At the
  // deadline stop waiting and issue no further calls; the stop controller must
  // enforce root exit. Never report that a timed-out call was cancelled.
  const remaining = Math.max(0, (request.deadline - await io.now()) * 1000)
  const timeout = io.sleep(remaining).then(() => {
    expired = true
    return answer('deadline_unknown', 'native_call_may_still_finish')
  })
  return Promise.race([run(), timeout])
}
