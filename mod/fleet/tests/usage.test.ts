// Context + quota reported by the session (issue #1338). A mocked engine: the
// version answers in range, `process.run` records every tmux argv, and the test
// fires `session.measure` itself the way the engine does after a turn.

import { expect, mock, test } from 'claude-code/testing'
import type { On, SessionMeasureInput } from 'claude-code'

import { SUPPORTED } from '../hooks/version'

const START = { cwd: '/tmp', surface: 'terminal', isInteractive: false } as const
const NOW = 1_000_000_000_000

function engine(on: On, version: string = SUPPORTED.min, env: Record<string, string> = { TMUX_PANE: '%7' }) {
  const runs: string[][] = []
  on('session.version', () => ({ value: { version, base: version } }))
  on('process.run', (_$, e) => {
    runs.push([...e.argv])
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.measure', (_$, e) => ({ changed: e.changed }))
  mock.env(on, env)
  mock.clock(on, { now: NOW })
  return runs
}

/** Every value a run SETS on `key` (`set-option -w -t <pane> <key> <value>`), in order. */
function sets(runs: string[][], key: string): string[] {
  const out: string[] = []
  for (const argv of runs) {
    for (let i = 0; i < argv.length; i++) {
      if (argv[i] === key && argv[i - 2] === '-t' && argv[i - 3] === '-w') out.push(argv[i + 1] ?? '')
    }
  }
  return out
}

const FULL: SessionMeasureInput = {
  context: { tokens: 84_000, window: 200_000, percent: 42 },
  rateLimits: [
    { kind: 'five_hour', percentUsed: 37.5, resetsAt: '2001-09-09T03:00:00Z' },
    { kind: 'seven_day', percentUsed: 12, resetsAt: '2001-09-14T00:00:00.000Z' },
  ],
  changed: ['context', 'rateLimits'],
}

test('a measurement stamps @ctx_pct/@ctx_limit and the @rl_* set with @rl_src mod', async ($, on) => {
  const runs = engine(on)
  await $.session.start(START)
  await $.session.measure(FULL)
  expect(sets(runs, '@ctx_pct')).toEqual(['42'])
  expect(sets(runs, '@ctx_limit')).toEqual(['200000'])
  expect(sets(runs, '@rl5h')).toEqual(['37'])
  expect(sets(runs, '@rl7d')).toEqual(['12'])
  expect(sets(runs, '@rl_reset')).toEqual([`${Date.parse('2001-09-09T03:00:00Z') / 1000} ${Date.parse('2001-09-14T00:00:00Z') / 1000}`])
  expect(sets(runs, '@rl_ts')).toEqual([String(NOW / 1000)])
  expect(sets(runs, '@rl_src')).toEqual(['mod'])
  // One tmux call for the whole measurement, pinned to this pane.
  const usage = runs.filter(argv => argv.includes('@ctx_pct'))
  expect(usage.length).toBe(1)
  expect(usage[0]?.includes('%7')).toBe(true)
})

test('a half reading: context only, no rate limits — @rl_* untouched', async ($, on) => {
  const runs = engine(on)
  await $.session.start(START)
  await $.session.measure({ context: { window: 1_000_000, percent: 7 }, rateLimits: [{ kind: 'five_hour', percentUsed: 50 }], changed: ['context'] })
  expect(sets(runs, '@ctx_pct')).toEqual(['7'])
  expect(sets(runs, '@ctx_limit')).toEqual(['1000000'])
  expect(sets(runs, '@rl5h')).toEqual([])
  expect(sets(runs, '@rl_src')).toEqual([])
})

test('no fill yet and no rate limits: no tmux write at all', async ($, on) => {
  const runs = engine(on)
  await $.session.start(START)
  const before = runs.length
  await $.session.measure({ context: { window: 200_000 }, rateLimits: [], changed: ['cost'] })
  await $.session.measure({ context: { window: 200_000 }, rateLimits: [], changed: ['context'] })
  expect(runs.length).toBe(before)
})

test('gate shut (out-of-range engine): measurements write nothing', async ($, on) => {
  const runs = engine(on, '9.0.0')
  await $.session.start(START)
  await $.session.measure(FULL)
  expect(sets(runs, '@ctx_pct')).toEqual([])
  expect(sets(runs, '@rl5h')).toEqual([])
})

test('outside tmux: no TMUX_PANE, no tmux call', async ($, on) => {
  const runs = engine(on, SUPPORTED.min, {})
  await $.session.start(START)
  await $.session.measure(FULL)
  expect(runs).toEqual([])
})
