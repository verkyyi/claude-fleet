// The session reports its own state (issue #1336). Beneath the plugin the test's
// hooks stand for the engine: `process.run` records every argv (and its stdin)
// instead of running it, and the tools answer for themselves — so the asserted
// sequence is exactly the writes a real session would hand the fleet's scripts.

import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { SUPPORTED } from '../hooks/version'
import { isToolsRun } from '../hooks/tools'
import { isWhereRun } from '../hooks/where'

const START = { cwd: '/tmp', surface: 'terminal', isInteractive: true } as const

type Run = { argv: string[]; stdin?: string }

function engine(on: On, version: string = SUPPORTED.min, env: Record<string, string> = { TMUX_PANE: '%7' }) {
  const runs: Run[] = []
  on('session.version', () => ({ value: { version, base: version } }))
  on('process.run', (_$, e) => {
    if (!isWhereRun(e.argv) && !isToolsRun(e.argv)) runs.push({ argv: [...e.argv], stdin: e.init?.stdin })
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('turn.start', (_$, e) => ({ turnId: e.turnId }))
  on('turn.complete', (_$, e) => ({ text: e.answer }))
  on('tool.call', (_$, e) => {
    if (e.tool === 'CronCreate') return { result: { id: 'job42' } as never, isAborted: false, turnId: 't1' }
    return { result: {} as never, isAborted: false, turnId: 't1' }
  })
  mock.env(on, env)
  mock.clock(on, { now: 1_000_000_000_000 })
  return { runs }
}

/** The fleet-script calls only (the heartbeat's own tmux writes left out). */
function writes(runs: Run[]): string[] {
  return runs
    .filter(r => r.argv[0] !== 'tmux')
    .map(r => {
      const script = (r.argv[1] ?? '').split('/').pop()
      return [script, ...r.argv.slice(2)].join(' ')
    })
}

const COMPLETE = { answer: 'ok', durationMs: 5, isAborted: false, turnId: 't1', reason: 'answer' } as const

test('turn.start → working, turn.complete → done, via set-claude-state.sh --via mod', async ($, on) => {
  const { runs } = engine(on)
  await $.session.start(START)
  await $.turn.start({ text: 'go', turnId: 't1' })
  await $.turn.complete(COMPLETE)
  expect(writes(runs)).toEqual(['set-claude-state.sh --via mod working', 'set-claude-state.sh --via mod done'])
  const state = runs.filter(r => r.argv[0] === 'sh')
  expect(state.every(r => r.stdin === '')).toBe(true)
  expect(state.every(r => r.argv[1]?.endsWith('/../../bin/set-claude-state.sh'))).toBe(true)
})

test('AskUserQuestion: needs/ask while open, working once answered', async ($, on) => {
  const { runs } = engine(on)
  await $.session.start(START)
  await $.turn.start({ text: 'go', turnId: 't1' })
  await $.tool.call({ tool: 'AskUserQuestion', questions: [] } as never)
  await $.turn.complete(COMPLETE)
  expect(writes(runs)).toEqual([
    'set-claude-state.sh --via mod working',
    'set-claude-state.sh --via mod ask',
    'set-claude-state.sh --via mod working',
    'set-claude-state.sh --via mod done',
  ])
})

test('ScheduleWakeup / CronCreate / CronDelete → fleet_loop_mark.py hook with the PostToolUse payload', async ($, on) => {
  const { runs } = engine(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'ScheduleWakeup', delaySeconds: 600, prompt: 'p', reason: 'r' } as never)
  await $.tool.call({ tool: 'CronCreate', cron: '*/5 * * * *', prompt: 'p' } as never)
  await $.tool.call({ tool: 'CronDelete', id: 'job42' } as never)
  await $.tool.call({ tool: 'Read', file_path: '/tmp/x' } as never)
  expect(writes(runs)).toEqual(['fleet_loop_mark.py hook', 'fleet_loop_mark.py hook', 'fleet_loop_mark.py hook'])
  const payloads = runs.filter(r => r.argv[0] === 'python3').map(r => JSON.parse(r.stdin ?? '{}'))
  expect(payloads[0].tool_name).toBe('ScheduleWakeup')
  expect(payloads[0].tool_input.delaySeconds).toBe(600)
  expect(payloads[0].tool_input.tool).toBe(undefined)
  expect(payloads[1].tool_response).toEqual({ id: 'job42' })
  expect(payloads[2].tool_input).toEqual({ id: 'job42' })
})

test('gate shut (out of range): no state write at all', async ($, on) => {
  const { runs } = engine(on, '9.0.0')
  await $.session.start(START)
  await $.turn.start({ text: 'go', turnId: 't1' })
  await $.tool.call({ tool: 'AskUserQuestion', questions: [] } as never)
  await $.tool.call({ tool: 'ScheduleWakeup', delaySeconds: 600, prompt: 'p', reason: 'r' } as never)
  await $.turn.complete(COMPLETE)
  expect(writes(runs)).toEqual([])
})

test('outside tmux: nothing is written', async ($, on) => {
  const { runs } = engine(on, SUPPORTED.min, {})
  await $.session.start(START)
  await $.turn.start({ text: 'go', turnId: 't1' })
  await $.turn.complete(COMPLETE)
  expect(runs).toEqual([])
})

test('a subagent turn or question is not this pane’s state', async ($, on) => {
  const { runs } = engine(on)
  await $.session.start(START)
  await $.turn.complete({ ...COMPLETE, agentId: 'sub1' })
  await $.tool.call({ tool: 'AskUserQuestion', questions: [], agentId: 'sub1' } as never)
  expect(writes(runs)).toEqual([])
})
