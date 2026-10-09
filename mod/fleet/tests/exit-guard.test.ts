// A slip of the hand must not end the orchestrator (issue #2584). A mocked
// engine: the version answers in range; `process.run` answers the window's
// @fleet_role with whatever the test sets; `command.run` beneath the plugin
// stands for the engine's own command and records each one that RAN;
// `prompt.submit` beneath it records each prompt that entered.

import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { CONFIRM_MS, DEFER_MS, confirmForm, resetGuard } from '../hooks/exit-guard'
import { isRoleRun, resetRole } from '../hooks/orchestrator'
import { SUPPORTED } from '../hooks/version'

const START = { cwd: '/tmp', surface: 'terminal', isInteractive: true } as const
const PRESENT = { layout: 'main', columns: 80 } as never
const HAND = { kind: 'composer' } as const
const PLUGIN = { kind: 'plugin', name: 'fleet' } as const

function engine(on: On, windowRole: string) {
  const ran: string[] = []
  const entered: string[] = []
  on('session.version', () => ({ value: { version: SUPPORTED.min, base: SUPPORTED.min } }))
  on('process.run', (_$, e) => {
    const stdout = isRoleRun(e.argv) ? `${windowRole}\n` : ''
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.read', () => ({ value: '# 你是编排会话\n' }))
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.end', (_$, e) => ({ sessionId: e.sessionId }))
  on('command.run', (_$, e) => {
    ran.push(`/${e.command}${e.args === '' ? '' : ` ${e.args}`}`)
    return { text: 'ran' }
  })
  on('prompt.submit', (_$, e) => {
    entered.push(e.text)
    return { text: e.text }
  })
  mock.env(on, { TMUX_PANE: '%7' })
  const clock = mock.clock(on, { now: 1_000_000_000_000 })
  return { ran, entered, clock }
}

function cmd(command: string, origin: typeof HAND | typeof PLUGIN = HAND, args = '') {
  return { command, args, origin, presentation: PRESENT }
}

test('confirmForm: exactly /<command>!, aliases folded', () => {
  expect(confirmForm('/exit!')).toBe('exit')
  expect(confirmForm(' /quit! ')).toBe('exit')
  expect(confirmForm('/clear!')).toBe('clear')
  expect(confirmForm('/new!')).toBe('clear')
  expect(confirmForm('/exit')).toBe(undefined)
  expect(confirmForm('/exit! now')).toBe(undefined)
  expect(confirmForm('exit!')).toBe(undefined)
})

test('the orchestrator: the first /exit is a hint and does not run; the second within 60s runs', async ($, on) => {
  resetRole()
  resetGuard()
  const { ran, clock } = engine(on, 'orchestrator')
  await $.session.start(START)
  const first = await $.command.run(cmd('exit'))
  expect(ran).toEqual([])
  expect(first.text).toContain('这是编排会话')
  expect(first.text).toContain('⌃D')
  expect(first.text).toContain('/exit!')
  await clock.advance(CONFIRM_MS - 1000)
  await $.command.run(cmd('exit'))
  expect(ran).toEqual(['/exit'])
})

test('the orchestrator: a second /exit after 60s is a hint again; /clear arms on its own', async ($, on) => {
  resetRole()
  resetGuard()
  const { ran, clock } = engine(on, 'orchestrator')
  await $.session.start(START)
  await $.command.run(cmd('exit'))
  await clock.advance(CONFIRM_MS + 1000)
  expect((await $.command.run(cmd('exit'))).text).toContain('这是编排会话')
  expect((await $.command.run(cmd('clear'))).text).toContain('/clear!')
  expect(ran).toEqual([])
  await $.command.run(cmd('clear'))
  expect(ran).toEqual(['/clear'])
})

test('the orchestrator: /exit! runs the real /exit a moment later and reaches no model', async ($, on) => {
  resetRole()
  resetGuard()
  const { ran, entered, clock } = engine(on, 'orchestrator')
  await $.session.start(START)
  const r = await $.prompt.submit({ text: '/exit!', origin: HAND, wait: false })
  expect('drop' in r && r.drop !== undefined).toBe(true)
  expect(ran).toEqual([])
  await clock.advance(DEFER_MS)
  expect(entered).toEqual([])
  expect(ran).toEqual(['/exit'])
  // typed with a space it is the command's argument, and confirms the same
  await $.command.run(cmd('clear', HAND, '!'))
  expect(ran).toEqual(['/exit', '/clear'])
})

test('the orchestrator: a plugin run (the command inbox) is never guarded', async ($, on) => {
  resetRole()
  resetGuard()
  const { ran } = engine(on, 'orchestrator')
  await $.session.start(START)
  await $.command.run(cmd('clear', PLUGIN))
  await $.command.run(cmd('exit', PLUGIN))
  expect(ran).toEqual(['/clear', '/exit'])
})

test('any other window: /exit and /clear run at once, /exit! is an ordinary prompt', async ($, on) => {
  resetRole()
  resetGuard()
  const { ran, entered } = engine(on, 'worker')
  await $.session.start(START)
  await $.command.run(cmd('exit'))
  await $.command.run(cmd('clear'))
  await $.prompt.submit({ text: '/exit!', origin: HAND, wait: false })
  expect(ran).toEqual(['/exit', '/clear'])
  expect(entered).toEqual(['/exit!'])
})
