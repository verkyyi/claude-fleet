// The command inbox (issue #1337). Beneath the plugin the test's hooks stand for
// the engine and the disk: an in-memory file map answers fs.list / fs.read /
// fs.write, `process.run` performs the `mv` claim on that map, and `command.run`
// records each command instead of running it.

import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { INBOX_MS, inboxDir, parseMessage, pending, pollInbox } from '../hooks/inbox'
import { SUPPORTED } from '../hooks/version'

const START = { cwd: '/tmp', surface: 'terminal', isInteractive: true } as const
const DIR = '/conf/global/mod-inbox/fleet-a/7'
const ENV = { TMUX_PANE: '%7', TMUX: '/private/tmp/tmux-501/fleet-a,123,0', FLEET_CONF_DIR: '/conf', HOME: '/h' }

function engine(on: On, opts: { refuse?: string; env?: Record<string, string> } = {}) {
  const files = new Map<string, string>()
  const commands: Array<[string, string]> = []
  const observations: Record<string, unknown>[] = []
  const ok = (stdout = '') => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })
  on('session.version', () => ({ value: { version: SUPPORTED.min, base: SUPPORTED.min } }))
  on('process.run', (_$, e) => {
    const [bin, from, to] = e.argv
    if (from?.endsWith('/fleet_runtime.py')) observations.push(JSON.parse(e.init?.stdin ?? '{}'))
    if (bin !== 'mv') return ok()
    const text = from === undefined ? undefined : files.get(from)
    if (text === undefined || to === undefined) return { value: { ...ok().value, exitCode: 1 } }
    files.delete(from as string)
    files.set(to, text)
    return ok()
  })
  on('fs.list', (_$, e) => {
    const names = [...files.keys()].filter(p => p.startsWith(`${e.path}/`)).map(p => p.slice(e.path.length + 1))
    if (names.length === 0) throw new Error('ENOENT')
    return { value: names.map(name => ({ name, kind: 'file' as const, size: 1, mtimeMs: 0, isLink: false })) }
  })
  on('fs.read', (_$, e) => {
    const t = files.get(e.path)
    if (t === undefined) throw new Error('ENOENT')
    return { value: t }
  })
  on('fs.write', (_$, e) => {
    files.set(e.path, e.text)
    return { value: undefined }
  })
  on('command.run', (_$, e) => {
    commands.push([e.command, e.args])
    if (opts.refuse === e.command) throw new Error(`Unknown command: /${e.command}`)
    return {}
  })
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.end', (_$, e) => ({ sessionId: e.sessionId }))
  mock.env(on, { ...ENV, ...opts.env })
  const clock = mock.clock(on, { now: 1_000_000_000_000 })
  return { files, commands, clock, observations }
}

test('inboxDir: keyed by socket label and pane number; nothing outside tmux', () => {
  expect(inboxDir('/conf/', ENV.TMUX, '%7')).toBe(DIR)
  expect(inboxDir('/conf', undefined, '%7')).toBe(undefined)
  expect(inboxDir('/conf', ENV.TMUX, undefined)).toBe(undefined)
  expect(inboxDir('/conf', ENV.TMUX, '@3')).toBe(undefined)
})

test('parseMessage: one /command, args kept verbatim; anything else refused', () => {
  expect(parseMessage('{"cmd":"/compact","args":"Keep the map; it is at /x","from":"compact-send"}'))
    .toEqual({ cmd: 'compact', args: 'Keep the map; it is at /x', from: 'compact-send' })
  expect(parseMessage('{"cmd":"/clear"}')).toEqual({ cmd: 'clear', args: '', from: '?' })
  expect('error' in parseMessage('{"cmd":"clear"}')).toBe(true)
  expect('error' in parseMessage('{"cmd":"/a b"}')).toBe(true)
  expect('error' in parseMessage('nope')).toBe(true)
})

test('pending: .json only, dot-temps skipped, post order', () => {
  expect(pending(['20-1.json', '.21-1.tmp', '10-1.json', '9-1.taken', '9-1.done'])).toEqual(['10-1', '20-1'])
})

test('native runtime queries never enter the command runner', async () => {
  const commands: string[] = []
  const queries: Record<string, unknown>[] = []
  const replies: string[] = []
  await pollInbox({
    list: async () => ['runtime-observation.json'],
    read: async () => JSON.stringify({ query: 'runtime.v1', nonce: 'a'.repeat(32), cmd: '/clear' }),
    claim: async () => true,
    write: async (_path, value) => { replies.push(value) },
    run: async command => { commands.push(command) },
    query: async request => { queries.push(request) },
  }, DIR)
  expect(commands).toEqual([])
  expect(queries.length).toBe(1)
  expect(JSON.parse(replies[0] ?? '{}')).toEqual({ ok: true })
})

