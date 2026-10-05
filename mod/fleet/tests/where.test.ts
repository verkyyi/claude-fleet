// Where the person is, in the session's context (issue #1716). A mocked engine:
// the version answers in range; `process.run` answers the where script with
// whatever the test sets (and tmux with nothing); `prompt.compose` answers the
// engine's own two sections, and the plugin's hook adds its line after them.

import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { SUPPORTED } from '../hooks/version'
import { WHERE_POLL_MS, WHERE_SECTION, resetWhere, takeWhere, whereArgv } from '../hooks/where'

const START = { cwd: '/tmp', surface: 'terminal', isInteractive: false } as const
const COMPOSE = { model: 'claude-opus-5-5', promptModel: 'claude-opus-5-5', surfaces: ['terminal'], tools: [], outputStyle: null, traits: [] } as const

function engine(on: On) {
  const where = { exitCode: 0, stdout: 'MacBook · macOS · iTerm2 3.6 · 能：打开网页、收文件、系统通知、iTerm2\n', runs: 0 }
  on('session.version', () => ({ value: { version: SUPPORTED.min, base: SUPPORTED.min } }))
  on('session.model', () => ({ value: 'claude-opus-5-5' }))
  on('process.run', (_$, e) => {
    const isWhere = (e.argv[1] ?? '').endsWith('/bin/fleet-client-where.sh')
    if (isWhere) where.runs++
    const value = isWhere ? { exitCode: where.exitCode, stdout: where.stdout } : { exitCode: 0, stdout: '' }
    return { value: { ...value, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('prompt.compose', () => ({
    sections: [
      { id: 'intro', text: 'engine intro', scope: 'shared' },
      { id: 'env', text: 'engine env', scope: 'session' },
    ],
  }))
  mock.env(on, { TMUX_PANE: '%7' })
  const clock = mock.clock(on, { now: 1_000_000_000_000 })
  return { where, clock }
}

function whereText(sections: readonly { id: string; text: string }[]): string | undefined {
  return sections.find(s => s.id === WHERE_SECTION)?.text
}

test('the script path sits beside the plugin: <install>/bin', () => {
  expect(whereArgv('/i/mod/fleet')).toEqual(['bash', '/i/mod/fleet/../../bin/fleet-client-where.sh'])
  expect(whereArgv('/i/mod/fleet/.claude-plugin/')).toEqual(['bash', '/i/mod/fleet/../../bin/fleet-client-where.sh'])
})

test('a failed read keeps the line; 0 and 3 replace it', () => {
  resetWhere()
  expect(takeWhere(0, 'A · iTerm2\n')).toBe(true)
  expect(takeWhere(1, '')).toBe(false)
  expect(takeWhere(0, 'A · iTerm2')).toBe(false)
  expect(takeWhere(3, '此刻没有客户端连着\n')).toBe(true)
})

test('the line is in the context from the start, last, as a session section', async ($, on) => {
  resetWhere()
  engine(on)
  await $.session.start(START)
  const { sections } = await $.prompt.compose(COMPOSE)
  expect(sections.map(s => s.id)).toEqual(['intro', 'env', WHERE_SECTION])
  expect(sections[2]!.scope).toBe('session')
  expect(whereText(sections)).toContain('操作者此刻在：MacBook · macOS · iTerm2 3.6')
})

test('a takeover reaches the context within one poll; a failed read keeps the last', async ($, on) => {
  resetWhere()
  const { where, clock } = engine(on)
  await $.session.start(START)
  where.stdout = 'verkyyi-iphone · iOS · Termius（客户端在 m5 上运行）· 能：给链接\n'
  await clock.advance(WHERE_POLL_MS)
  expect(whereText((await $.prompt.compose(COMPOSE)).sections)).toContain('verkyyi-iphone · iOS · Termius（客户端在 m5 上运行）')
  where.exitCode = 1
  where.stdout = ''
  await clock.advance(WHERE_POLL_MS)
  expect(whereText((await $.prompt.compose(COMPOSE)).sections)).toContain('verkyyi-iphone')
  expect(where.runs).toBe(3)
})

test('no answer yet: nothing is added', async ($, on) => {
  resetWhere()
  const { where } = engine(on)
  where.exitCode = 1
  where.stdout = ''
  await $.session.start(START)
  expect((await $.prompt.compose(COMPOSE)).sections.map(s => s.id)).toEqual(['intro', 'env'])
})
