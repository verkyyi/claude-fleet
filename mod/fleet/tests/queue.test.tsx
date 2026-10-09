// What waits behind a busy orchestrator (issue #2617). A mocked engine: the
// version answers in range; `process.run` answers the window's @fleet_role, the
// strings dump (the `orch_queue` keys among them) and records every tmux write;
// the turn events, tool calls and prompts end beneath the plugin; the clock
// moves only when the test moves it.

import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On, RenderPropsOf, TurnStepInput } from 'claude-code'

import { isRoleRun, resetRole } from '../hooks/orchestrator'
import { isStringsRun } from '../hooks/qd'
import { QUEUE_OPTION, counts, queueText, resetQueue } from '../hooks/queue'
import { SUPPORTED } from '../hooks/version'

const START = { cwd: '/tmp', surface: 'terminal', isInteractive: true } as const
const HAND = { kind: 'composer' } as const
const NOW = 1_000_000_000_000

const DUMP = [
  'orch_queue_fmt', '排队 \u0001 条 · 在忙 \u0001（已 \u0001 秒）· /qd 直接派',
  'orch_queue_thinking', '想下一步', 'orch_queue_qd', '快速派发',
].join('\0') + '\0'

function engine(on: On, windowRole = 'orchestrator') {
  const stamps: string[] = []
  const commands: string[] = []
  on('session.version', () => ({ value: { version: SUPPORTED.min, base: SUPPORTED.min } }))
  on('process.run', (_$, e) => {
    let stdout = ''
    if (isRoleRun(e.argv)) stdout = `${windowRole}\n`
    else if (isStringsRun(e.argv)) stdout = DUMP
    else if (e.argv[0] === 'tmux' && e.argv.includes(QUEUE_OPTION)) {
      const at = e.argv.indexOf(QUEUE_OPTION)
      stamps.push(e.argv[at - 1] === '-u' || e.argv[at + 1] === undefined || e.argv[at + 1] === ';' ? 'unset' : (e.argv[at + 1] as string))
    }
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.read', () => ({ value: '# 你是编排会话\n' }))
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.end', (_$, e) => ({ sessionId: e.sessionId }))
  on('command.register', (_$, e) => ({ value: { command: e.name } }))
  on('command.run', (_$, e) => {
    commands.push(e.command)
    return { text: 'engine' }
  })
  on('prompt.submit', (_$, e) => ({ text: e.text }))
  on('turn.start', (_$, e) => ({ turnId: e.turnId }))
  on('turn.complete', (_$, e) => ({ text: e.answer }))
  on('turn.step', async function* (_$, e) {
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'end_turn', usage: null }
  })
  on('tool.call', () => ({ result: {} as never, isAborted: false, turnId: 't1' }))
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Box } = $.ui.resolve(e)
    return <Box key="engine" />
  })
  mock.env(on, { TMUX_PANE: '%7', TMPDIR: '/var/folders/xx/T/', HOME: '/Users/me' })
  mock.store(on)
  const clock = mock.clock(on, { now: NOW })
  return { stamps, commands, clock }
}

function band(): RenderPropsOf['AbovePrompt'] {
  return { hasSurvey: false, isWorking: true, maxRows: 10, bodyColumns: 120, scroll: { offset: 0, bodyRows: 10 }, view: {} }
}

async function drawn($: Engine): Promise<string | undefined> {
  const ui = await $.ui.mount({ plugin: 'fleet', surface: 'terminal', component: 'AbovePrompt', props: band() })
  const text = (await ui.find({ key: 'fleet-queue' }))?.text
  await ui.unmount()
  return text
}

const STEP: TurnStepInput = { turnId: 't1', index: 0, model: 'claude-opus-5-5', effort: 'high', messageCount: 3 }

async function step($: Engine, input: TurnStepInput): Promise<void> {
  for await (const _chunk of $.turn.step(input)) { /* drain */ }
}

const COMPLETE = { answer: 'ok', durationMs: 5, isAborted: false, turnId: 't1', reason: 'answer' } as const