test('idle beyond TTL is observed on demand in the native module; old requests refuse', async ($, on) => {
  const { files, commands, clock, observations } = engine(on, { env: { FLEET_LAUNCH_CONTEXT: '{"version":1}' } })
  on('turn.start', (_$, e) => ({ turnId: e.turnId }))
  on('turn.complete', (_$, e) => ({ text: e.answer }))
  await $.session.start(START)
  await $.turn.start({ text: 'go', turnId: 't1' })
  await $.turn.complete({ answer: 'ok', durationMs: 5, isAborted: false, turnId: 't1', reason: 'answer' })
  await clock.advance(18_000)
  const request = { query: 'runtime.v1', launch: { version: 1 }, nonce: 'a'.repeat(32), deadline: 1_000_000_021 }
  files.set(`${DIR}/runtime-observation.json`, JSON.stringify(request))
  await clock.advance(INBOX_MS)
  const reply = observations.at(-1)
  expect(reply?.state).toBe('idle')
  expect(reply?.turn_id).toBe('t1')
  expect(reply?.observed_at).toBe(1_000_000_019)
  expect(reply?.query_id).toBe(request.nonce)
  expect(commands).toEqual([])
  const count = observations.length
  for (const invalid of [{ ...request, launch: { version: 2 } }, { ...request, deadline: 0 }]) {
    files.set(`${DIR}/runtime-observation.json`, JSON.stringify(invalid))
    await clock.advance(INBOX_MS)
    expect(JSON.parse(files.get(`${DIR}/runtime-observation.done`) ?? '{}').ok).toBe(false)
    expect(observations.length).toBe(count)
  }
})

test('a posted /compact is claimed, run through command.run, and answered done', async ($, on) => {
  const { files, commands, clock } = engine(on)
  await $.session.start(START)
  files.set(`${DIR}/100-1.json`, '{"cmd":"/compact","args":"Keep the map","from":"compact-send"}')
  await clock.advance(INBOX_MS)
  expect(commands).toEqual([['compact', 'Keep the map']])
  expect(files.has(`${DIR}/100-1.json`)).toBe(false)
  expect(files.has(`${DIR}/100-1.taken`)).toBe(true)
  expect(JSON.parse(files.get(`${DIR}/100-1.done`) ?? 'null')).toEqual({ ok: true })
  await clock.advance(INBOX_MS * 3)
  expect(commands.length).toBe(1) // never twice
})

test('the poll outlives a /clear: the pickup posted after it is still taken', async ($, on) => {
  const { files, commands, clock } = engine(on)
  await $.session.start(START)
  files.set(`${DIR}/100-1.json`, '{"cmd":"/clear","args":"","from":"handoff-cycle"}')
  await clock.advance(INBOX_MS)
  await $.session.end({ reason: 'clear', sessionId: 's', resume: { id: 's' } })
  files.set(`${DIR}/101-1.json`, '{"cmd":"/fleet-handoff","args":"pickup","from":"handoff-cycle"}')
  await clock.advance(INBOX_MS)
  expect(commands).toEqual([['clear', ''], ['fleet-handoff', 'pickup']])
})

test('a refused command writes ok:false with the reason', async ($, on) => {
  const { files, clock } = engine(on, { refuse: 'nosuch' })
  await $.session.start(START)
  files.set(`${DIR}/100-1.json`, '{"cmd":"/nosuch","args":"","from":"t"}')
  files.set(`${DIR}/100-2.json`, '{"cmd":"bad"}')
  await clock.advance(INBOX_MS)
  const done = JSON.parse(files.get(`${DIR}/100-1.done`) ?? 'null')
  expect(done.ok).toBe(false)
  expect(String(done.error).length).toBeGreaterThan(0)
  expect(JSON.parse(files.get(`${DIR}/100-2.done`) ?? 'null').ok).toBe(false)
})

test('a cancelled post (the .json renamed away) never runs; a real exit stops the poll', async ($, on) => {
  const { files, commands, clock } = engine(on)
  await $.session.start(START)
  await $.session.end({ reason: 'prompt_input_exit', sessionId: 's', resume: { id: 's' } })
  files.set(`${DIR}/100-1.json`, '{"cmd":"/clear"}')
  await clock.advance(INBOX_MS * 3)
  expect(commands).toEqual([])
})
