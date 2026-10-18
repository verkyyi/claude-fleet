// Conditional idle acceptance (issue #4618). Beneath the plugin the test's hooks
// stand for the engine: the inbox is an in-memory file map, the band is mounted
// as the terminal mounts it, and `prompt.submit`'s core starts a turn the way
// the engine does (turn.start through the plugin) — or, `busy`, holds it. What
// the real 2.1.295 engine does at each step is bin/fleet-idle-accept-claude-selftest.py's.

import { expect, mock, test } from 'claude-code/testing'
import type { Engine, On, RenderPropsOf } from 'claude-code'

import { ACCEPT_GRACE_S, RECEIPT_PREFIX, parseAccept } from '../hooks/accept'
import { INBOX_MS } from '../hooks/inbox'
import { SUPPORTED } from '../hooks/version'

const START = { cwd: '/tmp', surface: 'terminal', isInteractive: true } as const
const DIR = '/conf/global/mod-inbox/fleet-a/7'
const LAUNCH = '{"version":1,"provider":"claude"}'
const ENV = { TMUX_PANE: '%7', TMUX: '/private/tmp/tmux-501/fleet-a,123,0', FLEET_CONF_DIR: '/conf', HOME: '/h', FLEET_LAUNCH_CONTEXT: LAUNCH }
const NOW = 1_000_000_000
const ID = '6f1c2d3e-4b5a-4c6d-8e9f-0a1b2c3d4e5f'

type Entered = { text: string; context: readonly string[] }

function engine(on: On, opts: { draft?: string } = {}) {
  const files = new Map<string, string>()
  const entered: Entered[] = []
  const dropped: string[] = []
  const ok = { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
  const box = { text: opts.draft ?? '' }
  on('session.version', () => ({ value: { version: SUPPORTED.min, base: SUPPORTED.min } }))
  on('process.run', (_$, e) => {
    const [bin, from, to] = e.argv
    if (bin !== 'mv') return { value: ok }
    const text = from === undefined ? undefined : files.get(from)
    if (text === undefined || to === undefined) return { value: { ...ok, exitCode: 1 } }
    files.delete(from as string)
    files.set(to, text)
    return { value: ok }
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
  on('fs.write', (_$, e) => { files.set(e.path, e.text); return { value: undefined } })
  on('prompt.read', () => ({ value: { text: box.text, cursor: box.text.length } }))
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Box } = $.ui.resolve(e)
    return <Box key="engine" />
  })
  on('ui.toast', () => ({ value: undefined }))
  // The engine's entry: the prompt became a turn of its own (post() starts it).
  on('prompt.submit', (_$, e) => {
    entered.push({ text: e.text, context: e.context ?? [] })
    return { text: e.text, context: e.context, origin: e.origin }
  })
  on('turn.start', (_$, e) => ({ turnId: e.turnId }))
  on('turn.complete', (_$, e) => ({ text: e.answer }))
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.end', (_$, e) => ({ sessionId: e.sessionId }))
  mock.env(on, ENV)
  const clock = mock.clock(on, { now: NOW * 1000 })
  return { files, entered, dropped, clock, box }
}

function band(): RenderPropsOf['AbovePrompt'] {
  return { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 120, scroll: { offset: 0, bodyRows: 10 }, view: {} }
}

function request(extra: Record<string, unknown> = {}) {
  return { accept: 'idle.v1', nonce: 'b'.repeat(32), launch: JSON.parse(LAUNCH), delivery_id: ID,
    expected_turn: 't1', text: 'loop wakeup', deadline: NOW + 5, ...extra }
}

async function idleAfter($: Engine, turnId = 't1') {
  await $.turn.start({ text: 'go', turnId })
  await $.turn.complete({ answer: 'ok', durationMs: 5, isAborted: false, turnId, reason: 'answer' })
}

type Rig = { files: Map<string, string>; entered: Entered[]; clock: { advance: (ms: number) => Promise<void> } }

/** Post one request and run the clock until it is answered; an entered prompt's turn starts. */
async function post($: Engine, rig: Rig, req: Record<string, unknown>, steps = 4) {
  const { files, entered, clock } = rig
  const before = entered.length
  files.delete(`${DIR}/idle-accept.done`)
  files.set(`${DIR}/idle-accept.json`, JSON.stringify(req))
  for (let i = 0; i < steps * 20 && !files.has(`${DIR}/idle-accept.done`); i++) {
    await clock.advance(INBOX_MS / 20)
    if (entered.length > before && i % 20 === 19) await $.turn.start({ text: 'x', turnId: `t-entered-${entered.length}` })
  }
  return JSON.parse(files.get(`${DIR}/idle-accept.done`) ?? 'null')
}

