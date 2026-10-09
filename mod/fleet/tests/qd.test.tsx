// /qd, the orchestrator's quick dispatch (issue #2618). A mocked engine: the
// version answers in range; `process.run` answers the window's @fleet_role, the
// `qd_` strings dump, `fleet-mcp.py --call repos` and `--call file_issue` (each
// file_issue recorded with its arguments); `command.register`, `ui.open`,
// `ui.close` and `ui.toast` beneath the plugin record what the plugin asked.

import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { isRoleRun } from '../hooks/orchestrator'
import { resetRole } from '../hooks/orchestrator'
import {
  QD_COMMAND, QD_PANE, hints, isStringsRun, issueNumber, parseReport, parseRepos, pickRepo, takeStrings, t,
} from '../hooks/qd'
import { SUPPORTED } from '../hooks/version'

const START = { cwd: '/tmp', surface: 'terminal', isInteractive: true } as const
const PRESENT = { layout: 'main', columns: 80 } as never
const HAND = { kind: 'composer' } as const

const DUMP = [
  'qd_title', '快速派发', 'qd_desc', '快速派发说明', 'qd_empty', '标题是空的', 'qd_norepo', '读不到仓库',
  'qd_done_fmt', '已建 #\u0001 并开工', 'qd_failed_fmt', '没派出去：\u0001', 'qd_hint', '↵ 建单',
].join('\0') + '\0'

const REPOS = 'exit 0 · fleet-repo.sh\nfleet fleet hosts:\n' +
  '  verkyyi/claude-fleet                 main=/x  base=master  [repos/a.conf]\n' +
  '  acme/web main=/y  base=main  [repos/b.conf]'

const FILED = 'exit 0 · fleet-issue-file.sh\nhttps://github.com/acme/web/issues/77\n[stderr]\n' +
  'fleet-issue-file: hint: the title is 44 columns — keep it to one use, ≤ 20 汉字'

type Filed = Record<string, unknown>

