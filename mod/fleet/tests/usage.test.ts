// Context, quota, model and effort reported by the session (issues #1338, #1459).
// A mocked engine: the version answers in range, `process.run` records every argv
// (the mod feeds conf/statusline.sh — it never writes tmux itself here),
// `session.model` answers whatever the test sets, and the test fires
// `session.measure` / `turn.step` the way the engine does after a turn.

import { expect, mock, test } from 'claude-code/testing'
import type { On, SessionMeasureInput, TurnStepInput } from 'claude-code'

import { MODEL_POLL_MS, displayName, measureFields, modelFields, statuslinePath } from '../hooks/usage'
import { SUPPORTED } from '../hooks/version'

const START = { cwd: '/tmp', surface: 'terminal', isInteractive: false } as const
const NOW = 1_000_000_000_000

function engine(on: On, version: string = SUPPORTED.min, env: Record<string, string> = { TMUX_PANE: '%7' }) {
  const runs: string[][] = []
  const model = { id: 'claude-opus-5-5' }
  on('session.version', () => ({ value: { version, base: version } }))
  on('session.model', () => ({ value: model.id }))
  on('process.run', (_$, e) => {
    runs.push([...e.argv])
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.end', (_$, e) => ({ sessionId: e.sessionId }))
  on('session.measure', (_$, e) => ({ changed: e.changed }))
  on('turn.step', async function* (_$, e) {
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'end_turn', usage: null }
  })
  mock.env(on, env)
  const clock = mock.clock(on, { now: NOW })
  return { runs, model, clock }
}

/** The statusline feeds, each as its key=value fields (after `--from mod`). */
function feeds(runs: string[][]): string[][] {
  return runs
    .filter(argv => argv[0] === 'bash' && (argv[1] ?? '').endsWith('/conf/statusline.sh'))
    .map(argv => {
      expect(argv[2]).toBe('--from')
      expect(argv[3]).toBe('mod')
      return argv.slice(4)
    })
}

const STEP: TurnStepInput = { turnId: 't1', index: 0, model: 'claude-opus-5-5', effort: 'high', messageCount: 3 }

/** Fire one model request through the chain the way the engine does, reading its stream to the end. */
async function step($: { turn: { step: (input: TurnStepInput) => AsyncIterable<unknown> } }, input: TurnStepInput): Promise<void> {
  for await (const _chunk of $.turn.step(input)) { /* drain */ }
}

const FULL: SessionMeasureInput = {
  context: { tokens: 84_000, window: 200_000, percent: 42.4 },
  rateLimits: [
    { kind: 'five_hour', percentUsed: 37.5, resetsAt: '2001-09-09T03:00:00Z' },
    { kind: 'seven_day', percentUsed: 12, resetsAt: '2001-09-14T00:00:00.000Z' },
  ],
  changed: ['context', 'rateLimits'],
}

test('pure: the display name Claude Code spells, the fields, the script path', () => {
  expect(displayName('claude-opus-5-5')).toBe('Opus 5.5')
  expect(displayName('claude-haiku-4-5-20251001')).toBe('Haiku 4.5')
  expect(displayName('claude-fable-5-1')).toBe('Fable 5.1')
  expect(displayName('claude-sonnet-4-6[1m]')).toBe('Sonnet 4.6 (1M context)')
  expect(displayName('us.anthropic.claude-opus-5-5-v1:0')).toBe('us.anthropic.claude-opus-5-5-v1:0')
  expect(displayName(' opus ')).toBe('opus')
  expect(modelFields('claude-opus-5-5', 'high')).toEqual(['model=Opus 5.5', 'effort=high'])
  expect(modelFields('claude-opus-5-5', undefined)).toEqual(['model=Opus 5.5'])
  expect(modelFields('claude-opus-5-5', 50_000)).toEqual(['model=Opus 5.5', 'effort=50000'])
  expect(statuslinePath('/i/mod/fleet')).toBe('/i/mod/fleet/../../conf/statusline.sh')
  expect(statuslinePath('/i/mod/fleet/.claude-plugin/')).toBe('/i/mod/fleet/../../conf/statusline.sh')
  expect(measureFields(FULL)).toEqual([
    'ctx_pct=42.40', 'ctx_limit=200000', 'rl5h=37', 'rl7d=12',
    `rl_reset5=${Date.parse('2001-09-09T03:00:00Z') / 1000}`, `rl_reset7=${Date.parse('2001-09-14T00:00:00Z') / 1000}`,
  ])
  expect(measureFields({ context: { window: 1_000_000, percent: 7 }, rateLimits: [{ kind: 'five_hour', percentUsed: 50 }] }))
    .toEqual(['ctx_pct=7.00', 'ctx_limit=1000000'])
  expect(measureFields({ context: { window: 200_000 }, rateLimits: [] })).toEqual([])
})

test('a measurement feeds conf/statusline.sh --from mod with the context + rate-limit fields', async ($, on) => {
  const { runs } = engine(on)
  await $.session.start(START)
  const before = feeds(runs).length
  await $.session.measure(FULL)
  const got = feeds(runs).slice(before)
  expect(got).toEqual([measureFields(FULL)])
  // One bash run for the whole measurement, no tmux call of the mod's own.
  expect(runs.some(argv => argv[0] === 'tmux' && argv.includes('@ctx_pct'))).toBe(false)
})

test('a half reading: context only — no rate-limit fields', async ($, on) => {
  const { runs } = engine(on)
  await $.session.start(START)
  const before = feeds(runs).length
  await $.session.measure({ context: { window: 1_000_000, percent: 7 }, rateLimits: [{ kind: 'five_hour', percentUsed: 50 }], changed: ['context'] })
  expect(feeds(runs).slice(before)).toEqual([['ctx_pct=7.00', 'ctx_limit=1000000']])
})

test('no fill yet and no rate limits, or only the cost moved: no feed at all', async ($, on) => {
  const { runs } = engine(on)
  await $.session.start(START)
  const before = runs.length
  await $.session.measure({ context: { window: 200_000 }, rateLimits: [], changed: ['cost'] })
  await $.session.measure({ context: { window: 200_000 }, rateLimits: [], changed: ['context'] })
  expect(runs.length).toBe(before)
})

test('session.start feeds the model at once; a /model lands within one poll, as the model alone', async ($, on) => {
  const { runs, model, clock } = engine(on)
  await $.session.start(START)
  expect(feeds(runs)).toEqual([['model=Opus 5.5']])
  await clock.advance(MODEL_POLL_MS * 3)
  expect(feeds(runs).length).toBe(1)                       // unchanged: no re-feed
  model.id = 'claude-fable-5-1'
  await clock.advance(MODEL_POLL_MS)
  expect(feeds(runs)).toEqual([['model=Opus 5.5'], ['model=Fable 5.1']])
})

test('turn.step feeds model + effort once per change; a subagent step is ignored; the stream passes', async ($, on) => {
  const { runs } = engine(on)
  await $.session.start(START)
  await step($, STEP)
  await step($, { ...STEP, index: 1 })                        // same pair: nothing
  await step($, { ...STEP, index: 2, agentId: 'agent-1', model: 'claude-haiku-4-5' })
  await step($, { ...STEP, index: 3, effort: 'max' })
  await step($, { ...STEP, index: 4, model: 'claude-haiku-4-5-20251001', effort: undefined })
  expect(feeds(runs)).toEqual([
    ['model=Opus 5.5'],                                        // session.start's poll
    ['model=Opus 5.5', 'effort=high'],
    ['model=Opus 5.5', 'effort=max'],
    ['model=Haiku 4.5'],                                       // no effort ⇒ the script unsets @effort
  ])
})

test('gate shut (out-of-range engine): nothing is fed, nothing polled', async ($, on) => {
  const { runs, clock } = engine(on, '9.0.0')
  await $.session.start(START)
  await $.session.measure(FULL)
  await step($, STEP)
  await clock.advance(MODEL_POLL_MS * 2)
  expect(feeds(runs)).toEqual([])
})

test('outside tmux: no TMUX_PANE, no feed', async ($, on) => {
  const { runs, clock } = engine(on, SUPPORTED.min, {})
  await $.session.start(START)
  await $.session.measure(FULL)
  await step($, STEP)
  await clock.advance(MODEL_POLL_MS)
  expect(runs).toEqual([])
})

test('a real exit stops the model poll', async ($, on) => {
  const { runs, model, clock } = engine(on)
  await $.session.start(START)
  await $.session.end({ reason: 'prompt_input_exit', sessionId: 's', resume: { id: 's' } })
  model.id = 'claude-fable-5-1'
  await clock.advance(MODEL_POLL_MS * 2)
  expect(feeds(runs)).toEqual([['model=Opus 5.5']])
})