test('parseAccept: the launch must match; nonce, uuid, turn, text and a near deadline required', () => {
  expect('error' in parseAccept(request(), LAUNCH, NOW)).toBe(true) // gate shut outside a session
})

test('idle: one turn of its own, the receipt in hidden context, accepted with that turn', async ($, on) => {
  const rig = engine(on)
  const { entered } = rig
  await $.session.start(START)
  const ui = await $.ui.mount({ plugin: 'fleet', surface: 'terminal', component: 'AbovePrompt', props: band() })
  await idleAfter($)
  const done = await post($, rig, request())
  expect(done).toEqual({ ok: true, state: 'accepted', reason: 'native_entry', nonce: 'b'.repeat(32),
    delivery_id: ID, turn_id: 't-entered-1', previous_turn_id: 't1' })
  expect(entered).toEqual([{ text: 'loop wakeup', context: [RECEIPT_PREFIX + ID] }])
  const receipt = JSON.parse(rig.files.get(`${DIR}/idle-accept-${ID}.receipt`) ?? 'null')
  expect([receipt.state, receipt.turn_id, receipt.delivery_id, receipt.nonce]).toEqual(['accepted', 't-entered-1', ID, undefined])
  await ui.unmount()
})

test('precheck: a running turn, another last turn, an interrupted one ⇒ rejected, nothing submitted', async ($, on) => {
  const rig = engine(on)
  const { entered } = rig
  await $.session.start(START)
  const ui = await $.ui.mount({ plugin: 'fleet', surface: 'terminal', component: 'AbovePrompt', props: band() })
  await idleAfter($, 't0')
  expect((await post($, rig, request())).reason).toBe('precheck_not_idle') // last is t0, not t1
  await $.turn.start({ text: 'go', turnId: 't1' })
  expect((await post($, rig, request())).reason).toBe('precheck_not_idle') // t1 still running
  await $.turn.complete({ answer: '', durationMs: 5, isAborted: true, turnId: 't1', reason: 'aborted' })
  expect((await post($, rig, request())).state).toBe('rejected') // interrupted is not idle
  expect(entered).toEqual([])
  await ui.unmount()
})

test('entry boundary: a draft in the box ⇒ dropped, rejected, no turn', async ($, on) => {
  const rig = engine(on, { draft: 'half typed' })
  const { entered } = rig
  await $.session.start(START)
  const ui = await $.ui.mount({ plugin: 'fleet', surface: 'terminal', component: 'AbovePrompt', props: band() })
  await idleAfter($)
  const done = await post($, rig, request())
  expect([done.state, done.reason]).toEqual(['rejected', 'draft_present'])
  expect(entered).toEqual([])
  expect(rig.files.has(`${DIR}/idle-accept-${ID}.receipt`)).toBe(false)
  await ui.unmount()
})

test('a /clear between precheck and entry: the old turn no longer names the conversation', async ($, on) => {
  const rig = engine(on)
  const { entered } = rig
  await $.session.start(START)
  await idleAfter($)
  await $.session.end({ reason: 'clear', sessionId: 's', resume: { id: 's' } })
  const ui = await $.ui.mount({ plugin: 'fleet', surface: 'terminal', component: 'AbovePrompt', props: band() })
  expect((await post($, rig, request())).reason).toBe('precheck_not_idle')
  expect(entered).toEqual([])
  await ui.unmount()
})

test('no band drawn by the deadline: never submitted ⇒ rejected not_submitted', async ($, on) => {
  const rig = engine(on)
  const { entered } = rig
  await $.session.start(START)
  await idleAfter($)
  const done = await post($, rig, request(), 10)
  expect([done.state, done.reason]).toEqual(['rejected', 'not_submitted'])
  expect(entered).toEqual([])
})

test('a fleet prompt with no live slot is dropped; a person\'s prompt passes untouched', async ($, on) => {
  const { entered } = engine(on)
  await $.session.start(START)
  await idleAfter($)
  const late = await $.prompt.submit({ text: 'stale accept' })
  expect(late.drop).toBe(undefined) // the test's own call is no fleet origin
  expect(entered.map(e => e.text)).toEqual(['stale accept'])
  expect(ACCEPT_GRACE_S).toBeGreaterThan(0)
})

test('a wrong launch, an expired or malformed request refuses at once (ok:false)', async ($, on) => {
  const rig = engine(on)
  const { entered } = rig
  await $.session.start(START)
  await idleAfter($)
  for (const bad of [request({ launch: { version: 2 } }), request({ deadline: NOW - 1 }),
    request({ delivery_id: 'x' }), request({ text: '' }), request({ accept: 'idle.v2' })]) {
    expect((await post($, rig, bad)).ok).toBe(false)
  }
  expect(entered).toEqual([])
})