function engine(
  on: On, windowRole: string,
  answer: () => { exitCode: number; stdout: string } = () => ({ exitCode: 0, stdout: FILED }),
  roleFile = true,
) {
  const filed: Filed[] = []
  const registered: { name: string; immediate?: true }[] = []
  const opened: string[] = []
  const closed: string[] = []
  const toasts: string[] = []
  const entered: string[] = []
  on('session.version', () => ({ value: { version: SUPPORTED.min, base: SUPPORTED.min } }))
  on('process.run', (_$, e) => {
    let out = { exitCode: 0, stdout: '' }
    if (isRoleRun(e.argv)) out.stdout = `${windowRole}\n`
    else if (isStringsRun(e.argv)) out.stdout = DUMP
    else if (e.argv.includes('--call') && e.argv.includes('repos')) out.stdout = REPOS
    else if (e.argv.includes('--call') && e.argv.includes('file_issue')) {
      filed.push(JSON.parse(e.argv[e.argv.length - 1] as string) as Filed)
      out = answer()
    }
    return { value: { ...out, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.read', () => {
    if (!roleFile) throw new Error('ENOENT')
    return { value: '# 你是编排会话\n' }
  })
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('command.register', (_$, e) => {
    registered.push(e)
    return { value: { command: e.name } }
  })
  on('command.run', () => ({ text: 'engine' }))
  on('ui.open', (_$, e) => {
    opened.push(e.id)
    return { value: { isPlaced: true } }
  })
  on('ui.close', (_$, e) => {
    closed.push(e.id)
    return { value: undefined }
  })
  on('ui.toast', (_$, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('prompt.submit', (_$, e) => {
    entered.push(e.text)
    return { text: e.text }
  })
  mock.store(on)
  return { filed, registered, opened, closed, toasts, entered }
}

const PANE = {
  title: '快速派发', isFocused: true, bodyColumns: 70, placement: 'inline', scroll: { offset: 0, rows: 6 },
} as never

async function openQd($: Parameters<Parameters<typeof test>[1]>[0]) {
  await $.command.run({ command: QD_COMMAND, args: '', origin: HAND, presentation: PRESENT })
  return $.ui.mount({ plugin: 'fleet', surface: 'terminal', component: 'Pane', requestId: QD_PANE, props: PANE })
}

test('qd: the report, the repo list, the issue number, the hints', () => {
  expect(parseReport('exit 3 · fleet-issue-file.sh\nout\n[stderr]\nerr')).toEqual({ exit: 3, stdout: 'out', stderr: 'err' })
  expect(parseReport('fleet.file_issue: no. Nothing ran.').exit).toBe(null)
  expect(parseRepos(REPOS)).toEqual(['verkyyi/claude-fleet', 'acme/web'])
  expect(issueNumber('https://github.com/acme/web/issues/77')).toBe('77')
  expect(hints('a\nfleet-issue-file: hint: x\nb')).toEqual(['fleet-issue-file: hint: x'])
  expect(pickRepo(['a/b', 'c/d'], 'c/d')).toBe('c/d')
  expect(pickRepo(['a/b', 'c/d'], 'gone/x')).toBe('a/b')
  takeStrings(DUMP)
  expect(t('qd_done_fmt', '9')).toBe('已建 #9 并开工')
  expect(t('qd_nope')).toBe('qd_nope')
})

test('qd: only the orchestrator window registers /qd, immediate', async ($, on) => {
  resetRole()
  const { registered } = engine(on, 'worker')
  mock.env(on, { TMUX_PANE: '%7' })
  await $.session.start(START)
  expect(registered.map(c => c.name)).not.toContain(QD_COMMAND)
})

test('qd: in the orchestrator, /qd mid-turn opens the dialog; Enter files exactly once with spawn', async ($, on) => {
  resetRole()
  const { registered, opened, closed, toasts, filed } = engine(on, 'orchestrator')
  mock.env(on, { TMUX_PANE: '%7' })
  await $.session.start(START)
  const qd = registered.find(c => c.name === QD_COMMAND)
  expect(qd?.immediate).toBe(true)
  const ui = await openQd($)
  expect(opened).toEqual([QD_PANE])
  expect((await ui.find({ key: 'qd-repo' }))).toBeDefined()
  await ui.select({ key: 'qd-repo', value: 'acme/web' })
  await ui.input({ key: 'qd-title', text: '首页加载变慢' })
  expect(filed).toEqual([{ title: '首页加载变慢', spawn: true, repo: 'acme/web' }])
  expect(closed).toEqual([QD_PANE])
  expect(toasts.some(x => x.startsWith('已建 #77 并开工') && x.includes('hint:'))).toBe(true)
  await ui.unmount()
})

test('qd: an empty title dispatches nothing and says so', async ($, on) => {
  resetRole()
  const { filed, closed } = engine(on, 'orchestrator')
  mock.env(on, { TMUX_PANE: '%7' })
  await $.session.start(START)
  const ui = await openQd($)
  await ui.input({ key: 'qd-title', text: '   ' })
  expect(filed).toEqual([])
  expect(closed).toEqual([])
  expect(await ui.find({ text: /标题是空的/ })).toBeDefined()
  await ui.unmount()
})

test('qd: a failed dispatch keeps the dialog, the title and the reason', async ($, on) => {
  resetRole()
  const { filed, closed } = engine(on, 'orchestrator', () => ({
    exitCode: 1, stdout: 'fleet.file_issue: repo "x/y" is not hosted by this fleet. Nothing ran.',
  }))
  mock.env(on, { TMUX_PANE: '%7' })
  await $.session.start(START)
  const ui = await openQd($)
  await ui.input({ key: 'qd-title', text: '修登录' })
  expect(filed.length).toBe(1)
  expect(closed).toEqual([])
  expect(await ui.find({ text: /没派出去：.*not hosted/ })).toBeDefined()
  expect((await ui.find({ key: 'qd-title' }))?.props.value).toBe('修登录')
  await ui.unmount()
})

test('qd: the 派： prefix is off by default; on, a mid-turn one is dropped and dispatched', async ($, on) => {
  resetRole()
  const { filed, entered } = engine(on, 'orchestrator')
  mock.env(on, { TMUX_PANE: '%7', FLEET_ORCH_QD_PREFIX: '1' })
  await $.session.start(START)
  // Idle: goes to the model as typed.
  await $.prompt.submit({ text: '派：修登录', wait: false, origin: HAND })
  expect(filed).toEqual([])
  // Mid-turn: never queued, filed once.
  await $.prompt.submit({ text: '派：修登录', wait: false, origin: HAND, turnId: 't1' })
  expect(filed).toEqual([{ title: '修登录', spawn: true, repo: 'verkyyi/claude-fleet' }])
  expect(entered).toEqual(['派：修登录'])
})

test('qd: without FLEET_ORCH_QD_PREFIX the 派： prefix just queues', async ($, on) => {
  resetRole()
  const { filed, entered } = engine(on, 'orchestrator')
  mock.env(on, { TMUX_PANE: '%7' })
  await $.session.start(START)
  await $.prompt.submit({ text: '派：修登录', wait: false, origin: HAND, turnId: 't1' })
  expect(filed).toEqual([])
  expect(entered).toEqual(['派：修登录'])
})

test('qd: an unreadable role file keeps the orchestrator window its /qd', async ($, on) => {
  resetRole()
  const { registered } = engine(on, 'orchestrator', undefined, false)
  mock.env(on, { TMUX_PANE: '%7' })
  await $.session.start(START)
  expect(registered.map(c => c.name)).toContain(QD_COMMAND)
})
