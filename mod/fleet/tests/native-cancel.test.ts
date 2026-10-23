import { expect, test } from 'claude-code/testing'
import { cancelNative } from '../hooks/native-cancel'
import type { CancelIo } from '../hooks/native-cancel'
import { pollInbox, pollNativeCancel } from '../hooks/inbox'

const SID = '22222222-2222-4222-8222-222222222222'
const request = () => ({ cancel: 'native.cancel.v1', nonce: 'a'.repeat(32), execution: { cancel_request: 'stop' },
  launch_id: '33333333-3333-4333-8333-333333333333', session_id: SID, deadline: 102,
  cron_ids: ['1234abcd', '5678abcd'] })

function engine() {
  const calls: Array<Record<string, unknown>> = []
  const verifies: string[][] = []
  let generation = 1
  let session = SID
  let timeout: () => void = () => { throw new Error('timeout not armed') }
  const io: CancelIo = {
    now: async () => 100,
    sleep: () => new Promise(resolve => { timeout = resolve }),
    session: async () => session,
    generation: () => generation,
    verify: async (_request, ids, expected) => {
      verifies.push(ids)
      for (const id of ids) if (expected[id] !== undefined) expect(expected[id]).toBe('hash-' + id)
      return { evidence: Object.fromEntries(ids.map(id => [id, 'hash-' + id])), present_ids: [...ids] }
    },
    call: async input => {
      calls.push(input)
      return { result: input.tool === 'CronList' ? { jobs: [{ id: 'aaaaaaaa' }] } : { id: input.id } }
    },
  }
  return { io, calls, verifies, expire: () => timeout(), boundary: () => generation++,
    changeSession: () => { session = '44444444-4444-4444-8444-444444444444' } }
}

test('durable cancellation re-verifies each owner and observes absence without touching another ID', async () => {
  const e = engine()
  const result = await cancelNative(e.io, request())
  expect(result.state).toBe('observed_absent')
  expect(result.scope).toBe('native_durable_plans')
  expect(e.verifies).toEqual([['1234abcd', '5678abcd'], ['1234abcd'], ['5678abcd'], []])
  expect(e.calls).toEqual([{ tool: 'CronDelete', id: '1234abcd' },
    { tool: 'CronDelete', id: '5678abcd' }, { tool: 'CronList' }])
})

test('unknown fields, arbitrary task IDs and expired or extended deadlines call no native tool', async () => {
  for (const extra of [{ tool: 'Bash' }, { task_ids: ['someone'] }, { deadline: 100 },
    { deadline: 104 }, { deadline: Number.NaN }, { cron_ids: ['1234abcd', '1234abcd'] }]) {
    const e = engine()
    expect((await cancelNative(e.io, { ...request(), ...extra })).state).toBe('refused')
    expect(e.calls).toEqual([])
    expect(e.verifies).toEqual([])
  }
})

test('wrong current session refuses even an otherwise valid request', async () => {
  const e = engine()
  e.changeSession()
  expect((await cancelNative(e.io, request())).state).toBe('refused')
  expect(e.calls).toEqual([])
})

test('missing durable ownership refuses before any native invocation', async () => {
  const e = engine()
  e.io.verify = async () => { throw new Error('ownership unavailable') }
  expect((await cancelNative(e.io, request())).state).toBe('refused')
  expect(e.calls).toEqual([])
})

test('a boundary during an identity await refuses before verifying or calling tools', async () => {
  const e = engine()
  e.io.session = async () => { e.boundary(); return SID }
  expect((await cancelNative(e.io, request())).state).toBe('refused')
  expect(e.verifies).toEqual([])
  expect(e.calls).toEqual([])
})

test('wall-clock expiry reports unknown even before the timeout callback fires', async () => {
  const e = engine()
  let reads = 0
  e.io.now = async () => ++reads > 2 ? 103 : 100
  expect((await cancelNative(e.io, request())).state).toBe('deadline_unknown')
  expect(e.calls).toEqual([])
})

test('session boundary or owner change after one cancellation prevents the rest', async () => {
  for (const mode of ['session', 'generation', 'owner']) {
    const e = engine()
    const call = e.io.call
    const verify = e.io.verify
    e.io.call = async input => {
      const result = await call(input)
      if (mode === 'session') e.changeSession()
      if (mode === 'generation') e.boundary()
      return result
    }
    e.io.verify = async (req, ids, expected) => {
      if (mode === 'owner' && ids.length === 1 && ids[0] === '5678abcd') throw new Error('owner changed')
      return verify(req, ids, expected)
    }
    expect((await cancelNative(e.io, request())).state).toBe('refused')
    expect(e.calls).toEqual([{ tool: 'CronDelete', id: '1234abcd' }])
  }
})

test('resolved native error is not a successful cancellation', async () => {
  const e = engine()
  e.io.call = async input => { e.calls.push(input); return { isError: true, result: 'unknown ID' } }
  const result = await cancelNative(e.io, request())
  expect(result.state).toBe('refused')
  expect(result.cancelled_ids).toEqual([])
  expect(e.calls.length).toBe(1)
})

test('native readback still containing a cancelled ID is not absence proof', async () => {
  const e = engine()
  const call = e.io.call
  e.io.call = async input => input.tool === 'CronList'
    ? { result: { jobs: [{ id: '1234abcd' }] } } : call(input)
  expect((await cancelNative(e.io, request())).state).toBe('refused')
})

test('deadline returns unknown while a native call is pending and prevents later calls', async () => {
  const e = engine()
  let started: () => void = () => {}
  const beginning = new Promise<void>(resolve => { started = resolve })
  let finish: (result: Record<string, unknown>) => void = () => {}
  e.io.call = async input => {
    e.calls.push(input)
    started()
    return new Promise(resolve => { finish = resolve })
  }
  const pending = cancelNative(e.io, request())
  await beginning
  e.expire()
  const result = await pending
  expect(result.state).toBe('deadline_unknown')
  expect(result.cancelled_ids).toEqual([])
  finish({ result: { id: '1234abcd' } })
  for (let i = 0; i < 15; i++) await Promise.resolve()
  expect(e.calls).toEqual([{ tool: 'CronDelete', id: '1234abcd' }])
})

test('the fixed cancellation slot runs while a normal command is waiting for idle', async () => {
  const files = new Map([['/in/1.json', '{"cmd":"/compact"}'],
    ['/in/native-cancel.json', JSON.stringify(request())]])
  let started: () => void = () => {}
  const beginning = new Promise<void>(resolve => { started = resolve })
  let finish: () => void = () => {}
  const io = {
    list: async () => [...files.keys()].map(p => p.slice('/in/'.length)),
    read: async (path: string) => files.get(path) ?? '',
    write: async (path: string, text: string) => { files.set(path, text) },
    claim: async (from: string, to: string) => {
      const text = files.get(from)
      if (text === undefined) return false
      files.delete(from); files.set(to, text); return true
    },
    run: async () => { started(); await new Promise<void>(resolve => { finish = resolve }) },
    cancel: async () => ({ ok: false, state: 'refused', reason: 'fixture has no ownership proof' }),
  }
  const command = pollInbox(io, '/in')
  await beginning
  await pollNativeCancel(io, '/in')
  expect(JSON.parse(files.get('/in/native-cancel.done') ?? '{}').state).toBe('refused')
  expect(files.has('/in/1.done')).toBe(false)
  finish()
  await command
})