function fresh(): void {
  resetRole()
  resetQueue()
}

test('pure: what counts, and the line', () => {
  expect(counts({ turnId: 't1', origin: HAND, text: '再加一件' })).toBe(true)
  expect(counts({ turnId: undefined, origin: HAND, text: '再加一件' })).toBe(false) // idle: it starts a turn
  expect(counts({ turnId: 't1', origin: { kind: 'peer' } as never, text: '[child-report]' })).toBe(false)
  expect(counts({ turnId: 't1', origin: HAND, text: '/qd' })).toBe(false)
  expect(queueText({ n: 0, since: NOW, what: '', now: NOW })).toBe('')
})

test('two prompts over a running turn: 「排队 2 条」 and @orch_queue=2; the next step folds them in → 0', async ($, on) => {
  fresh()
  const m = engine(on)
  await $.session.start(START)
  expect(m.stamps).toEqual(['0']) // a counting orchestrator says a number from the start
  await $.turn.start({ text: 'go', turnId: 't1' })
  await step($, STEP)
  await $.tool.call({ tool: 'Bash', command: 'sleep 30' } as never).catch(() => undefined)
  await $.prompt.submit({ text: '还有一件', wait: false, origin: HAND, turnId: 't1' })
  await m.clock.advance(12_000)
  await $.prompt.submit({ text: '再一件', wait: false, origin: HAND, turnId: 't1' })
  expect(m.stamps).toEqual(['0', '1', '2'])
  const text = await drawn($)
  expect(text).toContain('排队 2 条')
  expect(text).toContain('（已 12 秒）')
  expect(text).toContain('/qd 直接派')
  await step($, { ...STEP, index: 1, messageCount: 7 })
  expect(m.stamps).toEqual(['0', '1', '2', '0'])
  expect(await drawn($)).toBeUndefined()
})

test('a subagent step folds nothing; the turn ending clears it', async ($, on) => {
  fresh()
  const m = engine(on)
  await $.session.start(START)
  await $.turn.start({ text: 'go', turnId: 't1' })
  await $.prompt.submit({ text: '还有一件', wait: false, origin: HAND, turnId: 't1' })
  expect(await drawn($)).toContain('排队 1 条')
  await step($, { ...STEP, index: 0, agentId: 'a1' })
  expect(await drawn($)).toContain('排队 1 条')
  await $.turn.complete(COMPLETE)
  expect(await drawn($)).toBeUndefined()
  expect(m.stamps[m.stamps.length - 1]).toBe('0')
})

test('idle prompts and a peer delivery do not count; the band button opens /qd', async ($, on) => {
  fresh()
  const m = engine(on)
  await $.session.start(START)
  await $.prompt.submit({ text: '开始', wait: false, origin: HAND })
  expect(await drawn($)).toBeUndefined()
  await $.turn.start({ text: 'go', turnId: 't1' })
  await $.prompt.submit({ text: '还有一件', wait: false, origin: HAND, turnId: 't1' })
  const ui = await $.ui.mount({ plugin: 'fleet', surface: 'terminal', component: 'AbovePrompt', props: band() })
  await ui.press({ key: 'fleet-queue-qd' })
  await ui.unmount()
  expect(m.commands).toContain('qd')
})

test('not the orchestrator: nothing counted, nothing stamped, nothing drawn', async ($, on) => {
  fresh()
  const m = engine(on, 'worker')
  await $.session.start(START)
  await $.turn.start({ text: 'go', turnId: 't1' })
  await $.prompt.submit({ text: '还有一件', wait: false, origin: HAND, turnId: 't1' })
  await $.prompt.submit({ text: '再一件', wait: false, origin: HAND, turnId: 't1' })
  expect(m.stamps).toEqual([])
  expect(await drawn($)).toBeUndefined()
})

test('a real exit unsets @orch_queue', async ($, on) => {
  fresh()
  const m = engine(on)
  await $.session.start(START)
  await $.session.end({ reason: 'prompt_input_exit', sessionId: 's1' } as never)
  expect(m.stamps).toEqual(['0', 'unset'])
})
