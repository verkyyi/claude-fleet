// The version gate + heartbeat (issue #1335). Beneath the plugin, the test's
// own hooks stand for the engine: `session.version` answers a chosen release,
// `process.run` records every tmux argv instead of running it, and the mocked
// clock moves only when the test moves it.

import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { HEARTBEAT_MS } from '../hooks/lifecycle'
import { SUPPORTED, isSupported } from '../hooks/version'
import { isWhereRun } from '../hooks/where'

const START = { cwd: '/tmp', surface: 'terminal', isInteractive: true } as const

function engine(on: On, version: string, env: Record<string, string> = { TMUX_PANE: '%7' }) {
  const runs: string[][] = []
  on('session.version', () => ({ value: { version, base: version } }))
  on('process.run', (_$, e) => {
    if (!isWhereRun(e.argv)) runs.push([...e.argv])
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.end', (_$, e) => ({ sessionId: e.sessionId }))
  mock.env(on, env)
  const clock = mock.clock(on, { now: 1_000_000_000_000 })
  return { runs, clock }
}

/** The value each `set-option -w [-u] -t <pane> <key> [value]` in a run gives `key`. */
function option(runs: string[][], key: string): Array<string | null> {
  const out: Array<string | null> = []
  for (const argv of runs) {
    for (let i = 0; i < argv.length; i++) {
      if (argv[i] !== key || argv[i - 1] === undefined) continue
      out.push(argv[i - 4] === '-u' || argv[i - 3] === '-u' ? null : (argv[i + 1] ?? ''))
    }
  }
  return out
}

test('version range: inclusive min, exclusive ceiling, dev spellings', () => {
  expect(isSupported(SUPPORTED.min)).toBe(true)
  expect(isSupported(`${SUPPORTED.min}-dev.20261003.t101500.sha1a2b3c4`)).toBe(true)
  expect(isSupported(SUPPORTED.below)).toBe(false)
  expect(isSupported('2.1.0')).toBe(false)
  expect(isSupported('not-a-version')).toBe(false)
})

test('in range: @mod_state on, @mod_ver, and a heartbeat every 15s', async ($, on) => {
  const { runs, clock } = engine(on, SUPPORTED.min)
  await $.session.start(START)
  expect(option(runs, '@mod_state')).toEqual(['on'])
  expect(option(runs, '@mod_ver').length).toBe(1)
  expect(option(runs, '@mod_alive')).toEqual(['1000000000'])
  expect(runs.filter(argv => argv[0] !== 'bash').every(argv => argv.includes('%7'))).toBe(true)
  await clock.advance(HEARTBEAT_MS)
  await clock.advance(HEARTBEAT_MS)
  expect(option(runs, '@mod_alive')).toEqual(['1000000000', '1000000015', '1000000030'])
})

test('out of range: registers nothing past the gate — off:version, no heartbeat', async ($, on) => {
  const { runs, clock } = engine(on, '9.0.0')
  await $.session.start(START)
  expect(option(runs, '@mod_state')).toEqual(['off:version'])
  // The only @mod_alive write is the UNSET of a stale one; no beat ever follows.
  expect(option(runs, '@mod_alive')).toEqual([null])
  await clock.advance(HEARTBEAT_MS * 4)
  expect(option(runs, '@mod_alive')).toEqual([null])
  await $.session.end({ reason: 'prompt_input_exit', sessionId: 's', resume: { id: 's' } })
  expect(option(runs, '@mod_alive')).toEqual([null])
})

test('a /clear keeps beating; a real exit unsets @mod_alive and stops', async ($, on) => {
  const { runs, clock } = engine(on, SUPPORTED.min)
  await $.session.start(START)
  await $.session.end({ reason: 'clear', sessionId: 's', resume: { id: 's' } })
  await clock.advance(HEARTBEAT_MS)
  expect(option(runs, '@mod_alive')).toEqual(['1000000000', '1000000015'])
  await $.session.end({ reason: 'prompt_input_exit', sessionId: 's', resume: { id: 's' } })
  await clock.advance(HEARTBEAT_MS * 2)
  expect(option(runs, '@mod_alive')).toEqual(['1000000000', '1000000015', null])
})

test('outside tmux: no TMUX_PANE, no tmux call at all', async ($, on) => {
  const { runs, clock } = engine(on, SUPPORTED.min, {})
  await $.session.start(START)
  await clock.advance(HEARTBEAT_MS)
  expect(runs).toEqual([])
})
