// The orchestrator's role in every request (issue #2582). A mocked engine: the
// version answers in range; `process.run` answers the window's @fleet_role with
// whatever the test sets; `fs.read` answers role.md; `prompt.compose` answers the
// engine's own two sections, and the plugin's hook adds the role after them.

import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { ROLE_SECTION, isBodyRun, isRoleRun, resetRole, rolePath, takeRole, currentRole } from '../hooks/orchestrator'
import { SUPPORTED } from '../hooks/version'

const START = { cwd: '/tmp', surface: 'terminal', isInteractive: false } as const
const COMPOSE = { model: 'claude-opus-5-5', promptModel: 'claude-opus-5-5', surfaces: ['terminal'], tools: [], outputStyle: null, traits: [] } as const
const ROLE_MD = '# 你是编排会话（fleet 的编排会话）\n先谈，再派。\n'

const BODY = '/c/roles/orchestrator-0123456789abcdef.md'
const BODY_MD = '# 你是编排会话（fleet 的编排会话）\n照定义来。\n'

function engine(on: On, windowRole: string, file: string | null = ROLE_MD, body = '') {
  const reads: string[] = []
  on('session.version', () => ({ value: { version: SUPPORTED.min, base: SUPPORTED.min } }))
  on('session.model', () => ({ value: 'claude-opus-5-5' }))
  on('process.run', (_$, e) => {
    const stdout = isRoleRun(e.argv) ? `${windowRole}\n` : isBodyRun(e.argv) ? `${body}\n` : ''
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.read', (_$, e) => {
    reads.push(e.path)
    if (body !== '' && e.path === body && body === BODY) return { value: BODY_MD }
    if (file === null || !e.path.endsWith('/skills/fleet-orchestrate/role.md')) throw new Error('ENOENT')
    return { value: file }
  })
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.end', (_$, e) => ({ sessionId: e.sessionId }))
  on('prompt.compose', () => ({
    sections: [
      { id: 'intro', text: 'engine intro', scope: 'shared' },
      { id: 'env', text: 'engine env', scope: 'session' },
    ],
  }))
  mock.env(on, { TMUX_PANE: '%7' })
  mock.clock(on, { now: 1_000_000_000_000 })
  return { reads }
}

test('role.md sits in the install beside the plugin: <install>/skills', () => {
  expect(rolePath('/i/mod/fleet')).toBe('/i/mod/fleet/../../skills/fleet-orchestrate/role.md')
  expect(rolePath('/i/mod/fleet/.claude-plugin/')).toBe('/i/mod/fleet/../../skills/fleet-orchestrate/role.md')
})

test('only an orchestrator window with a non-empty file keeps a role', () => {
  resetRole()
  takeRole('orchestrator\n', ROLE_MD)
  expect(currentRole()).toBe(ROLE_MD.trim())
  takeRole('worker', ROLE_MD)
  expect(currentRole()).toBe(undefined)
  takeRole('orchestrator', '  \n')
  expect(currentRole()).toBe(undefined)
})

test('the orchestrator carries its role in every request, as a session section', async ($, on) => {
  resetRole()
  engine(on, 'orchestrator')
  await $.session.start(START)
  const { sections } = await $.prompt.compose(COMPOSE)
  const role = sections.find(s => s.id === ROLE_SECTION)
  expect(role?.scope).toBe('session')
  expect(role?.text).toContain('编排会话')
  // a /clear ends the session but fires no new start: the module keeps the role
  await $.session.end({ reason: 'clear', sessionId: 's', resume: { id: 's' } })
  expect((await $.prompt.compose(COMPOSE)).sections.map(s => s.id)).toContain(ROLE_SECTION)
})

test('a worker window never sees it, and its file is never read', async ($, on) => {
  resetRole()
  const { reads } = engine(on, 'worker')
  await $.session.start(START)
  expect((await $.prompt.compose(COMPOSE)).sections.map(s => s.id)).not.toContain(ROLE_SECTION)
  expect(reads.filter(p => p.endsWith('role.md'))).toEqual([])
})

test('a role.md that cannot be read adds nothing', async ($, on) => {
  resetRole()
  engine(on, 'orchestrator', null)
  await $.session.start(START)
  expect((await $.prompt.compose(COMPOSE)).sections.map(s => s.id)).not.toContain(ROLE_SECTION)
})

test('the rendered body the launcher stamped (#2782) is the text, the skill copy its fallback', async ($, on) => {
  resetRole()
  const { reads } = engine(on, 'orchestrator', ROLE_MD, BODY)
  await $.session.start(START)
  const role = (await $.prompt.compose(COMPOSE)).sections.find(s => s.id === ROLE_SECTION)
  expect(role?.text).toBe(BODY_MD.trim())
  expect(reads).toContain(BODY)
  expect(reads.filter(p => p.endsWith('/skills/fleet-orchestrate/role.md'))).toEqual([])
})

test('a stamped body that cannot be read falls back to the skill copy', async ($, on) => {
  resetRole()
  engine(on, 'orchestrator', ROLE_MD, '/c/roles/gone.md')
  await $.session.start(START)
  const role = (await $.prompt.compose(COMPOSE)).sections.find(s => s.id === ROLE_SECTION)
  expect(role?.text).toBe(ROLE_MD.trim())
})
